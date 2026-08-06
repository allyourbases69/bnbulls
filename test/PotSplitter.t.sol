// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SplitterBase} from "./SplitterBase.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {MintBnbullSplitter} from "../contracts/MintBnbullSplitter.sol";
import {ReviveBuySplitter} from "../contracts/ReviveBuySplitter.sol";
import {TimelockedAddress} from "../contracts/lib/TimelockedAddress.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MockERC20, NoDecimalsToken} from "./mocks/MockERC20.sol";
import {BrokenWBNB} from "./mocks/MockWBNB.sol";
import {
    SplitterV2Router,
    SplitterPolicySource,
    SplitterWrongAbiPolicy,
    SplitterHostilePot,
    SplitterReentrantPot,
    SplitterFeeToken,
    SplitterFatDecimalsToken,
    SplitterFrozenCaller,
    SplitterRefusingReceiver
} from "./mocks/SplitterMocks.sol";

/**
 * @title PotSplitterTest
 * @notice THE SHARED NEVER-FAIL CORE. `BNBULLS-BOOTSTRAP.md §6`, in full.
 *
 * @dev ⚠ MOCKS ONLY, NO MAINNET FORK — see `SplitterBase.t.sol` for why.
 *
 *      The rule this file exists to prove:
 *
 *        > an entrypoint that a FROZEN upstream calls with NO try/catch on the
 *        > caller's side MUST NEVER REVERT, or it bricks that caller forever.
 *
 *      Two live instances of that shape in this codebase:
 *        - `MintDrop._routeNative` forwards the LP slice with a bare
 *          `lpTreasury.call{value}("")`. Point `lpTreasury` at
 *          `MintBnbullSplitter` and that lands in its `receive()`.
 *        - `Graveyard` donates the revive pot slice to its `mintDrop` slot.
 *          Point that at `ReviveBuySplitter` and it lands in
 *          `donatePotNative()`.
 *
 *      So every failure mode below drives an entrypoint into that state and
 *      asserts THREE things, never fewer:
 *        1. the call RETURNS NORMALLY,
 *        2. every wei is ACCRUED into a `pending*` bucket — nothing is lost,
 *        3. a `…Deferred` EVENT is emitted, so which branch ran is on chain and
 *           nobody has to take our word for which one production is in.
 *
 *      Then the money is shown to be recoverable afterwards, because "the route
 *      was down for an hour" has to have an answer that is not "it's gone".
 */
