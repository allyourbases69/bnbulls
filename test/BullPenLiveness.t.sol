// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {BullPen} from "../contracts/BullPen.sol";
import {MintDrop} from "../contracts/MintDrop.sol";

/**
 * @title BullPenLivenessTest
 * @notice The other half of the pen's story. `BullPenSnipe.t.sol` proves the
 *         draw cannot be gamed; this file proves a buyer who has PAID always
 *         gets their bull, without needing us.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      THE ONE FAILURE HERE THAT HURTS A REAL PLAYER
 *      ══════════════════════════════════════════════════════════════════════
 *      Delivery is asynchronous, so between paying and receiving there is a
 *      window in which the buyer owns nothing. Two things have to be true in
 *      that window or somebody is out of pocket for nothing:
 *
 *        1. the bull must still be reachable, by them, without us; and
 *        2. if it never becomes reachable, the money must come back.
 *
 *      (1) is the permissionless blockhash fallback: `armFallback` ->
 *      `pinFallbackSeed` -> `settle`, none of which needs VRF to be alive, an
 *      owner key or a keeper. (2) is `refund`, which exists because the money
 *      is now ESCROWED in the pen rather than routed at reserve time.
 *
 *      ⚠ THE ROUTING CHANGE IS THE WHOLE REASON (2) IS POSSIBLE. `MintDrop`
 *      used to route the payment at `reserve`: 70% to a treasury EOA and 30%
 *      into the two `Jackpot` contracts, which are NO-WITHDRAW BY DESIGN.
 *      Nothing gets money out of a jackpot except a won ticket, so by the time
 *      a reservation existed there was nothing left to refund out of. Payment
 *      is now held here and routed on settle.
 *
 *      ⛔ AND THE RULE THAT KEEPS THAT SAFE: a refund requires `!seeded`, not
 *      merely `!settled`. Once a word exists the outcome is computable off
 *      chain, so a refund after that point would BE the free-abort attack the
 *      two-transaction design exists to close. The tests below are what stop
 *      that line being deleted by somebody who thinks it is redundant.
 */
