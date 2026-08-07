// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MockERC20, RevertingERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {RevertingReceiver} from "./mocks/Hostile.sol";
import {
    GraveyardLpSink,
    GraveyardReentrantMintDrop,
    GraveyardReentrantReviver,
    GraveyardRevertingMintDrop
} from "./mocks/GraveyardMocks.sol";

/**
 * @title GraveyardNeverFailTest
 * @notice PRIORITY 8. A revive can never fail because of a buyback.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      THE EXACT BUG THIS EXISTS FOR, from `Graveyard.sol`'s own header. On
 *      fefers `MintDrop.donateJackpotBuy` was called from
 *      `Graveyard._routeNative` with NO try/catch:
 *
 *          IJackpotBuyDonate(mintDrop).donateJackpotBuy{value: jackpotShare}();
 *
 *      "If that entrypoint ever reverted — paused, unwired, mid-upgrade, a
 *      buyback pool that did not exist yet — **every revive in the game
 *      bricked**, and the Graveyard was frozen so there was no fixing it from
 *      this side."
 *
 *      Every test below drives that leg into a failure mode and asserts three
 *      things: the revive SUCCEEDS, every wei is ACCRUED (nothing is lost),
 *      and a DEFERRED EVENT is emitted so which branch ran is on chain.
 *
 *      `DECISIONS.md §19` extends the same rule to the LP leg, which now
 *      accrues to `lpUndelivered` instead of reverting. Reverting a revive to
 *      protect a discretionary buyback leg is the wrong trade: it is the
 *      owner's own money on the way to the owner's own splitter.
 */