contract PotSplitterTest is SplitterBase {
    // ══════════════════════════════════════════════════════════════════════
    //  1. THE ENTRYPOINTS MUST NEVER REVERT
    // ══════════════════════════════════════════════════════════════════════

    function test_theHappyPathRoutesBothLegsInline() public {
        _sendNative(address(mintSplit), 10 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "20% bought BNBULL");
        assertEq(potBnb.pool(), 1 ether, "10% wrapped straight into the WBNB pot");
        assertEq(address(mintSplit).balance, 7 ether, "70% retained for the dev");
        assertEq(mintSplit.reservedOf(PotSplitter.PotSource.Native), 0);
    }

    function test_survivesARouterThatReverts() public {
        dex.setRevertOnSwap(true);
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "the swap leg deferred");
        assertEq(potBnb.pool(), 1 ether, "the wrap leg needs no router and still landed");
    }

    /**
     * @notice THE LAUNCH STATE, not an edge case. BNBULL launches on
     *         four.meme's bonding curve (`DECISIONS.md §4`) and there is no
     *         PancakeSwap pair at all until it graduates, so every inline buy
     *         fails on day one.
     */
    function test_survivesARouterThatReturnsZero() public {
        dex.setQuoteZero(true);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotDeferred(PotSplitter.PotSource.Native, 2 ether, 2 ether);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");

        assertTrue(ok, "the LP-slot call must never fail");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        assertEq(potBnbull.pool(), 0, "nothing was bought with nothing");
    }

    function test_survivesAnUnwiredRouter() public {
        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(potBnbull));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(s), true);
        potBnb.setFunder(address(s), true);
        _publishFloors(s);

        _sendNative(address(s), 10 ether);

        // The cheap pre-check short-circuits before the try/catch even runs.
        assertEq(s.pendingBnbullBuyNative(), 2 ether);
        assertEq(potBnb.pool(), 1 ether, "the wrap leg still works with no router");
    }

    function test_survivesAnUnwiredPot() public {
        MintBnbullSplitter s = _bareMintSplitter();
        _sendNative(address(s), 10 ether);

        assertEq(s.pendingBnbullBuyNative(), 2 ether);
        assertEq(s.pendingBnbPotNative(), 1 ether);
        assertEq(address(s).balance, 10 ether, "every wei is still here");
    }

    /// @dev The realistic deploy-ordering bug: the pot exists but has not
    ///      granted the splitter the funder role yet.
    function test_survivesAPotThatHasNotGrantedTheFunderRole() public {
        potBnbull.setFunder(address(mintSplit), false);
        potBnb.setFunder(address(mintSplit), false);

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        assertEq(mintSplit.pendingBnbPotNative(), 1 ether);
    }

    function test_survivesAPotThatRevertsOnFunding() public {
        SplitterHostilePot bad = new SplitterHostilePot(address(bnbull));
        bad.setFundReverts(true);

        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
        s.bootstrapWire(PotSplitter.Wire.Router, address(dex));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(bad));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        potBnb.setFunder(address(s), true);
        _publishFloors(s);

        _sendNative(address(s), 10 ether);

        assertEq(s.pendingBnbullBuyNative(), 2 ether, "the swap rolled back with the funding");
        assertEq(bnbull.balanceOf(address(s)), 0, "the caught swap left no half-state behind");
        assertEq(potBnb.pool(), 1 ether);
    }

    /// @dev Even the WRAP — the one leg with no router, no slippage and no
    ///      liquidity dependency — must defer rather than revert.
    function test_survivesABrokenWrapper() public {
        BrokenWBNB bad = new BrokenWBNB();
        MintBnbullSplitter s = new MintBnbullSplitter(owner, address(bad), keeper);
        SplitterHostilePot pot = new SplitterHostilePot(address(bad));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(pot));

        _sendNative(address(s), 10 ether);
        assertEq(s.pendingBnbPotNative(), 1 ether, "the wrap leg deferred instead of reverting");
        assertEq(pot.pool(), 0);
    }

    function test_survivesStaleFloors() public {
        vm.warp(block.timestamp + 13 hours); // maxFloorAge is 12h
        assertFalse(mintSplit.floorsFresh());

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "a swap leg on a stale floor defers");
        assertEq(potBnb.pool(), 1 ether, "the wrap leg has no floor to be stale");
    }

    function test_survivesZeroFloors() public {
        // The kill switch: a keeper that has lost its price source writes zero.
        vm.prank(keeper);
        mintSplit.setFloors(0, 0);

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        assertEq(dex.swapCalls(), 0, "a zero floor must never reach the router");
    }

    function test_survivesAPolicyReadThatReverts() public {
        SplitterPolicySource p = new SplitterPolicySource();
        p.setMode(SplitterPolicySource.Mode.Revert);
        MintBnbullSplitter s = _splitterWithPolicy(address(p));

        _sendNative(address(s), 10 ether);

        // Fell back to the local 2000 / 1000 / never-sell.
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether));
        assertEq(potBnb.pool(), 1 ether);
        assertEq(address(s).balance, 7 ether);
    }

    /**
     * @notice ⚠ THE ONE THING TRY/CATCH DOES NOT COVER is a callee that BURNS
     *         the caller's gas rather than reverting: an out-of-gas sub-call
     *         leaves only 1/64 of the frame, which is not enough to finish the
     *         accrual. `POLICY_READ_GAS` is what makes this survivable, and
     *         this test is why it is load-bearing.
     * @dev The 1,000,000 gas budget is the point. Without the cap the sub-call
     *      would take 63/64 of it (~984k) and leave ~16k — nowhere near enough
     *      to run two pot legs. With the cap it takes 100k and the frame lives.
     */
    function test_survivesAPolicyReadThatBurnsGas() public {
        SplitterPolicySource p = new SplitterPolicySource();
        p.setMode(SplitterPolicySource.Mode.BurnGas);
        MintBnbullSplitter s = _splitterWithPolicy(address(p));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool ok,) = address(s).call{value: 10 ether, gas: 1_000_000}("");

        assertTrue(ok, "a gas-burning policy source bricked a never-fail entrypoint");
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "the local fallback carried the split");
        assertEq(potBnb.pool(), 1 ether);
    }

    function test_survivesAPolicySourceWithTheWrongAbi() public {
        MintBnbullSplitter s = _splitterWithPolicy(address(new SplitterWrongAbiPolicy()));
        _sendNative(address(s), 10 ether);
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether));
    }

    function test_survivesAPolicySourceWithNoCodeAtAll() public {
        MintBnbullSplitter s = _splitterWithPolicy(address(0xDEAD));
        _sendNative(address(s), 10 ether);
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether));
        assertEq(potBnb.pool(), 1 ether);
    }

    function test_survivesTotalCollapse() public {
        dex.setRevertOnSwap(true);
        potBnbull.setFunder(address(mintSplit), false);
        potBnb.setFunder(address(mintSplit), false);
        vm.warp(block.timestamp + 13 hours);

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(
            mintSplit.pendingBnbullBuyNative() + mintSplit.pendingBnbPotNative(),
            3 ether,
            "the pot slices are all still here"
        );
        assertEq(address(mintSplit).balance, 10 ether);
    }

    /// @dev Fuzzed over the payment size with every route dead. A frozen
    ///      upstream calls this un-guarded; it may not revert for ANY input.
    function testFuzz_receiveNeverRevertsWithEveryRouteDead(uint96 amount) public {
        dex.setRevertOnSwap(true);
        potBnbull.setFunder(address(mintSplit), false);
        potBnb.setFunder(address(mintSplit), false);

        vm.deal(alice, uint256(amount));
        vm.prank(alice);
        (bool ok,) = address(mintSplit).call{value: uint256(amount)}("");

        assertTrue(ok);
        uint256 pots = (uint256(amount) * 2_000) / 10_000 + (uint256(amount) * 1_000) / 10_000;
        assertEq(
            mintSplit.pendingBnbullBuyNative() + mintSplit.pendingBnbPotNative(),
            pots,
            "wei went missing on the deferred path"
        );
    }

    /**
     * @notice The shape the whole pattern exists for: an upstream that treats a
     *         failed forward as fatal. On fefers `MintDrop._routeNative` did
     *         `if (!ok) revert LpTransferFailed()`, so a reverting `receive()`
     *         bricked every native mint.
     */
    function test_aFrozenUpstreamCallerIsNeverBricked() public {
        SplitterFrozenCaller frozen = new SplitterFrozenCaller();
        dex.setRevertOnSwap(true);
        potBnbull.setFunder(address(mintSplit), false);
        potBnb.setFunder(address(mintSplit), false);

        vm.deal(address(frozen), 10 ether);
        frozen.push(payable(address(mintSplit)), 10 ether);

        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);

        // ...and the same through the explicit selector.
        vm.deal(address(frozen), 10 ether);
        frozen.pushWithSelector(
            payable(address(mintSplit)), abi.encodeWithSignature("routeNative()"), 10 ether
        );
        assertEq(mintSplit.pendingBnbullBuyNative(), 4 ether);
    }

    /// @dev The Graveyard's two selectors, un-guarded, with everything broken.
    function test_theGraveyardSelectorsAreNeverFail() public {
        SplitterFrozenCaller frozen = new SplitterFrozenCaller();
        dex.setRevertOnSwap(true);
        potBnbull.setFunder(address(reviveSplit), false);
        potBnb.setFunder(address(reviveSplit), false);

        vm.deal(address(frozen), 6 ether);
        frozen.pushWithSelector(
            payable(address(reviveSplit)), abi.encodeWithSignature("donatePotNative()"), 6 ether
        );

        assertEq(reviveSplit.pendingBnbullBuyNative(), 4 ether, "2:1 of a pot-only donation");
        assertEq(reviveSplit.pendingBnbPotNative(), 2 ether);
        assertEq(address(reviveSplit).balance, 6 ether, "this splitter retains nothing");
    }

    function test_aMissingAllowanceEmitsPullFailedInsteadOfReverting() public {
        bnbull.mint(alice, 1_000e18); // no approve
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(reviveSplit));
        emit ReviveBuySplitter.PullFailed(address(bnbull), alice, 100e18);
        reviveSplit.donatePotToken(address(bnbull), 100e18);

        assertEq(bnbull.balanceOf(alice), 1_000e18, "the caller keeps its money");
        assertEq(reviveSplit.pendingBnbullDirect(), 0, "nothing was routed either");
    }

    function test_anUnsupportedAssetIsIgnoredNotRejected() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.expectEmit(true, false, false, true, address(reviveSplit));
        emit ReviveBuySplitter.UnsupportedAssetIgnored(address(stray), 5e18);
        reviveSplit.donatePotToken(address(stray), 5e18);

        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit MintBnbullSplitter.UnsupportedAssetIgnored(address(0), 5e18);
        mintSplit.routePayment(address(0), 5e18);
    }

    function test_zeroIsANoOpNotARevert() public {
        vm.prank(alice);
        (bool ok,) = address(mintSplit).call{value: 0}("");
        assertTrue(ok);
        mintSplit.routePayment(address(bnbull), 0);
        reviveSplit.donatePotToken(address(bnbull), 0);
        vm.prank(alice);
        reviveSplit.donatePotNative{value: 0}();
    }

    /**
     * @notice `PotSplitter` deliberately carries NO `nonReentrant` on its
     *         entrypoints: `ReentrancyGuard` REVERTS, and a reverting modifier
     *         on a never-fail entrypoint is exactly the brick the pattern
     *         exists to prevent. This proves that is safe.
     */
    function test_aReentrantDeliveryIsNeitherDoubleCountedNorDoubleSpent() public {
        SplitterReentrantPot pot = new SplitterReentrantPot(address(wbnb));

        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(pot));
        vm.deal(address(pot), 1 ether);
        // 9 wei re-entered mid-funding: enough to exercise the entrypoint, small
        // enough that its own BNB slice rounds to zero and does not recurse.
        pot.arm(payable(address(s)), 9 wei, 1);

        _sendNative(address(s), 10 ether);

        assertEq(pot.funded(), 1 ether, "the outer funding landed exactly ONCE");
        assertEq(pot.reentries(), 1, "and the entrypoint accepted the re-entrant delivery");
        assertEq(s.pendingBnbullBuyNative(), 2 ether + 1 wei, "outer 20% + the inner delivery's");
        assertEq(s.pendingBnbPotNative(), 0, "the outer BNB leg funded, so nothing deferred");
        assertEq(address(s).balance, 10 ether + 9 wei - 1 ether, "10 in, 9 wei back in, 1 out");
    }

    /// @dev And when a re-entrant pot clobbers its own allowance on the way
    ///      through, the outer leg simply DEFERS. Even a pot actively fighting
    ///      the splitter cannot make the entrypoint revert.
    function test_aPotThatReEntersDeeplyOnlyCausesItsOwnLegToDefer() public {
        SplitterReentrantPot pot = new SplitterReentrantPot(address(wbnb));

        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(pot));
        vm.deal(address(pot), 5 ether);
        pot.arm(payable(address(s)), 1 ether, 1);

        _sendNative(address(s), 10 ether);

        assertEq(pot.funded(), 0, "the outer funding was rolled back with the caught revert");
        assertEq(s.pendingBnbPotNative(), 1 ether, "so it accrued instead");
        assertEq(s.pendingBnbullBuyNative(), 2 ether);
        assertEq(address(s).balance, 10 ether, "and the pot's 1 ether went back with the rollback");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. MEASURED BALANCE DELTAS, NEVER THE ROUTER'S WORD
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A router that reports 10x what it delivered must not be able to
     *         book 10x into the pot. What lands is `balanceOf` after minus
     *         before, always.
     */
    function test_theBookedFigureIsTheMeasuredDeltaNotTheRoutersWord() public {
        dex.setOverreport(100_000); // claim 10x, transfer the honest amount

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotFundedInline(
            PotSplitter.PotSource.Native, 2 ether, _bnbullFromBnb(2 ether)
        );
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");

        assertTrue(ok);
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "the lie was not booked");
    }

    /**
     * @notice THE lying-router case: full quote reported, 1% actually
     *         transferred. The measured delta misses `minOut`, the swap is
     *         rejected, and the slice accrues — so the lie cannot fund a pot
     *         with nothing.
     */
    function test_aLyingRouterCannotFundThePotWithAlmostNothing() public {
        dex.setLying(100); // transfer 1% of what it claims

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        assertEq(potBnbull.pool(), 0, "the pot must not be fed dust");
        assertEq(bnbull.balanceOf(address(mintSplit)), 0, "the partial buy rolled back");
    }

    function test_aRouterThatTransfersNothingAtAllDefers() public {
        dex.setLying(0);
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        assertEq(potBnbull.pool(), 0);
    }

    /**
     * @notice `minOut == 0` is refused outright as a BLIND SWAP. A swap with no
     *         floor is a free sandwich, and a dead pool is exactly when the
     *         right answer is to defer rather than trade.
     * @dev Reached here with a payment so small the floor rounds to zero, which
     *      is the realistic route in — a non-zero rate can still produce a zero
     *      floor on dust.
     */
    function test_aFloorThatRoundsToZeroIsRefusedAsABlindSwap() public {
        vm.prank(keeper);
        mintSplit.setFloors(1, 1); // absurdly low but non-zero rates

        _sendNativeAndAssertNothingLost(mintSplit, 1000 wei);
        assertEq(mintSplit.pendingBnbullBuyNative(), 200 wei);
        assertEq(dex.swapCalls(), 0, "a zero floor must never reach the router");
    }

    function test_theSweepAlsoRefusesAZeroFloorButNotForADirectLeg() public {
        dex.setRevertOnSwap(true);
        _sendNative(address(mintSplit), 10 ether);
        dex.setRevertOnSwap(false);

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.BlindSwapRefused.selector);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, 0);

        // A BNBULL-denominated bucket needs no floor: nothing is swapped.
        _giveSplitterBnbull(alice, address(mintSplit), 100e18);
        potBnbull.setFunder(address(mintSplit), false);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);
        potBnbull.setFunder(address(mintSplit), true);
        assertEq(mintSplit.pendingBnbullDirect(), 30e18);

        vm.prank(keeper);
        uint256 funded = mintSplit.sweepBnbullPot(PotSplitter.PotSource.Bnbull, 0, 0);
        assertEq(funded, 30e18);
    }

    /**
     * @notice A fee-on-transfer OUTPUT token cannot wedge a pot: the measured
     *         delta is short of the floor, the swap is rejected, and the slice
     *         accrues instead of the pot silently receiving less than it paid
     *         for.
     */
    function test_aFeeOnTransferOutputTokenCannotWedgeThePot() public {
        SplitterFeeToken feeBull = new SplitterFeeToken("FeeBull", "FBULL", 18, 500); // 5%
        SplitterHostilePot pot = new SplitterHostilePot(address(feeBull));
        SplitterV2Router r = new SplitterV2Router(address(wbnb));
        r.setRate(address(wbnb), address(feeBull), 60_000, 1);
        feeBull.mint(address(r), 1e30);

        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(feeBull));
        s.bootstrapWire(PotSplitter.Wire.Router, address(r));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(pot));
        _publishFloors(s);

        _sendNative(address(s), 10 ether);

        assertEq(s.pendingBnbullBuyNative(), 2 ether, "5% skim < 1% floor headroom, so it defers");
        assertEq(pot.pool(), 0);
        assertEq(feeBull.balanceOf(address(s)), 0, "no orphan tokens left behind");
    }

    /**
     * @dev A fee-on-transfer INPUT token cannot wedge anything either: the pull
     *      is measured, so only what actually arrived is ever routed.
     *
     *      ⚠ REWRITTEN for `DECISIONS.md §26` to tax BNBULL rather than the
     *      stablecoin, and that is the more honest test: BNBULL is
     *      launchpad-issued, so a transfer gate is a thing to VERIFY at deploy
     *      rather than assume — and pre-graduation four.meme tokens refuse
     *      transfers outright, which is the extreme of the same failure.
     */
    function test_aFeeOnTransferPaymentTokenIsRoutedOnWhatArrived() public {
        SplitterFeeToken feeBull = new SplitterFeeToken("FeeBull", "FBULL", 18, 100); // 1%
        SplitterV2Router r = new SplitterV2Router(address(wbnb));
        r.setRate(address(feeBull), address(wbnb), 1, 60_000);
        vm.deal(address(this), address(this).balance + 1e21);
        wbnb.deposit{value: 1e21}();
        wbnb.transfer(address(r), 1e21);

        Jackpot pot = new Jackpot(address(feeBull), address(0), address(coord), 50);

        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(feeBull));
        s.bootstrapWire(PotSplitter.Wire.Router, address(r));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(pot));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        pot.setFunder(address(s), true);
        potBnb.setFunder(address(s), true);
        _publishFloors(s);

        feeBull.mint(alice, 1_000e18);
        vm.startPrank(alice);
        feeBull.approve(address(s), type(uint256).max);
        s.routePayment(address(feeBull), 100e18);
        vm.stopPrank();

        // 1% skimmed on the way in: 99 arrived, so the split is of 99. `§14`
        // sends the whole 30% to the BNBULL pot as tokens, less the token's own
        // 1% on the way into the pot.
        uint256 arrived = 99e18;
        uint256 slice = (arrived * 3_000) / 10_000;
        assertEq(pot.pool(), (slice * 9_900) / 10_000);
        assertEq(s.reservedOf(PotSplitter.PotSource.Bnbull), 0, "nothing had to defer");
    }

    /// @dev The floor handed to the router is the keeper's published rate
    ///      applied to the slice — not a router-derived quote, which a
    ///      front-run would simply move first.
    function test_theFloorHandedToTheRouterIsTheKeepersPublishedRate() public {
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.lastMinOut(), (2 ether * FLOOR_BNBULL_PER_BNB) / 1e18);
    }

    function test_noAllowanceIsLeftStandingAfterASwapOrAFunding() public {
        _sendNative(address(mintSplit), 10 ether);
        assertEq(wbnb.allowance(address(mintSplit), address(dex)), 0);
        assertEq(wbnb.allowance(address(mintSplit), address(potBnb)), 0);
        assertEq(bnbull.allowance(address(mintSplit), address(potBnbull)), 0);

        _giveSplitterBnbull(alice, address(mintSplit), 1_000e18);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);
        assertEq(bnbull.allowance(address(mintSplit), address(dex)), 0);
        assertEq(bnbull.allowance(address(mintSplit), address(potBnbull)), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. STALE FLOORS DEFER, NEVER BRICK — IN BOTH DIRECTIONS
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Direction one: too OLD. Past `maxFloorAge` the rates are treated as
    ///      absent, so a dead keeper degrades to "everything accrues" —
    ///      visibly, in the events — instead of trading on a week-old price.
    function test_staleByAgeDefersVisibly() public {
        vm.warp(block.timestamp + 12 hours + 1);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotDeferred(PotSplitter.PotSource.Native, 2 ether, 2 ether);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");

        assertTrue(ok);
        assertEq(dex.swapCalls(), 0, "a stale floor must never authorise a trade");
    }

    /// @dev The boundary is inclusive: exactly `maxFloorAge` old is still fresh.
    function test_theFreshnessBoundaryIsInclusive() public {
        vm.warp(block.timestamp + 12 hours);
        assertTrue(mintSplit.floorsFresh());
        vm.warp(block.timestamp + 1);
        assertFalse(mintSplit.floorsFresh());
    }

    /**
     * @dev Direction two: too HIGH for the current market. The floor is FRESH,
     *      so the pre-check passes and the swap is genuinely attempted — it
     *      simply misses `amountOutMinimum`, the revert is caught, and the
     *      slice accrues. A stale floor always defers safely, never bricks.
     *
     *      The mechanism is pinned on the SWEEP, whose revert is not swallowed:
     *      `SwapOutBelowMin(received, minimum)` names both numbers, proving the
     *      rejection came from the MEASURED output and not from the pre-check.
     *      (Inside the inline path nothing survives to be asserted — the whole
     *      sub-frame rolls back, which is the point of it.)
     */
    function test_aFloorStaleInTheOtherDirectionMissesMinOutAndAccrues() public {
        uint256 tooHigh = RATE_BNBULL_PER_BNB * 2; // BNBULL "doubled", keeper asleep
        vm.prank(keeper);
        mintSplit.setFloors(tooHigh, FLOOR_WBNB_PER_BNBULL);
        assertTrue(mintSplit.floorsFresh(), "the floor is FRESH, just wrong");

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);
        assertEq(potBnbull.pool(), 0, "nothing was bought at a price the market will not give");

        // The same floor, on the path that is allowed to revert, names the
        // measured shortfall out loud.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                PotSplitter.SwapOutBelowMin.selector,
                _bnbullFromBnb(2 ether),
                (2 ether * tooHigh) / 1e18
            )
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, (2 ether * tooHigh) / 1e18);
    }

    /// @dev Writing ONE rate as zero disables only that leg. Both share a
    ///      timestamp on purpose: a partial refresh would leave one leg
    ///      authorised by the other leg's freshness.
    function test_aZeroRateDisablesOnlyItsOwnLeg() public {
        vm.prank(keeper);
        mintSplit.setFloors(0, FLOOR_WBNB_PER_BNBULL);

        _sendNative(address(mintSplit), 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "the BNB->BNBULL leg is off");
        assertEq(potBnb.pool(), 1 ether, "the wrap leg is unaffected");

        // ...and the leg that needs NO floor at all is unaffected too: `§14`
        // routes a BNBULL payment straight into the pot with no swap.
        _giveSplitterBnbull(alice, address(mintSplit), 1_000e18);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);
        assertEq(potBnbull.pool(), 30e18, "the direct BNBULL leg still runs");
        assertEq(dex.swapCalls(), 0, "BNBULL WAS SOLD");
    }

    function test_maxFloorAgeIsBounded() public {
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.InvalidFloorAge.selector, uint256(0)));
        mintSplit.setMaxFloorAge(0);

        uint256 tooLong = mintSplit.MAX_FLOOR_AGE() + 1;
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.InvalidFloorAge.selector, tooLong));
        mintSplit.setMaxFloorAge(tooLong);

        mintSplit.setMaxFloorAge(1 hours);
        assertEq(mintSplit.maxFloorAge(), 1 hours);
    }

    function test_onlyTheKeeperOrOwnerMayPublishFloors() public {
        vm.prank(alice);
        vm.expectRevert(PotSplitter.NotKeeperOrOwner.selector);
        mintSplit.setFloors(1, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE POT-ROUTING POLICY (DECISIONS §13 + §14)
    // ══════════════════════════════════════════════════════════════════════

    function test_thePolicyIsReadLiveOffMintDrop() public {
        (uint256 a, uint256 b, bool sells) = mintSplit.potPolicy();
        assertEq(a, 2_000);
        assertEq(b, 1_000);
        assertFalse(sells, "DECISIONS 14: never sell BNBULL, and it is the DEFAULT");

        // Retune MintDrop and the splitter follows without a transaction of its
        // own — one source of truth on chain.
        drop.setPotShares(1_500, 1_500);
        (a, b,) = mintSplit.potPolicy();
        assertEq(a, 1_500);
        assertEq(b, 1_500);

        _sendNative(address(mintSplit), 10 ether);
        assertEq(potBnbull.pool(), _bnbullFromBnb(1.5 ether));
        assertEq(potBnb.pool(), 1.5 ether);
    }

    function test_theFallbackEngagesWhenMintDropIsUnwired() public {
        MintBnbullSplitter s = _splitterWithPolicy(address(0));
        (uint256 a, uint256 b, bool sells) = s.potPolicy();
        assertEq(a, 2_000, "the fallback launches at the same numbers, so it is never a surprise");
        assertEq(b, 1_000);
        assertFalse(sells);

        s.setFallbackPolicy(2_500, 500, false);
        (a, b,) = s.potPolicy();
        assertEq(a, 2_500);
        assertEq(b, 500);
    }

    /**
     * @notice An out-of-bounds live policy CANNOT BE ADOPTED. The read is
     *         checked against `MAX_TOTAL_POT_BPS` and rejected in favour of the
     *         local fallback, so a mis-wired policy source can never make the
     *         pots take more than half of a payment.
     */
    function test_anOutOfBoundsPolicyCannotBeAdopted() public {
        SplitterPolicySource p = new SplitterPolicySource();
        p.setPolicy(6_000, 1_000, true); // 7000 > MAX_TOTAL_POT_BPS
        MintBnbullSplitter s = _splitterWithPolicy(address(p));

        (uint256 a, uint256 b, bool sells) = s.potPolicy();
        assertEq(a, 2_000, "rejected, fell back");
        assertEq(b, 1_000);
        assertFalse(sells, "and the sell flag came from the fallback too, not the rogue source");

        _sendNative(address(s), 10 ether);
        assertEq(address(s).balance, 7 ether, "the dev share was never squeezed");
    }

    /**
     * @notice 🔴 FINDING. `potPolicy()` promises in its own NatSpec that an
     *         unwired slot, a wrong ABI, a revert, an out-of-gas OR an
     *         out-of-bounds answer all mean "use the local policy, never fail
     *         the player". An answer whose two shares SUM ABOVE 2^256 does not:
     *         the bounds check `a + b <= MAX_TOTAL_POT_BPS` is evaluated in the
     *         try's SUCCESS BLOCK, which runs in `potPolicy`'s own frame, so it
     *         panics with an arithmetic overflow instead of falling through to
     *         the fallback.
     *
     *         `potPolicy` is called from `_route`, which is called straight
     *         from `receive()`. A panic there IS the brick this whole pattern
     *         exists to prevent.
     *
     * @dev SEVERITY: low in practice, because the only way to reach it is for
     *      the owner to point `Wire.MintDrop` at a contract that answers those
     *      three selectors with absurd values — the real `MintDrop` cannot
     *      (`setPotShares` bounds the sum to 5,000). But that slot is
     *      TIMELOCKED precisely because it is not assumed to be trustworthy,
     *      and the documented contract is "any answer degrades to the
     *      fallback". This is the one answer that does not.
     *
     *      FIX: do the addition in `unchecked`, or bound each share
     *      individually before adding — e.g.
     *      `if (a <= MAX_TOTAL_POT_BPS && b <= MAX_TOTAL_POT_BPS && a + b <=
     *      MAX_TOTAL_POT_BPS)`. Either makes the check total.
     */
    function test_FINDING_anOverflowingPolicyAnswerBricksTheEntrypoint() public {
        SplitterPolicySource p = new SplitterPolicySource();
        p.setMode(SplitterPolicySource.Mode.Huge); // each share is 2^255
        MintBnbullSplitter s = _splitterWithPolicy(address(p));

        // The view itself should degrade to the fallback and never revert.
        (uint256 a, uint256 b,) = s.potPolicy();
        assertEq(a, 2_000, "potPolicy() must fall back, not panic");
        assertEq(b, 1_000);

        // ...and the never-fail entrypoint must survive it.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool ok,) = address(s).call{value: 10 ether}("");
        assertTrue(ok, "receive() reverted on a policy answer: every native mint would brick");
    }

    /// @dev Exactly on the ceiling is still adopted; one bps over is not.
    function test_thePolicyBoundIsInclusive() public {
        SplitterPolicySource p = new SplitterPolicySource();
        MintBnbullSplitter s = _splitterWithPolicy(address(p));

        p.setPolicy(4_000, 1_000, false); // == MAX_TOTAL_POT_BPS
        (uint256 a,,) = s.potPolicy();
        assertEq(a, 4_000);

        p.setPolicy(4_000, 1_001, false);
        (a,,) = s.potPolicy();
        assertEq(a, 2_000, "one bps over the ceiling and the fallback takes over");
    }

    function test_theLocalFallbackIsBoundedToo() public {
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.InvalidShare.selector, uint256(5_001)));
        mintSplit.setFallbackPolicy(4_000, 1_001, false);

        mintSplit.setFallbackPolicy(4_000, 1_000, true);
        assertEq(mintSplit.fallbackBnbullShareBps(), 4_000);
        assertTrue(mintSplit.fallbackSellsForBnbLeg());
    }

    /// @dev The raw read is self-gated: it is `external` ONLY so `potPolicy`
    ///      can try/catch it in one place.
    function test_theRawPolicyReadIsSelfGated() public {
        vm.prank(alice);
        vm.expectRevert(PotSplitter.NotSelf.selector);
        mintSplit.readMintDropPolicy();
    }

    /// @dev So are the two inline workers — they are the only things that can
    ///      spend this contract's balance, so nobody else may reach them.
    function test_theInlineWorkersAreSelfGated() public {
        vm.startPrank(alice);
        vm.expectRevert(PotSplitter.NotSelf.selector);
        mintSplit.routeToBnbullPotInline(PotSplitter.PotSource.Native, 1 ether);
        vm.expectRevert(PotSplitter.NotSelf.selector);
        mintSplit.routeToBnbPotInline(PotSplitter.PotSource.Native, 1 ether);
        vm.expectRevert(PotSplitter.NotSelf.selector);
        mintSplit.pullInline(address(bnbull), bob, 1e18);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. THE BACKLOG IS RECOVERABLE
    // ══════════════════════════════════════════════════════════════════════

    function test_theKeeperSweepsTheBacklogOnceTheRouteIsBack() public {
        dex.setQuoteZero(true); // launch day: no pool
        _sendNative(address(mintSplit), 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);

        dex.setQuoteZero(false); // the token graduated the curve
        uint256 offChainFloor = (_bnbullFromBnb(2 ether) * 99) / 100;
        vm.prank(keeper);
        uint256 funded = mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, offChainFloor);

        assertEq(funded, _bnbullFromBnb(2 ether));
        assertEq(potBnbull.pool(), funded);
        assertEq(mintSplit.pendingBnbullBuyNative(), 0);
        assertEq(address(mintSplit).balance, 7 ether, "only the retained share is left");
    }

    function test_sweepsArePartialBoundedAndGated() public {
        dex.setRevertOnSwap(true);
        _sendNative(address(mintSplit), 10 ether);
        dex.setRevertOnSwap(false);

        vm.prank(keeper);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0.5 ether, 1);
        assertEq(mintSplit.pendingBnbullBuyNative(), 1.5 ether);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InsufficientPending.selector, 2 ether, 1.5 ether)
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 2 ether, 1);

        vm.prank(alice);
        vm.expectRevert(PotSplitter.NotKeeperOrOwner.selector);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, 1);

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.NothingToDo.selector);
        mintSplit.sweepBnbPot(PotSplitter.PotSource.Bnbull, 0, 1);
    }

    function test_deferredEventsCarryTheRunningBucketTotal() public {
        dex.setRevertOnSwap(true);
        vm.deal(alice, 20 ether);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotDeferred(PotSplitter.PotSource.Native, 2 ether, 2 ether);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");
        assertTrue(ok);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotDeferred(PotSplitter.PotSource.Native, 2 ether, 4 ether);
        (ok,) = address(mintSplit).call{value: 10 ether}("");
        assertTrue(ok);
    }

    /**
     * @notice THE TRUST BOUNDARY, TESTED BOTH WAYS. Money in a `pending*`
     *         bucket has not entered a pot, so the owner can pull it out and
     *         place the buy by hand. Money that has REACHED a pot can never
     *         come out except through a won ticket — that guarantee IS the
     *         product.
     */
    function test_pendingIsWithdrawableButPotMoneyIsNot() public {
        dex.setRevertOnSwap(true);
        _sendNative(address(mintSplit), 10 ether);

        assertEq(potBnb.pool(), 1 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);

        vm.expectEmit(false, false, false, true, address(mintSplit));
        emit PotSplitter.PendingWithdrawnForManualBuy(
            PotSplitter.PotSource.Native, true, address(0xBEEF), 2 ether
        );
        mintSplit.withdrawPendingForManualBuy(
            true, PotSplitter.PotSource.Native, address(0xBEEF), 0
        );
        assertEq(address(0xBEEF).balance, 2 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 0);

        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnb.sweepForeignToken(address(wbnb), owner, 1 ether);
        assertEq(potBnb.pool(), 1 ether);
    }

    function test_withdrawUnreservedCannotReachPotMoney() public {
        dex.setRevertOnSwap(true);
        _sendNative(address(mintSplit), 10 ether);

        // 10 in, 1 wrapped away, 3 slices... only 2 deferred natively (the BNB
        // leg wrapped fine), so free == 10 - 1 - 2 == 7.
        assertEq(mintSplit.freeOf(PotSplitter.PotSource.Native), 7 ether);

        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InsufficientFree.selector, 8 ether, 7 ether)
        );
        mintSplit.withdrawUnreserved(PotSplitter.PotSource.Native, owner, 8 ether);

        uint256 before = owner.balance;
        mintSplit.withdrawUnreserved(PotSplitter.PotSource.Native, owner, 0);
        assertEq(owner.balance - before, 7 ether);
        assertEq(address(mintSplit).balance, 2 ether, "the deferred slice is untouched");
    }

    function test_ownerHatchesAreOwnerOnlyAndRefuseAZeroDestination() public {
        vm.prank(alice);
        vm.expectRevert();
        mintSplit.withdrawUnreserved(PotSplitter.PotSource.Native, alice, 0);

        vm.expectRevert(PotSplitter.ZeroAddress.selector);
        mintSplit.withdrawUnreserved(PotSplitter.PotSource.Native, address(0), 0);

        vm.expectRevert(PotSplitter.ZeroAddress.selector);
        mintSplit.withdrawPendingForManualBuy(true, PotSplitter.PotSource.Native, address(0), 0);
    }

    /// @dev The owner hatches ARE allowed to revert — they are not never-fail
    ///      paths — and a refusing destination is exactly when they should.
    function test_aRefusingDestinationRevertsTheOwnerHatch() public {
        SplitterRefusingReceiver bad = new SplitterRefusingReceiver();
        _sendNative(address(mintSplit), 10 ether);

        vm.expectRevert(PotSplitter.NativeSendFailed.selector);
        mintSplit.withdrawUnreserved(PotSplitter.PotSource.Native, address(bad), 1 ether);
    }

    function test_rescueRefusesTheAccountedTokensAndAllowsStrays() public {
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.InsufficientFree.selector, 1, 0));
        mintSplit.rescueToken(address(bnbull), owner, 1);

        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(mintSplit), 5e18);
        mintSplit.rescueToken(address(stray), owner, 5e18);
        assertEq(stray.balanceOf(owner), 5e18);
    }

    function test_routeHeldIsGatedAndBoundedByTheFreeBalance() public {
        // `MintDrop._routeToken` forwards its ERC-20 LP slice with a plain
        // `safeTransfer`, which gives this contract no callback to notice it.
        bnbull.mint(address(mintSplit), 100e18);

        vm.prank(alice);
        vm.expectRevert(PotSplitter.NotKeeperOrOwner.selector);
        mintSplit.routeHeld(PotSplitter.PotSource.Bnbull, 0);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InsufficientFree.selector, 200e18, 100e18)
        );
        mintSplit.routeHeld(PotSplitter.PotSource.Bnbull, 200e18);

        vm.prank(keeper);
        mintSplit.routeHeld(PotSplitter.PotSource.Bnbull, 0);
        // `§14`: 30% into the BNBULL pot as tokens, 70% retained, no DEX.
        assertEq(potBnbull.pool(), 30e18);
        assertEq(bnbull.balanceOf(address(mintSplit)), 70e18);

        // ⚠ The retained 70% is FREE balance, not a bucket, so a second
        // `routeHeld` legitimately routes it again — that is the dial working,
        // not a double-spend. `NothingToDo` is what an EMPTY asset gives.
        vm.prank(keeper);
        vm.expectRevert(PotSplitter.NothingToDo.selector);
        mintSplit.routeHeld(PotSplitter.PotSource.Native, 0);
    }

    /// @dev `routeHeld` may never spend money a deferred pot leg already has a
    ///      claim on.
    function test_routeHeldCannotSpendReservedMoney() public {
        dex.setRevertOnSwap(true);
        _sendNative(address(mintSplit), 10 ether);
        dex.setRevertOnSwap(false);

        assertEq(mintSplit.reservedOf(PotSplitter.PotSource.Native), 2 ether);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InsufficientFree.selector, 8 ether, 7 ether)
        );
        mintSplit.routeHeld(PotSplitter.PotSource.Native, 8 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. RULE 1: NO 1e12, EVERY DIVISOR RE-DERIVED FROM A LIVE READ
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE DECIMALS TRAP. A floor denominated per ONE WHOLE unit of its
     *         input token must produce the same number whatever that token's
     *         precision is. On fefers the divisor was the constant `1e12`; here
     *         it is `10 ** decimals()`, READ at wiring time.
     *
     * @dev ⚠ REWRITTEN, NOT DELETED, for `DECISIONS.md §26`. The old version
     *      drove a 6dp and an 18dp STABLECOIN through `bnbullPerStable`. That
     *      rate is gone with the asset — but `wbnbPerBnbull` is the identical
     *      shape ("WBNB wei per ONE WHOLE BNBULL"), and it divides by the
     *      decimals of the one token nobody can check in advance, because
     *      four.meme issues it. So the trap moved; it did not close.
     *
     *      The leg is only reachable with `§14`'s never-sell policy switched
     *      OFF, which is exactly why it needs a test: it is the leg nobody
     *      exercises by accident.
     */
    function test_theBnbullFloorDividesByTheTokensOwnDecimals() public {
        uint256 want = (30e18 * FLOOR_WBNB_PER_BNBULL) / 1e18;

        // 18 dp control: 30 whole BNBULL in.
        MintBnbullSplitter s18 = _isolatedSellBnbullSplitter(address(bnbull));
        _giveSplitterBnbull(alice, address(s18), 1_000e18);
        vm.prank(alice);
        s18.routePayment(address(bnbull), 100e18);
        assertEq(dex.lastMinOut(), want, "18dp: floor is 30 whole units x the rate");

        // 6 dp. SAME published rate, SAME floor, because the divisor is read.
        MockERC20 bull6 = new MockERC20("BNBull", "BNBULL", 6);
        dex.setRate(address(bull6), address(wbnb), 1e12, 60_000);
        MintBnbullSplitter s6 = _isolatedSellBnbullSplitter(address(bull6));
        assertEq(s6.bnbullDecimals(), 6, "decimals are READ, never assumed");

        bull6.mint(alice, 1_000e6);
        vm.startPrank(alice);
        bull6.approve(address(s6), type(uint256).max);
        s6.routePayment(address(bull6), 100e6);
        vm.stopPrank();

        assertEq(dex.lastMinOut(), want, "6dp: the SAME floor from the SAME rate");
    }

    function test_theBnbFloorDividesBy1e18BecauseThatIsAChainFact() public {
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.lastMinOut(), (2 ether * FLOOR_BNBULL_PER_BNB) / 1e18);
    }

    function test_wiringATokenWithNoDecimalsFailsTheWiringTx() public {
        MintBnbullSplitter s = _bareMintSplitter();
        NoDecimalsToken bad = new NoDecimalsToken();
        vm.expectRevert();
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bad));
        assertEq(s.bnbullDecimals(), 0, "a half-wired token left its divisor behind");
    }

    function test_wiringATokenWithAbsurdDecimalsFailsTheWiringTx() public {
        MintBnbullSplitter s = _bareMintSplitter();
        SplitterFatDecimalsToken bad = new SplitterFatDecimalsToken();
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.TokenDecimalsUnusable.selector, 37));
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bad));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  7. WIRING IS TIMELOCKED, NEVER ONE-TIME-SET
    // ══════════════════════════════════════════════════════════════════════

    function test_bootstrapIsImmediateOnlyWhileASlotIsEmpty() public {
        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.Router, address(dex));

        SplitterV2Router other = new SplitterV2Router(address(wbnb));
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, address(dex))
        );
        s.bootstrapWire(PotSplitter.Wire.Router, address(other));
    }

    function test_repointingAWireNeedsThePublishedDelay() public {
        SplitterV2Router other = new SplitterV2Router(address(wbnb));
        uint64 eta = mintSplit.proposeWire(PotSplitter.Wire.Router, address(other));

        (address current, address pending, uint64 slotEta) =
            mintSplit.wireOf(PotSplitter.Wire.Router);
        assertEq(current, address(dex));
        assertEq(pending, address(other), "the pending target is public the whole time");
        assertEq(slotEta, eta);

        vm.expectRevert();
        mintSplit.commitWire(PotSplitter.Wire.Router);

        vm.warp(eta);
        mintSplit.commitWire(PotSplitter.Wire.Router);
        (, address router,,,) = mintSplit.wires();
        assertEq(router, address(other));
    }

    function test_aPendingWireCanBeCancelled() public {
        SplitterV2Router other = new SplitterV2Router(address(wbnb));
        mintSplit.proposeWire(PotSplitter.Wire.Router, address(other));
        mintSplit.cancelWire(PotSplitter.Wire.Router);

        (, address pending,) = mintSplit.wireOf(PotSplitter.Wire.Router);
        assertEq(pending, address(0));

        vm.expectRevert(TimelockedAddress.NothingPending.selector);
        mintSplit.cancelWire(PotSplitter.Wire.Router);
    }

    function test_theWiringDelayIsBounded() public {
        uint256 tooShort = mintSplit.MIN_WIRING_DELAY() - 1;
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.DelayOutOfRange.selector, tooShort));
        mintSplit.setWiringDelay(tooShort);

        uint256 tooLong = mintSplit.MAX_WIRING_DELAY() + 1;
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.DelayOutOfRange.selector, tooLong));
        mintSplit.setWiringDelay(tooLong);

        mintSplit.setWiringDelay(7 days);
        assertEq(mintSplit.wiringDelay(), 7 days);
    }

    /// @dev `keeper` is deliberately NOT timelocked: it can only push money INTO
    ///      a pot, never out.
    function test_theKeeperSlotIsAPlainSetter() public {
        mintSplit.setKeeper(bob);
        assertEq(mintSplit.keeper(), bob);

        vm.prank(alice);
        vm.expectRevert();
        mintSplit.setKeeper(alice);
    }

    function test_socialsAreOwnerSettableStringsNotConstants() public {
        assertEq(mintSplit.website(), "https://bnbulls.xyz");
        assertEq(mintSplit.twitter(), "https://x.com/WeAreBNBulls");
        assertEq(mintSplit.telegram(), "https://t.me/WeAreBNBulls");

        mintSplit.setSocials("a", "b", "c");
        assertEq(mintSplit.website(), "a");
    }

    /**
     * @notice The minimum-liquidity floor is a BOUNDED OWNER-SETTABLE variable
     *         (`BNBULLS-BOOTSTRAP.md §0`), and **zero is refused**.
     *
     * @dev Zero would re-open the exact hole the floor exists to close, and
     *      there is already a safe way to stop trading — `setFloors(0, 0)`,
     *      which defers. This replaces `setPoolFees`: v2 has no fee tiers, so
     *      the dial that used to select a pool (and could therefore select the
     *      WRONG pool) is gone, and this one only ever says "is the one
     *      canonical pool real enough to trade into".
     */
    function test_theMinimumLiquidityFloorIsBoundedAndRefusesZero() public {
        assertEq(mintSplit.minPoolLiquidity(), 1 ether, "launch default");

        vm.expectRevert(abi.encodeWithSelector(PotSplitter.InvalidMinLiquidity.selector, uint256(0)));
        mintSplit.setMinPoolLiquidity(0);

        uint256 tooBig = mintSplit.MAX_MIN_POOL_LIQUIDITY() + 1;
        vm.expectRevert(abi.encodeWithSelector(PotSplitter.InvalidMinLiquidity.selector, tooBig));
        mintSplit.setMinPoolLiquidity(tooBig);

        vm.prank(alice);
        vm.expectRevert();
        mintSplit.setMinPoolLiquidity(5 ether);

        vm.expectEmit(false, false, false, true, address(mintSplit));
        emit PotSplitter.MinPoolLiquidityChanged(5 ether);
        mintSplit.setMinPoolLiquidity(5 ether);
        assertEq(mintSplit.minPoolLiquidity(), 5 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    function _sendNative(address to, uint256 amount) internal {
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        (bool ok,) = to.call{value: amount}("");
        assertTrue(ok, "a never-fail entrypoint reverted");
    }

    /// @dev Send, then prove conservation: every wei either reached a pot or is
    ///      sitting here backed by a bucket. Nothing evaporates.
    function _sendNativeAndAssertNothingLost(MintBnbullSplitter s, uint256 amount) internal {
        uint256 potBefore = potBnb.pool();
        uint256 balBefore = address(s).balance;

        _sendNative(address(s), amount);

        uint256 wrappedAway = potBnb.pool() - potBefore;
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

    /// @dev A fully wired splitter whose live-policy slot points wherever the
    ///      test wants — including nowhere.
    function _splitterWithPolicy(address policy) internal returns (MintBnbullSplitter s) {
        s = new MintBnbullSplitter(owner, address(wbnb), keeper);
        _wireSplitter(s, policy);
    }

    /// @dev A splitter wired to `bull` with the never-sell policy switched OFF
    ///      and the BNBULL pot leg switched off, so the ONLY swap it can make
    ///      is BNBULL -> WBNB and `dex.lastMinOut()` is unambiguously that
    ///      leg's floor.
    function _isolatedSellBnbullSplitter(address bull)
        internal
        returns (MintBnbullSplitter s)
    {
        s = new MintBnbullSplitter(owner, address(wbnb), keeper);
        s.bootstrapWire(PotSplitter.Wire.Bnbull, bull);
        s.bootstrapWire(PotSplitter.Wire.Router, address(dex));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        potBnb.setFunder(address(s), true);
        // 0% BNBULL pot / 30% BNB pot, and SELLING allowed: the one
        // configuration in which `wbnbPerBnbull` is ever consulted.
        s.setFallbackPolicy(0, 3_000, true);
        _publishFloors(s);
    }
}
