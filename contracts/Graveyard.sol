// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Bulls} from "./Bulls.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

/// @dev MintDrop's donation entrypoints. The revive pot slice goes here so ONE
///      contract owns the 20/10 split, the swap routes and the never-fail
///      accrual for every source of pot money in the game.
/// @dev ⚠ Uniquely named on purpose. File-level declarations are hoisted into
///      any file that imports them, so a test importing both `MintDrop.sol`
///      and this would fail to compile on a duplicate `IJackpotFund`.
interface IMintDropDonate {
    function donatePotNative() external payable;
    function donatePotToken(address asset, uint256 amount) external;
}

/// @dev The Duel contract's streak hook. A revived bull starts clean.
interface IDuelStreak {
    function resetStreak(uint256 tokenId) external;
}

/**
 * @title Graveyard
 * @notice Permadeath, and the two ladders out of it. A bull that loses too
 *         many fights in a row flips dead; its holder can buy it back on the
 *         cheap OWNER ladder, and after a head-start a stranger can buy it
 *         back on the dearer TAKEOVER ladder and walk off with it. Both
 *         ladders spend the same finite pool of lives. When those are gone,
 *         the next death is forever and no price brings it back.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      RULE 1: THE LADDER IS IN DOLLARS, AND ON BNB THAT NEEDS AN ORACLE
 *      ══════════════════════════════════════════════════════════════════════
 *      The fefers Graveyard's comment reads "DOLLARS ONLY. Native amounts ARE
 *      dollars on Stable, so the ladder needs no oracle and no keeper peg."
 *      Every word of that is false here. `$50 / $200 / $500` are still the
 *      published numbers — that is the whole point of `DECISIONS.md §1`
 *      option A — but a dollar is no longer a unit of BNB. Each rung is stored
 *      as a 1e18-scaled dollar figure and converted at PAY TIME through the
 *      Chainlink BNB/USD feed, exactly as `MintDrop` does.
 *
 *      Stale `updatedAt`, a non-positive answer, an incomplete round and an
 *      out-of-band price all REVERT. Nothing is clamped: a clamped price is a
 *      wrong price presented as a right one, and here it would either sell
 *      lives for dust or price them out of reach.
 *
 *      ⚠ `msg.value >= due`, not `== due`, and the surplus is refunded. The
 *      conversion happens at pay time, so the oracle moves between the wallet
 *      quoting and the transaction landing. Insisting on equality would revert
 *      honest revives on ordinary volatility.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      RULE 2: `maxResurrects` IS A BOUNDED SETTER, NOT A CONSTANT
 *      ══════════════════════════════════════════════════════════════════════
 *      `MAX_RESURRECTS = 3` was a `constant` on fefers, behind a Graveyard
 *      slot the NFT had one-time-set, so it was frozen for the life of the
 *      collection. Here it is `maxResurrects`, settable inside
 *      `[1, MAX_RESURRECTS_CEILING]`, and both ladders are ARRAYS rather than
 *      three named rungs so a fourth life has a fourth price to charge for it.
 *      The only `constant` left is `MAX_RESURRECTION_COST`, a true security
 *      ceiling on any single rung.
 *
 *      A rung index past the end of a ladder reads the LAST rung, so a ladder
 *      never needs to be resized in lockstep with `maxResurrects` and can
 *      never leave a life priced at zero by accident.
 *
 *      ⚠ Lowering `maxResurrects` below a bull's spent count makes that bull
 *      permanently gone. That is a real consequence of a real setter, and it
 *      is the owner's call to make deliberately.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ONE COUNTER, NOT TWO (`DECISIONS.md §11`)
 *      ══════════════════════════════════════════════════════════════════════
 *      Fefers carried `resurrectsUsed` (every revive) AND `paidRevives` (paid
 *      ones only), and its own documentation says why: a founder freebie had
 *      to cost a LIFE without also costing a RUNG, so the owner ladder was
 *      indexed off the paid count.
 *
 *      **Founder tiers are gone, so the second counter is gone with them.**
 *      There is no code path here that revives a bull without payment — the
 *      owner ladder charges, the takeover ladder charges — so `paidRevives`
 *      would equal `resurrectsUsed` after every single transaction. Keeping it
 *      would be a duplicated source of truth whose only possible future is to
 *      disagree with the first one, plus a storage write per revive to keep
 *      two numbers identical. Both ladders index off `resurrectsUsed`.
 *
 *      It also removes an ambiguity the two-counter version had: if the owner
 *      ever sets a rung to $0 as a promotion, "did that advance the ladder?"
 *      has one obvious answer here (yes — a life and a rung were both spent)
 *      instead of depending on how `paid` was defined.
 *
 *      ⚠ If a future phase-2 mechanism ever grants a genuinely FREE revive (a
 *      bonded calf sponsoring a life), the second counter earns its place back
 *      and should be reintroduced THEN, with the free-revive path that needs
 *      it. A sponsored revive that someone still pays for does not need it.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      POT ROUTING (`DECISIONS.md §13`, §14)
 *      ══════════════════════════════════════════════════════════════════════
 *      `potShareBps` (30%) of every revive is handed to MintDrop's donation
 *      entrypoints, which split it 2:1 into the two pots — so a revive lands
 *      as 20% BNBULL / 10% BNB / 70% dev, the same as a mint. A BNBULL-paid
 *      revive routes 30% BNBULL / 0% BNB / 70% dev and sells nothing, because
 *      MintDrop's `bnbullPaymentSellsForBnbLeg` defaults to false (§14). One
 *      contract owns the split, the swap routes and the slippage floors; this
 *      one owns the ladder.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE NEVER-FAIL RULE, AND THE EXACT BUG IT EXISTS FOR
 *      ══════════════════════════════════════════════════════════════════════
 *      On fefers `MintDrop.donateJackpotBuy` was called from
 *      `Graveyard._routeNative` with NO try/catch:
 *
 *          IJackpotBuyDonate(mintDrop).donateJackpotBuy{value: jackpotShare}();
 *
 *      If that entrypoint ever reverted — paused, unwired, mid-upgrade, a
 *      buyback pool that did not exist yet — **every revive in the game
 *      bricked**, and the Graveyard was frozen so there was no fixing it from
 *      this side.
 *
 *      Here every pot leg is `pre-check, then try this.route…Inline() catch
 *      { accrue }` (`BNBULLS-BOOTSTRAP.md §6`). The inline worker is
 *      `external` ONLY so this contract can try/catch its own call and is
 *      gated by `NotSelf`. A failed leg accrues into a `pending*` bucket that
 *      a keeper sweeps later, and BOTH outcomes emit an event so which one is
 *      happening in production is visible on chain. **A revive can never fail
 *      because of a buyback.** Do not "simplify" the try/catch away.
 */
