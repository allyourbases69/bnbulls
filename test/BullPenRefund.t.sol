// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {BullPen} from "../contracts/BullPen.sol";
import {MintDrop} from "../contracts/MintDrop.sol";

/// @notice A buyer that cannot receive BNB, to prove a refund it refuses does
///         not wedge the FIFO queue for anybody else.
contract RefusingPayer {
    MintDrop private immutable drop;
    bool public refusing = true;

    constructor(MintDrop _drop) {
        drop = _drop;
    }

    function stopRefusing() external {
        refusing = false;
    }

    function buy(uint256 value) external {
        drop.mintWithBNB{value: value}(address(this), 1);
    }

    function refund(BullPen pen, uint256 rid) external {
        pen.refund(rid);
    }

    receive() external payable {
        require(!refusing, "no");
    }
}

/**
 * @title BullPenRefundTest
 * @notice A buyer who pays and never gets a bull must be able to get their
 *         money back, and must never be able to get the money AND the bull.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS NEEDED A ROUTING CHANGE, NOT AN EXTRA FUNCTION
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop` used to route the payment at `reserve` time: 70% to a
 *      treasury EOA and 30% into the two `Jackpot` contracts. A jackpot is
 *      NO-WITHDRAW BY DESIGN — nothing gets money out of one except a won
 *      ticket — so by the moment a reservation existed, most of the payment was
 *      already somewhere nobody could ever retrieve it from, including us.
 *      A refund bolted onto that would have had nothing to pay out of.
 *
 *      So the money is ESCROWED in the pen and routed on SETTLE. The pots and
 *      the treasury are paid one transaction later than they used to be. That
 *      is the entire cost.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⛔ THE TWO RULES THESE TESTS EXIST TO DEFEND
 *      ══════════════════════════════════════════════════════════════════════
 *      1. **A seed is the point of no return.** `refund` checks `!seeded`, not
 *         merely `!settled`. Once a word exists the drawn ids are computable
 *         off chain from public state, so a refund available after that point
 *         would BE the free-abort attack the whole two-transaction design
 *         exists to close: buy, compute, unwind unless it is a legendary.
 *
 *      2. **Refund and settle are mutually exclusive forever.** One flag,
 *         written before any external call, checked by `settle`,
 *         `fulfillRandomWords`, `armFallback` and `pinFallbackSeed`. A word
 *         that arrives after a refund is inert — otherwise the buyer keeps
 *         their money and takes a bull, and the pen is one short for good.
 */
