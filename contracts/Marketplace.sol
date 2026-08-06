// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

/// @dev The one fragment of `Bulls` this contract needs beyond ERC-721. Declared
///      locally rather than importing `Bulls`, because the phase-2 instance of
///      this marketplace points at the calves collection, which is a different
///      type. `blocksDeadListings` switches the call off for a collection that
///      has no notion of death.
interface ICollectionDeadRead {
    function isDead(uint256 tokenId) external view returns (bool);
}

/**
 * @title Marketplace
 * @notice The in-game, approval-based secondary market for bnbulls. Sellers
 *         keep custody; the contract only ever moves an NFT at the moment of a
 *         sale. **92.5% of every sale reaches the seller. The 7.5% protocol fee
 *         splits 2.5% into the BNBULL jackpot and 5% to the treasury**, and the
 *         whole fee is hard-capped by a `constant` nobody can raise.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      RULE 1, APPLIED HERE: EVERY DIVISOR RE-DERIVED FROM SCRATCH
 *      ══════════════════════════════════════════════════════════════════════
 *      The Fighting Fefers marketplace stored `price` in **USDG smallest units
 *      (6 dp)** and called that "a plain dollar figure", because on Stable the
 *      gas token WAS USDT and 6 dp WAS the dollar. That rule leaked into the
 *      off-chain tooling and rendered an $80 listing as **$0.00** in
 *      production (80e6 read through an 18-dp lens is 8e-11).
 *
 *      Nothing of that survives here, and it is NOT enough to change the
 *      number 6 to the number 18. The whole *shape* is different:
 *
 *        - **The stored price is not a token amount at all.** `usdPrice` is a
 *          pure dollar figure scaled by 1e18 ($80 = 80e18), matching
 *          `MintDrop.PriceTier.usdPrice` so the entire codebase has exactly ONE
 *          price convention. It is not BNB and it is not BNBULL. There is
 *          therefore no "the marketplace is N-dp" rule to get wrong.
 *
 *        - **Every payable leg derives its own divisor at call time**, from a
 *          decimals value READ OFF CHAIN-STATE, never assumed:
 *
 *            BNB (native, 18 dp — a chain fact, not an assumption):
 *              bnbDue = ceil( usd1e18 * 1e18 / bnbUsd1e18 )
 *              e.g. $80 at $600/BNB -> 80e18 * 1e18 / 600e18 = 1.333e17 wei
 *                   = 0.1333 BNB.  ✔ $80 / $600 = 0.1333 BNB.
 *
 *            BNBULL (`bnbullDecimals` read from `decimals()` when wired — do
 *            NOT assume 18 just because BEP-20s usually are; the token is
 *            launchpad-issued, `DECISIONS.md §4`):
 *              bnbullDue = ceil( usd1e18 * 10**bnbullDecimals / bnbullUsd1e18 )
 *              e.g. $80 at $0.0005, d=18 -> 80e18 * 1e18 / 5e14 = 1.6e23 wei
 *                   = 160,000 BNBULL.  ✔ $80 / $0.0005 = 160,000.
 *              e.g. $80 at $0.0005, d=6  -> 80e18 * 1e6  / 5e14 = 1.6e11
 *                   = 160,000 BNBULL.  ✔ The SAME listing renders correctly
 *                   under either token, because the divisor is a function of
 *                   live state and not of folklore.
 *
 *          ⚠ `DECISIONS.md §26` dropped the stablecoin, and with it the 6-dp
 *          payment asset the fefers `$80 renders as $0.00` bug had to live in.
 *          It did NOT drop the rule. BNBULL is now the only wired ERC-20 whose
 *          decimals divide anything here — and it is the one nobody can check
 *          in advance, because four.meme issues it. The read stays.
 *
 *        - **Every conversion rounds UP** (`_ceilDiv`), so a rounding artefact
 *          can never shave a wei off the seller.
 *
 *        - **The fee is computed AFTER conversion, in the asset the buyer
 *          actually pays.** No cross-unit fee arithmetic exists, so there is
 *          no second place for a decimals mistake to hide.
 *
 *      Overflow, checked rather than hoped for: `usdPrice` is `uint128`
 *      (max ~3.4e38). The widest product below is `usdPrice * 10**decimals`
 *      with `decimals` bounded to 36 at wiring time -> 3.4e74, comfortably
 *      inside 1.15e77. `bnbullPrice` is likewise `uint128`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      RULE 2: BOUNDED SETTERS, NOT CONSTANTS
 *      ══════════════════════════════════════════════════════════════════════
 *      `constant` here is reserved for true security ceilings: `MAX_FEE_BPS`,
 *      `MAX_DISCOUNT_BPS`, `MAX_ORACLE_AGE`, `MAX_PEG_AGE` and the wiring
 *      timelock bounds. Everything a player feels — the fee, the discount, the
 *      oracle policy, the BNBULL peg staleness window — is an owner-settable
 *      variable inside one of those. Wiring that could redirect money (the
 *      price feed, BNBULL, the jackpot sink) is TIMELOCKED, never one-time-set:
 *      repointing BNBULL at a worthless token would let a buyer walk off with a
 *      bull for nothing, so it gets the full published delay.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE COLLECTION REFERENCE IS `immutable`, ON PURPOSE
 *      ══════════════════════════════════════════════════════════════════════
 *      It was immutable on fefers and it stays immutable here. A marketplace
 *      that can be repointed at another collection mid-life would strand every
 *      open listing against tokens it no longer refers to, and would hand a
 *      compromised owner key a way to make `buy` deliver the wrong asset.
 *
 *      **PHASE 2 THEREFORE DEPLOYS A SECOND INSTANCE** of this exact contract
 *      pointed at the calves collection (`BNBULLS-BOOTSTRAP.md §2`), sharing
 *      the treasury and folded into one /market page on the site. That second
 *      instance will want `blocksDeadListings = false` unless calves can die.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE DUEL LOCK-OUT
 *      ══════════════════════════════════════════════════════════════════════
 *      `isListed(tokenId)` is the clean view `Duel` reads to refuse a fight for
 *      a bull that is on sale. It never reverts and it never touches the
 *      oracle, so a stale feed can never block a fight. Selling a bull whose
 *      record could change between the buyer clicking and the tx landing is the
 *      thing being prevented; cancel the listing to fight again.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      APPROVAL-BASED, NOT ESCROW — AND WHAT THAT COSTS
 *      ══════════════════════════════════════════════════════════════════════
 *      The seller keeps the bull. If they transfer it or revoke approval the
 *      listing goes stale; `buy` refuses it and anyone may `sweep` it away. No
 *      NFT is ever locked in this contract and there is no admin path to move
 *      one. The trade-off is that a listing is a standing offer, not a
 *      guarantee — which is why `buy` re-checks ownership, approval and (for
 *      the bulls instance) liveness at settlement rather than trusting the
 *      listing record.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE DISCOUNT (`DECISIONS.md §2`) — FEE-FUNDED, NEVER SELLER-FUNDED
 *      ══════════════════════════════════════════════════════════════════════
 *      §2 says BNBULL and only BNBULL carries the discount, implemented as a
 *      generic `discountBpsOf` mapping under a `MAX_DISCOUNT_BPS` ceiling. On a
 *      MINT the discount is the protocol's to give. On a PEER-TO-PEER sale it
 *      is not: a naive discount would come out of the seller's pocket for a
 *      buyer's choice of currency the seller never agreed to.
 *
 *      So here the rebate is taken **out of the protocol fee and nowhere
 *      else**. The seller always receives exactly `price - grossFee`, whatever
 *      the buyer pays in; the buyer pays `price - rebate`; the protocol keeps
 *      `grossFee - rebate`. `MAX_DISCOUNT_BPS == MAX_FEE_BPS` and the rebate is
 *      clamped to the live fee, so the protocol's share can reach zero and can
 *      never go negative. **The launch value is 0 on every asset** — turning it
 *      on is a deliberate owner call to spend fee revenue on BNBULL volume.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE FEE HAS TWO LEGS: 2.5% JACKPOT / 5% DEV, SPLIT PRO-RATA
 *      ══════════════════════════════════════════════════════════════════════
 *      `feeBps` (750) is the whole protocol fee. `jackpotFeeBps` (250) is the
 *      slice of it that market-buys BNBULL into the no-withdraw BNBULL pot.
 *      **Both are expressed in bps OF THE SALE, not of the fee**, so they read
 *      the same way and are directly comparable; `jackpotFeeBps <= feeBps` is
 *      an enforced invariant in the constructor and in BOTH setters, because a
 *      jackpot leg larger than the fee would underflow the dev leg.
 *
 *      The split is taken **pro-rata off the fee actually collected**, never
 *      off gross:
 *
 *          potCut = fee * jackpotFeeBps / feeBps
 *          devCut = fee - potCut
 *
 *      That matters because the rebate shrinks `fee`; taking the jackpot leg
 *      off gross would let a large rebate drive `devCut` negative. Pro-rata
 *      shrinks both legs together and leaves `sellerProceeds = gross -
 *      grossFee` completely untouched. At launch, with the discount at zero,
 *      it is exactly 2.5% / 5% / 92.5%. The invariant, for every asset and
 *      every rounding path, is `buyerPays == sellerProceeds + potCut + devCut`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE JACKPOT LEG IS NEVER-FAIL. IT WILL FAIL ON DAY ONE.
 *      ══════════════════════════════════════════════════════════════════════
 *      The jackpot slice is handed to `Wire.JackpotSink` — a `PotSplitter`
 *      instance configured 100% BNBULL / 0% BNB — which market-buys BNBULL and
 *      locks it in the pot. **At launch BNBULL trades on four.meme's bonding
 *      curve and there is no PancakeSwap pair at all**, so that buy cannot
 *      run. That is the EXPECTED state, not an edge case.
 *
 *      A sale must never revert because of it. So the slice is pushed with a
 *      low-level call whose result is never trusted, the amount actually taken
 *      is a MEASURED BALANCE DELTA, and anything not taken **accrues** to
 *      `potFeeUndelivered` / `potFeeUndeliveredToken` and is swept later with
 *      `sweepPotFee` — the same accrue-and-carry-on shape as `lpUndelivered`
 *      in `MintDrop` and `Graveyard` (`DECISIONS.md §19`). With the sink
 *      unwired every slice simply accrues, so the marketplace can go live
 *      before the splitter exists.
 *
 *      A buyer paying IN BNBULL is never swapped (`DECISIONS.md §14`): the
 *      slice is handed over as tokens and lands straight in the pot.
 */
