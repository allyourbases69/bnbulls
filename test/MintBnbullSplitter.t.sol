// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SplitterBase} from "./SplitterBase.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {MintBnbullSplitter} from "../contracts/MintBnbullSplitter.sol";
import {MintDrop} from "../contracts/MintDrop.sol";

/**
 * @title MintBnbullSplitterTest
 * @notice `DECISIONS.md §13` (20/10/70) and `§14` (never sell BNBULL) as they
 *         apply to the house money sink — plus the LP-slot trick that is the
 *         reason this contract exists at all (`BNBULLS-BOOTSTRAP.md §6`).
 *
 * @dev ⚠ MOCKS ONLY, NO MAINNET FORK. See `SplitterBase.t.sol`.
 *
 *      The headline test in this file is `test_theLpSlotTrickEndToEnd`. It
 *      wires `MintDrop.lpTreasury` at this splitter and mints for real, because
 *      that is the exact configuration `DECISIONS.md §19` records as having
 *      BRICKED EVERY BNB MINT on the first attempt:
 *
 *        > The obvious LP splitter bricked every BNB mint. The obvious splitter
 *        > body forwards to `MintDrop.donatePotNative()`, which re-enters
 *        > MintDrop while `mintWithBNB` still holds `nonReentrant`.
 *
 *      This splitter does its own swaps instead of forwarding, and only ever
 *      STATIC-calls MintDrop (for the live policy), which `nonReentrant` does
 *      not block. The test proves both halves: the mint completes, and the
 *      slice is really routed rather than silently landing in `lpUndelivered`.
 */
