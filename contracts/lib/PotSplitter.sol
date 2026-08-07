// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAddress} from "./TimelockedAddress.sol";

/// @dev Minimal `Jackpot` surface. `fund` pulls the prize token from the
///      caller, who must hold the funder role — an owner call ON THE POT,
///      granted separately, never from here.
interface IJackpotFund {
    function fund(uint256 amount, string calldata source) external;
}

/// @dev Wrapped BNB (0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c). `deposit` is
///      1:1 and has no liquidity dependency — it is a wrap, not a swap, which
///      is why funding the WBNB pot out of a BNB payment touches no DEX at all
///      (`DECISIONS.md §13`).
interface IWBNB is IERC20 {
    function deposit() external payable;
}

/**
 * @dev PancakeSwap **v2** router (0x10ED43C718714eb63d5aA57B78B54704E256024E).
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY V2, AND WHY THE v3 DIALECT IS GONE — `DECISIONS.md §28`
 *      ══════════════════════════════════════════════════════════════════════
 *      four.meme graduates into PancakeSwap **V2 against WBNB** and creates
 *      **NO v3 pool at any fee tier.** Verified by executing three complete
 *      graduations on mainnet forks plus reading two live graduates; the LP is
 *      100% burned to `0x…dEaD`.
 *
 *      So the v3-only leg this contract used to carry could never reach the
 *      real book. The only thing it COULD ever find is somebody else's decoy,
 *      and that is measured, not hypothetical: a v3 1% pool seeded with 0.01
 *      BNB by a random EOA quoted 112,244 tokens for 1 BNB against 10,704,225
 *      in the real v2 pool — **95x worse, silently.** `ISwapRouterV3`,
 *      `ExactInputSingleParams`, `wbnbBnbullPoolFee`, `setPoolFees` and
 *      `MAX_POOL_FEE` are all gone with it: **v2 has no fee tiers**, and a
 *      dial that selects a pool is a dial that can select the wrong pool.
 *
 *      ⚠ THE SWAP IS THE **FEE-SUPPORTING** VARIANT, DELIBERATELY —
 *      `DECISIONS.md §30`. four.meme template B carries a creator-set buy AND
 *      sell tax (measured -10%), and a plain `swapExactTokensForTokens` on such
 *      a token reverts `Pancake: K`. `…SupportingFeeOnTransferTokens` is the
 *      only call that survives BOTH templates, so we are safe whichever launch
 *      form the token ends up on rather than betting on one. It returns
 *      NOTHING, which suits us exactly: every swap here is already booked as a
 *      measured balance delta and the router's word was never trusted anyway.
 *
 *      ⚠ THE FACTORY IS DERIVED FROM THE ROUTER, NOT WIRED SEPARATELY.
 *      `factory()` is authoritative and cannot disagree with the router we are
 *      about to trade on. A second wire is one more thing to mis-set and one
 *      more way to price off a different book than the one the swap hits —
 *      which is the `BNB-CHAIN-FACTS.md §3` decoy bug in a new costume.
 *
 *      ⚠ Every remaining swap has WBNB on one side (`DECISIONS.md §26` dropped
 *      the stablecoin, collapsing the old two-hop path), so every one of them
 *      is a SINGLE v2 hop through the ONE canonical WBNB/BNBULL pair — **unless
 *      `Wire.SwapIntermediate` is wired**, in which case it is two hops through
 *      WBNB/X and X/BNBULL. See `swapIntermediate` for why that dial exists and
 *      why it is dormant by default. The router's `path` is an arbitrary-length
 *      array and always was; nothing else about this call changes.
 */
interface IPancakeRouter02 {
    /// @notice The v2 factory this router routes through. Authoritative.
    function factory() external view returns (address);

    /// @dev Returns nothing. See the fee-supporting note above.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @dev PancakeSwap v2 factory. ONE canonical pair per token pair — there is no
///      "which pair is real" ambiguity on v2, which is why the floor below only
///      has to ask one question.
interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @dev The canonical v2 pair. `token0()` is read rather than derived from
///      address ordering: the pair is the authority on its own reserve order.
interface IPancakePair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

/// @dev The pot-routing policy this splitter mirrors, read live off `MintDrop`
///      so `DECISIONS.md §13`/`§14` has exactly ONE source of truth on chain.
///      Every getter here is a public variable on `MintDrop`.
interface IMintDropPolicy {
    function bnbullShareBps() external view returns (uint256);
    function bnbShareBps() external view returns (uint256);
    function bnbullPaymentSellsForBnbLeg() external view returns (bool);
}

/**
 * @title PotSplitter
 * @notice The shared never-fail core behind `MintBnbullSplitter` and
 *         `ReviveBuySplitter`: take money in either of the game's two payment
 *         currencies — BNB or BNBULL — push the pot slices into the two
 *         no-withdraw pots, and — above all — **never revert**.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE #1 RULE: THE ENTRYPOINTS MUST NEVER REVERT
 *      ══════════════════════════════════════════════════════════════════════
 *      An entrypoint that an upstream contract calls with NO try/catch on the
 *      caller's side bricks that caller forever if it reverts
 *      (`BNBULLS-BOOTSTRAP.md §6`). Two live examples in this codebase:
 *
 *        - `MintDrop._routeNative` forwards the LP slice with a bare
 *          `lpTreasury.call{value: lpShare}("")` and does `if (!ok) revert
 *          LpTransferFailed()`. Point `lpTreasury` at `MintBnbullSplitter` and
 *          that call lands in its `receive()`. **If that `receive()` reverts,
 *          every native mint bricks.**
 *
 *        - `Graveyard` donates the revive pot slice to its `mintDrop` slot with
 *          an un-guarded value call. Point that slot at `ReviveBuySplitter` and
 *          the call lands in `donatePotNative()`. **If that reverts, every
 *          revive in the game bricks.**
 *
 *      So the mechanism, identically on every leg:
 *        1. a cheap pre-check (`_bnbullLegReady` / `_bnbLegReady`) so a
 *           pre-launch payment does not pay gas for a try/catch that cannot
 *           possibly work;
 *        2. `try this.routeTo…Inline(src, amount) { emit …Inline; return; }
 *           catch { fall through }`. The inline worker is `external`
 *           ONLY so this contract can try/catch its own call, and is gated by
 *           `if (msg.sender != address(this)) revert NotSelf();` so it is not a
 *           way for anyone else to spend this contract's balance;
 *        3. on any failure it **accrues** — `pending… += amount; emit
 *           …Deferred(...)` — and returns normally. A keeper spends the bucket
 *           later through `sweepBnbullPot` / `sweepBnbPot` with an OFF-CHAIN
 *           quoted floor, and the owner has an escape hatch on top. **Nothing
 *           on this path can revert:** it is storage writes and events.
 *
 *      Every state change made inside a caught call is rolled back with it, so
 *      a swap that reverts after its WBNB wrap leaves the accrued BNB genuinely
 *      backed by balance. The buckets and the balances stay consistent.
 *
 *      ⚠ THE ONE THING TRY/CATCH DOES NOT COVER is a callee that BURNS the
 *      caller's gas rather than reverting: an out-of-gas sub-call leaves only
 *      1/64 of the frame, which is not enough to finish the accrual. Two places
 *      touch code we do not fully control, and they are handled differently:
 *        - the live policy read off `MintDrop` is capped at `POLICY_READ_GAS`,
 *          because it is a three-SLOAD view and a cap costs nothing;
 *        - the inline swap leg is NOT capped, deliberately. A real v2 swap plus
 *          a pot funding is a few hundred thousand gas and the honest figure
 *          moves with the route, so a cap tight enough to protect the frame
 *          would defer legitimate buys on ordinary mints. This matches
 *          `MintDrop`'s own inline legs, which are exposed to the same BNBULL
 *          token; if BNBULL ever turns out to burn unbounded gas on transfer,
 *          that is a token-level emergency for the whole economy, not a
 *          splitter-level one, and `setFloors(0,0,0,0)` disables every inline
 *          swap here in one transaction.
 *
 *      ⚠ NOTE WHAT IS *NOT* ON THE ENTRYPOINTS: `nonReentrant`. The fefers
 *      splitters put it on `receive()` / `donateJackpotBuy()`, which is a
 *      latent brick — `ReentrancyGuard` REVERTS, and a reverting modifier on a
 *      never-fail entrypoint is exactly the failure the pattern exists to
 *      prevent. The entrypoints are safe without it because each one handles
 *      only the value delivered to that call and accrues with `+=`, so a
 *      re-entrant delivery can neither double-count nor double-spend. The
 *      keeper and owner paths, which do move existing balances, keep the guard.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      SWAPS ARE A MEASURED BALANCE DELTA, AND A ZERO FLOOR IS REFUSED
 *      ══════════════════════════════════════════════════════════════════════
 *      What gets booked into a pot is `token.balanceOf` after minus before,
 *      re-checked against `minOut`. The router's reported output is never
 *      trusted: a fee-on-transfer token or a lying router would otherwise wedge
 *      the pot forever. The fee-supporting v2 call returns nothing at all, so
 *      there is no reported output left to be tempted by. And `minOut == 0` is
 *      refused outright as a blind swap — a swap with no floor is a free
 *      sandwich, and a dead pool is exactly when the correct answer is to defer
 *      rather than trade.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      AND THE POOL MUST BE REAL BEFORE WE TRADE INTO IT
 *      ══════════════════════════════════════════════════════════════════════
 *      `minPoolLiquidity` is a hard floor on the **WBNB-side reserve** of the
 *      canonical WBNB/BNBULL v2 pair, read off the factory the router itself
 *      names. Under it — or with no pair at all — the leg **defers and
 *      accrues**; it never trades and it never reverts an entrypoint.
 *
 *      v2 has ONE canonical pair per token pair, so this is not the "which pool
 *      is real" question v3 posed. It closes a different window, and two of
 *      them:
 *        - **pre-graduation**, when anybody can `createPair(BNBULL, WBNB)` and
 *          front-run the pair into existence with dust. They cannot seed BNBULL
 *          into it (the transfer gate, `§28.1`), but they can donate WBNB, and
 *          a pair that exists is a pair a naive leg will trade against;
 *        - it is also what makes the ENTIRE curve phase *deliberately* deferred
 *          rather than accidentally so (`§29`). Launch is BNB-first and the
 *          BNBULL legs are expected to accrue until the curve completes. That
 *          is the normal launch state, not an error state, and this is the line
 *          that states it in code.
 *
 *      Denominated in **WBNB, never in BNBULL** — a decoy can print its own
 *      token, it cannot print BNB.
 *
 *      ⚠ AND IT FOLLOWS THE ROUTE. `Wire.SwapIntermediate` (dormant, see
 *      `swapIntermediate`) changes which asset BNBULL is paired against, and
 *      the floor moves with it onto the X/BNBULL pair — where the reserve is
 *      denominated in **X, not WBNB**. That is why there are TWO floors and
 *      not one shared number: `minPoolLiquidityAlt` carries the X-denominated
 *      one, and an unset one refuses the trade instead of comparing a USDT
 *      reserve against a figure that means 1 BNB. Mismatched units that look
 *      alike is the bug class this project has been bitten by twice.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE FLOORS ARE QUOTED OFF CHAIN, AND A STALE ONE DEFERS
 *      ══════════════════════════════════════════════════════════════════════
 *      The inline floors are keeper-published rates, re-pegged as BNBULL
 *      drifts — the job `fight-price-keeper.mjs` did on fefers.
 *
 *      ⚠ THEY STAYED OFF CHAIN AFTER THE MOVE TO V2, DELIBERATELY. v2 does
 *      have a cheap on-chain quote (`getAmountsOut`) and using it would be the
 *      obvious simplification. It is also not a slippage guard: quoting the
 *      very reserves the swap is about to hit, in the same call, with no state
 *      change in between, means a front-run moves the reserves BEFORE the quote
 *      and the quote is simply taken at the attacker's price. A published floor
 *      is the one bound a same-block front-run cannot move, and it is
 *      venue-independent — it came through this change untouched, which is
 *      itself the argument for it. Three things follow:
 *
 *        - a rate of ZERO disables its leg: the pre-check fails and the slice
 *          defers. Never a blind swap;
 *        - the rates carry ONE timestamp and `maxFloorAge`. Past that age they
 *          are treated as absent, so a dead keeper degrades to "everything
 *          accrues" — visibly, on chain, in the `…Deferred` events — instead of
 *          quietly trading against a week-old price;
 *        - a floor that is stale in the OTHER direction (too high for the
 *          current market) simply makes the swap miss `amountOutMinimum`; the
 *          revert is caught and the slice accrues. **A stale floor always
 *          defers safely and never bricks.**
 *
 *      ⛔ AND THE KEEPER'S PRICE IS LEASHED, BECAUSE AN UNBOUNDED KEEPER PRICE
 *      IS AN UNBOUNDED KEEPER THEFT. `DECISIONS.md §42` gave the keeper its own
 *      least-privileged key on the written grounds that "every keeper setter is
 *      bounded by a constant a compromised key cannot exceed". `setFloors` was
 *      not, and the sweeps' `minOut` override replaced the floor outright, so
 *      the sentence was false in both directions: a stolen keeper key could
 *      publish a rate of 1 wei and convert an entire accrued bucket to dust
 *      through a sandwich, in one transaction, with no owner key involved.
 *
 *      A constant could not fix it — a floor is a market price and MUST follow
 *      the market, and any number written at deploy time is either a rug or a
 *      permanent outage a year later. The bound is therefore on the RATE OF
 *      CHANGE and on the DIRECTION, which are the two things that can be
 *      bounded without knowing what BNBULL is worth:
 *
 *        - raising a floor, and killing one, stay free: both only ever cause
 *          deferral, which is this contract's safe state;
 *        - lowering one is capped per step and per hour (`keeperFloorDropBps`,
 *          `keeperFloorDropGap`), and arming a dead leg is owner-only;
 *        - a sweep's `minOut` may tighten the published floor and never loosen
 *          it (`_requireKeeperFloor`), which also caps how much of a bucket one
 *          sweep can move — price impact does that arithmetic for us.
 *
 *      The owner is exempt from all of it and keeps its one-transaction
 *      correction, because it already holds `withdrawPendingForManualBuy` and
 *      bounding a price it can route around would bound nothing.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      RULE 1: NO 1e12, NO DUAL VIEW, EVERY DIVISOR RE-DERIVED
 *      ══════════════════════════════════════════════════════════════════════
 *      The fefers splitters were built on `NATIVE_TO_ERC20 = 1e12` — on Stable
 *      the native gas token and the USDT0 ERC-20 were the same balance at two
 *      precisions, so a contract holding `x` native wei could approve the
 *      router for `x / 1e12` USDT0 and the swap drained native. **That identity
 *      does not exist on BNB Chain and the constant is gone.** Here:
 *
 *        - BNB is 18 dp, always, and never a dollar. Holding BNB gives this
 *          contract no ERC-20 balance whatsoever, so the BNB->BNBULL leg
 *          genuinely wraps to WBNB first and then swaps a token it holds;
 *        - BNBULL's decimals are READ from `decimals()` when it is wired and
 *          never assumed — it is launchpad-issued (`DECISIONS.md §4`), so
 *          "BEP-20s are usually 18" is not evidence. Dropping the stablecoin
 *          (`§26`) removed the OTHER token whose decimals mattered; it did NOT
 *          relax the rule for the one that is left;
 *        - every floor rate is denominated per ONE WHOLE unit of its input
 *          token and divided by `10**decimals(input)` — read, not assumed. The
 *          BNB rate divides by 1e18 because native being 18 dp is a chain fact,
 *          not a token property.
 *        - there is no sub-1e12 dust concept, because there is no truncating
 *          6-dp interface to lose it in.
 */
abstract contract PotSplitter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── True security ceilings ──────────────────────────────────────────

