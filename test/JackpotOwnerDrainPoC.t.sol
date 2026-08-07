// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Jackpot} from "../contracts/Jackpot.sol";

/**
 * @title JackpotOwnerDrainBlockedTest
 * @notice ⚠ THE REGRESSION GUARD FOR THE POOL DRAIN. This file was the proof of
 *         concept; it is now the proof of the fix.
 *
 * @dev `DECISIONS.md §18` sets the standard: *"the audit question is not 'is
 *      there a withdraw function' but 'can the owner cause the money to leave to
 *      a chosen address'."* `sweepForeignToken` refuses `prizeToken` and there
 *      is no `receive()`, so the only value exit is `resolve()` paying a winner
 *      — which is why the three numbers deciding "who wins and how much" are
 *      money slots in their own right.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT THIS FILE USED TO PROVE — reproduced end to end, four transactions
 *      ══════════════════════════════════════════════════════════════════════
 *      `resolve` read `oddsOneIn`, `minPoolToFire` and `payoutBps` from LIVE
 *      storage at decision time, and all three were plain un-timelocked
 *      `onlyOwner` setters with no in-flight guard:
 *
 *        1. `setMinPoolToFire(type(uint256).max)` → `resolve(n)` walks the
 *           cursor past every other player's ticket paying nothing
 *        2. open one ticket to an address you control
 *        3. `setMinPoolToFire(0); setOdds(1); setPayoutBps(10_000)`
 *        4. `resolve(1)` → **the entire pool, to an address of your choosing**
 *
 *      `setOdds(1)` is the hinge: `H % 1 == 0` for EVERY possible word, so no
 *      VRF grinding was needed at all. And because the terms were read live, the
 *      owner could watch the word land and only then choose the terms it would
 *      be judged under — which handed back exactly what "the batch range is
 *      fixed at REQUEST time, before the word exists" was protecting.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT THIS FILE PROVES NOW — the same four steps, and each one blocked
 *      ══════════════════════════════════════════════════════════════════════
 *        1. `setOdds` / `setPayoutBps` / `setMinPoolToFire` DO NOT EXIST.
 *        2. `MIN_ODDS_ONE_IN = 10` is a floor on the constructor, on the
 *           one-time bootstrap AND on the timelocked proposal. A certain win
 *           cannot be configured by any route.
 *        3. The three numbers move together through
 *           bootstrap-once → propose → wait `wiringDelay` → commit, so the end
 *           state is on public display with an ETA for a full day first.
 *        4. THE SNAPSHOT. The terms are captured into the request beside the
 *           range and promoted with the word, so a change made after the word
 *           lands cannot reach the batch it lands on.
 *
 *      ⚠ Every test below asserts the drain is IMPOSSIBLE. A failure here is a
 *      regression on the most serious defect class this contract has.
 */
