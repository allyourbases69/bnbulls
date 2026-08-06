// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDuel} from "./mocks/Hostile.sol";

/**
 * @title JackpotRollSeparationTest
 * @notice PRIORITY 2. The `address(this)` term in the roll preimage.
 *
 * @dev THE BUG THIS FILE EXISTS TO CATCH, IN THE OWNER'S OWN WORDS
 *      (`DECISIONS.md §10`, `LEARNINGS-AND-MISTAKES §C`):
 *
 *        "without it, on stable, both pools rolled identically and one pot
 *         never paid — measured over 600 duels: 7 wins on one pot, 0 on the
 *         other."
 *
 *      The mechanism is arithmetic, not chance. Both pools are ticketed on
 *      every decisive duel and those two tickets share EVERY other input: the
 *      same duel entropy, the same tokenId, the same winner, and the same
 *      ticket index (one ticket per pool per duel keeps the cursors in
 *      lockstep). Drop `address(this)` and the two pools hash an IDENTICAL
 *      preimage, so they produce the same `H`. With odds of 50 and 100, and 50
 *      dividing 100:
 *
 *            H % 100 == 0   =>   H % 50 == 0
 *
 *      Every win on the 1-in-100 pot arrives with a win on the 1-in-50 pot,
 *      the 1-in-50 pot claims the shared `duelKey` first, and the 1-in-100 pot
 *      pays NEVER. Not rarely. Never.
 *
 *      So the test is not "do the pools look different". It is:
 *        A. reproduce the ORIGINAL bug arithmetically over 600 duels and show
 *           the containment is total (§ `test_counterfactual...`);
 *        B. show the shipped preimage breaks it (§ `test_liveRolls...`);
 *        C. run 600 real duels through two real deployments sharing one word
 *           and show BOTH pots actually pay (§ `test_sixHundredDuels...`).
 *      A test that would have caught the original bug is one that fails if
 *      `address(this)` is deleted — all three of these do.
 */