contract BullPenLivenessTest is BnbullsBase {
    BullPen internal pen;

    uint256 internal constant STOCK = 40;

    function setUp() public override {
        super.setUp();
        pen = new BullPen(address(bulls), address(bnbull), owner, address(coord));
        pen.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        pen.bootstrapSeller(address(drop));
        for (uint256 i = 0; i < STOCK; i++) {
            bulls.mint(address(pen));
        }
        drop.bootstrapWire(MintDrop.Wire.Pen, address(pen));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _buy(address who) internal returns (uint256 reservationId) {
        (, uint256 due,,) = drop.quote(1);
        vm.deal(who, who.balance + due * 2 + 1 ether);
        vm.prank(who);
        drop.mintWithBNB{value: due * 2}(who, 1);
        return pen.nextReservationId() - 1;
    }

    function _requestIdOf(uint256 reservationId) internal view returns (uint256) {
        for (uint256 i = 1; i <= coord.nextRequestId(); i++) {
            if (pen.reservationOfRequest(i) == reservationId) return i;
        }
        revert("no vrf request for reservation");
    }

    function _state(uint256 rid) internal view returns (BullPen.Rescue) {
        (BullPen.Rescue s,,) = pen.rescueState(rid);
        return s;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE STUCK RESERVATION, AND THE BUYER GETTING OUT OF IT ALONE
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice VRF never answers. The buyer, using nothing but their own wallet
     *         and the contract's own view, recovers their bull.
     * @dev ⛔ THIS IS THE TEST THE WHOLE DESIGN RESTS ON. No owner call, no
     *      keeper, no coordinator. If this ever stops passing, a stalled VRF
     *      means somebody paid for nothing.
     */
    function test_aBuyerAloneCanRecoverAReservationVrfAbandoned() public {
        uint256 rid = _buy(alice);
        assertEq(bulls.balanceOf(alice), 0, "no bull yet, by design");

        // The coordinator is simply never going to answer.
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.WaitingForVrf));
        // ⚠ THE REFUND WINDOW OPENS FIRST, SO THE VIEW NAMES THAT BLOCK FIRST.
        // The buyer gets the choice to leave with their money BEFORE anybody is
        // allowed to force an outcome onto them. This test is about the buyer
        // who would rather have the bull, so it rolls straight past it.
        (, uint256 refundAt,) = pen.rescueState(rid);
        assertEq(refundAt, block.number + pen.refundAfterBlocks(), "the view names the refund block");

        vm.roll(refundAt);
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Refundable));

        uint256 armAt = block.number + (pen.vrfTimeoutBlocks() - pen.refundAfterBlocks());
        vm.roll(armAt);
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.ArmFallback));

        // Everything from here is alice, and alice is not special.
        vm.prank(alice);
        pen.armFallback(rid);

        (BullPen.Rescue s, uint256 pinAt,) = pen.rescueState(rid);
        assertEq(uint8(s), uint8(BullPen.Rescue.WaitFallback));
        vm.roll(pinAt);
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.PinFallback));

        vm.prank(alice);
        pen.pinFallbackSeed(rid);
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Settle));

        vm.prank(alice);
        pen.settle(rid);

        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Settled));
        assertEq(bulls.balanceOf(alice), 1, "the buyer got the bull they paid for");
    }

    /// @notice There is no block at which NEITHER action is available. The pin
    ///         window is 256 blocks and re-arming opens the block after it
    ///         closes, so a buyer who sleeps through one window is not stranded.
    function test_thereIsNoDeadZoneBetweenPinningAndReArming() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.vrfTimeoutBlocks());
        vm.prank(alice);
        pen.armFallback(rid);
        uint64 target = pen.reservationOf(rid).fallbackBlock;

        // Sleep through the entire pin window.
        vm.roll(uint256(target) + 257);
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.ArmFallback), "re-arming must be open");

        vm.prank(alice);
        pen.armFallback(rid);
        uint64 target2 = pen.reservationOf(rid).fallbackBlock;
        vm.roll(uint256(target2) + 1);
        vm.prank(alice);
        pen.pinFallbackSeed(rid);
        vm.prank(alice);
        pen.settle(rid);
        assertEq(bulls.balanceOf(alice), 1, "a missed window costs a retry, not the bull");
    }

    /// @notice Every state the view reports names an action the CALLER may
    ///         actually take. A view that says "arm it" while `armFallback`
    ///         reverts would be worse than no view at all.
    function test_everyStateTheViewReportsIsActuallyCallable() public {
        uint256 rid = _buy(alice);

        // WaitingForVrf: arming must revert.
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.WaitingForVrf));
        vm.expectRevert();
        pen.armFallback(rid);

        vm.roll(block.number + pen.vrfTimeoutBlocks());
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.ArmFallback));
        pen.armFallback(rid); // must NOT revert

        // WaitFallback: pinning must revert.
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.WaitFallback));
        vm.expectRevert();
        pen.pinFallbackSeed(rid);

        (, uint256 pinAt,) = pen.rescueState(rid);
        vm.roll(pinAt);
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.PinFallback));
        pen.pinFallbackSeed(rid); // must NOT revert

        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Settle));
        pen.settle(rid); // must NOT revert
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Settled));
    }

    /**
     * @notice A stuck reservation blocks everybody behind it, and the view says
     *         so by name — so the person who is stuck knows WHICH reservation
     *         to go and unstick.
     * @dev Head-of-line blocking is a deliberate security control (`nextToSettle`
     *      is what stops a caller shopping for an ordering), so the answer can
     *      never be "let it settle out of order". The answer is that unsticking
     *      the head is permissionless, so the person with the incentive can do
     *      it themselves.
     */
    function test_beingQueuedBehindAStuckReservationNamesTheBlocker() public {
        uint256 first = _buy(alice);
        uint256 second = _buy(bob);

        // Bob's word arrives. Alice's never does.
        coord.fulfill(_requestIdOf(second), uint256(keccak256("bob")));

        (BullPen.Rescue s,, uint256 blockedBy) = pen.rescueState(second);
        assertEq(uint8(s), uint8(BullPen.Rescue.QueuedBehind));
        assertEq(blockedBy, first, "the view names the reservation in front");

        // Bob unsticks Alice's, because he can, and then both settle.
        vm.roll(block.number + pen.vrfTimeoutBlocks());
        vm.startPrank(bob);
        pen.armFallback(first);
        (, uint256 pinAt,) = pen.rescueState(first);
        vm.roll(pinAt);
        pen.pinFallbackSeed(first);
        pen.settle(first);
        pen.settle(second);
        vm.stopPrank();

        assertEq(bulls.balanceOf(alice), 1, "the stuck buyer is paid out too");
        assertEq(bulls.balanceOf(bob), 1);
    }

    /// @notice `queueHead` is the one bounded read a liveness keeper needs: the
    ///         only reservation whose being stuck can hold anyone else up.
    function test_queueHeadPointsAtTheOnlyThingWorthUnsticking() public {
        (uint256 idle,,) = pen.queueHead();
        assertEq(idle, 1, "an empty queue still names the next id");
        (, BullPen.Rescue idleState,) = pen.queueHead();
        assertEq(uint8(idleState), uint8(BullPen.Rescue.Unknown), "nothing to do");

        uint256 first = _buy(alice);
        _buy(bob);
        (uint256 head, BullPen.Rescue s,) = pen.queueHead();
        assertEq(head, first);
        assertEq(uint8(s), uint8(BullPen.Rescue.WaitingForVrf));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. A PENDING RESERVATION SURVIVES A RELOAD
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The buyer's address alone is enough to find what they are owed.
     * @dev Nothing here depends on a toast, a receipt, a local cache or the
     *      device the purchase was made on. That is the whole requirement.
     */
    function test_aBuyerFindsTheirOwnPendingReservationFromTheirAddressAlone() public {
        assertEq(pen.openReservationsOf(alice).length, 0);

        uint256 rid = _buy(alice);
        uint256[] memory open = pen.openReservationsOf(alice);
        assertEq(open.length, 1, "the reservation is discoverable");
        assertEq(open[0], rid);
        assertEq(pen.reservationIdsOf(alice).length, 1);

        coord.fulfill(_requestIdOf(rid), uint256(keccak256("w")));
        pen.settle(rid);

        assertEq(pen.openReservationsOf(alice).length, 0, "settled drops off the open list");
        assertEq(pen.reservationIdsOf(alice).length, 1, "but the history is kept");
    }

    /**
     * @notice A gifted mint is discoverable by BOTH people, because a gift
     *         concerns two of them and they need different things from it.
     *
     * @dev ⚠ THIS TEST USED TO ASSERT THE PAYER SAW NOTHING, AND THAT WAS THE
     *      BUG IT WAS DOCUMENTING AS CORRECT. Indexing only the recipient meant
     *      the gifter — who holds the refund right, because they are the one out
     *      of pocket — had no way to find the reservation they were entitled to
     *      refund. The recipient could see it and be truthfully told the money
     *      was not theirs, which helped nobody.
     */
    function test_aGiftedMintIsDiscoverableByBothTheRecipientAndThePayer() public {
        (, uint256 due,,) = drop.quote(1);
        vm.deal(alice, due * 2 + 1 ether);
        vm.prank(alice);
        drop.mintWithBNB{value: due * 2}(bob, 1);
        uint256 rid = pen.nextReservationId() - 1;

        uint256[] memory recipient = pen.openReservationsOf(bob);
        uint256[] memory payer = pen.openReservationsOf(alice);
        assertEq(recipient.length, 1, "the recipient is waiting for a bull");
        assertEq(payer.length, 1, "the gifter holds the refund right and must find it");
        assertEq(recipient[0], rid);
        assertEq(payer[0], rid);

        // Same reservation, different rights. The struct is what says which.
        assertEq(pen.reservationOf(rid).to, bob, "the bull is bob's");
        assertEq(pen.reservationOf(rid).payer, alice, "the money is alice's");
    }

    function test_severalOpenReservationsAreAllListed() public {
        uint256 a = _buy(alice);
        uint256 b = _buy(alice);
        uint256 c = _buy(alice);
        uint256[] memory open = pen.openReservationsOf(alice);
        assertEq(open.length, 3);
        assertEq(open[0], a);
        assertEq(open[1], b);
        assertEq(open[2], c);

        coord.fulfill(_requestIdOf(a), 1);
        pen.settle(a);
        open = pen.openReservationsOf(alice);
        assertEq(open.length, 2, "only the unsettled ones");
        assertEq(open[0], b);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. THE COUNT: WHAT THE PEN HOLDS IS NOT SOLD
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `poolIds()` is the whole unsold set in ONE call, and it is exactly
     *         what has to be subtracted from `nextTokenId - 1` to get the honest
     *         circulating count.
     * @dev Without it the site reads "500 of 500 minted" while several hundred
     *      bulls have never been sold, and the only alternative was 469 separate
     *      `poolAt` calls.
     */
    function test_poolIdsIsTheHonestCountInOneCall() public {
        uint32[] memory held = pen.poolIds();
        assertEq(held.length, STOCK, "the pen holds the stock");
        assertEq(held.length, pen.poolSize(), "and agrees with poolSize");

        uint256 existing = uint256(bulls.nextTokenId()) - 1;
        assertEq(existing, STOCK, "every id that exists is in the pen");
        assertEq(existing - held.length, 0, "so nothing is in circulation yet");

        uint256 rid = _buy(alice);
        coord.fulfill(_requestIdOf(rid), uint256(keccak256("one")));
        pen.settle(rid);

        held = pen.poolIds();
        assertEq(held.length, STOCK - 1, "the pen shrank by exactly one");
        assertEq(
            (uint256(bulls.nextTokenId()) - 1) - held.length,
            1,
            "and exactly one bull is in circulation"
        );
    }

    /// @notice The set `poolIds` reports is the set the pen actually owns. If
    ///         these ever disagree the circulating count is wrong in a way
    ///         nothing else would catch.
    function test_everyIdPoolIdsReportsIsReallyHeldByThePen() public {
        uint256 rid = _buy(alice);
        coord.fulfill(_requestIdOf(rid), uint256(keccak256("two")));
        pen.settle(rid);

        uint32[] memory held = pen.poolIds();
        for (uint256 i = 0; i < held.length; i++) {
            assertEq(bulls.ownerOf(held[i]), address(pen), "poolIds named a bull it does not hold");
        }
        assertEq(bulls.balanceOf(address(pen)), held.length, "and it holds nothing else");
    }

    /// @notice `sellable` excludes bulls promised to open reservations, so the
    ///         site's "N left" cannot oversell what is actually free.
    function test_sellableExcludesWhatIsAlreadyPromised() public {
        _buy(alice);
        assertEq(pen.poolSize(), STOCK, "the bull is still physically here");
        assertEq(pen.sellable(), STOCK - 1, "but it is spoken for");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE INDEX MUST NOT WEAKEN THE DRAW
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The per-owner index is bookkeeping and nothing more: the same
     *         seed still draws the same POSITION in the pool no matter who the
     *         bull is for.
     * @dev Asserted on the position rather than the id, because the two pens
     *      are stocked with disjoint id ranges — the point is that `_drawOne`
     *      is still `(seed, index) % poolLength` and has not quietly acquired a
     *      dependency on `to`.
     */
    function test_theOwnerIndexDoesNotEnterTheDraw() public {
        uint256 word = uint256(keccak256("fixed"));

        uint32[] memory poolA = pen.poolIds();
        uint256 ridA = _buy(alice);
        coord.fulfill(_requestIdOf(ridA), word);
        pen.settle(ridA);
        uint256 posA = _positionOf(poolA, pen.drawnIds(ridA)[0]);

        // A second pen over the same collection, stocked to the same depth,
        // sold to a DIFFERENT recipient, seeded with the SAME word.
        BullPen pen2 = new BullPen(address(bulls), address(bnbull), owner, address(coord));
        pen2.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        pen2.bootstrapSeller(address(this));
        for (uint256 i = 0; i < STOCK; i++) {
            bulls.mint(address(pen2));
        }
        uint32[] memory poolB = pen2.poolIds();
        uint256 ridB = pen2.reserve(bob, 1, bob, 0);
        coord.fulfill(_requestIdOfOn(pen2, ridB), word);
        pen2.settle(ridB);
        uint256 posB = _positionOf(poolB, pen2.drawnIds(ridB)[0]);

        assertEq(poolA.length, poolB.length, "the two pools must be the same depth");
        assertEq(posA, posB, "the draw moved with the buyer's address");
    }

    function _positionOf(uint32[] memory pool, uint32 id) internal pure returns (uint256) {
        for (uint256 i = 0; i < pool.length; i++) {
            if (pool[i] == id) return i;
        }
        revert("drawn id was not in the pool");
    }

    function _requestIdOfOn(BullPen p, uint256 rid) internal view returns (uint256) {
        for (uint256 i = 1; i <= coord.nextRequestId(); i++) {
            if (p.reservationOfRequest(i) == rid) return i;
        }
        revert("no vrf request for reservation");
    }

    /// @notice An id nobody reserved reports `Unknown` rather than a state that
    ///         invites a call that would revert.
    function test_anUnknownReservationSaysSo() public view {
        (BullPen.Rescue s, uint256 at, uint256 by) = pen.rescueState(999);
        assertEq(uint8(s), uint8(BullPen.Rescue.Unknown));
        assertEq(at, 0);
        assertEq(by, 0);
    }
}
