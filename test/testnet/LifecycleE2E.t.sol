// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestnetDexBase} from "./TestnetDexBase.t.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

import {Bulls} from "../../contracts/Bulls.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";
import {MintBnbullSplitter} from "../../contracts/MintBnbullSplitter.sol";
import {PotSplitter} from "../../contracts/lib/PotSplitter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";

/**
 * @title LifecycleE2ETest
 * @notice **`DECISIONS.md §29`, end to end, against the real chain-97
 *         PancakeSwap.** This is the launch plan as an executable sequence:
 *
 *           curve phase  -> every BNBULL leg DEFERS AND ACCRUES.
 *                           Nothing reverts. Nothing bricks.
 *           graduation   -> a real v2 pair with real liquidity exists.
 *           sweep        -> the accrued BNB buys BNBULL through the REAL
 *                           router and lands in the pot.
 *           and only now -> BNBULL transfers work, so the 10% discount, the
 *                           fight stakes and the marketplace come alive.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHICH LEG IS DRIVEN, AND WHY
 *      ══════════════════════════════════════════════════════════════════════
 *      The sweep is driven through **`MintDrop`**, deliberately. §28/§9.3:
 *      four.meme graduates into PancakeSwap **v2**, and `MintDrop`'s v2 leg is
 *      currently **the only leg in the codebase that can reach the real book**.
 *      `PotSplitter`'s swap dialect is being migrated from v3 to v2 as this is
 *      written, so nothing here pins it: the splitter is exercised on the
 *      venue-AGNOSTIC half of its contract — the never-fail deferral, the
 *      accrual buckets, the never-sell BNBULL policy and the manual-buy hatch —
 *      none of which changes with the router shape.
 *
 *      ⚠ WHAT THAT LEAVES UNPROVEN, STATED UP FRONT: `PotSplitter.sweepBnbullPot`
 *      swapping through the real router is NOT asserted here. It cannot be until
 *      the v2 migration lands. That belongs in the report's gap list.
 *
 *      ⚠ The oracle and VRF are mocked (`test/mocks`). Neither is on the four.meme
 *      lifecycle path; standing up a real Chainlink feed would test Chainlink,
 *      not this.
 */