contract Marketplace is Ownable, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── True security ceilings (the only `constant`s here) ──────────────

    /// @notice Hard cap on the protocol fee. 1000 bps = 10%. The launch value
    ///         is 750 (7.5%, i.e. 92.5% to the seller); this ceiling is what
    ///         stops a compromised owner key from fee-ing a sale to zero.
    uint16 public constant MAX_FEE_BPS = 1_000;
    /// @notice Hard cap on any per-asset rebate. Equal to `MAX_FEE_BPS` by
    ///         construction: the rebate is funded from the fee, so it can never
    ///         be configured to eat into seller proceeds.
    uint16 public constant MAX_DISCOUNT_BPS = 1_000;
    /// @notice Ceiling on how stale a Chainlink answer may be and still price a
    ///         sale. The BSC BNB/USD feed heartbeats far faster than this.
    uint256 public constant MAX_ORACLE_AGE = 24 hours;
    /// @notice Ceiling on how stale the keeper's BNBULL/USD peg may be and
    ///         still price a sale. BNBULL is low-cap and swings hard
    ///         (`BNBULLS-BOOTSTRAP.md §4`); a week-old peg is not a price.
    uint256 public constant MAX_PEG_AGE = 7 days;
    /// @notice Wiring timelock bounds.
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;
    /// @notice Any wired token reporting more decimals than this is refused at
    ///         wiring time — it would put the conversion products near the
    ///         uint256 ceiling, and no real token needs it.
    uint8 public constant MAX_TOKEN_DECIMALS = 36;
    /// @notice Gas forwarded to a native payout. Generous for any ordinary
    ///         wallet, multisig or proxy, and small enough that a seller with a
    ///         deliberately expensive receiver cannot burn the buyer's gas to
    ///         grief the sale — that seller is paid by credit instead.
    uint256 private constant NATIVE_PAY_GAS = 60_000;

    uint256 private constant BPS = 10_000;
    /// @notice Sentinel keying native BNB in `discountBpsOf`. Matches
    ///         `MintDrop.NATIVE`.
    address public constant NATIVE = address(0);

    // ─── Immutable ref (see the header — deliberately not re-settable) ───

    /// @notice The ERC-721 this instance trades. Bulls on instance one; the
    ///         calves collection on the phase-2 instance.
    IERC721 public immutable collection;

    // ─── Timelocked wiring ───────────────────────────────────────────────

    /// ⚠ RENUMBERED BY `DECISIONS.md §26`. `Stablecoin` was slot 0 and every
    ///   member has shifted DOWN by one. The hole was not kept reserved;
    ///   nothing is deployed yet and a reserved slot preserves exactly the
    ///   thing the decision deletes.
    enum Wire {
        /// Chainlink BNB/USD (0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE).
        PriceFeed,
        /// The BNBULL token. ⚠ Wiring reads `decimals()`; nothing here assumes
        /// 18 just because BEP-20s usually are.
        Bnbull,
        /// The `PotSplitter` that turns the jackpot slice of the fee into
        /// locked BNBULL. Timelocked like every other money-redirecting slot:
        /// repointing it at an address the owner controls would quietly
        /// convert the jackpot leg into a second dev cut. Zero is a valid
        /// launch state — the slice accrues until the splitter exists.
        JackpotSink
    }

    mapping(uint8 => TimelockedAddress.Slot) private _wires;

    /// @notice Delay a wiring change must age before it can be committed.
    uint256 public wiringDelay = 24 hours;

    /// @notice `decimals()` read off the wired price feed (8 for BNB/USD).
    uint8 public feedDecimals;
    /// @notice `decimals()` read off the wired BNBULL token. NEVER assumed.
    uint8 public bnbullDecimals;

    // ─── Fee + rebate ────────────────────────────────────────────────────

    /// @notice The WHOLE protocol fee in basis points. Launch: 750 (7.5%),
    ///         i.e. 92.5% seller.
    uint16 public feeBps = 750;
    /// @notice The slice of the sale — NOT of the fee — that market-buys BNBULL
    ///         into the jackpot. Launch: 250 (2.5%), leaving 5% for the
    ///         treasury. Invariant: `jackpotFeeBps <= feeBps`.
    uint16 public jackpotFeeBps = 250;
    /// @notice Where the dev leg of the protocol fee lands.
    address public feeTreasury;
    /// @notice Jackpot slices that could not be handed to the sink, in native
    ///         BNB. Swept with `sweepPotFee(NATIVE, …)`.
    uint256 public potFeeUndelivered;
    /// @notice The same, per ERC-20. Swept with `sweepPotFee(token, …)`.
    mapping(address => uint256) public potFeeUndeliveredToken;
    /// @notice Per-asset buyer rebate, funded out of the fee (see the header).
    ///         `NATIVE` keys the BNB leg. Launch value 0 on every asset.
    mapping(address => uint16) public discountBpsOf;

    // ─── Oracle policy (mirrors MintDrop so both price the same way) ─────

    uint256 public maxOracleAge = 1 hours;
    /// @notice Optional 1e18-scaled sanity band on BNB/USD. Zero disables a
    ///         side. A feed pinned at a circuit-breaker floor would otherwise
    ///         sell every listed bull for dust.
    uint256 public minBnbUsd;
    uint256 public maxBnbUsd;

    // ─── The BNBULL peg (keeper-maintained; there is no BNBULL/USD feed) ─

    /// @notice BNBULL/USD, 1e18-scaled, published by the price-keeper exactly
    ///         as `fight-price-keeper.mjs` pegged the fefers BNBULL legs
    ///         (`DECISIONS.md §2`). Zero means "not pegged", which disables
    ///         every `Pegged` listing's BNBULL leg rather than guessing.
    uint256 public bnbullUsd1e18;
    /// @notice When `bnbullUsd1e18` was last written.
    uint64 public bnbullUsdUpdatedAt;
    /// @notice How stale that peg may be and still settle a sale. A stale peg
    ///         is dangerous in exactly one direction — if BNBULL fell and the
    ///         peg has not caught up, a buyer takes the bull for too few
    ///         tokens — so past this age the BNBULL leg is refused outright.
    uint256 public maxBnbullPegAge = 1 hours;

    /// @notice May refresh the BNBULL peg alongside the owner.
    address public keeper;

    // ─── Listing policy ──────────────────────────────────────────────────

    /// @notice Refuse to list, and refuse to sell, a dead bull. Buyers should
    ///         not discover post-purchase that they bought a corpse.
    ///         ⚠ Set FALSE on the phase-2 calves instance if that collection
    ///         does not implement `isDead(uint256)` — with it true, `list`
    ///         reverts on every token there.
    bool public blocksDeadListings = true;

    // ─── Listings ────────────────────────────────────────────────────────

    /// @notice How this listing prices its BNBULL leg.
    enum BnbullMode {
        /// BNBULL is not accepted for this listing. The default.
        Off,
        /// Derived from `usdPrice` through the keeper's BNBULL/USD peg. Needs a
        /// fresh peg at buy time or the leg is refused.
        Pegged,
        /// An exact BNBULL amount the seller named. Never touches the peg, so
        /// it cannot be mispriced by a keeper outage — the seller carries the
        /// drift instead.
        Fixed
    }

    struct Listing {
        // ── slot 0 ──
        address seller; // 20 bytes; zero means "not listed"
        uint64 listedAt; //  8
        BnbullMode bnbullMode; //  1
        // ── slot 1 ──
        /// @dev The dollar sticker, 1e18-scaled. NOT a token amount.
        uint128 usdPrice;
        /// @dev BNBULL wei, meaningful only in `Fixed` mode.
        uint128 bnbullPrice;
    }

    mapping(uint256 => Listing) private _listings;

    /// @notice Which currency a buyer settled in.
    /// @dev ⚠ RENUMBERED BY `DECISIONS.md §26`: `Stable` was 1 and `Bnbull` has
    ///      moved 2 -> 1. This value rides in the `Sold` event, so an indexer
    ///      keyed on the old codes reads every BNBULL sale as a stablecoin one.
    enum PayKind {
        BNB,
        Bnbull
    }

    /// @notice Native owed to an address whose direct payout could not be
    ///         delivered. Pull it with `withdrawCredit`. This exists so a
    ///         seller with an awkward receiver cannot make their own listing
    ///         unbuyable, and cannot grief a buyer's gas.
    mapping(address => uint256) public nativeCredit;

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    event Listed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 usdPrice1e18,
        BnbullMode bnbullMode,
        uint256 bnbullPrice
    );
    event PriceUpdated(
        uint256 indexed tokenId,
        uint256 oldUsdPrice1e18,
        uint256 newUsdPrice1e18,
        BnbullMode bnbullMode,
        uint256 bnbullPrice
    );
    event Unlisted(uint256 indexed tokenId, address indexed seller);
    /// @param asset The token paid in, or `NATIVE` for BNB.
    /// @param paid  What the buyer actually parted with, in `asset` units.
    /// @param fee   The WHOLE protocol fee after any rebate, in `asset` units —
    ///              the jackpot leg plus the dev leg. `PotFeeRouted` /
    ///              `PotFeeDeferred` say what became of the jackpot half.
    /// @dev The seller's proceeds are `paid - fee` exactly, for every asset and
    ///      every rebate setting — see `_split`. Not emitted separately because
    ///      a derived field that can drift from its source is a bug waiting to
    ///      be indexed.
    event Sold(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        PayKind kind,
        address asset,
        uint256 usdPrice1e18,
        uint256 paid,
        uint256 fee
    );
    event NativeCredited(address indexed to, uint256 amount);
    event CreditWithdrawn(address indexed to, uint256 amount);
    /// @notice The jackpot slice reached the sink inside the buyer's own tx.
    event PotFeeRouted(address indexed asset, address indexed sink, uint256 amount);
    /// @notice It did not, so it accrued. The expected launch-day event, since
    ///         BNBULL has no PancakeSwap pair until it graduates the curve.
    event PotFeeDeferred(address indexed asset, uint256 amount, uint256 bucketTotal);
    event PotFeeSwept(address indexed asset, address indexed to, uint256 amount);
    event FeeChanged(uint16 previous, uint16 next);
    event JackpotFeeChanged(uint16 previous, uint16 next);
    event DiscountSet(address indexed asset, uint16 bps);
    event TreasuryChanged(address indexed previous, address indexed next);
    event KeeperChanged(address indexed previous, address indexed next);
    event OraclePolicyChanged(uint256 maxAge, uint256 minPrice, uint256 maxPrice);
    event BnbullPegUpdated(uint256 price1e18, uint64 at);
    event BnbullPegPolicyChanged(uint256 maxAge);
    event DeadListingPolicyChanged(bool blocks);
    event WireBootstrapped(Wire indexed slot, address indexed target);
    event WireProposed(Wire indexed slot, address indexed target, uint64 eta);
    event WireCommitted(Wire indexed slot, address indexed previous, address indexed next);
    event WireCancelled(Wire indexed slot, address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event SocialsChanged(string website, string twitter, string telegram);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroPrice();
    error NotListed();
    error AlreadyListed();
    error NotSeller();
    error NotTokenOwner();
    error NotApproved();
    error NotStale();
    error BullIsDead(uint256 tokenId);
    error FeeTooHigh(uint16 requested);
    /// @dev `jackpotFeeBps > feeBps`. Raised by the constructor, by
    ///      `setJackpotFeeBps` and — crucially — by `setFee` when lowering the
    ///      whole fee under the jackpot leg, which would underflow the dev leg.
    error JackpotFeeTooHigh(uint16 jackpotBps, uint16 feeBps_);
    error DiscountTooHigh(uint16 requested);
    /// @dev A rescue would dip into a jackpot slice that is already accrued.
    error ReservedForPot(uint256 requested, uint256 free);
    error InvalidBnbullMode();
    error BnbullNotAccepted(uint256 tokenId);
    error BnbullNotWired();
    error BnbullPegUnavailable(uint256 price1e18, uint64 updatedAt);
    error InsufficientBNB(uint256 required, uint256 sent);
    error PaymentShortfall(uint256 expected, uint256 received);
    error NothingToWithdraw();
    error CreditWithdrawFailed();
    error DelayOutOfRange(uint256 requested);
    error NotKeeperOrOwner();
    error BadOraclePolicy(uint256 value);
    error OracleNotWired();
    error OracleBadAnswer(int256 answer);
    error OracleBadRound(uint80 roundId, uint80 answeredInRound, uint256 updatedAt);
    error OracleStale(uint256 updatedAt, uint256 maxAge);
    error OracleOutOfBand(uint256 price1e18);
    error TokenDecimalsUnusable(uint8 decimals_);
    error DirectNativeNotAccepted();

    // ─── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _collection   The ERC-721 traded here. IMMUTABLE — see the header;
     *                      phase 2 deploys a second instance for calves.
     * @param _feeTreasury  Where the protocol fee lands.
     * @param _feeBps       Launch fee. 750 = 7.5% (92.5% to the seller), of
     *                      which `jackpotFeeBps` (250 = 2.5% of the sale) buys
     *                      BNBULL for the pot and the rest is the dev leg.
     * @param initialOwner  A zero here is caught by Ownable's own constructor,
     *                      which runs before this body.
     *
     * @dev The `jackpotFeeBps <= feeBps` invariant is enforced HERE too, not
     *      only in the setters: state initialisers run before this body, so
     *      `jackpotFeeBps` already holds its launch value and a `_feeBps` below
     *      it would deploy a contract whose first sale underflows the dev leg.
     */
    constructor(
        address _collection,
        address _feeTreasury,
        uint16 _feeBps,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_collection == address(0) || _feeTreasury == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh(_feeBps);
        if (jackpotFeeBps > _feeBps) revert JackpotFeeTooHigh(jackpotFeeBps, _feeBps);
        collection = IERC721(_collection);
        feeTreasury = _feeTreasury;
        feeBps = _feeBps;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════════════════════════════

    function listingOf(uint256 tokenId) external view returns (Listing memory) {
        return _listings[tokenId];
    }

    /**
     * @notice THE DUEL LOCK-OUT VIEW. True while `tokenId` is on sale here.
     *         `Duel` reads this and refuses a fight for a listed bull.
     * @dev Deliberately trivial: one storage read, no oracle, no external call,
     *      cannot revert. A fight must never fail because of a market fault.
     */
    function isListed(uint256 tokenId) public view returns (bool) {
        return _listings[tokenId].seller != address(0);
    }

    /// @notice True if this contract may move `tokenId` for `owner_`.
    function isApprovedForMarketplace(uint256 tokenId, address owner_)
        public
        view
        returns (bool)
    {
        return collection.getApproved(tokenId) == address(this)
            || collection.isApprovedForAll(owner_, address(this));
    }

    /// @notice True if the listing can no longer settle: the seller moved the
    ///         token, revoked approval, or (bulls instance) the bull died.
    ///         Anyone may `sweep` such a listing away.
    function isStale(uint256 tokenId) public view returns (bool) {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) return false;
        if (collection.ownerOf(tokenId) != l.seller) return true;
        if (!isApprovedForMarketplace(tokenId, l.seller)) return true;
        return blocksDeadListings && ICollectionDeadRead(address(collection)).isDead(tokenId);
    }

    /**
     * @notice What `tokenId` costs right now in each currency, in that
     *         currency's own units, AFTER any rebate — i.e. exactly what the
     *         matching `buyWith…` will take.
     *
     * @dev Unlike `MintDrop.quote` this NEVER reverts: a marketplace grid
     *      renders hundreds of listings at once and one stale feed must not
     *      blank the page. **A zero return means "this leg is unavailable"**
     *      (unwired asset, stale oracle, unpegged or stale BNBULL, or the
     *      seller declined BNBULL) — a real amount is never zero, because every
     *      conversion rounds up from a non-zero price.
     */
    function quote(uint256 tokenId)
        external
        view
        returns (
            uint256 usdPrice1e18,
            uint256 bnbDue,
            uint256 bnbullDue,
            uint256 bnbUsd1e18
        )
    {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) return (0, 0, 0, 0);
        usdPrice1e18 = l.usdPrice;

        try this.bnbUsdPrice() returns (uint256 p) {
            bnbUsd1e18 = p;
            bnbDue = _afterRebate(_ceilDiv(usdPrice1e18 * 1e18, p), NATIVE);
        } catch {
            // Leave both at zero: "the BNB leg cannot be priced right now".
        }

        address bull = _wire(Wire.Bnbull);
        if (bull != address(0)) {
            if (l.bnbullMode == BnbullMode.Fixed) {
                bnbullDue = _afterRebate(l.bnbullPrice, bull);
            } else if (l.bnbullMode == BnbullMode.Pegged && _bnbullPegFresh()) {
                bnbullDue = _afterRebate(
                    _ceilDiv(usdPrice1e18 * (10 ** bnbullDecimals), bnbullUsd1e18), bull
                );
            }
        }
    }

    /// @notice Every live PAYMENT wiring address in one call, for the preflight
    ///         and the keepers. `wireOf` adds the pending target and its ETA.
    /// @dev `Wire.JackpotSink` is deliberately NOT here: it has its own getter,
    ///      so adding it did not break the preflight's destructuring.
    function wires() external view returns (address priceFeed, address bnbull) {
        return (_wire(Wire.PriceFeed), _wire(Wire.Bnbull));
    }

    /// @notice The `PotSplitter` the jackpot slice of the fee is pushed to.
    ///         Zero means "not wired yet"; the slice accrues instead.
    function jackpotSink() external view returns (address) {
        return _wire(Wire.JackpotSink);
    }

    function wireOf(Wire slot)
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        TimelockedAddress.Slot storage s = _wires[uint8(slot)];
        return (s.current, s.pending, s.eta);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The oracle — `DECISIONS.md §1`, option A. Same policy as MintDrop.
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice BNB/USD, normalised to 1e18.
     * @dev REVERTS rather than clamping on a non-positive answer, an incomplete
     *      round, a zero timestamp, an answer older than `maxOracleAge`, or a
     *      price outside the sanity band. Refusing to sell is always safe here;
     *      nothing upstream of this contract can be bricked by a revert.
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
        price1e18 = d <= 18
            ? uint256(answer) * (10 ** (18 - d))
            : uint256(answer) / (10 ** (d - 18));
        if (price1e18 == 0) revert OracleBadAnswer(answer);
        if (minBnbUsd != 0 && price1e18 < minBnbUsd) revert OracleOutOfBand(price1e18);
        if (maxBnbUsd != 0 && price1e18 > maxBnbUsd) revert OracleOutOfBand(price1e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Seller actions
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice List `tokenId` at `usdPrice1e18` dollars ($80 = 80e18). The
     *         caller must own it and must already have approved this contract
     *         (per-token `approve` or blanket `setApprovalForAll`).
     *
     *         The dollar sticker prices the BNB leg automatically. The BNBULL
     *         leg is opt-in:
     *           `Off`    — BNBULL not accepted.
     *           `Pegged` — derived from the sticker via the keeper's BNBULL/USD
     *                      peg; refused at buy time if that peg is stale.
     *           `Fixed`  — `bnbullPrice` exactly, in BNBULL wei. No peg, no
     *                      keeper dependency; the seller carries the drift.
     *
     * @dev `nonReentrant`: without it a seller could re-enter `list` from a
     *      payout callback during someone else's `buy` and leave a stale,
     *      sweepable listing behind.
     */
    function list(
        uint256 tokenId,
        uint128 usdPrice1e18,
        BnbullMode bnbullMode,
        uint128 bnbullPrice
    ) external whenNotPaused nonReentrant {
        if (usdPrice1e18 == 0) revert ZeroPrice();
        _validateBnbullTerms(bnbullMode, bnbullPrice);
        if (collection.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!isApprovedForMarketplace(tokenId, msg.sender)) revert NotApproved();
        if (_listings[tokenId].seller != address(0)) revert AlreadyListed();
        if (blocksDeadListings && ICollectionDeadRead(address(collection)).isDead(tokenId)) {
            revert BullIsDead(tokenId);
        }

        _listings[tokenId] = Listing({
            seller: msg.sender,
            listedAt: uint64(block.timestamp),
            bnbullMode: bnbullMode,
            usdPrice: usdPrice1e18,
            bnbullPrice: bnbullPrice
        });
        emit Listed(tokenId, msg.sender, usdPrice1e18, bnbullMode, bnbullPrice);
    }

    /// @notice Re-price an existing listing, and/or change its BNBULL terms.
    function updatePrice(
        uint256 tokenId,
        uint128 usdPrice1e18,
        BnbullMode bnbullMode,
        uint128 bnbullPrice
    ) external whenNotPaused {
        if (usdPrice1e18 == 0) revert ZeroPrice();
        _validateBnbullTerms(bnbullMode, bnbullPrice);
        Listing storage l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();

        uint256 old = l.usdPrice;
        l.usdPrice = usdPrice1e18;
        l.bnbullMode = bnbullMode;
        l.bnbullPrice = bnbullPrice;
        emit PriceUpdated(tokenId, old, usdPrice1e18, bnbullMode, bnbullPrice);
    }

    /// @notice Cancel a listing. Deliberately NOT `whenNotPaused` — a seller
    ///         must always be able to leave, even during an emergency freeze.
    function cancel(uint256 tokenId) external {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        delete _listings[tokenId];
        emit Unlisted(tokenId, msg.sender);
    }

    /// @notice Anyone may clear a listing that can no longer settle (the seller
    ///         moved the token, revoked approval, or the bull died). Reverts if
    ///         the listing is still good — only the seller may `cancel` those.
    function sweep(uint256 tokenId) external {
        if (_listings[tokenId].seller == address(0)) revert NotListed();
        if (!isStale(tokenId)) revert NotStale();
        address seller = _listings[tokenId].seller;
        delete _listings[tokenId];
        emit Unlisted(tokenId, seller);
    }

    function _validateBnbullTerms(BnbullMode mode, uint128 bnbullPrice) private pure {
        if (mode == BnbullMode.Fixed) {
            if (bnbullPrice == 0) revert ZeroPrice();
        } else if (bnbullPrice != 0) {
            // A non-zero BNBULL price with a mode that ignores it is almost
            // always a mistake by a caller who thinks it will be honoured.
            revert InvalidBnbullMode();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Buy
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Buy `tokenId` with BNB.
     *
     * @dev Send at least `quote(tokenId).bnbDue` — the surplus comes straight
     *      back. `>=` rather than `==` is `DECISIONS.md §1`, not sloppiness:
     *      the dollar sticker converts through the oracle at PAY time, so the
     *      exact wei due moves between the wallet quoting and the tx landing.
     *      Fefers could demand an exact `msg.value` only because on Stable the
     *      native token WAS the dollar and the price never moved.
     */
    function buyWithBNB(uint256 tokenId) external payable whenNotPaused nonReentrant {
        Listing memory l = _takeListingForSale(tokenId);

        uint256 gross = _ceilDiv(uint256(l.usdPrice) * 1e18, bnbUsdPrice());
        (uint256 buyerPays, uint256 sellerProceeds, uint256 fee) = _split(gross, NATIVE);
        if (msg.value < buyerPays) revert InsufficientBNB(buyerPays, msg.value);

        collection.safeTransferFrom(l.seller, msg.sender, tokenId);

        _payNative(l.seller, sellerProceeds);
        if (fee > 0) {
            (uint256 potCut, uint256 devCut) = _feeLegs(fee);
            _payNative(feeTreasury, devCut);
            _payPotCutNative(potCut);
        }
        _payNative(msg.sender, msg.value - buyerPays);

        _emitSold(tokenId, l.seller, PayKind.BNB, NATIVE, l.usdPrice, buyerPays, fee);
    }

    /// @notice Buy `tokenId` with BNBULL. Only listings whose seller opted in
    ///         (`Pegged` or `Fixed`) accept it. Approve
    ///         `quote(tokenId).bnbullDue` first.
    function buyWithBNBULL(uint256 tokenId) external whenNotPaused nonReentrant {
        address bull = _wire(Wire.Bnbull);
        if (bull == address(0)) revert BnbullNotWired();
        Listing memory l = _takeListingForSale(tokenId);

        uint256 gross;
        if (l.bnbullMode == BnbullMode.Fixed) {
            gross = l.bnbullPrice;
        } else if (l.bnbullMode == BnbullMode.Pegged) {
            // A stale or absent peg REFUSES the sale. It never falls back to a
            // guess: the failure mode of an out-of-date peg is a bull sold for
            // too few tokens, and that is not recoverable.
            if (!_bnbullPegFresh()) {
                revert BnbullPegUnavailable(bnbullUsd1e18, bnbullUsdUpdatedAt);
            }
            gross = _ceilDiv(uint256(l.usdPrice) * (10 ** bnbullDecimals), bnbullUsd1e18);
        } else {
            revert BnbullNotAccepted(tokenId);
        }

        _settleToken(tokenId, l, PayKind.Bnbull, IERC20(bull), gross);
    }

    /**
     * @dev Re-validate a listing at settlement and clear it (CEI: the listing
     *      is gone before any external call, so a re-entrant buy finds nothing
     *      to double-spend, belt to `nonReentrant`'s braces).
     */
    function _takeListingForSale(uint256 tokenId) private returns (Listing memory l) {
        l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        // The listing is a standing offer, not a guarantee — re-check the world
        // rather than trusting the record. A stale listing stays in storage
        // until someone calls `sweep`.
        if (collection.ownerOf(tokenId) != l.seller) revert NotTokenOwner();
        if (!isApprovedForMarketplace(tokenId, l.seller)) revert NotApproved();
        if (blocksDeadListings && ICollectionDeadRead(address(collection)).isDead(tokenId)) {
            revert BullIsDead(tokenId);
        }
        delete _listings[tokenId];
    }

    /// @dev The shared ERC-20 settlement leg. Pull, move the bull, pay out.
    function _settleToken(
        uint256 tokenId,
        Listing memory l,
        PayKind kind,
        IERC20 token,
        uint256 gross
    ) private {
        (uint256 buyerPays, uint256 sellerProceeds, uint256 fee) = _split(gross, address(token));

        // MEASURED pull, scoped so the measurement locals die immediately. A
        // fee-on-transfer payment token would silently shortchange the seller,
        // so the delta must be exact and a shortfall refuses the sale outright.
        {
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), buyerPays);
            uint256 received = token.balanceOf(address(this)) - before;
            if (received < buyerPays) revert PaymentShortfall(buyerPays, received);
        }

        collection.safeTransferFrom(l.seller, msg.sender, tokenId);

        if (sellerProceeds > 0) token.safeTransfer(l.seller, sellerProceeds);
        if (fee > 0) {
            (uint256 potCut, uint256 devCut) = _feeLegs(fee);
            if (devCut > 0) token.safeTransfer(feeTreasury, devCut);
            _payPotCutToken(token, potCut);
        }

        _emitSold(tokenId, l.seller, kind, address(token), l.usdPrice, buyerPays, fee);
    }

    /// @dev Broken out so the settlement bodies above stay inside the EVM's
    ///      16-slot stack window. Purely mechanical; no logic lives here.
    function _emitSold(
        uint256 tokenId,
        address seller,
        PayKind kind,
        address asset,
        uint256 usdPrice1e18,
        uint256 paid,
        uint256 fee
    ) private {
        emit Sold(tokenId, seller, msg.sender, kind, asset, usdPrice1e18, paid, fee);
    }

    /**
     * @dev The 95/5 split, plus the fee-funded rebate.
     *
     *      seller  = gross - grossFee            (invariant: never touched by
     *                                             the rebate)
     *      rebate  = min(gross * discount, grossFee)
     *      buyer   = gross - rebate
     *      fee     = grossFee - rebate
     *
     *      so buyer == seller + fee, exactly, for every input. The clamp is
     *      what guarantees the fee cannot go negative even if a future owner
     *      sets the discount above the fee.
     */
    function _split(uint256 gross, address asset)
        private
        view
        returns (uint256 buyerPays, uint256 sellerProceeds, uint256 fee)
    {
        uint256 grossFee = (gross * feeBps) / BPS;
        sellerProceeds = gross - grossFee;
        uint256 rebate = (gross * discountBpsOf[asset]) / BPS;
        if (rebate > grossFee) rebate = grossFee;
        buyerPays = gross - rebate;
        fee = grossFee - rebate;
    }

    /**
     * @dev Divide the fee actually collected into its jackpot and dev legs,
     *      PRO-RATA off `fee` rather than off gross.
     *
     *      Off gross, a rebate that shrank `fee` below the jackpot slice would
     *      underflow `devCut`; pro-rata shrinks both legs together and leaves
     *      `sellerProceeds` alone. `potCut <= fee` holds because
     *      `jackpotFeeBps <= feeBps` is enforced everywhere `feeBps` or
     *      `jackpotFeeBps` can change, so `devCut` cannot underflow.
     */
    function _feeLegs(uint256 fee) private view returns (uint256 potCut, uint256 devCut) {
        uint16 f = feeBps;
        potCut = f == 0 ? 0 : (fee * jackpotFeeBps) / f;
        devCut = fee - potCut;
    }

    /**
     * @dev Hand the native jackpot slice to the sink, or accrue it.
     *
     *      ⚠ NEVER REVERTS. The sink's `receive()` market-buys BNBULL, and at
     *      launch there is no pool to buy from — so this failing is the
     *      EXPECTED case, and a sale may not fail with it. The call result is
     *      only ever used to decide "routed or accrued".
     */
    function _payPotCutNative(uint256 amount) private {
        if (amount == 0) return;
        address sink = _wire(Wire.JackpotSink);
        if (sink != address(0)) {
            (bool ok,) = sink.call{value: amount}("");
            if (ok) {
                emit PotFeeRouted(NATIVE, sink, amount);
                return;
            }
        }
        potFeeUndelivered += amount;
        emit PotFeeDeferred(NATIVE, amount, potFeeUndelivered);
    }

    /**
     * @dev The ERC-20 version. Approve, push, then book what the sink ACTUALLY
     *      took as a MEASURED BALANCE DELTA — `PotSplitter.donatePotToken`
     *      returns normally even when its own pull fails (it emits
     *      `PullFailed` instead of reverting), so a successful call is not
     *      evidence that anything moved. Whatever did not move accrues.
     *
     *      ⚠ NEVER REVERTS, for the same reason as the native leg.
     */
    function _payPotCutToken(IERC20 token, uint256 amount) private {
        if (amount == 0) return;
        address sink = _wire(Wire.JackpotSink);
        uint256 taken;
        if (sink != address(0)) {
            uint256 before = token.balanceOf(address(this));
            token.forceApprove(sink, amount);
            (bool ok,) = sink.call(
                abi.encodeWithSignature("donatePotToken(address,uint256)", address(token), amount)
            );
            token.forceApprove(sink, 0);
            uint256 held = token.balanceOf(address(this));
            if (ok && before > held) taken = before - held;
            if (taken > 0) emit PotFeeRouted(address(token), sink, taken);
        }
        if (taken < amount) {
            uint256 shortfall = amount - taken;
            uint256 bucket = potFeeUndeliveredToken[address(token)] + shortfall;
            potFeeUndeliveredToken[address(token)] = bucket;
            emit PotFeeDeferred(address(token), shortfall, bucket);
        }
    }

    /**
     * @notice Sweep an accrued jackpot slice. `to == address(0)` retries the
     *         wired sink, so a backlog built up before the BNBULL pool existed
     *         can be re-bought rather than only withdrawn.
     * @dev For a token, retrying means a plain transfer to the splitter; the
     *      keeper then puts it through `PotSplitter.routeHeld`.
     */
    function sweepPotFee(address asset, address to) external onlyOwner nonReentrant {
        address dest = to == address(0) ? _wire(Wire.JackpotSink) : to;
        if (dest == address(0)) revert ZeroAddress();

        uint256 amount;
        if (asset == NATIVE) {
            amount = potFeeUndelivered;
            if (amount == 0) revert NothingToWithdraw();
            potFeeUndelivered = 0;
            (bool ok,) = dest.call{value: amount}("");
            if (!ok) revert CreditWithdrawFailed();
        } else {
            amount = potFeeUndeliveredToken[asset];
            if (amount == 0) revert NothingToWithdraw();
            potFeeUndeliveredToken[asset] = 0;
            IERC20(asset).safeTransfer(dest, amount);
        }
        emit PotFeeSwept(asset, dest, amount);
    }

    /// @dev Push native, or credit it for later pull if the push fails. Never
    ///      reverts, so no receiver can block a sale or burn the buyer's gas.
    function _payNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: NATIVE_PAY_GAS}("");
        if (!ok) {
            nativeCredit[to] += amount;
            emit NativeCredited(to, amount);
        }
    }

    /// @notice Collect native owed to you from a payout that could not be
    ///         delivered directly.
    function withdrawCredit() external nonReentrant {
        uint256 amount = nativeCredit[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        nativeCredit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert CreditWithdrawFailed();
        emit CreditWithdrawn(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════════

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeperOrOwner();
        _;
    }

    /// @notice Retune the WHOLE protocol fee. ⚠ Lowering it below
    ///         `jackpotFeeBps` REVERTS rather than silently inverting the two
    ///         legs — that is the direction the invariant is easy to break in.
    function setFee(uint16 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh(_feeBps);
        if (jackpotFeeBps > _feeBps) revert JackpotFeeTooHigh(jackpotFeeBps, _feeBps);
        emit FeeChanged(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    /// @notice Retune the jackpot leg, in bps OF THE SALE. Bounded by the live
    ///         `feeBps`, so it can never exceed the fee it is carved out of.
    function setJackpotFeeBps(uint16 bps) external onlyOwner {
        uint16 f = feeBps;
        if (bps > f) revert JackpotFeeTooHigh(bps, f);
        emit JackpotFeeChanged(jackpotFeeBps, bps);
        jackpotFeeBps = bps;
    }

    /// @notice Set the fee-funded buyer rebate for a payment asset. `NATIVE`
    ///         keys the BNB leg. Generic per `DECISIONS.md §2`; launch value 0
    ///         on every asset here (see the header for why a P2P venue cannot
    ///         hand out a seller-funded discount).
    function setDiscountBps(address asset, uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert DiscountTooHigh(bps);
        discountBpsOf[asset] = bps;
        emit DiscountSet(asset, bps);
    }

    function setFeeTreasury(address _feeTreasury) external onlyOwner {
        if (_feeTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(feeTreasury, _feeTreasury);
        feeTreasury = _feeTreasury;
    }

    function setKeeper(address _keeper) external onlyOwner {
        emit KeeperChanged(keeper, _keeper);
        keeper = _keeper;
    }

    /// @notice Oracle policy. Mirrors `MintDrop.setOraclePolicy` so both
    ///         contracts price BNB the same way.
    function setOraclePolicy(uint256 maxAge, uint256 minPrice, uint256 maxPrice)
        external
        onlyOwner
    {
        if (maxAge == 0 || maxAge > MAX_ORACLE_AGE) revert BadOraclePolicy(maxAge);
        if (minPrice != 0 && maxPrice != 0 && minPrice > maxPrice) revert OracleOutOfBand(minPrice);
        maxOracleAge = maxAge;
        minBnbUsd = minPrice;
        maxBnbUsd = maxPrice;
        emit OraclePolicyChanged(maxAge, minPrice, maxPrice);
    }

    /// @notice Publish the BNBULL/USD peg. Owner or keeper, because it tracks a
    ///         drifting market price (`DECISIONS.md §2`). Writing 0 disables
    ///         every `Pegged` listing's BNBULL leg immediately — the kill
    ///         switch for a keeper that has lost its price source.
    function setBnbullUsd(uint256 price1e18) external onlyKeeperOrOwner {
        bnbullUsd1e18 = price1e18;
        bnbullUsdUpdatedAt = uint64(block.timestamp);
        emit BnbullPegUpdated(price1e18, uint64(block.timestamp));
    }

    function setMaxBnbullPegAge(uint256 maxAge) external onlyOwner {
        if (maxAge == 0 || maxAge > MAX_PEG_AGE) revert BadOraclePolicy(maxAge);
        maxBnbullPegAge = maxAge;
        emit BnbullPegPolicyChanged(maxAge);
    }

    /// @notice See `blocksDeadListings`. ⚠ The phase-2 calves instance sets
    ///         this false if that collection has no `isDead(uint256)`.
    function setBlocksDeadListings(bool blocks_) external onlyOwner {
        blocksDeadListings = blocks_;
        emit DeadListingPolicyChanged(blocks_);
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

    function setWiringDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_WIRING_DELAY || newDelay > MAX_WIRING_DELAY) {
            revert DelayOutOfRange(newDelay);
        }
        wiringDelay = newDelay;
        emit WiringDelayChanged(newDelay);
    }

    /**
     * @dev THE DECIMALS TRAP, HANDLED. Every decimals value this contract
     *      divides by is READ from the wired contract at wiring time, so a
     *      token that does not implement `decimals()` fails the wiring
     *      transaction instead of the first sale — and no divisor anywhere is
     *      a literal copied from a different chain's assumptions.
     */
    function _afterWire(Wire slot, address target) private {
        if (slot == Wire.Bnbull) {
            bnbullDecimals = _readDecimals(target);
        } else if (slot == Wire.PriceFeed) {
            uint8 d = AggregatorV3Interface(target).decimals();
            if (d > MAX_TOKEN_DECIMALS) revert TokenDecimalsUnusable(d);
            feedDecimals = d;
        }
        // Wire.JackpotSink has nothing to read: it is handed money, never asked
        // for a price. Deliberately NOT probed for an interface either — the
        // slice is pushed with a call whose result is not trusted anyway.
    }

    function _readDecimals(address token) private view returns (uint8 d) {
        d = IERC20Metadata(token).decimals();
        if (d > MAX_TOKEN_DECIMALS) revert TokenDecimalsUnusable(d);
    }

    function _wire(Wire slot) private view returns (address) {
        return _wires[uint8(slot)].current;
    }

    /**
     * @notice Recover a token sent here by mistake.
     *
     * @dev This contract is not an escrow: it holds a payment for the few
     *      opcodes between the pull and the payouts of a single `buy`, and
     *      nothing else. It never custodies an NFT, and there is deliberately
     *      NO native rescue — native held here is either mid-sale, owed to
     *      someone through `nativeCredit`, or an accrued jackpot slice, and
     *      none of that money is the owner's to take.
     *
     *      ⚠ A token balance is no longer always stray: an accrued jackpot
     *      slice sits here as a real balance waiting for `sweepPotFee`. The
     *      rescue is bounded by what is NOT spoken for, so it cannot become a
     *      side door into the pot's money.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 reserved = potFeeUndeliveredToken[token];
        if (reserved != 0) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (amount + reserved > bal) {
                revert ReservedForPot(amount, bal > reserved ? bal - reserved : 0);
            }
        }
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ─── Maths ───────────────────────────────────────────────────────────

    function _afterRebate(uint256 gross, address asset) private view returns (uint256) {
        (uint256 buyerPays,,) = _split(gross, asset);
        return buyerPays;
    }

    function _bnbullPegFresh() private view returns (bool) {
        if (bnbullUsd1e18 == 0 || bnbullUsdUpdatedAt == 0) return false;
        return block.timestamp <= uint256(bnbullUsdUpdatedAt) + maxBnbullPegAge;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ─── IERC721Receiver ─────────────────────────────────────────────────
    //
    // Implemented so this contract is a valid receiver if a token is ever
    // pushed to it (it never asks for one). Buyers receive directly from the
    // seller, so the sale path does not route through here.

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Bare native sends are refused. BNB is a payment currency here, but
    ///      only through `buyWithBNB`, which knows what it is buying. Nothing
    ///      upstream calls this contract in a never-fail path, so reverting is
    ///      safe — it cannot brick a mint, a revive or a fight.
    receive() external payable {
        revert DirectNativeNotAccepted();
    }
}
