// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Duel} from "../contracts/Duel.sol";

/**
 * @title DuelFightSeqTest
 * @notice PRIORITY 1. The per-wallet fight sequence — the fix for the
 *         affordability hole.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      `BNBULLS-BOOTSTRAP.md §5` describes the fefers latent revert, and
 *      `DECISIONS.md §16` records that blocking self-duels NARROWS it without
 *      closing it:
 *
 *        "two of one owner's bulls can still hold signed fights against two
 *         *different* opponents while drawing on the same wallet balance; both
 *         pass their affordability snapshot, the first to settle takes the
 *         money and the second reverts on `ERC20: balance`."
 *
 *      The commit is per WALLET here, and it is enforced on chain. Every
 *      address carries a `fightSeq`; the signed result names the value each
 *      side is spending; settlement requires an exact match and bumps it. The
 *      consequence that matters:
 *
 *        **at most one signed result naming a given wallet can ever settle.**
 *
 *      Every test below is a facet of that sentence. The most important one is
 *      `test_aSecondSignatureOnTheSameWalletDiesBeforeAnyTokenMoves`: the
 *      second signature must fail with `StaleFightSeq` — a named, legible
 *      error carrying the numbers — and it must fail BEFORE `_collectStakes`
 *      runs, not deep inside an opaque `ERC20: transfer amount exceeds
 *      balance`.
 */