contract LifecycleE2ETest is TestnetDexBase {
    /// @notice A 2 BNB raise leaves 1.96 WBNB in the pool — a real book, deep
    ///         enough that a 0.1 BNB sweep is an ordinary trade rather than a
    ///         price event.
    uint256 internal constant RAISE = 2 ether;

    MockBnbull internal bnbull;
    Bulls internal bulls;
    Jackpot internal potBnbull;
    Jackpot internal potBnb;
    MintDrop internal drop;
    MintBnbullSplitter internal splitter;
    MockAggregator internal feed;
    MockVRFCoordinator internal coord;

    address internal treasury = address(0x7EA5);
    address internal lpTreasury = address(0x1B7EA5);
    address internal keeper = address(0xCEE9E2);

    function setUp() public override {
        super.setUp();

        // ── The token four.meme would have issued ─────────────────────────
        bnbull = _launchDefault(RAISE);

        // ── The game, wired to the REAL router and the REAL WBNB ──────────
        feed = new MockAggregator(8, 600e8);
        coord = new MockVRFCoordinator();
        bulls = new Bulls(address(this), 0xB011, bytes32(0));

        potBnbull = new Jackpot(address(bnbull), address(0), address(coord), 50);
        potBnb = new Jackpot(WBNB, address(0), address(coord), 100);

        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: address(this),
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        drop.bootstrapWire(MintDrop.Wire.Router, V2_ROUTER);
        drop.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        drop.setKeeper(keeper);

        splitter = new MintBnbullSplitter(address(this), WBNB, keeper);
        splitter.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
        splitter.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(potBnbull));
        splitter.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        splitter.bootstrapWire(PotSplitter.Wire.MintDrop, address(drop));
        // ⚠ `Wire.Router` is left UNWIRED on the splitter on purpose. Its swap
        //   dialect is mid-migration (v3 -> v2, §28/§9.3); an unwired route is
        //   the honest launch-day state anyway, and it exercises exactly the
        //   behaviour §29 needs: the BNBULL leg defers.

        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);
        potBnbull.setFunder(address(splitter), true);
        potBnb.setFunder(address(splitter), true);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Phase 1 — the curve. BNB works, BNBULL accrues, nothing bricks.
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice §29: "phase 1 launches BNB-only… every BNBULL leg is present in
     *         the contracts but reads as 'not available yet' and defers —
     *         **this is the normal launch state, not an error state.**"
     */
    function test_curvePhase_bnbullLegsDeferAndTheBnbLegWorks() public {
        assertEq(pad.statusOf(address(bnbull)), pad.STATUS_TRADING());
        assertEq(_pair(address(bnbull)), address(0), "no pool exists during the curve");

        uint256 donated = 3 ether;
        vm.deal(address(this), donated);
        drop.donatePotNative{value: donated}();

        // 20% BNBULL / 10% BNB, of a pot-only amount -> 2:1.
        uint256 expectBnbull = (donated * 2_000) / 3_000;
        uint256 expectBnb = donated - expectBnbull;

        // The BNBULL leg found no pool, so it ACCRUED. Visibly, on chain.
        assertEq(drop.pendingBnbullBuyNative(), expectBnbull, "the BNBULL leg must accrue");
        assertEq(wbnb.balanceOf(address(potBnb)), expectBnb, "the BNB pot funds from block one");
        assertEq(bnbull.balanceOf(address(potBnbull)), 0, "the BNBULL pot is empty, as expected");

        // Nothing reverted, and the accrued BNB is genuinely still here.
        assertEq(address(drop).balance, expectBnbull, "the deferred BNB is backed by balance");
    }

    /// @notice The never-fail splitter entrypoint, during the curve. `receive()`
    ///         is what every native mint's LP slice lands in — if it reverted,
    ///         every mint in the game would brick.
    function test_curvePhase_splitterReceiveNeverReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok, "receive() must never revert");

        assertEq(splitter.pendingBnbullBuyNative(), 0.2 ether, "20% accrues");
        assertEq(wbnb.balanceOf(address(potBnb)), 0.1 ether, "10% funds the WBNB pot");
        // The 70% dev share is simply retained as balance.
        assertEq(splitter.freeOf(PotSplitter.PotSource.Native), 0.7 ether);
    }

    /**
     * @notice A BNBULL-denominated payment during the curve. The pull hits the
     *         transfer gate, the splitter catches it, the payer keeps the money
     *         and **the caller's transaction still succeeds**.
     */
    function test_curvePhase_bnbullPaymentIsRefusedWithoutBrickingAnybody() public {
        uint256 held = _curveBuy(bnbull, alice, 0.2 ether, 0);
        assertGt(held, 0);

        vm.prank(alice);
        bnbull.approve(address(splitter), type(uint256).max);

        vm.prank(alice);
        splitter.routePayment(address(bnbull), 1e21);

        assertEq(bnbull.balanceOf(alice), held, "alice keeps every token");
        assertEq(bnbull.balanceOf(address(splitter)), 0, "nothing was pulled");
        assertEq(splitter.pendingBnbullDirect(), 0, "and nothing was booked that is not there");
    }

    /// @notice The deferred BNB is not stranded: the owner can pull it out and
    ///         place the buy by hand, which is the escape hatch that makes
    ///         "the route was down" survivable (`PotSplitter`'s trust-boundary
    ///         note).
    function test_curvePhase_deferredMoneyIsRecoverable() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 pending = splitter.pendingBnbullBuyNative();
        uint256 before = bob.balance;
        splitter.withdrawPendingForManualBuy(true, PotSplitter.PotSource.Native, bob, 0);
        assertEq(bob.balance - before, pending);
        assertEq(splitter.pendingBnbullBuyNative(), 0);
    }

    /**
     * @notice §9.1's integration constraints, as a shape. A curve-buy leg must
     *         land every failure in a try/catch and accrue — `Slippage`,
     *         `Disabled`, the operator halt — exactly like `lpUndelivered`.
     * @dev ⚠ REFERENCE SHAPE ONLY. No such leg exists in `contracts/` yet; this
     *      proves the four failure modes are all catchable and that none of them
     *      can brick a caller.
     */
    function test_curvePhase_aNeverFailCurveBuyLegAccruesOnEveryFailure() public {
        CurveBuyLeg leg = new CurveBuyLeg(address(pad), address(bnbull));

        // 1. An unreachable floor -> `Slippage` -> accrue.
        vm.deal(address(leg), 1 ether);
        leg.buyOrAccrue(0.1 ether, type(uint256).max);
        assertEq(leg.accrued(), 0.1 ether, "Slippage must accrue");
        assertEq(bnbull.balanceOf(address(leg)), 0);

        // 2. four.meme freezes the curve -> accrue.
        vm.prank(fourMemeOperator);
        pad.setTradingHalt(true);
        leg.buyOrAccrue(0.1 ether, 0);
        assertEq(leg.accrued(), 0.2 ether, "a pad-level halt must accrue");
        vm.prank(fourMemeOperator);
        pad.setTradingHalt(false);

        // 3. A live buy with a keeper-pegged floor works, and the amount out is
        //    a MEASURED DELTA because the call returns nothing.
        uint256 floorAmt = (pad.calcBuyAmount(address(bnbull), 0.1 ether) * 99) / 100;
        leg.buyOrAccrue(0.1 ether, floorAmt);
        assertEq(leg.accrued(), 0.2 ether, "a good buy must not accrue");
        assertGe(bnbull.balanceOf(address(leg)), floorAmt, "and it must deliver");

        // 4. After graduation the call reverts `Disabled` -> accrue. **The good
        //    failure**: it is how the leg learns the venue moved.
        _graduate(bnbull);
        leg.buyOrAccrue(0.1 ether, 0);
        assertEq(leg.accrued(), 0.3 ether, "Disabled must accrue, never revert");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Graduation, the sweep, and the game coming alive
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice **The whole of `DECISIONS.md §29`, in order.**
     */
    function test_theLaunchSequence_endToEnd() public {
        // ── PHASE 1: BNB-only. The BNBULL legs accrue. ────────────────────
        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();
        uint256 accrued = drop.pendingBnbullBuyNative();
        assertGt(accrued, 0, "the curve phase must leave money accrued");
        assertEq(bnbull.balanceOf(address(potBnbull)), 0);

        // The discount cannot be paid in BNBULL yet: the gate is shut.
        _curveBuy(bnbull, alice, 0.2 ether, 0);
        vm.prank(alice);
        bnbull.approve(address(this), type(uint256).max);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        bnbull.transferFrom(alice, address(this), 1e18);

        // ── GRADUATION ────────────────────────────────────────────────────
        _graduate(bnbull);
        address pair = _pair(address(bnbull));
        assertTrue(pair != address(0), "the pair must exist");
        (uint256 tokenSide, uint256 wbnbSide) = _reserves(address(bnbull));
        assertEq(wbnbSide, (RAISE * 9_800) / 10_000, "real WBNB liquidity");
        assertEq(tokenSide, SUPPLY_18DP - (SUPPLY_18DP * CURVE_SHARE_BPS) / 10_000);

        // ── THE SWEEP: accrued BNB -> BNBULL -> the pot, through the REAL
        //    PancakeSwap v2 router, with an OFF-CHAIN quoted floor. ────────
        uint256 minOut = (_quoteBnbIn(address(bnbull), accrued) * 99) / 100;
        assertGt(minOut, 0);

        uint256 potBefore = bnbull.balanceOf(address(potBnbull));
        vm.prank(keeper);
        uint256 funded = drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, minOut);

        assertEq(drop.pendingBnbullBuyNative(), 0, "the bucket must drain");
        assertGe(funded, minOut, "the swap must clear its floor");
        assertEq(
            bnbull.balanceOf(address(potBnbull)) - potBefore,
            funded,
            "the pot must receive exactly the measured delta"
        );

        // ── AND NOW THE GAME COMES ALIVE ─────────────────────────────────
        // The 10% discount's payment pull, which reverted 30 lines ago.
        vm.prank(alice);
        bnbull.approve(address(this), type(uint256).max);
        uint256 aliceBefore = bnbull.balanceOf(alice);
        bnbull.transferFrom(alice, address(this), 1e18);
        assertEq(aliceBefore - bnbull.balanceOf(alice), 1e18, "exact amount, no tax");

        // A BNBULL-denominated payment through the splitter now funds the pot
        // directly, selling nothing (`DECISIONS.md §14`).
        vm.prank(alice);
        bnbull.approve(address(splitter), type(uint256).max);
        uint256 payment = 1e22;
        uint256 potBefore2 = bnbull.balanceOf(address(potBnbull));
        vm.prank(alice);
        splitter.routePayment(address(bnbull), payment);
        assertEq(
            bnbull.balanceOf(address(potBnbull)) - potBefore2,
            (payment * 3_000) / 10_000,
            "30% BNBULL pot / 70% dev, and no DEX is touched"
        );
    }

    /// @notice A blind sweep is refused even after the pool is real. §9.2: "a
    ///         zero floor is a blind swap", and there is no state in which that
    ///         becomes acceptable.
    function test_sweepRefusesABlindSwapEvenWithARealPool() public {
        vm.deal(address(this), 1 ether);
        drop.donatePotNative{value: 1 ether}();
        _graduate(bnbull);

        vm.prank(keeper);
        vm.expectRevert(MintDrop.BlindSwapRefused.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 0);
    }

    /// @notice A floor that is too high simply defers: the sweep reverts, the
    ///         bucket is untouched, and nothing is bricked. `PotSplitter`'s
    ///         "a stale floor always defers safely" promise, on a real pool.
    function test_anUnreachableFloorLeavesTheBucketIntact() public {
        vm.deal(address(this), 1 ether);
        drop.donatePotNative{value: 1 ether}();
        uint256 accrued = drop.pendingBnbullBuyNative();
        _graduate(bnbull);

        vm.prank(keeper);
        vm.expectRevert();
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, type(uint128).max);

        assertEq(drop.pendingBnbullBuyNative(), accrued, "the money must still be there");
    }

    /**
     * @notice ⚠ THE REGRESSION THAT WOULD COST THE MOST. After graduation the
     *         inline leg starts working on its own — no keeper, no sweep —
     *         because the pool the router quotes off finally exists.
     */
    function test_afterGraduationTheInlineLegWorksWithNoKeeperAtAll() public {
        _graduate(bnbull);

        uint256 potBefore = bnbull.balanceOf(address(potBnbull));
        vm.deal(address(this), 0.3 ether);
        drop.donatePotNative{value: 0.3 ether}();

        assertEq(drop.pendingBnbullBuyNative(), 0, "nothing should defer any more");
        assertGt(bnbull.balanceOf(address(potBnbull)), potBefore, "the pot funds inline");
    }
}