contract Graveyard is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── True security ceilings (the only policy-free `constant`s) ───────

    /// @notice Hard cap on any single ladder rung, 1e18-scaled dollars. Clears
    ///         the $1000 top takeover rung with room to retune while still
    ///         bounding a compromised owner key.
    uint256 public constant MAX_RESURRECTION_COST = 5_000e18;
    /// @notice Ceiling on `maxResurrects`. Permadeath has to stay reachable —
    ///         a bull that can always come back is a subscription.
    uint8 public constant MAX_RESURRECTS_CEILING = 10;
    /// @notice Ceiling on the holder's exclusive window.
    uint256 public constant MAX_OWNER_PRIORITY_WINDOW = 30 days;
    /// @notice Ceiling on how much of a revive the pots can take.
    uint256 public constant MAX_POT_SHARE_BPS = 5_000;
    /// @notice Ceiling on any per-asset discount. Launch is 1000 (10%) on
    ///         BNBULL (`DECISIONS.md §2`).
    uint16 public constant MAX_DISCOUNT_BPS = 5_000;
    /// @notice Ceiling on how stale a Chainlink answer may be and still be
    ///         used. The BSC BNB/USD feed heartbeats far faster than this.
    uint256 public constant MAX_ORACLE_AGE = 24 hours;
    /// @notice Ceiling on the keeper's BNBULL peg, in BNBULL wei per dollar.
    ///         ⚠ VERIFY against the real fixed supply at deploy.
    uint256 public constant MAX_BNBULL_PER_USD = 10_000_000e18;
    /// @notice Ceiling on the BNBULL peg staleness window. Past this the
    ///         freshness check stops being a check.
    uint256 public constant MAX_BNBULL_PEG_AGE = 30 days;
    /// @notice Wiring timelock bounds.
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;

    uint256 private constant BPS = 10_000;

    /// @notice Sentinel keying native BNB in `discountBpsOf`. BNB has no
    ///         token address. Same convention as `MintDrop`.
    address public constant NATIVE = address(0);

    // ─── Immutable refs ──────────────────────────────────────────────────

    /// @notice The bulls collection.
    Bulls public immutable bulls;
    /// @notice BNBULL: a payment currency, and the discounted one.
    IERC20 public immutable bnbull;

    // ─── Timelocked wiring ───────────────────────────────────────────────

    /// @dev Every slot here can redirect money or gate a revive, so every one
    ///      of them is bootstrap-once-then-timelocked. `treasury`,
    ///      `lpTreasury` and `keeper` are NOT: the first two are the owner's
    ///      own revenue and the third can only push money INTO a pot.
    /// ⚠ RENUMBERED BY `DECISIONS.md §26`. `Stablecoin` was slot 2 and
    ///   `PriceFeed` has moved 3 -> 2. The hole was not kept reserved; nothing
    ///   is deployed yet and a reserved slot preserves exactly the thing the
    ///   decision deletes.
    enum Wire {
        /// The Duel contract, whose loss streaks a revive clears.
        Duel,
        /// MintDrop, which owns the pot split and the swap routes.
        MintDrop,
        /// Chainlink BNB/USD (0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE).
        PriceFeed
    }

    mapping(uint8 => TimelockedAddress.Slot) private _wires;

    /// @notice Delay a wiring change must age before it can be committed.
    uint256 public wiringDelay = 24 hours;

    /// @notice `decimals()` read off the wired price feed (8 for BNB/USD).
    uint8 public feedDecimals;

    // ─── The two ladders ─────────────────────────────────────────────────

    /// @dev Rungs in 1e18-scaled dollars. Index = revives already spent; an
    ///      index past the end reads the last rung.
    uint256[] private _ownerLadder;
    uint256[] private _takeoverLadder;

    /// @notice Lifetime revives a bull may ever have. A VARIABLE, bounded by
    ///         `MAX_RESURRECTS_CEILING`. See the header for why this is not a
    ///         constant and what lowering it does.
    uint8 public maxResurrects = 3;

    /// @notice Revives a bull has spent. THE counter — there is only one.
    mapping(uint256 => uint256) public resurrectsUsed;

    /// @notice How long after a death only the HOLDER may revive. Stops a bot
    ///         sniping a corpse the instant it hits the ground: the owner gets
    ///         a full day to decide before the takeover door opens. Zero
    ///         disables the window.
    uint256 public ownerPriorityWindow = 24 hours;

    // ─── Pricing ─────────────────────────────────────────────────────────

    /// @notice Per-asset discount in bps. `NATIVE` keys the BNB leg. Launch:
    ///         1000 on BNBULL, 0 elsewhere (`DECISIONS.md §2`). Generic on
    ///         purpose — do NOT hardcode which asset is discounted.
    mapping(address => uint16) public discountBpsOf;

    /// @notice The keeper's peg: BNBULL wei per ONE DOLLAR, at the FULL
    ///         undiscounted sticker. Zero disables the BNBULL revive leg.
    ///
    /// @dev ⚠ DOUBLE-DISCOUNT TRAP, handled exactly as `MintDrop` handles it.
    ///      `DECISIONS.md §2` says the keeper pegs the BNBULL legs to "dollar
    ///      sticker − discount". If the keeper wrote the discounted number
    ///      here AND this contract applied `discountBpsOf[bnbull]` on top, a
    ///      BNBULL revive would be 19% off, not 10%. **The keeper pegs the
    ///      full sticker; this contract owns the discount.**
    ///
    ///      ⚠ ONE SCALAR, NOT A PER-RUNG TABLE — a deliberate divergence from
    ///      `MintDrop.PriceTier.bnbullPrice`. Mint tiers carry independent
    ///      dollar stickers the owner may want to move independently, so they
    ///      need a peg each. Every rung here derives from the SAME ladder, so
    ///      one peg cannot drift against another and there is no way to leave
    ///      rung 3 pegged at last week's price.
    uint256 public bnbullPerUsd;
    /// @notice When `bnbullPerUsd` was last written.
    uint64 public bnbullPegUpdatedAt;
    /// @notice A peg older than this disables the BNBULL leg rather than
    ///         selling lives at last week's price. Same principle as the
    ///         oracle staleness check: refuse, never guess.
    uint256 public maxBnbullPegAge = 6 hours;

    // ─── Oracle policy (mirrors MintDrop) ────────────────────────────────

    /// @notice Reject an answer older than this. ⚠ VERIFY the BNB/USD
    ///         heartbeat at kickoff and tighten.
    uint256 public maxOracleAge = 1 hours;
    /// @notice Optional sanity band on BNB/USD, 1e18-scaled. Zero disables a
    ///         side. A feed pinned at its circuit-breaker floor (the LUNA
    ///         failure mode) would otherwise sell lives for dust.
    uint256 public minBnbUsd;
    uint256 public maxBnbUsd;

    // ─── Routing ─────────────────────────────────────────────────────────

    /// @notice Receives the dev share of every revive.
    address public treasury;
    /// @notice The LP slot. Unused at launch (`lpShareBps = 0`) and kept on
    ///         purpose: on fefers this exact kind of slot was the hook that
    ///         added a whole buyback leg to a frozen contract with no
    ///         redeploy. Do not delete it as dead code.
    address public lpTreasury;
    /// @notice Share of the post-pot remainder routed to `lpTreasury`.
    uint256 public lpShareBps;
    /// @notice BNB whose LP transfer failed. Held here, never lost, sweepable
    ///         by the owner. See `_routeNative`.
    uint256 public lpUndelivered;
    /// @notice Share of every revive handed to MintDrop for the two pots.
    ///         3000 = 30%, which MintDrop splits 2:1 into 20% BNBULL / 10% BNB.
    uint256 public potShareBps = 3_000;

    /// @notice May run the deferred-leg sweeps in addition to the owner.
    address public keeper;

    // ─── Deferred pot legs (the never-fail fallback) ─────────────────────

    /// @dev Which asset a deferred pot leg is denominated in.
    /// @dev ⚠ RENUMBERED BY `DECISIONS.md §26`: `Stable` was 1 and `Bnbull` has
    ///      moved 2 -> 1. This value is the `paymentType` in `Resurrected`, so
    ///      an indexer keyed on the old codes reads every BNBULL revive as a
    ///      stablecoin one.
    enum PotSource {
        Native,
        Bnbull
    }

    /// @notice BNB set aside because the pot donation could not run.
    uint256 public pendingPotNative;
    /// @notice BNBULL set aside for the same reason.
    uint256 public pendingPotBnbull;

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    /// @param paymentType MintDrop's currency codes: 0 = BNB, 1 = BNBULL
    ///        (`DECISIONS.md §26` renumbered these — BNBULL used to be 2).
    /// @param usdSticker1e18 The undiscounted dollar rung that was charged, so
    ///        the receipt is readable without re-deriving the oracle price.
    event Resurrected(
        uint256 indexed tokenId,
        address indexed by,
        uint8 paymentType,
        uint256 paid,
        uint256 usdSticker1e18,
        uint256 revivesUsed
    );
    /// @notice A stranger paid the takeover ladder and walked off with a bull
    ///         that was lying dead in the graveyard.
    event ResurrectedAndClaimed(
        uint256 indexed tokenId,
        address indexed previousOwner,
        address indexed claimedBy,
        uint256 paid,
        uint256 revivesUsed
    );
    /// @notice The pot slice reached MintDrop inside the payer's own
    ///         transaction. The normal case.
    event PotFundedInline(PotSource indexed src, uint256 amount);
    /// @notice The pot slice could not be routed this time, so it accrued.
    ///         The exception, on chain, so nobody has to take our word for
    ///         which it was.
    event PotDeferred(PotSource indexed src, uint256 amount, uint256 bucketTotal);
    event PotSwept(PotSource indexed src, uint256 amount);
    event PendingWithdrawn(PotSource indexed src, address indexed to, uint256 amount);

    event LaddersChanged(uint256[] ownerLadder, uint256[] takeoverLadder);
    event MaxResurrectsChanged(uint8 maxResurrects);
    event OwnerPriorityWindowChanged(uint256 secondsWindow);
    event SharesChanged(uint256 potShareBps, uint256 lpShareBps);
    event DiscountSet(address indexed asset, uint16 bps);
    event BnbullPegChanged(uint256 bnbullPerUsd, uint64 at);
    event BnbullPegPolicyChanged(uint256 maxAge);
    event OraclePolicyChanged(uint256 maxAge, uint256 minPrice, uint256 maxPrice);
    event TreasuryChanged(address indexed previous, address indexed next);
    event LpTreasuryChanged(address indexed previous, address indexed next);
    event KeeperChanged(address indexed previous, address indexed next);
    event WireBootstrapped(Wire indexed slot, address indexed target);
    event WireProposed(Wire indexed slot, address indexed target, uint64 eta);
    event WireCommitted(Wire indexed slot, address indexed previous, address indexed next);
    event WireCancelled(Wire indexed slot, address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event SocialsChanged(string website, string twitter, string telegram);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice The LP slice could not be delivered and is being held here.
    event LpDeferred(uint256 amount, uint256 bucketTotal);
    event LpUndeliveredWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotDead(uint256 tokenId);
    error GoneForever(uint256 tokenId);
    /// @dev Owner ladder used by someone who is not the holder.
    error NotOwner(uint256 tokenId);
    /// @dev Takeover ladder used by the holder — they have a cheaper door.
    error AlreadyOwner(uint256 tokenId);
    /// @dev Takeover attempted inside the holder's exclusive window.
    error OwnerPriority(uint256 tokenId, uint256 opensAt);
    error InsufficientBNB(uint256 required, uint256 sent);
    /// @dev A token payment delivered less than it should have — a
    ///      fee-on-transfer or rebasing payment asset.
    error PaymentShortfall(address asset, uint256 expected, uint256 received);
    error RefundFailed();
    error TreasuryTransferFailed();
    error NothingUndelivered();
    error ZeroAddress();
    error InvalidLadder();
    error CostTooHigh(uint256 requested, uint256 cap);
    error InvalidShare(uint256 bps);
    error ValueOutOfRange(uint256 requested, uint256 cap);
    error DelayOutOfRange(uint256 requested);
    error NotSelf();
    error NotKeeperOrOwner();
    error NothingToSweep();
    error InsufficientPending(uint256 requested, uint256 available);
    error DuelNotWired();
    error MintDropNotWired();
    error BnbullPathNotPriced();
    error BnbullPegStale(uint64 updatedAt, uint256 maxAge);
    error PegTooHigh(uint256 requested, uint256 cap);
    error OracleNotWired();
    error OracleBadAnswer(int256 answer);
    error OracleBadRound(uint80 roundId, uint80 answeredInRound, uint256 updatedAt);
    error OracleStale(uint256 updatedAt, uint256 maxAge);
    error OracleOutOfBand(uint256 price1e18);
    error FeedDecimalsUnusable(uint8 decimals_);
    error ReservedForPots(uint256 requested, uint256 free);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address initialOwner, address _bulls, address _bnbull, address _treasury)
        Ownable(initialOwner)
    {
        if (_bulls == address(0) || _bnbull == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        bulls = Bulls(_bulls);
        bnbull = IERC20(_bnbull);
        treasury = _treasury;

        // The published ladders, in dollars. These MUST be real economics
        // rather than placeholders waiting on a `setLadders` call: a zero rung
        // on the takeover side would let anyone walk off with a dead bull for
        // free the moment the contract is wired.
        //   owner:    $50  -> $200 -> $500
        //   takeover: $200 -> $500 -> $1000
        _ownerLadder.push(50e18);
        _ownerLadder.push(200e18);
        _ownerLadder.push(500e18);
        _takeoverLadder.push(200e18);
        _takeoverLadder.push(500e18);
        _takeoverLadder.push(1_000e18);

        // `DECISIONS.md §2`: 1000 bps on BNBULL, 0 on every other asset.
        discountBpsOf[_bnbull] = 1_000;
        emit DiscountSet(_bnbull, 1_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The oracle — `DECISIONS.md §1`, option A
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice BNB/USD, normalised to 1e18.
     * @dev REVERTS rather than clamping on a non-positive answer, an
     *      incomplete round, a zero timestamp, an answer older than
     *      `maxOracleAge`, or a price outside the sanity band. A clamp would
     *      charge for a life at a price nobody chose.
     */
    function bnbUsdPrice() public view returns (uint256 price1e18) {
        address f = _wire(Wire.PriceFeed);
        if (f == address(0)) revert OracleNotWired();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(f).latestRoundData();

        if (answer <= 0) revert OracleBadAnswer(answer);
        if (updatedAt == 0 || answeredInRound < roundId) {
            revert OracleBadRound(roundId, answeredInRound, updatedAt);
        }
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > maxOracleAge) {
            revert OracleStale(updatedAt, maxOracleAge);
        }

        uint8 d = feedDecimals;
        price1e18 =
            d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
        if (price1e18 == 0) revert OracleBadAnswer(answer);
        if (minBnbUsd != 0 && price1e18 < minBnbUsd) revert OracleOutOfBand(price1e18);
        if (maxBnbUsd != 0 && price1e18 > maxBnbUsd) revert OracleOutOfBand(price1e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════════════════════════════

    function ownerLadder() external view returns (uint256[] memory) {
        return _ownerLadder;
    }

    function takeoverLadder() external view returns (uint256[] memory) {
        return _takeoverLadder;
    }

    /// @dev A rung index past the end of a ladder reads the LAST rung, so the
    ///      ladder never has to be resized in lockstep with `maxResurrects`
    ///      and a new life can never end up priced at zero by omission.
    function _rung(uint256[] storage ladder, uint256 used) private view returns (uint256) {
        uint256 n = ladder.length;
        return used >= n ? ladder[n - 1] : ladder[used];
    }

    /// @notice Dollar cost for the HOLDER to revive their own bull next.
    ///         Reverts `GoneForever` once the lives are spent.
    function costFor(uint256 tokenId) public view returns (uint256) {
        uint256 used = resurrectsUsed[tokenId];
        if (used >= maxResurrects) revert GoneForever(tokenId);
        return _rung(_ownerLadder, used);
    }

    /// @notice Dollar cost for a STRANGER to revive this corpse into their own
    ///         wallet. Dearer at every rung: the holder always has the cheaper
    ///         claim on their own fighter, so the way to keep a bull is to
    ///         pick it up before somebody else does.
    function takeoverCostFor(uint256 tokenId) public view returns (uint256) {
        uint256 used = resurrectsUsed[tokenId];
        if (used >= maxResurrects) revert GoneForever(tokenId);
        return _rung(_takeoverLadder, used);
    }

    /**
     * @notice One batched read for the graveyard UI. NEVER reverts, and never
     *         touches the oracle — a UI must be able to render a corpse card
     *         while the feed is stale.
     * @return allowed         false once the bull is out of lives for good
     * @return used            lives spent so far
     * @return ownerUsd1e18    dollars for the HOLDER to revive
     * @return takeoverUsd1e18 dollars for a stranger to revive AND claim it
     * @return takeoverOpensAt unix time the takeover door unlocks (0 = open)
     */
    function quoteResurrect(uint256 tokenId)
        external
        view
        returns (
            bool allowed,
            uint256 used,
            uint256 ownerUsd1e18,
            uint256 takeoverUsd1e18,
            uint256 takeoverOpensAt
        )
    {
        used = resurrectsUsed[tokenId];
        if (used >= maxResurrects) return (false, used, 0, 0, 0);
        allowed = true;
        ownerUsd1e18 = _rung(_ownerLadder, used);
        takeoverUsd1e18 = _rung(_takeoverLadder, used);
        uint64 died = bulls.diedAt(tokenId);
        if (died != 0) {
            uint256 opens = uint256(died) + ownerPriorityWindow;
            if (block.timestamp < opens) takeoverOpensAt = opens;
        }
    }

    /**
     * @notice What a given dollar sticker costs right now in each currency,
     *         discounts applied.
     * @dev Reverts if the oracle is stale or out of band — deliberately: a UI
     *      must not paper over a bad price. `bnbullDue` comes back as zero when
     *      that leg is not pegged or the peg is stale, rather than as a wrong
     *      number.
     */
    function quotePayment(uint256 usd1e18)
        external
        view
        returns (uint256 bnbDue, uint256 bnbullDue, uint256 bnbUsd1e18)
    {
        bnbUsd1e18 = bnbUsdPrice();
        bnbDue = _ceilDiv(_discounted(usd1e18, NATIVE) * 1e18, bnbUsd1e18);
        bnbullDue = _bnbullPegUsable() ? _usdToBnbull(usd1e18) : 0;
    }

    /// @notice The wired Duel contract.
    function duelContract() external view returns (address) {
        return _wire(Wire.Duel);
    }

    /// @notice The wired MintDrop.
    function mintDrop() external view returns (address) {
        return _wire(Wire.MintDrop);
    }

    /// @notice Every live wiring address in one call — the read the deploy
    ///         preflight and the keepers use.
    function wires()
        external
        view
        returns (address duel, address mintDrop_, address priceFeed)
    {
        return (_wire(Wire.Duel), _wire(Wire.MintDrop), _wire(Wire.PriceFeed));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The owner ladder — bring YOUR OWN bull back
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Revive your own dead bull, paying in BNB. Send at least
    ///         `quotePayment(costFor(tokenId)).bnbDue` plus a cushion; the
    ///         surplus comes back.
    function resurrectWithBNB(uint256 tokenId) external payable whenNotPaused nonReentrant {
        _revive(tokenId, PotSource.Native, false);
    }

    /// @notice Revive your own dead bull, paying in BNBULL — the discounted
    ///         path (`DECISIONS.md §2`).
    function resurrectWithBNBULL(uint256 tokenId) external whenNotPaused nonReentrant {
        _revive(tokenId, PotSource.Bnbull, false);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The takeover ladder — revive someone else's bull and TAKE IT
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Revive a stranger's dead bull and claim it, paying in BNB. The
     *         bull lands in the caller's wallet, alive.
     *
     * @dev This moves an NFT without its holder's signature, which is only
     *      defensible because (a) the bull is DEAD and `Bulls.graveyardClaim`
     *      reverts on anything still standing, (b) the holder could always
     *      have revived it first for less, (c) they had the priority window to
     *      do it in, and (d) the life count is shared, so a takeover burns one
     *      of the same finite lives. Out of lives is out of lives for
     *      everyone, holder and claimer alike.
     */
    function resurrectAndClaimWithBNB(uint256 tokenId)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        _revive(tokenId, PotSource.Native, true);
    }

    /// @notice Takeover revive paid in BNBULL — the discounted path.
    function resurrectAndClaimWithBNBULL(uint256 tokenId) external whenNotPaused nonReentrant {
        _revive(tokenId, PotSource.Bnbull, true);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The revive itself
    // ══════════════════════════════════════════════════════════════════════

    function _revive(uint256 tokenId, PotSource pay, bool takeover) private {
        address holder = bulls.ownerOf(tokenId);
        if (!bulls.isDead(tokenId)) revert NotDead(tokenId);
        uint256 used = resurrectsUsed[tokenId];
        if (used >= maxResurrects) revert GoneForever(tokenId);

        uint256 usd;
        if (takeover) {
            // The holder has their own, cheaper door. Sending them through
            // this one would just be charging them extra for their own bull.
            if (holder == msg.sender) revert AlreadyOwner(tokenId);
            // The holder's exclusive window. A bull with no death stamp falls
            // through as immediately claimable rather than locked forever.
            uint64 died = bulls.diedAt(tokenId);
            if (died != 0 && block.timestamp < uint256(died) + ownerPriorityWindow) {
                revert OwnerPriority(tokenId, uint256(died) + ownerPriorityWindow);
            }
            usd = _rung(_takeoverLadder, used);
        } else {
            if (holder != msg.sender) revert NotOwner(tokenId);
            usd = _rung(_ownerLadder, used);
        }

        address duel = _wire(Wire.Duel);
        if (duel == address(0)) revert DuelNotWired();

        // Spend the life before any external call (CEI).
        unchecked {
            resurrectsUsed[tokenId] = used + 1;
        }

        uint256 paid = _collect(pay, usd);

        IDuelStreak(duel).resetStreak(tokenId);

        if (takeover) {
            // Hand over the corpse FIRST, then breathe life into it, so the
            // claimer never owns a bull that is briefly alive under the old
            // holder — and `graveyardClaim`'s is-dead guard still holds.
            bulls.graveyardClaim(tokenId, msg.sender);
            bulls.resurrect(tokenId);
            emit ResurrectedAndClaimed(tokenId, holder, msg.sender, paid, used + 1);
        } else {
            bulls.resurrect(tokenId);
        }

        emit Resurrected(tokenId, msg.sender, uint8(pay), paid, usd, used + 1);

        // Dead last: the oracle cushion comes back only once the bull is
        // standing and every piece of state is settled. This is the one call
        // in the whole revive that hands control to an address of the caller's
        // choosing, so there is nothing left for a re-entrant frame to catch
        // half-done, on top of the `nonReentrant` guard.
        if (pay == PotSource.Native && msg.value > paid) {
            (bool ok,) = msg.sender.call{value: msg.value - paid}("");
            if (!ok) revert RefundFailed();
        }
    }

    /**
     * @dev Take payment in the chosen currency and route it. Returns what was
     *      actually charged, in that currency's own units.
     */
    function _collect(PotSource pay, uint256 usd) private returns (uint256 paid) {
        if (pay == PotSource.Native) {
            // ⚠ `>=`, not `==`. `DECISIONS.md §1` converts at PAY time, so the
            // oracle moves between quote and confirm. See the header.
            paid = _ceilDiv(_discounted(usd, NATIVE) * 1e18, bnbUsdPrice());
            if (msg.value < paid) revert InsufficientBNB(paid, msg.value);
            _routeNative(paid);
            // The surplus is NOT returned here — see the end of `_revive`.
        } else {
            // No `msg.value` guard needed on the BNBULL leg: its entrypoints
            // are not `payable`, so the dispatcher already rejects any value.
            if (!_bnbullPegUsable()) {
                if (bnbullPerUsd == 0) revert BnbullPathNotPriced();
                revert BnbullPegStale(bnbullPegUpdatedAt, maxBnbullPegAge);
            }
            // MEASURED: what we route is what actually arrived, not what we
            // asked for.
            paid = _pullMeasured(bnbull, _usdToBnbull(usd));
            _routeToken(PotSource.Bnbull, bnbull, paid);
        }
    }

    /**
     * @dev Pull a token payment and MEASURE what actually arrived, so what
     *      gets routed is what we really hold.
     *
     *      A shortfall REVERTS rather than quietly accepting a cheap life.
     *      ⚠ This is the guard that catches a stake asset with a transfer tax
     *      — BNBULL is launchpad-issued (`DECISIONS.md §4`), so "it has no fee
     *      on transfer" is a thing to VERIFY at deploy, not to assume. If it
     *      does, this leg refuses loudly instead of selling revives at a
     *      discount nobody chose.
     */
    function _pullMeasured(IERC20 token, uint256 amount) private returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
        if (received < amount) revert PaymentShortfall(address(token), amount, received);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Routing — 30% to the pots via MintDrop, the rest to dev
    // ══════════════════════════════════════════════════════════════════════

    function _routeNative(uint256 amount) private {
        uint256 potShare = (amount * potShareBps) / BPS;
        uint256 rest = amount - potShare;

        _toPotOrAccrue(PotSource.Native, potShare);

        uint256 lpShare = (rest * lpShareBps) / BPS;
        uint256 devShare = rest - lpShare;
        if (devShare > 0) {
            (bool ok,) = treasury.call{value: devShare}("");
            if (!ok) revert TreasuryTransferFailed();
        }
        if (lpShare > 0) {
            // ⚠ ACCRUES ON FAILURE — it does NOT revert the revive. Mirrors
            // `MintDrop._routeNative` and for the same reason: a splitter whose
            // `receive()` forwards back into the contract that paid it trips
            // that contract's own `nonReentrant` guard, and a revert here would
            // brick every native revive. A discretionary buyback leg must never
            // be able to stop a bull coming back from the dead. The money stays
            // here as `lpUndelivered` and the owner sweeps it.
            (bool ok,) = lpTreasury.call{value: lpShare}("");
            if (!ok) {
                lpUndelivered += lpShare;
                emit LpDeferred(lpShare, lpUndelivered);
            }
        }
    }

    function _routeToken(PotSource src, IERC20 token, uint256 amount) private {
        uint256 potShare = (amount * potShareBps) / BPS;
        uint256 rest = amount - potShare;

        _toPotOrAccrue(src, potShare);

        uint256 lpShare = (rest * lpShareBps) / BPS;
        uint256 devShare = rest - lpShare;
        if (devShare > 0) token.safeTransfer(treasury, devShare);
        if (lpShare > 0) token.safeTransfer(lpTreasury, lpShare);
    }

    /**
     * @dev THE never-fail leg. On fefers this call had no try/catch and a
     *      reverting MintDrop bricked every revive in the game. Here a failure
     *      is a deferral: the money stays here in a `pending*` bucket, the
     *      revive completes, and an event says which happened.
     */
    function _toPotOrAccrue(PotSource src, uint256 amount) private {
        if (amount == 0) return;
        address md = _wire(Wire.MintDrop);
        // Cheap pre-check so a pre-launch revive does not pay for a try/catch
        // that cannot possibly work. `code.length` matters: a payable call to
        // an EOA SUCCEEDS, so without it a mis-wired slot would silently send
        // the pot slice to a wallet instead of failing loudly into the bucket.
        if (md != address(0) && md.code.length > 0) {
            if (src == PotSource.Native) {
                try this.routePotNativeInline(md, amount) {
                    emit PotFundedInline(src, amount);
                    return;
                } catch {}
            } else {
                try this.routePotTokenInline(md, address(bnbull), amount) {
                    emit PotFundedInline(src, amount);
                    return;
                } catch {
                    // Deliberately catch-all: a paused MintDrop, a pot that has
                    // not whitelisted it yet, a thin pair, a router that
                    // reverts — every one of them means "not now", never "fail
                    // the revive".
                }
            }
        }
        uint256 total = _accrue(src, amount);
        emit PotDeferred(src, amount, total);
    }

    /**
     * @notice The inline native pot leg. `external` ONLY so this contract can
     *         try/catch its own call; `NotSelf` makes it unreachable to anyone
     *         else, so it is not a door into this contract's balance.
     * @dev Reverts freely — every revert is caught upstream and becomes an
     *      accrual.
     */
    function routePotNativeInline(address md, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        IMintDropDonate(md).donatePotNative{value: amount}();
    }

    /// @notice The inline token pot leg. See `routePotNativeInline`.
    function routePotTokenInline(address md, address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        IERC20(asset).forceApprove(md, amount);
        IMintDropDonate(md).donatePotToken(asset, amount);
        IERC20(asset).forceApprove(md, 0);
    }

    function _accrue(PotSource src, uint256 amount) private returns (uint256) {
        if (src == PotSource.Native) return pendingPotNative += amount;
        return pendingPotBnbull += amount;
    }

    function _bucket(PotSource src) private view returns (uint256) {
        return src == PotSource.Native ? pendingPotNative : pendingPotBnbull;
    }

    function _debit(PotSource src, uint256 amount) private {
        if (src == PotSource.Native) pendingPotNative -= amount;
        else pendingPotBnbull -= amount;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Sweeps — the deferred legs, retried
    // ══════════════════════════════════════════════════════════════════════

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeperOrOwner();
        _;
    }

    /**
     * @notice Retry a deferred pot leg once the route is healthy again.
     *
     *         This is the fallback drain, not the main path: money only lands
     *         in a bucket when the inline leg could not run. It stays because
     *         "the route was down for an hour" has to have an answer.
     *
     * @param amount Amount to route. 0 routes the whole bucket. Reverts here
     *               rather than deferring — a keeper wants to know it failed.
     */
    function sweepPending(PotSource src, uint256 amount)
        external
        nonReentrant
        onlyKeeperOrOwner
    {
        address md = _wire(Wire.MintDrop);
        if (md == address(0)) revert MintDropNotWired();

        uint256 available = _bucket(src);
        uint256 spend = amount == 0 ? available : amount;
        if (spend == 0) revert NothingToSweep();
        if (spend > available) revert InsufficientPending(spend, available);

        // Book the spend before the external call (CEI).
        _debit(src, spend);

        if (src == PotSource.Native) {
            this.routePotNativeInline(md, spend);
        } else {
            this.routePotTokenInline(md, address(bnbull), spend);
        }
        emit PotSwept(src, spend);
    }

    /**
     * @notice Escape hatch: pull a deferred leg OUT instead of routing it, for
     *         the case where MintDrop is gone for good and the dev wants to
     *         top the pots up by hand.
     *
     * @dev ⚠ TRUST BOUNDARY, STATED PLAINLY. Money in a `pending*` bucket has
     *      NOT entered a pot yet, so this hatch can move it. Money that has
     *      reached a `Jackpot` can never come out except through a won ticket
     *      — there is no owner path there, no "temporary" hatch, no
     *      pause-and-withdraw. The two guarantees are different and this emits
     *      its own event so the receipts trail says which is which.
     */
    function withdrawPending(PotSource src, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = _bucket(src);
        uint256 take = amount == 0 ? available : amount;
        if (take == 0) revert NothingToSweep();
        if (take > available) revert InsufficientPending(take, available);

        _debit(src, take);

        if (src == PotSource.Native) {
            (bool ok,) = to.call{value: take}("");
            if (!ok) revert TreasuryTransferFailed();
        } else {
            bnbull.safeTransfer(to, take);
        }
        emit PendingWithdrawn(src, to, take);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Replace BOTH ladders at once, so the two can never drift apart
     *         unnoticed. Every rung is bounded by `MAX_RESURRECTION_COST`.
     * @param owner_    Owner-ladder rungs in 1e18 dollars, index = lives spent.
     * @param takeover_ Takeover-ladder rungs, same indexing.
     *
     * @dev The takeover ladder SHOULD be dearer at every rung — the holder
     *      having the cheaper claim on their own fighter is the mechanic. That
     *      is not enforced on chain, because a promotional inversion is a
     *      legitimate (if odd) thing for an owner to want and a hard rule here
     *      would just be a redeploy waiting to happen. Both ladders are public
     *      and the change emits, so an inversion is visible.
     */
    function setLadders(uint256[] calldata owner_, uint256[] calldata takeover_)
        external
        onlyOwner
    {
        if (owner_.length == 0 || takeover_.length == 0) revert InvalidLadder();
        delete _ownerLadder;
        delete _takeoverLadder;
        for (uint256 i = 0; i < owner_.length; i++) {
            if (owner_[i] > MAX_RESURRECTION_COST) {
                revert CostTooHigh(owner_[i], MAX_RESURRECTION_COST);
            }
            _ownerLadder.push(owner_[i]);
        }
        for (uint256 i = 0; i < takeover_.length; i++) {
            if (takeover_[i] > MAX_RESURRECTION_COST) {
                revert CostTooHigh(takeover_[i], MAX_RESURRECTION_COST);
            }
            _takeoverLadder.push(takeover_[i]);
        }
        emit LaddersChanged(owner_, takeover_);
    }

    /**
     * @notice Retune the lifetime revive cap. THE setter fefers could not
     *         have: `MAX_RESURRECTS = 3` was a constant behind a one-time-set
     *         wiring slot, so the number was frozen for the life of the
     *         collection.
     * @dev ⚠ Lowering this below a bull's spent count makes that bull
     *      permanently gone. Deliberate, and the owner's call.
     */
    function setMaxResurrects(uint8 n) external onlyOwner {
        if (n == 0 || n > MAX_RESURRECTS_CEILING) {
            revert ValueOutOfRange(n, MAX_RESURRECTS_CEILING);
        }
        maxResurrects = n;
        emit MaxResurrectsChanged(n);
    }

    /// @notice Retune the holder's exclusive window. 0 opens takeovers the
    ///         instant a bull dies.
    function setOwnerPriorityWindow(uint256 secondsWindow) external onlyOwner {
        if (secondsWindow > MAX_OWNER_PRIORITY_WINDOW) {
            revert ValueOutOfRange(secondsWindow, MAX_OWNER_PRIORITY_WINDOW);
        }
        ownerPriorityWindow = secondsWindow;
        emit OwnerPriorityWindowChanged(secondsWindow);
    }

    /// @notice Retune the fee split. `potShareBps` is what MintDrop divides
    ///         2:1 between the pots.
    function setShares(uint256 _potShareBps, uint256 _lpShareBps) external onlyOwner {
        if (_potShareBps > MAX_POT_SHARE_BPS) revert InvalidShare(_potShareBps);
        if (_lpShareBps > BPS) revert InvalidShare(_lpShareBps);
        // ⚠ An LP share with nowhere to send it is not a no-op. On the native
        // path a `.call{value:}` to `address(0)` SUCCEEDS and burns the slice;
        // on the token path `safeTransfer` to zero reverts and bricks every
        // revive. Point the slot first, then open the share.
        if (_lpShareBps > 0 && lpTreasury == address(0)) revert ZeroAddress();
        potShareBps = _potShareBps;
        lpShareBps = _lpShareBps;
        emit SharesChanged(_potShareBps, _lpShareBps);
    }

    /// @notice Set the discount for a payment asset. `NATIVE` keys the BNB
    ///         leg. Generic on purpose (`DECISIONS.md §2`).
    function setDiscountBps(address asset, uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert InvalidShare(bps);
        discountBpsOf[asset] = bps;
        emit DiscountSet(asset, bps);
    }

    /// @notice The keeper's peg: BNBULL wei per ONE DOLLAR at the FULL
    ///         undiscounted sticker. Zero disables the BNBULL revive leg.
    function setBnbullPerUsd(uint256 perUsd) external onlyKeeperOrOwner {
        if (perUsd > MAX_BNBULL_PER_USD) revert PegTooHigh(perUsd, MAX_BNBULL_PER_USD);
        bnbullPerUsd = perUsd;
        bnbullPegUpdatedAt = uint64(block.timestamp);
        emit BnbullPegChanged(perUsd, bnbullPegUpdatedAt);
    }

    /// @notice How stale the BNBULL peg may be before that leg switches off.
    function setMaxBnbullPegAge(uint256 maxAge) external onlyOwner {
        if (maxAge == 0 || maxAge > MAX_BNBULL_PEG_AGE) {
            revert ValueOutOfRange(maxAge, MAX_BNBULL_PEG_AGE);
        }
        maxBnbullPegAge = maxAge;
        emit BnbullPegPolicyChanged(maxAge);
    }

    /**
     * @notice Oracle policy: how stale an answer may be, and the sanity band.
     * @param maxAge   Seconds. Non-zero and <= `MAX_ORACLE_AGE`.
     * @param minPrice 1e18-scaled floor. 0 disables.
     * @param maxPrice 1e18-scaled ceiling. 0 disables.
     */
    function setOraclePolicy(uint256 maxAge, uint256 minPrice, uint256 maxPrice)
        external
        onlyOwner
    {
        if (maxAge == 0 || maxAge > MAX_ORACLE_AGE) revert ValueOutOfRange(maxAge, MAX_ORACLE_AGE);
        if (minPrice != 0 && maxPrice != 0 && minPrice > maxPrice) revert OracleOutOfBand(minPrice);
        maxOracleAge = maxAge;
        minBnbUsd = minPrice;
        maxBnbUsd = maxPrice;
        emit OraclePolicyChanged(maxAge, minPrice, maxPrice);
    }

    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, next);
        treasury = next;
    }

    /// @notice Set the LP-slice recipient. Leave `lpShareBps` at zero unless
    ///         this points somewhere real.
    function setLpTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit LpTreasuryChanged(lpTreasury, next);
        lpTreasury = next;
    }

    /// @notice Sweep BNB whose LP transfer failed. Retries the LP slot when
    ///         `to` is zero, so a fixed splitter can be paid what it missed.
    function withdrawLpUndelivered(address to) external onlyOwner {
        uint256 amount = lpUndelivered;
        if (amount == 0) revert NothingUndelivered();
        lpUndelivered = 0;
        address dest = to == address(0) ? lpTreasury : to;
        (bool ok,) = dest.call{value: amount}("");
        if (!ok) revert TreasuryTransferFailed();
        emit LpUndeliveredWithdrawn(dest, amount);
    }

    function setKeeper(address next) external onlyOwner {
        emit KeeperChanged(keeper, next);
        keeper = next;
    }

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

    // ─── Admin: timelocked wiring ────────────────────────────────────────

    function bootstrapWire(Wire slot, address target) external onlyOwner {
        _wires[uint8(slot)].bootstrap(target);
        _afterWire(slot, target);
        emit WireBootstrapped(slot, target);
    }

    function proposeWire(Wire slot, address target) external onlyOwner returns (uint64 eta) {
        eta = _wires[uint8(slot)].propose(target, wiringDelay);
        emit WireProposed(slot, target, eta);
    }

    function commitWire(Wire slot) external onlyOwner {
        (address previous, address next) = _wires[uint8(slot)].commit();
        _afterWire(slot, next);
        emit WireCommitted(slot, previous, next);
    }

    function cancelWire(Wire slot) external onlyOwner {
        address dropped = _wires[uint8(slot)].cancel();
        emit WireCancelled(slot, dropped);
    }

    function wireOf(Wire slot)
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        TimelockedAddress.Slot storage s = _wires[uint8(slot)];
        return (s.current, s.pending, s.eta);
    }

    function setWiringDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_WIRING_DELAY || newDelay > MAX_WIRING_DELAY) {
            revert DelayOutOfRange(newDelay);
        }
        wiringDelay = newDelay;
        emit WiringDelayChanged(newDelay);
    }

    /**
     * @dev Cache the decimals of anything whose decimals we depend on.
     *
     *      ⚠ THIS IS THE DECIMALS TRAP, HANDLED. On Stable the same balance
     *      read as 18dp through `msg.value` and 6dp through the USDT0 ERC-20,
     *      and the mismatch rendered an $80 listing as $0.00 in production.
     *      Nothing is assumed: we read it, and a feed with no `decimals()`
     *      fails the wiring transaction rather than the first revive.
     *
     *      The BNBULL leg needs no decimals read here because `bnbullPerUsd` is
     *      a keeper peg denominated directly in BNBULL WEI per dollar — the
     *      token's own units — so its decimals never enter the arithmetic.
     */
    function _afterWire(Wire slot, address target) private {
        if (slot == Wire.PriceFeed) {
            uint8 d = AggregatorV3Interface(target).decimals();
            if (d > 36) revert FeedDecimalsUnusable(d);
            feedDecimals = d;
        }
    }

    function _wire(Wire slot) private view returns (address) {
        return _wires[uint8(slot)].current;
    }

    /**
     * @notice Recover a token sent here by mistake. Refuses to touch anything
     *         a deferred pot leg has already been credited with — that money
     *         is spoken for, and `withdrawPending` is the only door it may
     *         leave by.
     * @dev There is deliberately NO native rescue. Every BNB path routes or
     *      accrues to the wei and there is no `receive()`, so the only way
     *      loose BNB lands here is a forced `selfdestruct` transfer.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 reserved = token == address(bnbull) ? pendingPotBnbull : 0;
        uint256 free = bal > reserved ? bal - reserved : 0;
        if (amount > free) revert ReservedForPots(amount, free);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ─── Maths ───────────────────────────────────────────────────────────

    /// @dev Apply the per-asset discount. Applied EXACTLY ONCE, here.
    function _discounted(uint256 amount, address asset) private view returns (uint256) {
        uint16 bps = discountBpsOf[asset];
        if (bps == 0) return amount;
        return (amount * (BPS - bps)) / BPS;
    }

    /// @dev USD (1e18) -> BNBULL wei at the keeper's peg, discount applied.
    function _usdToBnbull(uint256 usd1e18) private view returns (uint256) {
        return _discounted(_ceilDiv(usd1e18 * bnbullPerUsd, 1e18), address(bnbull));
    }

    /// @dev Is the BNBULL leg priced AND fresh? A stale peg disables the leg
    ///      rather than charging last week's price.
    function _bnbullPegUsable() private view returns (bool) {
        if (bnbullPerUsd == 0) return false;
        return block.timestamp <= uint256(bnbullPegUpdatedAt) + maxBnbullPegAge;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