contract BullPenRefundTest is BnbullsBase {
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

    function _buy(address who) internal returns (uint256 reservationId) {
        (, uint256 due,,) = drop.quote(1);
        vm.deal(who, who.balance + due * 2 + 1 ether);
        vm.prank(who);
        drop.mintWithBNB{value: due * 2}(who, 1);
        return pen.nextReservationId() - 1;
    }

    function _requestIdOf(uint256 rid) internal view returns (uint256) {
        for (uint256 i = 1; i <= coord.nextRequestId(); i++) {
            if (pen.reservationOfRequest(i) == rid) return i;
        }
        revert("no vrf request for reservation");
    }

    function _state(uint256 rid) internal view returns (BullPen.Rescue) {
        (BullPen.Rescue s,,) = pen.rescueState(rid);
        return s;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE MONEY IS ACTUALLY THERE TO REFUND
    // ══════════════════════════════════════════════════════════════════════

    function test_thePaymentIsEscrowedNotRouted() public {
        uint256 potBefore = wbnb.balanceOf(address(potBnb));
        uint256 treasuryBefore = treasury.balance;

        uint256 rid = _buy(alice);

        assertGt(pen.reservationOf(rid).nativeEscrow, 0, "the pen recorded an escrow");
        assertEq(
            address(pen).balance, pen.reservationOf(rid).nativeEscrow, "and it physically holds it"
        );
        assertEq(wbnb.balanceOf(address(potBnb)), potBefore, "the pot has NOT been paid yet");
        assertEq(treasury.balance, treasuryBefore, "the treasury has NOT been paid yet");

        coord.fulfill(_requestIdOf(rid), uint256(keccak256("w")));
        pen.settle(rid);

        assertEq(address(pen).balance, 0, "settle hands the escrow on");
        assertGt(wbnb.balanceOf(address(potBnb)), potBefore, "the pot is paid at settle");
        assertGt(treasury.balance, treasuryBefore, "and so is the treasury");
    }

    function test_theBuyerCanTakeTheirMoneyBackAfterTheWindowOpens() public {
        uint256 rid = _buy(alice);
        uint256 escrow = pen.reservationOf(rid).nativeEscrow;
        uint256 before = alice.balance;

        vm.roll(block.number + pen.refundAfterBlocks());
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Refundable));

        vm.prank(alice);
        pen.refund(rid);

        assertEq(alice.balance, before + escrow, "every wei came back");
        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Refunded));
        assertEq(pen.sellable(), STOCK, "and the bull went back on sale");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. ⛔ REFUND AND SETTLE ARE MUTUALLY EXCLUSIVE, FOREVER
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The failure that would actually cost money: refund, then the
    ///         word turns up and settles. Money back AND a bull, pen one short.
    function test_aWordArrivingAfterARefundIsInertAndCannotSettle() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(rid);

        // VRF wakes up late and delivers the word it was always going to.
        coord.fulfill(_requestIdOf(rid), uint256(keccak256("late")));

        assertFalse(pen.reservationOf(rid).seeded, "a refunded reservation must never seed");
        vm.expectRevert(abi.encodeWithSelector(BullPen.AlreadyRefunded.selector, rid));
        pen.settle(rid);
        assertEq(bulls.balanceOf(alice), 0, "no bull on top of the refund");
        assertEq(pen.poolSize(), STOCK, "and the pen is not one short");
    }

    /// @notice Both seeding routes are closed, not just the VRF one. The
    ///         blockhash fallback cannot resurrect a refunded reservation.
    function test_aRefundedReservationCannotBeSeededByTheFallbackEither() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(rid);

        vm.roll(block.number + pen.vrfTimeoutBlocks());
        vm.expectRevert(abi.encodeWithSelector(BullPen.AlreadyRefunded.selector, rid));
        pen.armFallback(rid);
        vm.expectRevert(abi.encodeWithSelector(BullPen.AlreadyRefunded.selector, rid));
        pen.pinFallbackSeed(rid);
    }

    /// @notice The other half: once a seed exists the outcome is computable off
    ///         chain, so a refund would be the free-abort attack.
    function test_aSeededReservationCanNeverBeRefundedNoMatterHowLongYouWait() public {
        uint256 rid = _buy(alice);
        coord.fulfill(_requestIdOf(rid), uint256(keccak256("seed")));

        vm.roll(block.number + pen.refundAfterBlocks() + pen.vrfTimeoutBlocks());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BullPen.AlreadySeeded.selector, rid));
        pen.refund(rid);
    }

    function test_aRefundBeforeTheWindowIsRefused() public {
        uint256 rid = _buy(alice);
        vm.prank(alice);
        vm.expectRevert();
        pen.refund(rid);
    }

    function test_aRefundCannotBeTakenTwice() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(rid);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BullPen.AlreadyRefunded.selector, rid));
        pen.refund(rid);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. WHO MAY CALL IT
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Payer-only. A stranger refunding somebody else's stuck
    ///         reservation would hand them a free choice between two outcomes
    ///         for their own seeded one, both computable off chain.
    function test_aStrangerCannotRefundSomebodyElsesReservation() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BullPen.NotThePayer.selector, bob, alice));
        pen.refund(rid);
    }

    /// @notice Payer-only does NOT cost liveness: anyone can still push a stuck
    ///         reservation all the way through to delivery. That is what keeps a
    ///         lost key from wedging the queue.
    function test_payerOnlyRefundsDoNotCostAnybodyLiveness() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.vrfTimeoutBlocks());

        // bob is nobody. He can still deliver alice her bull.
        vm.startPrank(bob);
        pen.armFallback(rid);
        (, uint256 pinAt,) = pen.rescueState(rid);
        vm.roll(pinAt);
        pen.pinFallbackSeed(rid);
        pen.settle(rid);
        vm.stopPrank();

        assertEq(bulls.balanceOf(alice), 1, "a stranger delivered it");
    }

    function test_aGiftedMintRefundsTheGifter() public {
        (, uint256 due,,) = drop.quote(1);
        vm.deal(alice, due * 4);
        vm.prank(alice);
        drop.mintWithBNB{value: due * 2}(bob, 1);
        uint256 rid = pen.nextReservationId() - 1;

        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BullPen.NotThePayer.selector, bob, alice));
        pen.refund(rid);

        uint256 before = alice.balance;
        vm.prank(alice);
        pen.refund(rid);
        assertGt(alice.balance, before, "the gifter is the one out of pocket, so they get it back");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE FIFO HOLE
    // ══════════════════════════════════════════════════════════════════════

    function test_aRefundAtTheHeadDoesNotWedgeTheQueue() public {
        uint256 first = _buy(alice);
        uint256 second = _buy(bob);
        coord.fulfill(_requestIdOf(second), uint256(keccak256("b")));

        assertEq(uint8(_state(second)), uint8(BullPen.Rescue.QueuedBehind));

        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(first);

        assertEq(pen.nextToSettle(), second, "the queue moved past the hole");
        assertEq(uint8(_state(second)), uint8(BullPen.Rescue.Settle));
        pen.settle(second);
        assertEq(bulls.balanceOf(bob), 1, "the buyer behind it is paid out");
    }

    function test_aRefundInTheMiddleDoesNotWedgeTheQueue() public {
        uint256 a = _buy(alice);
        uint256 b = _buy(bob);
        uint256 c = _buy(carol);

        coord.fulfill(_requestIdOf(a), uint256(keccak256("a")));
        coord.fulfill(_requestIdOf(c), uint256(keccak256("c")));

        pen.settle(a);
        assertEq(pen.nextToSettle(), b, "b is next and it is not seeded");
        assertEq(uint8(_state(c)), uint8(BullPen.Rescue.QueuedBehind));

        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(bob);
        pen.refund(b);

        assertEq(pen.nextToSettle(), c, "the hole is skipped");
        pen.settle(c);
        assertEq(bulls.balanceOf(alice), 1);
        assertEq(bulls.balanceOf(bob), 0, "refunded, so no bull");
        assertEq(bulls.balanceOf(carol), 1);
        assertEq(pen.poolSize(), STOCK - 2, "exactly two bulls left the pen");
    }

    /// @notice A run of refunds is skipped in one step, so a stretch of stuck
    ///         reservations does not need one settle per hole to clear.
    function test_aRunOfRefundsIsSkippedInOneStep() public {
        uint256 a = _buy(alice);
        uint256 b = _buy(bob);
        uint256 c = _buy(carol);
        coord.fulfill(_requestIdOf(c), uint256(keccak256("c")));

        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(a);
        vm.prank(bob);
        pen.refund(b);

        assertEq(pen.nextToSettle(), c, "both holes skipped");
        pen.settle(c);
        assertEq(bulls.balanceOf(carol), 1);
    }

    /// @notice Skipping a hole must not change what anybody else draws relative
    ///         to a world where the hole was never there. A refund draws
    ///         nothing, so `_pool` is identical either side of it.
    function test_skippingAHoleDoesNotDisturbTheDrawOfAnybodyBehindIt() public {
        uint256 word = uint256(keccak256("fixed"));

        // World A: alice's reservation is refunded, then bob settles.
        uint256 a = _buy(alice);
        uint256 b = _buy(bob);
        coord.fulfill(_requestIdOf(b), word);
        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(a);
        uint32[] memory poolBefore = pen.poolIds();
        pen.settle(b);
        uint32 drawn = pen.drawnIds(b)[0];

        // The draw is `word % poolLength` over the pool as it stood, untouched
        // by the refund in front of it.
        uint256 expected = uint256(keccak256(abi.encode(word, uint256(0)))) % poolBefore.length;
        assertEq(drawn, poolBefore[expected], "the refund in front changed the draw");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. BATCHES AND GRIEFING
    // ══════════════════════════════════════════════════════════════════════

    /// @notice ALL-OR-NOTHING, because a reservation carries ONE seed for all of
    ///         its bulls. There is no partial seed, so there is no partial
    ///         refund to offer.
    function test_aBatchRefundsWholeBecauseItCarriesOneSeed() public {
        (, uint256 due,,) = drop.quote(5);
        vm.deal(alice, due * 4);
        uint256 before = alice.balance;
        vm.prank(alice);
        drop.mintWithBNB{value: due * 2}(alice, 5);
        uint256 rid = pen.nextReservationId() - 1;
        assertEq(pen.sellable(), STOCK - 5, "five are spoken for");

        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(rid);

        assertEq(alice.balance, before, "the whole batch came back to the wei");
        assertEq(pen.sellable(), STOCK, "and all five went back on sale");
    }

    /// @notice A payer that refuses BNB cannot wedge the queue. The refund is
    ///         parked and pulled, and the reservation is still marked refunded.
    function test_aPayerThatRefusesDeliveryCannotWedgeTheQueue() public {
        RefusingPayer hostile = new RefusingPayer(drop);
        (, uint256 due,,) = drop.quote(1);
        vm.deal(address(hostile), due * 3);
        // EXACTLY the amount due: `MintDrop` refunds the BNB cushion to
        // `msg.sender` and reverts `RefundFailed` if that bounces, so a
        // contract that refuses BNB cannot overpay in the first place.
        hostile.buy(due);
        uint256 rid = pen.nextReservationId() - 1;
        uint256 escrow = pen.reservationOf(rid).nativeEscrow;

        uint256 second = _buy(bob);
        coord.fulfill(_requestIdOf(second), uint256(keccak256("b")));

        vm.roll(block.number + pen.refundAfterBlocks());
        hostile.refund(pen, rid);

        assertEq(uint8(_state(rid)), uint8(BullPen.Rescue.Refunded), "still refunded");
        assertEq(pen.unclaimedRefundNative(address(hostile)), escrow, "parked, not lost");

        // The queue moved on regardless, which is the whole point.
        pen.settle(second);
        assertEq(bulls.balanceOf(bob), 1);

        hostile.stopRefusing();
        pen.claimRefund(address(hostile));
        assertGe(address(hostile).balance, escrow, "pulled once it can receive");
        assertEq(pen.unclaimedRefundNative(address(hostile)), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. THE TWO CLOCKS
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The refund window must open BEFORE the forced-draw window, or a
     *         stranger could settle a reservation its buyer was still entitled
     *         to walk away from. Enforced by both setters, in both directions.
     */
    function test_theRefundWindowCanNeverBeMovedPastTheForcedDrawWindow() public {
        assertLt(pen.refundAfterBlocks(), pen.vrfTimeoutBlocks(), "refund opens first");

        // ⚠ HOIST THE ARGUMENTS. `vm.expectRevert()` attaches to the very next
        // CALL, and an external getter used as an argument is evaluated first -
        // so `setX(pen.y())` would arm the expectation against `y()`.
        uint256 vrfTimeout = pen.vrfTimeoutBlocks();
        uint256 refundAfter = pen.refundAfterBlocks();
        vm.expectRevert();
        pen.setRefundAfterBlocks(vrfTimeout);
        vm.expectRevert();
        pen.setVrfTimeoutBlocks(refundAfter);

        pen.setRefundAfterBlocks(9_000);
        assertEq(pen.refundAfterBlocks(), 9_000);
    }

    /// @notice ⛔ THE FLOOR EXISTS TO STOP THE OWNER. Below the worst observed
    ///         VRF fulfilment a refund window becomes a griefing tool: reserve,
    ///         refund immediately, repeat, and the queue churns while the
    ///         subscription pays for words nobody uses.
    function test_theOwnerCannotDialTheRefundWindowDownToNothing() public {
        uint256 floor_ = pen.MIN_REFUND_AFTER_BLOCKS();
        vm.expectRevert();
        pen.setRefundAfterBlocks(0);
        vm.expectRevert();
        pen.setRefundAfterBlocks(floor_ - 1);
        assertGe(floor_, 3_169, "must clear the worst measured live fulfilment");
    }

    /// @notice The view walks the buyer through it: wait, then you may leave,
    ///         then anyone may force it through.
    function test_theViewNamesTheBlockTheRefundWindowOpens() public {
        uint256 rid = _buy(alice);
        (BullPen.Rescue s, uint256 at,) = pen.rescueState(rid);
        assertEq(uint8(s), uint8(BullPen.Rescue.WaitingForVrf));
        assertEq(at, block.number + pen.refundAfterBlocks(), "it names the refund block first");

        vm.roll(at);
        (s, at,) = pen.rescueState(rid);
        assertEq(uint8(s), uint8(BullPen.Rescue.Refundable));
        assertEq(at, block.number + (pen.vrfTimeoutBlocks() - pen.refundAfterBlocks()));
    }

    /**
     * @notice The gifter can FIND the reservation they are entitled to refund.
     *
     * @dev ⛔ THE REFUND GUARANTEE HAD A HOLE EXACTLY HERE. `refund` is
     *      payer-only, but the only index was keyed on the recipient - so on a
     *      gifted mint the one person who could refund was the one person who
     *      could not find it. "You can always get your money back" was false
     *      for precisely the case where somebody else has your bull.
     */
    function test_theGifterCanDiscoverTheReservationTheyCanRefund() public {
        (, uint256 due,,) = drop.quote(1);
        vm.deal(alice, due * 4);
        vm.prank(alice);
        drop.mintWithBNB{value: due}(bob, 1);
        uint256 rid = pen.nextReservationId() - 1;

        uint256[] memory gifterSees = pen.openReservationsOf(alice);
        assertEq(gifterSees.length, 1, "the payer must be able to find it");
        assertEq(gifterSees[0], rid);

        uint256[] memory recipientSees = pen.openReservationsOf(bob);
        assertEq(recipientSees.length, 1, "and so must the recipient");
        assertEq(recipientSees[0], rid);

        // And the one who can find it is the one who can act on it.
        vm.roll(block.number + pen.refundAfterBlocks());
        uint256 before = alice.balance;
        vm.prank(alice);
        pen.refund(gifterSees[0]);
        assertGt(alice.balance, before, "discoverable AND refundable by the same person");
    }

    /// @notice A self-mint is indexed ONCE, so the ordinary path pays nothing
    ///         for the gift index and the two lists stay disjoint.
    function test_aSelfMintIsNotDoubleIndexed() public {
        uint256 rid = _buy(alice);
        uint256[] memory ids = pen.reservationIdsOf(alice);
        assertEq(ids.length, 1, "indexed once, not twice");
        assertEq(ids[0], rid);
    }

    /// @notice A wallet that both buys for itself and gifts sees both, once each.
    function test_aWalletThatBuysAndGiftsSeesBothExactlyOnce() public {
        uint256 own = _buy(alice);
        (, uint256 due,,) = drop.quote(1);
        vm.deal(alice, alice.balance + due * 2);
        vm.prank(alice);
        drop.mintWithBNB{value: due}(bob, 1);
        uint256 gift = pen.nextReservationId() - 1;

        uint256[] memory ids = pen.reservationIdsOf(alice);
        assertEq(ids.length, 2, "no duplicates, no omissions");
        assertEq(ids[0], own);
        assertEq(ids[1], gift);
    }

    /// @notice A refunded reservation stays listed, so the "your money came
    ///         back" dialogue survives a page reload instead of vanishing the
    ///         moment it becomes true.
    function test_aRefundedReservationStaysDiscoverableSoTheDialogueSurvivesAReload() public {
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.refundAfterBlocks());
        vm.prank(alice);
        pen.refund(rid);

        uint256[] memory open = pen.openReservationsOf(alice);
        assertEq(open.length, 1, "still findable after the refund");
        assertEq(uint8(_state(open[0])), uint8(BullPen.Rescue.Refunded), "and it says what happened");
    }
}
