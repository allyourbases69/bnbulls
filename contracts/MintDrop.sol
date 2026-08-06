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

/// @dev Minimal Jackpot surface used by MintDrop.
interface IJackpotFund {
    function fund(uint256 amount, string calldata source) external;
}

/// @dev Wrapped BNB. `deposit` is 1:1 and cannot fail on liquidity — it is a
///      wrap, not a swap, which is why the BNB leg of a BNB payment still
///      counts as "no DEX interaction at all" (`DECISIONS.md §13`).
interface IWBNB is IERC20 {
    function deposit() external payable;
}

/**
 * @dev PancakeSwap v2 router (0x10ED43C718714eb63d5aA57B78B54704E256024E).
 *      `WETH()` here returns **WBNB**, and unlike Stable's WgUSDT that is a
 *      real wrapper over a real volatile gas token — the swap legs below wrap
 *      for real.
 *
 *      ⚠ THE SWAPS ARE THE **FEE-SUPPORTING** VARIANTS — `DECISIONS.md §30`.
 *      four.meme template B carries a creator-set buy AND sell tax (measured
 *      -10%), and a plain `swapExactTokensForTokens` on such a token reverts
 *      `Pancake: K`. The fee-supporting calls work on both templates, so the
 *      buy leg does not depend on which launch form the token ends up on. They
 *      return NOTHING, which costs us nothing: the figure booked here has
 *      always been `balanceOf` after minus before.
 *
 *      ⚠ `factory()` IS THE ONLY SOURCE OF THE PAIR. Never a second wire — a
 *      separate factory address could point at a different book than the one
 *      the swap hits, which is `BNB-CHAIN-FACTS.md §3` all over again.
 */
interface IPancakeRouter02 {
    function WETH() external view returns (address);

    /// @notice The v2 factory this router routes through. Authoritative.
    function factory() external view returns (address);

    /// @dev Constant-product quote over the pairs the swap is about to hit.
    ///      Used to derive `minOut` for the inline buy, where no off-chain
    ///      keeper exists to pre-quote.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @dev PancakeSwap v2 factory. ONE canonical pair per token pair.
interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @dev The canonical v2 pair. `token0()` is read, never derived from address
///      ordering — the pair is the authority on its own reserve order.
interface IPancakePair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

/**
 * @title MintDrop
 * @notice The initial-mint controller for bnbulls. Sells up to MAX_MINT bulls
 *         on a dollar-denominated ladder payable in BNB or BNBULL
 *         (`DECISIONS.md §26` — there is no third payment currency), and splits
 *         every payment across the two no-withdraw pots and the dev treasury.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      RULE 1: `$USDT0 -> $BNB` WAS A REWRITE, NOT A RENAME
 *      ══════════════════════════════════════════════════════════════════════
 *      Fighting Fefers ran on Stable (chain 988), where the native gas token
 *      WAS USDT and `native_balance / 1e12 == USDT0.balanceOf(same)` exactly.
 *      The entire fefers money layer fell out of that one identity: prices
 *      were "already in dollars, no oracle needed", a contract holding native
 *      could approve an ERC-20 router and swap with no wrap step, and
 *      `MintDrop.buyFeferInline` could pull a 6-dec ERC-20 and then check
 *      `address(this).balance` for the matching 18-dec native.
 *
 *      **On BNB Chain every line of that is false.** BNB is volatile, 18-dec,
 *      and not a dollar; swaps need WBNB. So:
 *        - `NATIVE_TO_ERC20 = 1e12` IS DELETED. It has no counterpart here and
 *          re-introducing it would silently mis-scale every slice by 1e12.
 *        - Every dollar sticker is converted at PAY TIME through the Chainlink
 *          BNB/USD feed (`DECISIONS.md §1`). Stale `updatedAt`, a non-positive
 *          answer, an incomplete round and an out-of-band price all REVERT.
 *          Nothing is clamped silently — a clamp is a wrong price presented as
 *          a right one.
 *        - Contracts truly custody what they swap. A BNBULL payment is pulled
 *          in, measured, and routed as the token we hold; a BNB payment is
 *          spent as BNB through the WBNB path.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      RULE 2: PLAYER-FACING NUMBERS ARE BOUNDED SETTERS, NOT CONSTANTS
 *      ══════════════════════════════════════════════════════════════════════
 *      `constant` here is reserved for true security ceilings (`MAX_*`). Every
 *      price, share and slippage figure is owner-settable inside one. Wiring
 *      legs are TIMELOCKED, never one-time-set — see `lib/TimelockedAddress`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE PRICE LADDER (`DECISIONS.md §12`)
 *      ══════════════════════════════════════════════════════════════════════
 *        upToSold  100 -> $10   |  200 -> $20  |  300 -> $35
 *                  400 -> $50   |  500 -> $75
 *      Set with `setPriceTiers`, which replaces the WHOLE table. There is no
 *      flat-price fallback: fefers fell back to `ethPrice/usdgPrice` when no
 *      tier matched, which is a live footgun (a stale testnet flat price
 *      silently underselling the drop). Here an unpriced mint reverts.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE DISCOUNT (`DECISIONS.md §2`) — APPLIED EXACTLY ONCE, HERE
 *      ══════════════════════════════════════════════════════════════════════
 *      `discountBpsOf` is generic per payment asset (`address(0)` is the
 *      sentinel for native BNB) and launches at 1000 bps on BNBULL, 0 on
 *      everything else.
 *
 *      ⚠ DOUBLE-DISCOUNT TRAP. `DECISIONS.md §2` says the price-keeper pegs
 *      the BNBULL legs to "dollar sticker − discount". If the keeper wrote the
 *      already-discounted amount into `PriceTier.bnbullPrice` AND this
 *      contract applied `discountBpsOf[bnbull]` on top, buyers would get 19%
 *      off, not 10%. The contract is the single source of the discount:
 *      **the keeper pegs `bnbullPrice` to the FULL sticker's BNBULL
 *      equivalent, and this contract takes the 10% off.** `bnbullPriceFor`
 *      returns the undiscounted peg, `quoteBNBULL` returns what a buyer pays.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      POT ROUTING (`DECISIONS.md §13`) — 20% BNBULL / 10% BNB / 70% dev
 *      ══════════════════════════════════════════════════════════════════════
 *        - The BNBULL leg is ALWAYS a swap, except when the buyer paid in
 *          BNBULL — then it is already the pot asset and routes straight in.
 *        - The BNB leg is a swap ONLY from a BNBULL payment, and `§14` keeps
 *          that switched off. A BNB payment is wrapped 1:1 to WBNB and routed
 *          straight into the pot.
 *          ⚠ The "BNB pot" is a **WBNB** pot; see the note on `Jackpot`.
 *        - The remaining 70% splits between `treasury` and the LP slot.
 *
 *      ⚠ KEEP THE LP SLOT. `lpTreasury` / `lpShareBps` are unused at launch
 *      (`lpShareBps = 0`) and that is deliberate: on fefers this exact slot was
 *      the hook that let a whole extra buyback leg be added to a FROZEN
 *      MintDrop with zero redeploy — point `lpTreasury` at a splitter and its
 *      `receive()` gets the slice. Do not delete it as dead code.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE NEVER-FAIL RULE (`BNBULLS-BOOTSTRAP.md §6`)
 *      ══════════════════════════════════════════════════════════════════════
 *      A mint, a revive or a fight must NEVER fail because of a buyback. A
 *      thin pool, a reverting router, a pool that does not exist yet and a
 *      slippage bust are all real. So every pot leg is
 *      `try this.routeTo…Inline() catch { accrue }`, the inline worker is
 *      `external` only so this contract can try/catch its own call and is
 *      gated by `NotSelf`, and a failed leg ACCRUES into a `pending*` bucket
 *      that a keeper sweeps later with an off-chain-quoted floor. Both
 *      outcomes emit their own event, so which one is happening in production
 *      is visible on chain. Do not "simplify" the try/catch away.
 *
 *      Swaps are booked as a MEASURED BALANCE DELTA (`balanceOf` after minus
 *      before), re-checked against `minOut`. The router's reported output is
 *      never trusted: a fee-on-transfer token or a lying router would
 *      otherwise wedge the pot forever. A `minOut` of 0 is refused outright as
 *      a blind swap.
 */
contract MintDrop is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── True security ceilings (the only `constant`s that are policy-free) ─

