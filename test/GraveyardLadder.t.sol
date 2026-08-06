// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Duel} from "../contracts/Duel.sol";
import {Graveyard} from "../contracts/Graveyard.sol";

/**
 * @title GraveyardLadderTest
 * @notice PRIORITIES 6 and 7. The two ladders, permadeath, and the ONE revive
 *         counter.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      **The ladder is in dollars, and on BNB that needs an oracle.** The
 *      fefers Graveyard's comment reads "DOLLARS ONLY. Native amounts ARE
 *      dollars on Stable, so the ladder needs no oracle and no keeper peg."
 *      Every word of that is false here. `$50 / $200 / $500` are still the
 *      published numbers, but a dollar is no longer a unit of BNB, so each
 *      rung converts at PAY TIME through the Chainlink feed.
 *
 *      **`maxResurrects` is a BOUNDED SETTER, not a constant.** On fefers
 *      `MAX_RESURRECTS = 3` sat behind a one-time-set Graveyard slot and was
 *      frozen for the life of the collection. Here it moves inside
 *      `[1, MAX_RESURRECTS_CEILING]`, and both ladders are ARRAYS so a fourth
 *      life has a fourth price to charge for it.
 *
 *      **ONE COUNTER, NOT TWO (`DECISIONS.md §11`).** Founder tiers are gone,
 *      so `paidRevives` went with them: there is no code path that revives a
 *      bull without payment, so a second counter could only ever disagree with
 *      the first. `test_thereIsNoSecondReviveCounter` and
 *      `test_noEntrypointRevivesWithoutCharging` are that invariant, and
 *      `test_aZeroDollarPromoRungStillAdvancesTheLadder` is the case the
 *      two-counter version was ambiguous about.
 */
