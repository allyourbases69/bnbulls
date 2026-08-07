// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {BNBull} from "../contracts/BNBull.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Duel} from "../contracts/Duel.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {DuelRecordingJackpot} from "./mocks/DuelMocks.sol";

/**
 * @title JackpotQueueWedgeTest
 * @notice 🔴 THE WEDGE, EXECUTED — a winning ticket against a prize token that
 *         will not move, and the silence that used to follow it.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT HAPPENED ON CHAIN 97
 *      ══════════════════════════════════════════════════════════════════════
 *      `BNBull` ships `tradingEnabled = false` and whitelists only the initial
 *      owner and holder. That is the LAUNCH STATE, not a mistake:
 *      `DECISIONS.md §29` opens BNB first and BNBULL only after four.meme's
 *      curve completes. Nothing in the real deploy path whitelisted the game —
 *      `setWhitelist` was called by the anvil rehearsal and nowhere else — so
 *      the BNBULL pot was locked out of its own prize token.
 *
 *      The first ticket to WIN then reverted `TradingNotEnabled` inside
 *      `prizeToken.safeTransfer`. `Duel._resolveOnly` swallowed it, exactly as
 *      it must (a pot fault may never revert a fight), and `Jackpot.resolve`'s
 *      cursor rolled back with it — so the SAME ticket was retried, and
 *      failed, on every duel afterwards. **77 tickets piled up behind it.**
 *      No player transaction reverted. Nothing was logged. Every dashboard
 *      read healthy.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT IS UNDER TEST, AND WHAT IS DELIBERATELY NOT
 *      ══════════════════════════════════════════════════════════════════════
 *      NOT the whitelist. The whitelist is one cause; a blacklisted winner, a
 *      paused prize token or an outright bug in `resolve` produce the
 *      identical, equally invisible stall. What is under test is that the
 *      stall is **OBSERVABLE** — `Duel.JackpotResolveFailed` carries the pot
 *      and the revert selector, so a keeper or an alert bot can see the wedge
 *      the same block it starts, instead of nobody seeing it at all.
 *
 *      The try/catch STAYS, and these tests assert that too: every fight in
 *      this file settles normally while the queue is jammed.
 *
 *      ⚠ REAL CONTRACTS, NOT STUBS. A stub that reverts on `resolve` would
 *      prove the event fires and nothing about the defect. This uses the real
 *      `BNBull` in its real launch state, the real `Jackpot`, the real `Duel`
 *      and a real VRF word chosen so the ticket genuinely wins.
 */
