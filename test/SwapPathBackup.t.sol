// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {SplitterBase} from "./SplitterBase.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {MintBnbullSplitter} from "../contracts/MintBnbullSplitter.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {TimelockedAddress} from "../contracts/lib/TimelockedAddress.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockRouter.sol";

/**
 * @title SwapPathBackup
 * @notice ⚠ THE DORMANT BACKUP ROUTE — `DECISIONS.md §28`, `§29`, `§30`, `§37`.
 *
 * @dev The risk this file insures against, stated plainly:
 *
 *        > four.meme's `_templates()` lists **20 templates and 19 of them
 *        > graduate into a NON-BNB pool** (USDT, USDC, CAKE, NVDAB…). The
 *        > dominant flow lands in PancakeSwap v2 against **WBNB**, and a real
 *        > mainnet graduate was re-confirmed WBNB-paired. But the LP is burned
 *        > and the token is immutable, so if the launch form is ever answered
 *        > wrongly there is **no contract fix afterwards** — every buy leg would
 *        > point at a pool that does not exist, permanently.
 *
 *      So the swap carries an optional middle hop, wired off, forever we hope.
 *      Two claims are being made and both are tested here, in this order,
 *      because the second is worthless if the first is not true:
 *
 *        1. **NOTHING CHANGED.** Unwired — the default, the deploy state, and
 *           the expected end state — every swap is the same two-element
 *           `[WBNB, BNBULL]` hop against the same WBNB/BNBULL pair with the same
 *           1 BNB floor. The route is asserted element by element off the
 *           router mock, not inferred from the pot balance;
 *        2. **and the backup works, safely.** Wired, the route becomes
 *           `[WBNB, X, BNBULL]`, the floor follows onto the X/BNBULL pair, and
 *           — the part that matters most — **the floor is never compared in the
 *           wrong units**. `minPoolLiquidity` means 1 BNB. An X pair's reserve
 *           is X. Those two numbers must never meet, and the way they are kept
 *           apart is a second, X-denominated floor whose ZERO means "refuse to
 *           trade" rather than "no floor".
 *
 *      ⚠ AND IT IS ONE ADDRESS, NOT A SETTABLE `address[]`. Everything a
 *      settable path would have to VALIDATE — length >= 2, a first element that
 *      is the token being spent, a last element that is the wired BNBULL, no
 *      zero members, no gas-bomb length — is instead STRUCTURALLY IMPOSSIBLE to
 *      violate, and the tests below assert the structure rather than the
 *      guards. A path whose last hop is not BNBULL is the whole attack, and it
 *      cannot be expressed.
 */