contract MintBnbullSplitterTest is SplitterBase {
    // ══════════════════════════════════════════════════════════════════════
    //  DECISIONS §13 — 20% BNBULL / 10% BNB / 70% dev, on everything
    // ══════════════════════════════════════════════════════════════════════

    function test_aNativePaymentIs20_10_70() public {
        _send(10 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "20% market-bought BNBULL");
        assertEq(potBnb.pool(), 1 ether, "10% wrapped into the WBNB pot, no DEX at all");
        assertEq(address(mintSplit).balance, 7 ether, "70% retained");
    }

    /**
     * @notice `DECISIONS.md §14`. Read literally, "20/10/70 on everything"
     *         would have a BNBULL payment sell 10% of itself to fund the BNB
     *         pot — the game dumping the one token whose chart its holders
     *         watch. **It does not.** 30% BNBULL pot / 0% BNB / 70% dev, and no
     *         DEX is touched.
     */
    function test_aBnbullPaymentIs30_0_70AndSellsNothing() public {
        _giveSplitterBnbull(alice, address(mintSplit), 1_000e18);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);

        assertEq(potBnbull.pool(), 30e18, "the BNB slice joined the BNBULL pot");
        assertEq(potBnb.pool(), 0, "nothing was sold for the BNB pot");
        assertEq(bnbull.balanceOf(address(mintSplit)), 70e18);
        assertEq(dex.swapCalls(), 0, "NOT ONE SWAP. That is the whole rule.");
    }

    /// @dev And it is a DEFAULT, not a post-deploy toggle: if the configuration
    ///      tx is forgotten, the safe behaviour is the one that happens anyway.
    function test_neverSellingIsTheDefaultOnBothPolicySources() public {
        assertFalse(drop.bnbullPaymentSellsForBnbLeg(), "MintDrop's live default");
        MintBnbullSplitter fresh = _bareMintSplitter();
        assertFalse(fresh.fallbackSellsForBnbLeg(), "and the local fallback matches it");
    }

    /// @dev Flipping the owner switch restores the literal §13 read, through the
    ///      LIVE MintDrop policy, with no transaction on the splitter at all.
    function test_theOwnerCanTurnSellingBackOnThroughMintDrop() public {
        drop.setBnbullPaymentSellPolicy(true);

        _giveSplitterBnbull(alice, address(mintSplit), 1_000e18);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);

        assertEq(potBnbull.pool(), 20e18);
        assertEq(potBnb.pool(), uint256(10e18) / 60_000, "10% sold for WBNB at the harness rate");
        assertEq(dex.swapCalls(), 1);
    }

    /**
     * @notice The 70% is LEFT AS BALANCE, not pushed to a treasury inside
     *         `receive()`. A push to a blacklisted USDT recipient, a multisig
     *         mid-upgrade or an expensive fallback would revert the mint. The
     *         one thing that can never fail is not doing anything at all.
     */
    function test_theDevShareIsRetainedNotForwarded() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.Retained(PotSplitter.PotSource.Native, 7 ether);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");
        assertTrue(ok);

        assertEq(mintSplit.freeOf(PotSplitter.PotSource.Native), 7 ether);
        uint256 before = treasury.balance;
        mintSplit.withdrawUnreserved(PotSplitter.PotSource.Native, treasury, 0);
        assertEq(treasury.balance - before, 7 ether);
    }

    function test_receiveAndRouteNativeDoTheSameThing() public {
        vm.deal(alice, 20 ether);
        vm.prank(alice);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");
        assertTrue(ok);
        uint256 potAfterBare = potBnb.pool();

        vm.prank(alice);
        mintSplit.routeNative{value: 10 ether}();
        assertEq(potBnb.pool(), potAfterBare * 2);
        assertEq(address(mintSplit).balance, 14 ether);
    }

    /// @dev Integer division truncates toward the retained share, never away
    ///      from it, so the three legs always re-add to the payment exactly.
    function testFuzz_theThreeLegsAlwaysReAddToThePayment(uint96 amount) public {
        vm.assume(amount > 0);
        dex.setRevertOnSwap(true); // everything defers, so every leg is countable
        potBnb.setFunder(address(mintSplit), false);

        vm.deal(alice, uint256(amount));
        vm.prank(alice);
        (bool ok,) = address(mintSplit).call{value: uint256(amount)}("");
        assertTrue(ok);

        uint256 potted = mintSplit.pendingBnbullBuyNative() + mintSplit.pendingBnbPotNative();
        uint256 retained = mintSplit.freeOf(PotSplitter.PotSource.Native);
        assertEq(potted + retained, uint256(amount), "a wei went missing between the legs");
        assertLe(potted * 10_000, uint256(amount) * 3_000 + 9_999, "the pots never over-take");
    }

    function test_dustPaymentsRoundToTheRetainedShareAndNeverRevert() public {
        _send(3 wei);
        assertEq(mintSplit.freeOf(PotSplitter.PotSource.Native), 3 wei, "all three wei retained");
        assertEq(potBnbull.pool(), 0);
        assertEq(potBnb.pool(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The LP-slot trick (BNBULLS-BOOTSTRAP §6) — and the §19 regression
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Point `MintDrop.lpTreasury` here, set `lpShareBps`, and a whole
     *         extra buyback leg joins the mint money path with NO redeploy of
     *         MintDrop. `DECISIONS.md §19` records the first attempt at this
     *         bricking every BNB mint.
     */
    function test_theLpSlotTrickEndToEnd() public {
        drop.setLpTreasury(address(mintSplit));
        drop.setLpShare(10_000); // the whole post-pot remainder

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 rest = bnbDue - (bnbDue * 2_000) / 10_000 - (bnbDue * 1_000) / 10_000;

        uint256 spent = _mintBnb(alice, 1);

        assertEq(spent, bnbDue, "the buyer paid exactly the quote");
        assertEq(bulls.balanceOf(alice), 1, "THE MINT MUST NOT BRICK ON THE LP SLOT");
        assertEq(drop.lpUndelivered(), 0, "the slice really was delivered, not accrued upstream");

        // MintDrop's own 10% wrap, plus the splitter's 10% of what it received.
        assertEq(potBnb.pool(), (bnbDue * 1_000) / 10_000 + (rest * 1_000) / 10_000);
        assertEq(
            address(mintSplit).balance,
            rest - (rest * 2_000) / 10_000 - (rest * 1_000) / 10_000,
            "70% of 70%, with each leg truncated on its own the way the contract does it"
        );
        assertEq(treasury.balance, 0, "the dev leg went through the splitter, not direct");
    }

    /// @dev ...and it still does not brick when the splitter's own route is
    ///      dead, which on launch day it will be.
    function test_theLpSlotTrickSurvivesADeadRouteWithoutBrickingTheMint() public {
        drop.setLpTreasury(address(mintSplit));
        drop.setLpShare(10_000);
        dex.setQuoteZero(true); // no PancakeSwap pair for BNBULL yet
        router.setRevertOnSwap(true); // MintDrop's own v2 leg is down too

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 rest = bnbDue - (bnbDue * 2_000) / 10_000 - (bnbDue * 1_000) / 10_000;

        _mintBnb(alice, 1);

        assertEq(bulls.balanceOf(alice), 1);
        assertEq(drop.lpUndelivered(), 0, "receive() returned normally, so nothing accrued here");
        assertEq(
            mintSplit.pendingBnbullBuyNative(),
            (rest * 2_000) / 10_000,
            "it accrued INSIDE the splitter instead, where a keeper can sweep it"
        );
    }

    /// @dev The ERC-20 LP slice arrives by a plain `safeTransfer` — no callback,
    ///      so nothing notices it. It piles up and the keeper routes it.
    function test_theErc20LpSliceArrivesSilentlyAndIsPickedUpByRouteHeld() public {
        drop.setLpTreasury(address(mintSplit));
        drop.setLpShare(10_000);

        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        // The $10 rung pegs at 1,000 BNBULL undiscounted; the BNBULL leg takes
        // 10% off (`DECISIONS.md §2`), so 900 arrives and 70% of it parks here.
        uint256 paid = 900e18;
        uint256 parked = bnbull.balanceOf(address(mintSplit));
        assertEq(parked, (paid * 7_000) / 10_000, "70% landed here with no callback");
        assertEq(
            mintSplit.reservedOf(PotSplitter.PotSource.Bnbull), 0, "and nothing routed itself"
        );

        uint256 potBefore = potBnbull.pool();
        vm.prank(keeper);
        mintSplit.routeHeld(PotSplitter.PotSource.Bnbull, 0);
        // `§14`: a BNBULL payment is never sold, so the whole 30% joins the
        // BNBULL pot as tokens and no DEX is touched.
        assertEq(potBnbull.pool() - potBefore, (parked * 3_000) / 10_000);
        assertEq(bnbull.balanceOf(address(mintSplit)), parked - (parked * 3_000) / 10_000);
        assertEq(dex.swapCalls(), 0, "BNBULL WAS SOLD");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  routePayment
    // ══════════════════════════════════════════════════════════════════════

    function test_routePaymentSplitsWhatActuallyArrived() public {
        _giveSplitterBnbull(alice, address(mintSplit), 500e18);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 500e18);

        // `§14`: 30% BNBULL pot / 70% retained, and nothing is sold.
        assertEq(potBnbull.pool(), 150e18);
        assertEq(bnbull.balanceOf(alice), 0, "the whole approved amount was pulled");
        assertEq(bnbull.balanceOf(address(mintSplit)), 350e18);
        assertEq(dex.swapCalls(), 0, "BNBULL WAS SOLD");
    }

    function test_routePaymentOnAnUnwiredAssetIsIgnoredNotRejected() public {
        MintBnbullSplitter s = _bareMintSplitter();
        bnbull.mint(alice, 100e18);
        vm.startPrank(alice);
        bnbull.approve(address(s), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(s));
        emit MintBnbullSplitter.UnsupportedAssetIgnored(address(bnbull), 100e18);
        s.routePayment(address(bnbull), 100e18);
        vm.stopPrank();

        assertEq(bnbull.balanceOf(alice), 100e18, "an unwired asset is never taken");
    }

    /// @dev And a WIRED splitter still refuses an asset that is not BNBULL —
    ///      there is no second ERC-20 to fall through to since
    ///      `DECISIONS.md §26`, so anything else is ignored, never taken.
    function test_routePaymentOnANonBnbullAssetIsIgnored() public {
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit MintBnbullSplitter.UnsupportedAssetIgnored(address(wbnb), 100e18);
        mintSplit.routePayment(address(wbnb), 100e18);
        vm.stopPrank();
    }

    /// @dev A caller that forgot the approval keeps its money and gets an event.
    ///      That matters because a future caller may be a frozen contract with
    ///      no try/catch of its own.
    function test_routePaymentWithNoAllowanceEmitsAndReturns() public {
        bnbull.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(mintSplit));
        emit MintBnbullSplitter.PullFailed(address(bnbull), alice, 100e18);
        mintSplit.routePayment(address(bnbull), 100e18);
        assertEq(bnbull.balanceOf(alice), 100e18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _send(uint256 amount) internal {
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        (bool ok,) = address(mintSplit).call{value: amount}("");
        assertTrue(ok, "receive() reverted: every native mint would brick");
    }
}