    /// @notice Hard cap on paid mints. Matches `Bulls.MAX_SUPPLY` so the last
    ///         mint either contract allows is the same event.
    uint256 public constant MAX_MINT = 500;
    /// @notice Upper bound on batch size per tx. Bounds gas and blast radius.
    uint256 public constant MAX_BATCH = 20;
    /// @notice Ceiling on any dollar sticker, 1e18-scaled. Stops a compromised
    ///         owner key re-pricing the remaining supply absurdly.
    uint256 public constant MAX_USD_PRICE = 10_000e18;
    /// @notice Ceiling on the BNBULL leg of a tier, in BNBULL wei.
    ///         ⚠ VERIFY against the real fixed supply at deploy.
    uint256 public constant MAX_BNBULL_PRICE = 10_000_000e18;
    /// @notice Ceiling on the per-mint BNBULL airdrop.
    uint256 public constant MAX_AIRDROP_PER_MINT = 1_000_000e18;
    /// @notice Ceiling on any per-asset discount. The launch value is 1000
    ///         (10%) on BNBULL; this bound exists so a stolen key cannot sell
    ///         the drop for pennies.
    uint16 public constant MAX_DISCOUNT_BPS = 5_000;
    /// @notice Ceiling on how much of a payment the two pots can take between
    ///         them. Launch is 3000 (20% + 10%).
    uint256 public constant MAX_TOTAL_POT_BPS = 5_000;
    /// @notice Ceiling on the inline-swap slippage tolerance. Past 20% the
    ///         floor stops being a floor.
    uint256 public constant MAX_INLINE_SLIPPAGE_BPS = 2_000;
    /// @notice Ceiling on the minimum-liquidity floor. A floor set absurdly
    ///         high defers every buy forever — safe, but silently.
    uint256 public constant MAX_MIN_POOL_LIQUIDITY = 10_000 ether;
    /// @notice Ceiling on how stale a Chainlink answer may be and still be
    ///         used. The BSC BNB/USD feed heartbeats far faster than this.
    uint256 public constant MAX_ORACLE_AGE = 24 hours;
    /// @notice Wiring timelock bounds.
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;

    uint256 private constant BPS = 10_000;
    /// @notice Sentinel used as the "asset" key for native BNB in
    ///         `discountBpsOf`. BNB has no token address.
    address public constant NATIVE = address(0);

    // ─── Immutable refs ──────────────────────────────────────────────────

    /// @notice The bulls collection this contract mints from.
    Bulls public immutable bulls;
    /// @notice The BNBULL token: a payment currency, the airdrop asset, and
    ///         the prize token of one of the two pots.
    IERC20 public immutable bnbull;
    /// @notice Wrapped BNB (0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c).
    ///         Immutable because it is the canonical wrapper and never moves.
    IWBNB public immutable wbnb;

    // ─── Timelocked wiring ───────────────────────────────────────────────

    /// @dev Every slot here can redirect money if it is repointed, so every
    ///      one of them is bootstrap-once-then-timelocked. `treasury`,
    ///      `lpTreasury` and `keeper` are NOT in here: the first two are the
    ///      owner's own revenue and the third can only push money INTO a pot.
    ///
    /// ⚠ RENUMBERED BY `DECISIONS.md §26`. `Stablecoin` used to be slot 0 and
    ///   every member has shifted DOWN by one. The hole was not kept reserved —
    ///   nothing is deployed yet, and a reserved slot preserves exactly the
    ///   thing the decision deletes. Re-check every deploy script and any
    ///   tooling that passes a raw uint8.
    enum Wire {
        /// Chainlink BNB/USD (0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE).
        PriceFeed,
        /// PancakeSwap v2 router.
        Router,
        /// The BNBULL-prize Jackpot (1 in 50).
        JackpotBnbull,
        /// The WBNB-prize Jackpot (1 in 100).
        JackpotBnb
    }

    mapping(uint8 => TimelockedAddress.Slot) private _wires;

    /// @notice Delay a wiring change must age before it can be committed.
    uint256 public wiringDelay = 24 hours;

    /// @notice `decimals()` read off the wired price feed (8 for BNB/USD).
    uint8 public feedDecimals;

    // ─── Pricing ─────────────────────────────────────────────────────────

    /**
     * @notice One rung of the mint ladder. Covers mint numbers
     *         (previous tier's upToSold + 1) .. `upToSold` inclusive.
     * @param upToSold    Last mint number this rung covers. Ascending.
     * @param usdPrice    The dollar sticker, 1e18-scaled ($10 = 10e18). The BNB
     *                    leg derives from this through the oracle.
     * @param bnbullPrice The keeper's peg of that sticker in BNBULL wei,
     *                    **undiscounted**. The discount is applied by this
     *                    contract — see the double-discount note in the header.
     *                    Zero means "the BNBULL leg is not priced yet".
     */
    struct PriceTier {
        uint16 upToSold;
        uint128 usdPrice;
        uint128 bnbullPrice;
    }

    PriceTier[] private _priceTiers;

    /// @notice Per-asset discount in basis points. `NATIVE` keys the BNB leg.
    ///         Launch: 1000 on BNBULL, 0 elsewhere (`DECISIONS.md §2`).
    mapping(address => uint16) public discountBpsOf;

    // ─── Oracle policy ───────────────────────────────────────────────────

    /// @notice Reject an answer older than this. ⚠ VERIFY the BNB/USD
    ///         heartbeat at kickoff and tighten.
    uint256 public maxOracleAge = 1 hours;
    /// @notice Optional sanity band on the BNB/USD price, 1e18-scaled. Zero
    ///         disables a side. A feed pinned at its circuit-breaker floor
    ///         (the LUNA failure mode) would otherwise sell the drop for dust.
    uint256 public minBnbUsd;
    uint256 public maxBnbUsd;

    // ─── Routing shares ──────────────────────────────────────────────────

    /// @notice Receives the dev share of mint proceeds.
    address public treasury;
    /// @notice The LP slot. Unused at launch; the splitter hook. See header.
    address public lpTreasury;
    /// @notice Share of the post-pot remainder routed to `lpTreasury`.
    uint256 public lpShareBps;
    /// @notice BNB whose LP transfer failed. Held here, never lost, sweepable
    ///         by the owner. See `_routeNative`.
    uint256 public lpUndelivered;
    /// @notice Share of every payment that buys BNBULL for the BNBULL pot.
    uint256 public bnbullShareBps = 2_000;
    /// @notice Share of every payment that lands in the WBNB pot.
    uint256 public bnbShareBps = 1_000;

    /**
     * @notice When a buyer pays in BNBULL, does the 10% BNB leg SELL BNBULL
     *         for WBNB, or stay in the BNBULL pot?
     *
     * @dev `DECISIONS.md §13` locks "20% BNBULL / 10% BNB / 70% dev, on
     *      everything", and the literal reading of that for a BNBULL payment
     *      is a BNBULL -> WBNB swap. Default `true` implements it literally.
     *
     *      ⚠ OWNER CALL. Selling 10% of BNBULL receipts on the open market
     *      partly cancels the buy pressure the pot exists to create, which is
     *      arguably self-defeating for the one currency whose chart holders
     *      watch. Setting this false routes that slice into the BNBULL pot
     *      instead (so a BNBULL payment becomes 30% BNBULL pot / 70% dev) and
     *      nothing is ever sold. The switch is here so the choice is one tx,
     *      not a redeploy.
     */
    /// @dev OWNER DECISION 2026-08-06: **never sell BNBULL.** A BNBULL payment
    ///      routes 30% BNBULL pot / 70% dev and touches no DEX at all. This is
    ///      the DEFAULT, not a post-deploy toggle, deliberately: if the
    ///      configuration tx is ever forgotten, the safe behaviour is the one
    ///      that happens. Flipping it true restores the literal 20/10/70 read
    ///      and starts selling the token the pot exists to bid up.
    bool public bnbullPaymentSellsForBnbLeg = false;