contract SwapPathBackupSplitterTest is SplitterBase {
    /// @dev The alternate quote asset. 18dp like BSC-USDT — `BNB-CHAIN-FACTS
    ///      §1` — and the decimals matter, because the alt floor is denominated
    ///      in THIS token's smallest unit and nothing on chain divides by them.
    MockERC20 internal usdt;
    /// @dev The X/BNBULL pair. A DIFFERENT pool from WBNB/BNBULL, which is the
    ///      entire reason the factory mock had to learn per-pair answers: a mock
    ///      that answers one pair for everything cannot tell a floor that
    ///      followed the route from a floor pointed at the wrong book.
    MockV2Pair internal altPair;

    /// @notice 100,000 USDT in the alternate pair — healthy.
    uint256 internal constant ALT_HEALTHY = 100_000e18;
    /// @notice The X-denominated floor: 500 USDT. ⚠ NOT 1 ether. The number is
    ///         deliberately one that would be nonsense read as BNB.
    uint256 internal constant ALT_FLOOR = 500e18;

    function setUp() public virtual override {
        super.setUp();
        usdt = new MockERC20("Tether USD", "USDT", 18);
        altPair = new MockV2Pair();
        altPair.setTokens(address(usdt), address(bnbull));
        altPair.setReserves(uint112(ALT_HEALTHY), uint112(1e24));
        dex.v2Factory().setPairFor(address(usdt), address(bnbull), address(altPair));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE DEFAULT IS THE BEHAVIOUR THAT SHIPPED. NOTHING ELSE MATTERS
    //     UNTIL THIS IS TRUE.
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The slot is zero at deploy and the getter agrees. If this ever
    ///      needs a configuration transaction to be true, the insurance has
    ///      become the risk.
    function test_theBackupRouteIsDormantAtDeploy() public view {
        assertEq(mintSplit.swapIntermediate(), address(0), "wired on by default");
        (address cur, address pend, uint64 eta) =
            mintSplit.wireOf(PotSplitter.Wire.SwapIntermediate);
        assertEq(cur, address(0));
        assertEq(pend, address(0));
        assertEq(eta, 0);
        assertEq(mintSplit.minPoolLiquidityAlt(), 0, "and the alt floor is unset");
    }

    /**
     * @notice **THE GOVERNING ASSERTION.** With nothing wired the buy leg is
     *         the same single hop it has always been — asserted on the array
     *         the router actually received, element by element.
     */
    function test_theDefaultBuyPathIsStillExactlyWbnbThenBnbull() public {
        _sendNative(address(mintSplit), 10 ether);

        address[] memory p = dex.lastPath();
        assertEq(p.length, 2, "the default route grew a hop");
        assertEq(p[0], address(wbnb), "the input token must be the first element");
        assertEq(p[1], address(bnbull), "the last hop must be BNBULL");
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "and it bought the same amount");
        assertEq(dex.swapCalls(), 1, "one hop, one call");
    }

    /// @dev The sell leg too. It is only reachable with `DECISIONS.md §14`
    ///      switched off, but "unreachable today" is not "allowed to be wrong".
    function test_theDefaultSellPathIsStillExactlyBnbullThenWbnb() public {
        drop.setBnbullPaymentSellPolicy(true);
        _giveSplitterBnbull(alice, address(mintSplit), 1_000e18);

        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 1_000e18);

        address[] memory p = dex.lastPath();
        assertEq(p.length, 2, "the default sell route grew a hop");
        assertEq(p[0], address(bnbull));
        assertEq(p[1], address(wbnb));
        assertGt(potBnb.pool(), 0, "the sell leg landed");
    }

    /// @dev The floor still reads the WBNB/BNBULL pair and still means 1 BNB.
    function test_theDefaultFloorIsStillOneBnbOnTheWbnbPair() public {
        assertEq(mintSplit.minPoolLiquidity(), 1 ether);

        (address pair, uint256 reserve) = mintSplit.wbnbPoolLiquidity();
        assertEq(pair, address(dex.v2Pair()), "the default pool is the WBNB one");
        assertEq(reserve, uint256(dex.HEALTHY_RESERVE()));

        // And the boundary has not moved by a wei.
        dex.setPairReserves(uint112(1 ether - 1), 1e24);
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.swapCalls(), 0, "one wei under 1 BNB must still defer");

        dex.setPairReserves(uint112(1 ether), 1e24);
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.swapCalls(), 1, "exactly 1 BNB must still trade");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE BACKUP ROUTE, WHEN IT IS NEEDED
    // ══════════════════════════════════════════════════════════════════════

    /// @notice `[WBNB, USDT, BNBULL]` — the §30 case, working.
    function test_aWiredIntermediateRoutesThroughThreeHops() public {
        _wireAltRoute();

        _sendNative(address(mintSplit), 10 ether);

        address[] memory p = dex.lastPath();
        assertEq(p.length, 3, "the middle hop is missing");
        assertEq(p[0], address(wbnb), "still the token being spent");
        assertEq(p[1], address(usdt), "the intermediate");
        assertEq(p[2], address(bnbull), "and it MUST still end on BNBULL");
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "the pot was funded through it");
    }

    /// @dev The sell leg reverses: `[BNBULL, USDT, WBNB]`. Getting this
    ///      backwards would route the sale into a pair that does not exist.
    function test_theSellLegRoutesThroughTheIntermediateInReverse() public {
        _wireAltRoute();
        drop.setBnbullPaymentSellPolicy(true);
        _giveSplitterBnbull(alice, address(mintSplit), 1_000e18);

        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 1_000e18);

        address[] memory p = dex.lastPath();
        assertEq(p.length, 3);
        assertEq(p[0], address(bnbull), "the token being spent");
        assertEq(p[1], address(usdt));
        assertEq(p[2], address(wbnb), "and out to the pot asset");
        assertGt(potBnb.pool(), 0);
    }

    /**
     * @notice ⚠ THE PATH IS 2 OR 3 ELEMENTS AND ENDS ON BNBULL, BY
     *         CONSTRUCTION — the reason a full settable `address[]` was not
     *         worth its own weight.
     *
     * @dev A settable path would need five separate guards, each of which is a
     *      chance for a later edit to keep four. Here there is nothing to
     *      validate: the length is chosen by one branch, the first element is
     *      the token the caller is spending, and the last is read from the same
     *      `Wire.Bnbull` slot that the pot funding uses. They cannot disagree.
     */
    function test_thePathIsStructurallyBoundedInEveryConfiguration() public {
        _sendNative(address(mintSplit), 10 ether);
        address[] memory direct = dex.lastPath();

        _wireAltRoute();
        dex.resetSwapCalls();
        _sendNative(address(mintSplit), 10 ether);
        address[] memory hopped = dex.lastPath();

        assertLe(direct.length, 4, "a gas-bomb path must be unreachable");
        assertLe(hopped.length, 4, "a gas-bomb path must be unreachable");
        assertGe(direct.length, 2);
        assertGe(hopped.length, 2);
        assertEq(direct[direct.length - 1], address(bnbull), "a buy must end on BNBULL");
        assertEq(hopped[hopped.length - 1], address(bnbull), "a buy must end on BNBULL");
        for (uint256 i = 0; i < hopped.length; i++) {
            assertTrue(hopped[i] != address(0), "no path element may be zero");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. ⚠ THE FLOOR FOLLOWS THE ROUTE, AND NEVER IN THE WRONG UNITS
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice **THE UNIT MISMATCH, REFUSED RATHER THAN GUESSED.** An
     *         intermediate is wired, the alt floor is left at zero, and the
     *         WBNB/BNBULL pair is as deep as ever. A contract that reused
     *         `minPoolLiquidity` here would compare a USDT reserve against a
     *         number meaning 1 BNB and wave the trade through.
     *
     * @dev It defers instead — never trades, never reverts the entrypoint. That
     *      is the whole answer to "what if the operator sets the route and
     *      forgets the floor": the money waits, visibly, in a `…Deferred` event.
     */
    function test_aWiredRouteWithNoAltFloorRefusesToTradeAtAll() public {
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));
        assertEq(mintSplit.minPoolLiquidityAlt(), 0, "the operator forgot it");

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);

        assertEq(dex.swapCalls(), 0, "an unmeasured pool must never be traded");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "deferred, not lost");
        assertEq(potBnb.pool(), 1 ether, "and the wrap leg is untouched by any of it");
    }

    /// @dev The sweep says it out loud, because a keeper is allowed to fail
    ///      loudly and a silent "nothing happened" is how a dead leg survives.
    function test_theSweepNamesTheMissingAltFloor() public {
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));
        _sendNative(address(mintSplit), 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidMinLiquidity.selector, uint256(0))
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, 1);
    }

    /**
     * @notice The floor moves onto the X/BNBULL pair, and a deep WBNB/BNBULL
     *         pair does NOT rescue a dust one. Reading the old pool would be
     *         `BNB-CHAIN-FACTS.md §3` again: pricing off a book the swap does
     *         not touch.
     */
    function test_theFloorFollowsOntoTheOtherPairAndTheWbnbPairCannotRescueIt() public {
        _wireAltRoute();
        // The WBNB pair stays as deep as it has ever been.
        assertEq(uint256(dex.HEALTHY_RESERVE()), 1e24);
        // The pair the swap actually ends on holds 1 USDT against a 500 floor.
        altPair.setReserves(uint112(1e18), uint112(1e24));

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);

        assertEq(dex.swapCalls(), 0, "the floor was read off the wrong pool");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
    }

    /// @dev And it is denominated in X. 499 USDT defers, 500 trades — the same
    ///      inclusive boundary as the WBNB floor, in a different unit.
    function test_theAltFloorIsDenominatedInTheIntermediateAndIsInclusive() public {
        _wireAltRoute();

        altPair.setReserves(uint112(ALT_FLOOR - 1), uint112(1e24));
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "one unit under the alt floor must defer");

        altPair.setReserves(uint112(ALT_FLOOR), uint112(1e24));
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.swapCalls(), 1, "exactly at the alt floor must trade");
    }

    /// @dev The pair the reserve is read from is identified by `token0()`, on
    ///      the alternate pair exactly as on the WBNB one.
    function test_theAltReserveIsIdentifiedByToken0NotByAddressOrdering() public {
        _wireAltRoute();
        altPair.setTokens(address(bnbull), address(usdt));
        altPair.setReserves(type(uint112).max, uint112(1e18)); // r0 = BNBULL, r1 = USDT

        (address pair, uint256 reserve) = mintSplit.wbnbPoolLiquidity();
        assertEq(pair, address(altPair), "the pool view must follow the route");
        assertEq(reserve, 1e18, "the quote side was misidentified");

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "a thin pool read as deep is the whole bug again");
    }

    /// @dev The alt floor is owner-only and bounded. ZERO is legal here, and
    ///      means "stop trading the backup route" — the opposite of what zero
    ///      means on `setMinPoolLiquidity`, because the risks are not
    ///      symmetrical.
    function test_theAltFloorIsOwnerOnlyBoundedAndZeroIsTheKillSwitch() public {
        vm.prank(alice);
        vm.expectRevert();
        mintSplit.setMinPoolLiquidityAlt(ALT_FLOOR);

        uint256 tooBig = mintSplit.MAX_MIN_POOL_LIQUIDITY() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidMinLiquidity.selector, tooBig)
        );
        mintSplit.setMinPoolLiquidityAlt(tooBig);

        vm.expectEmit(false, false, false, true, address(mintSplit));
        emit PotSplitter.MinPoolLiquidityAltChanged(ALT_FLOOR);
        mintSplit.setMinPoolLiquidityAlt(ALT_FLOOR);
        assertEq(mintSplit.minPoolLiquidityAlt(), ALT_FLOOR);

        // The kill switch: back to zero, and the backup route stops trading.
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));
        mintSplit.setMinPoolLiquidityAlt(0);
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0);
    }

    /// @dev The WBNB floor is untouched by any of this: still owner-only, still
    ///      refuses zero, still 1 BNB.
    function test_theWbnbFloorStillRefusesZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidMinLiquidity.selector, uint256(0))
        );
        mintSplit.setMinPoolLiquidity(0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. ⚠ IT IS A RUG VECTOR, SO IT IS TIMELOCKED AND VALIDATED
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Point the route at a token you control and protocol money buys
     *         your own worthless supply. So the slot is a `Wire`: immediate
     *         while it is zero, then propose -> wait -> commit, with the pending
     *         target and its ETA public the whole time.
     */
    function test_theIntermediateIsTimelockedOnceItHoldsAnAddress() public {
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));

        MockERC20 rug = new MockERC20("Rug", "RUG", 18);

        // No second bootstrap. The instant door closes after the first set.
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, address(usdt))
        );
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(rug));

        uint64 eta = mintSplit.proposeWire(PotSplitter.Wire.SwapIntermediate, address(rug));
        assertEq(eta, uint64(block.timestamp + mintSplit.wiringDelay()));

        // Public the whole time — holders get the full delay to react.
        (address cur, address pend, uint64 storedEta) =
            mintSplit.wireOf(PotSplitter.Wire.SwapIntermediate);
        assertEq(cur, address(usdt), "the live route does not move on a proposal");
        assertEq(pend, address(rug), "the proposal is visible on chain");
        assertEq(storedEta, eta);
        assertEq(mintSplit.swapIntermediate(), address(usdt), "and the swap still uses the old one");

        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockedAddress.TimelockNotElapsed.selector, eta, uint64(block.timestamp)
            )
        );
        mintSplit.commitWire(PotSplitter.Wire.SwapIntermediate);

        vm.warp(eta);
        mintSplit.commitWire(PotSplitter.Wire.SwapIntermediate);
        assertEq(mintSplit.swapIntermediate(), address(rug));
    }

    /// @dev There is NO instant setter. If one ever appears, this is the test
    ///      that should have stopped it.
    function test_thereIsNoInstantPathSetterOnTheAbi() public {
        (bool ok,) = address(mintSplit).call(
            abi.encodeWithSignature("setSwapPath(address[])", new address[](2))
        );
        assertFalse(ok, "a settable path with no timelock is the rug vector itself");

        (ok,) = address(mintSplit).call(
            abi.encodeWithSignature("setSwapIntermediate(address)", address(usdt))
        );
        assertFalse(ok, "an instant intermediate setter is the same hole");
    }

    function test_onlyTheOwnerMayTouchTheRoute() public {
        vm.prank(alice);
        vm.expectRevert();
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));

        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));
        vm.prank(alice);
        vm.expectRevert();
        mintSplit.proposeWire(PotSplitter.Wire.SwapIntermediate, address(bnbull));
    }

    /// @dev A zero target is refused by the wiring library, which is what makes
    ///      "no path element may be zero" structural rather than checked.
    function test_theIntermediateCanNeverBeTheZeroAddress() public {
        vm.expectRevert(TimelockedAddress.ZeroTarget.selector);
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(0));

        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));
        vm.expectRevert(TimelockedAddress.ZeroTarget.selector);
        mintSplit.proposeWire(PotSplitter.Wire.SwapIntermediate, address(0));
    }

    /// @dev BNBULL as its own middle hop is a path with a self-pair in it —
    ///      `IDENTICAL_ADDRESSES` on the real router, i.e. a leg that dies
    ///      silently. Refused at wiring time, in BOTH orders, because either
    ///      slot can be the one written second.
    function test_theIntermediateCanNeverBeBnbullInEitherOrder() public {
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.BadIntermediate.selector, address(bnbull))
        );
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(bnbull));

        // The other order: the intermediate first, then BNBULL onto the same
        // address.
        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(bnbull));
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.BadIntermediate.selector, address(bnbull))
        );
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
    }

    /**
     * @notice ⚠ A WRONG GUESS MUST BE REVERSIBLE, or the insurance becomes the
     *         trap. `TimelockedAddress` refuses a zero target, so a wire can
     *         never be un-set — `address(wbnb)` is the sentinel for "back to
     *         direct", and it is safe to spend as a flag precisely because
     *         `[WBNB, WBNB, BNBULL]` is nonsense as a route.
     */
    function test_theWbnbSentinelReturnsTheRouteToDirect() public {
        _wireAltRoute();
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.lastPath().length, 3, "harness sanity: the backup is live");

        uint64 eta = mintSplit.proposeWire(PotSplitter.Wire.SwapIntermediate, address(wbnb));
        vm.warp(eta);
        mintSplit.commitWire(PotSplitter.Wire.SwapIntermediate);
        // ⚠ The timelock is 24h and `maxFloorAge` is 12h, so waiting out a
        // wiring change ALWAYS stales the keeper's floors. That is correct
        // behaviour — a stale floor defers — but it means a real operator has
        // to republish on the far side of the wait, and so does this test.
        _publishFloors(mintSplit);

        assertEq(mintSplit.swapIntermediate(), address(0), "the sentinel means direct");
        dex.resetSwapCalls();
        _sendNative(address(mintSplit), 10 ether);

        address[] memory p = dex.lastPath();
        assertEq(p.length, 2, "the route did not come home");
        assertEq(p[0], address(wbnb));
        assertEq(p[1], address(bnbull));

        // ...and the WBNB-denominated floor is in charge again.
        (address pair,) = mintSplit.wbnbPoolLiquidity();
        assertEq(pair, address(dex.v2Pair()));
        dex.setPairReserves(uint112(1 ether - 1), 1e24);
        dex.resetSwapCalls();
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "the 1 BNB floor is back in force");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. A BAD ROUTE DEFERS. IT NEVER BRICKS AN ENTRYPOINT.
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The wrong guess, live: an intermediate whose pair with BNBULL
     *         does not exist. The LP-slot call — the one `MintDrop._routeNative`
     *         makes with no try/catch of its own — must still succeed.
     */
    function test_anIntermediateWithNoPairDefersAndTheEntrypointStillSucceeds() public {
        _wireAltRoute();
        dex.v2Factory().setPairFor(address(usdt), address(bnbull), address(0));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotDeferred(PotSplitter.PotSource.Native, 2 ether, 2 ether);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");

        assertTrue(ok, "a wrong route must never brick the mint");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "the slice is kept");
        assertEq(dex.swapCalls(), 0);
        assertEq(potBnb.pool(), 1 ether, "the wrap leg never touches the route at all");
    }

    /// @dev And a route that exists but whose swap reverts — a pair with no
    ///      depth on the middle hop, on the real router — is the same story.
    function test_aRouteWhoseSwapRevertsDefersAndKeepsTheMoney() public {
        _wireAltRoute();
        dex.setRevertOnSwap(true);

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);

        // And once the route is fixed the backlog clears through the sweep.
        dex.setRevertOnSwap(false);
        vm.prank(keeper);
        uint256 funded =
            mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(1 ether));
        assertEq(funded, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), 0);
    }

    /// @dev An intermediate pointed at something that is not a token at all.
    ///      Still a deferral, still no revert.
    function test_aNonsenseIntermediateStillOnlyDefers() public {
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(0xDEAD));
        mintSplit.setMinPoolLiquidityAlt(ALT_FLOOR);
        dex.v2Factory().setPairFor(address(0xDEAD), address(bnbull), address(0));

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. THE KEEPER FLOORS ARE PATH-AGNOSTIC AND WERE NOT TOUCHED
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `bnbullPerBnb` is BNBULL wei per 1 BNB **in, end to end** — it
     *         prices the whole trip, not a hop — so the same input demands the
     *         same `minOut` whichever route carries it. Nothing about the
     *         keeper's job changes, and nothing in this change touched it.
     */
    function test_theKeeperFloorIsIdenticalOnBothRoutes() public {
        _sendNative(address(mintSplit), 10 ether);
        uint256 directFloor = dex.lastMinOut();

        _wireAltRoute();
        dex.resetSwapCalls();
        _sendNative(address(mintSplit), 10 ether);
        uint256 hoppedFloor = dex.lastMinOut();

        assertEq(hoppedFloor, directFloor, "the floor must price the trip, not the hop");
        assertEq(directFloor, (2 ether * FLOOR_BNBULL_PER_BNB) / 1e18, "and it is the keeper's rate");
    }

    /// @dev A zero floor is still refused, on either route. `minOut == 0` is a
    ///      blind swap and a blind swap is a free sandwich.
    function test_aBlindSwapIsStillRefusedOnTheBackupRoute() public {
        _wireAltRoute();

        // Build a backlog to sweep: a route that is down defers.
        dex.setRevertOnSwap(true);
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        dex.setRevertOnSwap(false);

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.BlindSwapRefused.selector);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, 0);

        // ...and a zero published rate defers every inline leg, as before.
        vm.prank(keeper);
        mintSplit.setFloors(0, 0);
        dex.resetSwapCalls();
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "a rate of zero must never authorise a swap");
    }

    /// @dev The measured-delta discipline is unchanged on three hops: a lying
    ///      router still cannot fund the pot with dust.
    function test_aLyingRouterStillCannotWedgeThePotOnTheBackupRoute() public {
        _wireAltRoute();
        dex.setLying(100); // 1% of the honest figure

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(potBnbull.pool(), 0, "1% of the quote must never be booked as the buy");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
    }

    /// @dev And it is still the FEE-SUPPORTING call, so a taxed four.meme
    ///      template B token survives the backup route too.
    function test_theBackupRouteStillUsesTheFeeSupportingCall() public {
        _wireAltRoute();
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.legacyCalls(), 0, "a taxed token would revert `Pancake: K` on that call");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Deploy-day wiring of the backup route: the intermediate, and the
    ///      X-denominated floor that must go with it.
    function _wireAltRoute() internal {
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));
        mintSplit.setMinPoolLiquidityAlt(ALT_FLOOR);
    }

    function _sendNative(address to, uint256 amount) internal {
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        (bool ok,) = to.call{value: amount}("");
        assertTrue(ok, "a never-fail entrypoint reverted");
    }

    /// @dev Send, then prove conservation: every wei either reached a pot or is
    ///      sitting here backed by a bucket.
    function _sendNativeAndAssertNothingLost(MintBnbullSplitter s, uint256 amount) internal {
        uint256 balBefore = address(s).balance;
        uint256 wrappedBefore = potBnb.pool();

        _sendNative(address(s), amount);

        uint256 wrappedAway = potBnb.pool() - wrappedBefore;
        assertEq(
            address(s).balance,
            balBefore + amount - wrappedAway,
            "value left the splitter without reaching a pot"
        );
        assertGe(
            address(s).balance,
            s.reservedOf(PotSplitter.PotSource.Native),
            "a bucket is not actually backed by balance"
        );
    }
}

