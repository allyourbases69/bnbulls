// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Stats} from "./lib/Stats.sol";
import {Xorshift} from "./lib/Xorshift.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

/**
 * @title Bulls
 * @notice The bnbulls ERC-721. Every bull's full record — stats, weapon, ELO,
 *         wins/losses, status — lives on-chain. 500 in the curated drop plus
 *         the 1-of-1 king at #501.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT CARRIES OVER FROM FIGHTING FEFERS UNTOUCHED
 *      ══════════════════════════════════════════════════════════════════════
 *      The rarity shuffle (Fisher-Yates over a SplitMix-seeded xorshift128+
 *      from `masterSeed`), the point-buy stat roll, the weapon catalog's
 *      damage/speed/type/weight tuples and the per-tier weapon slices. Those
 *      are the combat balance; the port renames and re-arts them, nothing
 *      more. `initialRarityHash` is the fairness proof: anyone can re-derive
 *      the shuffle off-chain from `masterSeed` alone and check it matches.
 *      ⚠ THE POOLS FREEZE AT DEPLOY. Reordering or inserting anything
 *      re-rolls every token.
 *
 *      WHAT CHANGED, AND WHY
 *      ══════════════════════════════════════════════════════════════════════
 *      1. **Five clean tiers** (`DECISIONS.md §7`). Fefers shipped with tier 3
 *         labelled "Legendary" holding the `TIER_EPIC` count and tier 4
 *         labelled "Epic" holding `TIER_LEGENDARY` — the names read swapped
 *         against the values and the contract carried a paragraph of comment
 *         explaining it. Here the ladder is boring and correct:
 *           0 common 200 / 1 uncommon 130 / 2 rare 90 / 3 epic 50 /
 *           4 legendary 30 / 5 king (#501 only). 200+130+90+50+30 = 500.
 *
 *      2. **No founder bands, no founder badges, no house flag**
 *         (`DECISIONS.md §11`). Fefers carried `isHouseOutlaw` for exactly one
 *         reason — to stop keeper-owned tokens in the 1..100 founder range
 *         pocketing founder perks. With founders deleted the flag has no
 *         consumer left, so it is gone rather than left as dead state.
 *
 *      3. **Names are DEALT off-chain and published here** (`DECISIONS.md §9`).
 *         Fefers rolled names on-chain from a 50x50 pool, which collides hard
 *         (the birthday problem gave rare 46 unique names across 90 tokens).
 *         The bnbulls generator deals each tier's shuffled pool one name per
 *         token through a shared `taken` set — 501 names, 501 unique — using
 *         an rng stream separate from the trait stream. That algorithm is not
 *         reproducible on-chain at sane gas, so the owner publishes the dealt
 *         table via `setNames` and `namesCommitment` (a constructor argument,
 *         committed BEFORE the sale) is what anyone checks it against.
 *         `freezeNames()` seals it.
 *
 *      4. **Wiring is TIMELOCKED, never one-time-set** (`BUILD-PLAN.md` rule
 *         2). The live fefers NFT pinned its Duel and Graveyard with a
 *         one-time-set, which froze `CONSECUTIVE_LOSSES_TO_DIE = 3` forever
 *         and made a later request for 4 losses impossible. See
 *         `lib/TimelockedAddress.sol`.
 *
 *      5. **The resurrection multipliers are a bounded setter**, not a
 *         hard-coded array.
 */