    /// @notice Slippage tolerance on the INLINE swaps, in bps off the router's
    ///         own `getAmountsOut` quote over the very reserves the swap will
    ///         hit.
    ///
    /// @dev    Read this before touching it, and do not call it a sandwich
    ///         guard — it is not one. The quote and the swap run in the same
    ///         function body with no state change between them, so a front-run
    ///         moves the reserves BEFORE we quote and the quote is simply
    ///         taken at the attacker's price. Nothing quoted on chain can fix
    ///         that. What it actually bounds: ordinary movement plus the
    ///         router fee, a drained pair (quotes zero, the buy defers) and a
    ///         broken router. `sweepBnbullPot` / `sweepBnbPot` are the
    ///         recovery path, and there the floor is quoted OFF chain, which a
    ///         front-run cannot move.
    ///
    /// @dev    ⚠ A TAXED BNBULL NEEDS THIS RAISED ABOVE THE TAX RATE.
    ///         `getAmountsOut` prices the constant-product curve and knows
    ///         NOTHING about a token's transfer tax, so on a four.meme template
    ///         B token (creator-set buy and sell tax, measured -10%,
    ///         `DECISIONS.md §30`) the quote overstates what actually lands by
    ///         the tax. At the launch 500 (5%) every inline buy would then miss
    ///         `minOut` and defer — safe, and money is never lost, but the leg
    ///         silently stops working. The fee-supporting router call fixes the
    ///         `Pancake: K` revert; it does not fix the QUOTE. If the token
    ///         ships with a tax, set this above it (the cap is 20%).
    uint256 public inlineSlippageBps = 500;

    /**
     * @notice Smallest **WBNB-side reserve** the canonical WBNB/BNBULL v2 pair
     *         may hold and still be bought into. Below it, the buy defers and
     *         accrues (`DECISIONS.md §28`, `FOUR-MEME-LAUNCH-ROUTE.md §9.2`).
     *
     * @dev Denominated in WBNB, never in BNBULL: a decoy can mint an unlimited
     *      supply of its own token, it cannot mint BNB.
     *
     *      The window this closes is PRE-GRADUATION, when anybody can
     *      `createPair(BNBULL, WBNB)` and front-run the pair into existence
     *      with dust — v2 has one canonical pair per token pair, so this is not
     *      the "which pool is real" question, it is the "is this pool real at
     *      all" one. It is also what makes the whole curve phase *deliberately*
     *      deferred rather than accidentally so (`§29`).
     *
     *      Bounded owner-settable, not a `constant` (`BNBULLS-BOOTSTRAP §0`):
     *      the right number depends on the raise the token graduates with.
     *      Measured reference points — graduation opens at **17.64 WBNB**, the
     *      demonstrated decoy held **0.01 WBNB**. ZERO IS REFUSED; the way to
     *      stop buying is to unwire the router, which defers.
     */
    uint256 public minPoolLiquidity = 1 ether;

    /// @notice May call the sweeps in addition to the owner.
    address public keeper;

    /// @notice BNBULL airdropped per mint. Zero at launch. Paid out of this
    ///         contract's FREE BNBULL balance only — never out of accrued pot
    ///         money.
    uint256 public airdropPerMint;

    // ─── Deferred pot legs (the never-fail fallback) ─────────────────────

    /// @notice BNB set aside because a BNB -> BNBULL buy could not run.
    uint256 public pendingBnbullBuyNative;
    /// @notice BNBULL set aside because the BNBULL pot could not be funded.
    uint256 public pendingBnbullDirect;
    /// @notice BNB set aside because the WBNB pot could not be funded.
    uint256 public pendingBnbPotNative;
    /// @notice BNBULL set aside because a BNBULL -> WBNB swap could not run.
    uint256 public pendingBnbPotBnbull;

    /// @dev Which asset a pot leg is denominated in.
    /// @dev ⚠ RENUMBERED BY `DECISIONS.md §26`: `Stable` was 1 and `Bnbull` has
    ///      moved 2 -> 1. It is an ARGUMENT to `sweepBnbullPot`, `sweepBnbPot`
    ///      and `withdrawPendingForManualBuy` and is INDEXED in the deferral
    ///      events, so keepers and indexers move with it.
    enum PotSource {
        Native,
        Bnbull
    }

    // ─── Sale state ──────────────────────────────────────────────────────