    /// @notice Ceiling on the fallback pot shares, matching
    ///         `MintDrop.MAX_TOTAL_POT_BPS`. A live policy read that exceeds it
    ///         is rejected in favour of the local fallback.
    uint256 public constant MAX_TOTAL_POT_BPS = 5_000;
    /// @notice Ceiling on how stale the keeper's swap floors may be and still
    ///         authorise an inline swap.
    uint256 public constant MAX_FLOOR_AGE = 7 days;
    /// @notice Ceiling on how far a KEEPER may lower a published floor in one
    ///         step. Past half, one step stops being a repeg and becomes a rug.
    uint256 public constant MAX_KEEPER_FLOOR_DROP_BPS = 5_000;
    /// @notice Floor on the gap between two keeper floor DROPS.
    ///
    /// @dev ⛔ THE GAP IS WHAT MAKES THE STEP CAP A BOUND AT ALL. A per-step
    ///      percentage on its own is not a leash: the same key just sends the
    ///      step a thousand times in one block and arrives at dust anyway. The
    ///      cap bounds the SIZE of a move, the gap bounds its SPEED, and only
    ///      the two together bound the distance a stolen key can travel.
    uint256 public constant MIN_KEEPER_FLOOR_DROP_GAP = 15 minutes;
    /// @notice Ceiling on the minimum-liquidity floor. A floor set absurdly
    ///         high would defer every leg forever — safe, but silently, which
    ///         is the failure mode this whole file is written against.
    uint256 public constant MAX_MIN_POOL_LIQUIDITY = 10_000 ether;
    /// @notice Any wired token reporting more decimals than this is refused at
    ///         wiring time.
    uint8 public constant MAX_TOKEN_DECIMALS = 36;
    /// @notice Wiring timelock bounds.
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;
    /// @notice Gas ceiling on the live policy read off `MintDrop`. See
    ///         `potPolicy` — this cap is what stops a wedged or hostile policy
    ///         source from starving a never-fail entrypoint of gas.
    uint256 private constant POLICY_READ_GAS = 100_000;

    uint256 internal constant BPS = 10_000;

    // ─── Immutable ───────────────────────────────────────────────────────

    /// @notice Wrapped BNB. The WBNB pot's prize token, and the first hop of
    ///         every swap out of BNB.
    IWBNB public immutable wbnb;

    // ─── Timelocked wiring ───────────────────────────────────────────────

    /// @dev Every slot here can redirect money or distort the split if it is
    ///      repointed, so every one is bootstrap-once-then-timelocked. `keeper`
    ///      is not: it can only push money INTO a pot.
    ///
    /// ⚠ RENUMBERED BY `DECISIONS.md §26`. `Stablecoin` used to be slot 0 and
    ///   every member below it has shifted DOWN by one. The hole was NOT kept
    ///   reserved: nothing is deployed yet, and a reserved slot preserves
    ///   exactly the thing the decision deletes. Deploy scripts and any tooling
    ///   that passes a raw uint8 must be re-checked against this list.
    enum Wire {
        /// The BNBULL token. A wire rather than an immutable because
        /// four.meme issues it and it may not exist at deploy time.
        Bnbull,
        /// PancakeSwap **v2** router. Its `factory()` is where the pair — and
        /// therefore the liquidity floor — is read from, so there is exactly
        /// one venue wire and it cannot disagree with itself.
        Router,
        /// The BNBULL-prize Jackpot (1 in 50). This contract must be granted
        /// its funder role — an owner call ON THE POT.
        JackpotBnbull,
        /// The WBNB-prize Jackpot (1 in 100). Same funder role requirement.
        JackpotBnb,
        /// `MintDrop`, read live for the pot-routing policy (`§13`/`§14`).
        /// Zero, or any read that fails or returns nonsense, falls back to the
        /// local shares below.
        MintDrop,
        /// ⚠ THE DORMANT ONE. Optional middle hop for every swap, so a BNBULL
        /// that graduates against something other than WBNB is still reachable.
        /// **Zero at deploy and expected to stay zero forever** — see
        /// `swapIntermediate`. APPENDED, so slots 0..4 keep their numbers and
        /// nothing already written against this enum moves.
        SwapIntermediate
    }

