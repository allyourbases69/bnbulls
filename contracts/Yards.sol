// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Yards
 * @notice THE ARENA ROSTER. A bull may only be fought while its CURRENT owner
 *         has explicitly sent it into the yards, and an owner may take it back
 *         out again whenever it is not already in a fight.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS CONTRACT IS CALLED `Yards` AND NOT `Arena`
 *      ══════════════════════════════════════════════════════════════════════
 *      It IS the arena the owner asked for. `DECISIONS.md §17` parks the
 *      roman/arena framing across the product, and `§36` locks the replacement
 *      in the owner's own landing line — "build a herd, **send them into the
 *      yards**, keep them off the truck or they face the chop". "The yards" is
 *      the australian term for stockyards and `§36` records that it reads as
 *      both the holding pen and the arena, which is exactly what this contract
 *      is: the pen a duel-ready bull waits in to be matched. The fefers
 *      equivalent is `ArenaOptOut`; that name stays in the fefers archive.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE HOLE THIS CLOSES — AND IT IS TWO HOLES, NOT ONE
 *      ══════════════════════════════════════════════════════════════════════
 *      Before this contract existed, "am I in the arena" was answered by the
 *      ERC-20 ALLOWANCE. `Duel._takeSide` says so in its own comment — "A
 *      passive opponent stakes by allowance, always" — and a wallet with a zero
 *      allowance reverts a staked fight with `StakeNotApproved`.
 *
 *      That is a real gate, and it has two defects that make it not a gate at
 *      all:
 *
 *      1. **IT IS WALLET-WIDE, NOT PER-BULL.** One `approve` sent so a player
 *         can fight their scrappy common ALSO makes their legendary matchable —
 *         and killable — by anyone who asks the signer for a fight. A holder
 *         cannot say "this one fights, that one does not" at any price. That is
 *         the same defect fefers built `ArenaOptOut` for.
 *
 *      2. **A ZERO-STAKE DUEL SKIPS IT ENTIRELY.** `Duel._takeSide` returns on
 *         `stake == 0` BEFORE it reads `balanceOf` or `allowance`, so a fight
 *         with `assetA/assetB == address(0)` and both stakes zero touches no
 *         allowance anywhere. `DECISIONS.md §25` already stopped such a fight
 *         BUYING A JACKPOT TICKET, but it still settles: `applyDuelResult`
 *         runs, the ELO moves, `consecutiveLosses` increments — and the
 *         `lossesToDie`-th consecutive loss KILLS THE BULL. Five signed
 *         zero-cost losses and it is sausages (`§32`, `§36`), against a wallet
 *         that never approved anything, never sent a transaction to any game
 *         contract, and never consented to a single fight.
 *
 *         The only thing standing in the way of that today is the off-chain
 *         signer's policy plus `Duel._authorize` (the submitter must own one
 *         side). That is policy, not bytecode, and `DECISIONS.md §16` is the
 *         house ruling on exactly this distinction: the fefers autoplay bot
 *         killed 34 of 60 bulls through a policy bug, so the protection was
 *         moved into the bytecode where no future bot can reintroduce it.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE HARD PART: AN EJECT MUST NOT BECOME A DODGE
 *      ══════════════════════════════════════════════════════════════════════
 *      The owner's words are "eject their bulls **if not in a fight and haven't
 *      paid the money**". The second half is the whole design problem.
 *
 *      A duel settles when someone submits a SIGNED result. The result carries
 *      `winnerId`, and on BSC the mempool is public — so a passive opponent who
 *      is about to lose can SEE the losing result in the pending transaction.
 *      If leaving the yards took effect the instant the transaction landed, the
 *      opponent would front-run it, `submitDuel` would revert, and the loss
 *      would evaporate. Repeat that on every losing fight and you have a wallet
 *      that only ever wins. It would not be a safety feature, it would be an
 *      undefeatable-bull button.
 *
 *      ⚠ `Duel.fightSeq` DOES NOT SOLVE THIS, and it is worth being precise
 *      about why, because at a glance it looks like it should. The per-wallet
 *      sequence guarantees that **at most one** signed result naming a wallet
 *      can ever settle — it bounds HOW MANY results land. It is consumed at
 *      SETTLEMENT, so nothing on chain marks a wallet as "busy" while a
 *      signature is outstanding, and it therefore says nothing about WHETHER a
 *      given result lands. Anti-dodging needs the second property, so it needs
 *      a different mechanism.
 *
 *      **The mechanism is a delay, and only on the way OUT.**
 *
 *        - `enter` is INSTANT. Entering can only ever expose you to more
 *          fights, so there is no outcome it can dodge and no reason to make a
 *          player wait.
 *        - `eject` SCHEDULES a departure at `block.timestamp + ejectDelay`.
 *          Until that moment the bull is still in the yards and every
 *          already-signed fight naming it still settles, exactly as if nothing
 *          had happened.
 *
 *      `MIN_EJECT_DELAY` is 5 minutes and that number is not a taste: it is
 *      `MAX_DUEL_EXPIRY_SECONDS` from `frontend/src/lib/serverEnv.ts`, the hard
 *      ceiling on how long the signer is allowed to make a duel signature live
 *      (the launch default there is 180 seconds). So by the time an eject
 *      bites, EVERY signature that could possibly name that bull has already
 *      expired. A dodge is not merely discouraged, it is arithmetically
 *      impossible — while a genuine eject still completes inside five minutes.
 *
 *      ⚠ WHY THIS IS 5 MINUTES AND NOT THE 15 IT LAUNCHED AT. Both numbers
 *      satisfied the safety property; 15 was simply the wrong one to pick. The
 *      floor only has to outlive the LONGEST signature the signer may ever
 *      issue, and that ceiling was 900s while the value actually in use —
 *      `DEFAULT_DUEL_EXPIRY_SECONDS` — has always been 180s. So the delay was
 *      sized against a worst case nobody runs, and every honest player paid 15
 *      minutes for a 3-minute risk. Lowering the CEILING to 300 and the floor
 *      with it keeps the identical guarantee (a signature still cannot outlive
 *      an eject) at a fifth of the cost to the player. The margin over the
 *      180s default is still 120 seconds.
 *
 *      ⚠ IF THAT TTL CEILING IS EVER RAISED, RAISE `ejectDelay` FIRST. The two
 *      numbers are one safety property split across two repositories; the
 *      constant floor here is what stops the owner-settable value drifting
 *      under it. `DuelYards.t.sol` now READS `serverEnv.ts` and fails if the
 *      two ever disagree, so the pair can no longer drift silently — but the
 *      ORDER still matters on a live system: raise the floor (which means a
 *      redeploy of this contract, it is a `constant`) and get it wired BEFORE
 *      the signer starts issuing longer-lived signatures.
 *
 *      The other half is off chain and needs no delay: the signer reads this
 *      contract before it quotes, so a bull with a pending eject is unmatchable
 *      IMMEDIATELY. The delay only ever protects fights that were already
 *      signed and paid for; to every new opponent the bull is gone the moment
 *      the eject transaction confirms.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE DEFAULT IS **OUT**, INCLUDING FOR A FRESHLY MINTED BULL
 *      ══════════════════════════════════════════════════════════════════════
 *      Stated plainly because it has a real cost: **the yards are empty on
 *      launch day.** Nobody can be fought until they enter. Four reasons that
 *      is still the right call:
 *
 *      1. **THE FORGOTTEN TRANSACTION MUST LEAVE THE SAFE STATE.** This is the
 *         house rule, twice over: `DECISIONS.md §14` (`bnbullPaymentSellsFor
 *         BnbLeg` defaults false "if the configuration tx is ever forgotten,
 *         the safe behaviour is the one that happens anyway") and `§25` ("an
 *         unset mapping is zero, and a forgotten wiring tx must fail SAFE").
 *         Default IN means the dangerous state is the one you get by doing
 *         nothing, for every one of 501 bulls at once.
 *
 *      2. **THE ZERO-STAKE PATH NEEDS NO CONSENT AT ALL.** With a default of
 *         IN, a bull whose owner has never touched a game contract is grindable
 *         to death by five signed free losses. With a default of OUT, the same
 *         bull is untouchable until its holder deliberately says otherwise.
 *
 *      3. **THE PLAYER IS ALREADY SENDING A READINESS TRANSACTION.** Before a
 *         first staked fight a wallet must `approve` the stake asset anyway.
 *         Entering the yards rides in the same step of the UI, and `enter`
 *         takes an ARRAY, so a holder with twenty bulls sends ONE transaction,
 *         not twenty.
 *
 *      4. **A ROSTER OF EVERYTHING IS NOT A ROSTER.** The product wants a list
 *         of the bulls actually looking for a fight. Default IN makes that list
 *         "all 501", which tells a matchmaker nothing and tells a player
 *         nothing.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      A TRANSFER TAKES A BULL OUT OF THE YARDS. NO HOOK REQUIRED.
 *      ══════════════════════════════════════════════════════════════════════
 *      The stored entry is `(enteredBy, leavesAt)` and membership requires
 *      `enteredBy == the LIVE owner`. So the instant a bull changes hands the
 *      entry stops matching and the bull is out — no ERC-721 transfer hook, no
 *      per-transfer gas, no cooperation from `Bulls`, and no window where the
 *      new owner holds a fightable bull they never entered.
 *
 *      This deliberately DIVERGES from fefers, whose `ArenaOptOut` documents
 *      the opposite ("a bought warrior carries its previous owner's explicit
 *      choice until the new owner changes it"). Inheriting a stranger's
 *      standing instruction to fight is the same defect as defaulting IN, just
 *      aimed at buyers instead of minters — and `Marketplace` is NOT an escrow
 *      (see its own note: "This contract is not an escrow"), so a bull really
 *      can change hands between a signature being issued and that signature
 *      settling. `Duel` re-reads `ownerOf` at settlement for precisely that
 *      reason, and this check rides on the same read.
 *
 *      One honest consequence: a bull sold and later bought BACK by the same
 *      wallet is in the yards again without a new transaction, because the
 *      stored entry matches the live owner once more. That is the owner's own
 *      standing instruction being honoured, it can only ever affect that one
 *      wallet, and the alternative — clearing entries on transfer — is the
 *      hook this design exists to avoid.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY PER-TOKEN ONLY, WITH NO PER-WALLET DEFAULT
 *      ══════════════════════════════════════════════════════════════════════
 *      A per-wallet "all my bulls are in" default was considered and rejected.
 *      It buys one thing — a holder who mints again later does not re-enter —
 *      and `enter(uint256[])` already serves that holder in a single
 *      transaction. What it COSTS is a two-dimensional truth table (wallet in +
 *      token out, wallet out + token in, and the precedence rule between them),
 *      a second thing every UI and every keeper must read, and a second place
 *      for a bug to hide. It would also re-introduce the exact hazard §3 above
 *      removes: with a wallet default of IN, a bull bought into that wallet
 *      becomes fightable the moment it lands, without its new owner acting.
 *
 *      Fefers reached the same conclusion from the other direction — its v3
 *      note records collapsing a rarity-based default down to "NOTHING enters
 *      the arena by itself".
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THIS CONTRACT CANNOT REVERT ON THE FIGHT PATH
 *      ══════════════════════════════════════════════════════════════════════
 *      `fightBlocked` — the only function `Duel` calls — reads storage and
 *      nothing else. No `ownerOf`, no external call, no arithmetic that can
 *      overflow, no revert. `Duel` hands it the two live owners it has ALREADY
 *      read, so the check costs two cold `SLOAD`s and one `STATICCALL` and can
 *      never halt a fight by faulting.
 *
 *      That property is what earns this contract a TIMELOCKED wiring slot in
 *      `Duel` rather than the plain setter `marketplace` and `authorizedRouter`
 *      get. Those two are plain setters because they sit on the hot path and a
 *      dependency that starts reverting must be removable in one transaction.
 *      Here there is nothing to remove: a gate that cannot revert needs no
 *      liveness valve, and an eject that a single compromised-key transaction
 *      could switch off for the whole collection would not be a guarantee at
 *      all. `DECISIONS.md §18`'s lesson, generalised: the question is not "is
 *      there an off switch" but "can one key reach the thing holders are
 *      relying on".
 */
contract Yards is Ownable {
    // ─── Immutable refs ──────────────────────────────────────────────────

    /// @notice The bulls collection. Only ever read for `ownerOf`, and only in
    ///         the setters and the convenience views — never on `Duel`'s path.
    IERC721 public immutable bulls;

    // ─── True security ceilings (the only policy-free `constant`s) ───────

    /**
     * @notice Floor on the eject delay. **THIS IS THE ANTI-DODGE BOUND** and
     *         it is the one number in this contract the owner may not move.
     *
     * @dev 5 minutes == `MAX_DUEL_EXPIRY_SECONDS` (300) in
     *      `frontend/src/lib/serverEnv.ts`, the hard ceiling on how long the
     *      signer may make a duel signature live. Any eject delay at or above
     *      that outlives every signature that could name the bull, so a pending
     *      eject can never cancel a fight that was already signed — the loss
     *      lands, then the bull leaves. Set it below and "eject" becomes
     *      "cancel the fight I am losing", which is worth more than the bull.
     *
     *      ⚠ THESE TWO NUMBERS MOVE TOGETHER OR NOT AT ALL. They are one
     *      safety property that happens to be spelled in two languages, in two
     *      repositories, and no compiler checks across that seam.
     *      `test_theEjectFloorMatchesTheSignersSignatureCeiling` closes it by
     *      reading the TypeScript source from Solidity at test time.
     *
     *      ⚠ The linter flags `block.timestamp` comparisons as
     *      validator-manipulable, and here that is answered rather than
     *      suppressed: a BSC validator can nudge a timestamp by seconds, and
     *      the margin this bound has to survive is FIVE MINUTES. That is still
     *      four orders of magnitude more than the couple of seconds a block
     *      producer can shift, so the conclusion is unchanged by the retune —
     *      nothing they can do to the clock moves a departure across that gap.
     *      The same reasoning is why `Duel`'s own `expiry` check has always
     *      carried the identical warning without a mitigation.
     */
    uint64 public constant MIN_EJECT_DELAY = 5 minutes;

    /**
     * @notice Ceiling on the eject delay.
     * @dev The mirror-image bound. Without it a compromised owner key could set
     *      the delay to a decade and nobody could ever take a bull out of the
     *      yards again — the feature would be present in the ABI and dead in
     *      practice. A day is long enough to cover any plausible future
     *      signature policy and short enough that a hostile setting is a
     *      nuisance rather than a trap.
     */
    uint64 public constant MAX_EJECT_DELAY = 24 hours;

    // ─── Types ───────────────────────────────────────────────────────────

    /**
     * @notice One bull's standing instruction. Packs into a single slot.
     * @param enteredBy The wallet that sent this bull in. Membership requires
     *                  this to equal the LIVE owner, which is what makes a
     *                  transfer take the bull out for free.
     * @param leavesAt  Unix time the eject takes effect. Zero means "staying".
     *                  Stamped when `eject` is called, so a later change to
     *                  `ejectDelay` can never move a departure already in
     *                  flight.
     */
    struct Entry {
        address enteredBy;
        uint64 leavesAt;
    }

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice tokenId => standing instruction. Unset means OUT (see header).
    mapping(uint256 => Entry) public entryOf;

    /// @notice How long an eject takes to bite. A player-facing number, so a
    ///         bounded owner setter rather than a constant — but bounded BELOW
    ///         by the anti-dodge floor, which is the part that is not policy.
    /// @dev Launches AT the floor deliberately. The floor is already the
    ///      smallest value the safety property permits, so any larger default
    ///      would just be a tax on the player with nothing bought for it; the
    ///      setter exists to go UP if the signer's TTL ceiling ever rises.
    uint64 public ejectDelay = 5 minutes;

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    /// @notice A bull is in the yards, effective immediately. THE event a
    ///         matchmaker indexes to build the roster.
    event EnteredYards(uint256 indexed tokenId, address indexed owner);
    /// @notice A bull is scheduled to leave. It is still fightable until
    ///         `leavesAt` — that is the anti-dodge delay, not a bug.
    event LeavingYards(uint256 indexed tokenId, address indexed owner, uint64 leavesAt);
    event EjectDelayChanged(uint64 previous, uint64 next);
    event SocialsChanged(string website, string twitter, string telegram);

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    /// @dev The caller is not the LIVE owner of that bull. Checked against
    ///      `ownerOf` at call time, never against a stored owner: only the
    ///      wallet holding the bull right now may speak for it.
    error NotTokenOwner(uint256 tokenId);
    error EmptyBatch();
    error EjectDelayOutOfRange(uint64 requested);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address initialOwner, address bullsAddress) Ownable(initialOwner) {
        if (bullsAddress == address(0)) revert ZeroAddress();
        bulls = IERC721(bullsAddress);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The player's two buttons
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Send bulls into the yards. Effective IMMEDIATELY.
     * @param tokenIds The bulls to enter. Batched so a holder with twenty of
     *                 them sends one transaction (see the header).
     *
     * @dev Reverts on the FIRST id the caller does not own, so a batch either
     *      applies whole or not at all — a half-applied roster is worse than a
     *      rejected one, because the player would have to diff it to find out
     *      what happened.
     *
     *      Calling this on a bull that is already leaving CANCELS the eject —
     *      that is deliberate and it is safe: cancelling an eject can only ever
     *      make the bull MORE available, so it cannot duck anything.
     *
     *      No liveness check. A dead bull cannot fight (`Duel._validate`
     *      enforces `isAlive`), and a bull bought back off the truck through
     *      the `Graveyard` should not have to be re-entered.
     */
    function enter(uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n;) {
            uint256 id = tokenIds[i];
            if (bulls.ownerOf(id) != msg.sender) revert NotTokenOwner(id);
            entryOf[id] = Entry({enteredBy: msg.sender, leavesAt: 0});
            emit EnteredYards(id, msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Take bulls back out of the yards. Effective after `ejectDelay` —
     *         read the anti-dodge section of the header before changing this.
     * @param tokenIds The bulls to pull out.
     *
     * @dev A bull that is not actually in the yards (never entered, or entered
     *      by a previous owner) is skipped rather than reverted: a holder
     *      ejecting their whole stack should not have the transaction fail
     *      because three of them were already out.
     *
     *      ⚠ An existing, EARLIER departure is never pushed back. Without that
     *      guard a second `eject` on a bull whose delay had already elapsed
     *      would stamp a fresh future timestamp and put the bull BACK in the
     *      yards — an eject that re-enters is the last thing this function
     *      should be able to do.
     */
    function eject(uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        if (n == 0) revert EmptyBatch();
        uint64 at = uint64(block.timestamp) + ejectDelay;
        for (uint256 i; i < n;) {
            uint256 id = tokenIds[i];
            if (bulls.ownerOf(id) != msg.sender) revert NotTokenOwner(id);
            Entry storage e = entryOf[id];
            if (e.enteredBy == msg.sender && (e.leavesAt == 0 || e.leavesAt > at)) {
                e.leavesAt = at;
                emit LeavingYards(id, msg.sender, at);
            }
            unchecked {
                ++i;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Is this bull in the yards, given its live owner?
     *
     * @dev ⚠ THE HOT-PATH READ. Storage only — no external call, no `ownerOf`,
     *      nothing that can revert. `Duel` passes the owner it already read at
     *      settlement, so this adds no reads to a fight and cannot fault one.
     *
     *      The `liveOwner == address(0)` guard is not decoration: `enteredBy`
     *      is zero for every bull that was never entered, so without it a zero
     *      owner would match the whole collection and report every bull IN.
     */
    function inYardsFor(uint256 tokenId, address liveOwner) public view returns (bool) {
        if (liveOwner == address(0)) return false;
        Entry storage e = entryOf[tokenId];
        if (e.enteredBy != liveOwner) return false;
        uint64 lv = e.leavesAt;
        return lv == 0 || block.timestamp < lv;
    }

    /**
     * @notice `Duel`'s single question: may these two fight?
     * @return blockedToken 0 if both are in the yards, else the id of the
     *         first one that is not.
     *
     * @dev Returns the offending id rather than a bool so `Duel` can name the
     *      bull in its revert with ONE staticcall instead of two. Zero is an
     *      unambiguous "nothing blocked" because zero is not a valid bull:
     *      `Bulls` rejects it (`id == 0 || (id > MAX_SUPPLY && id !=
     *      KING_TOKEN_ID)`) and mints from 1.
     */
    function fightBlocked(uint256 tokenA, address ownerA, uint256 tokenB, address ownerB)
        external
        view
        returns (uint256 blockedToken)
    {
        if (!inYardsFor(tokenA, ownerA)) return tokenA;
        if (!inYardsFor(tokenB, ownerB)) return tokenB;
        return 0;
    }

    /// @notice Is this bull in the yards right now? The UI/keeper read, which
    ///         resolves the live owner itself. Reverts for a nonexistent id,
    ///         because `ownerOf` does.
    function inYards(uint256 tokenId) public view returns (bool) {
        return inYardsFor(tokenId, bulls.ownerOf(tokenId));
    }

    /// @notice Batch of `inYards`, same order as the input. What the roster
    ///         page and the signer call.
    function inYardsMany(uint256[] calldata tokenIds) external view returns (bool[] memory out) {
        uint256 n = tokenIds.length;
        out = new bool[](n);
        for (uint256 i; i < n;) {
            out[i] = inYards(tokenIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Everything a UI needs to render one bull's yard status.
     * @return enteredBy Who sent it in (zero if never entered).
     * @return leavesAt  When a pending eject bites (zero if none).
     * @return live      Whether it is fightable right now.
     *
     * @dev `leavesAt` in the future with `live == true` is the "leaving in
     *      04:31" state — show the countdown, and say plainly that fights
     *      already signed can still land until it reaches zero.
     */
    function statusOf(uint256 tokenId)
        external
        view
        returns (address enteredBy, uint64 leavesAt, bool live)
    {
        Entry storage e = entryOf[tokenId];
        return (e.enteredBy, e.leavesAt, inYards(tokenId));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Retune how long an eject takes to bite.
     * @dev Bounded by `MIN_EJECT_DELAY` / `MAX_EJECT_DELAY`. Raising it does
     *      NOT extend a departure already scheduled — `leavesAt` is an absolute
     *      timestamp stamped at eject time — so a compromised owner key cannot
     *      trap bulls that are already on their way out.
     */
    function setEjectDelay(uint64 delaySeconds) external onlyOwner {
        if (delaySeconds < MIN_EJECT_DELAY || delaySeconds > MAX_EJECT_DELAY) {
            revert EjectDelayOutOfRange(delaySeconds);
        }
        emit EjectDelayChanged(ejectDelay, delaySeconds);
        ejectDelay = delaySeconds;
    }

    /// @notice `DECISIONS.md §5` — owner-settable, not constants, because
    ///         handles and domains move.
    function setSocials(string calldata w, string calldata t, string calldata g)
        external
        onlyOwner
    {
        website = w;
        twitter = t;
        telegram = g;
        emit SocialsChanged(w, t, g);
    }
}