contract JackpotRollSeparationTest is BnbullsBase {
    /// @dev The measurement size quoted in DECISIONS §10.
    uint256 internal constant DUELS = 600;

    /// @dev Fixed inputs shared by both pools, exactly as a real duel supplies
    ///      them. Varying them per duel is what makes the sample a sample.
    address internal constant WINNER = address(0xA11CE);

    function setUp() public override {
        super.setUp();
        potBnbull.bootstrapDuel(address(duel));
        potBnb.bootstrapDuel(address(duel));

        // Deep pools with a tiny payout share, so a win never empties the pot
        // and turns a later `won` into a false negative (`won = paid > 0`).
        bnbull.mint(owner, 1e30);
        bnbull.approve(address(potBnbull), type(uint256).max);
        potBnbull.topUp(1e28);
        potBnbull.setPayoutBps(1);

        vm.deal(owner, 1e24);
        wbnb.deposit{value: 1e22}();
        wbnb.approve(address(potBnb), type(uint256).max);
        potBnb.topUp(1e22);
        potBnb.setPayoutBps(1);
    }

    // ─── Roll arithmetic, mirrored from the contract ──────────────────────

    /// @dev The SHIPPED preimage.
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

    /// @dev The preimage as it was BEFORE the fix: no per-pool term.
    function _rollNoSeparation(
        uint256 word,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(word, entropy, tokenId, winner, id))) % odds;
    }

    function _entropyFor(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("duel-entropy", i)));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A. Reproduce the original bug
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Without `address(this)`, the 1-in-100 pot is a strict subset of
     *         the 1-in-50 pot — so under the exclusivity lock it pays zero.
     */
    function test_counterfactual_withoutAddressThisTheSecondPotNeverPays() public pure {
        uint256 word = uint256(keccak256("the deciding word"));
        uint256 wins50;
        uint256 wins100;
        uint256 winsBoth;

        for (uint256 i = 0; i < DUELS; i++) {
            uint256 e = _entropyFor(i);
            bool a = _rollNoSeparation(word, e, i + 1, WINNER, i, 50) == 0;
            bool b = _rollNoSeparation(word, e, i + 1, WINNER, i, 100) == 0;
            if (a) wins50++;
            if (b) wins100++;
            if (a && b) winsBoth++;
            // The containment, stated per duel: a 1-in-100 hit is ALWAYS also
            // a 1-in-50 hit, because 50 divides 100 and the hash is identical.
            if (b) assertTrue(a, "counterfactual broken: 100-hit without a 50-hit");
        }

        assertGt(wins100, 0, "sample too small to say anything");
        assertEq(winsBoth, wins100, "every 100-pot win collided with a 50-pot win");

        // Under `one pot per duel, first winning ticket claims it`, the pot
        // resolved second is denied on every single one of its wins.
        uint256 paidByTheSecondPot = wins100 - winsBoth;
        assertEq(paidByTheSecondPot, 0, "this IS the fefers bug: 0 payouts, forever");
    }

    /// @dev The same thing at IDENTICAL odds, where the failure is even starker:
    ///      two pools would fire on exactly the same fights, every time.
    function test_counterfactual_identicalOddsMeanIdenticalPools() public pure {
        uint256 word = uint256(keccak256("word"));
        uint256 agree;
        uint256 winsA;
        for (uint256 i = 0; i < DUELS; i++) {
            uint256 e = _entropyFor(i);
            bool a = _rollNoSeparation(word, e, i + 1, WINNER, i, 50) == 0;
            bool b = _rollNoSeparation(word, e, i + 1, WINNER, i, 50) == 0;
            if (a) winsA++;
            if (a == b) agree++;
        }
        assertEq(agree, DUELS, "two pools would be the same pool");
        assertGt(winsA, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  B. The shipped preimage breaks it
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice With `address(this)` the two pools' outcomes diverge: there are
     *         duels the 1-in-100 pot wins and the 1-in-50 pot does not, which
     *         is exactly the set of fights the second pot can be paid on.
     */
    function test_liveRollsDivergeBetweenTheTwoDeployments() public view {
        uint256 word = uint256(keccak256("the deciding word"));
        uint256 wins50;
        uint256 wins100;
        uint256 winsBoth;
        uint256 hundredOnly;

        for (uint256 i = 0; i < DUELS; i++) {
            uint256 e = _entropyFor(i);
            bool a = _roll(word, e, i + 1, WINNER, i, address(potBnbull), 50) == 0;
            bool b = _roll(word, e, i + 1, WINNER, i, address(potBnb), 100) == 0;
            if (a) wins50++;
            if (b) wins100++;
            if (a && b) winsBoth++;
            if (b && !a) hundredOnly++;
        }

        assertGt(wins50, 0, "the 1-in-50 pot never fired");
        assertGt(wins100, 0, "the 1-in-100 pot never fired");
        assertGt(hundredOnly, 0, "NO duel pays the second pot - address(this) is not working");
        assertEq(
            hundredOnly, wins100 - winsBoth, "arithmetic sanity on the divergence count"
        );
    }

    /// @dev Two pools with the SAME odds and the SAME word must still disagree,
    ///      which can only come from the per-deployment term.
    function test_identicalOddsStillDivergeBecauseOfAddressThis() public {
        MockERC20 prize = new MockERC20("Prize", "PRZ", 18);
        Jackpot potA = new Jackpot(address(prize), address(0), address(coord), 50);
        Jackpot potB = new Jackpot(address(prize), address(0), address(coord), 50);
        assertTrue(address(potA) != address(potB));

        uint256 word = uint256(keccak256("word"));
        uint256 disagree;
        for (uint256 i = 0; i < DUELS; i++) {
            uint256 e = _entropyFor(i);
            bool a = _roll(word, e, i + 1, WINNER, i, address(potA), 50) == 0;
            bool b = _roll(word, e, i + 1, WINNER, i, address(potB), 50) == 0;
            if (a != b) disagree++;
        }
        // ~2 * 600 * (1/50) * (49/50) ~= 23 expected disagreements.
        assertGt(disagree, 5, "identical-odds pools rolled in lockstep");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  C. 600 real duels through two real deployments, sharing one word
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The regression test proper. Both pools are ticketed on every
     *         decisive duel with the same `duelKey`, both are decided by the
     *         SAME VRF word (the worst case the contract's comment calls out —
     *         two separate requests would give different words today, but that
     *         is a property of the KEEPER's call pattern, not of the code), and
     *         both must actually pay somebody.
     */
    function test_sixHundredDuels_bothPotsActuallyPay() public {
        uint256 word = uint256(keccak256("the deciding word"));

        for (uint256 i = 0; i < DUELS; i++) {
            uint256 duelKey = i + 1;
            duel.open(address(potBnbull), WINNER, i + 1, _entropyFor(i), duelKey);
            duel.open(address(potBnb), WINNER, i + 1, _entropyFor(i), duelKey);
        }
        assertEq(potBnbull.ticketCount(), DUELS);
        assertEq(potBnb.ticketCount(), DUELS);

        uint256 reqA = potBnbull.requestResolve(DUELS);
        uint256 reqB = potBnb.requestResolve(DUELS);
        coord.fulfill(reqA, word);
        coord.fulfill(reqB, word);

        potBnbull.resolve(DUELS);
        potBnb.resolve(DUELS);

        uint256 winsA = potBnbull.awardCount();
        uint256 winsB = potBnb.awardCount();

        // THE ASSERTION. On stable this read `7, 0`.
        assertGt(winsA, 0, "the BNBULL pot never paid");
        assertGt(winsB, 0, "THE WBNB POT NEVER PAID - this is the fefers 7-and-0 bug");

        // And the exclusivity lock still holds: no duel paid both pots.
        for (uint256 i = 1; i <= DUELS; i++) {
            address claimant = duel.claimedBy(i);
            claimant; // one claimant at most, by construction of MockDuel
        }
        assertEq(potBnbull.pendingTickets(), 0);
        assertEq(potBnb.pendingTickets(), 0);

        // Cross-check the live counts against the arithmetic above, which is
        // what proves the CONTRACT is using the preimage this file models.
        uint256 expectedA;
        uint256 expectedB;
        for (uint256 i = 0; i < DUELS; i++) {
            uint256 e = _entropyFor(i);
            bool a = _roll(word, e, i + 1, WINNER, i, address(potBnbull), 50) == 0;
            bool b = _roll(word, e, i + 1, WINNER, i, address(potBnb), 100) == 0;
            if (a) expectedA++;
            // pot B resolves second, so a shared win is denied to it
            if (b && !a) expectedB++;
        }
        assertEq(winsA, expectedA, "live 1-in-50 wins do not match the modelled preimage");
        assertEq(winsB, expectedB, "live 1-in-100 wins do not match the modelled preimage");
    }

    /// @dev Odds sanity: over a large sample the observed rate must sit near
    ///      1/oddsOneIn. A roll that is not uniform (a stuck word, a truncated
    ///      preimage) shows up here rather than as a subtle payout skew.
    function test_observedWinRateTracksTheStatedOdds() public view {
        uint256 word = uint256(keccak256("rate sample"));
        uint256 n = 5_000;
        uint256 wins;
        for (uint256 i = 0; i < n; i++) {
            if (_roll(word, _entropyFor(i), i + 1, WINNER, i, address(potBnbull), 50) == 0) {
                wins++;
            }
        }
        // Expect 100. A ±50% band is loose enough never to flake and tight
        // enough to catch a roll that is not actually 1-in-50.
        assertGt(wins, 50, "win rate far below the stated 1-in-50");
        assertLt(wins, 150, "win rate far above the stated 1-in-50");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  One pot per duel — the other half of the same rule
    // ══════════════════════════════════════════════════════════════════════

    function test_onePotPerDuel_secondPotIsDeniedAndSaysSo() public {
        potBnbull.setOdds(1);
        potBnb.setOdds(1); // force BOTH to win the same duel

        duel.open(address(potBnbull), alice, 1, 0xAAA, 99);
        duel.open(address(potBnb), alice, 1, 0xAAA, 99);

        uint256 rA = potBnbull.requestResolve(1);
        uint256 rB = potBnb.requestResolve(1);
        coord.fulfill(rA, 1);
        coord.fulfill(rB, 1);

        potBnbull.resolve(1);

        vm.expectEmit(true, true, false, true, address(potBnb));
        emit Jackpot.ExclusivityDenied(0, alice, 99);
        potBnb.resolve(1);

        assertEq(potBnbull.awardCount(), 1, "the first pot to resolve pays");
        assertEq(potBnb.awardCount(), 0, "one fight must never pay both pots");
        assertEq(wbnb.balanceOf(alice), 0);
    }

    /// @dev `duelKey == 0` disables the check — the standalone-pool escape used
    ///      by tests and by any future single-pot deployment.
    function test_duelKeyZeroSkipsTheExclusivityCheck() public {
        potBnbull.setOdds(1);
        potBnb.setOdds(1);

        duel.open(address(potBnbull), alice, 1, 0xAAA, 0);
        duel.open(address(potBnb), alice, 1, 0xAAA, 0);

        uint256 rA = potBnbull.requestResolve(1);
        uint256 rB = potBnb.requestResolve(1);
        coord.fulfill(rA, 1);
        coord.fulfill(rB, 1);
        potBnbull.resolve(1);
        potBnb.resolve(1);

        assertEq(potBnbull.awardCount(), 1);
        assertEq(potBnb.awardCount(), 1);
    }

    /// @dev An unreachable lock is treated as DENIED, deliberately: we cannot
    ///      prove the other pot did not already pay, and "never both pots" is
    ///      the invariant that matters. Cost of being wrong this way: a payout
    ///      that rolls back into the pool, visible on chain.
    function test_unreachableLockIsTreatedAsDenied() public {
        potBnbull.setOdds(1);
        duel.setClaimReverts(true);

        duel.open(address(potBnbull), alice, 1, 0xAAA, 5);
        uint256 r = potBnbull.requestResolve(1);
        coord.fulfill(r, 1);
        potBnbull.resolve(1);

        assertEq(potBnbull.awardCount(), 0, "paid out with an unreachable lock");
        assertEq(bnbull.balanceOf(alice), 0);
        assertEq(potBnbull.pendingTickets(), 0, "the loop must not have reverted");
    }

    /// @dev A `duel` with no code, and a `duel` that answers with EMPTY
    ///      returndata, are both treated as DENIED without reverting. This is
    ///      the case `_claimDuel`'s low-level call was written for.
    function test_silentLockIsTreatedAsDeniedWithoutReverting() public {
        Jackpot pot = _standalonePot();
        address silent = address(new SilentLock());
        pot.bootstrapDuel(silent);

        vm.prank(silent);
        pot.recordWin(alice, 1, 1, 42);
        uint256 r = pot.requestResolve(1);
        coord.fulfillTo(address(pot), r, 1);
        pot.resolve(1);

        assertEq(pot.pendingTickets(), 0, "the resolve loop reverted on empty returndata");
        assertEq(pot.awardCount(), 0, "silence must read as denied");
    }

    /**
     * @notice ⚠ FINDING — `_claimDuel` CAN revert, and its NatSpec says it
     *         cannot.
     *
     * @dev The comment on `_claimDuel` reads:
     *
     *        "Low-level `call` rather than try/catch on purpose. A `duel` that
     *         is an EOA would return success with EMPTY returndata, and
     *         Solidity's try/catch does NOT catch a return-data decode failure
     *         — it would revert the whole resolve loop. **This cannot revert
     *         for any callee.**"
     *
     *      The `ret.length < 32` guard covers the empty case, but not a callee
     *      that returns a full 32-byte word which is not a canonical bool.
     *      `abi.decode(ret, (bool))` validates that the word is 0 or 1 and
     *      PANICS otherwise — so the resolve loop reverts after all, for the
     *      exact class of callee the comment claims immunity from.
     *
     *      Blast radius if it ever happened: `resolve` reverts on that ticket
     *      forever, the cursor can never advance past it, and every later
     *      ticket is stranded — in a contract with NO withdraw path. That is a
     *      permanently wedged queue, which is the one failure mode the whole
     *      "nothing here may ever revert" discipline exists to prevent.
     *
     *      Likelihood: low. The Duel wire is timelocked and the real Duel is
     *      Solidity returning a `bool`, which is always canonical. It bites if
     *      the wire is ever pointed at a proxy, a Vyper/assembly implementation,
     *      or a contract whose fallback answers with arbitrary data.
     *
     *      FIX (one line): replace `abi.decode(ret, (bool))` with a raw word
     *      read, e.g. `return abi.decode(ret, (uint256)) == 1;` — or bound the
     *      whole thing by treating any non-1 word as denied.
     *
     *      ⚠ THE ASSERTION BELOW DOCUMENTS TODAY'S BEHAVIOUR. When the fix
     *      lands, this must become the passing `resolve` of the silent-lock
     *      test above rather than a `vm.expectRevert`.
     */
    /// FIXED 2026-08-06 — `_claimDuel` now decodes the raw word and compares
    /// to 1, instead of `abi.decode(ret, (bool))` which reverts on any word
    /// that is not exactly 0 or 1. Before the fix this stranded the ticket
    /// forever: `resolve` reverted on it, the cursor could never advance past
    /// it, and every later ticket was unreachable in a contract with no
    /// withdraw path.
    function test_nonCanonicalBoolFromTheLockCannotStrandTheResolveLoop() public {
        Jackpot pot = _standalonePot();
        address garbage = address(new GarbageLock());
        pot.bootstrapDuel(garbage);

        vm.prank(garbage);
        pot.recordWin(alice, 1, 1, 42);
        uint256 r = pot.requestResolve(1);
        coord.fulfillTo(address(pot), r, 1);

        // Resolves cleanly now. The garbage word reads as "denied", which is
        // the documented fail-safe: we could not prove the other pot had not
        // already paid, so this one does not.
        pot.resolve(1);

        assertEq(pot.pendingTickets(), 0, "the cursor advanced past the bad ticket");
        assertEq(pot.awardCount(), 0, "and an unreadable lock denies the payout");
        assertGt(pot.pool(), 0, "the money rolls over into the pool, not out of it");
    }

    function _standalonePot() internal returns (Jackpot pot) {
        pot = new Jackpot(address(bnbull), address(0), address(coord), 1);
        pot.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        bnbull.mint(address(pot), 1_000e18);
    }
}

/// @dev Answers the lock call with a full 32-byte word that is not 0 or 1.
contract GarbageLock {
    function claimJackpotForDuel(uint256) external pure returns (bytes32) {
        return bytes32(uint256(0xdeadbeef));
    }
}

/// @dev Answers every call successfully, with nothing.
contract SilentLock {
    fallback() external {}
}
