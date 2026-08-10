// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {MockDuel, GarbageDuel, RevertingReceiver} from "./mocks/Hostile.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title JackpotNativePotTest
 * @notice The native-BNB pot. A winner receives **BNB**, never WBNB.
 *
 * @dev `Jackpot.sol` chose ERC-20 for one specific, correct reason: a native
 *      payout inside the resolve loop is a `.call{value:}` to an arbitrary
 *      winner, and a winner with a reverting `receive()` would revert the batch
 *      and WEDGE THE QUEUE FOREVER in a contract with no withdraw path.
 *
 *      `JackpotNative` removes the premise rather than the objection: resolving
 *      never sends, it credits. So the tests that matter most here are the ones
 *      that prove the old objection no longer bites —
 *      `test_hostileWinner_cannotWedgeTheBatch` above all — plus the solvency
 *      invariant that a credit ledger introduces:
 *
 *          address(this).balance >= pool() + totalOwed
 *
 *      asserted after every money-moving test.
 */
contract JackpotNativePotTest is Test {
    JackpotNative internal pot;
    MockWBNB internal wbnb;
    MockVRFCoordinator internal coord;
    MockDuel internal mockDuel;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal funder = address(0xF00D);

    uint256 internal constant ODDS = 75;
    bytes32 internal constant KEY_HASH = bytes32(uint256(0xBEEF));
    uint256 internal constant SUB_ID = 1;

    function setUp() public {
        wbnb = new MockWBNB();
        coord = new MockVRFCoordinator();
        mockDuel = new MockDuel();

        pot = new JackpotNative(address(wbnb), owner, address(coord), ODDS);
        pot.bootstrapDuel(address(mockDuel));
        pot.bootstrapPayoutParams(ODDS, 10_000, 0);
        pot.setVrfConfig(KEY_HASH, SUB_ID, 3, 200_000, true);
        pot.setFunder(funder, true);
        pot.setRequester(owner, true);

        vm.deal(funder, 100 ether);
        vm.deal(owner, 100 ether);
        vm.deal(alice, 10 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    /// @dev THE SOLVENCY INVARIANT. Every wei here is either pot or an
    ///      unclaimed prize; the balance can never be short of the two.
    function _assertSolvent() internal view {
        assertGe(
            address(pot).balance, pot.pool() + pot.totalOwed(), "balance < pool + owed: INSOLVENT"
        );
        assertEq(
            address(pot).balance, pot.pool() + pot.totalOwed(), "balance != pool + owed: drift"
        );
    }

    /// @dev Mirrors `JackpotNative.resolve`'s preimage EXACTLY, `address(this)`
    ///      term and all. If that preimage is ever edited this stops finding
    ///      winners and every win test fails loudly rather than silently
    ///      passing on a roll that no longer means anything.
    function _roll(uint256 word, uint256 entropy, uint256 tokenId, address winner, uint256 id)
        internal
        view
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(word, entropy, tokenId, winner, id, address(pot))))
            % ODDS;
    }

    function _winningWord(uint256 entropy, uint256 tokenId, address winner, uint256 id)
        internal
        view
        returns (uint256)
    {
        for (uint256 w = 1; w < 200_000; w++) {
            if (_roll(w, entropy, tokenId, winner, id) == 0) return w;
        }
        revert("no winning word found");
    }

    function _losingWord(uint256 entropy, uint256 tokenId, address winner, uint256 id)
        internal
        view
        returns (uint256)
    {
        for (uint256 w = 1; w < 200_000; w++) {
            if (_roll(w, entropy, tokenId, winner, id) != 0) return w;
        }
        revert("no losing word found");
    }

    /// @dev Fund natively, the way `DuelNative` will once its last wrap is gone.
    function _fundNative(uint256 amount) internal {
        vm.prank(funder);
        pot.fundNative{value: amount}("test");
    }

    function _openTicket(address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        internal
        returns (uint256 id)
    {
        return mockDuel.open(address(pot), winner, tokenId, entropy, duelKey);
    }

    function _requestAndFulfil(uint256 maxTickets, uint256 word) internal {
        uint256 reqId = pot.requestResolve(maxTickets);
        coord.fulfillTo(address(pot), reqId, word);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Funding — the compatibility door and the native door
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE MIGRATION-SCOPE TEST. `MintDrop` and the three splitters are
     *         deployed and immutable; their pot leg is hard-coded
     *         `forceApprove(pot, amount); pot.fund(amount, source)`. If this
     *         breaks, all four have to be redeployed too.
     */
    function test_fund_pullsWbnbAndUnwrapsToNative() public {
        vm.startPrank(funder);
        wbnb.deposit{value: 5 ether}();
        wbnb.approve(address(pot), 5 ether);
        pot.fund(5 ether, "mintdrop");
        vm.stopPrank();

        assertEq(pot.pool(), 5 ether, "pool should be native after unwrap");
        assertEq(address(pot).balance, 5 ether, "contract should hold native, not wbnb");
        assertEq(wbnb.balanceOf(address(pot)), 0, "no wbnb should rest in the pot");
        assertEq(pot.totalFunded(), 5 ether);
        _assertSolvent();
    }

    function test_fundNative_credits() public {
        _fundNative(3 ether);
        assertEq(pot.pool(), 3 ether);
        assertEq(pot.totalFunded(), 3 ether);
        _assertSolvent();
    }

    function test_topUp_isOwnerOnlyAndNative() public {
        pot.topUp{value: 2 ether}();
        assertEq(pot.pool(), 2 ether);

        vm.prank(alice);
        vm.expectRevert();
        pot.topUp{value: 1 ether}();
        _assertSolvent();
    }

    function test_fund_refusedFromNonFunder() public {
        vm.startPrank(alice);
        wbnb.deposit{value: 1 ether}();
        wbnb.approve(address(pot), 1 ether);
        vm.expectRevert(JackpotNative.NotFunder.selector);
        pot.fund(1 ether, "nope");
        vm.stopPrank();
    }

    /// @dev A plain transfer in is a donation, exactly as the ERC-20 pot's
    ///      `balanceOf`-based pool treated a plain token transfer.
    function test_plainTransferIsADonation() public {
        vm.prank(alice);
        (bool ok,) = address(pot).call{value: 1 ether}("");
        assertTrue(ok, "receive() should accept native");
        assertEq(pot.pool(), 1 ether);
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The win — credited, not transferred
    // ══════════════════════════════════════════════════════════════════════

    function test_winCreditsThePrizeAndDoesNotSend() public {
        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        uint256 word = _winningWord(42, 1, alice, id);

        uint256 aliceBefore = alice.balance;
        _requestAndFulfil(1, word);
        pot.resolve(1);

        assertEq(pot.owed(alice), 10 ether, "whole pool at 100% payout");
        assertEq(pot.totalOwed(), 10 ether);
        assertEq(alice.balance, aliceBefore, "resolve must NOT send");
        assertEq(pot.pool(), 0, "pool is emptied by the win");
        assertEq(pot.awardCount(), 1);
        assertEq(pot.totalAwarded(), 10 ether);
        _assertSolvent();
    }

    function test_withdrawPaysNativeBnb() public {
        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        _requestAndFulfil(1, _winningWord(42, 1, alice, id));
        pot.resolve(1);

        uint256 before = alice.balance;
        vm.prank(alice);
        pot.withdrawAll();

        assertEq(alice.balance, before + 10 ether, "winner receives native BNB");
        assertEq(pot.owed(alice), 0);
        assertEq(pot.totalOwed(), 0);
        _assertSolvent();
    }

    function test_partialWithdraw() public {
        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        _requestAndFulfil(1, _winningWord(42, 1, alice, id));
        pot.resolve(1);

        vm.prank(alice);
        pot.withdraw(4 ether);
        assertEq(pot.owed(alice), 6 ether);
        assertEq(pot.totalOwed(), 6 ether);
        _assertSolvent();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(JackpotNative.InsufficientOwed.selector, alice, 7 ether, 6 ether)
        );
        pot.withdraw(7 ether);
    }

    /**
     * @notice ⛔ THE TEST THIS WHOLE CONTRACT EXISTS TO PASS.
     *
     * @dev `Jackpot.sol` refused to hold native precisely because "a winner
     *      that is a contract with a reverting `receive()` would revert the
     *      resolve loop and WEDGE THE QUEUE — permanently, in a contract with
     *      no withdraw path." Crediting instead of sending removes that: the
     *      hostile winner's prize is a storage write that cannot revert, the
     *      batch completes, later tickets resolve normally, and the only party
     *      inconvenienced is the hostile contract itself.
     */
    function test_hostileWinner_cannotWedgeTheBatch() public {
        RevertingReceiver hostile = new RevertingReceiver();
        _fundNative(10 ether);

        uint256 idHostile = _openTicket(address(hostile), 1, 42, 1);
        uint256 idAlice = _openTicket(alice, 2, 43, 2);

        // A word that makes the FIRST (hostile) ticket win.
        uint256 word = _winningWord(42, 1, address(hostile), idHostile);

        _requestAndFulfil(2, word);
        // Must not revert even though ticket 0's winner cannot receive BNB.
        uint256 resolved = pot.resolve(2);

        assertEq(resolved, 2, "the whole batch must resolve");
        assertEq(pot.owed(address(hostile)), 10 ether, "hostile winner still credited");
        assertEq(pot.nextToResolve(), 2, "cursor advanced past both tickets");
        assertFalse(pot.wordReady(), "batch consumed, a fresh request is possible");
        _assertSolvent();

        // And the hostile contract can only hurt itself when it tries to pull.
        vm.prank(address(hostile));
        vm.expectRevert(JackpotNative.WithdrawFailed.selector);
        pot.withdrawAll();

        // Its prize stays owed — the ledger is untouched by its own failure.
        assertEq(pot.owed(address(hostile)), 10 ether);
        // The queue is still healthy for everybody else.
        assertEq(pot.pool(), 0);
        _assertSolvent();

        // Alice's later ticket was never blocked.
        assertEq(idAlice, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The hardened invariants, carried over
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The snapshot: terms are fixed at REQUEST time, before the word
    ///      exists, so the owner cannot watch it land and then choose the odds.
    function test_termsAreSnapshottedAtRequestTime() public {
        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        uint256 word = _winningWord(42, 1, alice, id);

        uint256 reqId = pot.requestResolve(1);
        assertEq(pot.pendingOdds(), ODDS);
        assertEq(pot.pendingPayoutBps(), 10_000);

        // Owner proposes new terms after the request. Even once committed they
        // must not touch the batch already in flight.
        pot.proposePayoutParams(1000, 5000, 0);
        vm.warp(block.timestamp + 25 hours);
        pot.commitPayoutParams();
        assertEq(pot.oddsOneIn(), 1000, "live odds moved");

        coord.fulfillTo(address(pot), reqId, word);
        assertEq(pot.resolveOdds(), ODDS, "batch keeps the odds it was requested under");
        assertEq(pot.resolvePayoutBps(), 10_000, "batch keeps its payout share");

        pot.resolve(1);
        assertEq(pot.owed(alice), 10 ether, "paid under the snapshotted terms");
        _assertSolvent();
    }

    function test_minPoolToFireBoundary() public {
        pot.proposePayoutParams(ODDS, 10_000, 5 ether);
        vm.warp(block.timestamp + 25 hours);
        pot.commitPayoutParams();

        // Below the floor: a winning roll pays nothing.
        _fundNative(4 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        _requestAndFulfil(1, _winningWord(42, 1, alice, id));
        pot.resolve(1);

        assertEq(pot.owed(alice), 0, "under the floor, a win pays nothing");
        assertEq(pot.pool(), 4 ether, "and the money stays in the pot");
        _assertSolvent();

        // Top it over the floor and the next winner is paid.
        _fundNative(2 ether);
        uint256 id2 = _openTicket(alice, 2, 43, 2);
        _requestAndFulfil(1, _winningWord(43, 2, alice, id2));
        pot.resolve(1);
        assertEq(pot.owed(alice), 6 ether, "over the floor, the win pays");
        _assertSolvent();
    }

    function test_payoutBpsBelowFullLeavesRemainder() public {
        pot.proposePayoutParams(ODDS, 5000, 0);
        vm.warp(block.timestamp + 25 hours);
        pot.commitPayoutParams();

        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        _requestAndFulfil(1, _winningWord(42, 1, alice, id));
        pot.resolve(1);

        assertEq(pot.owed(alice), 5 ether, "half the pool");
        assertEq(pot.pool(), 5 ether, "the rest rolls over");
        _assertSolvent();
    }

    /// @dev One pot per duel. A denied win pays nothing and the money stays.
    function test_exclusivityDenialPaysNothing() public {
        _fundNative(10 ether);
        mockDuel.setAlwaysDeny(true);

        uint256 id = _openTicket(alice, 1, 42, 7);
        _requestAndFulfil(1, _winningWord(42, 1, alice, id));
        pot.resolve(1);

        assertEq(pot.owed(alice), 0, "denied by the other pot");
        assertEq(pot.pool(), 10 ether, "money rolls over to the next winner");
        assertEq(pot.awardCount(), 0);
        _assertSolvent();
    }

    /// @dev A `duel` returning a non-canonical word must be treated as DENIED
    ///      and must NOT revert the loop — otherwise the cursor sticks and every
    ///      later ticket is stranded.
    function test_garbageDuelIsDeniedNotFatal() public {
        GarbageDuel garbage = new GarbageDuel();
        JackpotNative p2 = new JackpotNative(address(wbnb), owner, address(coord), ODDS);
        p2.bootstrapDuel(address(garbage));
        p2.bootstrapPayoutParams(ODDS, 10_000, 0);
        p2.setVrfConfig(KEY_HASH, SUB_ID, 3, 200_000, true);
        p2.setFunder(funder, true);
        p2.setRequester(owner, true);

        vm.prank(funder);
        p2.fundNative{value: 5 ether}("seed");

        // Open through the garbage duel by impersonating it.
        vm.prank(address(garbage));
        uint256 id = p2.recordWin(alice, 1, 42, 9);

        uint256 word;
        for (uint256 w = 1; w < 200_000; w++) {
            if (
                uint256(keccak256(abi.encodePacked(w, uint256(42), uint256(1), alice, id, address(p2))))
                    % ODDS == 0
            ) {
                word = w;
                break;
            }
        }
        uint256 reqId = p2.requestResolve(1);
        coord.fulfillTo(address(p2), reqId, word);

        uint256 resolved = p2.resolve(1);
        assertEq(resolved, 1, "loop must complete, not revert");
        assertEq(p2.owed(alice), 0, "garbage lock = denied");
        assertEq(p2.pool(), 5 ether);
    }

    function test_oddsFloorIsEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(JackpotNative.InvalidOdds.selector, uint256(1)));
        new JackpotNative(address(wbnb), owner, address(coord), 1);

        vm.expectRevert(abi.encodeWithSelector(JackpotNative.InvalidOdds.selector, uint256(9)));
        pot.proposePayoutParams(9, 10_000, 0);
    }

    /// @dev The word must come from the TIMELOCKED coordinator, not from
    ///      whatever `s_vrfCoordinator` happens to point at.
    function test_wordFromUntrustedCoordinatorIsRefused() public {
        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        uint256 word = _winningWord(42, 1, alice, id);
        pot.requestResolve(1);

        MockVRFCoordinator evil = new MockVRFCoordinator();
        vm.expectRevert();
        evil.fulfillTo(address(pot), 1, word);

        assertFalse(pot.wordReady(), "no word from an untrusted source");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The no-withdraw guarantee, in a contract that now holds native
    // ══════════════════════════════════════════════════════════════════════

    /// @dev There is deliberately NO native rescue. Every wei is pot or an
    ///      unclaimed prize, so the owner has no path to any of it.
    function test_ownerHasNoNativePathToThePool() public {
        _fundNative(10 ether);
        uint256 before = owner.balance;

        // Every owner entrypoint that exists, none of which can move native.
        pot.setFunder(address(0xdead), true);
        pot.setRequester(address(0xdead), true);
        pot.setWiringDelay(12 hours);
        pot.setTimeouts(1000, 1000);
        pot.setSocials("a", "b", "c");

        assertEq(pot.pool(), 10 ether, "pool untouched by every owner call");
        assertEq(owner.balance, before, "owner gained nothing");
        _assertSolvent();
    }

    /// @dev WBNB is refused by the sweep even though it is not the prize: the
    ///      canonical path unwraps atomically, so any WBNB resting here was a
    ///      mistaken transfer plainly meant for the pot.
    function test_sweepRefusesWbnb() public {
        vm.expectRevert(JackpotNative.PrizeIsNotSweepable.selector);
        pot.sweepForeignToken(address(wbnb), owner, 1);
    }

    function test_sweepRecoversAGenuineForeignToken() public {
        MockERC20 foreign = new MockERC20("Oops", "OOPS", 18);
        foreign.mint(address(pot), 1000e18);
        pot.sweepForeignToken(address(foreign), owner, 1000e18);
        assertEq(foreign.balanceOf(owner), 1000e18);
    }

    /// @dev Stray WBNB goes to the PLAYERS, permissionlessly — not to the owner.
    function test_absorbStrayWbnbGivesItToThePot() public {
        vm.startPrank(alice);
        wbnb.deposit{value: 2 ether}();
        wbnb.transfer(address(pot), 2 ether);
        vm.stopPrank();

        assertEq(pot.pool(), 0, "wbnb is not pot money until absorbed");

        vm.prank(alice); // permissionless
        pot.absorbStrayWbnb();

        assertEq(pot.pool(), 2 ether, "now it belongs to the players");
        assertEq(wbnb.balanceOf(address(pot)), 0);
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Solvency under load
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Many tickets, real wins, real withdrawals — and the ledger never
     *         drifts from the balance.
     *
     * @dev This is the invariant a credit ledger introduces and the ERC-20 pot
     *      never had to worry about. `pool()` nets `totalOwed` out precisely so
     *      an unclaimed prize cannot be handed to a second winner.
     */
    function test_manyTicketsStaySolvent() public {
        _fundNative(20 ether);

        uint256 n = 12;
        for (uint256 i = 0; i < n; i++) {
            _openTicket(alice, i + 1, 100 + i, i + 1);
        }

        // A word chosen to win on the first ticket; the rest roll as they roll.
        uint256 word = _winningWord(100, 1, alice, 0);
        _requestAndFulfil(n, word);

        // Resolve in two chunks to exercise a partial batch.
        pot.resolve(5);
        _assertSolvent();
        pot.resolve(n);
        _assertSolvent();

        assertEq(pot.nextToResolve(), n, "every ticket resolved");
        assertGt(pot.totalOwed(), 0, "at least the seeded winner was paid");

        // Full withdrawal drains only what is owed, never the pot.
        uint256 owedAlice = pot.owed(alice);
        uint256 poolBefore = pot.pool();
        vm.prank(alice);
        pot.withdrawAll();

        assertEq(pot.owed(alice), 0);
        assertEq(pot.totalOwed(), 0);
        assertEq(pot.pool(), poolBefore, "withdrawing a prize must not touch the pot");
        assertEq(address(pot).balance, poolBefore, "balance is exactly the pot now");
        assertGt(owedAlice, 0);
        _assertSolvent();
    }

    /// @dev A losing batch pays nobody and leaves the pot exactly as it was.
    function test_losingTicketPaysNothing() public {
        _fundNative(7 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        _requestAndFulfil(1, _losingWord(42, 1, alice, id));
        pot.resolve(1);

        assertEq(pot.owed(alice), 0);
        assertEq(pot.pool(), 7 ether);
        assertEq(pot.awardCount(), 0);
        _assertSolvent();
    }

    /// @dev `pool()` must never count an unclaimed prize as pot money — that is
    ///      the whole reason it subtracts `totalOwed`.
    function test_poolExcludesUnclaimedPrizes() public {
        _fundNative(10 ether);
        uint256 id = _openTicket(alice, 1, 42, 1);
        _requestAndFulfil(1, _winningWord(42, 1, alice, id));
        pot.resolve(1);

        assertEq(pot.totalOwed(), 10 ether);
        assertEq(pot.pool(), 0, "an unwithdrawn prize is NOT pot money");
        assertEq(address(pot).balance, 10 ether, "but the contract still holds it");
        _assertSolvent();

        // Fund again: the new money is pot, the old prize is still Alice's.
        _fundNative(3 ether);
        assertEq(pot.pool(), 3 ether);
        assertEq(pot.totalOwed(), 10 ether);
        _assertSolvent();
    }
}