contract Bulls is ERC721, Ownable, Pausable {
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── Combat constants (ported unchanged — do not touch) ──────────────

    /// @notice Starting ELO for every bull.
    uint32 public constant STARTING_ELO = 1_000;
    /// @notice Absolute floor on ELO regardless of losses.
    uint32 public constant MIN_ELO = 100;

    // ─── Supply (structural: the art and the rarity table are built to it) ─

    /// @notice Hard cap on the curated drop. LOCKED, `DECISIONS.md §13`.
    uint32 public constant MAX_SUPPLY = 500;
    /// @notice The 1-of-1 king, "Lord Wagyu". Not counted against MAX_SUPPLY.
    uint32 public constant KING_TOKEN_ID = 501;

    // Tier counts for the 500-token drop. Sum MUST equal MAX_SUPPLY.
    // 40% / 26% / 18% / 10% / 6%. `DECISIONS.md §7`.
    uint32 private constant TIER_COMMON = 200;
    uint32 private constant TIER_UNCOMMON = 130;
    uint32 private constant TIER_RARE = 90;
    uint32 private constant TIER_EPIC = 50;
    uint32 private constant TIER_LEGENDARY = 30;

    // ─── Wiring timelock bounds (true security ceilings) ─────────────────

    /// @notice Shortest wiring timelock the owner may configure. A compromised
    ///         key therefore always has to publish its intent six hours ahead.
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    /// @notice Longest, so the delay cannot be set to "never".
    uint256 public constant MAX_WIRING_DELAY = 30 days;
    /// @notice Ceiling on a resurrection-cost multiplier.
    uint16 public constant MAX_RARITY_MULT = 1_000;

    // ─── Types ───────────────────────────────────────────────────────────

    /// @notice Full on-chain record for one bull.
    struct Bull {
        // Slot 1 (packed): 6 bytes stats + 1 weaponId + 2 level + 4 xp
        //                  + 4 elo + 2 wins + 2 losses + 2 ties + 1 flag
        uint8 strength;
        uint8 dexterity;
        uint8 constitution;
        uint8 intelligence;
        uint8 wisdom;
        uint8 charisma;
        uint8 weaponId; // index into the weapon catalog
        uint16 level;
        uint32 xp;
        uint32 elo;
        uint16 wins;
        uint16 losses;
        uint16 ties;
        bool isDead;
        // Slot 2+
        string name;
    }

    /// @notice Weapon definition. 12 slots, count LOCKED.
    struct Weapon {
        string name;
        uint8 damageMin;
        uint8 damageMax;
        uint8 speed;
        uint8 weaponType; // 0 = blade, 1 = blunt, 2 = ranged
        uint8 weight; // rarity weight; slots 0..10 sum to 100
    }

    /// @dev The three externally wired game contracts.
    enum Wire {
        Duel,
        Graveyard,
        MintDrop
    }

    // ─── Storage ─────────────────────────────────────────────────────────

    /// @notice Master seed every trait is derived from. Commit it publicly
    ///         before the first mint.
    uint256 public immutable masterSeed;

    /// @notice keccak256 of the DEALT name table produced off-chain by the
    ///         generator from `masterSeed`. The fairness proof for names,
    ///         exactly parallel to `initialRarityHash`. Zero disables the
    ///         check (local/testnet only — never deploy mainnet with zero).
    bytes32 public immutable namesCommitment;

    // ⚠ `devWallet`, `DEV_RARITY_SCAN_LIMIT`, `rarityFrozen` and
    // `freezeRarity()` ALL LIVED HERE AND ARE GONE (`DECISIONS.md §31`).
    //
    // They existed only to serve `_skipRareForDev`, which mutated `_rarity`
    // after `initialRarityHash` was committed. With the skip deleted, NOTHING
    // writes `_rarity` after construction — so a `freezeRarity()` that freezes
    // nothing would be a lie in the ABI, and a `devWallet` that caps nothing
    // would be a lie in the explorer. The table is immutable from birth, which
    // is exactly what `verify:rarity` and the art commitment rest on.

    /// @notice Next token ID to mint. Starts at 1.
    uint32 public nextTokenId = 1;

    /// @dev Timelocked wiring slots, keyed by `Wire`.
    mapping(uint8 => TimelockedAddress.Slot) private _wires;

    /// @notice Delay a wiring change must age before it can be committed.
    ///         Bounded by MIN/MAX_WIRING_DELAY.
    uint256 public wiringDelay = 24 hours;

    /// @notice Per-token bull record.
    mapping(uint256 => Bull) internal _bulls;

    /// @notice Unix time a bull last died, 0 if it never has. Written by the
    ///         duel path, read by the Graveyard's owner-priority window. Not
    ///         cleared on revive — a later death overwrites it, so it always
    ///         describes the CURRENT stay in the graveyard.
    mapping(uint256 => uint64) public diedAt;

    /// @notice Weapon catalog. Index = weaponId. Immutable after construction.
    Weapon[] internal _weapons;

    /// @notice Resurrection-cost multiplier per tier 0..5. Owner-settable
    ///         within MAX_RARITY_MULT; the Graveyard reads it through
    ///         `computeResurrectionCost`.
    uint16[6] public rarityCostMult = [1, 3, 10, 30, 100, 500];

    /// @notice Pre-shuffled rarity tier per token. `_rarity[tokenId - 1]` is
    ///         the tier in 0..4.
    bytes private _rarity;

    /// @notice keccak256 of `_rarity` the moment shuffling finished in the
    ///         constructor. Since `DECISIONS.md §31` removed the dev-mint
    ///         skip-rare swap, nothing can ever change `_rarity` afterwards —
    ///         so this is not merely the INITIAL hash, it is the permanent one.
    ///         Re-derive the shuffle off-chain from `masterSeed` and check it
    ///         matches; `npm run verify:rarity` does exactly that.
    bytes32 public immutable initialRarityHash;

    /// @notice Once true, `setNames` is closed forever.
    bool public namesFrozen;

    /// @notice How many name slots the owner has written. Purely for the
    ///         deploy checklist — 501 means the table is fully published.
    uint256 public namesWritten;

    /// @notice Whether the 1-of-1 king has been minted.
    bool public kingMinted;

    /// @notice Base URI prefix for `tokenURI(id)`. Trailing slash matters.
    string private _baseTokenURI;

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    event BullMinted(uint256 indexed tokenId, address indexed owner, string name);
    event KingMinted(address indexed owner, string name);
    event BullStatsUpdated(
        uint256 indexed tokenId,
        uint32 newElo,
        uint16 newWins,
        uint16 newLosses,
        uint16 newTies,
        bool isDead
    );
    /// @notice A dead bull changed hands via the takeover-revive path.
    event GraveyardClaimed(uint256 indexed tokenId, address indexed from, address indexed to);
    event WireBootstrapped(Wire indexed slot, address indexed target);
    event WireProposed(Wire indexed slot, address indexed target, uint64 eta);
    event WireCommitted(Wire indexed slot, address indexed previous, address indexed next);
    event WireCancelled(Wire indexed slot, address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event BaseURISet(string oldURI, string newURI);
    event NamesSet(uint256 indexed fromTokenId, uint256 count);
    event NamesFrozen(uint256 namesWritten);
    event RarityCostMultChanged(uint8 indexed tier, uint16 mult);
    event SocialsChanged(string website, string twitter, string telegram);

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotAuthorized();
    error BullDoesNotExist(uint256 tokenId);
    /// @dev Takeover-revive tried to move a bull that is still alive.
    error NotDead(uint256 tokenId);
    error InvalidWeaponId(uint8 id);
    error WeightsMustSumTo100(uint256 actual);
    error NotMintDropOrOwner();
    error SupplyExhausted();
    error InvalidTokenId(uint256 tokenId);
    error InvalidTier(uint8 tier);
    error KingAlreadyMinted();
    error ZeroAddress();
    error DelayOutOfRange(uint256 requested);
    error NamesAreFrozen();
    error MultTooHigh(uint16 requested, uint16 cap);
    error EmptyBatch();

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyDuelContract() {
        if (msg.sender != _wires[uint8(Wire.Duel)].current) revert NotAuthorized();
        _;
    }

    modifier onlyGraveyardContract() {
        if (msg.sender != _wires[uint8(Wire.Graveyard)].current) revert NotAuthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    /**
     * @param initialOwner    Owner of the contract.
     * @param _masterSeed     Seed every trait derives from. Commit publicly
     *                        before the first mint.
     * @param _namesCommitment keccak256 of the generator's dealt name table.
     *
     * @dev ⚠ `_devWallet` WAS THE THIRD ARGUMENT AND IS GONE (`§31`). Anything
     *      still passing four arguments is calling the old ABI.
     */
    constructor(address initialOwner, uint256 _masterSeed, bytes32 _namesCommitment)
        ERC721("BNBulls", "BNBULLS") // ⚠ VERIFY: NFT symbol is an OWNER call,
        Ownable(initialOwner) //       DECISIONS locks the TOKEN ticker only.
    {
        masterSeed = _masterSeed;
        namesCommitment = _namesCommitment;
        _initializeWeapons();
        _initializeRarity();
        // The canonical, and now permanent, post-shuffle hash. Nothing can
        // mutate `_rarity` after this line.
        initialRarityHash = keccak256(_rarity);
    }

    // ─── Wiring: bootstrap once, timelocked forever after ────────────────

    /**
     * @notice First-time wiring of a game contract. Immediate, and only while
     *         the slot is still empty, so deploy day is not a two-day job.
     * @dev Every LATER change goes through propose → wait `wiringDelay` →
     *      commit. That is the whole point: the fefers one-time-set froze the
     *      Duel and Graveyard permanently, and the numbers inside them with it.
     */
    function bootstrapWire(Wire slot, address target) external onlyOwner {
        _wires[uint8(slot)].bootstrap(target);
        emit WireBootstrapped(slot, target);
    }

    /// @notice Propose replacing a wired contract. Publishes the target and
    ///         the ETA; anyone can watch for it.
    function proposeWire(Wire slot, address target) external onlyOwner returns (uint64 eta) {
        eta = _wires[uint8(slot)].propose(target, wiringDelay);
        emit WireProposed(slot, target, eta);
    }

    /// @notice Commit a matured wiring proposal.
    function commitWire(Wire slot) external onlyOwner {
        (address previous, address next) = _wires[uint8(slot)].commit();
        emit WireCommitted(slot, previous, next);
    }

    /// @notice Drop a pending wiring proposal.
    function cancelWire(Wire slot) external onlyOwner {
        address dropped = _wires[uint8(slot)].cancel();
        emit WireCancelled(slot, dropped);
    }

    /// @notice Read a wiring slot: live address, pending target, and its ETA.
    function wireOf(Wire slot)
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        TimelockedAddress.Slot storage s = _wires[uint8(slot)];
        return (s.current, s.pending, s.eta);
    }

    /// @notice The authorized Duel contract.
    function duelContract() public view returns (address) {
        return _wires[uint8(Wire.Duel)].current;
    }

    /// @notice The authorized Graveyard contract.
    function graveyardContract() public view returns (address) {
        return _wires[uint8(Wire.Graveyard)].current;
    }

    /// @notice The authorized MintDrop contract.
    function mintDropContract() public view returns (address) {
        return _wires[uint8(Wire.MintDrop)].current;
    }

    /// @notice Tune the wiring timelock, within [6 hours, 30 days]. A shorter
    ///         delay than the floor would make the timelock decorative.
    function setWiringDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_WIRING_DELAY || newDelay > MAX_WIRING_DELAY) {
            revert DelayOutOfRange(newDelay);
        }
        wiringDelay = newDelay;
        emit WiringDelayChanged(newDelay);
    }

    // ─── External: admin ─────────────────────────────────────────────────

    /**
     * @notice Publish a run of dealt names, starting at `startTokenId`.
     * @dev The names come from the generator's `assignNames()`, which deals
     *      each tier's shuffled pool through a shared `taken` set so all 501
     *      are unique. Verify the whole table against `namesCommitment` before
     *      calling `freezeNames()`. Writing a name for an already-minted bull
     *      is allowed until the freeze; after it, nothing moves.
     */
    function setNames(uint256 startTokenId, string[] calldata names) external onlyOwner {
        if (namesFrozen) revert NamesAreFrozen();
        if (names.length == 0) revert EmptyBatch();
        for (uint256 i = 0; i < names.length; i++) {
            uint256 id = startTokenId + i;
            if (id == 0 || (id > MAX_SUPPLY && id != KING_TOKEN_ID)) revert InvalidTokenId(id);
            if (bytes(_bulls[id].name).length == 0 && bytes(names[i]).length != 0) {
                namesWritten += 1;
            }
            _bulls[id].name = names[i];
        }
        emit NamesSet(startTokenId, names.length);
    }

    /// @notice Seal the name table. ONE-WAY.
    function freezeNames() external onlyOwner {
        namesFrozen = true;
        emit NamesFrozen(namesWritten);
    }

    /**
     * @notice Set the ERC-721 base URI. `tokenURI(id)` returns `baseURI + id`.
     * @param newBaseURI The new prefix. Include a trailing slash — omit it and
     *                   the URLs mash together.
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        emit BaseURISet(_baseTokenURI, newBaseURI);
        _baseTokenURI = newBaseURI;
    }

    /// @notice Public getter for the base URI (`_baseURI` is internal).
    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice Retune a tier's resurrection-cost multiplier.
     * @dev Fefers hard-coded `[1, 3, 10, 30, 100, 500]` into a view. Bounded
     *      setter here so the ladder can be re-balanced without a redeploy.
     */
    function setRarityCostMult(uint8 tier, uint16 mult) external onlyOwner {
        if (tier > 5) revert InvalidTier(tier);
        if (mult == 0 || mult > MAX_RARITY_MULT) revert MultTooHigh(mult, MAX_RARITY_MULT);
        rarityCostMult[tier] = mult;
        emit RarityCostMultChanged(tier, mult);
    }

    /// @notice Update the published socials.
    function setSocials(string calldata w, string calldata t, string calldata g)
        external
        onlyOwner
    {
        website = w;
        twitter = t;
        telegram = g;
        emit SocialsChanged(w, t, g);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── External: minting ───────────────────────────────────────────────

    /**
     * @notice Mint a single bull to `to`. Stats and weapon are deterministic
     *         from (masterSeed, tokenId); the tier comes from the shuffled
     *         `_rarity` table; the name comes from the published table.
     * @dev Only the wired MintDrop or the owner may call it.
     */
    function mint(address to) external whenNotPaused returns (uint256 tokenId) {
        if (msg.sender != mintDropContract() && msg.sender != owner()) {
            revert NotMintDropOrOwner();
        }
        if (nextTokenId > MAX_SUPPLY) revert SupplyExhausted();

        // ⚠ THE DEV RARITY SKIP IS GONE (`DECISIONS.md §31`). It used to swap
        // a dev-bound mint onto the next common/uncommon slot. Owner call: the
        // dev may mint a rare, epic or legendary like anyone else, because he
        // pays like anyone else.
        //
        // Deleting it is not a preference, it is a correctness requirement.
        // The swap mutated `_rarity` AFTER `initialRarityHash` was committed,
        // so a token's tier could move away from its dealt name AND its sprite
        // once minting had started — silently, permanently, and in a way no
        // off-chain table could ever be made correct, because it depended on
        // mint ORDER. `§27` is what that costs: the generator and the chain
        // disagreed on 377 of 500 tiers and it was caught with hours to spare.
        //
        // The rarity table is now immutable from construction. That is what
        // `verify:rarity` proves and what the art commitment rests on.

        tokenId = nextTokenId;
        nextTokenId = uint32(tokenId + 1);

        Bull storage b = _bulls[tokenId];
        _rollBull(b, tokenId);

        _safeMint(to, tokenId);
        emit BullMinted(tokenId, to, b.name);
    }

    // ─── External: King mint (the 1-of-1) ────────────────────────────────

    /**
     * @notice Mint the one-of-one king at #501 — **Lord Wagyu**
     *         (`DECISIONS.md §9`). Stats all 18 (bypasses the point-buy
     *         budget), the king-only weapon at index 11, starting ELO 2000,
     *         level 10, rarity tier 5. Owner-only, once.
     */
    function mintKing(address to) external whenNotPaused onlyOwner returns (uint256) {
        if (kingMinted) revert KingAlreadyMinted();
        kingMinted = true;

        Bull storage b = _bulls[KING_TOKEN_ID];
        b.strength = 18;
        b.dexterity = 18;
        b.constitution = 18;
        b.intelligence = 18;
        b.wisdom = 18;
        b.charisma = 18;
        b.weaponId = 11; // Gilded Pike, king-only
        b.level = 10;
        b.xp = 0;
        b.elo = 2_000;
        b.wins = 0;
        b.losses = 0;
        b.ties = 0;
        b.isDead = false;
        // ⚠ "Lord Wagyu" is the NAME of the 1-of-1. "King" is the RARITY TIER
        // label (tier 5) shown as an edition badge. Two different things — do
        // not collapse them. The generator's peerage pools never roll this
        // name for a regular mint, so it stays unique.
        b.name = "Lord Wagyu";

        _safeMint(to, KING_TOKEN_ID);
        emit BullMinted(KING_TOKEN_ID, to, b.name);
        emit KingMinted(to, b.name);
        return KING_TOKEN_ID;
    }

    // ─── External: mutations by the Duel contract ────────────────────────

    /**
     * @notice Apply a duel's state updates to two bulls. Duel-only.
     * @dev The Duel contract has already verified the signature and outcome;
     *      this just writes storage.
     */
    function applyDuelResult(
        uint256 aId,
        uint256 bId,
        uint32 newEloA,
        uint32 newEloB,
        uint32 winnerId,
        bool aDied,
        bool bDied
    ) external onlyDuelContract {
        Bull storage a = _bulls[aId];
        Bull storage b = _bulls[bId];

        if (winnerId == aId) {
            a.wins++;
            b.losses++;
        } else if (winnerId == bId) {
            b.wins++;
            a.losses++;
        } else {
            a.ties++;
            b.ties++;
        }

        a.elo = newEloA < MIN_ELO ? MIN_ELO : newEloA;
        b.elo = newEloB < MIN_ELO ? MIN_ELO : newEloB;

        // Stamp the moment of death. The Graveyard reads this to run its
        // owner-priority window, so a bot watching the chain cannot snipe a
        // corpse the instant it hits the ground.
        if (aDied) {
            a.isDead = true;
            diedAt[aId] = uint64(block.timestamp);
        }
        if (bDied) {
            b.isDead = true;
            diedAt[bId] = uint64(block.timestamp);
        }

        emit BullStatsUpdated(aId, a.elo, a.wins, a.losses, a.ties, a.isDead);
        emit BullStatsUpdated(bId, b.elo, b.wins, b.losses, b.ties, b.isDead);
    }

    // ─── External: mutations by the Graveyard contract ───────────────────

    /// @notice Clear the isDead flag. Graveyard-only.
    function resurrect(uint256 tokenId) external onlyGraveyardContract {
        Bull storage b = _bulls[tokenId];
        b.isDead = false;
        emit BullStatsUpdated(tokenId, b.elo, b.wins, b.losses, b.ties, false);
    }

    /**
     * @notice Hand a DEAD bull to a new owner — the takeover-revive path,
     *         where a stranger pays the higher ladder to claim a fallen bull
     *         instead of rescuing it for its holder.
     * @dev Deliberately narrow. It moves an NFT without the holder's
     *      signature, so the guards ARE the safety: Graveyard-only, the token
     *      must exist, and it must currently be dead. A living bull can never
     *      be moved this way. `_update` is used directly rather than
     *      `safeTransferFrom` because the Graveyard has no approval and should
     *      never hold blanket operator rights over the collection.
     */
    function graveyardClaim(uint256 tokenId, address to) external onlyGraveyardContract {
        if (to == address(0)) revert ZeroAddress();
        address from = _ownerOf(tokenId);
        if (from == address(0)) revert BullDoesNotExist(tokenId);
        if (!_bulls[tokenId].isDead) revert NotDead(tokenId);
        _update(to, tokenId, address(0));
        emit GraveyardClaimed(tokenId, from, to);
    }

    // ─── External: views ─────────────────────────────────────────────────

    function getBull(uint256 tokenId) external view returns (Bull memory) {
        if (_ownerOf(tokenId) == address(0)) revert BullDoesNotExist(tokenId);
        return _bulls[tokenId];
    }

    /// @notice The dealt name for a token. Readable before mint, so the
    ///         published table can be audited against `namesCommitment`
    ///         without minting anything.
    function nameOf(uint256 tokenId) external view returns (string memory) {
        return _bulls[tokenId].name;
    }

    /// @notice Cheap dead-state read for cross-contract guards (Marketplace
    ///         blocks listing a corpse, Duel blocks fighting one). Returns
    ///         false for non-existent tokens.
    function isDead(uint256 tokenId) external view returns (bool) {
        return _bulls[tokenId].isDead;
    }

    function getStats(uint256 tokenId) external view returns (Stats.StatBlock memory) {
        if (_ownerOf(tokenId) == address(0)) revert BullDoesNotExist(tokenId);
        Bull storage b = _bulls[tokenId];
        return Stats.StatBlock({
            strength: b.strength,
            dexterity: b.dexterity,
            constitution: b.constitution,
            intelligence: b.intelligence,
            wisdom: b.wisdom,
            charisma: b.charisma
        });
    }

    function getWeapon(uint8 weaponId) external view returns (Weapon memory) {
        if (weaponId >= _weapons.length) revert InvalidWeaponId(weaponId);
        return _weapons[weaponId];
    }

    function getBullWeapon(uint256 tokenId) external view returns (Weapon memory) {
        if (_ownerOf(tokenId) == address(0)) revert BullDoesNotExist(tokenId);
        return _weapons[_bulls[tokenId].weaponId];
    }

    function weaponCount() external view returns (uint256) {
        return _weapons.length;
    }

    /**
     * @notice Rarity tier for a tokenId:
     *           0 = common    (200)
     *           1 = uncommon  (130)
     *           2 = rare      (90)
     *           3 = epic      (50)
     *           4 = legendary (30)
     *           5 = king      (only #501)
     *         Fixed at deploy by the shuffle; independent of whether the token
     *         has been minted yet.
     */
    function rarityOf(uint256 tokenId) public view returns (uint8) {
        if (tokenId == KING_TOKEN_ID) return 5;
        if (tokenId < 1 || tokenId > MAX_SUPPLY) revert InvalidTokenId(tokenId);
        return uint8(_rarity[tokenId - 1]);
    }

    /// @notice Live keccak256 of the on-chain rarity table.
    /// @dev    Since `§31` this MUST always equal `initialRarityHash` — nothing
    ///         can write `_rarity` after the constructor. Kept as a public
    ///         invariant anyone can check rather than removed: if these two
    ///         ever differ, something is very wrong and it should be visible
    ///         from a block explorer without reading the source.
    function rarityHash() external view returns (bytes32) {
        return keccak256(_rarity);
    }

    /**
     * @notice Rarity-scaled resurrection cost: `baseCost × rarityCostMult`.
     *         The Graveyard supplies the base and this returns the scaled
     *         figure for a given bull.
     */
    function computeResurrectionCost(uint256 tokenId, uint256 baseCost)
        external
        view
        returns (uint256 cost)
    {
        uint8 tier = rarityOf(tokenId);
        if (tier > 5) revert InvalidTier(tier);
        return baseCost * uint256(rarityCostMult[tier]);
    }

    function isAlive(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) revert BullDoesNotExist(tokenId);
        return !_bulls[tokenId].isDead;
    }

    // ─── Internal: roll a bull from seed ─────────────────────────────────

    /**
     * @dev Sub-seeds for stats and weapon are derived independently so that
     *      changing one cannot shift the other. The weapon pick is constrained
     *      to the token's pre-shuffled tier. The NAME is deliberately not
     *      touched here — it comes from the dealt table (`setNames`).
     */
    function _rollBull(Bull storage b, uint256 tokenId) private {
        uint256 statsSeed = masterSeed ^ (tokenId * 0xbf58476d1ce4e5b9);
        uint256 weaponSeed = masterSeed ^ (tokenId * 0x94d049bb133111eb);

        Stats.StatBlock memory s = _rollStats(statsSeed);
        b.strength = s.strength;
        b.dexterity = s.dexterity;
        b.constitution = s.constitution;
        b.intelligence = s.intelligence;
        b.wisdom = s.wisdom;
        b.charisma = s.charisma;

        uint8 tier = uint8(_rarity[tokenId - 1]);
        b.weaponId = _rollWeaponInTier(weaponSeed, tier);

        b.level = 1;
        b.xp = 0;
        b.elo = STARTING_ELO;
        b.wins = 0;
        b.losses = 0;
        b.ties = 0;
        b.isDead = false;
    }

    function _rollStats(uint256 seed) private pure returns (Stats.StatBlock memory s) {
        Xorshift.State memory rng = Xorshift.create(seed);
        s.strength = Stats.STAT_MIN;
        s.dexterity = Stats.STAT_MIN;
        s.constitution = Stats.STAT_MIN;
        s.intelligence = Stats.STAT_MIN;
        s.wisdom = Stats.STAT_MIN;
        s.charisma = Stats.STAT_MIN;

        uint256 remaining = Stats.POINT_BUY_TOTAL;
        uint256 maxIterations = Stats.POINT_BUY_TOTAL * 20;

        for (uint256 iter = 0; iter < maxIterations && remaining > 0; iter++) {
            uint8 pickIdx = uint8(uint256(Xorshift.nextInt(rng, 0, 5)));
            uint8 current = _getStatByIndex(s, pickIdx);
            if (current >= Stats.STAT_MAX_AT_CREATION) continue;
            uint8 nextValue = current + 1;
            uint256 incrementCost = Stats.pointBuyCost(nextValue) - Stats.pointBuyCost(current);
            if (incrementCost > remaining) {
                // Check if ANY stat is still affordable; if not, break.
                bool canAny = false;
                for (uint8 k = 0; k < 6; k++) {
                    uint8 v = _getStatByIndex(s, k);
                    if (v >= Stats.STAT_MAX_AT_CREATION) continue;
                    uint256 kCost = Stats.pointBuyCost(v + 1) - Stats.pointBuyCost(v);
                    if (kCost <= remaining) {
                        canAny = true;
                        break;
                    }
                }
                if (!canAny) break;
                continue;
            }
            _setStatByIndex(s, pickIdx, nextValue);
            remaining -= incrementCost;
        }
        require(Stats.validate(s), "Bulls: rollStats produced invalid stats");
    }

    /**
     * @dev Weighted weapon pick inside a rarity tier. Weights are the catalog
     *      weights, summed per tier.
     */
    function _rollWeaponInTier(uint256 seed, uint8 tier) private view returns (uint8) {
        Xorshift.State memory rng = Xorshift.create(seed);
        (uint8 start, uint8 count) = _tierWeaponRange(tier);
        uint256[] memory weights = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            weights[i] = _weapons[start + i].weight;
        }
        return start + uint8(Xorshift.weightedPick(rng, weights));
    }

    /**
     * @dev (startIndex, count) of the weapon catalog slice per tier. The
     *      SLICES are the fefers slices, unchanged — only the names moved.
     *
     *      0 = common    (0-2:  Shiv, Pitchfork, Maul)
     *      1 = uncommon  (3-4:  Cleaver, Hornbow)
     *      2 = rare      (5-6:  Bolter, Morningstar)
     *      3 = epic      (7-8:  Reaper, Sledge)
     *      4 = legendary (9-10: Ring, Pike)
     *      5 = king      (11:   Gilded Pike — reachable only via mintKing)
     */
    function _tierWeaponRange(uint8 tier) private pure returns (uint8 start, uint8 count) {
        if (tier == 0) return (0, 3);
        if (tier == 1) return (3, 2);
        if (tier == 2) return (5, 2);
        if (tier == 3) return (7, 2);
        if (tier == 4) return (9, 2);
        if (tier == 5) return (11, 1);
        revert InvalidTier(tier);
    }

    // ─── Internal: stat block index helpers ──────────────────────────────

    function _getStatByIndex(Stats.StatBlock memory s, uint8 idx) private pure returns (uint8) {
        if (idx == 0) return s.strength;
        if (idx == 1) return s.dexterity;
        if (idx == 2) return s.constitution;
        if (idx == 3) return s.intelligence;
        if (idx == 4) return s.wisdom;
        if (idx == 5) return s.charisma;
        revert("Bulls: invalid stat index");
    }

    function _setStatByIndex(Stats.StatBlock memory s, uint8 idx, uint8 value) private pure {
        if (idx == 0) s.strength = value;
        else if (idx == 1) s.dexterity = value;
        else if (idx == 2) s.constitution = value;
        else if (idx == 3) s.intelligence = value;
        else if (idx == 4) s.wisdom = value;
        else if (idx == 5) s.charisma = value;
        else revert("Bulls: invalid stat index");
    }

    // ─── Internal: weapon catalog ────────────────────────────────────────

    /**
     * @dev The 12-slot catalog. Damage / speed / type / weight are the fefers
     *      tuples SLOT FOR SLOT, so combat balance and the type triangle carry
     *      over untouched. Only the names are bull-themed, and each name was
     *      matched to a slot whose TYPE fits it (0 = blade, 1 = blunt,
     *      2 = ranged) so nothing reads absurd — a maul is blunt, a hornbow is
     *      ranged.
     *
     *      ⚠ `generator/bull.mjs` exports `WEAPONS` in a DIFFERENT order. The
     *      art must render the weapon the chain assigns, so that array has to
     *      be reordered to match this catalog index-for-index:
     *        ["shiv","pitchfork","maul","cleaver","hornbow","bolter",
     *         "morningstar","reaper","sledge","ring","pike","kingpike"]
     *      Index 11 renders the king-only "kingpike" sprite: slot 10's Pike,
     *      gilded and carrying his pennant — the same relationship the fefers
     *      Golden Warbow had to the Warbow.
     */
    function _initializeWeapons() private {
        //          name            dmgMin dmgMax spd type weight
        _addWeapon("Shiv", 6, 11, 9, 0, 18);
        _addWeapon("Pitchfork", 8, 13, 6, 1, 17);
        _addWeapon("Maul", 8, 13, 5, 1, 15);
        _addWeapon("Cleaver", 10, 15, 6, 0, 12);
        _addWeapon("Hornbow", 11, 16, 7, 2, 11);
        _addWeapon("Bolter", 14, 22, 4, 2, 9);
        _addWeapon("Morningstar", 14, 24, 3, 1, 7);
        _addWeapon("Reaper", 15, 22, 6, 0, 5);
        _addWeapon("Sledge", 16, 24, 5, 0, 3);
        _addWeapon("Ring", 22, 35, 2, 2, 2);
        _addWeapon("Pike", 25, 40, 6, 2, 1);
        // King-tier only. Weight 0 because it is not in any weighted pool.
        //
        // ⚠ RENAMED FROM "Gilded Prod" 2026-08-06, ON OWNER INSTRUCTION
        //   ("Lord Wagyu should have a better weapon than a prod staff").
        //   NAME ONLY. `50, 100, 10, 2, 0` is byte-for-byte what it was, and
        //   type 2 in particular is a vertex of the verified type-advantage
        //   triangle — `npm run verify:combat` proves no combat number here
        //   differs from fefers. The art side is `generator/bull.mjs`'s
        //   "kingpike" sprite; the two must agree or `verify:rarity` fails.
        _addWeapon("Gilded Pike", 50, 100, 10, 2, 0);

        // Slots 0..10 are the normal drop and MUST sum to 100.
        uint256 total = 0;
        for (uint256 i = 0; i < 11; i++) {
            total += _weapons[i].weight;
        }
        if (total != 100) revert WeightsMustSumTo100(total);
    }

    function _addWeapon(
        string memory name,
        uint8 damageMin,
        uint8 damageMax,
        uint8 speed,
        uint8 weaponType,
        uint8 weight
    ) private {
        _weapons.push(
            Weapon({
                name: name,
                damageMin: damageMin,
                damageMax: damageMax,
                speed: speed,
                weaponType: weaponType,
                weight: weight
            })
        );
    }

    /**
     * @dev Fill `_rarity` with the sorted tier distribution, then Fisher-Yates
     *      shuffle it with a masterSeed-derived PRNG. Runs once, in the
     *      constructor; the result is permanent and `initialRarityHash` is
     *      taken from it immediately afterwards.
     */
    function _initializeRarity() private {
        bytes memory r = new bytes(MAX_SUPPLY);
        uint256 cursor = 0;
        for (uint256 i = 0; i < TIER_COMMON; i++) {
            r[cursor++] = bytes1(uint8(0));
        }
        for (uint256 i = 0; i < TIER_UNCOMMON; i++) {
            r[cursor++] = bytes1(uint8(1));
        }
        for (uint256 i = 0; i < TIER_RARE; i++) {
            r[cursor++] = bytes1(uint8(2));
        }
        for (uint256 i = 0; i < TIER_EPIC; i++) {
            r[cursor++] = bytes1(uint8(3));
        }
        for (uint256 i = 0; i < TIER_LEGENDARY; i++) {
            r[cursor++] = bytes1(uint8(4));
        }
        require(cursor == MAX_SUPPLY, "Bulls: rarity dist mismatch");

        // Domain-separated shuffle seed, so rarity is decorrelated from the
        // stat and weapon streams.
        uint256 shuffleSeed = masterSeed ^ uint256(0x5348554646); // "SHUFF"
        Xorshift.State memory rng = Xorshift.create(shuffleSeed);
        for (uint256 i = MAX_SUPPLY - 1; i > 0; i--) {
            uint256 j = uint256(Xorshift.nextInt(rng, 0, int256(i)));
            bytes1 tmp = r[i];
            r[i] = r[j];
            r[j] = tmp;
        }
        _rarity = r;
    }

    // ─── Internal: OZ ERC-721 hooks ──────────────────────────────────────

    /// @dev Block transfers while paused. OZ 5.x routes every transfer/mint/
    ///      burn through `_update`.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        whenNotPaused
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    /// @dev So `tokenURI(id)` returns `baseURI + id`.
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
