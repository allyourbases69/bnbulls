// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {PayableSink} from "./mocks/Hostile.sol";

/**
 * @title MintDropRoutingTest
 * @notice PRIORITY 6. Pot routing, and the never-sell rule.
 *
 * @dev `DECISIONS.md §13` — **20% BNBULL / 10% BNB / 70% dev, on everything.**
 *      Changed from fefers' 15/15/70: the same 30% to the pots in total, but
 *      weighted 2:1 toward BNBULL, "because BNBULL is the token whose chart the
 *      holders actually watch, and BNB needs no help".
 *
 *      `DECISIONS.md §14` — **never sell BNBULL.** Read literally, §13 would
 *      have a BNBULL payment sell 10% of itself to fund the BNB pot: "the game
 *      dumping the one token whose chart its holders watch, partly cancelling
 *      the buy pressure the pot exists to create."
 *
 *        > It does not. A BNBULL payment routes **30% BNBULL pot / 70% dev**
 *        > and touches no DEX at all.
 *        >
 *        > `MintDrop.bnbullPaymentSellsForBnbLeg` **defaults to `false`** —
 *        > this is a default, not a post-deploy toggle, deliberately: if the
 *        > configuration tx is ever forgotten, the safe behaviour is the one
 *        > that happens anyway.
 *
 *      So the default is asserted FIRST, on its own, before any routing test —
 *      because a suite that configures the flag in `setUp` would pass whether
 *      the default was right or wrong, and the default is the decision.
 *
 *      Which legs are swaps (§13):
 *        - the 20% BNBULL leg is ALWAYS a swap, except from a BNBULL payment
 *        - the 10% BNB leg is a swap ONLY from a BNBULL payment; a BNB
 *          payment is a 1:1 WBNB wrap, no router, no liquidity dependency
 */
