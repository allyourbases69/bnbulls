// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {BullPen} from "../contracts/BullPen.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title SnipeBot
 * @notice The adversary. It KNOWS THE WHOLE RARITY TABLE — it reads
 *         `rarityOf` straight off the chain, exactly as anyone can, because
 *         `masterSeed` is public and the shuffle is in verified source.
 *
 * @dev ⚠ THIS IS NOT A CONVENIENCE MOCK. Every method here is one of the four
 *      attacks the pen claims to stop, written to actually succeed if it can:
 *
 *        `snipeSequential`   — time `nextTokenId()` and mint the legendary.
 *                              This one WORKS on the legacy path. That is the
 *                              bug, and `test_theSnipeWorksToday` proves it so
 *                              the fix has something to be measured against.
 *        `mintAndInspect`    — buy, then look for the outcome inside the same
 *                              transaction. There must be nothing to see.
 *        `mintOrRevert`      — buy, and revert the whole transaction unless a
 *                              legendary landed. The free-abort attack.
 *        `grindInOneTx`      — buy repeatedly in ONE transaction, keeping only
 *                              a run that produced a legendary.
 */
contract SnipeBot is IERC721Receiver {
    Bulls public immutable bulls;
    MintDrop public immutable drop;
    BullPen public immutable pen;

    error NoLegendary();

    constructor(Bulls _bulls, MintDrop _drop, BullPen _pen) {
        bulls = _bulls;
        drop = _drop;
        pen = _pen;
    }

    receive() external payable {}

    /// @notice Every bull this bot has actually taken delivery of. It is the
    ///         only handle it has on "what did I get", because the pen returns
    ///         no id at buy time.
    uint256[] public received;

    function receivedCount() external view returns (uint256) {
        return received.length;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        received.push(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice The legacy snipe: mint exactly when the counter reaches a
    ///         legendary id.
    function snipeSequential(uint256 value) external returns (uint256 id) {
        uint256[] memory ids = drop.mintWithBNB{value: value}(address(this), 1);
        return ids[0];
    }

    /// @notice Buy through the pen and report everything observable about the
    ///         outcome from inside the buying transaction.
    function mintAndInspect(uint256 value)
        external
        returns (uint256 returnedIds, uint256 balanceAfter, bool anySeeded)
    {
        uint256[] memory ids = drop.mintWithBNB{value: value}(address(this), 1);
        returnedIds = ids.length;
        balanceAfter = bulls.balanceOf(address(this));
        // Sweep every reservation this bot could possibly own and ask whether
        // any of them has a seed yet. If one did, the outcome would be
        // computable here and the abort would be back on.
        uint256 next = pen.nextReservationId();
        for (uint256 i = 1; i < next; i++) {
            if (pen.reservationOf(i).seeded) anySeeded = true;
        }
    }

    /// @notice Buy, and unwind the entire purchase unless a legendary landed.
    /// @dev This is the attack that makes naive same-transaction randomness
    ///      worthless. It must find nothing to branch on.
    function mintOrRevert(uint256 value) external {
        drop.mintWithBNB{value: value}(address(this), 1);
        for (uint256 i = 0; i < received.length; i++) {
            if (bulls.rarityOf(received[i]) == 4) return;
        }
        revert NoLegendary();
    }

    /// @notice Buy `tries` times in ONE transaction and keep the run only if a
    ///         legendary showed up.
    function grindInOneTx(uint256 valueEach, uint256 tries) external {
        for (uint256 t = 0; t < tries; t++) {
            drop.mintWithBNB{value: valueEach}(address(this), 1);
            // Try to settle immediately — the only route to an id.
            uint256 next = pen.nextToSettle();
            try pen.settle(next) {
                uint32[] memory ids = pen.drawnIds(next);
                for (uint256 j = 0; j < ids.length; j++) {
                    if (bulls.rarityOf(ids[j]) == 4) return;
                }
            } catch {
                // Not seeded. Keep buying.
            }
        }
        revert NoLegendary();
    }

    /// @notice Settle, then unwind unless a legendary landed.
    function settleOrRevert(uint256 reservationId) external {
        pen.settle(reservationId);
        uint32[] memory ids = pen.drawnIds(reservationId);
        for (uint256 j = 0; j < ids.length; j++) {
            if (bulls.rarityOf(ids[j]) == 4) return;
        }
        revert NoLegendary();
    }
}

/// @notice A recipient that refuses delivery, to prove it cannot wedge the
///         FIFO queue for everybody else.
contract HostileReceiver is IERC721Receiver {
    bool public refusing = true;

    function stopRefusing() external {
        refusing = false;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        require(!refusing, "HostileReceiver: no");
        return IERC721Receiver.onERC721Received.selector;
    }
}

/**
 * @title BullPenSnipeTest
 * @notice Proves the snipe is dead, not that minting still works.
 *
 * @dev The suite is deliberately built around ONE claim and its converse:
 *
 *        `test_theSnipeWorksToday`  — the legacy path is exploitable, 100% of
 *                                     the time, for the price of one mint.
 *        everything after it        — the same adversary, with the same
 *                                     knowledge, cannot do it through the pen.
 *
 *      A test that merely shows minting still works proves nothing, so there
 *      is not one of those here — the 920 tests already in the suite cover the
 *      unchanged path, and they still pass because an unwired pen is
 *      byte-for-byte today's behaviour.
 */
contract BullPenSnipeTest is BnbullsBase {
    BullPen internal pen;
    SnipeBot internal bot;

    /// @dev Bulls stocked into the pen by `_enablePen`.
    uint256 internal constant STOCK = 60;

    function setUp() public override {
        super.setUp();
        pen = new BullPen(address(bulls), owner, address(coord));
        pen.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        pen.bootstrapSeller(address(drop));
        bot = new SnipeBot(bulls, drop, pen);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev Stock the pen and switch MintDrop onto it. Deliberately NOT in
    ///      `setUp`, so the legacy-path tests run against the real live shape.
    function _enablePen(uint256 stock) internal {
        for (uint256 i = 0; i < stock; i++) {
            bulls.mint(address(pen));
        }
        drop.bootstrapPen(address(pen));
    }

    /// @dev The lowest legendary id at or after `from`, per the chain's own
    ///      table. This is the attacker's homework, and it is one call.
    function _nextLegendaryAtOrAfter(uint256 from) internal view returns (uint256) {
        for (uint256 i = from; i <= bulls.MAX_SUPPLY(); i++) {
            if (bulls.rarityOf(i) == 4) return i;
        }
        revert("no legendary left");
    }

    function _bnbFor1() internal view returns (uint256 due) {
        (, due,,) = drop.quote(1);
    }

    /// @dev Buy through the pen, seed the reservation from VRF, settle it.
    function _buyAndSettle(address who, uint256 word) internal returns (uint32[] memory ids) {
        uint256 rid = _buy(who);
        _seed(rid, word);
        pen.settle(rid);
        return pen.drawnIds(rid);
    }

    function _buy(address who) internal returns (uint256 reservationId) {
        return _buyTo(who, who);
    }

    /// @dev `payer` pays, `to` takes delivery. Split because the refund of the
    ///      BNB cushion goes to the PAYER, so a recipient that cannot accept
    ///      native must not be the one holding the wallet.
    function _buyTo(address payer, address to) internal returns (uint256 reservationId) {
        (, uint256 due,,) = drop.quote(1);
        vm.deal(payer, payer.balance + due * 2 + 1 ether);
        vm.prank(payer);
        drop.mintWithBNB{value: due * 2}(to, 1);
        return pen.nextReservationId() - 1;
    }

    /// @dev Deliver the VRF word for a reservation. The mock's request ids are
    ///      shared with the jackpots, so the reservation's own request id is
    ///      looked up rather than assumed.
    function _seed(uint256 reservationId, uint256 word) internal {
        uint256 reqId = _requestIdOf(reservationId);
        coord.fulfill(reqId, word);
    }

    function _requestIdOf(uint256 reservationId) internal view returns (uint256) {
        for (uint256 i = 1; i <= coord.nextRequestId(); i++) {
            if (pen.reservationOfRequest(i) == reservationId) return i;
        }
        revert("no vrf request for reservation");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  0. THE BUG, DEMONSTRATED. Everything else is measured against this.
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice An attacker who reads the public table mints a legendary on
     *         demand, for the price of one bull, with certainty.
     * @dev If this ever starts failing on the legacy path, the snipe was fixed
     *      somewhere else and this suite's premise needs re-reading.
     */
    function test_theSnipeWorksToday() public {
        uint256 target = _nextLegendaryAtOrAfter(bulls.nextTokenId());

        // Walk the counter up to the legendary, in legal 20-batches.
        while (bulls.nextTokenId() < target) {
            uint256 gap = target - bulls.nextTokenId();
            uint256 batch = gap > 20 ? 20 : gap;
            _mintBnb(alice, batch);
        }
        assertEq(bulls.nextTokenId(), target, "counter did not land on the legendary");

        uint256 due = _bnbFor1();
        vm.deal(address(bot), due * 2 + 1 ether);
        uint256 got = bot.snipeSequential(due * 2);

        assertEq(got, target, "the sniper did not get the id it aimed at");
        assertEq(bulls.rarityOf(got), 4, "the sniped bull is not legendary");
        assertEq(bulls.ownerOf(got), address(bot), "the sniper does not hold it");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. Same-transaction: there is nothing to see, so nothing to abort on
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Buying through the pen reveals NOTHING inside the buying
    ///         transaction: no id returned, no token received, no seed.
    function test_nothingAboutTheOutcomeIsVisibleInTheBuyingTransaction() public {
        _enablePen(STOCK);
        uint256 due = _bnbFor1();
        vm.deal(address(bot), due * 2 + 1 ether);

        (uint256 returnedIds, uint256 balanceAfter, bool anySeeded) = bot.mintAndInspect(due * 2);

        assertEq(returnedIds, 0, "an id came back and the abort is live again");
        assertEq(balanceAfter, 0, "a bull was delivered in the buying transaction");
        assertFalse(anySeeded, "a seed existed while the buyer could still revert");
    }

    /// @notice The free-abort attack: buy, and unwind unless it is a legendary.
    /// @dev It cannot even reach a decision — there is no id to branch on — so
    ///      it reverts every time, having bought nothing. On a naive
    ///      same-transaction randomisation this loop is how an attacker buys
    ///      legendaries for the price of gas.
    function test_abortOnUnfavourableOutcome_hasNothingToBranchOn() public {
        _enablePen(STOCK);
        uint256 due = _bnbFor1();

        for (uint256 attempt = 0; attempt < 10; attempt++) {
            vm.deal(address(bot), due * 2 + 1 ether);
            vm.expectRevert(SnipeBot.NoLegendary.selector);
            bot.mintOrRevert(due * 2);
            vm.roll(block.number + 1);
        }

        assertEq(bulls.balanceOf(address(bot)), 0, "the grinder acquired a bull");
        assertEq(pen.nextReservationId(), 1, "a reservation survived a reverted attempt");
        assertEq(drop.totalSold(), 0, "a reverted attempt was counted as a sale");
    }

    /// @notice Twenty buys inside one transaction, kept only if a legendary
    ///         appears. No path from payment to id exists in a single
    ///         transaction, so the run always unwinds.
    function test_grindingManyBuysInOneTransaction_cannotReachAnId() public {
        _enablePen(STOCK);
        uint256 due = _bnbFor1();
        vm.deal(address(bot), (due * 2 + 1 ether) * 25);

        vm.expectRevert(SnipeBot.NoLegendary.selector);
        bot.grindInOneTx(due * 2, 20);

        assertEq(bulls.balanceOf(address(bot)), 0, "the in-transaction grinder got a bull");
        assertEq(drop.totalSold(), 0, "sales survived the unwind");
    }

    /// @notice A reservation cannot be settled in the transaction that made it,
    ///         at any gas price, by anyone. This is the structural claim.
    function test_settleIsUnreachableUntilTheSeedArrives() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);

        vm.expectRevert(abi.encodeWithSelector(BullPen.NotSeededYet.selector, rid));
        pen.settle(rid);

        // Even after arbitrarily many blocks, without a word there is no draw.
        vm.roll(block.number + 5_000);
        vm.expectRevert(abi.encodeWithSelector(BullPen.NotSeededYet.selector, rid));
        pen.settle(rid);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. After the seed lands, reverting achieves nothing
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A settler who dislikes the draw and reverts hands the identical
    ///         ids to the next caller. Aborting buys nothing at all.
    function test_revertingASettlement_yieldsTheSameIdsToTheNextCaller() public {
        _enablePen(STOCK);
        uint256 rid = _buy(address(bot));
        _seed(rid, uint256(keccak256("word")));

        // The attacker unwinds because it is not a legendary...
        vm.expectRevert(SnipeBot.NoLegendary.selector);
        bot.settleOrRevert(rid);

        // ...and anybody settling afterwards, from another address, in another
        // block, draws exactly the same thing.
        vm.roll(block.number + 37);
        vm.prank(carol);
        pen.settle(rid);
        uint32[] memory ids = pen.drawnIds(rid);

        assertEq(ids.length, 1, "nothing was drawn");
        assertEq(bulls.ownerOf(ids[0]), address(bot), "the aborter still received the bull");
    }

    /// @notice The draw is a pure function of (seed, index, queue position). It
    ///         does not move with the caller, the block, or the timestamp.
    function test_theDrawDoesNotMoveWithCallerBlockOrTime() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);
        _seed(rid, uint256(keccak256("fixed")));

        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        pen.settle(rid);
        uint32[] memory first = pen.drawnIds(rid);

        vm.revertToState(snap);

        vm.roll(block.number + 999);
        vm.warp(block.timestamp + 30 days);
        vm.prank(address(bot));
        pen.settle(rid);
        uint32[] memory second = pen.drawnIds(rid);

        assertEq(first.length, second.length, "draw length moved");
        for (uint256 i = 0; i < first.length; i++) {
            assertEq(first[i], second[i], "the draw moved with caller/block/time");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. Ordering and stalling
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Settlement is strict FIFO, so nobody can shop for a pool
    ///         permutation by choosing whose reservation lands first.
    function test_settlementOrderCannotBeShopped() public {
        _enablePen(STOCK);
        uint256 r1 = _buy(alice);
        uint256 r2 = _buy(bob);
        _seed(r1, uint256(keccak256("a")));
        _seed(r2, uint256(keccak256("b")));

        vm.expectRevert(abi.encodeWithSelector(BullPen.NotNextToSettle.selector, r2, r1));
        pen.settle(r2);

        pen.settle(r1);
        pen.settle(r2);
        assertEq(pen.nextToSettle(), r2 + 1, "the queue did not advance");
    }

    /// @notice Sitting on a reservation you dislike does not reroll it, and it
    ///         cannot be overtaken while you sit on it.
    function test_stallingNeitherRerollsNorLetsAnyoneJumpTheQueue() public {
        _enablePen(STOCK);
        uint256 r1 = _buy(alice);
        uint256 r2 = _buy(bob);
        _seed(r1, uint256(keccak256("seed-1")));
        _seed(r2, uint256(keccak256("seed-2")));

        uint256 seedBefore = pen.reservationOf(r1).seed;

        vm.roll(block.number + 100_000);
        vm.warp(block.timestamp + 365 days);

        assertEq(pen.reservationOf(r1).seed, seedBefore, "the seed moved while stalling");
        // The stalled reservation still blocks the queue, so no pool state can
        // change underneath it.
        vm.expectRevert(abi.encodeWithSelector(BullPen.NotNextToSettle.selector, r2, r1));
        pen.settle(r2);
        assertEq(pen.poolSize(), STOCK, "the pool moved while a reservation stalled");
    }

    /// @notice A second VRF word for a live reservation is dropped, not
    ///         applied. Re-seeding would be a reroll.
    function test_aSecondVrfWordCannotRerollAReservation() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);
        uint256 reqId = _requestIdOf(rid);

        coord.fulfill(reqId, 111);
        uint256 seedAfterFirst = pen.reservationOf(rid).seed;

        coord.fulfill(reqId, 222);
        assertEq(pen.reservationOf(rid).seed, seedAfterFirst, "a second word rerolled the draw");
    }

    /// @notice A word from an untrusted coordinator is refused even if
    ///         `s_vrfCoordinator` has been repointed, because the check is
    ///         against the TIMELOCKED slot.
    function test_wordFromAnUntrustedCoordinatorIsRefused() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);
        uint256 reqId = _requestIdOf(rid);

        // The owner repoints the base pointer with no timelock — the exact
        // hole `JackpotNoWithdraw.t.sol` records.
        pen.setCoordinator(address(this));

        uint256[] memory words = new uint256[](1);
        words[0] = 999;
        vm.expectRevert(
            abi.encodeWithSelector(BullPen.UntrustedCoordinator.selector, address(this))
        );
        pen.rawFulfillRandomWords(reqId, words);

        assertFalse(pen.reservationOf(rid).seeded, "a hand-picked word was accepted");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. The pool is a real permutation, and the odds are the honest ones
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Draining the pen deals every stocked id exactly once — no
    ///         duplicates, no losses, no id that was never in the pen.
    function test_drainingThePenDealsEveryIdExactlyOnce() public {
        _enablePen(STOCK);
        uint256 firstStocked = bulls.nextTokenId() - STOCK;

        bool[] memory seen = new bool[](STOCK);
        for (uint256 i = 0; i < STOCK; i++) {
            uint32[] memory ids = _buyAndSettle(alice, uint256(keccak256(abi.encode("drain", i))));
            assertEq(ids.length, 1, "a settlement drew the wrong count");
            uint256 offset = uint256(ids[0]) - firstStocked;
            assertLt(offset, STOCK, "an id came out that was never stocked");
            assertFalse(seen[offset], "the same id was dealt twice");
            seen[offset] = true;
            assertEq(bulls.ownerOf(ids[0]), alice, "the buyer did not receive it");
        }

        assertEq(pen.poolSize(), 0, "the pen is not empty");
        assertEq(pen.sellable(), 0, "the pen still claims stock");
    }

    /// @notice The tier mix a buyer faces is exactly the mix left in the pen —
    ///         which is what makes the published odds true.
    function test_theDealtTierMixIsExactlyThePoolsTierMix() public {
        _enablePen(STOCK);
        uint256 firstStocked = bulls.nextTokenId() - STOCK;

        uint256[6] memory expected;
        for (uint256 i = 0; i < STOCK; i++) {
            expected[bulls.rarityOf(firstStocked + i)] += 1;
        }

        uint256[6] memory dealt;
        for (uint256 i = 0; i < STOCK; i++) {
            uint32[] memory ids = _buyAndSettle(bob, uint256(keccak256(abi.encode("mix", i))));
            dealt[bulls.rarityOf(ids[0])] += 1;
        }

        for (uint8 t = 0; t < 6; t++) {
            assertEq(dealt[t], expected[t], "the dealt tier mix does not match the pool");
        }
    }

    /// @notice Different seeds deal different bulls. (A draw that ignored its
    ///         seed would pass every uniqueness test above and still be a
    ///         sequential handout.)
    function test_differentSeedsDealDifferentBulls() public {
        _enablePen(STOCK);

        uint256 snap = vm.snapshotState();
        uint32[] memory a = _buyAndSettle(alice, uint256(keccak256("alpha")));
        vm.revertToState(snap);
        uint32[] memory b = _buyAndSettle(alice, uint256(keccak256("beta")));

        assertTrue(a[0] != b[0], "the seed made no difference to the draw");
    }

    /// @notice A 20-bull batch draws 20 DISTINCT bulls from across the pool,
    ///         not a sequential run.
    function test_aBatchDrawsDistinctBullsNotASequentialRun() public {
        _enablePen(STOCK);
        (, uint256 due,,) = drop.quote(20);
        vm.deal(alice, due * 2 + 1 ether);
        vm.prank(alice);
        drop.mintWithBNB{value: due * 2}(alice, 20);

        uint256 rid = pen.nextReservationId() - 1;
        _seed(rid, uint256(keccak256("batch")));
        pen.settle(rid);

        uint32[] memory ids = pen.drawnIds(rid);
        assertEq(ids.length, 20, "the batch did not draw 20");

        bool sequential = true;
        for (uint256 i = 1; i < ids.length; i++) {
            if (ids[i] != ids[i - 1] + 1) sequential = false;
            for (uint256 j = 0; j < i; j++) {
                assertTrue(ids[i] != ids[j], "a batch dealt the same bull twice");
            }
        }
        assertFalse(sequential, "the batch came out as a sequential run");
        assertEq(bulls.balanceOf(alice), 20, "the batch was not delivered");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. The hard requirement: nobody already holding a bull is disturbed
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Bulls minted before the pen existed keep their id, their owner
     *         and their exact rarity, and the fairness commitment does not
     *         move.
     * @dev This is the requirement the design is built around: the pen changes
     *      WHICH id you receive, never what an id MEANS. `_rarity` is never
     *      written, so `initialRarityHash` cannot move.
     */
    function test_alreadyMintedBullsKeepEverythingTheyHaveToday() public {
        _mintBnb(alice, 5);

        uint8[] memory tiersBefore = new uint8[](5);
        for (uint256 i = 1; i <= 5; i++) {
            tiersBefore[i - 1] = bulls.rarityOf(i);
            assertEq(bulls.ownerOf(i), alice);
        }
        bytes32 hashBefore = bulls.initialRarityHash();

        _enablePen(STOCK);
        for (uint256 i = 0; i < 10; i++) {
            _buyAndSettle(bob, uint256(keccak256(abi.encode("after", i))));
        }

        for (uint256 i = 1; i <= 5; i++) {
            assertEq(bulls.rarityOf(i), tiersBefore[i - 1], "an existing bull's rarity moved");
            assertEq(bulls.ownerOf(i), alice, "an existing bull changed hands");
        }
        assertEq(bulls.initialRarityHash(), hashBefore, "the commitment moved");
        assertEq(bulls.rarityHash(), bulls.initialRarityHash(), "the live table diverged");
    }

    /// @notice The pen only ever deals ids it was actually stocked with, so a
    ///         bull somebody already owns can never be handed out again.
    function test_thePenCannotDealABullSomebodyAlreadyOwns() public {
        _mintBnb(alice, 5);
        _enablePen(STOCK);

        for (uint256 i = 0; i < 12; i++) {
            uint32[] memory ids = _buyAndSettle(bob, uint256(keccak256(abi.encode("no-steal", i))));
            assertGt(ids[0], 5, "the pen dealt a bull alice already owned");
        }
        for (uint256 i = 1; i <= 5; i++) {
            assertEq(bulls.ownerOf(i), alice);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. Liveness and access control
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Only the wired seller may reserve. The pen is not a free mint.
    function test_onlyTheWiredSellerCanReserve() public {
        _enablePen(STOCK);
        vm.expectRevert(BullPen.NotSeller.selector);
        vm.prank(alice);
        pen.reserve(alice, 1);

        vm.expectRevert(BullPen.NotSeller.selector);
        pen.reserve(owner, 1); // not even the owner
    }

    /// @notice Open reservations are counted, so the pen cannot promise the
    ///         same bull twice.
    function test_openReservationsCannotOversellThePool() public {
        _enablePen(3);
        _buy(alice);
        _buy(bob);
        _buy(carol);
        assertEq(pen.sellable(), 0, "the pen still thinks it has stock");

        (, uint256 due,,) = drop.quote(1);
        vm.deal(alice, due * 2 + 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BullPen.PoolTooSmall.selector, 1, 0));
        drop.mintWithBNB{value: due * 2}(alice, 1);
    }

    /// @notice A recipient that refuses delivery breaks only its own delivery.
    ///         The queue keeps moving and the bull stays claimable.
    function test_aHostileRecipientCannotWedgeTheQueue() public {
        _enablePen(STOCK);
        HostileReceiver hostile = new HostileReceiver();

        uint256 r1 = _buyTo(alice, address(hostile));
        uint256 r2 = _buy(bob);
        _seed(r1, uint256(keccak256("h1")));
        _seed(r2, uint256(keccak256("h2")));

        pen.settle(r1);
        uint32[] memory stuck = pen.drawnIds(r1);
        assertEq(pen.unclaimedOwner(stuck[0]), address(hostile), "the token was not parked");
        assertEq(bulls.ownerOf(stuck[0]), address(pen), "the token left the pen anyway");

        // The queue is NOT wedged.
        pen.settle(r2);
        assertEq(bulls.balanceOf(bob), 1, "the next buyer was blocked by the hostile one");

        // And the parked bull is still theirs once they behave.
        hostile.stopRefusing();
        pen.claim(stuck[0]);
        assertEq(bulls.ownerOf(stuck[0]), address(hostile), "the claim did not deliver");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  7. The blockhash fallback — the degraded path behind VRF
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The fallback cannot be armed while VRF is still within its
    ///         window, and cannot be pinned before its block exists.
    function test_theFallbackCannotBeArmedEarlyOrPinnedEarly() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                BullPen.VrfTimeoutNotElapsed.selector, uint64(block.number), pen.vrfTimeoutBlocks()
            )
        );
        pen.armFallback(rid);

        vm.expectRevert(abi.encodeWithSelector(BullPen.FallbackNotArmed.selector, rid));
        pen.pinFallbackSeed(rid);

        vm.roll(block.number + pen.vrfTimeoutBlocks());
        pen.armFallback(rid);

        uint64 target = pen.reservationOf(rid).fallbackBlock;
        assertGt(target, block.number, "the fallback block already existed when armed");

        vm.expectRevert(abi.encodeWithSelector(BullPen.FallbackNotReady.selector, target));
        pen.pinFallbackSeed(rid);
    }

    /// @notice The whole point of the two-step: whoever arms the fallback
    ///         cannot see the value they are arming, because the block has not
    ///         happened. The pinner has no choice either — the seed is fixed
    ///         by the armed block's hash.
    function test_theFallbackSeedIsFixedByTheArmedBlockNotByWhoPinsIt() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);
        vm.roll(block.number + pen.vrfTimeoutBlocks());
        pen.armFallback(rid);
        uint64 target = pen.reservationOf(rid).fallbackBlock;

        vm.roll(uint256(target) + 1);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        pen.pinFallbackSeed(rid);
        uint256 seedA = pen.reservationOf(rid).seed;

        vm.revertToState(snap);
        vm.roll(uint256(target) + 40);
        vm.prank(address(bot));
        pen.pinFallbackSeed(rid);
        uint256 seedB = pen.reservationOf(rid).seed;

        assertEq(seedA, seedB, "the fallback seed moved with the pinner");
    }

    /// @notice VRF down: the fallback still delivers a bull, and the reservation
    ///         cannot then be re-seeded.
    function test_theFallbackStillDeliversAndCannotBeReseeded() public {
        _enablePen(STOCK);
        uint256 rid = _buy(alice);
        uint256 reqId = _requestIdOf(rid);

        vm.roll(block.number + pen.vrfTimeoutBlocks());
        pen.armFallback(rid);
        vm.roll(uint256(pen.reservationOf(rid).fallbackBlock) + 1);
        pen.pinFallbackSeed(rid);

        uint256 seed = pen.reservationOf(rid).seed;
        // A late VRF word must not overwrite a pinned fallback.
        coord.fulfill(reqId, 12345);
        assertEq(pen.reservationOf(rid).seed, seed, "a late VRF word rerolled a pinned fallback");

        pen.settle(rid);
        assertEq(bulls.balanceOf(alice), 1, "the fallback did not deliver");
    }

    /// @notice Stray bulls cannot be pushed into the drop by a third party.
    function test_aThirdPartyCannotStockThePen() public {
        _enablePen(STOCK);
        uint32[] memory ids = _buyAndSettle(alice, uint256(keccak256("stray")));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BullPen.NotStockable.selector, alice));
        bulls.safeTransferFrom(alice, address(pen), ids[0]);
    }
}