    mapping(uint8 => TimelockedAddress.Slot) private _wires;

    /// @notice Delay a wiring change must age before it can be committed.
    uint256 public wiringDelay = 24 hours;

    /// @notice `decimals()` read off the wired BNBULL token. NEVER assumed.
    uint8 public bnbullDecimals;

    // ─── Pot routing policy (mirrors DECISIONS §13 + §14) ────────────────

    /// @notice Used when `MintDrop` is unwired or its read fails. Kept in sync
    ///         with the launch policy so a fallback is never a surprise.
    uint256 public fallbackBnbullShareBps = 2_000;
    uint256 public fallbackBnbShareBps = 1_000;
    /// @notice `DECISIONS.md §14`: **never sell BNBULL.** A BNBULL payment
    ///         routes 30% BNBULL pot / 70% dev and touches no DEX. This is the
    ///         DEFAULT, not a post-deploy toggle — if the configuration tx is
    ///         ever forgotten, the safe behaviour is the one that happens
    ///         anyway. Mirrors `MintDrop.bnbullPaymentSellsForBnbLeg`, which
    ///         defaults `false` for the same reason.
    bool public fallbackSellsForBnbLeg = false;

    // ─── The minimum-liquidity floor ─────────────────────────────────────

    /**
     * @notice Smallest **WBNB-side reserve** the canonical WBNB/BNBULL v2 pair
     *         may hold and still be traded against. Below it, every swap leg
     *         defers and accrues.
     *
     * @dev Denominated in WBNB on purpose: a decoy can mint an unlimited supply
     *      of its own token, so a BNBULL-side floor measures nothing. It cannot
     *      mint BNB.
     *
     *      A bounded owner-settable variable rather than a `constant`
     *      (`BNBULLS-BOOTSTRAP.md §0`): the right number depends on the size of
     *      the raise the token graduates with, which is not knowable at deploy
     *      time. The graduation opening reserve measured on three mainnet-fork
     *      graduations was **17.64 WBNB**; the demonstrated decoy was **0.01
     *      WBNB**. The 1 BNB default sits between them by more than two orders
     *      of magnitude in each direction.
     *
     *      ⚠ ZERO IS REFUSED. A zero floor re-opens the exact hole this exists
     *      to close, and there is already a kill switch that does the safe
     *      thing instead: `setFloors(0, 0)` disables every inline swap and
     *      defers, which is what "stop trading" is supposed to look like here.
     */
    uint256 public minPoolLiquidity = 1 ether;

    /**
     * @notice The SAME floor, for the case where BNBULL is **not** paired
     *         against WBNB — denominated in whatever `swapIntermediate` is.
     *
     * @dev ⚠⚠ THIS EXISTS BECAUSE OF A UNIT MISMATCH, AND THE MISMATCH IS THE
     *      WHOLE REASON IT IS A SECOND VARIABLE RATHER THAN A REUSE.
     *
     *      `minPoolLiquidity` is **1 ether, meaning 1 BNB**. The pool the floor
     *      guards is always the BNBULL pair — `getPair(quote, BNBULL)` — and
     *      the reserve it reads is denominated in `quote`. Wire a USDT
     *      intermediate and that reserve is USDT. Comparing a USDT reserve
     *      against a number that means "1 BNB" is `BNB-CHAIN-FACTS.md §3` and
     *      the fefers decimals trap in a third costume: two numbers that look
     *      alike, mean different things, and silently pass.
     *
     *      So the floor is denominated in the quote asset, one variable per
     *      denomination, and **the two are never interchanged**:
     *
     *        - no intermediate (the default, forever, we hope) -> the pair is
     *          WBNB/BNBULL, the reserve is WBNB, `minPoolLiquidity` applies.
     *          Byte for byte the behaviour that shipped;
     *        - an intermediate X -> the pair is X/BNBULL, the reserve is X, and
     *          **this** number applies, in X's own smallest unit. ⚠ READ X's
     *          `decimals()` YOURSELF before setting it: this contract never
     *          divides by them, so it cannot catch a wrong one for you.
     *
     *      ⚠ ZERO MEANS "REFUSE TO TRADE", NOT "NO FLOOR". A wired intermediate
     *      with this left at zero makes every swap leg revert `InvalidMinLiquidity(0)`
     *      — which the inline paths catch and turn into an accrual, and the
     *      sweeps report loudly. That is deliberate: the failure mode of
     *      forgetting to set it is "everything defers", visibly, never "trade
     *      against an unmeasured pool". It is also the kill switch for the
     *      alternate route.
     */
    uint256 public minPoolLiquidityAlt;

    // ─── Keeper-published swap floors ────────────────────────────────────

    /// @notice BNBULL wei expected per 1 BNB (1e18 wei) in.
    uint256 public bnbullPerBnb;
    /// @notice WBNB wei expected per ONE WHOLE BNBULL unit in. Only reachable
    ///         when the sell-BNBULL policy is switched on (`§14` keeps it off).
    uint256 public wbnbPerBnbull;
    /// @notice When the two rates above were last published.
    uint64 public floorsUpdatedAt;
    /// @notice Past this age the rates are treated as absent and every swap
    ///         leg defers. See the header.
    uint256 public maxFloorAge = 12 hours;

    /**
     * @notice Most a KEEPER may cut off a published floor in a single step,
     *         and the minimum wall-clock gap between two such cuts.
     *
     * @dev ⛔ THIS PAIR IS THE LEASH. `setFloors` is keeper-callable because a
     *      floor is a market price and has to move with the market — but an
     *      UNBOUNDED keeper price is an unbounded keeper theft, because the
     *      published rate is the only thing standing between an inline swap and
     *      a sandwich. A rate of 1 wei plus one payment is the whole attack.
     *
     *      A fixed constant is the wrong shape here, and that is the reason
     *      this took a variable rather than a `MIN_BNBULL_PER_BNB`: nobody
     *      knows what BNBULL is worth at deploy time, and any number written
     *      today is either a rug (too low) or a permanent outage (too high) a
     *      year from now. What CAN be bounded without knowing the price is how
     *      fast the number is allowed to fall. So the leash is on the
     *      DERIVATIVE, not the value:
     *
     *        - a RAISE is free. A higher floor is a stricter floor; the worst
     *          it can do is make swaps miss `minOut` and defer, which is this
     *          contract's safe state and already its documented behaviour;
     *        - a ZERO is free. That is the kill switch — it disables the leg
     *          and everything accrues. Also safe;
     *        - a DROP is capped at `keeperFloorDropBps` and may not repeat
     *          inside `keeperFloorDropGap`;
     *        - ARMING a leg from zero is OWNER-ONLY (see `_isKeeperDrop`).
     *
     *      ⚠ WHAT THIS BUYS, STATED HONESTLY. It does not make a stolen keeper
     *      key harmless. It converts "one transaction, whole pot, any price"
     *      into a monotonic walk that at the launch settings needs ~16 steps
     *      over ~16 hours to reach 1% of the market — every step a
     *      `FloorsPublished` event, on chain, in order, while `PotSwept` and
     *      the `…FundedInline` events show what it is costing. That is the
     *      difference between a theft and an alarm.
     *
     *      ⚠ THE OWNER IS EXEMPT, DELIBERATELY, AND IT IS NOT A HOLE.
     *      `BNBULLS-BOOTSTRAP.md §0` requires the owner keep a way to make a
     *      large legitimate correction — a real 60% move in an hour is a
     *      Tuesday for a launchpad token, and the keeper's own repeg trigger is
     *      20% drift. More to the point the owner already holds
     *      `withdrawPendingForManualBuy`, which takes the whole bucket out in
     *      one call: leashing the owner's price would bound nothing it does not
     *      already outrank. The leash exists to make `DECISIONS.md §42` true of
     *      the KEEPER key, which is the one living unattended in a container.
     *
     *      Launch values: 25% per step, one step an hour. The step sits above
     *      the floor-keeper's own 20% repeg trigger (`FLOOR_DRIFT_PCT`) so a
     *      normal repeg is never refused, and the gap sits above its 30-minute
     *      minimum interval (`FLOOR_MIN_INTERVAL_MIN`) so a normal cadence is
     *      never refused either. Both are owner-settable within the ceilings
     *      above, per `§0`.
     *
     *      ⚠ `keeperFloorDropBps == 0` IS LEGAL AND IS THE STRICTEST SETTING:
     *      the keeper may then raise or kill a floor but never lower one, so a
     *      falling market simply defers until the owner repegs. Costs
     *      availability, costs nothing else.
     */
    uint256 public keeperFloorDropBps = 2_500;
    uint256 public keeperFloorDropGap = 1 hours;

    /// @notice When a keeper last LOWERED a floor. Zero until it happens, so
    ///         the first drop after deploy is never blocked by a gap that has
    ///         no start.
    uint64 public floorsDroppedAt;

    /// @notice May publish floors and run the sweeps, alongside the owner.
    address public keeper;

    // ─── Deferred legs (the never-fail fallback) ─────────────────────────

    /// @notice BNB set aside because a BNB -> BNBULL buy could not run.
    uint256 public pendingBnbullBuyNative;
    /// @notice BNBULL set aside because the BNBULL pot could not be funded.
    uint256 public pendingBnbullDirect;
    /// @notice BNB set aside because the WBNB pot could not be funded.
    uint256 public pendingBnbPotNative;
    /// @notice BNBULL set aside because a BNBULL -> WBNB swap could not run.
    uint256 public pendingBnbPotBnbull;