contract JackpotQueueWedgeTest is DuelGraveyardBase {
    /// @notice The prize token, in the state it actually ships in: trading
    ///         closed, and only the deployer whitelisted.
    BNBull internal gate;
    /// @notice A BNBULL pot whose prize token is that gated `BNBull`.
    Jackpot internal gatedPot;
    /// @notice The other pool, so "both pots were nudged" stays visible.
    DuelRecordingJackpot internal otherPot;

    Bulls internal b;
    Duel internal d;

    uint256 internal winnerBull;
    uint256 internal loserBull;
    /// @notice The duel whose winner holds the wedging ticket.
    uint256 internal duelKey;
    /// @notice A VRF word that makes ticket 0 a winner.
    uint256 internal winningWord;

    uint256 internal constant POT_SIZE = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        // The token exactly as `Deploy` builds it: deployer is both the
        // initial owner and the initial holder, and nothing else is listed.
        gate = new BNBull(address(this), address(this), 1_000_000_000e18);
        assertFalse(gate.tradingEnabled(), "harness: the launch gate must start SHUT");

        gatedPot = new Jackpot(address(gate), address(0), address(coord), 50);
        otherPot = new DuelRecordingJackpot();

        b = new Bulls(owner, SEED, bytes32(0));
        d = _newDuel(address(b));
        b.bootstrapWire(Bulls.Wire.Duel, address(d));
        d.bootstrapWire(Duel.Wire.JackpotBnbull, address(gatedPot));
        d.bootstrapWire(Duel.Wire.JackpotBnb, address(otherPot));
        gatedPot.bootstrapDuel(address(d));
        gatedPot.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);

        // Funding the pot WORKS while the gate is shut, and that is what makes
        // the defect so quiet: the deployer is whitelisted, so money flows IN
        // all day. Only the payout — the one transfer with a non-whitelisted
        // sender — is refused.
        gate.approve(address(gatedPot), type(uint256).max);
        gatedPot.topUp(POT_SIZE);
        assertEq(gatedPot.pool(), POT_SIZE, "harness: the pot did not fund");

        winnerBull = b.mint(alice);
        loserBull = b.mint(bob);

        // One decisive, STAKED fight (`DECISIONS.md §25`: a ticket is earned by
        // funding the pot), then a VRF word chosen so its ticket wins.
        Duel.DuelResult memory r = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r, STAKE_BNBULL);
        duelKey = d.duelJackpotKey(r.nonce);
        _submitOn(d, b, r);
        assertEq(gatedPot.ticketCount(), 1, "harness: no ticket was opened");

        uint256 reqId = gatedPot.requestResolve(1);
        winningWord = _findWinningWord(
            0, alice, winnerBull, uint256(keccak256(abi.encodePacked(r.seed, r.nonce)))
        );
        coord.fulfill(reqId, winningWord);
        assertTrue(gatedPot.wordReady(), "harness: the word was not stored");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  🔴 THE DEFECT: it wedges, and it USED TO DO IT IN SILENCE
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⛔ THE FIX, ASSERTED. A winning ticket against a transfer-gated
     *         token still cannot be paid — but it now SAYS SO, on chain, with
     *         the revert selector attached.
     *
     * @dev The selector is the load-bearing half. `TradingNotEnabled()` tells a
     *      keeper "whitelist the pot"; `AddrBlacklisted(address)` tells it
     *      "this winner is blocked"; a `SafeERC20FailedOperation` tells it the
     *      token lied about a transfer. Without it, the alert is "something,
     *      somewhere, on this pot", which is barely better than nothing on the
     *      day it fires.
     *
     *      ⚠ OZ's `SafeERC20` BUBBLES the token's own revert data rather than
     *      wrapping it, so the selector that reaches `Duel` really is the
     *      token's. That is not incidental — if it wrapped, every gated token
     *      in the world would report the same opaque error.
     */
    function test_aWinningTicketAgainstAGatedTokenEmitsTheFailureAndDoesNotWedgeSilently()
        public
    {
        Duel.DuelResult memory r2 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r2, STAKE_BNBULL);
        bytes memory sig = _signOn(d, r2);

        vm.expectEmit(true, false, false, true, address(d));
        emit Duel.JackpotResolveFailed(address(gatedPot), BNBull.TradingNotEnabled.selector);
        vm.prank(alice);
        d.submitDuel(r2, sig);

        // The queue really is stuck — the event is a report, not a repair.
        assertEq(gatedPot.nextToResolve(), 0, "the cursor moved past an unpayable ticket");
        assertTrue(gatedPot.wordReady(), "the batch was released without being resolved");
        assertEq(gate.balanceOf(alice), 0, "the winner was somehow paid");
        assertEq(gatedPot.pool(), POT_SIZE, "the pool moved");
        assertEq(gatedPot.awardCount(), 0, "an award was booked that never happened");
    }

    /// @notice And the fight settles anyway. The try/catch is not the bug and
    ///         it is not being removed — a pot fault must never cost a player
    ///         their fight.
    function test_theFightStillSettlesWhileTheQueueIsJammed() public {
        Duel.DuelResult memory r2 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r2, STAKE_BNBULL);
        _submitOn(d, b, r2);

        assertEq(d.fightSeq(alice), 2, "the fight did not settle");
        assertEq(b.getBull(winnerBull).wins, 2, "the win was not recorded");
        assertEq(b.getBull(loserBull).losses, 2, "the loss was not recorded");
        assertEq(gatedPot.ticketCount(), 2, "the second fight lost its ticket too");
    }

    /**
     * @notice ⚠ THE WEDGE IS TOTAL, AND THIS IS WHY IT COST 77 TICKETS. Every
     *         later fight retries the same unpayable ticket and stops there.
     *
     * @dev And `requestResolve` cannot route around it: the fulfilled batch has
     *      to be fully consumed before a new word may be asked for, so
     *      `BatchStillOpen` blocks the keeper's usual escape hatch too. The
     *      queue does not degrade, it stops.
     */
    function test_everyLaterFightRetriesTheSameTicketAndTheQueueNeverMoves() public {
        // ⚠ ALTERNATING WINNERS, or `DECISIONS.md §32` ends the test early —
        // five consecutive losses and it is sausages, and a dead bull cannot
        // fight again. Every one of these is still decisive and still staked,
        // so every one still earns its ticket.
        for (uint256 i = 0; i < 5; i++) {
            uint256 champ = i % 2 == 0 ? winnerBull : loserBull;
            uint256 chump = i % 2 == 0 ? loserBull : winnerBull;
            Duel.DuelResult memory r = _newResultOn(d, b, champ, chump, uint32(champ));
            _stakeOn(d, b, r, STAKE_BNBULL);
            _submitOn(d, b, r);
        }

        assertEq(gatedPot.ticketCount(), 6, "the tickets stopped being opened");
        assertEq(gatedPot.nextToResolve(), 0, "the cursor moved");
        assertEq(gatedPot.pendingTickets(), 6, "six tickets should be owed");

        vm.expectRevert(Jackpot.BatchStillOpen.selector);
        gatedPot.requestResolve(10);
    }

    /**
     * @notice ⚠ NOTHING IS BURNED WHILE THE QUEUE IS STUCK, and that is worth
     *         asserting rather than assuming.
     *
     * @dev `Jackpot.resolve` claims the one-pot-per-duel key BEFORE it pays
     *      (`_claimDuel` then `safeTransfer`), so a naive reading says the
     *      failed attempt spends the duel's exclusivity and the OTHER pot can
     *      never pay that fight — `DECISIONS.md §10`'s "one pot never pays",
     *      arrived at from a new direction. It does not, because the revert
     *      rolls the claim back with everything else. The atomicity is the
     *      thing being tested; the assertion is what would catch a future
     *      "optimisation" that caches the claim outside the failing path.
     */
    function test_theFailedPayoutBurnsNeitherTheDuelKeyNorTheTicket() public {
        Duel.DuelResult memory r2 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r2, STAKE_BNBULL);
        _submitOn(d, b, r2);

        assertFalse(d.duelJackpotPaid(duelKey), "the exclusivity claim was spent on a failed pay");
        assertEq(gatedPot.totalAwarded(), 0, "an unpaid award was booked");
        (address ticketWinner,,,,) = gatedPot.tickets(0);
        assertEq(ticketWinner, alice, "the ticket lost its winner");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The recovery: one whitelist transaction drains the whole backlog
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⛔ WHAT THE EVENT IS FOR. `setWhitelist(pot, true)` — the wire
     *         `Wire.s.sol` now writes and `Verify.s.sol` now asserts — and the
     *         next nudge pays the ticket that has been stuck all along.
     *
     * @dev Which is exactly why the silence mattered so much: the fix is one
     *      owner transaction, and it was never applied because nobody knew.
     */
    function test_whitelistingThePotUnwedgesTheQueueAndPaysTheStuckTicket() public {
        // Jam it first, so this is a recovery and not a fresh start.
        Duel.DuelResult memory r2 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r2, STAKE_BNBULL);
        _submitOn(d, b, r2);
        assertEq(gatedPot.nextToResolve(), 0, "harness: the queue was not jammed");

        gate.setWhitelist(address(gatedPot), true);

        Duel.DuelResult memory r3 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r3, STAKE_BNBULL);
        _submitOn(d, b, r3);

        assertEq(gatedPot.nextToResolve(), 1, "the stuck ticket still has not resolved");
        assertEq(gate.balanceOf(alice), POT_SIZE, "the winner was not paid the pool");
        assertEq(gatedPot.pool(), 0, "the pool did not leave");
        assertEq(gatedPot.awardCount(), 1, "the award was not booked");
        assertTrue(d.duelJackpotPaid(duelKey), "the duel key was not claimed on the real payout");
        // The batch was one ticket wide, so consuming it releases the word and
        // a fresh request becomes possible again.
        assertFalse(gatedPot.wordReady(), "the exhausted batch was not released");
    }

    /**
     * @notice And with the pot whitelisted from the start there is no event at
     *         all — so the alert means something.
     *
     * @dev A failure signal that fires on the healthy path is a failure signal
     *      that gets muted. `recordLogs` rather than `expectEmit` because what
     *      is being asserted is an ABSENCE.
     */
    function test_aWhitelistedPotResolvesQuietlyWithNoFailureEvent() public {
        gate.setWhitelist(address(gatedPot), true);

        Duel.DuelResult memory r2 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r2, STAKE_BNBULL);
        bytes memory sig = _signOn(d, r2);

        vm.recordLogs();
        vm.prank(alice);
        d.submitDuel(r2, sig);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic = keccak256("JackpotResolveFailed(address,bytes4)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0) continue;
            assertTrue(entries[i].topics[0] != topic, "a healthy resolve cried wolf");
        }
        assertEq(gatedPot.nextToResolve(), 1, "the healthy path did not resolve");
        assertEq(gate.balanceOf(alice), POT_SIZE, "the winner was not paid");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The generalisation: ANY revert in `resolve`, not just this one
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE WHITELIST IS ONE CAUSE OF MANY. A BLACKLISTED WINNER JAMS
     *         THE QUEUE IDENTICALLY, on a token with trading fully open.
     *
     * @dev This is why the fix is an event on the swallow and not a
     *      whitelist-shaped patch. It is also the nastier version: the
     *      whitelist is fixed by a wire the deploy now writes and `Verify` now
     *      asserts, while this one can only appear AFTER launch, when nobody is
     *      watching a deploy script at all. `unblacklist` still works even
     *      after `lockBlacklist()`, so it stays recoverable — but only if
     *      somebody is told.
     */
    function test_aBlacklistedWinnerJamsTheQueueTheSameWayAndSaysSo() public {
        // The anti-bot window is closed first: it is a different mechanism with
        // a different symptom, and leaving it running would make this test pass
        // for the wrong reason.
        gate.setAntiBotBlocks(0);
        gate.enableTrading();
        gate.liftLimits();
        gate.setWhitelist(address(gatedPot), true);
        gate.blacklist(alice, "test: a winner nobody may pay");

        Duel.DuelResult memory r2 = _newResultOn(d, b, winnerBull, loserBull, uint32(winnerBull));
        _stakeOn(d, b, r2, STAKE_BNBULL);
        bytes memory sig = _signOn(d, r2);

        vm.expectEmit(true, false, false, true, address(d));
        emit Duel.JackpotResolveFailed(address(gatedPot), BNBull.AddrBlacklisted.selector);
        vm.prank(alice);
        d.submitDuel(r2, sig);

        assertEq(gatedPot.nextToResolve(), 0, "a blacklisted winner did not jam the queue");
        assertEq(d.fightSeq(alice), 2, "and the fight must still settle");
    }

    /// @notice A pot whose `resolve` reverts with NO data at all still names
    ///         itself. A zero selector is "it broke and would not say how",
    ///         which is a different alert from silence.
    function test_aPotThatRevertsWithNoDataStillNamesItselfWithAZeroSelector() public {
        address blind = address(new EmptyRevertPot());
        (Bulls b2, Duel d2) = _bareStack(blind);
        uint256 t1 = b2.mint(alice);
        uint256 t2 = b2.mint(bob);

        Duel.DuelResult memory r = _newResultOn(d2, b2, t1, t2, uint32(t1));
        _stakeOn(d2, b2, r, STAKE_BNBULL);
        bytes memory sig = _signOn(d2, r);

        vm.expectEmit(true, false, false, true, address(d2));
        emit Duel.JackpotResolveFailed(blind, bytes4(0));
        vm.prank(alice);
        d2.submitDuel(r, sig);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _bareStack(address pot) internal returns (Bulls nb, Duel nd) {
        nb = new Bulls(owner, SEED, bytes32(0));
        nd = _newDuel(address(nb));
        nb.bootstrapWire(Bulls.Wire.Duel, address(nd));
        nd.bootstrapWire(Duel.Wire.JackpotBnbull, pot);
    }

    /// @dev Search for a word that makes ticket `id` win. ⚠ The preimage
    ///      includes `address(this)` ON THE POT (`Jackpot.resolve`, the
    ///      `DECISIONS.md §10` separation), so the search must run against the
    ///      deployed pot's own address.
    function _findWinningWord(uint256 id, address winner, uint256 tokenId, uint256 entropy)
        internal
        view
        returns (uint256)
    {
        for (uint256 w = 1; w < 20_000; w++) {
            uint256 roll = uint256(
                keccak256(abi.encodePacked(w, entropy, tokenId, winner, id, address(gatedPot)))
            ) % gatedPot.oddsOneIn();
            if (roll == 0) return w;
        }
        revert("no winning word found in the search window");
    }
}

/// @dev A pot whose `resolve` reverts with an EMPTY payload, so the selector
///      the Duel logs has nothing to read. Not a contrived case: an
///      out-of-gas sub-call returns nothing either.
contract EmptyRevertPot {
    function recordWin(address, uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function resolve(uint256) external pure returns (uint256) {
        // solhint-disable-next-line reason-string
        revert();
    }

    function fund(uint256, string calldata) external pure {}
}
