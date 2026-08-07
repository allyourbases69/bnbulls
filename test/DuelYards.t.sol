// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Duel} from "../contracts/Duel.sol";
import {Yards} from "../contracts/Yards.sol";
import {TimelockedAddress} from "../contracts/lib/TimelockedAddress.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DuelYardsTest
 * @notice THE CONSENT GATE. A bull may only be fought while its CURRENT owner
 *         has put it in the yards, and its owner may take it back out.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      What this suite is really defending, in one sentence: before `Yards`,
 *      arena membership WAS the ERC-20 allowance — wallet-wide, and skipped
 *      entirely by a zero-stake duel, which still killed bulls. Both halves are
 *      reproduced here as attacks, not as assertions about flags.
 *
 *      The subtle half is the anti-dodge property, and it gets more tests than
 *      the feature itself does. An eject that took effect instantly would be
 *      strictly WORSE than no eject at all: `winnerId` is visible in the public
 *      mempool, so a losing side would front-run the submission and delete the
 *      loss. Every test below that warps a clock is testing that a fight
 *      already signed still lands.
 */
contract DuelYardsTest is DuelGraveyardBase {
    Yards internal yards;

    uint256 internal aliceBull;
    uint256 internal bobBull;
    uint256 internal carolBull;

    /// @notice `MAX_DUEL_EXPIRY_SECONDS` in `frontend/src/lib/serverEnv.ts`.
    ///         The eject floor is pinned to it — see the test at the bottom.
    uint64 internal constant SIGNER_MAX_TTL_SECONDS = 900;

    function setUp() public override {
        super.setUp();

        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
        carolBull = _mintBull(carol);

        yards = new Yards(owner, address(bulls));
        duelC.bootstrapWire(Duel.Wire.Yards, address(yards));
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _enter(address who, uint256 id) internal {
        vm.prank(who);
        yards.enter(_one(id));
    }

    function _eject(address who, uint256 id) internal {
        vm.prank(who);
        yards.eject(_one(id));
    }

    /// @dev Put both fighters in the yards, which is the ordinary state of the
    ///      world for every OTHER Duel suite (they leave `Wire.Yards` unwired).
    function _bothIn() internal {
        _enter(alice, aliceBull);
        _enter(bob, bobBull);
    }

    function _notInYards(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Duel.BullNotInYards.selector, id);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The default is OUT
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev THE DECISION, asserted. A bull nobody has touched is not fightable.
     *      `DECISIONS.md §14` / `§25`: the transaction nobody sent must leave
     *      the SAFE state, and the dangerous one must cost somebody a
     *      deliberate action.
     */
    function test_aFreshlyMintedBullIsNotInTheYards() public view {
        assertFalse(yards.inYards(aliceBull), "a new bull is out until its owner says otherwise");
        assertFalse(yards.inYards(bobBull));
        (address by, uint64 leavesAt, bool live) = yards.statusOf(aliceBull);
        assertEq(by, address(0));
        assertEq(leavesAt, 0);
        assertFalse(live);
    }

    function test_theYardsAreEmptyUntilSomebodyEnters() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _expectSubmitRevert(alice, r, _notInYards(aliceBull));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ⚠ THE HOLE: the zero-stake path never touched an allowance
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev THE HEADLINE. Reproduces the whole attack the allowance gate could
     *      not see, end to end.
     *
     *      `Duel._takeSide` returns on `stake == 0` BEFORE it reads
     *      `balanceOf`/`allowance`, so a duel with `assetA == assetB ==
     *      address(0)` and zero stakes touches nothing the victim controls. It
     *      earns no jackpot ticket (`DECISIONS.md §25` closed that) — but it
     *      still runs `applyDuelResult`, still increments `consecutiveLosses`,
     *      and the `lossesToDie`-th consecutive loss KILLS THE BULL.
     *
     *      Half A proves the grind is dead while the bull is out of the yards.
     *      Half B proves it was never blocked by anything else: with the same
     *      wallet, the same signer and the same zero stakes, entering the
     *      yards is the ONLY change needed for all five losses to land and the
     *      bull to die. So the gate is doing the work, not some other check.
     */
    function test_FINDING_aZeroStakeDuelCouldGrindAnUnwillingBullToDeath() public {
        // The victim (bob) has never approved anything and never will.
        assertEq(bnbull.allowance(bob, address(duelC)), 0, "no allowance anywhere");

        _enter(alice, aliceBull);

        // ── half A: out of the yards, the grind cannot start.
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        assertEq(r.stakeA, 0);
        assertEq(r.stakeB, 0);
        assertEq(r.assetA, address(0));
        _expectSubmitRevert(alice, r, _notInYards(bobBull));

        assertEq(duelC.consecutiveLosses(bobBull), 0, "not one free loss landed");
        assertTrue(bulls.isAlive(bobBull));

        // ── half B: the ONLY change is that bob volunteers. Now it works, and
        // that is what makes half A a real defence rather than a coincidence.
        _enter(bob, bobBull);
        uint8 n = duelC.lossesToDie();
        for (uint8 i = 0; i < n; i++) {
            _fight(aliceBull, bobBull, uint32(aliceBull));
        }
        assertTrue(bulls.isDead(bobBull), "five losses and it's sausages");
        assertEq(potBnbull.ticketCount(), 0, "and still no free jackpot ticket (S25)");
    }

    function test_anEjectedBullCannotBeFoughtOnTheZeroStakePath() public {
        _bothIn();
        _eject(bob, bobBull);
        vm.warp(block.timestamp + yards.ejectDelay() + 1);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _expectSubmitRevert(alice, r, _notInYards(bobBull));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The staked path
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev The gate is not a stand-in for the allowance check, it is upstream
     *      of it: bob here HAS the balance and HAS approved (`_newStakedResult`
     *      funds both sides), so the only thing refusing the fight is the
     *      yards. A wallet that approved once to fight one bull has not
     *      volunteered the rest of its stack.
     */
    function test_anEjectedBullCannotBeFoughtOnTheStakedPath() public {
        _bothIn();

        Duel.DuelResult memory r =
            _newStakedResult(aliceBull, bobBull, uint32(aliceBull), STAKE_BNBULL);
        assertGe(
            bnbull.allowance(bob, address(duelC)), STAKE_BNBULL, "bob is approved and solvent"
        );

        _eject(bob, bobBull);
        vm.warp(block.timestamp + yards.ejectDelay() + 1);

        uint256 before = bnbull.balanceOf(bob);
        _expectSubmitRevert(alice, r, _notInYards(bobBull));

        assertEq(bnbull.balanceOf(bob), before, "no stake pulled");
        assertEq(duelC.fightSeq(bob), 0, "no sequence consumed");
        assertEq(duelC.fightSeq(alice), 0);
    }

    /// @dev BOTH sides, not just the passive one. The aggressor has to be in
    ///      the yards too, or "I fight, you cannot" would be a strategy.
    function test_theAggressorMustBeInTheYardsAsWell() public {
        _enter(bob, bobBull);
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _expectSubmitRevert(alice, r, _notInYards(aliceBull));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ⚠ NO DODGING — the eject is delayed on purpose
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev THE ANTI-GRIEFING TEST, and the reason `eject` is not instant.
     *
     *      The scenario is exactly the front-run: bob is about to LOSE a funded
     *      fight, the signed result is already in hand, and bob ejects before
     *      it is submitted. The fight still settles, bob still pays, bob's bull
     *      still takes the loss. "Haven't paid the money" is decided by the
     *      clock, not by whether the transaction has landed yet.
     */
    function test_anInFlightFundedFightStillSettlesAfterAnEject() public {
        _bothIn();

        Duel.DuelResult memory r =
            _newStakedResult(aliceBull, bobBull, uint32(aliceBull), STAKE_BNBULL);
        bytes memory sig = _sign(r);

        // Bob sees the losing result coming and bails. This is the dodge.
        _eject(bob, bobBull);
        assertTrue(yards.inYards(bobBull), "still in until the delay elapses");

        uint256 bobBefore = bnbull.balanceOf(bob);
        vm.prank(alice);
        duelC.submitDuel(r, sig);

        assertEq(bnbull.balanceOf(bob), bobBefore - STAKE_BNBULL, "the money was paid");
        assertEq(duelC.consecutiveLosses(bobBull), 1, "and the loss was taken");
    }

    /// @dev The same signature, one second past the departure. The gate is
    ///      absolute once it bites — note the harness signs a ONE HOUR expiry,
    ///      far longer than the signer's 900-second ceiling, so this proves the
    ///      on-chain refusal rather than relying on expiry to do the work.
    function test_theEjectBitesOnceTheDelayElapses() public {
        _bothIn();
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r);

        _eject(bob, bobBull);
        vm.warp(block.timestamp + yards.ejectDelay());
        assertFalse(yards.inYards(bobBull), "leavesAt is inclusive of the boundary");

        vm.prank(alice);
        vm.expectRevert(_notInYards(bobBull));
        duelC.submitDuel(r, sig);
    }

    /**
     * @dev THE NUMBER THAT MAKES THE DODGE IMPOSSIBLE RATHER THAN MERELY
     *      AWKWARD, pinned. `MIN_EJECT_DELAY` is the signer's
     *      `MAX_DUEL_EXPIRY_SECONDS`, so no signature can outlive an eject
     *      request. If that TTL ceiling is ever raised in `serverEnv.ts`, this
     *      test is what fails.
     */
    function test_theEjectFloorMatchesTheSignersSignatureCeiling() public view {
        assertEq(
            yards.MIN_EJECT_DELAY(),
            SIGNER_MAX_TTL_SECONDS,
            "raise DUEL TTL and you must raise this floor with it"
        );
        assertGe(yards.ejectDelay(), yards.MIN_EJECT_DELAY(), "the launch value clears the floor");
    }

    function test_setEjectDelayIsBoundedBothWays() public {
        vm.expectRevert(abi.encodeWithSelector(Yards.EjectDelayOutOfRange.selector, uint64(899)));
        yards.setEjectDelay(899);

        vm.expectRevert(
            abi.encodeWithSelector(Yards.EjectDelayOutOfRange.selector, uint64(24 hours + 1))
        );
        yards.setEjectDelay(24 hours + 1);

        yards.setEjectDelay(1 hours);
        assertEq(yards.ejectDelay(), 1 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        yards.setEjectDelay(1 hours);
    }

    /// @dev A departure is an absolute timestamp stamped when `eject` ran, so a
    ///      compromised owner key cannot lengthen the delay and trap bulls that
    ///      are already leaving.
    function test_raisingTheDelayDoesNotExtendADepartureAlreadyScheduled() public {
        _bothIn();
        _eject(bob, bobBull);
        (, uint64 leavesAt,) = yards.statusOf(bobBull);

        yards.setEjectDelay(24 hours);
        (, uint64 after_,) = yards.statusOf(bobBull);
        assertEq(after_, leavesAt, "the stamp does not move");

        vm.warp(leavesAt);
        assertFalse(yards.inYards(bobBull), "and it still leaves on time");
    }

    /// @dev The mirror image: a second `eject` must never push an earlier
    ///      departure back, which would silently re-enter a bull that had
    ///      already left.
    function test_aSecondEjectCannotPushAnEarlierDepartureBack() public {
        _bothIn();
        _eject(bob, bobBull);
        (, uint64 first,) = yards.statusOf(bobBull);

        vm.warp(block.timestamp + first + 10 minutes);
        assertFalse(yards.inYards(bobBull), "gone");

        _eject(bob, bobBull);
        (, uint64 second,) = yards.statusOf(bobBull);
        assertEq(second, first, "the departure did not move");
        assertFalse(yards.inYards(bobBull), "and the bull is still gone");
    }

    /// @dev Re-entering DOES cancel a pending eject, and that is safe: it can
    ///      only ever make the bull more available, so it ducks nothing.
    function test_reEnteringCancelsAPendingEject() public {
        _bothIn();
        _eject(bob, bobBull);
        (, uint64 leavesAt,) = yards.statusOf(bobBull);
        assertGt(leavesAt, 0);

        _enter(bob, bobBull);
        (, uint64 cleared,) = yards.statusOf(bobBull);
        assertEq(cleared, 0, "the departure is cancelled");

        vm.warp(block.timestamp + 2 days);
        assertTrue(yards.inYards(bobBull), "and stays cancelled");
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.consecutiveLosses(bobBull), 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Batching, and who may speak for a bull
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A holder with a stack sends ONE transaction, not twenty. This is
    ///      the reason the default of OUT is affordable at all.
    function test_enterAndEjectAreBatched() public {
        uint256 second = _mintBull(alice);
        uint256 third = _mintBull(alice);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (aliceBull, second, third);

        vm.prank(alice);
        yards.enter(ids);

        bool[] memory inNow = yards.inYardsMany(ids);
        assertTrue(inNow[0] && inNow[1] && inNow[2], "one tx, three bulls in");

        vm.prank(alice);
        yards.eject(ids);
        vm.warp(block.timestamp + yards.ejectDelay());

        inNow = yards.inYardsMany(ids);
        assertFalse(inNow[0] || inNow[1] || inNow[2], "one tx, three bulls out");
    }

    /// @dev A batch either applies whole or not at all — a half-applied roster
    ///      is worse than a rejected one, because the player has to diff it to
    ///      find out what happened.
    function test_aBatchWithSomebodyElsesBullRevertsWhole() public {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (aliceBull, bobBull);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Yards.NotTokenOwner.selector, bobBull));
        yards.enter(ids);

        assertFalse(yards.inYards(aliceBull), "not even the one she does own");
    }

    /// @dev Checked against LIVE `ownerOf`, never a stored owner, and never an
    ///      approval: an operator being able to volunteer somebody's bull for
    ///      combat is the whole hazard restated.
    function test_onlyTheLiveOwnerMaySpeakForABull() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Yards.NotTokenOwner.selector, aliceBull));
        yards.enter(_one(aliceBull));

        _enter(alice, aliceBull);

        vm.prank(alice);
        bulls.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Yards.NotTokenOwner.selector, aliceBull));
        yards.eject(_one(aliceBull));

        // The contract owner has no special power here either.
        vm.expectRevert(abi.encodeWithSelector(Yards.NotTokenOwner.selector, aliceBull));
        yards.enter(_one(aliceBull));
    }

    function test_emptyBatchesRevert() public {
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(Yards.EmptyBatch.selector);
        yards.enter(none);

        vm.prank(alice);
        vm.expectRevert(Yards.EmptyBatch.selector);
        yards.eject(none);
    }

    /// @dev Ejecting a bull that is already out is a no-op, not a revert: a
    ///      holder pulling their whole stack must not have the transaction fail
    ///      because three of them had never been entered.
    function test_ejectingABullThatIsNotInTheYardsIsANoOp() public {
        _eject(alice, aliceBull);
        (address by, uint64 leavesAt,) = yards.statusOf(aliceBull);
        assertEq(by, address(0));
        assertEq(leavesAt, 0, "nothing was stamped");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ⚠ A TRANSFER TAKES A BULL OUT — the decision, tested
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev THE CHOSEN SEMANTICS, and it diverges from fefers on purpose.
     *      Fefers' `ArenaOptOut` keeps the seller's standing choice ("a bought
     *      warrior carries its previous owner's explicit choice"). Here the
     *      entry is bound to `enteredBy == the live owner`, so it lapses the
     *      instant the bull moves — no ERC-721 hook, no per-transfer gas, and
     *      no window in which a buyer holds a fightable bull they never
     *      volunteered.
     */
    function test_aTransferTakesABullStraightOutOfTheYards() public {
        _bothIn();
        assertTrue(yards.inYards(bobBull));

        vm.prank(bob);
        bulls.transferFrom(bob, carol, bobBull);

        assertFalse(yards.inYards(bobBull), "the entry lapsed with the transfer");
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _expectSubmitRevert(alice, r, _notInYards(bobBull));
    }

    /// @dev And the new owner has to say so themselves. One extra transaction,
    ///      which is the price of not inheriting a stranger's instruction to
    ///      fight.
    function test_theNewOwnerMustEnterTheBullThemselves() public {
        _bothIn();
        vm.prank(bob);
        bulls.transferFrom(bob, carol, bobBull);

        _enter(carol, bobBull);
        assertTrue(yards.inYards(bobBull));
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.consecutiveLosses(bobBull), 1);
    }

    /**
     * @dev ⚠ THE ONE HONEST CONSEQUENCE, asserted rather than hidden: a bull
     *      sold and later bought BACK is in the yards again without a new
     *      transaction, because the stored entry matches the live owner once
     *      more. It is that wallet's own standing instruction being honoured
     *      and it can affect nobody else — the alternative is the transfer hook
     *      this design exists to avoid.
     */
    function test_aBullBoughtBackByItsOriginalEntrantIsInTheYardsAgain() public {
        _bothIn();
        vm.prank(bob);
        bulls.transferFrom(bob, carol, bobBull);
        assertFalse(yards.inYards(bobBull));

        vm.prank(carol);
        bulls.transferFrom(carol, bob, bobBull);
        assertTrue(yards.inYards(bobBull), "bob's own standing instruction, still standing");
    }

    /// @dev A transfer cannot be used to dodge either — same shape as the
    ///      eject, and here it is `enteredBy` doing the work rather than a
    ///      clock, so it is worth proving the two do not interact badly: the
    ///      fight was signed against bob, bob dumps the bull, and the duel is
    ///      refused. That is a lost fight for the AGGRESSOR, not an escaped
    ///      loss for bob: `Duel` re-reads `ownerOf`, so the stake and the
    ///      streak would have followed the bull to carol anyway.
    function test_aTransferOutOfTheYardsRefusesAnAlreadySignedFight() public {
        _bothIn();
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r);

        vm.prank(bob);
        bulls.transferFrom(bob, carol, bobBull);

        vm.prank(alice);
        vm.expectRevert(_notInYards(bobBull));
        duelC.submitDuel(r, sig);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Wiring
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev ⚠ THE DEPLOY OBLIGATION, written down as a test because it is the
     *      one way this whole feature silently does nothing: an unwired slot
     *      means no check, exactly like `marketplace`. Every OTHER Duel suite
     *      in this repo leaves it unwired, which is why they still pass — and
     *      why `script/` must bootstrap it before the first duel is signed.
     */
    function test_anUnwiredYardsSlotLeavesEveryDuelUngated() public {
        Duel fresh = _newDuel(address(bulls));
        assertEq(fresh.yardsContract(), address(0), "unwired by default");

        // Same collection, same signer, nobody in the yards — and it settles.
        // That is the state to avoid on deploy day.
        bulls.proposeWire(Bulls.Wire.Duel, address(fresh));
        vm.warp(block.timestamp + bulls.wiringDelay());
        bulls.commitWire(Bulls.Wire.Duel);

        _submitOn(fresh, bulls, _newResultOn(fresh, bulls, aliceBull, bobBull, uint32(aliceBull)));
        assertEq(fresh.consecutiveLosses(bobBull), 1, "ungated, exactly as documented");
    }

    /**
     * @dev A slot pointed at a WALLET degrades to "no check" instead of
     *      bricking every duel in the game. `fightBlocked` returns a value, so
     *      solc emits an `extcodesize` check before the call and a bare address
     *      would revert `submitDuel` for everybody until the timelock could be
     *      walked — the trap `_rollOnePool` documents on the ticket leg.
     */
    function test_aYardsSlotPointedAtAWalletDegradesRatherThanBricking() public {
        address notAContract = address(0xDEADBEEF);
        assertEq(notAContract.code.length, 0);

        duelC.proposeWire(Duel.Wire.Yards, notAContract);
        vm.warp(block.timestamp + duelC.wiringDelay());
        duelC.commitWire(Duel.Wire.Yards);

        // Nobody is in the yards, and the duel still settles — degraded, not
        // dead. Recoverable by re-proposing a real Yards.
        _fight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(duelC.consecutiveLosses(bobBull), 1);
    }

    /**
     * @dev The slot is TIMELOCKED, not a plain setter. An eject a single
     *      compromised-key transaction could switch off for the whole
     *      collection would not be a guarantee — and unlike `marketplace`,
     *      there is no liveness case for a plain setter here, because
     *      `Yards.fightBlocked` touches storage only and cannot revert.
     */
    function test_theYardsWireIsTimelockedNotAPlainSetter() public {
        Yards other = new Yards(owner, address(bulls));

        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, address(yards))
        );
        duelC.bootstrapWire(Duel.Wire.Yards, address(other));

        uint64 eta = duelC.proposeWire(Duel.Wire.Yards, address(other));
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockedAddress.TimelockNotElapsed.selector, eta, uint64(block.timestamp)
            )
        );
        duelC.commitWire(Duel.Wire.Yards);

        assertEq(duelC.yardsContract(), address(yards), "still the old one, publicly");

        vm.warp(eta);
        duelC.commitWire(Duel.Wire.Yards);
        assertEq(duelC.yardsContract(), address(other));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The views the UI and the signer read
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The read the API uses to refuse a quote MUST agree with the read
    ///      `Duel` uses to refuse a settlement, or the site offers fights that
    ///      revert. Same function underneath; this pins that.
    function test_theViewsAgreeWithTheEnforcement() public {
        _bothIn();
        assertEq(yards.fightBlocked(aliceBull, alice, bobBull, bob), 0, "both in");

        _eject(bob, bobBull);
        assertEq(yards.fightBlocked(aliceBull, alice, bobBull, bob), 0, "still in, mid-delay");
        vm.warp(block.timestamp + yards.ejectDelay());
        assertEq(yards.fightBlocked(aliceBull, alice, bobBull, bob), bobBull);
        assertEq(yards.fightBlocked(bobBull, bob, aliceBull, alice), bobBull, "first offender");
    }

    /// @dev `enteredBy` is zero for every bull nobody entered, so a zero owner
    ///      must not match the whole collection.
    function test_aZeroOwnerNeverReadsAsInTheYards() public view {
        assertFalse(yards.inYardsFor(aliceBull, address(0)));
        assertEq(yards.fightBlocked(aliceBull, address(0), bobBull, address(0)), aliceBull);
    }

    function test_statusOfRendersTheLeavingCountdown() public {
        _enter(bob, bobBull);
        _eject(bob, bobBull);

        (address by, uint64 leavesAt, bool live) = yards.statusOf(bobBull);
        assertEq(by, bob);
        assertEq(leavesAt, uint64(block.timestamp) + yards.ejectDelay());
        assertTrue(live, "leaving, but still fightable: show the countdown");
    }
}