contract JackpotOwnerDrainBlockedTest is BnbullsBase {
    /// @dev The address a compromised owner would want the pool to land in.
    address internal constant ATTACKER_PAYOUT = address(0xDEADBEEF);

    function setUp() public override {
        super.setUp();
        potBnbull.bootstrapDuel(address(duel));
        bnbull.mint(owner, 1e30);
        bnbull.approve(address(potBnbull), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Roll arithmetic, mirrored from the contract
    // ══════════════════════════════════════════════════════════════════════

    function _roll(
        uint256 word,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        address pot,
        uint256 odds
    ) internal pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(word, entropy, tokenId, winner, id, pot))) % odds;
    }

    /// @dev A word that makes ticket `id` a winner. The honest replacement for
    ///      `setOdds(1)`: it still costs only ~`odds` keccaks to find, which is
    ///      precisely why the roll preimage was never the defence (§18) — only
    ///      the timelocked coordinator and these bounds are.
    function _wordThatWins(
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256) {
        for (uint256 word = 1; word < 100_000; word++) {
            if (_roll(word, entropy, tokenId, winner, id, pot, odds) == 0) return word;
        }
        revert("no winning word found");
    }

    function _wordThatLoses(
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256) {
        for (uint256 word = 1; word < 100_000; word++) {
            if (_roll(word, entropy, tokenId, winner, id, pot, odds) != 0) return word;
        }
        revert("no losing word found");
    }

    /// @dev How many of the first `n` candidate words would make this ticket
    ///      win. At odds of 1 the answer is `n` — every word, no exceptions —
    ///      which is the whole reason the floor exists.
    function _winningWordsAmongFirst(
        uint256 n,
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256 count) {
        for (uint256 word = 1; word <= n; word++) {
            if (_roll(word, entropy, tokenId, winner, id, pot, odds) == 0) count++;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. The three setters are GONE
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The deleted surface, asserted by SELECTOR rather than by the
     *         compiler.
     *
     * @dev A compile error would be enough to stop this file naming them, but it
     *      would not stop somebody re-adding them later and this file still
     *      passing. `Jackpot` has no `receive()` and no `fallback()`, so an
     *      unroutable selector reverts — the calls below can only succeed if the
     *      functions come back.
     */
    function test_theThreeUnTimelockedSettersDoNotExist() public {
        (bool ok,) =
            address(potBnbull).call(abi.encodeWithSignature("setOdds(uint256)", uint256(1)));
        assertFalse(ok, "setOdds is BACK - step 3 of the pool drain is reachable again");

        (ok,) = address(potBnbull).call(
            abi.encodeWithSignature("setPayoutBps(uint256)", uint256(10_000))
        );
        assertFalse(ok, "setPayoutBps is BACK");

        (ok,) = address(potBnbull).call(
            abi.encodeWithSignature("setMinPoolToFire(uint256)", type(uint256).max)
        );
        assertFalse(ok, "setMinPoolToFire is BACK - the queue-burn step is reachable again");

        // And nothing above moved the live numbers.
        assertEq(potBnbull.oddsOneIn(), 50);
        assertEq(potBnbull.payoutBps(), 10_000);
        assertEq(potBnbull.minPoolToFire(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. A certain win cannot be configured, by any route
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `oddsOneIn = 1` is a win on every possible word. All three ways
     *         into the odds — construction, the one free instant write, and the
     *         timelocked proposal — refuse anything under `MIN_ODDS_ONE_IN`.
     */
    function test_oddsBelowTheFloorAreRejectedEverywhere() public {
        uint256 floor_ = potBnbull.MIN_ODDS_ONE_IN();
        assertEq(floor_, 10, "the floor moved - re-derive what a drain now costs");

        // A pot deployed at odds of one would be drainable from block one,
        // before any timelock could matter. So it cannot be deployed.
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, uint256(1)));
        new Jackpot(address(bnbull), address(0), address(coord), 1);

        for (uint256 o = 0; o < floor_; o++) {
            vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, o));
            potBnbull.bootstrapPayoutParams(o, 10_000, 0);

            vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, o));
            potBnbull.proposePayoutParams(o, 10_000, 0);
        }

        // A refused proposal leaves nothing pending to commit.
        vm.expectRevert(Jackpot.NothingProposed.selector);
        potBnbull.commitPayoutParams();
        assertEq(potBnbull.oddsOneIn(), 50, "the odds must not have moved");

        // ⚠ THE PROPERTY THE FLOOR BUYS, stated directly: at odds of one every
        // word is a winning word. At the floor, almost none are.
        uint256 atFloor = _winningWordsAmongFirst(
            200, address(potBnbull), 0xC3, 3, ATTACKER_PAYOUT, 0, floor_
        );
        assertLt(atFloor, 200, "odds of one would make EVERY word a winning word");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. The full four-step sequence no longer moves the pool
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE WHOLE ORIGINAL ATTACK, RUN AGAIN. The players' tickets can
     *         still be burned behind a high floor — that half was never the
     *         defect — but step 3 is now a floored, timelocked, publicly
     *         announced change, and step 4 pays nobody.
     */
    function test_theFourStepDrainNoLongerMovesThePool() public {
        potBnbull.topUp(1_000e18);
        uint256 pool = potBnbull.pool();
        assertEq(pool, 1_000e18);
        assertEq(bnbull.balanceOf(ATTACKER_PAYOUT), 0);

        // Two real players win fights and are ticketed, ahead of the attacker.
        duel.open(address(potBnbull), alice, 1, 0xA1, 0);
        duel.open(address(potBnbull), bob, 2, 0xB2, 0);

        // ── STEP 1: make every pending ticket unwinnable, then burn them. ──
        // The one free deploy-day write, spent here. `won = roll == 0 &&
        // balance >= minPool && ...` is false for all, but the cursor advances
        // anyway, so the players' tickets are consumed paying nothing.
        potBnbull.bootstrapPayoutParams(50, 10_000, type(uint256).max);
        uint256 r1 = potBnbull.requestResolve(10);
        coord.fulfill(r1, uint256(keccak256("any word at all")));
        potBnbull.resolve(10);

        assertEq(potBnbull.pendingTickets(), 0, "the players' tickets were consumed");
        assertEq(bnbull.balanceOf(alice), 0, "alice was paid nothing");
        assertEq(bnbull.balanceOf(bob), 0, "bob was paid nothing");
        assertEq(potBnbull.pool(), pool, "and the pool is untouched, ready for step 2");

        // ── STEP 2: the attacker's own ticket is now the head of the queue. ─
        duel.open(address(potBnbull), ATTACKER_PAYOUT, 3, 0xC3, 0);
        uint256 ticketId = 2;

        // ── STEP 3: flip the three knobs. THIS IS WHERE IT NOW STOPS. ──────
        // (a) the instant write is a ONE-TIME flag, and it is already spent.
        vm.expectRevert(Jackpot.PayoutParamsAlreadyBootstrapped.selector);
        potBnbull.bootstrapPayoutParams(1, 10_000, 0);

        // (b) a certain win cannot even be PROPOSED.
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, uint256(1)));
        potBnbull.proposePayoutParams(1, 10_000, 0);

        // (c) the best available end state is the floor, and buying it costs a
        //     full `wiringDelay` of public notice with an ETA on chain. All
        //     three numbers move on ONE clock, so the queue-burn floor and the
        //     odds cannot be staged separately and landed in one block.
        uint64 eta = potBnbull.proposePayoutParams(potBnbull.MIN_ODDS_ONE_IN(), 10_000, 0);
        assertEq(uint256(eta), block.timestamp + potBnbull.wiringDelay(), "the ETA is public");
        assertEq(potBnbull.proposedOdds(), 10, "and so is the whole intended end state");
        assertEq(potBnbull.proposedMinPool(), 0);

        vm.warp(uint256(eta) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Jackpot.PayoutParamsNotElapsed.selector, eta, uint64(block.timestamp)
            )
        );
        potBnbull.commitPayoutParams();
        assertEq(potBnbull.oddsOneIn(), 50, "the odds must not move before the ETA");

        vm.warp(eta);
        potBnbull.commitPayoutParams();
        assertEq(potBnbull.oddsOneIn(), 10, "a whole day of notice bought 1-in-10, not 1-in-1");
        assertEq(potBnbull.minPoolToFire(), 0);

        // ── STEP 4: resolve. The roll is a ROLL again. ─────────────────────
        // On the old code this step was deterministic: at odds of 1 the ticket
        // won no matter what word arrived. Now nine words in ten lose it, and
        // WHICH word arrives is not the owner's to choose either — it comes
        // from the timelocked coordinator (§18, `JackpotNoWithdraw.t.sol`).
        uint256 winningWords = _winningWordsAmongFirst(
            100, address(potBnbull), 0xC3, 3, ATTACKER_PAYOUT, ticketId, potBnbull.oddsOneIn()
        );
        assertLt(winningWords, 100, "EVERY word wins - the odds are effectively 1");

        uint256 r2 = potBnbull.requestResolve(1);
        coord.fulfill(
            r2, _wordThatLoses(address(potBnbull), 0xC3, 3, ATTACKER_PAYOUT, ticketId, 10)
        );
        potBnbull.resolve(1);

        // ── The result, inverted. ─────────────────────────────────────────
        assertEq(
            bnbull.balanceOf(ATTACKER_PAYOUT),
            0,
            "THE POOL LEFT THE POT TO AN OWNER-CHOSEN ADDRESS"
        );
        assertEq(potBnbull.pool(), pool, "the pot is intact");
        assertEq(potBnbull.awardCount(), 0);
        assertEq(potBnbull.pendingTickets(), 0, "the ticket resolved, it just did not pay");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. The snapshot: a mid-flight change cannot reach a batch in flight
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE SHARPEST FORM OF THE FIX. Even granting the attacker a
     *         WINNING word and a full timelock's patience, the terms the ticket
     *         is judged under were fixed before that word existed.
     *
     * @dev This is the half a bound on the odds alone would not have closed. The
     *      pot is set up so nothing can win (the floor is above the pool), the
     *      word lands, and only THEN does the owner move the live numbers to
     *      terms that would pay. The commit succeeds — it is a legitimate,
     *      publicly-noticed change — and the batch in flight ignores it.
     */
    function test_aMidFlightParamChangeCannotReachABatchAlreadyRequested() public {
        potBnbull.topUp(1_000e18);
        uint256 pool = potBnbull.pool();

        // Terms under which NOTHING can win: the floor is above the pool.
        potBnbull.bootstrapPayoutParams(50, 10_000, type(uint256).max);

        duel.open(address(potBnbull), ATTACKER_PAYOUT, 3, 0xC3, 0);

        // ⛔ THE TERMS ARE SNAPSHOTTED HERE, WITH THE RANGE, BEFORE THE WORD.
        uint256 reqId = potBnbull.requestResolve(1);
        assertEq(potBnbull.pendingOdds(), 50);
        assertEq(potBnbull.pendingPayoutBps(), 10_000);
        assertEq(potBnbull.pendingMinPool(), type(uint256).max);

        // The word arrives — and it is one that WINS this ticket outright.
        uint256 word = _wordThatWins(address(potBnbull), 0xC3, 3, ATTACKER_PAYOUT, 0, 50);
        coord.fulfill(reqId, word);
        assertEq(potBnbull.resolveOdds(), 50, "the terms travel with the word");
        assertEq(potBnbull.resolvePayoutBps(), 10_000);
        assertEq(potBnbull.resolveMinPool(), type(uint256).max);

        // NOW the owner has seen the word land and moves the live numbers to
        // terms that would pay it. Allowed, timelocked, and useless.
        uint64 eta = potBnbull.proposePayoutParams(50, 10_000, 0);
        vm.warp(eta);
        potBnbull.commitPayoutParams();
        assertEq(potBnbull.minPoolToFire(), 0, "the LIVE floor is now zero");
        assertEq(
            potBnbull.resolveMinPool(),
            type(uint256).max,
            "THE SNAPSHOT MOVED WITH THE LIVE VALUE - resolve is reading live storage again"
        );

        // ⚠ The assertion that makes this bite. `roll == 0` says the ticket
        // genuinely won under the delivered word; `won == false` says the
        // SNAPSHOTTED floor, not the live one, is what judged it.
        vm.expectEmit(true, true, true, true, address(potBnbull));
        emit Jackpot.TicketResolved(0, ATTACKER_PAYOUT, 3, 0, 50, false);
        potBnbull.resolve(1);

        assertEq(
            bnbull.balanceOf(ATTACKER_PAYOUT),
            0,
            "a param change made AFTER the word reached the batch it decided"
        );
        assertEq(potBnbull.pool(), pool, "the pot is intact");
        assertEq(potBnbull.awardCount(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. The instant write is available exactly once
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev ⚠ It is a ONE-TIME FLAG and deliberately NOT "while no tickets
     *      exist". The latter looks equivalent and is not: the owner could fund
     *      the pot, set the odds to the floor while the queue was empty, and
     *      only then open the ticket that collects.
     */
    function test_theInstantWriteIsAvailableExactlyOnce() public {
        assertFalse(potBnbull.payoutParamsBootstrapped(), "fresh pot, unbootstrapped");
        potBnbull.bootstrapPayoutParams(50, 10_000, 0);
        assertTrue(potBnbull.payoutParamsBootstrapped());

        vm.expectRevert(Jackpot.PayoutParamsAlreadyBootstrapped.selector);
        potBnbull.bootstrapPayoutParams(50, 10_000, 0);

        // Nothing pending means nothing to commit and nothing to cancel.
        vm.expectRevert(Jackpot.NothingProposed.selector);
        potBnbull.commitPayoutParams();
        vm.expectRevert(Jackpot.NothingProposed.selector);
        potBnbull.cancelPayoutParams();

        // A cancelled proposal must never land, however long it is left.
        uint64 eta = potBnbull.proposePayoutParams(100, 5_000, 1);
        potBnbull.cancelPayoutParams();
        vm.warp(uint256(eta) + 365 days);
        vm.expectRevert(Jackpot.NothingProposed.selector);
        potBnbull.commitPayoutParams();

        assertEq(potBnbull.oddsOneIn(), 50, "a cancelled proposal landed anyway");
        assertEq(potBnbull.payoutBps(), 10_000);
        assertEq(potBnbull.minPoolToFire(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. The narrow version, with nobody else involved
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The half that used to survive being argued away: even with an
     *         empty queue and no other players, ONE setter and ONE ticket
     *         emptied the pot. The setter is gone, so the ticket is a 1-in-50
     *         gamble on a word the owner does not choose.
     */
    function test_theShortVersionWithNoOtherPlayersInvolved() public {
        potBnbull.topUp(500e18);
        address chosen = address(0xC0FFEE);

        duel.open(address(potBnbull), chosen, 9, 0x9, 0);

        (bool ok,) =
            address(potBnbull).call(abi.encodeWithSignature("setOdds(uint256)", uint256(1)));
        assertFalse(ok, "setOdds is back - one setter and one ticket empties the pot");

        uint256 r = potBnbull.requestResolve(1);
        coord.fulfill(r, _wordThatLoses(address(potBnbull), 0x9, 9, chosen, 0, 50));
        potBnbull.resolve(1);

        assertEq(bnbull.balanceOf(chosen), 0, "one ticket must not be able to empty the pot");
        assertEq(potBnbull.pool(), 500e18, "the pool is whole");
        assertEq(potBnbull.awardCount(), 0);
    }
}