/**
 * @title CurveBuyLeg
 * @notice ⚠ TEST-ONLY REFERENCE SHAPE for the `§9.1` curve-buy integration.
 *         Not production code and not wired to anything.
 *
 * @dev Four constraints, all from `FOUR-MEME-LAUNCH-ROUTE.md §9.1`:
 *        1. every failure — `Slippage`, `Disabled`, the operator halt, a
 *           template revert — is caught and ACCRUED, never propagated;
 *        2. the amount out is a MEASURED BALANCE DELTA, because the pad's call
 *           returns nothing;
 *        3. `funds == msg.value`, and there is a payable fallback anyway,
 *           because overpayment is refunded;
 *        4. `minAmount` is passed in by the caller. Nothing here invents a
 *           zero floor.
 */
contract CurveBuyLeg {
    address public immutable pad;
    address public immutable token;
    uint256 public accrued;
    uint256 public bought;

    event Deferred(uint256 amount, uint256 bucket);

    constructor(address pad_, address token_) {
        pad = pad_;
        token = token_;
    }

    function buyOrAccrue(uint256 funds, uint256 minAmount) external {
        uint256 before = IBalanceOf(token).balanceOf(address(this));
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = pad.call{value: funds}(
            abi.encodeWithSelector(0x87f27655, token, funds, minAmount)
        );
        if (!ok) {
            accrued += funds;
            emit Deferred(funds, accrued);
            return;
        }
        bought += IBalanceOf(token).balanceOf(address(this)) - before;
    }

    receive() external payable {}
}

interface IBalanceOf {
    function balanceOf(address) external view returns (uint256);
}