contract GraveyardLadderTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    uint256 internal constant USD_RUNG_1 = 50e18;
    uint256 internal constant USD_RUNG_2 = 200e18;
    uint256 internal constant USD_RUNG_3 = 500e18;
    uint256 internal constant USD_TAKEOVER_1 = 200e18;
    uint256 internal constant USD_TAKEOVER_2 = 500e18;
    uint256 internal constant USD_TAKEOVER_3 = 1_000e18;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
        _fundForRevive(alice);
        _fundForRevive(bob);
        _fundForRevive(carol);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The two ladders
    // ══════════════════════════════════════════════════════════════════════

    function test_thePublishedLaddersAreTheDeployedOnes() public view {
        uint256[] memory own = grave.ownerLadder();
        uint256[] memory take = grave.takeoverLadder();

        assertEq(own[0], USD_RUNG_1);
        assertEq(own[1], USD_RUNG_2);
        assertEq(own[2], USD_RUNG_3);
        assertEq(take[0], USD_TAKEOVER_1);
        assertEq(take[1], USD_TAKEOVER_2);
        assertEq(take[2], USD_TAKEOVER_3);

        // The mechanic: the holder always has the cheaper claim on their own
        // fighter, so the way to keep a bull is to pick it up first.
        for (uint256 i = 0; i < own.length; i++) {
            assertGt(take[i], own[i], "the takeover ladder must be dearer at every rung");
        }
    }

    function test_theOwnerLadderClimbsWithEveryLifeSpent() public {
        assertEq(grave.costFor(aliceBull), USD_RUNG_1);
        assertEq(grave.takeoverCostFor(aliceBull), USD_TAKEOVER_1);

        _killAndRevive(aliceBull);
        assertEq(grave.costFor(aliceBull), USD_RUNG_2);
        assertEq(grave.takeoverCostFor(aliceBull), USD_TAKEOVER_2);

        _killAndRevive(aliceBull);
        assertEq(grave.costFor(aliceBull), USD_RUNG_3);
        assertEq(grave.takeoverCostFor(aliceBull), USD_TAKEOVER_3);
    }

    /**
     * @notice A rung index past the end of a ladder reads the LAST rung.
     *
     * @dev So a ladder never has to be resized in lockstep with
     *      `maxResurrects`, and a new life can never end up priced at zero by
     *      omission — which on the takeover side would let anyone walk off
     *      with a dead bull for free.
     */
    function test_aRungPastTheEndOfTheLadderReadsTheLastRung() public {
        grave.setMaxResurrects(5);

        _killAndRevive(aliceBull);
        _killAndRevive(aliceBull);
        _killAndRevive(aliceBull);
        assertEq(grave.resurrectsUsed(aliceBull), 3);

        // The ladder only has three rungs; lives four and five read the third.
        assertEq(grave.costFor(aliceBull), USD_RUNG_3, "life four was not priced");
        assertEq(grave.takeoverCostFor(aliceBull), USD_TAKEOVER_3);

        _killAndRevive(aliceBull);
        assertEq(grave.costFor(aliceBull), USD_RUNG_3, "life five was not priced");
    }

    function test_bothLaddersReplaceAtOnceAndAreBounded() public {
        uint256[] memory own = new uint256[](2);
        own[0] = 10e18;
        own[1] = 20e18;
        uint256[] memory take = new uint256[](2);
        take[0] = 30e18;
        take[1] = 40e18;

        grave.setLadders(own, take);
        assertEq(grave.costFor(aliceBull), 10e18);
        assertEq(grave.takeoverCostFor(aliceBull), 30e18);

        // Every rung is bounded by the one true security ceiling.
        own[0] = grave.MAX_RESURRECTION_COST() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                Graveyard.CostTooHigh.selector,
                grave.MAX_RESURRECTION_COST() + 1,
                grave.MAX_RESURRECTION_COST()
            )
        );
        grave.setLadders(own, take);

        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(Graveyard.InvalidLadder.selector);
        grave.setLadders(empty, take);

        vm.prank(alice);
        vm.expectRevert();
        grave.setLadders(own, take);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Dollars, converted at pay time
    // ══════════════════════════════════════════════════════════════════════

    function test_rungsAreDollarsAndConvertAtPayTime() public {
        (uint256 bnbDue, uint256 bnbullDue, uint256 price) = grave.quotePayment(USD_RUNG_1);

        assertEq(price, BNB_USD_1E18);
        assertEq(bnbDue, _bnbDue(USD_RUNG_1), "$50 at $600/BNB");
        assertEq(bnbullDue, _bnbullDue(USD_RUNG_1), "the BNBULL leg carries the 10% discount");

        // BNB halves; the same $50 rung now costs twice the BNB.
        feed.setAnswer(300e8);
        (uint256 bnbDueAfter,, uint256 priceAfter) = grave.quotePayment(USD_RUNG_1);
        assertEq(priceAfter, 300e18);
        assertEq(bnbDueAfter, _ceilDiv(USD_RUNG_1 * 1e18, 300e18));
        // Ceil-then-double is not double-then-ceil; one wei of rounding is
        // the ladder rounding UP so an artefact can never undercharge a life.
        assertApproxEqAbs(bnbDueAfter, bnbDue * 2, 2, "the dollar sticker did not hold");

        // And the conversion that is charged is the one at PAY time.
        _killBull(aliceBull, bobBull);
        uint256 before = alice.balance;
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        assertEq(before - alice.balance, bnbDueAfter, "charged at the wrong price");
    }

    /// @dev `>=`, not `==`: the oracle moves between the wallet quoting and
    ///      the transaction landing, so insisting on equality would revert
    ///      honest revives on ordinary volatility. The surplus comes back.
    function test_theOracleCushionIsRefunded() public {
        _killBull(aliceBull, bobBull);
        uint256 due = _bnbDue(USD_RUNG_1);

        uint256 before = alice.balance;
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 3}(aliceBull);
        assertEq(before - alice.balance, due, "the cushion was kept");

        // A short payment is refused with both numbers in the error.
        _killBull(aliceBull, bobBull);
        uint256 due2 = _bnbDue(USD_RUNG_2);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.InsufficientBNB.selector, due2, due2 - 1)
        );
        grave.resurrectWithBNB{value: due2 - 1}(aliceBull);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  `maxResurrects` — a bounded setter, and what lowering it costs
    // ══════════════════════════════════════════════════════════════════════

    function test_maxResurrectsIsASetterAndItsBoundsHold() public {
        assertEq(grave.maxResurrects(), 3, "the launch value");
        assertEq(grave.MAX_RESURRECTS_CEILING(), 10);

        vm.expectEmit(false, false, false, true, address(grave));
        emit Graveyard.MaxResurrectsChanged(7);
        grave.setMaxResurrects(7);
        assertEq(grave.maxResurrects(), 7, "THE setter fefers could not have");

        // Permadeath has to stay reachable — a bull that can always come back
        // is a subscription.
        vm.expectRevert(abi.encodeWithSelector(Graveyard.ValueOutOfRange.selector, 0, 10));
        grave.setMaxResurrects(0);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.ValueOutOfRange.selector, 11, 10));
        grave.setMaxResurrects(11);

        vm.prank(alice);
        vm.expectRevert();
        grave.setMaxResurrects(4);
    }

    function test_theLivesRunOutAndTheNextDeathIsForever() public {
        _killAndRevive(aliceBull);
        _killAndRevive(aliceBull);
        _killAndRevive(aliceBull);
        assertEq(grave.resurrectsUsed(aliceBull), 3);

        _killBull(aliceBull, bobBull);

        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.costFor(aliceBull);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.takeoverCostFor(aliceBull);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);

        // No price brings it back, and no stranger can buy it either.
        _openTakeoverWindow(aliceBull);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.resurrectAndClaimWithBNB{value: 5 ether}(aliceBull);
    }

    /**
     * @notice ⚠ Lowering `maxResurrects` below a bull's spent count makes that
     *         bull permanently gone.
     *
     * @dev "That is a real consequence of a real setter, and it is the owner's
     *      call to make deliberately." Documented, so proved — including the
     *      part nobody should have to guess at: raising it again brings the
     *      bull back, because the check is a live comparison and not a
     *      one-way flag burned into the token.
     */
    function test_loweringMaxResurrectsBelowTheSpentCountIsPermadeath() public {
        _killAndRevive(aliceBull);
        _killAndRevive(aliceBull);
        assertEq(grave.resurrectsUsed(aliceBull), 2);
        assertEq(grave.costFor(aliceBull), USD_RUNG_3, "still revivable at rung three");

        grave.setMaxResurrects(1);

        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.costFor(aliceBull);

        (bool allowed, uint256 used,,,) = grave.quoteResurrect(aliceBull);
        assertFalse(allowed, "the UI would still offer a revive that cannot happen");
        assertEq(used, 2);

        _killBull(aliceBull, bobBull);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);

        // The mirror: it is a live comparison, so raising it undoes the
        // sentence. Nothing was burned into the token.
        grave.setMaxResurrects(3);
        assertEq(grave.costFor(aliceBull), USD_RUNG_3);
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        assertTrue(bulls.isAlive(aliceBull));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The 24-hour owner head start
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A bot cannot snipe a corpse the instant it hits the ground.
     */
    function test_theOwnerHeadStartIsEnforcedThenTheDoorOpens() public {
        _killBull(aliceBull, bobBull);
        uint64 died = bulls.diedAt(aliceBull);
        assertGt(died, 0, "the death was never stamped");

        uint256 opensAt = uint256(died) + 24 hours;
        (,,,, uint256 quotedOpensAt) = grave.quoteResurrect(aliceBull);
        assertEq(quotedOpensAt, opensAt, "the UI would show the wrong unlock time");

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.OwnerPriority.selector, aliceBull, opensAt)
        );
        grave.resurrectAndClaimWithBNB{value: 5 ether}(aliceBull);

        // One second before the door opens is still too early.
        vm.warp(opensAt - 1);
        _refreshPrices();
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.OwnerPriority.selector, aliceBull, opensAt)
        );
        grave.resurrectAndClaimWithBNB{value: 5 ether}(aliceBull);

        vm.warp(opensAt);
        _refreshPrices();
        vm.prank(carol);
        grave.resurrectAndClaimWithBNB{value: 5 ether}(aliceBull);

        assertEq(bulls.ownerOf(aliceBull), carol, "the claimer did not get the bull");
        assertTrue(bulls.isAlive(aliceBull), "the bull is standing but still dead");
    }

    function test_theHolderCanRescueTheirOwnBullDuringTheWindow() public {
        _killBull(aliceBull, bobBull);
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        assertEq(bulls.ownerOf(aliceBull), alice);
        assertTrue(bulls.isAlive(aliceBull));
    }

    function test_theWindowIsSettableAndBounded() public {
        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.ValueOutOfRange.selector, 30 days + 1, 30 days)
        );
        grave.setOwnerPriorityWindow(30 days + 1);

        // Zero opens takeovers the instant a bull dies.
        grave.setOwnerPriorityWindow(0);
        _killBull(aliceBull, bobBull);
        vm.prank(carol);
        grave.resurrectAndClaimWithBNB{value: 5 ether}(aliceBull);
        assertEq(bulls.ownerOf(aliceBull), carol);
    }

    function test_theHolderMayNotUseTheDearerDoor() public {
        _killBull(aliceBull, bobBull);
        _openTakeoverWindow(aliceBull);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.AlreadyOwner.selector, aliceBull));
        grave.resurrectAndClaimWithBNB{value: 5 ether}(aliceBull);
    }

    function test_aStrangerMayNotUseTheCheaperDoor() public {
        _killBull(aliceBull, bobBull);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.NotOwner.selector, aliceBull));
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
    }

    function test_aLivingBullCannotBeRevived() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.NotDead.selector, aliceBull));
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
    }

    /// @dev Both ladders spend the SAME finite pool of lives. Out of lives is
    ///      out of lives for everyone, holder and claimer alike.
    function test_bothLaddersSpendTheSameFiniteLives() public {
        _killAndRevive(aliceBull); // life 1, owner ladder
        assertEq(grave.resurrectsUsed(aliceBull), 1);

        _killBull(aliceBull, bobBull);
        _openTakeoverWindow(aliceBull);
        vm.prank(carol);
        grave.resurrectAndClaimWithBNB{value: 10 ether}(aliceBull); // life 2, takeover
        assertEq(grave.resurrectsUsed(aliceBull), 2, "a takeover did not burn a life");
        assertEq(bulls.ownerOf(aliceBull), carol);

        _killBull(aliceBull, bobBull);
        vm.prank(carol);
        grave.resurrectWithBNB{value: 10 ether}(aliceBull); // life 3
        assertEq(grave.resurrectsUsed(aliceBull), 3);

        _killBull(aliceBull, bobBull);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.resurrectWithBNB{value: 10 ether}(aliceBull);
    }

    /// @dev A revive clears the loss streak on the Duel, so a revived bull
    ///      does not die again on its very next loss.
    function test_aReviveClearsTheLossStreak() public {
        _killBull(aliceBull, bobBull);
        assertEq(duelC.consecutiveLosses(aliceBull), duelC.lossesToDie());

        vm.expectEmit(true, false, false, false, address(duelC));
        emit Duel.StreakReset(aliceBull);
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);

        assertEq(duelC.consecutiveLosses(aliceBull), 0, "the revived bull is one loss from death");
    }

    function test_theStreakHookIsGraveyardOnly() public {
        vm.prank(alice);
        vm.expectRevert(Duel.NotGraveyard.selector);
        duelC.resetStreak(aliceBull);
    }

    /**
     * @notice The graveyard UI read NEVER reverts and never touches the
     *         oracle — a UI must be able to render a corpse card while the
     *         feed is stale.
     */
    function test_quoteResurrectNeverRevertsAndNeverTouchesTheOracle() public {
        feed.setReadReverts(true);

        (bool allowed, uint256 used, uint256 ownerUsd, uint256 takeoverUsd, uint256 opensAt) =
            grave.quoteResurrect(aliceBull);
        assertTrue(allowed);
        assertEq(used, 0);
        assertEq(ownerUsd, USD_RUNG_1);
        assertEq(takeoverUsd, USD_TAKEOVER_1);
        assertEq(opensAt, 0, "a bull that never died has no unlock time");

        // ...but a quote that DOES need a price refuses rather than papering
        // over a bad one.
        vm.expectRevert();
        grave.quotePayment(USD_RUNG_1);

        // And an unminted token reads as a clean zero rather than reverting.
        (bool ok,,,,) = grave.quoteResurrect(999);
        assertTrue(ok);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ONE COUNTER, NOT TWO — `DECISIONS.md §11`
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice There is exactly one revive counter, and `paidRevives` does not
     *         exist.
     *
     * @dev Fefers carried both because a founder freebie had to cost a LIFE
     *      without costing a RUNG. Founder tiers are gone, so the second
     *      counter would be "a duplicated source of truth whose only possible
     *      future is to disagree with the first one".
     */
    function test_thereIsNoSecondReviveCounter() public {
        (bool ok,) =
            address(grave).staticcall(abi.encodeWithSignature("paidRevives(uint256)", aliceBull));
        assertFalse(ok, "paidRevives(uint256) exists; the two counters can now disagree");

        (ok,) = address(grave).staticcall(abi.encodeWithSignature("paidRevives()"));
        assertFalse(ok, "paidRevives() exists");

        // The one that does exist counts EVERY revive, from either ladder.
        assertEq(grave.resurrectsUsed(aliceBull), 0);
        _killAndRevive(aliceBull);
        assertEq(grave.resurrectsUsed(aliceBull), 1);
    }

    /**
     * @notice No entrypoint revives without charging. All six, enumerated.
     *
     * @dev This is the invariant that lets the second counter stay deleted: if
     *      any path here could revive for nothing, `resurrectsUsed` and a
     *      hypothetical `paidRevives` would immediately diverge and the owner
     *      ladder would quote the wrong rung.
     */
    function test_noEntrypointRevivesWithoutCharging() public {
        address broke = address(0xB204E);
        vm.deal(broke, 1 ether);
        _killBull(aliceBull, bobBull);
        _openTakeoverWindow(aliceBull);

        // Owner ladder. The holder is alice, so the takeover paths are the
        // ones a stranger can reach; both are covered below.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graveyard.InsufficientBNB.selector, _bnbDue(USD_RUNG_1), uint256(0)
            )
        );
        grave.resurrectWithBNB{value: 0}(aliceBull);

        vm.prank(alice);
        bnbull.approve(address(grave), 0);
        vm.prank(alice);
        vm.expectRevert();
        grave.resurrectWithBNBULL(aliceBull);

        // Takeover ladder, from a wallet with nothing.
        vm.prank(broke);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graveyard.InsufficientBNB.selector, _bnbDue(USD_TAKEOVER_1), uint256(0)
            )
        );
        grave.resurrectAndClaimWithBNB{value: 0}(aliceBull);

        vm.prank(broke);
        vm.expectRevert();
        grave.resurrectAndClaimWithBNBULL(aliceBull);

        // Four refusals later, nothing has been spent and nothing has stood up.
        assertEq(grave.resurrectsUsed(aliceBull), 0, "a life was spent by a failed revive");
        assertTrue(bulls.isDead(aliceBull), "the bull got up without paying");
        assertEq(bulls.ownerOf(aliceBull), alice, "the bull changed hands without payment");
    }

    /**
     * @notice A rung set to $0 as a promotion STILL advances the ladder.
     *
     * @dev The ambiguity the two-counter version had — "did that advance the
     *      ladder?" — has one obvious answer with one counter: yes, a life and
     *      a rung were both spent. Pinned here so a future promo cannot
     *      quietly hand out free lives.
     */
    function test_aZeroDollarPromoRungStillAdvancesTheLadder() public {
        uint256[] memory own = new uint256[](3);
        own[0] = 0; // the promo
        own[1] = USD_RUNG_2;
        own[2] = USD_RUNG_3;
        uint256[] memory take = new uint256[](3);
        take[0] = USD_TAKEOVER_1;
        take[1] = USD_TAKEOVER_2;
        take[2] = USD_TAKEOVER_3;
        grave.setLadders(own, take);

        _killBull(aliceBull, bobBull);
        assertEq(grave.costFor(aliceBull), 0);

        uint256 before = alice.balance;
        vm.expectEmit(true, true, false, true, address(grave));
        emit Graveyard.Resurrected(aliceBull, alice, 0, 0, 0, 1);
        vm.prank(alice);
        grave.resurrectWithBNB{value: 0}(aliceBull);

        assertEq(alice.balance, before, "a free rung must cost exactly nothing");
        assertTrue(bulls.isAlive(aliceBull));
        assertEq(grave.resurrectsUsed(aliceBull), 1, "the free life did not advance the ladder");
        assertEq(grave.costFor(aliceBull), USD_RUNG_2, "the next rung is the dear one");

        // ...and it still counts against permadeath.
        _killAndRevive(aliceBull);
        _killAndRevive(aliceBull);
        _killBull(aliceBull, bobBull);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.GoneForever.selector, aliceBull));
        grave.costFor(aliceBull);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  🔴 FINDING
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice 🔴 FINDING — `Bulls.rarityCostMult` AND
     *         `Bulls.computeResurrectionCost` ARE DEAD CODE. The Graveyard
     *         never calls either, so a legendary bull costs exactly the same
     *         to revive as a common one, and `setRarityCostMult` is a live,
     *         bounded, event-emitting owner setter that changes nothing.
     *
     * @dev `Bulls.sol` documents the opposite in two places:
     *
     *        `uint16[6] public rarityCostMult`
     *          "Owner-settable within MAX_RARITY_MULT; **the Graveyard reads
     *           it through `computeResurrectionCost`**."
     *
     *        `computeResurrectionCost`
     *          "Rarity-scaled resurrection cost: `baseCost x rarityCostMult`.
     *           **The Graveyard supplies the base** and this returns the
     *           scaled figure for a given bull."
     *
     *      It does not. `Graveyard._revive` reads `_rung(ladder, used)` and
     *      charges that flat number; `computeResurrectionCost` has no caller
     *      anywhere in `contracts/`. So either the NFT's documented pricing
     *      never happens, or the table is vestigial and its docs and setter
     *      should go.
     *
     *      WHY IT MATTERS BEYOND TIDINESS. This is a live setter with a hard
     *      bound, its own error and its own event — every signal a reader has
     *      that it does something. An owner re-balancing the ladder would
     *      reasonably call `setRarityCostMult(4, 200)`, watch
     *      `RarityCostMultChanged` land, and believe legendary revives now
     *      cost 200x. They cost exactly the same as before. It is also a
     *      one-way trap if it is ever WIRED UP later: at the launch defaults
     *      `[1, 3, 10, 30, 100, 500]`, a $50 rung becomes $25,000 for the king
     *      — far above `MAX_RESURRECTION_COST` (5,000), which bounds the RUNG
     *      and not the scaled figure, so the ceiling that looks like it
     *      protects players would not.
     *
     *      Whichever way it is resolved, it should be resolved deliberately:
     *      wire it into `_revive` (and then bound the SCALED cost), or delete
     *      the multiplier, the setter and the two NatSpec claims.
     *
     *      ⚠ THIS TEST ASSERTS THE CURRENT (FLAT) BEHAVIOUR so the suite stays
     *      green while the finding is on record. INVERT IT IF THE MULTIPLIER
     *      IS EVER WIRED IN.
     */
    function test_FINDING_theRarityCostMultiplierIsNeverAppliedToARevive() public {
        (uint256 commonBull, uint256 rareBull) = _twoBullsOfDifferentTiers();
        uint8 rareTier = bulls.rarityOf(rareBull);

        // The NFT says a rarer bull is dearer...
        assertGt(
            bulls.computeResurrectionCost(rareBull, USD_RUNG_1),
            bulls.computeResurrectionCost(commonBull, USD_RUNG_1),
            "the multiplier table is flat; pick a different pair"
        );

        // ...and the Graveyard charges both of them the same flat rung.
        assertEq(grave.costFor(commonBull), USD_RUNG_1);
        assertEq(grave.costFor(rareBull), USD_RUNG_1, "the rarity multiplier reached the ladder");
        assertEq(grave.takeoverCostFor(rareBull), USD_TAKEOVER_1);

        // Paid, end to end, at the common price.
        _fundForRevive(alice);
        _killBull(rareBull, bobBull);
        uint256 before = alice.balance;
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(rareBull);
        assertEq(before - alice.balance, _bnbDue(USD_RUNG_1), "a legendary revive is not scaled");

        // And the setter that looks like it prices lives is inert.
        bulls.setRarityCostMult(rareTier, 1_000);
        assertEq(
            bulls.computeResurrectionCost(rareBull, USD_RUNG_1),
            USD_RUNG_1 * 1_000,
            "the view moved, as it should"
        );
        assertEq(grave.costFor(rareBull), USD_RUNG_2, "...but the ladder never looked at it");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Wiring the revive depends on
    // ══════════════════════════════════════════════════════════════════════

    function test_aReviveNeedsTheDuelWired() public {
        Graveyard fresh = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        fresh.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));

        _killBull(aliceBull, bobBull);
        vm.prank(alice);
        vm.expectRevert(Graveyard.DuelNotWired.selector);
        fresh.resurrectWithBNB{value: 5 ether}(aliceBull);
    }

    function test_pausingStopsRevives() public {
        _killBull(aliceBull, bobBull);
        grave.pause();
        vm.prank(alice);
        vm.expectRevert();
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);

        grave.unpause();
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _killAndRevive(uint256 tokenId) internal {
        _killBull(tokenId, bobBull);
        address holder = bulls.ownerOf(tokenId);
        vm.prank(holder);
        grave.resurrectWithBNB{value: 5 ether}(tokenId);
    }

    /// @dev Mint until a common (tier 0) and a rare-or-better (tier >= 2) bull
    ///      have both come out of the shuffle.
    function _twoBullsOfDifferentTiers()
        internal
        returns (uint256 commonBull, uint256 rareBull)
    {
        for (uint256 i = 0; i < 80 && (commonBull == 0 || rareBull == 0); i++) {
            uint256 id = _mintBull(alice);
            uint8 tier = bulls.rarityOf(id);
            if (tier == 0 && commonBull == 0) commonBull = id;
            else if (tier >= 2 && rareBull == 0) rareBull = id;
        }
        assertGt(commonBull, 0, "no common bull in 80 mints");
        assertGt(rareBull, 0, "no rare bull in 80 mints");
    }

    /// @dev Warp past the holder's exclusive window and republish the prices
    ///      the warp just made stale.
    function _openTakeoverWindow(uint256 tokenId) internal {
        uint64 died = bulls.diedAt(tokenId);
        vm.warp(uint256(died) + grave.ownerPriorityWindow() + 1);
        _refreshPrices();
    }
}