contract MintDropRoutingTest is BnbullsBase {
    // ══════════════════════════════════════════════════════════════════════
    //  The defaults, asserted before anything is configured
    // ══════════════════════════════════════════════════════════════════════

    function test_theNeverSellFlagDefaultsToFalse() public view {
        assertFalse(
            drop.bnbullPaymentSellsForBnbLeg(),
            "DECISIONS 14: this is a DEFAULT, not a post-deploy toggle"
        );
    }

    function test_potSharesDefaultToTwentyTenSeventy() public view {
        assertEq(drop.bnbullShareBps(), 2_000);
        assertEq(drop.bnbShareBps(), 1_000);
        assertEq(drop.lpShareBps(), 0, "the LP slot is unused at launch, on purpose");
        assertEq(drop.bnbullShareBps() + drop.bnbShareBps(), 3_000, "30% to the pots");
        assertEq(drop.MAX_TOTAL_POT_BPS(), 5_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A BNB payment: swap for the BNBULL leg, WRAP for the BNB leg
    // ══════════════════════════════════════════════════════════════════════

    function test_bnbPaymentRoutesTwentyTenSeventy() public {
        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 slice20 = (bnbDue * 2_000) / 10_000;
        uint256 slice10 = (bnbDue * 1_000) / 10_000;
        uint256 rest = bnbDue - slice20 - slice10;

        uint256 treasuryBefore = treasury.balance;
        _mintBnb(alice, 1);

        // 20%: swapped BNB -> BNBULL and locked in the BNBULL pot.
        assertEq(potBnbull.pool(), slice20 * BNBULL_PER_BNB, "BNBULL pot leg");
        // 10%: WRAPPED 1:1 into the WBNB pot. No router involved.
        assertEq(potBnb.pool(), slice10, "WBNB pot leg is a 1:1 wrap");
        // 70%: dev.
        assertEq(treasury.balance - treasuryBefore, rest, "dev leg");

        // Nothing left behind and nothing deferred.
        assertEq(drop.pendingBnbullBuyNative(), 0);
        assertEq(drop.pendingBnbPotNative(), 0);
        assertEq(address(drop).balance, 0, "MintDrop should hold no BNB in steady state");
        assertEq(drop.freeNative(), 0);
    }

    /// @dev Exactly ONE swap for a BNB payment — the BNBULL leg. The BNB leg
    ///      must not touch the router at all.
    function test_aBnbPaymentSwapsOnlyOnce() public {
        _mintBnb(alice, 1);
        assertEq(router.swapCalls(), 1, "the BNB pot leg must be a wrap, not a swap");
    }

    /// @dev The strongest form of "no DEX interaction": break the router
    ///      completely, and the WBNB pot leg still funds inline.
    function test_theBnbPotLegSurvivesADeadRouter() public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 slice10 = (bnbDue * 1_000) / 10_000;
        _mintBnb(alice, 1);

        assertEq(potBnb.pool(), slice10, "the wrap must not depend on a router");
        assertGt(drop.pendingBnbullBuyNative(), 0, "the swap leg should have deferred");
    }

    function test_bnbSlicesSumToThePaymentWithNoDust() public {
        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 treasuryBefore = treasury.balance;
        _mintBnb(alice, 1);

        uint256 intoBnbullLeg = potBnbull.pool() / BNBULL_PER_BNB;
        uint256 intoBnbLeg = potBnb.pool();
        uint256 intoDev = treasury.balance - treasuryBefore;
        assertEq(intoBnbullLeg + intoBnbLeg + intoDev, bnbDue, "wei went missing");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A BNBULL payment: 30 / 0 / 70 and NOT ONE SWAP
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `DECISIONS.md §14`, asserted three ways: the shares, the swap
     *         counter, and a router that would revert if it were touched.
     */
    function test_bnbullPaymentRoutesThirtyZeroSeventyAndNeverSells() public {
        // If ANY DEX interaction is attempted, these make it fail loudly and
        // the leg would defer instead of funding.
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);

        _giveBnbull(alice, 10_000e18);
        uint256 due = 900e18; // $10 sticker, -10%, pegged at $0.01

        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        assertEq(potBnbull.pool(), (due * 3_000) / 10_000, "30% to the BNBULL pot");
        assertEq(potBnbull.pool(), 270e18);
        assertEq(potBnb.pool(), 0, "the WBNB pot must get NOTHING from a BNBULL payment");
        assertEq(bnbull.balanceOf(treasury), (due * 7_000) / 10_000, "70% dev");
        assertEq(bnbull.balanceOf(treasury), 630e18);

        assertEq(router.swapCalls(), 0, "THE GAME SOLD BNBULL");
        assertEq(drop.pendingBnbPotBnbull(), 0, "nothing was queued for a sale either");
        assertEq(drop.pendingBnbullDirect(), 0, "the direct leg must fund inline");
    }

    /// @dev And with the flag flipped, the literal §13 reading returns — proving
    ///      the default is what is doing the work, not a missing code path.
    function test_flippingTheFlagRestoresTheLiteralTwentyTenSeventy() public {
        drop.setBnbullPaymentSellPolicy(true);
        assertTrue(drop.bnbullPaymentSellsForBnbLeg());

        _giveBnbull(alice, 10_000e18);
        uint256 due = 900e18;

        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        assertEq(potBnbull.pool(), (due * 2_000) / 10_000, "back to 20%");
        assertEq(potBnb.pool(), ((due * 1_000) / 10_000) / BNBULL_PER_BNB, "10% SOLD for WBNB");
        assertGt(potBnb.pool(), 0);
        assertEq(router.swapCalls(), 1, "the sale the default exists to prevent");
    }

    function test_onlyOwnerFlipsTheSellPolicy() public {
        vm.prank(alice);
        vm.expectRevert();
        drop.setBnbullPaymentSellPolicy(true);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Donations take the same route
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The Graveyard's revive slice lands here. 100% of what arrives goes
    ///      to the pots, split in the `bnbullShareBps : bnbShareBps` ratio.
    function test_donatePotNativeSplitsTwoToOneWithNoDevCut() public {
        uint256 amount = 3 ether;
        vm.deal(alice, amount);
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        drop.donatePotNative{value: amount}();

        assertEq(potBnbull.pool(), (amount * 2 / 3) * BNBULL_PER_BNB, "2/3 of the donation");
        assertEq(potBnb.pool(), amount - (amount * 2 / 3), "1/3 of the donation");
        assertEq(treasury.balance, treasuryBefore, "a donation takes no dev cut");
    }

    function test_donatePotTokenInBnbullAlsoRefusesToSell() public {
        router.setRevertOnSwap(true);
        bnbull.mint(alice, 1_000e18);
        vm.startPrank(alice);
        bnbull.approve(address(drop), type(uint256).max);
        drop.donatePotToken(address(bnbull), 900e18);
        vm.stopPrank();

        assertEq(potBnbull.pool(), 900e18, "the whole donation, unsold");
        assertEq(potBnb.pool(), 0);
        assertEq(router.swapCalls(), 0);
    }

    function test_donatePotTokenRefusesAnUnknownAsset() public {
        vm.expectRevert(abi.encodeWithSelector(MintDrop.UnsupportedAsset.selector, address(wbnb)));
        drop.donatePotToken(address(wbnb), 1);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.UnsupportedAsset.selector, address(0)));
        drop.donatePotToken(address(0), 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Shares are bounded, and the LP slot is a live hook
    // ══════════════════════════════════════════════════════════════════════

    function test_potSharesAreBounded() public {
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, uint256(5_001)));
        drop.setPotShares(4_000, 1_001);

        drop.setPotShares(3_000, 2_000); // the ceiling exactly
        assertEq(drop.bnbullShareBps(), 3_000);
        assertEq(drop.bnbShareBps(), 2_000);

        vm.prank(alice);
        vm.expectRevert();
        drop.setPotShares(0, 0);
    }

    /// @dev Pots fully disabled: everything routes to dev and nothing breaks.
    function test_potsCanBeTurnedOffEntirely() public {
        drop.setPotShares(0, 0);
        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 treasuryBefore = treasury.balance;
        _mintBnb(alice, 1);
        assertEq(treasury.balance - treasuryBefore, bnbDue);
        assertEq(potBnbull.pool(), 0);
        assertEq(potBnb.pool(), 0);
    }

    /**
     * @notice ⚠ KEEP THE LP SLOT. On fefers this exact unused slot was the hook
     *         that let a whole extra buyback leg be added to a FROZEN MintDrop
     *         with zero redeploy — point `lpTreasury` at a splitter and its
     *         `receive()` gets the slice.
     */
    function test_theLpSlotIsALiveSplitterHook() public {
        PayableSink splitter = new PayableSink();
        drop.setLpTreasury(address(splitter));
        drop.setLpShare(5_000); // half the post-pot remainder

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 rest = bnbDue - (bnbDue * 2_000) / 10_000 - (bnbDue * 1_000) / 10_000;
        uint256 treasuryBefore = treasury.balance;

        _mintBnb(alice, 1);

        assertEq(splitter.received(), rest / 2, "the LP slot took its slice");
        assertEq(treasury.balance - treasuryBefore, rest - rest / 2);
    }

    /**
     * @notice ⚠ FINDING FOR WHOEVER WRITES THE SPLITTERS — the most natural
     *         splitter implementation BRICKS EVERY BNB MINT.
     *
     * @dev The LP slot's own docs invite it: "point `lpTreasury` at a splitter
     *      and its `receive()` gets the slice". The obvious body for that
     *      `receive()` is "forward my slice to the pots", i.e. call
     *      `MintDrop.donatePotNative{value: msg.value}()`.
     *
     *      That reverts. `mintWithBNB` and `donatePotNative` are BOTH
     *      `nonReentrant` on the SAME contract, so the re-entry trips the
     *      guard; `_routeNative`'s LP transfer is a bare `.call` that reverts
     *      the mint on failure (`LpTransferFailed`), and unlike the pot legs it
     *      has no try/catch-or-accrue behind it. Every BNB mint fails for as
     *      long as `lpShareBps > 0` with such a splitter wired.
     *
     *      This is not a defect in MintDrop in isolation — the bare `.call` is
     *      deliberate and documented ("that is exactly what makes the LP slot a
     *      splitter hook ... which MUST therefore never revert"). It is a
     *      CROSS-CONTRACT CONSTRAINT that the splitter author has to be told,
     *      because the failure only appears when both halves are wired
     *      together, and `lpShareBps` is 0 at launch so it would not appear
     *      until the day someone turns the slot on.
     *
     *      SAFE SPLITTER SHAPES: hold the slice and let a keeper push it, or
     *      forward to a DIFFERENT sink than the MintDrop that paid it. Do NOT
     *      re-enter MintDrop from a `receive()` that MintDrop itself funds.
     */
    function test_anLpSplitterThatReEntersDonatePotNativeNoLongerBricksTheMint() public {
        ReentrantSplitter splitter = new ReentrantSplitter(address(drop));
        drop.setLpTreasury(address(splitter));
        drop.setLpShare(10_000);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        // FIXED 2026-08-06: the LP leg accrues instead of reverting, so the
        // re-entrant splitter can no longer brick every BNB mint.
        drop.mintWithBNB{value: 5 ether}(alice, 1);

        assertEq(bulls.balanceOf(alice), 1, "the mint must survive a bad LP sink");
        assertGt(drop.lpUndelivered(), 0, "the undelivered slice is held, not lost");

        // And the owner can recover it — including a retry at the LP slot once
        // the splitter is replaced with one that works.
        uint256 held = drop.lpUndelivered();
        PayableSink rescue = new PayableSink();
        drop.withdrawLpUndelivered(address(rescue));
        assertEq(drop.lpUndelivered(), 0, "bucket cleared");
        assertEq(address(rescue).balance, held, "recovered in full");

        // A splitter that merely HOLDS the slice is fine, which is the shape to
        // build.
        PayableSink safe = new PayableSink();
        drop.setLpTreasury(address(safe));
        vm.prank(alice);
        drop.mintWithBNB{value: 5 ether}(alice, 1);
        assertEq(bulls.balanceOf(alice), 2, "second mint, so two bulls now");
        assertGt(safe.received(), 0, "a well-behaved sink is still paid directly");
        assertEq(drop.lpUndelivered(), 0, "and nothing new was deferred");
    }

    function test_lpShareIsBoundedAndSlotsRejectZero() public {
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, uint256(10_001)));
        drop.setLpShare(10_001);
        vm.expectRevert(MintDrop.ZeroAddress.selector);
        drop.setLpTreasury(address(0));
        vm.expectRevert(MintDrop.ZeroAddress.selector);
        drop.setTreasury(address(0));
    }

    /// @dev The token-payment mirror of the LP hook.
    function test_theLpSlotAlsoTakesTokenPayments() public {
        drop.setLpShare(2_000);
        _giveBnbull(alice, 100_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        // 900 BNBULL paid; `§14` sends the whole 30% to the BNBULL pot, so the
        // remainder is 630 and the LP slot takes 20% of that.
        uint256 rest = 630e18;
        assertEq(bnbull.balanceOf(lpTreasury), (rest * 2_000) / 10_000);
        assertEq(bnbull.balanceOf(treasury), (rest * 8_000) / 10_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The refund path
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `msg.value >= due`, not `== due` — because the dollar-to-BNB
    ///      conversion happens at PAY time and the oracle moves between the
    ///      wallet quoting and the tx landing. Fefers could demand equality;
    ///      here that would revert honest mints on ordinary volatility.
    function test_theSurplusIsRefundedAndAShortfallReverts() public {
        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.InsufficientBNB.selector, bnbDue, bnbDue - 1)
        );
        drop.mintWithBNB{value: bnbDue - 1}(alice, 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        drop.mintWithBNB{value: 5 ether}(alice, 1);
        assertEq(before - alice.balance, bnbDue, "the surplus was not refunded");
    }

    function test_aTreasuryThatCannotReceiveBnbFailsLoudly() public {
        // Not a never-fail path: this is the OWNER's own revenue slot, and a
        // silent accrual there would hide a misconfigured treasury.
        drop.setTreasury(address(new NonPayable()));
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(MintDrop.TreasuryTransferFailed.selector);
        drop.mintWithBNB{value: 5 ether}(alice, 1);
    }
}

contract NonPayable {
    // no receive, no fallback
}

/// @dev The splitter shape the LP slot invites and the reentrancy guard
///      refuses. See `test_FINDING_anLpSplitterThatReEntersDonatePotNative...`.
contract ReentrantSplitter {
    MintDrop public immutable drop;

    constructor(address _drop) {
        drop = MintDrop(payable(_drop));
    }

    receive() external payable {
        drop.donatePotNative{value: msg.value}();
    }
}