    /// @notice Which asset a leg is denominated in. Mirrors `MintDrop.PotSource`.
    /// @dev ⚠ RENUMBERED BY `DECISIONS.md §26`: `Stable` was 1 and `Bnbull` has
    ///      moved 2 -> 1. This enum is an ARGUMENT to `sweepBnbullPot`,
    ///      `sweepBnbPot`, `routeHeld`, `withdrawUnreserved` and
    ///      `withdrawPendingForManualBuy`, and it is INDEXED in the events, so
    ///      keepers and indexers must be updated together with this.
    enum PotSource {
        Native,
        Bnbull
    }

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    /// @notice A pot leg completed inside the payer's own transaction. The
    ///         normal case.
    event BnbullPotFundedInline(PotSource indexed src, uint256 spent, uint256 funded);
    event BnbPotFundedInline(PotSource indexed src, uint256 spent, uint256 funded);
    /// @notice A pot leg could not run (no route wired, stale or absent floor,
    ///         thin or dead pool, router revert, funder role not granted), so
    ///         it accrued instead. The exception, on chain, so nobody has to
    ///         take our word for which one is happening in production.
    event BnbullPotDeferred(PotSource indexed src, uint256 amount, uint256 bucketTotal);
    event BnbPotDeferred(PotSource indexed src, uint256 amount, uint256 bucketTotal);
    /// @notice The share of an incoming payment this contract did NOT route to
    ///         a pot. It stays as balance for `withdrawUnreserved`.
    event Retained(PotSource indexed src, uint256 amount);
    event PotSwept(bool indexed toBnbullPot, PotSource src, uint256 spent, uint256 funded);
    event HeldRouted(PotSource indexed src, uint256 amount);
    event PendingWithdrawnForManualBuy(PotSource src, bool bnbullPot, address to, uint256 amount);
    event UnreservedWithdrawn(PotSource src, address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    event FallbackPolicyChanged(uint256 bnbullBps, uint256 bnbBps, bool sellsForBnbLeg);
    event MinPoolLiquidityChanged(uint256 minWbnbReserve);
    event MinPoolLiquidityAltChanged(uint256 minQuoteReserve);
    event FloorsPublished(uint256 bnbullPerBnb, uint256 wbnbPerBnbull, uint64 at);
    event MaxFloorAgeChanged(uint256 maxAge);
    event KeeperFloorLeashChanged(uint256 dropBps, uint256 gap);
    event KeeperChanged(address indexed previous, address indexed next);
    event WireBootstrapped(Wire indexed slot, address indexed target);
    event WireProposed(Wire indexed slot, address indexed target, uint64 eta);
    event WireCommitted(Wire indexed slot, address indexed previous, address indexed next);
    event WireCancelled(Wire indexed slot, address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event SocialsChanged(string website, string twitter, string telegram);

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotSelf();
    error NotKeeperOrOwner();
    error PotNotWired();
    error RouteNotWired();
    error BnbullNotWired();
    error BlindSwapRefused();
    error SwapOutBelowMin(uint256 received, uint256 minimum);
    /// @notice The BNBULL pair holds less of its quote asset than the floor for
    ///         that quote asset, or does not exist at all. Always caught on the
    ///         inline paths, where it becomes an accrual.
    error PoolTooThin(uint256 wbnbReserve, uint256 minimum);
    /// @dev The wired `SwapIntermediate` is the BNBULL token itself, which
    ///      would build a path with a self-pair hop in it.
    error BadIntermediate(address target);
    error NothingToDo();
    error InsufficientPending(uint256 requested, uint256 available);
    error InsufficientFree(uint256 requested, uint256 available);
    error InvalidShare(uint256 bps);
    error InvalidMinLiquidity(uint256 requested);
    error InvalidFloorAge(uint256 maxAge);
    /// @notice A keeper tried to cut more than `keeperFloorDropBps` off a
    ///         published floor in one step.
    error FloorDropTooLarge(uint256 requested, uint256 lowest);
    /// @notice A keeper tried to cut a floor again before `keeperFloorDropGap`
    ///         had elapsed. The gap is what turns the step cap into a distance.
    error FloorDropTooSoon(uint256 nextAllowedAt);
    /// @notice A keeper tried to bring a DISABLED leg (rate 0) back to life.
    ///         Turning a swap leg on is an owner act — see `_isKeeperDrop`.
    error FloorArmingIsOwnerOnly();
    /// @notice A keeper sweep with no fresh published floor to be measured
    ///         against. The money stays in its bucket; the owner can still act.
    error FloorsStale();
    /// @notice A keeper sweep asked to sell BELOW the floor it published
    ///         itself. The keeper may tighten a floor, never loosen one.
    error SweepFloorBelowPublished(uint256 minOut, uint256 published);
    error InvalidFloorLeash(uint256 dropBps, uint256 gap);
    error DelayOutOfRange(uint256 requested);
    error TokenDecimalsUnusable(uint8 decimals_);
    error NativeSendFailed();

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address initialOwner, address _wbnb, address _keeper) Ownable(initialOwner) {
        if (_wbnb == address(0)) revert ZeroAddress();
        wbnb = IWBNB(_wbnb);
        keeper = _keeper;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The split rule. Each concrete splitter supplies its own.
    // ══════════════════════════════════════════════════════════════════════

    /// @dev MUST NOT REVERT. Called straight from a never-fail entrypoint.
    function _route(PotSource src, uint256 amount) internal virtual;

    /**
     * @notice Apply this splitter's routing rule to money already sitting here
     *         — the ERC-20 slices that arrive by plain `transfer` with no
     *         callback to notice them (`MintDrop._routeToken` forwards its LP
     *         slice exactly that way), or native left over from a deferral the
     *         operator wants re-attempted.
     * @param amount 0 routes the whole unreserved balance of that asset.
     * @dev Keeper/owner gated so the operator, not a passer-by, chooses when to
     *      trade. Bounded by the unreserved balance, so it can never spend
     *      money a pot bucket already has a claim on.
     */
    function routeHeld(PotSource src, uint256 amount)
        external
        onlyKeeperOrOwner
        nonReentrant
    {
        uint256 free = freeOf(src);
        uint256 take = amount == 0 ? free : amount;
        if (take == 0) revert NothingToDo();
        if (take > free) revert InsufficientFree(take, free);
        _route(src, take);
        emit HeldRouted(src, take);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The pot-routing policy, read live off MintDrop (DECISIONS §13 + §14)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The live policy: BNBULL share, BNB share, and whether a BNBULL
     *         payment sells for the BNB leg.
     * @dev NEVER REVERTS. Reads `MintDrop` so the split has one source of truth
     *      on chain rather than a constant duplicated across three contracts;
     *      falls back to the local shares if that slot is unwired, the call
     *      fails, or the answer is out of bounds.
     */
    function potPolicy() public view returns (uint256 bnbullBps, uint256 bnbBps, bool sells) {
        if (_wire(Wire.MintDrop) != address(0)) {
            // ⚠ THE GAS CAP IS LOAD-BEARING. This read sits inside a never-fail
            // entrypoint, and try/catch protects against a revert but NOT
            // against a callee that burns the caller's gas — an OOG in the
            // sub-call leaves 1/64 of the frame, which is not enough to finish
            // the accrual, and the entrypoint dies. Three SLOADs behind a
            // staticcall cost well under 15k; the cap is generous and still
            // leaves the outer frame intact whatever the target does.
            try this.readMintDropPolicy{gas: POLICY_READ_GAS}() returns (
                uint256 a, uint256 b, bool s
            ) {
                // ⚠ BOUND EACH SHARE BEFORE ADDING THEM.
                //
                // This success block runs in THIS frame, not the callee's, so a
                // checked `a + b` that overflows panics HERE — past the catch,
                // which cannot see it. A policy source answering with two shares
                // summing above 2^256 would then brick `potPolicy` -> `_route`
                // -> `receive()`: the exact never-fail brick this pattern
                // exists to prevent, on every native mint through the LP slot
                // and every revive through the Graveyard slot.
                //
                // Checking each share on its own can never overflow, so the
                // documented promise below — that ANY bad answer means "use the
                // local policy" — is now true for every answer, not most.
                if (a <= MAX_TOTAL_POT_BPS && b <= MAX_TOTAL_POT_BPS && a + b <= MAX_TOTAL_POT_BPS)
                {
                    return (a, b, s);
                }
            } catch {
                // Unwired, wrong ABI, self-destructed, reverting, out of gas —
                // all mean "use the local policy", never "fail the player".
            }
        }
        return (fallbackBnbullShareBps, fallbackBnbShareBps, fallbackSellsForBnbLeg);
    }

    /// @notice The raw `MintDrop` read. `external` ONLY so `potPolicy` can
    ///         try/catch it in one place instead of nesting three try blocks.
    function readMintDropPolicy() external view returns (uint256, uint256, bool) {
        if (msg.sender != address(this)) revert NotSelf();
        IMintDropPolicy md = IMintDropPolicy(_wire(Wire.MintDrop));
        return (md.bnbullShareBps(), md.bnbShareBps(), md.bnbullPaymentSellsForBnbLeg());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The never-fail pot legs
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Route into the BNBULL pot, or accrue. CANNOT REVERT.
    function _toBnbullPotOrAccrue(PotSource src, uint256 amount) internal {
        if (amount == 0) return;
        if (_bnbullLegReady(src)) {
            try this.routeToBnbullPotInline(src, amount) returns (uint256 funded) {
                emit BnbullPotFundedInline(src, amount, funded);
                return;
            } catch {
                // Deliberately catch-all. A thin pool, a reverting router, a
                // pot that has not granted us the funder role yet, a token that
                // changed under us — every one of them means "not now", never
                // "fail the player".
            }
        }
        uint256 total = _accrueBnbull(src, amount);
        emit BnbullPotDeferred(src, amount, total);
    }

    /// @dev Route into the WBNB pot, or accrue. CANNOT REVERT.
    function _toBnbPotOrAccrue(PotSource src, uint256 amount) internal {
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

    /**
     * @dev Cheap pre-check so a pre-launch payment does not pay for a try/catch
     *      that cannot possibly work.
     *
     *      ⚠ STORAGE READS ONLY. NOTHING EXTERNAL BELONGS IN HERE. This runs
     *      OUTSIDE the try/catch, directly inside a never-fail entrypoint, so a
     *      call to a router that reverts, self-destructed, or burns the frame's
     *      gas would brick every native mint and every revive. That is why the
     *      minimum-liquidity floor — which must read the factory, the pair and
     *      its reserves — is checked down in `_swapSingle` instead, where a
     *      revert is caught and becomes an accrual.
     */
    function _bnbullLegReady(PotSource src) private view returns (bool) {
        if (_wire(Wire.JackpotBnbull) == address(0)) return false;
        if (_wire(Wire.Bnbull) == address(0)) return false;
        if (src == PotSource.Bnbull) return true; // already the pot asset
        if (_wire(Wire.Router) == address(0)) return false;
        if (!floorsFresh()) return false;
        return bnbullPerBnb != 0;
    }

    function _bnbLegReady(PotSource src) private view returns (bool) {
        if (_wire(Wire.JackpotBnb) == address(0)) return false;
        if (src == PotSource.Native) return true; // a 1:1 wrap, not a swap
        if (_wire(Wire.Router) == address(0)) return false;
        if (!floorsFresh()) return false;
        return _wire(Wire.Bnbull) != address(0) && wbnbPerBnbull != 0;
    }

    /// @notice True while the keeper's published floors are recent enough to
    ///         authorise an inline swap.
    function floorsFresh() public view returns (bool) {
        if (floorsUpdatedAt == 0) return false;
        return block.timestamp <= uint256(floorsUpdatedAt) + maxFloorAge;
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
     *      accrual — including the state changes it had already made.
     */
    function routeToBnbullPotInline(PotSource src, uint256 amount)
        external
        returns (uint256 funded)
    {
        if (msg.sender != address(this)) revert NotSelf();
        return _toBnbullPot(src, amount, 0, "inline");
    }

    /// @notice The inline WBNB-pot leg. See `routeToBnbullPotInline`.
    function routeToBnbPotInline(PotSource src, uint256 amount) external returns (uint256 funded) {
        if (msg.sender != address(this)) revert NotSelf();
        return _toBnbPot(src, amount, 0, "inline");
    }

    /**
     * @dev Move `amount` of `src` into the BNBULL pot.
     * @param minOutOverride 0 means "use the keeper's published floor" (the
     *        inline path). The sweeps pass a floor quoted OFF chain immediately
     *        before the call — the one bound a same-block front-run cannot move.
     */
    function _toBnbullPot(
        PotSource src,
        uint256 amount,
        uint256 minOutOverride,
        string memory source
    ) private returns (uint256 funded) {
        address pot = _wire(Wire.JackpotBnbull);
        if (pot == address(0)) revert PotNotWired();
        address bull = _wire(Wire.Bnbull);
        if (bull == address(0)) revert BnbullNotWired();
        if (amount == 0) revert NothingToDo();

        if (src == PotSource.Bnbull) {
            // Already the pot asset. No swap, no slippage, no router — the
            // `§14` path, and the reason a BNBULL payment can never be sold.
            funded = amount;
        } else {
            uint256 minOut =
                minOutOverride != 0 ? minOutOverride : _floor(amount, bnbullPerBnb, 1e18);
            // Wrap 1:1 first: on BNB Chain, holding BNB gives this contract no
            // ERC-20 balance at all. There is no 1e12 identity to lean on.
            //
            // Then ONE v2 hop, WBNB -> BNBULL, through the one canonical pair.
            // The two-hop path went with the stablecoin (`DECISIONS.md §26`)
            // and the v3 dialect went with `§28`. A middle hop comes BACK only
            // if `swapIntermediate()` is wired — dormant, and `§30`'s
            // insurance, not a route anyone expects to take.
            //
            // The wrap is kept rather than calling the router's ETH entrypoint:
            // it is the same two pair transfers either way, and holding WBNB
            // ourselves means ONE swap helper covers both directions and both
            // of them are measured the same way.
            uint256 wrapped = _wrap(amount);
            funded = _swapSingle(IERC20(address(wbnb)), IERC20(bull), wrapped, minOut);
        }

        _fundPot(pot, IERC20(bull), funded, source);
    }

    /// @dev Move `amount` of `src` into the WBNB pot.
    function _toBnbPot(PotSource src, uint256 amount, uint256 minOutOverride, string memory source)
        private
        returns (uint256 funded)
    {
        address pot = _wire(Wire.JackpotBnb);
        if (pot == address(0)) revert PotNotWired();
        if (amount == 0) revert NothingToDo();

        if (src == PotSource.Native) {
            // A WRAP, not a swap: 1:1, no router, no liquidity dependency, no
            // floor to be stale. Still measured, because measuring is free and
            // assumptions are how the fefers decimals trap happened.
            funded = _wrap(amount);
        } else {
            address bull = _wire(Wire.Bnbull);
            if (bull == address(0)) revert BnbullNotWired();
            uint256 minOut = minOutOverride != 0
                ? minOutOverride
                : _floor(amount, wbnbPerBnbull, 10 ** bnbullDecimals);
            funded = _swapSingle(IERC20(bull), IERC20(address(wbnb)), amount, minOut);
        }

        _fundPot(pot, IERC20(address(wbnb)), funded, source);
    }

    /// @dev `amountIn * rate / unit`, refusing a zero result. A zero floor is a
    ///      blind swap; the correct response is to defer, and the revert here
    ///      is what makes that happen.
    function _floor(uint256 amountIn, uint256 rate, uint256 unit)
        private
        pure
        returns (uint256 minOut)
    {
        minOut = (amountIn * rate) / unit;
        if (minOut == 0) revert BlindSwapRefused();
    }

    /// @dev BNB -> WBNB, measured. `deposit` is 1:1 and cannot fail on
    ///      liquidity, but the delta is still what gets booked.
    function _wrap(uint256 amount) private returns (uint256 wrapped) {
        uint256 before = wbnb.balanceOf(address(this));
        wbnb.deposit{value: amount}();
        wrapped = wbnb.balanceOf(address(this)) - before;
    }

    /**
     * @dev **PancakeSwap v2** swap — one hop by default, two if an intermediate
     *      is wired — booked as a MEASURED BALANCE DELTA and re-checked against
     *      `minOut`.
     *
     *      ══════════════════════════════════════════════════════════════════
     *      THIS IS THE SEAM. THREE THINGS ARE LOAD-BEARING IN IT.
     *      ══════════════════════════════════════════════════════════════════
     *      **1. The venue is v2** (`DECISIONS.md §28`). four.meme graduates
     *      into PancakeSwap V2 against WBNB and creates no v3 pool at any tier.
     *      A v3 leg could only ever have found somebody else's decoy — measured
     *      at 95x worse, silently. Everything around this function is
     *      venue-agnostic: the keeper floors, the measured delta, the
     *      zero-floor refusal, the accrue-on-failure. The venue lives here and
     *      only here.
     *
     *      **2. The call is the FEE-SUPPORTING variant** (`§30`). four.meme
     *      template B carries a creator-set buy and sell tax; a plain
     *      `swapExactTokensForTokens` on such a token reverts `Pancake: K`, and
     *      v3 has no fee-supporting variant at all. This one call works on both
     *      templates, so the money layer does not depend on a launch-form
     *      checkbox. It returns nothing — which costs us nothing, because the
     *      figure we book has always been `balanceOf` after minus before.
     *
     *      **3. The pool must be real before we trade into it.** The floor is
     *      checked here rather than in the `…LegReady` pre-checks on purpose:
     *      those run OUTSIDE the try/catch, straight inside a never-fail
     *      entrypoint, and an external call there — to a router that reverts,
     *      self-destructed, or burns the frame's gas — would be the very brick
     *      this contract exists to prevent. In here a revert is caught and
     *      becomes an accrual, which is precisely the behaviour `§29` asks for.
     *
     *      ⚠ AND ONE DELIBERATE INEFFICIENCY, SO NOBODY "FIXES" IT. On the
     *      BNB -> BNBULL leg the WBNB wrap happens BEFORE this check, so a
     *      pre-graduation deferral pays for a wrap it then rolls back — and
     *      pre-graduation deferral is the normal state for as long as the curve
     *      runs (`§29`). Hoisting the check above the wrap would save that gas
     *      and cost the thing that matters more: ONE choke point that every
     *      swap, in both directions, inline and swept, has to pass through.
     *      Two checks are two chances for a later edit to keep only one.
     */
    function _swapSingle(IERC20 inToken, IERC20 outToken, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 bought)
    {
        address r = _wire(Wire.Router);
        if (r == address(0)) revert RouteNotWired();
        if (minOut == 0) revert BlindSwapRefused();
        _requireLiquidity(r);

        address[] memory path = _path(address(inToken), address(outToken));

        inToken.forceApprove(r, amountIn);
        uint256 before = outToken.balanceOf(address(this));
        IPancakeRouter02(r).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minOut, path, address(this), block.timestamp
        );
        bought = outToken.balanceOf(address(this)) - before;
        // Never leave an allowance standing. A fee-on-transfer input token
        // makes the router pull less than `amountIn`, so there usually IS a
        // remainder here.
        inToken.forceApprove(r, 0);
        if (bought < minOut) revert SwapOutBelowMin(bought, minOut);
    }

    /**
     * @notice ⚠ THE DORMANT BACKUP ROUTE. Zero means the swap is the ONE hop it
     *         has always been; anything else inserts it as a middle hop.
     *
     * @dev ══════════════════════════════════════════════════════════════════
     *      WHY THIS EXISTS, AND WHY IT MUST STAY ASLEEP
     *      ══════════════════════════════════════════════════════════════════
     *      `DECISIONS.md §30`: four.meme's `_templates()` lists **20 templates
     *      and 19 of them graduate into a NON-BNB pool** (USDT, USDC, CAKE,
     *      NVDAB…). The dominant flow — and a live mainnet graduate re-checked
     *      on 2026-08-06 — lands in **PancakeSwap v2 against WBNB** (`§28`),
     *      which is what everything here assumes and what the launch form will
     *      ask for. But the LP is burned and the token is immutable, so if that
     *      form is ever answered wrongly there is no second chance: every buy
     *      leg would point at a pool that does not exist, forever.
     *
     *      That is what this is insurance against, and the cure had to be
     *      cheaper than the disease:
     *
     *      | BNBULL graduates against | resulting path |
     *      |---|---|
     *      | WBNB (expected) | `[WBNB, BNBULL]` — unchanged, unwired, today |
     *      | USDT / CAKE / X | `[WBNB, X, BNBULL]` |
     *
     *      ⚠ IT IS ONE ADDRESS, NOT AN `address[]`, DELIBERATELY. A full
     *      settable path is a strictly larger attack surface (length, first
     *      element, last element, zero members, gas-bomb length — five things
     *      to validate) for a case that is always exactly three hops or fewer.
     *      An optional middle hop makes every one of those five structurally
     *      impossible instead of merely checked: the length is 2 or 3, the
     *      first element is the input token this function was handed, the last
     *      is the wired BNBULL read from the same slot the pot funding uses,
     *      and `TimelockedAddress` refuses a zero target. **A path whose last
     *      hop is not BNBULL is the whole attack, and it cannot be expressed.**
     *
     *      ⚠ TIMELOCKED LIKE EVERY OTHER MONEY WIRE, because a settable route
     *      IS a rug vector in general: point it at a token you control and
     *      protocol money buys your own worthless supply. It is a `Wire` slot,
     *      so it inherits the exact discipline (`bootstrapWire` while zero,
     *      then `proposeWire` -> wait `wiringDelay` -> `commitWire`, with the
     *      pending target and its ETA public the whole time) with no second,
     *      weaker mechanism to audit.
     *
     *      ⚠ `address(wbnb)` IS THE SENTINEL FOR "GO BACK TO DIRECT", because
     *      `TimelockedAddress.propose` refuses a zero target and a wire can
     *      therefore never be un-set. `[WBNB, WBNB, BNBULL]` is nonsense as a
     *      route, which is exactly what makes it safe to spend as a flag —
     *      and reverting a wrong guess must be possible, or this insurance
     *      becomes its own trap.
     *
     *      ⚠ THE KEEPER FLOORS ARE UNAFFECTED AND MUST STAY THAT WAY.
     *      `bnbullPerBnb` is BNBULL wei per 1 BNB **in, end to end** — it
     *      prices the whole trip, not a hop — so it is path-agnostic by
     *      construction. Same for `wbnbPerBnbull`. Nothing here touches them.
     */
    function swapIntermediate() public view returns (address) {
        address mid = _wire(Wire.SwapIntermediate);
        // The sentinel and "never wired" collapse to the same answer: direct.
        return mid == address(wbnb) ? address(0) : mid;
    }

    /// @dev The asset the BNBULL pair is quoted in: WBNB normally, the wired
    ///      intermediate otherwise. This — NOT "the last element of the path" —
    ///      is the right question, because the buy leg ends on that pair and
    ///      the sell leg starts on it. Same pool either way.
    function _quoteAsset() private view returns (address) {
        address mid = swapIntermediate();
        return mid == address(0) ? address(wbnb) : mid;
    }

    /// @dev The route. Two elements — byte for byte what this contract has
    ///      always built — unless an intermediate is wired, and then three.
    ///      v2's router has always taken an arbitrary-length `address[] path`;
    ///      the only thing that was ever hardcoded here was the length.
    function _path(address inToken, address outToken)
        private
        view
        returns (address[] memory path)
    {
        address mid = swapIntermediate();
        if (mid == address(0)) {
            path = new address[](2);
            path[1] = outToken;
        } else {
            path = new address[](3);
            path[1] = mid;
            path[2] = outToken;
        }
        path[0] = inToken;
    }

    /// @dev Refuse to trade against a pair that does not exist, or holds less
    ///      of its quote asset than the floor for that quote asset. REVERTS —
    ///      every caller is either inside a try/catch (inline: becomes an
    ///      accrual) or a keeper/owner sweep (which is allowed, and expected,
    ///      to fail loudly).
    ///
    ///      ⚠ THE FLOOR IS PICKED BY DENOMINATION, NEVER SHARED. A WBNB pair is
    ///      measured against `minPoolLiquidity` (1 BNB); an X pair against
    ///      `minPoolLiquidityAlt`, in X. An unset alt floor refuses the trade
    ///      rather than waving it through — see `minPoolLiquidityAlt`.
    function _requireLiquidity(address router) private view {
        address quote = _quoteAsset();
        uint256 floor_ = quote == address(wbnb) ? minPoolLiquidity : minPoolLiquidityAlt;
        if (floor_ == 0) revert InvalidMinLiquidity(0);
        (, uint256 reserve) = _pool(router, quote, _wire(Wire.Bnbull));
        if (reserve < floor_) revert PoolTooThin(reserve, floor_);
    }

    /**
     * @dev `quote`-side reserve of the canonical `quote`/`token` v2 pair.
     *
     *      The factory comes from `router.factory()` — never a second wire —
     *      so the reserve we price the floor off is, by construction, the book
     *      the swap is about to hit. That identity is the whole point: on
     *      Stable a $50 dev buy was published as $13.26 because the pool that
     *      answered the lookup was not the pool that held the money
     *      (`BNB-CHAIN-FACTS.md §3`).
     *
     *      A missing pair returns ZERO rather than reverting, so "not launched
     *      yet" and "dust" land in the same place: below the floor, deferred.
     */
    function _pool(address router, address quote, address token)
        private
        view
        returns (address pair, uint256 reserve)
    {
        if (token == address(0)) return (address(0), 0);
        pair = IPancakeFactory(IPancakeRouter02(router).factory()).getPair(quote, token);
        if (pair == address(0)) return (pair, 0);
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        // `token0()` is READ, not derived from address ordering. The pair is
        // the authority on its own reserve order.
        reserve = IPancakePair(pair).token0() == quote ? uint256(r0) : uint256(r1);
    }

    /**
     * @notice The canonical BNBULL v2 pair and its quote-side reserve — the two
     *         numbers the liquidity floor is compared against.
     *
     * @dev ⚠ THE NAME IS HISTORICAL AND KEPT SO KEEPER TOOLING DOES NOT BREAK.
     *      It follows the route: with no intermediate (the default) it is the
     *      WBNB/BNBULL pair and the reserve is WBNB, exactly as before; with
     *      one wired it is the X/BNBULL pair and **the reserve is denominated
     *      in X**. Pair it with `swapIntermediate()` before you read a unit
     *      into the number.
     *
     *      An OFF-CHAIN read for the keepers and the deploy pre-flight. It is
     *      NOT on any never-fail path and it is allowed to revert if the router
     *      at the wire does not speak v2; that is information, not a brick.
     */
    function wbnbPoolLiquidity() external view returns (address pair, uint256 wbnbReserve) {
        address r = _wire(Wire.Router);
        if (r == address(0)) return (address(0), 0);
        return _pool(r, _quoteAsset(), _wire(Wire.Bnbull));
    }

    /// @dev Lock tokens into a pot. Nothing gets them out again except a won
    ///      ticket — that guarantee IS the product.
    function _fundPot(address pot, IERC20 token, uint256 amount, string memory source) private {
        if (amount == 0) revert NothingToDo();
        token.forceApprove(pot, amount);
        IJackpotFund(pot).fund(amount, source);
        token.forceApprove(pot, 0);
    }

    /// @dev Pull a token in and book what actually arrived.
    function _pullMeasured(IERC20 token, address from, uint256 amount)
        internal
        returns (uint256 received)
    {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - before;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Sweeps — the deferred legs, spent with an OFF-CHAIN quoted floor
    // ══════════════════════════════════════════════════════════════════════

    modifier onlyKeeperOrOwner() {
        _requireKeeperOrOwner();
        _;
    }

    function _requireKeeperOrOwner() private view {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeperOrOwner();
    }

    /**
     * @notice Spend a deferred BNBULL-pot leg.
     *
     *         This is the fallback drain, not the main path: money only lands
     *         in a `pending*` bucket when the inline leg could not run. It
     *         exists because "the route was down for an hour" has to have an
     *         answer that is not "the money is gone".
     *
     * @param src      Which bucket to spend.
     * @param amountIn Amount to spend. 0 spends the whole bucket.
     * @param minOut   Slippage floor, quoted OFF chain immediately before the
     *                 call. Ignored for `Bnbull` (no swap happens); zero is
     *                 refused for the swap sources. ⛔ From the KEEPER it may
     *                 only be STRICTER than the published floor — see
     *                 `_requireKeeperFloor`.
     */
    function sweepBnbullPot(PotSource src, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        onlyKeeperOrOwner
        returns (uint256 funded)
    {
        uint256 available = bnbullBucket(src);
        uint256 spend = amountIn == 0 ? available : amountIn;
        if (spend == 0) revert NothingToDo();
        if (spend > available) revert InsufficientPending(spend, available);
        if (src != PotSource.Bnbull) {
            if (minOut == 0) revert BlindSwapRefused();
            // ⚠ THE BUY LEG'S RATE AND ITS UNIT. `bnbullPerBnb` is BNBULL wei
            //   per 1e18 BNB in, so the divisor is 1e18 — a chain fact about
            //   the native token, never a token property. Never
            //   `wbnbPerBnbull`, and never `10 ** bnbullDecimals`.
            _requireKeeperFloor(spend, bnbullPerBnb, 1e18, minOut);
        }

        // Book the spend before the external calls (CEI).
        _debitBnbullBucket(src, spend);
        funded = _toBnbullPot(src, spend, minOut, "deferred-sweep");
        emit PotSwept(true, src, spend, funded);
    }

    /// @notice Spend a deferred WBNB-pot leg. See `sweepBnbullPot`. `minOut` is
    ///         ignored for `Native` (a 1:1 wrap, not a swap).
    function sweepBnbPot(PotSource src, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        onlyKeeperOrOwner
        returns (uint256 funded)
    {
        uint256 available = bnbBucket(src);
        uint256 spend = amountIn == 0 ? available : amountIn;
        if (spend == 0) revert NothingToDo();
        if (spend > available) revert InsufficientPending(spend, available);
        if (src != PotSource.Native) {
            if (minOut == 0) revert BlindSwapRefused();
            // ⚠ THE SELL LEG'S RATE AND ITS UNIT, AND THEY ARE NOT THE BUY
            //   LEG'S. `wbnbPerBnbull` is WBNB wei per ONE WHOLE BNBULL, so
            //   the divisor is `10 ** bnbullDecimals` — READ off the token at
            //   wiring time, never assumed to be 18. Interchanging these two
            //   pairs is `BNB-CHAIN-FACTS.md §3` and the fefers decimals trap,
            //   and it would pass silently in both directions.
            _requireKeeperFloor(spend, wbnbPerBnbull, 10 ** bnbullDecimals, minOut);
        }

        _debitBnbBucket(src, spend);
        funded = _toBnbPot(src, spend, minOut, "deferred-sweep");
        emit PotSwept(false, src, spend, funded);
    }

    /**
     * @dev ⛔ THE KEEPER MAY SPEND A BUCKET, BUT IT MAY NOT PRICE THE TRADE.
     *
     *      The sweeps take an off-chain-quoted `minOut` because that is the one
     *      bound a same-block front-run cannot move. The hole that opened
     *      underneath that sentence is that the same argument REPLACES the
     *      published floor outright, so `sweepBnbullPot(src, 0, 1)` from a
     *      stolen keeper key was one transaction that converted an entire
     *      accrued bucket into 1 wei of BNBULL through a sandwich — with no
     *      owner key involved anywhere, and `_requireLiquidity` waving it
     *      through, because a sandwicher's front-run BUY only ever makes the
     *      quote-side reserve larger.
     *
     *      So the override keeps its job and loses its reach: it may tighten
     *      the published floor and never loosen it. The floor it is measured
     *      against is the keeper's own published rate, which is leashed by
     *      `keeperFloorDropBps` — so the sweep is bounded by the same slow,
     *      logged walk as everything else, instead of by nothing.
     *
     *      ⚠ AND THIS IS ALSO THE CAP ON HOW MUCH OF A BUCKET ONE SWEEP MAY
     *      SPEND, without a magic fraction anywhere. The published floor scales
     *      LINEARLY with `spend`, while what a constant-product pool actually
     *      pays scales sub-linearly — price impact. So a sweep large enough to
     *      move the pool cannot clear its own floor and must be split into
     *      slices the pool can absorb. The bound comes out of the book's real
     *      depth rather than out of a number somebody guessed, and it retunes
     *      itself as the pool grows.
     *
     *      ⚠ A STALE FLOOR STILL DEFERS SAFELY, WHICH IS THE PROMISE THAT MUST
     *      NOT REGRESS. With no fresh floor there is nothing to measure a
     *      keeper's price against, so the sweep REVERTS and the money stays in
     *      its bucket, untouched and still owner-recoverable. A sweep is
     *      allowed to fail loudly; that is what it is for.
     *
     *      The OWNER is exempt, for the reason given on `keeperFloorDropBps`:
     *      it already holds `withdrawPendingForManualBuy`, which empties the
     *      same bucket in one call. Bounding a price it can simply route around
     *      would be theatre, and it would take away the large legitimate
     *      correction `BNBULLS-BOOTSTRAP.md §0` requires the owner to keep.
     */
    function _requireKeeperFloor(uint256 spend, uint256 rate, uint256 unit, uint256 minOut)
        private
        view
    {
        if (msg.sender == owner()) return;
        if (!floorsFresh()) revert FloorsStale();
        // `_floor` refuses a zero result, so a leg whose rate was never
        // published — or was killed — is a leg the keeper cannot sweep at all.
        uint256 published = _floor(spend, rate, unit);
        if (minOut < published) revert SweepFloorBelowPublished(minOut, published);
    }

    function bnbullBucket(PotSource src) public view returns (uint256) {
        return src == PotSource.Native ? pendingBnbullBuyNative : pendingBnbullDirect;
    }

    function bnbBucket(PotSource src) public view returns (uint256) {
        return src == PotSource.Native ? pendingBnbPotNative : pendingBnbPotBnbull;
    }

    function _debitBnbullBucket(PotSource src, uint256 amount) private {
        if (src == PotSource.Native) pendingBnbullBuyNative -= amount;
        else pendingBnbullDirect -= amount;
    }

    function _debitBnbBucket(PotSource src, uint256 amount) private {
        if (src == PotSource.Native) pendingBnbPotNative -= amount;
        else pendingBnbPotBnbull -= amount;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Balances: what is spoken for, and what is not
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Balance of `src` that a deferred pot leg already has a claim on.
    function reservedOf(PotSource src) public view returns (uint256) {
        if (src == PotSource.Native) return pendingBnbullBuyNative + pendingBnbPotNative;
        return pendingBnbullDirect + pendingBnbPotBnbull;
    }

    /// @notice Balance of `src` no pot leg has a claim on: this splitter's
    ///         retained share, plus anything force-sent here.
    function freeOf(PotSource src) public view returns (uint256) {
        uint256 bal;
        if (src == PotSource.Native) {
            bal = address(this).balance;
        } else {
            address token = _wire(Wire.Bnbull);
            if (token == address(0)) return 0;
            bal = IERC20(token).balanceOf(address(this));
        }
        uint256 reserved = reservedOf(src);
        return bal > reserved ? bal - reserved : 0;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Owner escape hatches
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Pull a deferred leg OUT instead of swapping it, for the case
     *         where no pool exists yet and the dev wants to place the buy by
     *         hand and top the pot up manually.
     *
     * @dev ⚠ TRUST BOUNDARY, STATED PLAINLY. Money in a `pending*` bucket has
     *      NOT entered a pot yet, so this hatch can move it. Money that has
     *      reached a `Jackpot` can never come out except through a won ticket —
     *      `Jackpot.sweepForeignToken` reverts on the prize token and there is
     *      no other path. The two guarantees are different, and this emits its
     *      own event so the receipts trail says which is which.
     */
    function withdrawPendingForManualBuy(
        bool bnbullPot,
        PotSource src,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = bnbullPot ? bnbullBucket(src) : bnbBucket(src);
        uint256 take = amount == 0 ? available : amount;
        if (take == 0) revert NothingToDo();
        if (take > available) revert InsufficientPending(take, available);

        if (bnbullPot) _debitBnbullBucket(src, take);
        else _debitBnbBucket(src, take);

        _send(src, to, take);
        emit PendingWithdrawnForManualBuy(src, bnbullPot, to, take);
    }

    /// @notice Withdraw balance no pot leg has a claim on — this splitter's
    ///         retained (dev) share and any force-sent residue. Bounded by
    ///         `freeOf`, so pot money is untouchable through this door.
    function withdrawUnreserved(PotSource src, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 free = freeOf(src);
        uint256 take = amount == 0 ? free : amount;
        if (take == 0) revert NothingToDo();
        if (take > free) revert InsufficientFree(take, free);
        _send(src, to, take);
        emit UnreservedWithdrawn(src, to, take);
    }

    function _send(PotSource src, address to, uint256 amount) private {
        if (src == PotSource.Native) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeSendFailed();
        } else {
            address bull = _wire(Wire.Bnbull);
            if (bull == address(0)) revert BnbullNotWired();
            IERC20(bull).safeTransfer(to, amount);
        }
    }

    /// @notice Recover a token sent here by mistake — WBNB left over from a
    ///         partially completed leg, an airdrop, a mis-send. Refuses BNBULL,
    ///         whose balance is accounted for above and leaves through
    ///         `withdrawUnreserved` / `withdrawPendingForManualBuy`.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == _wire(Wire.Bnbull)) revert InsufficientFree(amount, 0);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The local policy used when the `MintDrop` read is unavailable.
    ///         Keep it equal to MintDrop's live values.
    function setFallbackPolicy(uint256 bnbullBps, uint256 bnbBps, bool sellsForBnbLeg)
        external
        onlyOwner
    {
        if (bnbullBps + bnbBps > MAX_TOTAL_POT_BPS) revert InvalidShare(bnbullBps + bnbBps);
        fallbackBnbullShareBps = bnbullBps;
        fallbackBnbShareBps = bnbBps;
        fallbackSellsForBnbLeg = sellsForBnbLeg;
        emit FallbackPolicyChanged(bnbullBps, bnbBps, sellsForBnbLeg);
    }

    /**
     * @notice Set the minimum WBNB-side reserve the WBNB/BNBULL pair must hold
     *         before any leg will trade against it.
     *
     * @dev Owner-only, and ZERO IS REFUSED — see the variable's docs. Raising
     *      it is always safe (more legs defer, nothing is lost); lowering it
     *      towards dust is the decision to be careful with.
     */
    function setMinPoolLiquidity(uint256 minWbnbReserve) external onlyOwner {
        if (minWbnbReserve == 0 || minWbnbReserve > MAX_MIN_POOL_LIQUIDITY) {
            revert InvalidMinLiquidity(minWbnbReserve);
        }
        minPoolLiquidity = minWbnbReserve;
        emit MinPoolLiquidityChanged(minWbnbReserve);
    }

    /**
     * @notice Set the liquidity floor used when `swapIntermediate()` is wired —
     *         denominated in THAT token, not in BNB.
     *
     * @dev ⚠ ZERO IS ALLOWED HERE AND MEANS "DO NOT TRADE THE ALTERNATE
     *      ROUTE", which is the opposite of what zero means on
     *      `setMinPoolLiquidity`. The two are not symmetrical because the risks
     *      are not: a zero WBNB floor would let every leg trade against a dust
     *      pair, while a zero alt floor makes every leg on the alternate route
     *      defer. Both choices point the same way — never trade an unmeasured
     *      pool — and this one doubles as the kill switch for the backup route.
     *
     *      ⚠ THE CAP IS NOMINAL UNITS, NOT BNB. `MAX_MIN_POOL_LIQUIDITY` is
     *      reused as a sanity ceiling on the raw number; it is generous for any
     *      plausible quote asset and it only ever prevents a floor so high that
     *      every leg silently defers.
     */
    function setMinPoolLiquidityAlt(uint256 minQuoteReserve) external onlyOwner {
        if (minQuoteReserve > MAX_MIN_POOL_LIQUIDITY) {
            revert InvalidMinLiquidity(minQuoteReserve);
        }
        minPoolLiquidityAlt = minQuoteReserve;
        emit MinPoolLiquidityAltChanged(minQuoteReserve);
    }

    /**
     * @notice Publish both inline swap floors. Owner OR keeper, because they
     *         track a drifting market price.
     *
     *         Both are written together and share one timestamp: a partial
     *         refresh would leave one leg quietly authorised by the other leg's
     *         freshness. Writing a rate as ZERO disables that leg — the kill
     *         switch for a keeper that has lost its price source.
     *
     *         ⛔ AND A KEEPER PUBLISH IS LEASHED. The owner writes whatever it
     *         likes; the keeper may raise a rate, kill a rate, or lower one by
     *         at most `keeperFloorDropBps` once per `keeperFloorDropGap`. See
     *         those variables for why the bound is on the rate of change rather
     *         than on a constant, and what it does and does not buy.
     *
     * @param _bnbullPerBnb  BNBULL wei per 1e18 BNB in.
     * @param _wbnbPerBnbull WBNB wei per one whole BNBULL unit in.
     */
    function setFloors(uint256 _bnbullPerBnb, uint256 _wbnbPerBnbull)
        external
        onlyKeeperOrOwner
    {
        if (msg.sender != owner()) _leashKeeperFloors(_bnbullPerBnb, _wbnbPerBnbull);

        bnbullPerBnb = _bnbullPerBnb;
        wbnbPerBnbull = _wbnbPerBnbull;
        floorsUpdatedAt = uint64(block.timestamp);
        emit FloorsPublished(_bnbullPerBnb, _wbnbPerBnbull, uint64(block.timestamp));
    }

    /// @dev Apply the leash to a keeper publish. Reverts, or records that the
    ///      keeper has spent its drop for this gap.
    function _leashKeeperFloors(uint256 nextBnbullPerBnb, uint256 nextWbnbPerBnbull) private {
        // ⚠ BOTH RATES ARE EVALUATED, ALWAYS. Do NOT fold these into
        //   `_isKeeperDrop(a) || _isKeeperDrop(b)`: `||` short-circuits, and
        //   the second call is not just a question — it is the check that
        //   refuses to arm a dead leg. Skipping it because the first rate
        //   happened to be a drop is how `wbnbPerBnbull` gets turned on by a
        //   stolen key while nobody is reading the diff.
        bool bnbullDrop = _isKeeperDrop(bnbullPerBnb, nextBnbullPerBnb);
        bool wbnbDrop = _isKeeperDrop(wbnbPerBnbull, nextWbnbPerBnbull);
        if (!bnbullDrop && !wbnbDrop) return;

        uint256 nextAllowedAt = uint256(floorsDroppedAt) + keeperFloorDropGap;
        // `floorsDroppedAt == 0` means no keeper has ever cut a floor here, so
        // there is no gap to have violated. Without this the first legitimate
        // repeg of a fresh deployment is blocked by a window that never opened.
        if (floorsDroppedAt != 0 && block.timestamp < nextAllowedAt) {
            revert FloorDropTooSoon(nextAllowedAt);
        }
        floorsDroppedAt = uint64(block.timestamp);
    }

    /**
     * @dev Is this one rate's move a keeper DROP, and is it a legal one?
     *      Reverts on an illegal move; returns true when a legal drop was
     *      spent, so the caller knows to start the gap.
     *
     *      The four cases, and each one's reason:
     *
     *        - `next == 0` — the kill switch. Disables the leg, everything
     *          accrues, nothing trades. Never restricted: the safe direction
     *          must always be one transaction away;
     *        - `live == 0` — ⛔ ARMING A DEAD LEG, AND IT IS OWNER-ONLY. Zero
     *          is not "the smallest floor", it is "this leg is off", so
     *          0 -> anything is not a raise however the integers compare. Left
     *          unguarded it is also the trivial bypass of everything below:
     *          publish 0 to kill, publish 1 to re-arm at dust, and the whole
     *          leash is walked around in two transactions. It is the right
     *          rule on its own merits too — `wbnbPerBnbull` is the BNBULL SELL
     *          leg, `DECISIONS.md §14` keeps it off, and `floor-keeper.mjs`
     *          already promises in writing that "this keeper must never be the
     *          thing that turns BNBULL-selling on". This is that promise moved
     *          from a comment into the bytecode. The single exception is the
     *          first publish of a fresh deployment (`floorsUpdatedAt == 0`),
     *          which is the documented keeper bootstrap and happens when every
     *          bucket is still empty;
     *        - `next >= live` — a raise. Strictly stricter, so the worst case
     *          is that swaps miss `minOut` and defer. Free;
     *        - `next < live` — the only dangerous direction, and the only one
     *          that costs anything.
     */
    function _isKeeperDrop(uint256 live, uint256 next) private view returns (bool) {
        if (next == 0) return false;
        if (live == 0) {
            if (floorsUpdatedAt != 0) revert FloorArmingIsOwnerOnly();
            return false; // first publish of a fresh deployment
        }
        if (next >= live) return false;

        uint256 lowest = live - (live * keeperFloorDropBps) / BPS;
        if (next < lowest) revert FloorDropTooLarge(next, lowest);
        return true;
    }

    /// @notice Retune the keeper leash within its ceilings.
    ///
    /// @dev Tightening is always safe — the worst a too-tight leash does is
    ///      make a falling market defer until the owner repegs, which is this
    ///      contract's safe state. Loosening is the direction to be careful
    ///      with, which is why `MAX_KEEPER_FLOOR_DROP_BPS` and
    ///      `MIN_KEEPER_FLOOR_DROP_GAP` are `constant` and this is not.
    function setKeeperFloorLeash(uint256 dropBps, uint256 gap) external onlyOwner {
        // The upper bound on the gap is `MAX_FLOOR_AGE` rather than a new
        // number: a gap longer than the longest a floor may live is a leash
        // that silently means "the keeper can never lower a floor again", and
        // silent is the failure mode this whole file is written against.
        if (dropBps > MAX_KEEPER_FLOOR_DROP_BPS || gap < MIN_KEEPER_FLOOR_DROP_GAP
            || gap > MAX_FLOOR_AGE) {
            revert InvalidFloorLeash(dropBps, gap);
        }
        keeperFloorDropBps = dropBps;
        keeperFloorDropGap = gap;
        emit KeeperFloorLeashChanged(dropBps, gap);
    }

    function setMaxFloorAge(uint256 maxAge) external onlyOwner {
        if (maxAge == 0 || maxAge > MAX_FLOOR_AGE) revert InvalidFloorAge(maxAge);
        maxFloorAge = maxAge;
        emit MaxFloorAgeChanged(maxAge);
    }

    function setKeeper(address _keeper) external onlyOwner {
        emit KeeperChanged(keeper, _keeper);
        keeper = _keeper;
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

    function wireOf(Wire slot)
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        TimelockedAddress.Slot storage s = _wires[uint8(slot)];
        return (s.current, s.pending, s.eta);
    }

    /// @notice Every live wiring address in one call — the read the deploy
    ///         preflight and the keepers use.
    /// @dev ⚠ THE SHAPE IS DELIBERATELY UNCHANGED. `Wire.SwapIntermediate` is
    ///      NOT returned here: adding a sixth value would break every decoder
    ///      already written against this selector for the sake of a slot that
    ///      is expected to read zero forever. Read it with `swapIntermediate()`
    ///      (effective) or `wireOf(Wire.SwapIntermediate)` (raw + pending).
    function wires()
        external
        view
        returns (
            address bnbull,
            address router,
            address jackpotBnbull,
            address jackpotBnb,
            address mintDrop
        )
    {
        return (
            _wire(Wire.Bnbull),
            _wire(Wire.Router),
            _wire(Wire.JackpotBnbull),
            _wire(Wire.JackpotBnb),
            _wire(Wire.MintDrop)
        );
    }

    /**
     * @dev THE DECIMALS TRAP, HANDLED. Every decimals value a floor divides by
     *      is READ off the wired token here, so a token that does not implement
     *      `decimals()` fails the wiring transaction rather than the first
     *      payment — and no divisor anywhere is a literal carried over from
     *      Stable's 6-dp world.
     *
     *      ⚠ Dropping the stablecoin (`DECISIONS.md §26`) left ONE token whose
     *      decimals this contract divides by, and it is the one that is
     *      genuinely unknown: BNBULL is issued by four.meme, so 18 is an
     *      EXPECTATION, not a fact. Do not simplify this away.
     */
    function _afterWire(Wire slot, address target) private {
        if (slot == Wire.Bnbull) {
            // ⚠ Checked in BOTH directions, because either slot can be written
            // second. BNBULL as its own middle hop builds a path containing a
            // self-pair, which `PancakeLibrary.sortTokens` rejects
            // (`IDENTICAL_ADDRESSES`) — a dead leg rather than a stolen one,
            // but a dead leg that only shows up as silent deferral.
            if (target == swapIntermediate()) revert BadIntermediate(target);
            bnbullDecimals = _readDecimals(target);
        } else if (slot == Wire.SwapIntermediate) {
            if (target == _wire(Wire.Bnbull)) revert BadIntermediate(target);
        }
    }

    function _readDecimals(address token) private view returns (uint8 d) {
        d = IERC20Metadata(token).decimals();
        if (d > MAX_TOKEN_DECIMALS) revert TokenDecimalsUnusable(d);
    }

    function _wire(Wire slot) internal view returns (address) {
        return _wires[uint8(slot)].current;
    }
}