/**
 * @title SwapPathBackupMintDropTest
 * @notice The same backup route on `MintDrop`, which carries its OWN copy of
 *         the swap.
 *
 * @dev ⚠ `MintDrop` DUPLICATES RATHER THAN INHERITS, so every change here lands
 *      twice and this half is the size-constrained one. Its floor is quoted on
 *      chain off `getAmountsOut` over the whole `path` rather than off the
 *      keeper's published rate — which is why the route change needs nothing
 *      done to it: `getAmountsOut` has always priced the array it is handed,
 *      end to end, however many hops are in it.
 */
contract SwapPathBackupMintDropTest is BnbullsBase {
    MockERC20 internal usdt;
    MockV2Pair internal altPair;

    uint256 internal constant ALT_HEALTHY = 100_000e18;
    uint256 internal constant ALT_FLOOR = 500e18;

    function setUp() public virtual override {
        super.setUp();
        usdt = new MockERC20("Tether USD", "USDT", 18);
        altPair = new MockV2Pair();
        altPair.setTokens(address(usdt), address(bnbull));
        altPair.setReserves(uint112(ALT_HEALTHY), uint112(1e24));
        router.v2Factory().setPairFor(address(usdt), address(bnbull), address(altPair));
    }

    // ─── 1. The default is what shipped ──────────────────────────────────

    function test_theBackupRouteIsDormantAtDeploy() public view {
        assertEq(drop.swapIntermediate(), address(0));
        assertEq(drop.minPoolLiquidityAlt(), 0);
        (address cur, address pend, uint64 eta) = drop.wireOf(MintDrop.Wire.SwapIntermediate);
        assertEq(cur, address(0));
        assertEq(pend, address(0));
        assertEq(eta, 0);
    }

    /// @notice **THE GOVERNING ASSERTION** for MintDrop's copy.
    function test_theDefaultBuyPathIsStillExactlyWbnbThenBnbull() public {
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();

        address[] memory p = router.lastPath();
        assertEq(p.length, 2, "the default route grew a hop");
        assertEq(p[0], address(wbnb));
        assertEq(p[1], address(bnbull));
        assertEq(potBnbull.pool(), 2 ether * BNBULL_PER_BNB, "and it bought the same amount");
    }

    function test_theDefaultSellPathIsStillExactlyBnbullThenWbnb() public {
        drop.setBnbullPaymentSellPolicy(true);
        _giveBnbull(alice, 10_000e18);

        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        address[] memory p = router.lastPath();
        assertEq(p.length, 2);
        assertEq(p[0], address(bnbull));
        assertEq(p[1], address(wbnb));
    }

    function test_theDefaultFloorIsStillOneBnbOnTheWbnbPair() public {
        assertEq(drop.minPoolLiquidity(), 1 ether);
        (address pair, uint256 reserve) = drop.wbnbPoolLiquidity();
        assertEq(pair, address(router.v2Pair()));
        assertEq(reserve, uint256(router.HEALTHY_RESERVE()));

        router.setPairReserves(uint112(1 ether - 1), 1e24);
        _donate(3 ether);
        assertEq(router.swapCalls(), 0, "one wei under 1 BNB must still defer");

        router.setPairReserves(uint112(1 ether), 1e24);
        _donate(3 ether);
        assertEq(router.swapCalls(), 1, "exactly 1 BNB must still trade");
    }

    // ─── 2. The backup route ─────────────────────────────────────────────

    function test_aWiredIntermediateRoutesThroughThreeHops() public {
        _wireAltRoute();
        _donate(3 ether);

        address[] memory p = router.lastPath();
        assertEq(p.length, 3);
        assertEq(p[0], address(wbnb));
        assertEq(p[1], address(usdt));
        assertEq(p[2], address(bnbull), "a buy MUST still end on BNBULL");
        assertEq(potBnbull.pool(), 2 ether * BNBULL_PER_BNB, "the pot was funded through it");
    }

    /// @dev The on-chain quote prices the WHOLE array, so the inline slippage
    ///      floor needs nothing done to it for a longer route.
    function test_theOnChainQuoteFollowsTheWholePathEndToEnd() public {
        _wireAltRoute();
        _donate(3 ether);

        address[] memory p = router.lastPath();
        uint256[] memory outs = router.getAmountsOut(2 ether, p);
        assertEq(outs.length, 3, "the quote must cover every hop");
        assertEq(outs[2], 2 ether * BNBULL_PER_BNB, "and price the trip end to end");
    }

    function test_theSellLegRoutesThroughTheIntermediateInReverse() public {
        _wireAltRoute();
        drop.setBnbullPaymentSellPolicy(true);
        _giveBnbull(alice, 10_000e18);

        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        address[] memory p = router.lastPath();
        assertEq(p.length, 3);
        assertEq(p[0], address(bnbull));
        assertEq(p[1], address(usdt));
        assertEq(p[2], address(wbnb));
        assertGt(potBnb.pool(), 0);
    }

    // ─── 3. The floor follows, and never in the wrong units ──────────────

    /// @notice The unit mismatch, refused. A mint must still succeed.
    function test_aWiredRouteWithNoAltFloorDefersAndTheMintStillSucceeds() public {
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(usdt));

        uint256 spent = _mintBnb(alice, 1);

        assertEq(bulls.balanceOf(alice), 1, "the mint itself must not care");
        assertEq(router.swapCalls(), 0, "an unmeasured pool must never be traded");
        assertGt(drop.pendingBnbullBuyNative(), 0, "the slice accrued instead");
        assertEq(potBnb.pool(), (spent * 1_000) / 10_000, "the wrap leg is untouched");
    }

    function test_theFloorFollowsOntoTheOtherPairAndTheWbnbPairCannotRescueIt() public {
        _wireAltRoute();
        altPair.setReserves(uint112(1e18), uint112(1e24)); // 1 USDT against a 500 floor

        _donate(3 ether);

        assertEq(router.swapCalls(), 0, "the floor was read off the wrong pool");
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);
        (address pair, uint256 reserve) = drop.wbnbPoolLiquidity();
        assertEq(pair, address(altPair), "the pool view must follow the route");
        assertEq(reserve, 1e18);
    }

    function test_theAltFloorIsDenominatedInTheIntermediateAndIsInclusive() public {
        _wireAltRoute();

        altPair.setReserves(uint112(ALT_FLOOR - 1), uint112(1e24));
        _donate(3 ether);
        assertEq(router.swapCalls(), 0, "one unit under the alt floor must defer");

        altPair.setReserves(uint112(ALT_FLOOR), uint112(1e24));
        _donate(3 ether);
        assertEq(router.swapCalls(), 1, "exactly at the alt floor must trade");
    }

    function test_theAltFloorIsOwnerOnlyBoundedAndEmits() public {
        vm.prank(alice);
        vm.expectRevert();
        drop.setMinPoolLiquidityAlt(ALT_FLOOR);

        uint256 tooBig = drop.MAX_MIN_POOL_LIQUIDITY() + 1;
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidMinLiquidity.selector, tooBig));
        drop.setMinPoolLiquidityAlt(tooBig);

        vm.expectEmit(false, false, false, true, address(drop));
        emit MintDrop.MinPoolLiquidityAltChanged(ALT_FLOOR);
        drop.setMinPoolLiquidityAlt(ALT_FLOOR);
        assertEq(drop.minPoolLiquidityAlt(), ALT_FLOOR);
    }

    /// @dev The keeper sweep names the missing floor rather than failing quietly.
    function test_theSweepNamesTheMissingAltFloor() public {
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(usdt));
        _donate(3 ether);
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidMinLiquidity.selector, uint256(0)));
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);
    }

    // ─── 4. Timelocked and validated ─────────────────────────────────────

    function test_theIntermediateIsTimelockedOnceItHoldsAnAddress() public {
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(usdt));
        MockERC20 rug = new MockERC20("Rug", "RUG", 18);

        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, address(usdt))
        );
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(rug));

        uint64 eta = drop.proposeWire(MintDrop.Wire.SwapIntermediate, address(rug));
        assertEq(drop.swapIntermediate(), address(usdt), "the live route does not move");

        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockedAddress.TimelockNotElapsed.selector, eta, uint64(block.timestamp)
            )
        );
        drop.commitWire(MintDrop.Wire.SwapIntermediate);

        vm.warp(eta);
        drop.commitWire(MintDrop.Wire.SwapIntermediate);
        assertEq(drop.swapIntermediate(), address(rug));
    }

    function test_thereIsNoInstantPathSetterOnTheAbi() public {
        (bool ok,) = address(drop).call(
            abi.encodeWithSignature("setSwapPath(address[])", new address[](2))
        );
        assertFalse(ok);
        (ok,) = address(drop).call(
            abi.encodeWithSignature("setSwapIntermediate(address)", address(usdt))
        );
        assertFalse(ok);
    }

    function test_theIntermediateCanNeverBeZeroOrBnbull() public {
        vm.expectRevert(TimelockedAddress.ZeroTarget.selector);
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.BadIntermediate.selector, address(bnbull))
        );
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(bnbull));
    }

    function test_onlyTheOwnerMayTouchTheRoute() public {
        vm.prank(alice);
        vm.expectRevert();
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(usdt));
    }

    /// @dev A wrong guess is reversible. `address(wbnb)` is the sentinel.
    function test_theWbnbSentinelReturnsTheRouteToDirect() public {
        _wireAltRoute();
        _donate(3 ether);
        assertEq(router.lastPath().length, 3, "harness sanity");

        uint64 eta = drop.proposeWire(MintDrop.Wire.SwapIntermediate, address(wbnb));
        vm.warp(eta);
        drop.commitWire(MintDrop.Wire.SwapIntermediate);

        assertEq(drop.swapIntermediate(), address(0));
        _donate(3 ether);
        address[] memory p = router.lastPath();
        assertEq(p.length, 2, "the route did not come home");
        assertEq(p[0], address(wbnb));
        assertEq(p[1], address(bnbull));

        (address pair,) = drop.wbnbPoolLiquidity();
        assertEq(pair, address(router.v2Pair()), "and the WBNB pool is the measure again");
    }

    // ─── 5. A bad route defers, it never bricks ──────────────────────────

    /**
     * @notice The un-guarded donation entrypoint — the one the Graveyard calls
     *         on every revive with no try/catch of its own. A wrong route must
     *         not brick a single revive.
     */
    function test_anIntermediateWithNoPairDefersAndNeverRevertsTheDonation() public {
        _wireAltRoute();
        router.v2Factory().setPairFor(address(usdt), address(bnbull), address(0));

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbullPotDeferred(MintDrop.PotSource.Native, 2 ether, 2 ether);
        drop.donatePotNative{value: 3 ether}();

        assertEq(drop.pendingBnbullBuyNative(), 2 ether, "the slice is kept, not lost");
        assertEq(address(drop).balance, 2 ether, "and it is genuinely still here");
        assertEq(router.swapCalls(), 0);
    }

    /// @dev A mint on a broken route still sells the bull and still takes the
    ///      money. The backlog clears through the sweep once the route is right.
    function test_aMintOnABrokenRouteStillCompletesAndTheBacklogClears() public {
        _wireAltRoute();
        router.v2Factory().setPairFor(address(usdt), address(bnbull), address(0));

        _mintBnb(alice, 1);
        assertEq(bulls.balanceOf(alice), 1);
        uint256 backlog = drop.pendingBnbullBuyNative();
        assertGt(backlog, 0);

        // The operator repoints the route at the pair that actually exists.
        router.v2Factory().setPairFor(address(usdt), address(bnbull), address(altPair));
        vm.prank(keeper);
        uint256 funded = drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);
        assertEq(funded, backlog * BNBULL_PER_BNB);
        assertEq(drop.pendingBnbullBuyNative(), 0, "the backlog cleared");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _wireAltRoute() internal {
        drop.bootstrapWire(MintDrop.Wire.SwapIntermediate, address(usdt));
        drop.setMinPoolLiquidityAlt(ALT_FLOOR);
    }

    /// @dev 100% of a donation goes to the pots, 2:1. No dev cut, no refund
    ///      arithmetic — the cleanest way to exercise the buy leg.
    function _donate(uint256 amount) internal {
        router.resetSwapCalls();
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        drop.donatePotNative{value: amount}();
    }
}
