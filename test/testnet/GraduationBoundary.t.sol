// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestnetDexBase} from "./TestnetDexBase.t.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

import {Bulls} from "../../contracts/Bulls.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";
import {MintBnbullSplitter} from "../../contracts/MintBnbullSplitter.sol";
import {PotSplitter} from "../../contracts/lib/PotSplitter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";
import {MockDuel} from "../mocks/Hostile.sol";

/**
 * @title GraduationBoundaryTest
 * @notice **The pre/post-graduation scenarios the owner asked for, in his own
 *         words (`DECISIONS.md §46`):** *"we want the pots working
 *         pre-migration, we want auto buying working, everything. and you must
 *         test the pre and post migration scenarios."*
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT THIS ADDS THAT `LifecycleE2E` DOES NOT
 *      ══════════════════════════════════════════════════════════════════════
 *      `LifecycleE2E` proves the MONEY half of the boundary: legs defer on the
 *      curve, the pair appears, the accrued bucket sweeps into the pot. It stops
 *      there — no ticket is ever opened and nothing is ever paid out.
 *
 *      §47 closed the migration question ("graduation needs NO pot migration —
 *      the ERC-20 address is identical on both sides, so pot-held BNBULL is in
 *      exactly the position of wallet-held BNBULL") and then recorded what was
 *      still owed:
 *
 *        "still owed and worth doing regardless: the pre/post-graduation test —
 *         pots funding, auto-buying, tickets opening and A WIN PAYING, across
 *         the graduation boundary. The testnet run already proved the money
 *         half of this; **the win-paying half is blocked on VRF fulfilment.**"
 *
 *      It is blocked on a LIVE testnet, where nobody controls when Chainlink
 *      answers. It is not blocked here: `MockVRFCoordinator` is fulfilled by
 *      hand, so the deciding word arrives exactly when the scenario wants it —
 *      including *across* the boundary, with a request in flight while the
 *      venue changes underneath it.
 *
 *      Everything else is real: the etched PancakeSwap v2 factory/router/WBNB
 *      of chain 97, the real constant-product maths, and the real `Jackpot`,
 *      `MintDrop` and splitter bytecode.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE FOUR CLAIMS
 *      ══════════════════════════════════════════════════════════════════════
 *        1. PRE  — the game is fully playable on the curve. The BNB pot funds
 *                  from block one, takes tickets, and PAYS.
 *        2. PRE  — the BNBULL pot takes tickets while it is empty, resolves them
 *                  without reverting, and ⚠ does NOT burn the duel's
 *                  exclusivity claim doing it.
 *        3. CROSS— a ticket opened on the curve, against an EMPTY pot, is paid
 *                  in real BNBULL after graduation + sweep. Nothing is stranded
 *                  by the boundary, and no pot ever moved.
 *        4. POST — both pots fund INLINE with no keeper, and both pay, with the
 *                  one-pot-per-duel lock still holding.
 */