contract GraveyardNeverFailTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    uint256 internal constant USD_RUNG_1 = 50e18;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
        _fundForRevive(alice);
        _fundForRevive(bob);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A dead donation entrypoint defers; the revive completes
    // ══════════════════════════════════════════════════════════════════════

    function test_aRevertingMintDropDefersTheNativeLegAndTheReviveCompletes() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;
        uint256 treasuryBefore = treasury.balance;

        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.PotDeferred(Graveyard.PotSource.Native, potShare, potShare);
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull), "the revive bricked on a buyback");
        assertEq(grave.pendingPotNative(), potShare, "the slice was lost");
        assertEq(address(grave).balance, potShare, "the accrued BNB is not actually held");
        assertEq(treasury.balance - treasuryBefore, due - potShare, "dev's leg still settled");
    }

    function test_aRevertingMintDropDefersTheBnbullLeg() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        uint256 paid = _bnbullDue(USD_RUNG_1);
        uint256 potShare = (paid * 3_000) / 10_000;

        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.PotDeferred(Graveyard.PotSource.Bnbull, potShare, potShare);
        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertEq(grave.pendingPotBnbull(), potShare);
    }

    /**
     * @notice `code.length` is load-bearing. A payable call to an EOA
     *         SUCCEEDS, so without the check a mis-wired slot would silently
     *         send the pot slice to a wallet instead of failing loudly into
     *         the bucket.
     */
    function test_anEoaInTheMintDropSlotDefersRatherThanPayingAWallet() public {
        address wallet = address(0xEEEE);
        _repointGraveyardWire(Graveyard.Wire.MintDrop, wallet);
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;

        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertEq(wallet.balance, 0, "the pot slice was sent to a wallet");
        assertEq(grave.pendingPotNative(), potShare);
    }

    /// @dev And the pre-launch case: the slot was never wired at all.
    function test_anUnwiredMintDropDefers() public {
        Graveyard fresh = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        fresh.bootstrapWire(Graveyard.Wire.Duel, address(duelC));
        fresh.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));
        _installGraveyard(fresh);

        _killBull(aliceBull, bobBull);
        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;

        vm.prank(alice);
        fresh.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull), "a pre-launch revive bricked");
        assertEq(fresh.pendingPotNative(), potShare);
    }

    /**
     * @notice A re-entrant donation target. `_revive` holds `nonReentrant`, so
     *         a MintDrop that calls back into the Graveyard trips the guard —
     *         and that revert must be swallowed into an accrual, never
     *         surface as a failed revive.
     *
     * @dev This is `DECISIONS.md §19`'s LP-splitter bug seen from the other
     *      side: "the OBVIOUS splitter body forwards to
     *      `MintDrop.donatePotNative()`, which re-enters MintDrop while
     *      `mintWithBNB` still holds `nonReentrant`."
     */
    function test_aReentrantMintDropDefersAndTheReviveStillCompletes() public {
        GraveyardReentrantMintDrop hostile = new GraveyardReentrantMintDrop();
        hostile.configure(address(grave), aliceBull);
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(hostile));
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;

        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertEq(grave.resurrectsUsed(aliceBull), 1, "the re-entrant frame spent a second life");
        assertEq(grave.pendingPotNative(), potShare);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ...and with the REAL MintDrop, the failure absorbs one level down
    // ══════════════════════════════════════════════════════════════════════

    /// @dev With the real MintDrop the donate entrypoint cannot revert at all
    ///      — it defers internally — so the Graveyard's own bucket stays empty
    ///      and the money sits in MintDrop's. Nothing is lost either way,
    ///      which is the point of having the rule at BOTH levels.
    function test_aBrokenRouterIsAbsorbedByMintDropAndTheReviveCompletes() public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;

        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.PotFundedInline(Graveyard.PotSource.Native, potShare);
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertEq(grave.pendingPotNative(), 0, "the Graveyard should not have had to defer");
        assertGt(drop.pendingBnbullBuyNative(), 0, "MintDrop deferred the swap leg");
        assertEq(potBnb.pool(), potShare - drop.pendingBnbullBuyNative(), "the wrap leg landed");
    }

    function test_zeroLiquidityIsAbsorbedAndTheReviveCompletes() public {
        router.setQuoteZero(true);
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertGt(drop.pendingBnbullBuyNative(), 0);
    }

    /**
     * @notice A prize token whose `transfer` reverts — paused, blacklisting,
     *         or simply broken.
     *
     * @dev `BNB-CHAIN-FACTS §5` warns that a launchpad token with a transfer
     *      gate bricks every `transferFrom` flow in the game. BNBULL is
     *      launchpad-issued (`DECISIONS.md §4`), so this is not exotic. It
     *      must cost the buyback leg and nothing else: the bull still gets up.
     */
    function test_aRevertingPrizeTokenDoesNotBlockARevive() public {
        RevertingERC20 broken = new RevertingERC20();
        MockRouter r = new MockRouter(address(wbnb));
        r.setRate(address(wbnb), address(broken), 1_000, 1);
        broken.setBroken(false);
        broken.mint(address(r), 1e30);
        broken.setBroken(true);

        MintDrop d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(broken),
                wbnb: address(wbnb),
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        d.unpause();
        Jackpot brokenPot = new Jackpot(address(broken), address(0), address(coord), 50);
        brokenPot.setFunder(address(d), true);
        potBnb.setFunder(address(d), true);
        d.bootstrapWire(MintDrop.Wire.Router, address(r));
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(brokenPot));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));

        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(d));
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;
        uint256 toBnbull = (potShare * 2_000) / 3_000;

        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull), "a reverting prize token bricked the revive");
        assertEq(brokenPot.pool(), 0);
        assertEq(d.pendingBnbullBuyNative(), toBnbull, "the broken leg deferred");
        assertEq(potBnb.pool(), potShare - toBnbull, "the healthy leg still landed");
        assertEq(grave.pendingPotNative(), 0, "the Graveyard should not have had to defer");
    }

    /// @dev The realistic deploy-ordering bug: the pots exist but have not
    ///      whitelisted MintDrop as a funder yet.
    function test_potsThatRefuseFundingDoNotBlockARevive() public {
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;

        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertEq(
            drop.pendingBnbullBuyNative() + drop.pendingBnbPotNative(),
            potShare,
            "wei went missing between the two contracts"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The backlog is recoverable
    // ══════════════════════════════════════════════════════════════════════

    function test_theKeeperSweepsTheBacklogOnceTheRouteIsHealthy() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);
        assertEq(grave.pendingPotNative(), potShare);

        // The route comes back: repoint at the real MintDrop and sweep.
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(drop));

        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.PotSwept(Graveyard.PotSource.Native, potShare);
        vm.prank(keeper);
        grave.sweepPending(Graveyard.PotSource.Native, 0);

        assertEq(grave.pendingPotNative(), 0);
        assertEq(address(grave).balance, 0, "the swept BNB is still sitting here");
        assertGt(potBnbull.pool(), 0);
        assertGt(potBnb.pool(), 0);
    }

    function test_sweepsArePartialBoundedAndPermissioned() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        uint256 bucket = grave.pendingPotNative();
        assertGt(bucket, 0);

        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(drop));

        vm.prank(alice);
        vm.expectRevert(Graveyard.NotKeeperOrOwner.selector);
        grave.sweepPending(Graveyard.PotSource.Native, 0);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.InsufficientPending.selector, bucket + 1, bucket)
        );
        grave.sweepPending(Graveyard.PotSource.Native, bucket + 1);

        vm.prank(keeper);
        grave.sweepPending(Graveyard.PotSource.Native, bucket / 2);
        assertEq(grave.pendingPotNative(), bucket - bucket / 2);

        vm.prank(keeper);
        vm.expectRevert(Graveyard.NothingToSweep.selector);
        grave.sweepPending(Graveyard.PotSource.Bnbull, 0);
    }

    /**
     * @notice THE TRUST BOUNDARY, tested both ways.
     *
     * @dev Money in a `pending*` bucket has NOT entered a pot yet, so this
     *      hatch can move it. Money that has REACHED a `Jackpot` can never
     *      come out except through a won ticket — no owner path, no
     *      "temporary" hatch, no pause-and-withdraw. Two different guarantees,
     *      and the events say which is which.
     */
    function test_pendingIsWithdrawableButPottedMoneyIsNot() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);
        uint256 bucket = grave.pendingPotBnbull();
        assertGt(bucket, 0);

        vm.expectEmit(true, true, false, true, address(grave));
        emit Graveyard.PendingWithdrawn(Graveyard.PotSource.Bnbull, address(0xBEEF), bucket);
        grave.withdrawPending(Graveyard.PotSource.Bnbull, address(0xBEEF), 0);
        assertEq(bnbull.balanceOf(address(0xBEEF)), bucket);
        assertEq(grave.pendingPotBnbull(), 0);

        vm.prank(alice);
        vm.expectRevert();
        grave.withdrawPending(Graveyard.PotSource.Bnbull, alice, 0);

        vm.expectRevert(Graveyard.NothingToSweep.selector);
        grave.withdrawPending(Graveyard.PotSource.Bnbull, owner, 0);
    }

    /// @dev `rescueToken` refuses anything a deferred pot leg is credited
    ///      with — that money is spoken for and `withdrawPending` is the only
    ///      door it may leave by.
    function test_rescueCannotTouchMoneyEarmarkedForAPot() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);
        uint256 reserved = grave.pendingPotBnbull();

        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.ReservedForPots.selector, reserved, uint256(0))
        );
        grave.rescueToken(address(bnbull), owner, reserved);

        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(grave), 5e18);
        grave.rescueToken(address(stray), owner, 5e18);
        assertEq(stray.balanceOf(owner), 5e18);
    }

    /// @dev There is deliberately no native rescue and no `receive()`: every
    ///      BNB path routes or accrues to the wei.
    function test_thereIsNoNativeRescueAndNoReceive() public {
        (bool ok,) = address(grave).call(
            abi.encodeWithSignature("rescueNative(address,uint256)", owner, 1)
        );
        assertFalse(ok, "a native rescue exists on the Graveyard");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (ok,) = address(grave).call{value: 1 ether}("");
        assertFalse(ok, "the Graveyard has a receive(); BNB can arrive unaccounted for");
    }

    /// @dev The inline workers are `external` ONLY so the contract can
    ///      try/catch its own call.
    function test_theInlineRoutersAreUnreachableFromOutside() public {
        vm.prank(alice);
        vm.expectRevert(Graveyard.NotSelf.selector);
        grave.routePotNativeInline(address(drop), 1 ether);

        vm.expectRevert(Graveyard.NotSelf.selector);
        grave.routePotTokenInline(address(drop), address(bnbull), 1e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The LP leg — `DECISIONS.md §19`
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The LP slice ACCRUES on failure. It does not revert the revive.
     *
     * @dev Fefers reverted here, and `DECISIONS.md §19` names that the wrong
     *      trade: "a discretionary buyback leg must never be able to stop a
     *      bull coming back from the dead." It would not have surfaced until
     *      the day someone set `lpShareBps > 0`, because the slot launches at
     *      zero — which is exactly why it is tested with the slot open.
     */
    function test_theLpLegAccruesInsteadOfRevertingAndIsRecoverable() public {
        RevertingReceiver brokenSplitter = new RevertingReceiver();
        grave.setLpTreasury(address(brokenSplitter));
        grave.setShares(3_000, 5_000);
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 potShare = (due * 3_000) / 10_000;
        uint256 rest = due - potShare;
        uint256 lpShare = (rest * 5_000) / 10_000;
        uint256 treasuryBefore = treasury.balance;

        vm.expectEmit(false, false, false, true, address(grave));
        emit Graveyard.LpDeferred(lpShare, lpShare);
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull), "the revive bricked on the LP leg");
        assertEq(grave.lpUndelivered(), lpShare, "the LP slice vanished");
        assertEq(treasury.balance - treasuryBefore, rest - lpShare, "dev's leg still settled");

        // ...and `withdrawLpUndelivered` recovers it.
        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.LpUndeliveredWithdrawn(address(0xBEEF), lpShare);
        grave.withdrawLpUndelivered(address(0xBEEF));
        assertEq(address(0xBEEF).balance, lpShare);
        assertEq(grave.lpUndelivered(), 0);

        vm.expectRevert(Graveyard.NothingUndelivered.selector);
        grave.withdrawLpUndelivered(address(0xBEEF));
    }

    /// @dev A zero `to` RETRIES the LP slot, so a fixed splitter can be paid
    ///      what it missed — and a still-broken one fails loudly rather than
    ///      burning the money.
    function test_withdrawLpUndeliveredRetriesTheSlotWhenToIsZero() public {
        RevertingReceiver brokenSplitter = new RevertingReceiver();
        grave.setLpTreasury(address(brokenSplitter));
        grave.setShares(3_000, 5_000);
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        uint256 held = grave.lpUndelivered();
        assertGt(held, 0);

        vm.expectRevert(Graveyard.TreasuryTransferFailed.selector);
        grave.withdrawLpUndelivered(address(0));
        assertEq(grave.lpUndelivered(), held, "the money was burned on a failed retry");

        // Point the slot at a splitter that works, then retry.
        GraveyardLpSink good = new GraveyardLpSink();
        grave.setLpTreasury(address(good));
        grave.withdrawLpUndelivered(address(0));
        assertEq(good.received(), held);
        assertEq(grave.lpUndelivered(), 0);
    }

    /// @dev A healthy LP slot just gets paid, on both the native and the token
    ///      path.
    function test_aHealthyLpSlotIsPaidInline() public {
        GraveyardLpSink sink = new GraveyardLpSink();
        grave.setLpTreasury(address(sink));
        grave.setShares(3_000, 5_000);
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 rest = due - (due * 3_000) / 10_000;
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);
        assertEq(sink.received(), (rest * 5_000) / 10_000);
        assertEq(grave.lpUndelivered(), 0);

        // ⚠ The first revive spent life one, so the second is priced at RUNG
        // TWO ($200) — the ladder does not reset because the currency changed.
        _killBull(aliceBull, bobBull);
        uint256 rungTwo = 200e18;
        uint256 bullPaid = _bnbullDue(rungTwo);
        uint256 bullRest = bullPaid - (bullPaid * 3_000) / 10_000;
        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);
        assertEq(bnbull.balanceOf(address(sink)), (bullRest * 5_000) / 10_000);
    }

    /// @dev "An LP share with nowhere to send it is not a no-op": on the
    ///      native path a `.call{value:}` to `address(0)` SUCCEEDS and burns
    ///      the slice. Point the slot first, then open the share.
    function test_anLpShareCannotBeOpenedWithoutASlot() public {
        vm.expectRevert(Graveyard.ZeroAddress.selector);
        grave.setShares(3_000, 1);

        vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidShare.selector, uint256(5_001)));
        grave.setShares(5_001, 0);

        vm.expectRevert(Graveyard.ZeroAddress.selector);
        grave.setLpTreasury(address(0));
    }

    /**
     * @notice The dev leg is NOT the never-fail leg, and that asymmetry is
     *         deliberate: a broken treasury is the owner's own
     *         misconfiguration on the owner's own money, and failing loudly is
     *         how it gets noticed.
     */
    function test_aBrokenTreasuryDoesRevertTheRevive() public {
        RevertingReceiver brokenTreasury = new RevertingReceiver();
        grave.setTreasury(address(brokenTreasury));
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        vm.expectRevert(Graveyard.TreasuryTransferFailed.selector);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The refund is dead last, and re-entrancy finds nothing half-done
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The oracle cushion comes back only once the bull is standing.
     *
     * @dev The refund is the one call in the whole revive that hands control
     *      to an address of the caller's choosing. A re-entrant frame must
     *      find `nonReentrant` closed AND every piece of state already
     *      settled — the life spent, the bull alive.
     */
    function test_theRefundIsDeadLastAndAReentrantFrameIsBlocked() public {
        GraveyardReentrantReviver reviver = new GraveyardReentrantReviver();
        uint256 reviverBull = _mintBull(address(reviver));
        reviver.configure(address(grave), reviverBull);

        _killBull(reviverBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        vm.deal(address(this), address(this).balance + 5 ether);
        reviver.revive{value: due * 3}(reviverBull);

        assertTrue(reviver.sawRefund(), "no cushion came back");
        assertTrue(reviver.reentryReverted(), "a re-entrant revive got through");
        assertEq(reviver.usedAtRefund(), 1, "the life was not spent before the refund");
        assertTrue(bulls.isAlive(reviverBull));
        assertEq(grave.resurrectsUsed(reviverBull), 1, "two lives were spent");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The deferred events carry the running total
    // ══════════════════════════════════════════════════════════════════════

    /// @dev So an indexer can watch the backlog build without reading state.
    function test_deferredEventsCarryTheRunningBucketTotal() public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));

        uint256 first = (_bnbullDue(USD_RUNG_1) * 3_000) / 10_000;
        _killBull(aliceBull, bobBull);
        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.PotDeferred(Graveyard.PotSource.Bnbull, first, first);
        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);

        // Rung two is $200, so the second slice is four times the first and
        // the running total is the sum of both.
        uint256 second = (_bnbullDue(200e18) * 3_000) / 10_000;
        _killBull(aliceBull, bobBull);
        vm.expectEmit(true, false, false, true, address(grave));
        emit Graveyard.PotDeferred(Graveyard.PotSource.Bnbull, second, first + second);
        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);

        assertEq(grave.pendingPotBnbull(), first + second);
    }

    /// @dev Fuzzed over the payment: with the donation route dead, a revive
    ///      may not revert for ANY amount the ladder can produce, and not one
    ///      wei may go missing.
    function testFuzz_aReviveNeverFailsOnADeadRouteAndLosesNothing(uint96 cushion) public {
        GraveyardRevertingMintDrop bad = new GraveyardRevertingMintDrop();
        _repointGraveyardWire(Graveyard.Wire.MintDrop, address(bad));
        _killBull(aliceBull, bobBull);

        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 value = due + (uint256(cushion) % 5 ether);
        vm.deal(alice, value + 1 ether);

        uint256 treasuryBefore = treasury.balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        grave.resurrectWithBNB{value: value}(aliceBull);

        assertTrue(bulls.isAlive(aliceBull));
        assertEq(aliceBefore - alice.balance, due, "the payer was charged the wrong amount");
        assertEq(
            grave.pendingPotNative() + (treasury.balance - treasuryBefore),
            due,
            "wei went missing on the deferred path"
        );
        assertEq(address(grave).balance, grave.pendingPotNative());
    }
}