contract DuelFightSeqTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;
    uint256 internal aliceBull2;
    uint256 internal carolBull;

    uint256 internal constant STAKE = 10e18;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
        aliceBull2 = _mintBull(alice);
        carolBull = _mintBull(carol);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The sequence must match exactly, and settling bumps it
    // ══════════════════════════════════════════════════════════════════════

    function test_theSignedSequenceMustMatchTheWalletExactly() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.seqA = 1; // one ahead — nothing has been consumed yet

        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.StaleFightSeq.selector, alice, 0, 1)
        );
    }

    function test_aSequenceFromThePastIsAlsoRefused() public {
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.fightSeq(alice), 1);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.seqA = 0;

        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.StaleFightSeq.selector, alice, 1, 0)
        );
    }

    function test_settlementBumpsBothSidesSequences() public {
        assertEq(duelC.fightSeq(alice), 0);
        assertEq(duelC.fightSeq(bob), 0);

        _fight(aliceBull, bobBull, uint32(aliceBull));

        assertEq(duelC.fightSeq(alice), 1, "side A's wallet was not bumped");
        assertEq(duelC.fightSeq(bob), 1, "side B's wallet was not bumped");
    }

    function test_bothSidesSequencesAreEmittedAsTheyAreConsumed() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r);

        vm.expectEmit(true, false, false, true, address(duelC));
        emit Duel.FightSeqConsumed(alice, 0);
        vm.expectEmit(true, false, false, true, address(duelC));
        emit Duel.FightSeqConsumed(bob, 0);

        vm.prank(alice);
        duelC.submitDuel(r, sig);
    }

    /// @notice THE call the signer makes before quoting.
    function test_nextFightSeqReportsWhatTheSignerMustUse() public {
        assertEq(duelC.nextFightSeq(alice), 0);
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.nextFightSeq(alice), 1);
        assertEq(duelC.nextFightSeq(bob), 1);
        assertEq(duelC.nextFightSeq(carol), 0, "an untouched wallet still reads zero");

        // And the value it reports is the one that actually works.
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(bobBull));
        assertEq(r.seqA, duelC.nextFightSeq(alice));
        _submit(r);
        assertEq(duelC.fightSeq(alice), 2);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE affordability hole, closed
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The exact fefers scenario, reproduced and refused.
     *
     * @dev Two of alice's bulls hold signed fights against two DIFFERENT
     *      opponents, drawing on one balance. Both passed the signer's
     *      affordability snapshot. On fefers the first took the money and the
     *      second reverted deep inside the ERC-20.
     *
     *      Here the second one is dead the moment the first lands: it carries a
     *      stale sequence, and it says so by name and by number BEFORE a single
     *      token moves.
     */
    function test_aSecondSignatureOnTheSameWalletDiesBeforeAnyTokenMoves() public {
        // Alice can afford exactly ONE fight.
        _fundForFight(alice, STAKE, 0);
        _fundForFight(bob, STAKE, 0);
        _fundForFight(carol, STAKE, 0);

        // BOTH results are signed against the same snapshot — `seqA == 0`.
        Duel.DuelResult memory first = _stakedResult(aliceBull, bobBull, uint32(bobBull));
        Duel.DuelResult memory second = _stakedResult(aliceBull2, carolBull, uint32(carolBull));
        assertEq(first.seqA, 0);
        assertEq(second.seqA, 0, "both signatures name the same wallet sequence");

        _submitAs(alice, first);
        assertEq(bnbull.balanceOf(alice), 0, "the first fight took the money");

        uint256 aliceBefore = bnbull.balanceOf(alice);
        uint256 carolBefore = bnbull.balanceOf(carol);
        uint256 duelBefore = bnbull.balanceOf(address(duelC));

        // Not `ERC20: transfer amount exceeds balance`. Not `StakeUnaffordable`
        // either — the sequence gate is BEFORE `_collectStakes`, so the fight
        // is refused for the right reason.
        _expectSubmitRevert(
            alice, second, abi.encodeWithSelector(Duel.StaleFightSeq.selector, alice, 1, 0)
        );

        assertEq(bnbull.balanceOf(alice), aliceBefore, "alice moved");
        assertEq(bnbull.balanceOf(carol), carolBefore, "the opponent moved");
        assertEq(bnbull.balanceOf(address(duelC)), duelBefore, "the duel held a stake");
        assertEq(duelC.fightSeq(carol), 0, "the opponent's sequence was burned");
        assertFalse(duelC.usedNonces(second.nonce), "the nonce was consumed by a dead fight");
    }

    /**
     * @notice The passive-opponent version. Two players pick the same opponent
     *         at the same time; one of them resolves.
     *
     * @dev `Duel.sol` calls this out as the stated cost: "a passive opponent
     *      picked by two players at once resolves one of them. That is a
     *      re-quote, not a lost stake."
     */
    function test_twoPlayersPickingTheSameOpponentResolveOnlyOneOfThem() public {
        _fundForFight(alice, STAKE, 0);
        _fundForFight(carol, STAKE, 0);
        _fundForFight(bob, STAKE * 4, 0);

        Duel.DuelResult memory fromAlice = _stakedResult(aliceBull, bobBull, uint32(aliceBull));
        Duel.DuelResult memory fromCarol = _stakedResult(carolBull, bobBull, uint32(carolBull));
        assertEq(fromAlice.seqB, 0);
        assertEq(fromCarol.seqB, 0, "both name bob's sequence zero");

        _submitAs(alice, fromAlice);

        _expectSubmitRevert(
            carol, fromCarol, abi.encodeWithSelector(Duel.StaleFightSeq.selector, bob, 1, 0)
        );

        // Carol's own sequence is untouched, so her re-quote is one read away.
        assertEq(duelC.fightSeq(carol), 0);
        Duel.DuelResult memory requote = _stakedResult(carolBull, bobBull, uint32(carolBull));
        _submitAs(carol, requote);
        assertEq(duelC.fightSeq(carol), 1);
    }

    /// @dev The sequence is per WALLET, not per BULL. Alice's two bulls share
    ///      one counter — which is the whole point, because they share one
    ///      balance.
    function test_theSequenceIsPerWalletNotPerBull() public {
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.fightSeq(alice), 1);

        // Her OTHER bull now has to spend sequence 1, not sequence 0.
        Duel.DuelResult memory r = _newResult(aliceBull2, carolBull, uint32(aliceBull2));
        assertEq(r.seqA, 1, "the second bull inherited the wallet's sequence");
        _submit(r);
        assertEq(duelC.fightSeq(alice), 2);
    }

    /// @dev It follows the BULL'S CURRENT OWNER, because everything in
    ///      `submitDuel` keys off the live `ownerOf` reads.
    function test_theSequenceFollowsTheBullsCurrentOwner() public {
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.fightSeq(alice), 1);
        assertEq(duelC.fightSeq(carol), 0);

        vm.prank(alice);
        bulls.transferFrom(alice, carol, aliceBull);

        // The bull moved, so the fight now spends CAROL's sequence.
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        assertEq(r.seqA, 0, "the new holder's sequence is the one that counts");
        _submitAs(carol, r);
        assertEq(duelC.fightSeq(carol), 1);
        assertEq(duelC.fightSeq(alice), 1, "the old holder's sequence stood still");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Nothing expires awkwardly
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice "an unsubmitted result simply lapses at `expiry` and the same
     *          sequence number is re-signed."
     */
    function test_anUnsubmittedResultLapsesAndTheSameSequenceIsReSigned() public {
        Duel.DuelResult memory stale = _newResult(aliceBull, bobBull, uint32(aliceBull));
        uint64 seqAtQuote = stale.seqA;

        vm.warp(stale.expiry + 1);

        _expectSubmitRevert(alice, stale, abi.encodeWithSelector(Duel.Expired.selector));

        // The lapse cost nothing: the wallet is exactly where it was.
        assertEq(duelC.fightSeq(alice), seqAtQuote, "a lapsed quote burned a sequence");
        assertEq(duelC.fightSeq(bob), stale.seqB);

        Duel.DuelResult memory fresh = _newResult(aliceBull, bobBull, uint32(aliceBull));
        assertEq(fresh.seqA, seqAtQuote, "the same sequence number is re-signed");
        _submit(fresh);
        assertEq(duelC.fightSeq(alice), seqAtQuote + 1);
    }

    /// @dev `block.timestamp > expiry` — so a result submitted in the very
    ///      second it expires still settles. An off-by-one the other way would
    ///      make every quote a second shorter than the UI promised.
    function test_expiryIsInclusive() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        vm.warp(r.expiry);
        _submit(r);
        assertEq(duelC.fightSeq(alice), 1);
    }

    /// @dev Any revert leaves the sequence alone, so a failed submit is never
    ///      a wasted quote.
    function test_aFailedFightDoesNotBurnTheSequence() public {
        // No stake funding at all: `_takeSide` refuses on the balance check.
        Duel.DuelResult memory r = _stakedResult(aliceBull, bobBull, uint32(aliceBull));

        _expectSubmitRevert(
            alice,
            r,
            abi.encodeWithSelector(
                Duel.StakeUnaffordable.selector, alice, address(bnbull), STAKE, uint256(0)
            )
        );

        assertEq(duelC.fightSeq(alice), 0, "a failed fight burned a sequence");
        assertEq(duelC.fightSeq(bob), 0);

        // ...and the very same quote works once the money is there.
        _fundForFight(alice, STAKE, 0);
        _fundForFight(bob, STAKE, 0);
        _submitAs(alice, r);
        assertEq(duelC.fightSeq(alice), 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The invariant, fuzzed
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice At most ONE signed result naming a given wallet can ever settle,
     *         whatever order the outstanding signatures arrive in.
     */
    function testFuzz_onlyOneSignatureNamingAWalletCanSettle(uint8 pick) public {
        _fundForFight(alice, STAKE, 0);
        _fundForFight(bob, STAKE, 0);
        _fundForFight(carol, STAKE, 0);

        Duel.DuelResult memory a = _stakedResult(aliceBull, bobBull, uint32(bobBull));
        Duel.DuelResult memory b = _stakedResult(aliceBull2, carolBull, uint32(carolBull));

        bool takeAFirst = pick % 2 == 0;
        Duel.DuelResult memory first = takeAFirst ? a : b;
        Duel.DuelResult memory second = takeAFirst ? b : a;

        _submitAs(alice, first);

        _expectSubmitRevert(
            alice, second, abi.encodeWithSelector(Duel.StaleFightSeq.selector, alice, 1, 0)
        );

        assertEq(duelC.fightSeq(alice), 1, "exactly one fight may have settled");
        assertEq(bnbull.balanceOf(alice), 0);
    }

    /// @dev A long run of fights walks the sequence up one at a time and never
    ///      skips or repeats.
    function test_theSequenceWalksUpOneAtATime() public {
        for (uint64 i = 0; i < 8; i++) {
            assertEq(duelC.fightSeq(alice), i);
            assertEq(duelC.fightSeq(bob), i);
            // Alternate the winner so neither bull ever reaches `lossesToDie`.
            // (5 since `DECISIONS.md §32`; alternating never reaches any value.)
            _fight(aliceBull, bobBull, uint32(i % 2 == 0 ? aliceBull : bobBull));
        }
        assertEq(duelC.fightSeq(alice), 8);
        assertEq(duelC.fightSeq(bob), 8);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev A live-sequence result with both sides staking BNBULL.
    function _stakedResult(uint256 tokenA, uint256 tokenB, uint32 winnerId)
        internal
        returns (Duel.DuelResult memory r)
    {
        r = _newResult(tokenA, tokenB, winnerId);
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = STAKE;
        r.stakeB = STAKE;
    }

    /**
     * @notice The LAUNCH death threshold is five consecutive losses, not three.
     *
     * @dev `DECISIONS.md §32`, owner call. Pinned as its own test because the
     *      rest of the suite reads `lossesToDie()` rather than a literal — which
     *      is correct, and also means every one of those tests would keep
     *      passing if the launch value silently drifted back to fefers' 3.
     *      This is the only assertion standing between that and a live deploy.
     *
     *      Fefers froze this at 3 by pinning its Duel with a one-time-set wire
     *      and then could not change it when 4 was asked for. Here the bound is
     *      real and the launch value is the one actually wanted.
     */
    function test_theLaunchDeathThresholdIsFiveConsecutiveLosses() public view {
        assertEq(duelC.lossesToDie(), 5, "DECISIONS 32: five losses kill, not three");
        assertGe(duelC.lossesToDie(), duelC.MIN_LOSSES_TO_DIE());
        assertLe(duelC.lossesToDie(), duelC.MAX_LOSSES_TO_DIE());
    }
}