contract GraduationBoundaryTest is TestnetDexBase {
    /// @dev Same raise as `LifecycleE2E`: 2 BNB leaves 1.96 WBNB in the pool, a
    ///      book deep enough that a sweep is a trade rather than a price event.
    uint256 internal constant RAISE = 2 ether;

    /// @dev A real v2.5 key hash shape. `Jackpot` only checks it is non-zero.
    bytes32 internal constant KEY_HASH =
        0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77739083fd299aa9e9cff;

    MockBnbull internal bnbull;
    Bulls internal bulls;
    Jackpot internal potBnbull;
    Jackpot internal potBnb;
    MintDrop internal drop;
    MintBnbullSplitter internal splitter;
    MockAggregator internal feed;
    MockVRFCoordinator internal coord;
    MockDuel internal duel;

    address internal treasury = address(0x7EA5);
    address internal lpTreasury = address(0x1B7EA5);
    address internal keeper = address(0xCEE9E2);

    function setUp() public override {
        super.setUp();

        bnbull = _launchDefault(RAISE);

        feed = new MockAggregator(8, 600e8);
        coord = new MockVRFCoordinator();
        duel = new MockDuel();
        bulls = new Bulls(address(this), 0xB011, bytes32(0));

        potBnbull = new Jackpot(address(bnbull), address(0), address(coord), 50);
        potBnb = new Jackpot(WBNB, address(0), address(coord), 100);

        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: address(this),
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        drop.bootstrapWire(MintDrop.Wire.Router, V2_ROUTER);
        drop.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        drop.setKeeper(keeper);

        splitter = new MintBnbullSplitter(address(this), WBNB, keeper);
        splitter.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
        splitter.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(potBnbull));
        splitter.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        splitter.bootstrapWire(PotSplitter.Wire.MintDrop, address(drop));
        // ⚠ `LifecycleE2E` leaves this slot UNWIRED and declares the resulting
        //   hole in its own header: "`PotSplitter.sweepBnbullPot` swapping
        //   through the real router is NOT asserted here. It cannot be until the
        //   v2 migration lands." **That migration has landed** — `PotSplitter`
        //   now calls `swapExactTokensForTokensSupportingFeeOnTransferTokens` on
        //   IPancakeRouter02 and the v3 dialect is gone (§28). So the slot is
        //   wired here and the gap is closed below.
        splitter.bootstrapWire(PotSplitter.Wire.Router, V2_ROUTER);

        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);
        potBnbull.setFunder(address(splitter), true);
        potBnb.setFunder(address(splitter), true);

        // ── The half `LifecycleE2E` never wires: tickets and randomness ────
        potBnbull.bootstrapDuel(address(duel));
        potBnb.bootstrapDuel(address(duel));
        potBnbull.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        potBnb.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev Search for a VRF word that makes ticket `id` a WINNER on `pot`.
     *
     *      This mirrors `Jackpot.resolve`'s preimage exactly, `address(this)`
     *      term and all — so if that preimage is ever edited, every test in this
     *      file stops being able to force a win and fails loudly rather than
     *      quietly asserting nothing.
     *
     *      Searching the word (rather than nudging the odds down to 1) keeps the
     *      pots at their REAL shipped odds of 50 and 100 throughout.
     */
    function _wordThatWins(
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256) {
        for (uint256 word = 1; word < 100_000; word++) {
            uint256 roll = uint256(
                keccak256(abi.encodePacked(word, entropy, tokenId, winner, id, pot))
            ) % odds;
            if (roll == 0) return word;
        }
        revert("no winning word found");
    }

    /// @dev The mirror of the above: a word that makes ticket `id` a LOSER.
    function _wordThatLoses(
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256) {
        for (uint256 word = 1; word < 100_000; word++) {
            uint256 roll = uint256(
                keccak256(abi.encodePacked(word, entropy, tokenId, winner, id, pot))
            ) % odds;
            if (roll != 0) return word;
        }
        revert("no losing word found");
    }

    /// @dev Open a ticket the way a real fight does — through the wired duel.
    function _openTicket(
        Jackpot pot,
        address winner,
        uint256 tokenId,
        uint256 entropy,
        uint256 duelKey
    ) internal returns (uint256 ticketId) {
        return duel.open(address(pot), winner, tokenId, entropy, duelKey);
    }

    /// @dev Request → fulfil with `word` → resolve. The full keeper cycle.
    function _driveResolve(Jackpot pot, uint256 word) internal {
        uint256 reqId = pot.requestResolve(10);
        coord.fulfill(reqId, word);
        pot.resolve(10);
    }

    /// @dev A v2 quote the other way — BNBULL in, WBNB out — for the floor the
    ///      keeper publishes on the sell leg.
    function _quoteBnbullIn(uint256 amountIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(bnbull);
        path[1] = WBNB;
        return router.getAmountsOut(amountIn, path)[1];
    }

    /// @dev Fund the BNBULL pot the only way that exists after graduation:
    ///      sweep the accrued curve-phase bucket through the REAL router.
    function _sweepIntoBnbullPot() internal returns (uint256 funded) {
        uint256 accrued = drop.pendingBnbullBuyNative();
        require(accrued > 0, "nothing accrued to sweep");
        uint256 minOut = (_quoteBnbIn(address(bnbull), accrued) * 99) / 100;
        vm.prank(keeper);
        funded = drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, minOut);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. PRE-GRADUATION — the game is fully playable on the curve
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE CLAIM THE OWNER CARED ABOUT MOST: "we want the pots working
     *         pre-migration". The BNB pot funds from block one — it never needed
     *         a pool, because a BNB payment routes straight in — so it takes
     *         tickets and PAYS while BNBULL is still transfer-locked on the
     *         curve.
     */
    function test_pre_theBnbPotTakesATicketAndPaysDuringTheCurve() public {
        assertEq(pad.statusOf(address(bnbull)), pad.STATUS_TRADING(), "must still be on the curve");
        assertEq(_pair(address(bnbull)), address(0), "no pool exists yet");

        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();

        uint256 pool = potBnb.pool();
        assertEq(pool, 1 ether, "the BNB pot funds from block one, on the curve");
        assertEq(potBnbull.pool(), 0, "and the BNBULL pot cannot yet, as expected");

        uint256 ticketId = _openTicket(potBnb, alice, 7, 0xE47, 1);
        assertEq(ticketId, 0);
        assertEq(potBnb.pendingTickets(), 1, "a fight on the curve still opens a ticket");

        uint256 word = _wordThatWins(address(potBnb), 0xE47, 7, alice, 0, 100);
        uint256 before = wbnb.balanceOf(alice);

        _driveResolve(potBnb, word);

        // payoutBps defaults to 10_000, so a win takes the whole pool.
        assertEq(wbnb.balanceOf(alice) - before, pool, "the winner is paid, on the curve");
        assertEq(potBnb.pool(), 0, "and the pot is drained by the win");
        assertEq(potBnb.awardCount(), 1);
        assertEq(potBnb.pendingTickets(), 0, "the queue cleared");
    }

    /**
     * @notice The BNBULL pot on the curve: it is EMPTY, because its funding leg
     *         defers until a pool exists (§29). A ticket still opens, still
     *         resolves, and nothing reverts.
     *
     * @dev ⚠ AND THE PART THAT WOULD BE EXPENSIVE TO GET WRONG: a winning roll
     *      against an empty pot must NOT consume the duel's exclusivity claim.
     *      `Jackpot.resolve` computes `won = roll == 0 && balance > 0` BEFORE it
     *      calls `_claimDuel`, so an empty pot never reaches the lock. If it
     *      did, every curve-phase win would silently spend the duel key on a pot
     *      that paid nothing, and the BNB pot — which DID have money — would be
     *      refused. That is the `§10` "one pot never pays" bug wearing a
     *      different hat.
     */
    function test_pre_anEmptyBnbullPotResolvesWithoutBurningTheDuelClaim() public {
        uint256 duelKey = 99;

        uint256 ticketId = _openTicket(potBnbull, alice, 7, 0xE47, duelKey);
        uint256 word = _wordThatWins(address(potBnbull), 0xE47, 7, alice, ticketId, 50);

        assertEq(potBnbull.pool(), 0, "the pot is empty during the curve");

        uint256 reqId = potBnbull.requestResolve(10);
        coord.fulfill(reqId, word);

        // ⚠ The assertion that makes this test bite. Without it the test would
        //   pass just as happily on a LOSING roll, and would prove nothing about
        //   the empty pot at all: `roll == 0` says the ticket genuinely won, and
        //   `won == false` says the empty balance is what suppressed it.
        vm.expectEmit(true, true, true, true, address(potBnbull));
        emit Jackpot.TicketResolved(ticketId, alice, 7, 0, 50, false);
        potBnbull.resolve(10);

        assertEq(potBnbull.awardCount(), 0, "an empty pot pays nothing");
        assertEq(potBnbull.pendingTickets(), 0, "but the ticket still resolved");
        assertEq(bnbull.balanceOf(alice), 0, "and nothing was invented");

        // The claim was never spent, so the funded pot can still pay this duel.
        assertEq(duel.claimedBy(duelKey), address(0), "the duel key must be untouched");

        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();
        uint256 pool = potBnb.pool();

        uint256 tB = _openTicket(potBnb, alice, 7, 0xE47, duelKey);
        uint256 wordB = _wordThatWins(address(potBnb), 0xE47, 7, alice, tB, 100);
        uint256 before = wbnb.balanceOf(alice);
        _driveResolve(potBnb, wordB);

        assertEq(wbnb.balanceOf(alice) - before, pool, "the pot with money pays the same duel");
        assertEq(duel.claimedBy(duelKey), address(potBnb), "and it is the one that claims it");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. ACROSS THE BOUNDARY — nothing is stranded, and no pot moves
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE HEADLINE SCENARIO. A ticket is opened on the curve, against
     *         a BNBULL pot holding NOTHING. Then the token graduates, the
     *         accrued bucket sweeps in through the real router, and only then is
     *         the ticket resolved — and it pays real BNBULL.
     *
     * @dev This is `§47` made executable. The pot is never migrated, never
     *      ejected and never touched by graduation: the ERC-20 address is
     *      identical on both sides, so the pot's holding is in exactly the
     *      position of a player's wallet. What changed is the VENUE, and the
     *      only thing that had to happen is a swap finding a book.
     *
     *      A ticket that outlives the boundary is the sharpest version of the
     *      claim, because it is the case where a migration WOULD have been
     *      needed if the pot had had to move.
     */
    function test_cross_aCurveTicketIsPaidInRealBnbullAfterGraduation() public {
        // ── Curve: the BNBULL leg accrues, the pot stays empty ────────────
        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();
        uint256 accrued = drop.pendingBnbullBuyNative();
        assertGt(accrued, 0, "the curve phase must leave money accrued");
        assertEq(potBnbull.pool(), 0, "the pot is empty when the ticket is opened");

        // ── A fight happens on the curve. The ticket is real. ─────────────
        uint256 ticketId = _openTicket(potBnbull, bob, 11, 0xBEEF, 5);
        assertEq(potBnbull.pendingTickets(), 1);

        // ── GRADUATION. The pot is not touched, and does not move. ────────
        uint256 potCodeBefore = address(potBnbull).code.length;
        _graduate(bnbull);
        assertEq(pad.statusOf(address(bnbull)), pad.STATUS_COMPLETED());
        assertTrue(_pair(address(bnbull)) != address(0), "the pair must exist");
        assertEq(address(potBnbull).code.length, potCodeBefore, "the pot is the same contract");
        assertEq(potBnbull.ticketCount(), 1, "and it still holds the curve-phase ticket");

        // ── The sweep: accrued BNB -> BNBULL -> the pot. Auto-buying. ─────
        uint256 funded = _sweepIntoBnbullPot();
        assertGt(funded, 0);
        assertEq(drop.pendingBnbullBuyNative(), 0, "the bucket drained");
        assertEq(potBnbull.pool(), funded, "the pot now holds real BNBULL");

        // ── And NOW the curve-phase ticket pays. ──────────────────────────
        uint256 word = _wordThatWins(address(potBnbull), 0xBEEF, 11, bob, ticketId, 50);
        uint256 before = bnbull.balanceOf(bob);

        _driveResolve(potBnbull, word);

        assertEq(bnbull.balanceOf(bob) - before, funded, "a curve ticket pays post-graduation");
        assertEq(potBnbull.awardCount(), 1);
        assertEq(duel.claimedBy(5), address(potBnbull), "and it claims its duel");
    }

    /**
     * @notice A VRF request IN FLIGHT while the token graduates. The word is
     *         asked for on the curve and arrives after the venue has changed.
     *
     * @dev The boundary is not atomic in practice — a batch requested minutes
     *      before graduation fulfils minutes after it. `Jackpot` knows nothing
     *      about four.meme, so this must simply work; the test exists so that
     *      stays true rather than being assumed.
     */
    function test_cross_aVrfRequestInFlightSurvivesGraduation() public {
        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();

        uint256 ticketId = _openTicket(potBnbull, alice, 3, 0xF00D, 8);

        // Requested ON THE CURVE.
        uint256 reqId = potBnbull.requestResolve(10);
        assertGt(reqId, 0);
        assertEq(potBnbull.pendingRequestId(), reqId, "a request is in flight");

        // The venue changes underneath it.
        _graduate(bnbull);
        uint256 funded = _sweepIntoBnbullPot();

        assertEq(potBnbull.pendingRequestId(), reqId, "graduation must not disturb the request");

        // Fulfilled AFTER graduation, for a batch scoped before it.
        uint256 word = _wordThatWins(address(potBnbull), 0xF00D, 3, alice, ticketId, 50);
        coord.fulfill(reqId, word);
        assertTrue(potBnbull.resolvable(), "the word must land on the pre-graduation batch");

        uint256 before = bnbull.balanceOf(alice);
        potBnbull.resolve(10);

        assertEq(bnbull.balanceOf(alice) - before, funded, "and it pays");
        assertEq(potBnbull.pendingRequestId(), 0, "the request cleared");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. POST-GRADUATION — no keeper needed, and both pots pay
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice After graduation the BNBULL leg funds INLINE — no keeper, no
     *         sweep — because the router finally has a pool to quote off. Both
     *         pots then take a ticket and both pay.
     */
    function test_post_bothPotsFundInlineWithNoKeeperAndBothPay() public {
        _graduate(bnbull);

        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();

        assertEq(drop.pendingBnbullBuyNative(), 0, "nothing defers after graduation");
        uint256 bnbullPool = potBnbull.pool();
        uint256 bnbPool = potBnb.pool();
        assertGt(bnbullPool, 0, "the BNBULL pot funds inline");
        assertEq(bnbPool, 1 ether, "and the BNB pot as it always did");

        // Two different duels, so the exclusivity lock is not in play here.
        uint256 tA = _openTicket(potBnbull, alice, 1, 0xA1, 100);
        uint256 tB = _openTicket(potBnb, bob, 2, 0xB2, 200);

        uint256 aliceBefore = bnbull.balanceOf(alice);
        uint256 bobBefore = wbnb.balanceOf(bob);

        _driveResolve(potBnbull, _wordThatWins(address(potBnbull), 0xA1, 1, alice, tA, 50));
        _driveResolve(potBnb, _wordThatWins(address(potBnb), 0xB2, 2, bob, tB, 100));

        assertEq(bnbull.balanceOf(alice) - aliceBefore, bnbullPool, "the BNBULL pot pays");
        assertEq(wbnb.balanceOf(bob) - bobBefore, bnbPool, "the BNB pot pays");
    }

    /**
     * @notice ⚠ ONE POT PER DUEL, after graduation, with BOTH pots funded and
     *         BOTH rolls winning. Exactly one may pay.
     *
     * @dev Pre-graduation this invariant is untestable in its hard form, because
     *      the BNBULL pot is empty and can never contend. Graduation is the
     *      first moment both pots hold money at once, so it is the first moment
     *      the lock is actually load-bearing — which is why it is asserted here
     *      rather than only in the unit suite.
     */
    function test_post_onlyOnePotCanPayOneDuel() public {
        _graduate(bnbull);
        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();

        assertGt(potBnbull.pool(), 0, "both pots must hold money for this to mean anything");
        assertGt(potBnb.pool(), 0);

        uint256 duelKey = 4242;
        uint256 tA = _openTicket(potBnbull, alice, 9, 0xC0DE, duelKey);
        uint256 tB = _openTicket(potBnb, alice, 9, 0xC0DE, duelKey);

        uint256 bnbullBefore = bnbull.balanceOf(alice);
        uint256 wbnbBefore = wbnb.balanceOf(alice);

        _driveResolve(potBnbull, _wordThatWins(address(potBnbull), 0xC0DE, 9, alice, tA, 50));
        _driveResolve(potBnb, _wordThatWins(address(potBnb), 0xC0DE, 9, alice, tB, 100));

        bool paidBnbull = bnbull.balanceOf(alice) > bnbullBefore;
        bool paidBnb = wbnb.balanceOf(alice) > wbnbBefore;

        assertTrue(paidBnbull, "the first pot to resolve takes the duel");
        assertFalse(paidBnb, "and the second is refused by the lock");
        assertEq(potBnbull.awardCount(), 1);
        assertEq(potBnb.awardCount(), 0);
        assertEq(duel.claimedBy(duelKey), address(potBnbull));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE GAP `LifecycleE2E` DECLARED — the SPLITTER's own swap
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ CLOSES THE GAP `LifecycleE2E` DECLARES IN ITS OWN HEADER.
     *
     *         Every sweep in that file is driven through `MintDrop`, because at
     *         the time it was written `MintDrop`'s v2 leg was the only leg in
     *         the codebase that could reach the real book. `PotSplitter` was
     *         mid-migration from the v3 dialect and its `Wire.Router` was left
     *         deliberately unwired, so `sweepBnbullPot` through a real router
     *         was never asserted.
     *
     *         The migration has landed. This is that assertion: the splitter's
     *         OWN bucket, swept through the REAL PancakeSwap v2 router, into the
     *         pot — and then paid out to a winner.
     */
    function test_cross_theSplitterSweepsThroughTheRealRouterAndTheWinnerIsPaid() public {
        // ── Curve: the splitter's BNBULL leg defers, exactly as MintDrop's does
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok, "receive() must never revert");

        uint256 accrued = splitter.pendingBnbullBuyNative();
        assertEq(accrued, 0.2 ether, "the splitter's own leg accrues on the curve");
        assertEq(potBnbull.pool(), 0, "and the pot stays empty");

        // ── Graduation, then the splitter's own sweep ─────────────────────
        _graduate(bnbull);

        uint256 minOut = (_quoteBnbIn(address(bnbull), accrued) * 99) / 100;
        assertGt(minOut, 0);

        vm.prank(keeper);
        uint256 funded = splitter.sweepBnbullPot(PotSplitter.PotSource.Native, 0, minOut);

        assertGe(funded, minOut, "the splitter's swap must clear its floor");
        assertEq(splitter.pendingBnbullBuyNative(), 0, "the splitter's bucket drained");
        assertEq(potBnbull.pool(), funded, "and the pot holds exactly the measured delta");

        // ⚠ The assertion that makes `funded` mean something. `assertEq(pool,
        //   funded)` alone is self-consistent: a `_swapSingle` that reported the
        //   router's CLAIM instead of the measured `balanceOf` delta would
        //   satisfy it and quietly strand the difference here forever — the
        //   splitter has no withdraw path for BNBULL. Nothing may be left behind.
        assertEq(bnbull.balanceOf(address(splitter)), 0, "no swap output is stranded");

        // ── And the money that arrived this way pays a real winner ────────
        uint256 ticketId = _openTicket(potBnbull, bob, 21, 0x5171, 12);
        uint256 word = _wordThatWins(address(potBnbull), 0x5171, 21, bob, ticketId, 50);
        uint256 before = bnbull.balanceOf(bob);

        _driveResolve(potBnbull, word);

        assertEq(bnbull.balanceOf(bob) - before, funded, "splitter-sourced money pays out");
    }

    /**
     * @notice The splitter's INLINE leg, post-graduation, with no keeper sweep —
     *         driven by the published floors rather than a caller-supplied one.
     *
     * @dev This is the steady state the game runs in after launch: the keeper
     *      publishes `bnbullPerBnb`, and every payment funds the pot on its own
     *      way past. The floor is what makes the swap non-blind, so it is
     *      published from a REAL quote off the REAL pool rather than invented.
     */
    function test_post_theSplitterInlineLegBuysThroughTheRealRouterWithNoSweep() public {
        _graduate(bnbull);

        // The keeper can only publish an honest floor once a book exists — which
        // is precisely why it publishes for the first time at graduation (§47).
        uint256 perBnb = _quoteBnbIn(address(bnbull), 1 ether);
        uint256 perBnbull = _quoteBnbullIn(1e18);
        vm.prank(keeper);
        splitter.setFloors((perBnb * 90) / 100, (perBnbull * 90) / 100);

        uint256 potBefore = potBnbull.pool();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(splitter.pendingBnbullBuyNative(), 0, "nothing defers once the book is real");
        assertGt(potBnbull.pool(), potBefore, "the inline leg funded the pot, no keeper sweep");
        assertEq(wbnb.balanceOf(address(potBnb)), 0.1 ether, "and the BNB leg is unchanged");
        // Same rule as the swept path: the whole measured delta reaches the pot.
        assertEq(bnbull.balanceOf(address(splitter)), 0, "no swap output is stranded");
    }

    /**
     * @notice A losing roll after graduation pays nothing, leaves the pool
     *         intact, and leaves the duel key unclaimed — so the sibling pot can
     *         still take it.
     */
    function test_post_aLosingRollLeavesTheDuelClaimAvailable() public {
        _graduate(bnbull);
        vm.deal(address(this), 3 ether);
        drop.donatePotNative{value: 3 ether}();

        uint256 duelKey = 7;
        uint256 pool = potBnbull.pool();

        uint256 tA = _openTicket(potBnbull, alice, 4, 0xD00D, duelKey);
        _driveResolve(potBnbull, _wordThatLoses(address(potBnbull), 0xD00D, 4, alice, tA, 50));

        assertEq(potBnbull.pool(), pool, "a loss leaves the pool whole");
        assertEq(potBnbull.awardCount(), 0);
        assertEq(duel.claimedBy(duelKey), address(0), "and never claims the duel");

        uint256 tB = _openTicket(potBnb, alice, 4, 0xD00D, duelKey);
        uint256 before = wbnb.balanceOf(alice);
        _driveResolve(potBnb, _wordThatWins(address(potBnb), 0xD00D, 4, alice, tB, 100));

        assertGt(wbnb.balanceOf(alice), before, "so the other pot can still pay it");
        assertEq(duel.claimedBy(duelKey), address(potBnb));
    }
}