    /// @notice Bulls sold by this contract.
    uint256 public totalSold;

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    /// @param usdSticker1e18 The UNDISCOUNTED dollar sticker for this rung.
    /// @param paymentType ⚠ RENUMBERED BY `DECISIONS.md §26`: 0 = BNB,
    ///        **1 = BNBULL**. It used to be 1 = stablecoin, 2 = BNBULL. Any
    ///        indexer keyed on the old codes reads every BNBULL mint as a
    ///        stablecoin one.
    event BullSold(
        address indexed buyer,
        uint256 indexed tokenId,
        uint8 paymentType,
        uint256 usdSticker1e18,
        uint256 airdropped
    );
    /// @notice One receipt per payment. `bnbUsd1e18` is the oracle answer the
    ///         conversion actually used, so the price is auditable on chain.
    event MintPaid(
        address indexed buyer,
        uint8 paymentType,
        address asset,
        uint256 amountPaid,
        uint256 usdTotal1e18,
        uint16 discountBps,
        uint256 bnbUsd1e18
    );
    event PriceTiersSet(uint256 tierCount);
    event DiscountSet(address indexed asset, uint16 bps);
    event TreasuryChanged(address indexed previous, address indexed next);
    event LpTreasuryChanged(address indexed previous, address indexed next);
    event LpShareChanged(uint256 newBps);
    event PotSharesChanged(uint256 bnbullBps, uint256 bnbBps);
    event BnbullPaymentSellPolicyChanged(bool sellsForBnbLeg);
    event InlineSlippageChanged(uint256 newBps);
    event MinPoolLiquidityChanged(uint256 minWbnbReserve);
    event KeeperChanged(address indexed previous, address indexed next);
    event AirdropChanged(uint256 newAirdropPerMint);
    event OraclePolicyChanged(uint256 maxAge, uint256 minPrice, uint256 maxPrice);
    event WireBootstrapped(Wire indexed slot, address indexed target);
    event WireProposed(Wire indexed slot, address indexed target, uint64 eta);
    event WireCommitted(Wire indexed slot, address indexed previous, address indexed next);
    event WireCancelled(Wire indexed slot, address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event SocialsChanged(string website, string twitter, string telegram);

    /// @notice A pot leg completed inside the payer's own transaction. The
    ///         normal case, and the one the site describes.
    event BnbullPotFundedInline(PotSource indexed src, uint256 spent, uint256 funded);
    event BnbPotFundedInline(PotSource indexed src, uint256 spent, uint256 funded);
    /// @notice A pot leg could not run this time (no route wired, thin or dead
    ///         pair, router revert, slippage bust, pot not accepting funds), so
    ///         it accrued instead. The exception, on chain, so nobody has to
    ///         take our word for which it was.
    event BnbullPotDeferred(PotSource indexed src, uint256 amount, uint256 bucketTotal);
    event BnbPotDeferred(PotSource indexed src, uint256 amount, uint256 bucketTotal);
    event PotSwept(bool indexed toBnbullPot, PotSource src, uint256 spent, uint256 funded);
    event PendingWithdrawnForManualBuy(PotSource src, bool bnbullPot, address to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice The LP slice could not be delivered and is being held here.
    event LpDeferred(uint256 amount, uint256 bucketTotal);
    event LpUndeliveredWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────

    error SupplyExhausted();
    error ZeroAddress();
    error InvalidCount(uint256 count);
    error InvalidShare(uint256 bps);
    error InvalidTiers();
    error PriceTooHigh(uint256 requested, uint256 cap);
    error NotPriced(uint256 mintNumber);
    error BnbullPathNotPriced();
    error InsufficientBNB(uint256 required, uint256 sent);
    error RefundFailed();
    error TreasuryTransferFailed();
    error NothingUndelivered();
    error DelayOutOfRange(uint256 requested);
    error NotKeeperOrOwner();
    error NotSelf();
    error PotNotWired();
    error RouteNotWired();
    error UnsupportedAsset(address asset);
    error BadSource();
    error BlindSwapRefused();
    error SwapOutBelowMin(uint256 received, uint256 minimum);
    /// @notice The canonical WBNB/BNBULL pair holds less WBNB than
    ///         `minPoolLiquidity`, or does not exist at all. Caught on every
    ///         inline path, where it becomes an accrual.
    error PoolTooThin(uint256 wbnbReserve, uint256 minimum);
    error InvalidMinLiquidity(uint256 requested);
    error InsufficientPending(uint256 requested, uint256 available);
    error NothingToSweep();
    error AirdropTooHigh(uint256 requested, uint256 cap);
    error OracleNotWired();
    error OracleBadAnswer(int256 answer);
    error OracleBadRound(uint80 roundId, uint80 answeredInRound, uint256 updatedAt);
    error OracleStale(uint256 updatedAt, uint256 maxAge);
    error OracleOutOfBand(uint256 price1e18);
    error FeedDecimalsUnusable(uint8 decimals_);
    error ReservedForPots(uint256 requested, uint256 free);

    // ─── Constructor ─────────────────────────────────────────────────────

    struct DeployParams {
        address initialOwner;
        address bulls;
        address bnbull;
        address wbnb;
        address treasury;
        address lpTreasury;
    }

    constructor(DeployParams memory p) Ownable(p.initialOwner) {
        if (
            p.bulls == address(0) || p.bnbull == address(0) || p.wbnb == address(0)
                || p.treasury == address(0) || p.lpTreasury == address(0)
        ) revert ZeroAddress();

        bulls = Bulls(p.bulls);
        bnbull = IERC20(p.bnbull);
        wbnb = IWBNB(p.wbnb);
        treasury = p.treasury;
        lpTreasury = p.lpTreasury;

        // `DECISIONS.md §2`: the launch value is 1000 bps on the BNBULL leg
        // and 0 on every other asset. The mapping stays generic so the owner
        // can retune without a redeploy.
        discountBpsOf[p.bnbull] = 1_000;
        emit DiscountSet(p.bnbull, 1_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Views: pricing
    // ══════════════════════════════════════════════════════════════════════

    function priceTierCount() external view returns (uint256) {
        return _priceTiers.length;
    }

    function priceTierAt(uint256 i) external view returns (PriceTier memory) {
        return _priceTiers[i];
    }

    /**
     * @notice The undiscounted dollar sticker and BNBULL peg for the Nth mint.
     * @dev Reverts if no tier covers `mintNumber`. There is deliberately no
     *      flat-price fallback — see the header.
     */
    function priceForMint(uint256 mintNumber)
        public
        view
        returns (uint256 usd1e18, uint256 bnbullPrice)
    {
        uint256 n = _priceTiers.length;
        for (uint256 i = 0; i < n; i++) {
            if (mintNumber <= _priceTiers[i].upToSold) {
                return (_priceTiers[i].usdPrice, _priceTiers[i].bnbullPrice);
            }
        }
        revert NotPriced(mintNumber);
    }

    /// @dev Undiscounted totals for `count` mints starting at the next slot,
    ///      plus the per-unit stickers for the sale events.
    struct Quote {
        uint256 usdTotal;
        uint256 bnbullTotal;
        /// @dev False if ANY rung in the batch has `bnbullPrice == 0`, i.e.
        ///      the keeper has not pegged it yet (pre-pool). A separate flag
        ///      rather than a poison value in `bnbullTotal`, because a poison
        ///      sentinel would overflow the moment a later priced rung added
        ///      to it.
        bool bnbullPriced;
        uint256[] perUnitUsd;
    }

    function _quote(uint256 startMint, uint256 count) private view returns (Quote memory q) {
        q.perUnitUsd = new uint256[](count);
        q.bnbullPriced = true;
        for (uint256 i = 0; i < count; i++) {
            (uint256 usd, uint256 bull) = priceForMint(startMint + i);
            q.perUnitUsd[i] = usd;
            q.usdTotal += usd;
            q.bnbullTotal += bull;
            if (bull == 0) q.bnbullPriced = false;
        }
    }

    /// @notice What the next `count` mints cost right now in each currency.
    ///         Reverts if the oracle is stale or out of band — deliberately:
    ///         a UI must not paper over a bad price. For an oracle-free read
    ///         of the ladder itself, walk `priceForMint` / `priceTierAt`.
    function quote(uint256 count)
        external
        view
        returns (uint256 usdTotal1e18, uint256 bnbDue, uint256 bnbullDue, uint256 bnbUsd1e18)
    {
        Quote memory q = _quote(totalSold + 1, count);
        bnbUsd1e18 = bnbUsdPrice();
        usdTotal1e18 = q.usdTotal;
        bnbDue = _ceilDiv(_discounted(q.usdTotal, NATIVE) * 1e18, bnbUsd1e18);
        bnbullDue = q.bnbullPriced ? _discounted(q.bnbullTotal, address(bnbull)) : 0;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The oracle — `DECISIONS.md §1`, option A
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice BNB/USD, normalised to 1e18.
     * @dev REVERTS rather than clamping on: a non-positive answer, an
     *      incomplete round, a zero timestamp, an answer older than
     *      `maxOracleAge`, or a price outside the sanity band. A clamp would
     *      hand out mints at a price nobody chose.
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
    //  Public mint
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Mint `count` bulls to `to`, paying in BNB. Send at least
    ///         `quote(count).bnbDue` plus a cushion; the surplus is refunded.
    ///         `count` of 1 is the ordinary single mint.
    function mintWithBNB(address to, uint256 count)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256[] memory)
    {
        return _mintWithBNB(to, count);
    }

    /// @notice Mint `count` bulls paying in BNBULL — the discounted path
    ///         (`DECISIONS.md §2`). Approve `quote(count).bnbullDue` first.
    function mintWithBNBULL(address to, uint256 count)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory)
    {
        return _mintWithBNBULL(to, count);
    }

    /**
     * @dev The BNB path. `msg.value >= due` rather than `== due`, and the
     *      excess is refunded.
     *
     *      That is not sloppiness — it is `DECISIONS.md §1`. The dollar-to-BNB
     *      conversion happens at PAY time, so between the wallet quoting a
     *      price and the transaction landing the oracle can move and the exact
     *      amount due changes. Fefers could demand an exact `msg.value`
     *      because on Stable the price never moved: native WAS the dollar.
     *      Insisting on equality here would revert honest mints on ordinary
     *      volatility. Send with a cushion; the surplus comes back.
     */
    function _mintWithBNB(address to, uint256 count) private returns (uint256[] memory tokenIds) {
        _preflight(to, count);
        Quote memory q = _quote(totalSold + 1, count);

        uint256 price = bnbUsdPrice();
        uint256 bnbDue = _ceilDiv(_discounted(q.usdTotal, NATIVE) * 1e18, price);
        if (msg.value < bnbDue) revert InsufficientBNB(bnbDue, msg.value);

        unchecked {
            totalSold += count;
        }

        _routeNative(bnbDue);
        tokenIds = _mintAndEmit(to, count, 0, q.perUnitUsd);

        emit MintPaid(
            msg.sender, 0, NATIVE, bnbDue, q.usdTotal, discountBpsOf[NATIVE], price
        );

        uint256 refund = msg.value - bnbDue;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev The BNBULL path — the discounted one (`DECISIONS.md §2`). The full
    ///      payment is pulled in and MEASURED before anything is routed, so
    ///      what we distribute is what actually arrived rather than what we
    ///      asked for.
    function _mintWithBNBULL(address to, uint256 count)
        private
        returns (uint256[] memory tokenIds)
    {
        _preflight(to, count);
        Quote memory q = _quote(totalSold + 1, count);
        if (!q.bnbullPriced) revert BnbullPathNotPriced();
        uint256 due = _discounted(q.bnbullTotal, address(bnbull));

        unchecked {
            totalSold += count;
        }

        uint256 received = _pullMeasured(bnbull, msg.sender, due);
        _routeToken(PotSource.Bnbull, bnbull, received);
        tokenIds = _mintAndEmit(to, count, 1, q.perUnitUsd);

        emit MintPaid(
            msg.sender, 1, address(bnbull), received, q.usdTotal, discountBpsOf[address(bnbull)], 0
        );
    }

    function _preflight(address to, uint256 count) private view {
        if (to == address(0)) revert ZeroAddress();
        if (count == 0 || count > MAX_BATCH) revert InvalidCount(count);
        if (totalSold + count > MAX_MINT) revert SupplyExhausted();
    }

    function _mintAndEmit(
        address to,
        uint256 count,
        uint8 paymentType,
        uint256[] memory perUnitUsd
    ) private returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 id = bulls.mint(to);
            tokenIds[i] = id;
            uint256 airdropped = _maybeAirdrop(to);
            emit BullSold(to, id, paymentType, perUnitUsd[i], airdropped);
        }
    }

    /**
     * @dev Airdrop BNBULL out of the FREE balance only. A shortfall quietly
     *      airdrops less rather than reverting — a late mint must not fail
     *      because a promo budget ran out.
     */
    function _maybeAirdrop(address to) private returns (uint256 airdropped) {
        uint256 want = airdropPerMint;
        if (want == 0) return 0;
        uint256 free = _freeBnbull();
        airdropped = want > free ? free : want;
        if (airdropped > 0) bnbull.safeTransfer(to, airdropped);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Routing — `DECISIONS.md §13`: 20% BNBULL / 10% BNB / 70% dev
    // ══════════════════════════════════════════════════════════════════════

    /// @dev BNB in. The BNBULL leg is a swap; the BNB leg is a 1:1 wrap.
    function _routeNative(uint256 amount) private {
        uint256 potBnbull = (amount * bnbullShareBps) / BPS;
        uint256 potBnb = (amount * bnbShareBps) / BPS;
        uint256 rest = amount - potBnbull - potBnb;

        _toBnbullPotOrAccrue(PotSource.Native, potBnbull);
        _toBnbPotOrAccrue(PotSource.Native, potBnb);

        uint256 lpShare = (rest * lpShareBps) / BPS;
        uint256 devShare = rest - lpShare;
        if (devShare > 0) {
            (bool ok,) = treasury.call{value: devShare}("");
            if (!ok) revert TreasuryTransferFailed();
        }
        if (lpShare > 0) {
            // The LP slot is a splitter hook: point it at a splitter and this
            // lands in the splitter's `receive()`.
            //
            // ⚠ IT ACCRUES ON FAILURE, IT DOES NOT REVERT. Fefers reverted here
            // (`LpTransferFailed`), and that made every native mint depend on a
            // third-party `receive()` behaving. It does not always behave, and
            // the failure is not exotic — the OBVIOUS splitter body forwards to
            // `MintDrop.donatePotNative()`, which re-enters this contract while
            // `mintWithBNB` still holds `nonReentrant`. The guard reverts, `ok`
            // is false, and EVERY BNB MINT FAILS. It would not have shown up
            // until the day someone set `lpShareBps > 0`, because the slot
            // launches at zero.
            //
            // Reverting a mint to protect a discretionary buyback leg is the
            // wrong trade in any case: this is the owner's own money on its way
            // to the owner's own splitter. On failure it stays here, is visible
            // as `lpUndelivered`, and the owner sweeps it — the same
            // accrue-and-carry-on shape as every pot leg.
            (bool ok,) = lpTreasury.call{value: lpShare}("");
            if (!ok) {
                lpUndelivered += lpShare;
                emit LpDeferred(lpShare, lpUndelivered);
            }
        }
    }

    /// @dev A token payment already custodied by this contract.
    function _routeToken(PotSource src, IERC20 token, uint256 amount) private {
        uint256 potBnbull = (amount * bnbullShareBps) / BPS;
        uint256 potBnb = (amount * bnbShareBps) / BPS;
        uint256 rest = amount - potBnbull - potBnb;

        _toBnbullPotOrAccrue(src, potBnbull);

        if (src == PotSource.Bnbull && !bnbullPaymentSellsForBnbLeg) {
            // Owner opted out of selling BNBULL to fund the WBNB pot; the
            // slice joins the BNBULL pot instead. See the flag's docs.
            _toBnbullPotOrAccrue(PotSource.Bnbull, potBnb);
        } else {
            _toBnbPotOrAccrue(src, potBnb);
        }

        uint256 lpShare = (rest * lpShareBps) / BPS;
        uint256 devShare = rest - lpShare;
        if (devShare > 0) token.safeTransfer(treasury, devShare);
        if (lpShare > 0) token.safeTransfer(lpTreasury, lpShare);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The never-fail pot legs
    // ══════════════════════════════════════════════════════════════════════

    function _toBnbullPotOrAccrue(PotSource src, uint256 amount) private {
        if (amount == 0) return;
        if (_bnbullLegReady(src)) {
            try this.routeToBnbullPotInline(src, amount) returns (uint256 funded) {
                emit BnbullPotFundedInline(src, amount, funded);
                return;
            } catch {
                // Deliberately catch-all: a thin pair, a router that reverts,
                // a pot that has not whitelisted us yet, a token that changed
                // under us — every one of them means "not now", never "fail
                // the player".
            }
        }
        uint256 total = _accrueBnbull(src, amount);
        emit BnbullPotDeferred(src, amount, total);
    }

    function _toBnbPotOrAccrue(PotSource src, uint256 amount) private {
        if (amount == 0) return;
        if (_bnbLegReady(src)) {
            try this.routeToBnbPotInline(src, amount) returns (uint256 funded) {
                emit BnbPotFundedInline(src, amount, funded);
                return;
            } catch {}
        }
        uint256 total = _accrueBnb(src, amount);
        emit BnbPotDeferred(src, amount, total);
    }

    /// @dev Cheap pre-check so a pre-launch mint does not pay for a try/catch
    ///      that cannot possibly work.
    function _bnbullLegReady(PotSource src) private view returns (bool) {
        if (_wire(Wire.JackpotBnbull) == address(0)) return false;
        if (src == PotSource.Bnbull) return true; // already the pot asset
        return _wire(Wire.Router) != address(0);
    }

    function _bnbLegReady(PotSource src) private view returns (bool) {
        if (_wire(Wire.JackpotBnb) == address(0)) return false;
        if (src == PotSource.Native) return true; // a wrap, not a swap
        return _wire(Wire.Router) != address(0);
    }

    function _accrueBnbull(PotSource src, uint256 amount) private returns (uint256) {
        if (src == PotSource.Native) return pendingBnbullBuyNative += amount;
        return pendingBnbullDirect += amount;
    }

    function _accrueBnb(PotSource src, uint256 amount) private returns (uint256) {
        if (src == PotSource.Native) return pendingBnbPotNative += amount;
        return pendingBnbPotBnbull += amount;
    }

    /**
     * @notice The inline BNBULL-pot leg. `external` ONLY so this contract can
     *         try/catch its own call; `NotSelf` makes it unreachable to anyone
     *         else, so it is not a way to spend this contract's balance.
     * @dev Reverts freely. Every revert is caught upstream and becomes an
     *      accrual.
     */
    function routeToBnbullPotInline(PotSource src, uint256 amount)
        external
        returns (uint256 funded)
    {
        if (msg.sender != address(this)) revert NotSelf();
        return _toBnbullPot(src, amount, 0, "mint-inline");
    }

    /// @notice The inline WBNB-pot leg. See `routeToBnbullPotInline`.
    function routeToBnbPotInline(PotSource src, uint256 amount) external returns (uint256 funded) {
        if (msg.sender != address(this)) revert NotSelf();
        return _toBnbPot(src, amount, 0, "mint-inline");
    }

    /**
     * @dev Move `amount` of `src` into the BNBULL pot.
     * @param minOutOverride 0 means "quote the floor on chain off the router's
     *        own reserves" (the inline path). The sweeps pass a floor quoted
     *        OFF chain, which is the one bound a same-block front-run cannot
     *        move.
     */
    function _toBnbullPot(
        PotSource src,
        uint256 amount,
        uint256 minOutOverride,
        string memory source
    ) private returns (uint256 funded) {
        address pot = _wire(Wire.JackpotBnbull);
        if (pot == address(0)) revert PotNotWired();
        if (amount == 0) revert NothingToSweep();

        if (src == PotSource.Bnbull) {
            // Already the pot asset. No swap, no slippage, no router.
            funded = amount;
        } else {
            // ONE hop. The three-address stablecoin path went with
            // `DECISIONS.md §26`; WBNB -> BNBULL is the only route left.
            address[] memory path = new address[](2);
            path[0] = address(wbnb);
            path[1] = address(bnbull);
            funded = _swapNativeAndMeasure(amount, _floor(amount, path, minOutOverride), path);
        }

        _fundPot(pot, bnbull, funded, source);
    }

    /// @dev Move `amount` of `src` into the WBNB pot.
    function _toBnbPot(PotSource src, uint256 amount, uint256 minOutOverride, string memory source)
        private
        returns (uint256 funded)
    {
        address pot = _wire(Wire.JackpotBnb);
        if (pot == address(0)) revert PotNotWired();
        if (amount == 0) revert NothingToSweep();

        if (src == PotSource.Native) {
            // A WRAP, not a swap: 1:1, no router, no liquidity dependency.
            // Still measured, because measuring is free and assumptions are
            // how the fefers decimals trap happened.
            uint256 before = wbnb.balanceOf(address(this));
            wbnb.deposit{value: amount}();
            funded = wbnb.balanceOf(address(this)) - before;
        } else {
            address[] memory path = new address[](2);
            path[0] = address(bnbull);
            path[1] = address(wbnb);
            funded = _swapTokensAndMeasure(
                bnbull, amount, _floor(amount, path, minOutOverride), path, IERC20(address(wbnb))
            );
        }

        _fundPot(pot, IERC20(address(wbnb)), funded, source);
    }

    /// @dev The slippage floor for a swap. A floor of ZERO is refused outright
    ///      — a blind swap hands the slice to whoever is watching the mempool,
    ///      and a dead or empty pair quotes zero, which is exactly when we
    ///      want to defer rather than trade.
    function _floor(uint256 amountIn, address[] memory path, uint256 minOutOverride)
        private
        view
        returns (uint256 minOut)
    {
        if (minOutOverride != 0) return minOutOverride;
        address r = _wire(Wire.Router);
        if (r == address(0)) revert RouteNotWired();
        uint256[] memory outs = IPancakeRouter02(r).getAmountsOut(amountIn, path);
        minOut = (outs[outs.length - 1] * (BPS - inlineSlippageBps)) / BPS;
        if (minOut == 0) revert BlindSwapRefused();
    }

    /// @dev Swap BNB for a token, booked as a MEASURED BALANCE DELTA and
    ///      re-checked against `minOut`. The router's reported output is never
    ///      trusted: a fee-on-transfer token or a lying router would otherwise
    ///      wedge the pot forever. The fee-supporting call returns nothing at
    ///      all, so there is no longer anything to be tempted by.
    function _swapNativeAndMeasure(uint256 amountIn, uint256 minOut, address[] memory path)
        private
        returns (uint256 bought)
    {
        address r = _wire(Wire.Router);
        if (r == address(0)) revert RouteNotWired();
        _requireLiquidity(r);
        IERC20 outToken = IERC20(path[path.length - 1]);
        uint256 before = outToken.balanceOf(address(this));
        IPancakeRouter02(r).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            minOut, path, address(this), block.timestamp
        );
        bought = outToken.balanceOf(address(this)) - before;
        if (bought < minOut) revert SwapOutBelowMin(bought, minOut);
    }

    /// @dev Token-for-token, same measured-delta discipline.
    function _swapTokensAndMeasure(
        IERC20 inToken,
        uint256 amountIn,
        uint256 minOut,
        address[] memory path,
        IERC20 outToken
    ) private returns (uint256 bought) {
        address r = _wire(Wire.Router);
        if (r == address(0)) revert RouteNotWired();
        _requireLiquidity(r);
        inToken.forceApprove(r, amountIn);
        uint256 before = outToken.balanceOf(address(this));
        IPancakeRouter02(r).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minOut, path, address(this), block.timestamp
        );
        bought = outToken.balanceOf(address(this)) - before;
        // Never leave an allowance standing. A taxed input token makes the
        // router pull less than `amountIn`, so there usually IS a remainder.
        inToken.forceApprove(r, 0);
        if (bought < minOut) revert SwapOutBelowMin(bought, minOut);
    }

    /**
     * @dev Refuse to trade against a pair that does not exist, or holds less
     *      WBNB than `minPoolLiquidity`.
     *
     *      REVERTS, and every caller is either inside a try/catch (the inline
     *      legs, where it becomes an accrual and a `…Deferred` event) or a
     *      keeper/owner sweep, which is allowed to fail loudly. It is checked
     *      HERE and not in `_bnbullLegReady` / `_bnbLegReady`, because those
     *      run outside the try/catch inside a never-fail entrypoint and an
     *      external call there could brick the caller.
     *
     *      The factory is read off the router — never a second wire — so the
     *      reserve the floor is measured against is, by construction, the book
     *      the swap is about to hit.
     */
    function _requireLiquidity(address r) private view {
        (, uint256 reserve) = _pool(r);
        uint256 floor_ = minPoolLiquidity;
        if (reserve < floor_) revert PoolTooThin(reserve, floor_);
    }

    /**
     * @dev The canonical WBNB/BNBULL v2 pair and its WBNB-side reserve.
     *
     *      A MISSING pair returns zero rather than reverting, so "not launched
     *      yet" and "dust" land in the same place: below the floor, deferred.
     *      `token0()` is READ, never derived from address ordering — the pair
     *      is the authority on its own reserve order.
     */
    function _pool(address r) private view returns (address pair, uint256 reserve) {
        pair = IPancakeFactory(IPancakeRouter02(r).factory()).getPair(
            address(wbnb), address(bnbull)
        );
        if (pair == address(0)) return (pair, 0);
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        reserve = IPancakePair(pair).token0() == address(wbnb) ? uint256(r0) : uint256(r1);
    }

    /// @notice The canonical WBNB/BNBULL v2 pair and its WBNB-side reserve —
    ///         the two numbers `minPoolLiquidity` is compared against. An
    ///         OFF-CHAIN read for the keepers and the deploy pre-flight; it is
    ///         on no never-fail path and may revert if the wired router does
    ///         not speak v2.
    function wbnbPoolLiquidity() external view returns (address pair, uint256 wbnbReserve) {
        address r = _wire(Wire.Router);
        if (r == address(0)) return (address(0), 0);
        return _pool(r);
    }

    /// @dev Lock tokens into a pot. Nothing gets them out again except a won
    ///      ticket — that is the whole product.
    function _fundPot(address pot, IERC20 token, uint256 amount, string memory source) private {
        if (amount == 0) revert NothingToSweep();
        token.forceApprove(pot, amount);
        IJackpotFund(pot).fund(amount, source);
        token.forceApprove(pot, 0);
    }

    function _pullMeasured(IERC20 token, address from, uint256 amount)
        private
        returns (uint256 received)
    {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - before;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Donations — the revive / fight legs route their pot slice through here
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Accept a BNB pot donation and split it across the two pots.
     *         The Graveyard's revive slice lands here, so one route and one
     *         rule cover every source of pot money in the game.
     *
     * @dev ⚠ NOT PAUSABLE, AND IT MUST NOT REVERT. On fefers this exact
     *      entrypoint was called UN-GUARDED by `Graveyard._routeNative`: if it
     *      reverted, every revive in the game bricked. The split maths cannot
     *      revert and both legs are try/catch-or-accrue, so this cannot fail
     *      on the buyback.
     *
     *      The caller has already taken its own dev cut; 100% of what arrives
     *      here goes to the pots, divided in the `bnbullShareBps : bnbShareBps`
     *      ratio (2:1 at launch).
     */
    function donatePotNative() external payable nonReentrant {
        if (msg.value == 0) return;
        (uint256 toBnbull, uint256 toBnb) = _potSplit(msg.value);
        _toBnbullPotOrAccrue(PotSource.Native, toBnbull);
        _toBnbPotOrAccrue(PotSource.Native, toBnb);
    }

    /**
     * @notice Same, paid in BNBULL — the only ERC-20 payment currency left
     *         (`DECISIONS.md §26`). The Graveyard routes a BNBULL revive slice
     *         here so revives keep feeding the pots after the mint sells out.
     *
     * @dev The `(address,uint256)` shape is KEPT even though only one asset is
     *      legal: it is the selector `Graveyard.routePotTokenInline` and
     *      `ReviveBuySplitter` both speak, and the repoint-the-slot trick
     *      depends on the two contracts staying selector-compatible.
     */
    function donatePotToken(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) return;
        if (asset != address(bnbull)) revert UnsupportedAsset(asset);
        uint256 received = _pullMeasured(bnbull, msg.sender, amount);
        (uint256 toBnbull, uint256 toBnb) = _potSplit(received);
        _toBnbullPotOrAccrue(PotSource.Bnbull, toBnbull);
        if (!bnbullPaymentSellsForBnbLeg) {
            _toBnbullPotOrAccrue(PotSource.Bnbull, toBnb);
        } else {
            _toBnbPotOrAccrue(PotSource.Bnbull, toBnb);
        }
    }

    /// @dev Divide a pot-only amount in the configured ratio. With both shares
    ///      at zero (pots disabled) it all goes to the BNBULL leg rather than
    ///      dividing by zero or silently vanishing.
    function _potSplit(uint256 amount) private view returns (uint256 toBnbull, uint256 toBnb) {
        uint256 total = bnbullShareBps + bnbShareBps;
        if (total == 0) return (amount, 0);
        toBnbull = (amount * bnbullShareBps) / total;
        toBnb = amount - toBnbull;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Sweeps — the deferred legs, spent with an OFF-CHAIN quoted floor
    // ══════════════════════════════════════════════════════════════════════

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeperOrOwner();
        _;
    }

    /**
     * @notice Spend a deferred BNBULL-pot leg.
     *
     *         This is the fallback drain, not the main path: money only lands
     *         in a `pending*` bucket when the inline leg could not run. It
     *         stays because "the route was down for an hour" has to have an
     *         answer.
     *
     * @param src      Which bucket to spend.
     * @param amountIn Amount to spend. 0 spends the whole bucket.
     * @param minOut   Slippage floor, quoted OFF chain immediately before the
     *                 call — the one bound a same-block front-run cannot move.
     *                 Ignored for `Bnbull` (no swap). Zero is refused for the
     *                 swap sources.
     */
    function sweepBnbullPot(PotSource src, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        onlyKeeperOrOwner
        returns (uint256 funded)
    {
        uint256 available = _bnbullBucket(src);
        uint256 spend = amountIn == 0 ? available : amountIn;
        if (spend == 0) revert NothingToSweep();
        if (spend > available) revert InsufficientPending(spend, available);
        if (src != PotSource.Bnbull && minOut == 0) revert BlindSwapRefused();

        // Book the spend before the external calls (CEI).
        _debitBnbullBucket(src, spend);
        funded = _toBnbullPot(src, spend, minOut, "deferred-sweep");
        emit PotSwept(true, src, spend, funded);
    }

    /// @notice Spend a deferred WBNB-pot leg. See `sweepBnbullPot`. `minOut`
    ///         is ignored for `Native` (a 1:1 wrap, not a swap).
    function sweepBnbPot(PotSource src, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        onlyKeeperOrOwner
        returns (uint256 funded)
    {
        uint256 available = _bnbBucket(src);
        uint256 spend = amountIn == 0 ? available : amountIn;
        if (spend == 0) revert NothingToSweep();
        if (spend > available) revert InsufficientPending(spend, available);
        if (src != PotSource.Native && minOut == 0) revert BlindSwapRefused();

        _debitBnbBucket(src, spend);
        funded = _toBnbPot(src, spend, minOut, "deferred-sweep");
        emit PotSwept(false, src, spend, funded);
    }

    function _bnbullBucket(PotSource src) private view returns (uint256) {
        return src == PotSource.Native ? pendingBnbullBuyNative : pendingBnbullDirect;
    }

    function _debitBnbullBucket(PotSource src, uint256 amount) private {
        if (src == PotSource.Native) pendingBnbullBuyNative -= amount;
        else pendingBnbullDirect -= amount;
    }

    function _bnbBucket(PotSource src) private view returns (uint256) {
        return src == PotSource.Native ? pendingBnbPotNative : pendingBnbPotBnbull;
    }

    function _debitBnbBucket(PotSource src, uint256 amount) private {
        if (src == PotSource.Native) pendingBnbPotNative -= amount;
        else pendingBnbPotBnbull -= amount;
    }

    /**
     * @notice Escape hatch: pull a deferred leg OUT instead of swapping it,
     *         for the case where no BNBULL pool exists yet and the dev wants
     *         to place the buy by hand and top the pot up manually.
     *
     * @dev ⚠ TRUST BOUNDARY, STATED PLAINLY. Money in a `pending*` bucket has
     *      NOT entered a pot yet, so this hatch can move it. Money that has
     *      reached a `Jackpot` can never come out except through a won ticket
     *      — `Jackpot.sweepForeignToken` reverts on the prize token and there
     *      is no other path. The two guarantees are different and the receipts
     *      trail says which is which: this emits its own event.
     */
    function withdrawPendingForManualBuy(
        bool bnbullPot,
        PotSource src,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = bnbullPot ? _bnbullBucket(src) : _bnbBucket(src);
        uint256 take = amount == 0 ? available : amount;
        if (take == 0) revert NothingToSweep();
        if (take > available) revert InsufficientPending(take, available);

        if (bnbullPot) _debitBnbullBucket(src, take);
        else _debitBnbBucket(src, take);

        if (src == PotSource.Native) {
            (bool ok,) = to.call{value: take}("");
            if (!ok) revert TreasuryTransferFailed();
        } else {
            bnbull.safeTransfer(to, take);
        }
        emit PendingWithdrawnForManualBuy(src, bnbullPot, to, take);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Replace the WHOLE price table. Tiers MUST be sorted ascending by
     *         `upToSold`, and the last one MUST cover `MAX_MINT` — there is no
     *         flat-price fallback to catch an off-by-one table.
     *
     *         The launch table (`DECISIONS.md §12`) is
     *           {100, 10e18, …}, {200, 20e18, …}, {300, 35e18, …},
     *           {400, 50e18, …}, {500, 75e18, …}
     *         with `bnbullPrice` pegged by the keeper to the UNDISCOUNTED
     *         sticker; this contract applies the 10%.
     */
    function setPriceTiers(PriceTier[] calldata tiers) external onlyOwner {
        if (tiers.length == 0) revert InvalidTiers();
        for (uint256 i = 0; i < tiers.length; i++) {
            if (i > 0 && tiers[i].upToSold <= tiers[i - 1].upToSold) revert InvalidTiers();
            if (tiers[i].usdPrice > MAX_USD_PRICE) {
                revert PriceTooHigh(tiers[i].usdPrice, MAX_USD_PRICE);
            }
            if (tiers[i].bnbullPrice > MAX_BNBULL_PRICE) {
                revert PriceTooHigh(tiers[i].bnbullPrice, MAX_BNBULL_PRICE);
            }
        }
        if (tiers[tiers.length - 1].upToSold < MAX_MINT) revert InvalidTiers();

        delete _priceTiers;
        for (uint256 i = 0; i < tiers.length; i++) {
            _priceTiers.push(tiers[i]);
        }
        emit PriceTiersSet(tiers.length);
    }

    /// @notice Set the discount for a payment asset. `NATIVE` (address(0))
    ///         keys the BNB leg. Generic on purpose (`DECISIONS.md §2`) even
    ///         though only BNBULL carries a discount at launch.
    function setDiscountBps(address asset, uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert InvalidShare(bps);
        discountBpsOf[asset] = bps;
        emit DiscountSet(asset, bps);
    }

    /// @notice Retune the pot shares. Bounded so the pots can never take more
    ///         than half of a payment between them.
    function setPotShares(uint256 bnbullBps, uint256 bnbBps) external onlyOwner {
        if (bnbullBps + bnbBps > MAX_TOTAL_POT_BPS) revert InvalidShare(bnbullBps + bnbBps);
        bnbullShareBps = bnbullBps;
        bnbShareBps = bnbBps;
        emit PotSharesChanged(bnbullBps, bnbBps);
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

    /// @notice See `bnbullPaymentSellsForBnbLeg`. An owner call.
    function setBnbullPaymentSellPolicy(bool sellsForBnbLeg) external onlyOwner {
        bnbullPaymentSellsForBnbLeg = sellsForBnbLeg;
        emit BnbullPaymentSellPolicyChanged(sellsForBnbLeg);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }

    function setLpTreasury(address _lpTreasury) external onlyOwner {
        if (_lpTreasury == address(0)) revert ZeroAddress();
        emit LpTreasuryChanged(lpTreasury, _lpTreasury);
        lpTreasury = _lpTreasury;
    }

    function setLpShare(uint256 _lpShareBps) external onlyOwner {
        if (_lpShareBps > BPS) revert InvalidShare(_lpShareBps);
        lpShareBps = _lpShareBps;
        emit LpShareChanged(_lpShareBps);
    }

    function setInlineSlippageBps(uint256 bps) external onlyOwner {
        if (bps > MAX_INLINE_SLIPPAGE_BPS) revert InvalidShare(bps);
        inlineSlippageBps = bps;
        emit InlineSlippageChanged(bps);
    }

    /// @notice Set the minimum WBNB-side reserve the WBNB/BNBULL pair must hold
    ///         before the buy leg will trade against it. ZERO IS REFUSED — see
    ///         `minPoolLiquidity`. Raising it is always safe; lowering it
    ///         towards dust is the decision to be careful with.
    function setMinPoolLiquidity(uint256 minWbnbReserve) external onlyOwner {
        if (minWbnbReserve == 0 || minWbnbReserve > MAX_MIN_POOL_LIQUIDITY) {
            revert InvalidMinLiquidity(minWbnbReserve);
        }
        minPoolLiquidity = minWbnbReserve;
        emit MinPoolLiquidityChanged(minWbnbReserve);
    }

    function setKeeper(address _keeper) external onlyOwner {
        emit KeeperChanged(keeper, _keeper);
        keeper = _keeper;
    }

    function setAirdropPerMint(uint256 amount) external onlyOwner {
        if (amount > MAX_AIRDROP_PER_MINT) revert AirdropTooHigh(amount, MAX_AIRDROP_PER_MINT);
        airdropPerMint = amount;
        emit AirdropChanged(amount);
    }

    /**
     * @notice Oracle policy: how stale an answer may be, and the sanity band.
     * @param maxAge   Seconds. Must be non-zero and <= MAX_ORACLE_AGE.
     * @param minPrice 1e18-scaled floor. 0 disables.
     * @param maxPrice 1e18-scaled ceiling. 0 disables.
     */
    function setOraclePolicy(uint256 maxAge, uint256 minPrice, uint256 maxPrice)
        external
        onlyOwner
    {
        if (maxAge == 0 || maxAge > MAX_ORACLE_AGE) revert InvalidShare(maxAge);
        if (minPrice != 0 && maxPrice != 0 && minPrice > maxPrice) revert OracleOutOfBand(minPrice);
        maxOracleAge = maxAge;
        minBnbUsd = minPrice;
        maxBnbUsd = maxPrice;
        emit OraclePolicyChanged(maxAge, minPrice, maxPrice);
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
     *      showed as 18dp through `msg.value` and 6dp through the USDT0
     *      ERC-20, and the mismatch rendered an $80 listing as $0.00 in
     *      production. Nothing is assumed: we read it, and a feed that does not
     *      implement `decimals()` fails the wiring transaction rather than the
     *      first mint.
     *
     *      The stablecoin's `decimals()` read is gone with the stablecoin
     *      (`DECISIONS.md §26`) — but the FEED's is not, and neither is
     *      `Marketplace`'s BNBULL read. The rule survives the asset.
     */
    function _afterWire(Wire slot, address target) private {
        if (slot == Wire.PriceFeed) {
            uint8 d = AggregatorV3Interface(target).decimals();
            if (d > 36) revert FeedDecimalsUnusable(d);
            feedDecimals = d;
        }
    }

    /// @notice Every live wiring address in one call — the read the deploy
    ///         preflight and the keepers use. `wireOf` adds the pending target
    ///         and its ETA for a single slot.
    function wires()
        external
        view
        returns (address priceFeed, address router, address jackpotBnbull, address jackpotBnb)
    {
        return (
            _wire(Wire.PriceFeed),
            _wire(Wire.Router),
            _wire(Wire.JackpotBnbull),
            _wire(Wire.JackpotBnb)
        );
    }

    function _wire(Wire slot) private view returns (address) {
        return _wires[uint8(slot)].current;
    }

    // ─── Rescue, bounded by what the pots have a claim on ────────────────

    /// @notice BNBULL this contract may spend on airdrops or hand back. Never
    ///         includes BNBULL that has already been earmarked for a pot.
    function freeBnbull() external view returns (uint256) {
        return _freeBnbull();
    }

    function _freeBnbull() private view returns (uint256) {
        uint256 bal = bnbull.balanceOf(address(this));
        uint256 reserved = pendingBnbullDirect + pendingBnbPotBnbull;
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice BNB held here that no pot leg has a claim on. Should read zero
    ///         in steady state: every BNB path routes or accrues to the wei,
    ///         and there is no `receive()`, so the only way this goes non-zero
    ///         is a forced `selfdestruct` transfer. There is deliberately NO
    ///         native rescue — less owner power over BNB, and nothing
    ///         legitimate ever lands here to rescue.
    function freeNative() external view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 reserved = pendingBnbullBuyNative + pendingBnbPotNative;
        return bal > reserved ? bal - reserved : 0;
    }

    /**
     * @notice Recover a token sent here by mistake. Refuses to touch anything
     *         a pot leg has already been credited with — that money is spoken
     *         for, and `withdrawPendingForManualBuy` is the only door it may
     *         leave by.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        uint256 free = token == address(bnbull)
            ? _freeBnbull()
            : IERC20(token).balanceOf(address(this));
        if (amount > free) revert ReservedForPots(amount, free);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ─── Maths ───────────────────────────────────────────────────────────

    /// @dev Apply the per-asset discount. Applied EXACTLY ONCE, here — see the
    ///      double-discount note in the header.
    function _discounted(uint256 amount, address asset) private view returns (uint256) {
        uint16 bps = discountBpsOf[asset];
        if (bps == 0) return amount;
        return (amount * (BPS - bps)) / BPS;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
