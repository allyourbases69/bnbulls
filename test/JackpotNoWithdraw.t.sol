// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {TimelockedAddress} from "../contracts/lib/TimelockedAddress.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVRFCoordinator, EvilVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {MockDuel, ReentrantSweepToken, ReentrantResolveToken} from "./mocks/Hostile.sol";

/**
 * @title JackpotNoWithdrawTest
 * @notice PRIORITY 1. The no-withdraw guarantee IS the product.
 *
 * @dev `LEARNINGS-AND-MISTAKES §C`: "twin no-withdraw pots: only exit is a win.
 *      `sweepForeignToken` reverts on the prize token; the pool leaves only
 *      through a won ticket; a drain-attempt test must revert. **this guarantee
 *      IS the product — no escape hatches, including 'temporary' ones.**"
 *
 *      So this file is not a happy-path test with a couple of negatives bolted
 *      on. It is an attempt to get the money out, from every angle:
 *        1  the named hatch, on the prize token                  -> reverts
 *        2  the named hatch, fuzzed over every argument           -> reverts
 *        3  the named hatch, from a non-owner                     -> reverts
 *        4  EVERY other state-changing entrypoint, as owner       -> pool flat
 *        5  re-entrancy through a hostile "foreign token"         -> reverts
 *        6  re-entrancy into `resolve` mid-payout                 -> no double
 *        7  raw BNB in (there is no `receive()`)                  -> reverts
 *        8  opening a ticket without being the wired Duel         -> reverts
 *        9  repointing the Duel at a hostile one                  -> timelocked
 *       10  VRF going dark forever                                -> pool intact
 *      and then, positively, the ONE door: a won ticket.
 *
 *      ⚠ #11 IS A REAL FINDING. See `test_FINDING_*` at the bottom.
 */
contract JackpotNoWithdrawTest is BnbullsBase {
    MockERC20 internal foreign;

    function setUp() public override {
        super.setUp();
        potBnbull.bootstrapDuel(address(duel));
        potBnb.bootstrapDuel(address(duel));

        // A real pool, funded the only way money gets in.
        bnbull.mint(owner, 1_000_000e18);
        bnbull.approve(address(potBnbull), type(uint256).max);
        potBnbull.topUp(500_000e18);

        foreign = new MockERC20("Wrong Token", "OOPS", 18);
        foreign.mint(address(potBnbull), 1_000e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Forcing a win, now that `setOdds(1)` is correctly impossible
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev Search for a VRF word that makes ticket `id` a WINNER on `pot` at
     *      `odds`. Mirrors `Jackpot.resolve`'s preimage exactly, `address(this)`
     *      term and all — so if that preimage is ever edited, every test here
     *      stops being able to force a win and fails loudly rather than quietly
     *      asserting nothing.
     *
     *      ⚠ THIS IS WHAT REPLACED `setOdds(1)`. That was the old "make every
     *      ticket win" shortcut, and it is now forbidden by `MIN_ODDS_ONE_IN`
     *      for a very good reason: `H % 1 == 0` for EVERY possible word, so odds
     *      of one is a certain win with no grinding at all, and it was the last
     *      step of a four-transaction pool drain (see
     *      `JackpotOwnerDrainBlockedTest`). Searching the word instead keeps
     *      the pot at real, shipped odds throughout. Same helper as
     *      `test/testnet/GraduationBoundary.t.sol`.
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
            uint256 roll =
                uint256(keccak256(abi.encodePacked(word, entropy, tokenId, winner, id, pot))) % odds;
            if (roll == 0) return word;
        }
        revert("no winning word found");
    }

    /**
     * @dev ONE word that makes tickets `0 .. count-1` all win at once.
     *
     *      A batch is decided by a single VRF word, so a test that needs every
     *      ticket in the batch to pay needs one word satisfying all of them —
     *      which is exactly the thing `setOdds(1)` used to hand out for free.
     *      Assumes the ticket shape these tests open: `tokenId = i + 1`,
     *      `entropy = baseEntropy + i`, `ticketId = i`.
     */
    function _wordThatWinsBatch(
        address pot,
        address winner,
        uint256 baseEntropy,
        uint256 count,
        uint256 odds
    ) internal pure returns (uint256) {
        for (uint256 word = 1; word < 2_000_000; word++) {
            bool all = true;
            for (uint256 i = 0; i < count; i++) {
                uint256 roll = uint256(
                    keccak256(abi.encodePacked(word, baseEntropy + i, i + 1, winner, i, pot))
                ) % odds;
                if (roll != 0) {
                    all = false;
                    break;
                }
            }
            if (all) return word;
        }
        revert("no word wins the whole batch");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1-3. The named hatch cannot touch the prize
    // ══════════════════════════════════════════════════════════════════════

    function test_sweepForeignToken_revertsOnThePrizeToken() public {
        uint256 before = potBnbull.pool();
        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnbull.sweepForeignToken(address(bnbull), owner, 1);
        assertEq(potBnbull.pool(), before, "pool moved");
    }

    /// @dev The WBNB pot has a different prize token, so prove the rule is per
    ///      deployment and not a hardcoded address.
    function test_sweepForeignToken_revertsOnTheWbnbPotsPrizeToken() public {
        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnb.sweepForeignToken(address(wbnb), owner, 1);

        // ...and the BNBULL pot may sweep WBNB, because there it IS foreign.
        vm.deal(owner, 1 ether);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(address(potBnbull), 1 ether);
        potBnbull.sweepForeignToken(address(wbnb), owner, 1 ether);
        assertEq(wbnb.balanceOf(address(potBnbull)), 0);
    }

    function testFuzz_sweepForeignToken_neverTakesThePrize(address to, uint256 amount) public {
        uint256 before = potBnbull.pool();
        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnbull.sweepForeignToken(address(bnbull), to, amount);
        assertEq(potBnbull.pool(), before);
    }

    function test_sweepForeignToken_revertsForEveryNonOwner() public {
        address[3] memory callers = [alice, keeper, address(duel)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert("Only callable by owner");
            potBnbull.sweepForeignToken(address(foreign), callers[i], 1e18);
        }
        // A funder and a requester are privileged roles; neither is an owner.
        potBnbull.setFunder(alice, true);
        potBnbull.setRequester(alice, true);
        vm.prank(alice);
        vm.expectRevert("Only callable by owner");
        potBnbull.sweepForeignToken(address(foreign), alice, 1e18);
    }

    /// @dev The hatch exists — for tokens sent here by mistake, and nothing else.
    function test_sweepForeignToken_worksForAnActualMistake() public {
        uint256 pooled = potBnbull.pool();
        potBnbull.sweepForeignToken(address(foreign), alice, 1_000e18);
        assertEq(foreign.balanceOf(alice), 1_000e18);
        assertEq(potBnbull.pool(), pooled, "prize pool must not move");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. No OTHER entrypoint moves the prize either
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Call every state-changing function on Jackpot, as the owner, and
     *         assert the pool is byte-identical afterwards.
     *
     * @dev The point is coverage of the SURFACE, not of any one function: a
     *      future "temporary" hatch added to this contract fails here.
     */
    function test_noOwnerEntrypointRemovesThePrize() public {
        uint256 pooled = potBnbull.pool();

        bytes[] memory calls = new bytes[](22);
        calls[0] = abi.encodeCall(Jackpot.fund, (0, "x"));
        calls[1] = abi.encodeCall(Jackpot.topUp, (0));
        calls[2] = abi.encodeCall(Jackpot.recordWin, (owner, 1, 1, 0));
        calls[3] = abi.encodeCall(Jackpot.requestResolve, (10));
        calls[4] = abi.encodeCall(Jackpot.cancelStalledRequest, ());
        calls[5] = abi.encodeCall(Jackpot.resolve, (100));
        calls[6] = abi.encodeCall(Jackpot.bootstrapDuel, (owner));
        calls[7] = abi.encodeCall(Jackpot.proposeDuel, (owner));
        calls[8] = abi.encodeCall(Jackpot.commitDuel, ());
        calls[9] = abi.encodeCall(Jackpot.cancelDuel, ());
        calls[10] = abi.encodeCall(Jackpot.setWiringDelay, (12 hours));
        calls[11] = abi.encodeCall(Jackpot.setFunder, (owner, true));
        calls[12] = abi.encodeCall(Jackpot.setRequester, (owner, true));
        // ⚠ `setOdds` / `setPayoutBps` / `setMinPoolToFire` USED TO SIT HERE and
        // they are gone. All three now move together through
        // bootstrap-once-then-propose/wait/commit, so all four of the functions
        // that replaced them are swept instead of the three that were deleted.
        calls[13] = abi.encodeCall(Jackpot.bootstrapPayoutParams, (10, 10_000, 0));
        calls[14] = abi.encodeCall(Jackpot.proposePayoutParams, (10, 10_000, 0));
        calls[15] = abi.encodeCall(Jackpot.commitPayoutParams, ());
        calls[16] = abi.encodeCall(Jackpot.cancelPayoutParams, ());
        calls[17] = abi.encodeCall(Jackpot.setVrfConfig, (KEY_HASH, 2, 3, 200_000, false));
        calls[18] = abi.encodeCall(Jackpot.setTimeouts, (10, 10));
        calls[19] = abi.encodeCall(Jackpot.setSocials, ("w", "t", "g"));
        calls[20] = abi.encodeCall(Jackpot.sweepForeignToken, (address(bnbull), owner, pooled));
        calls[21] = abi.encodeWithSignature("transferOwnership(address)", alice);

        for (uint256 i = 0; i < calls.length; i++) {
            uint256 snap = vm.snapshotState();
            // Success or revert is irrelevant. The BALANCE is the invariant.
            (bool ok,) = address(potBnbull).call(calls[i]);
            ok; // silence
            assertEq(potBnbull.pool(), pooled, "an owner call moved the prize pool");
            vm.revertToState(snap);
        }
    }

    /// @dev The other half: nothing the owner sets can make the pool payable to
    ///      the owner without a ticket. `recordWin` is Duel-only, full stop.
    function test_ownerCannotOpenATicket() public {
        vm.expectRevert(Jackpot.NotDuel.selector);
        potBnbull.recordWin(owner, 1, 1, 0);

        vm.prank(alice);
        vm.expectRevert(Jackpot.NotDuel.selector);
        potBnbull.recordWin(alice, 1, 1, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5-6. Re-entrancy
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A hostile "foreign token" whose `transfer` re-enters the Jackpot and
    ///      tries to sweep the prize on the way past. The inner call must fail.
    function test_reentrantForeignTokenCannotSweepThePrize() public {
        ReentrantSweepToken evil =
            new ReentrantSweepToken(address(potBnbull), address(bnbull), alice);
        uint256 pooled = potBnbull.pool();

        potBnbull.sweepForeignToken(address(evil), alice, 1e18);

        assertFalse(evil.innerSucceeded(), "re-entrant sweep of the prize SUCCEEDED");
        assertEq(potBnbull.pool(), pooled, "pool drained via re-entrancy");
        assertEq(bnbull.balanceOf(alice), 0);
    }

    /// @dev `resolve` is permissionless by design (Duel nudges it on its way
    ///      past and must never be reverted by it), so re-entering it is a
    ///      legitimate worry. CEI in the loop — the cursor is retired before the
    ///      first external call — is what stops a ticket paying twice.
    function test_reentrantResolveCannotPayATicketTwice() public {
        // Deploy-day write: the odds floor (so a word that wins all three
        // tickets is findable) and 10% a win, so the pool survives three of
        // them. This used to be `setOdds(1); setPayoutBps(1_000);`.
        potBnbull.bootstrapPayoutParams(potBnbull.MIN_ODDS_ONE_IN(), 1_000, 0);

        for (uint256 i = 0; i < 3; i++) {
            duel.open(address(potBnbull), alice, i + 1, 0xABC + i, 0);
        }

        // ONE word, THREE winning tickets — the batch shape the CEI in the
        // resolve loop has to survive.
        uint256 word = _wordThatWinsBatch(
            address(potBnbull), alice, 0xABC, 3, potBnbull.MIN_ODDS_ONE_IN()
        );

        uint256 reqId = potBnbull.requestResolve(3);
        coord.fulfill(reqId, word);

        uint256 before = potBnbull.pool();
        potBnbull.resolve(3);

        assertEq(potBnbull.awardCount(), 3, "each ticket pays exactly once");
        assertEq(potBnbull.pendingTickets(), 0);
        // 3 wins of 10% each: 0.9^3 of the pool remains.
        assertEq(potBnbull.pool(), (((before * 9) / 10) * 9 / 10) * 9 / 10);
        assertEq(bnbull.balanceOf(alice), before - potBnbull.pool());
    }

    /// @dev The same question asked from inside the payout itself: a PRIZE
    ///      token whose `transfer` re-enters `resolve`. Every ticket must still
    ///      pay exactly once and the pool must not go negative-by-replay.
    function test_reentrantPrizeTokenCannotReplayATicket() public {
        ReentrantResolveToken evilPrize = new ReentrantResolveToken();
        // ⚠ The odds FLOOR, not 1. The constructor enforces `MIN_ODDS_ONE_IN`
        // too — a pot deployed at odds of one would be drainable from block one,
        // before any timelock could matter — so the win is forced with a
        // searched word instead.
        Jackpot pot = new Jackpot(address(evilPrize), address(0), address(coord), 10);
        evilPrize.setJackpot(address(pot));
        evilPrize.setBalance(1_000_000);
        pot.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        pot.bootstrapPayoutParams(10, 1_000, 0); // 10% a win
        pot.bootstrapDuel(address(duel));

        for (uint256 i = 0; i < 3; i++) {
            duel.open(address(pot), alice, i + 1, 0x1234 + i, 0);
        }
        uint256 word = _wordThatWinsBatch(address(pot), alice, 0x1234, 3, 10);
        uint256 reqId = pot.requestResolve(3);
        coord.fulfillTo(address(pot), reqId, word);

        pot.resolve(3);

        assertGt(evilPrize.reentries(), 1, "the re-entrancy did not actually fire");
        assertEq(pot.awardCount(), 3, "a ticket paid more than once");
        assertEq(pot.pendingTickets(), 0);
        assertEq(
            evilPrize.bal() + evilPrize.paidTo(alice),
            1_000_000,
            "value was created or destroyed by the re-entry"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  7-8. There is no BNB path at all
    // ══════════════════════════════════════════════════════════════════════

    function test_jackpotRefusesRawBnb() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(potBnbull).call{value: 1 ether}("");
        assertFalse(ok, "Jackpot accepted BNB; it has no code that moves BNB");
        assertEq(address(potBnbull).balance, 0);
    }

    function test_thereIsNoNativeSweep() public {
        (bool ok,) = address(potBnbull).call(
            abi.encodeWithSignature("sweepNative(address,uint256)", owner, 1)
        );
        assertFalse(ok, "a native sweep exists on Jackpot");
        (ok,) = address(potBnbull).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        assertFalse(ok, "a withdraw() exists on Jackpot");
        (ok,) = address(potBnbull).call(abi.encodeWithSignature("emergencyWithdraw()"));
        assertFalse(ok, "an emergencyWithdraw() exists on Jackpot");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  9. The Duel wire is the one real attack surface — and it is timelocked
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A malicious Duel could open tickets naming itself as the winner
     *         and statistically drain the pool. That is why the wire is
     *         timelocked rather than a bare setter.
     */
    function test_duelCannotBeRepointedInstantly() public {
        MockDuel hostile = new MockDuel();

        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, address(duel))
        );
        potBnbull.bootstrapDuel(address(hostile));

        uint64 eta = potBnbull.proposeDuel(address(hostile));
        (address current, address pending, uint64 storedEta) = potBnbull.duelWire();
        assertEq(current, address(duel), "wire moved on propose");
        assertEq(pending, address(hostile), "the pending target must be public");
        assertEq(storedEta, eta);
        assertEq(uint256(eta), block.timestamp + potBnbull.wiringDelay());

        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockedAddress.TimelockNotElapsed.selector, eta, uint64(block.timestamp)
            )
        );
        potBnbull.commitDuel();

        // The old duel still owns ticket creation for the whole delay.
        assertEq(potBnbull.duel(), address(duel));
        vm.prank(address(hostile));
        vm.expectRevert(Jackpot.NotDuel.selector);
        potBnbull.recordWin(alice, 1, 1, 0);

        vm.warp(eta);
        potBnbull.commitDuel();
        assertEq(potBnbull.duel(), address(hostile));
    }

    function test_wiringDelayIsBounded() public {
        vm.expectRevert(
            abi.encodeWithSelector(Jackpot.DelayOutOfRange.selector, 1 hours)
        );
        potBnbull.setWiringDelay(1 hours);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DelayOutOfRange.selector, 31 days));
        potBnbull.setWiringDelay(31 days);
        potBnbull.setWiringDelay(potBnbull.MIN_WIRING_DELAY());
        assertEq(potBnbull.wiringDelay(), 6 hours);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  10. VRF dark forever: the money sits there. Nobody takes it, us included
    // ══════════════════════════════════════════════════════════════════════

    function test_vrfDarkForeverStrandsPayoutsButNeverThePool() public {
        duel.open(address(potBnbull), alice, 1, 0xBEEF, 0);
        uint256 pooled = potBnbull.pool();

        uint256 reqId = potBnbull.requestResolve(1);
        assertEq(potBnbull.pendingRequestId(), reqId);

        // Never fulfilled. A second request is refused while one is in flight.
        vm.expectRevert(abi.encodeWithSelector(Jackpot.RequestInFlight.selector, reqId));
        potBnbull.requestResolve(1);

        // ⚠ READ THE LIVE VALUE, never a literal. It is an owner-settable
        // bounded number and it MOVED once already (1,200 -> 24,000, because
        // 1,200 was shorter than a measured fulfilment). The launch value is
        // pinned separately, in
        // `test_theStallTimeoutOutlastsTheSlowestFulfilmentEverMeasured`.
        uint256 timeout = potBnbull.requestTimeoutBlocks();
        vm.expectRevert(
            abi.encodeWithSelector(
                Jackpot.TimeoutNotElapsed.selector, uint64(block.number), timeout
            )
        );
        potBnbull.cancelStalledRequest();

        vm.roll(block.number + timeout + 1);
        // Permissionless: a stuck subscription must not need our key to unstick.
        vm.prank(alice);
        potBnbull.cancelStalledRequest();
        assertEq(potBnbull.pendingRequestId(), 0);

        assertEq(potBnbull.pool(), pooled, "the pool is untouched by any of this");
        assertEq(potBnbull.pendingTickets(), 1, "the ticket is still owed");
    }

    /// @dev A word for a request that was cancelled must be discarded, not
    ///      applied to a batch that has since moved on.
    function test_lateWordFromACancelledRequestIsDiscarded() public {
        duel.open(address(potBnbull), alice, 1, 0xBEEF, 0);
        uint256 reqId = potBnbull.requestResolve(1);
        vm.roll(block.number + potBnbull.requestTimeoutBlocks() + 1);
        potBnbull.cancelStalledRequest();

        coord.fulfill(reqId, 12345);
        assertFalse(potBnbull.wordReady(), "a cancelled request's word was applied");
        assertEq(potBnbull.resolve(10), 0);
    }

    /**
     * @notice ⚠ THE LAUNCH VALUE OF THE STALL TIMEOUT, PINNED. This is the one
     *         assertion standing between a silent drift and a keeper that
     *         cancels live VRF requests.
     *
     * @dev The measurement that set it: the FIRST live fulfilment on chain 97
     *      took **3,169 blocks (~24 minutes)** while `requestTimeoutBlocks`
     *      defaulted to **1,200** (~9 min at BSC's ~0.45s). A keeper obeying
     *      that default calls `cancelStalledRequest` on a request that is about
     *      to be answered — the subscription payment is spent for nothing, and
     *      the word that finally arrives is DISCARDED, deliberately, because
     *      `fulfillRandomWords` drops a word whose id no longer matches.
     *
     *      Every other test reads `requestTimeoutBlocks()` rather than a
     *      literal, which is right — and which also means all of them would
     *      keep passing if the launch value drifted back under real VRF
     *      latency. Hence this one. ⚠ Do not delete it, and do not relax the
     *      2x: it is a block count guarding a latency measured in TIME, so
     *      every BSC block-time reduction eats into the margin by itself.
     */
    function test_theStallTimeoutOutlastsTheSlowestFulfilmentEverMeasured() public view {
        uint256 measured = 3_169; // blocks, chain 97, first live fulfilment
        assertEq(potBnbull.requestTimeoutBlocks(), 24_000, "the launch stall timeout moved");
        assertEq(potBnb.requestTimeoutBlocks(), 24_000, "the two pots disagree");
        assertGe(
            potBnbull.requestTimeoutBlocks(),
            2 * measured,
            "the timeout is inside real VRF latency - a keeper would cancel live requests"
        );
        assertLe(
            potBnbull.requestTimeoutBlocks(),
            potBnbull.MAX_REQUEST_TIMEOUT_BLOCKS(),
            "the launch value is above its own ceiling"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The one door: a won ticket
    // ══════════════════════════════════════════════════════════════════════

    function test_theOnlyExitIsAWonTicket() public {
        // At the pot's REAL shipped odds of 1-in-50. The win is forced by
        // searching for the word rather than by bending the odds to 1.
        uint256 pooled = potBnbull.pool();
        assertEq(potBnbull.oddsOneIn(), 50, "harness sanity: real odds, not 1-in-1");

        duel.open(address(potBnbull), alice, 7, 0xF00D, 1);
        uint256 word = _wordThatWins(address(potBnbull), 0xF00D, 7, alice, 0, 50);
        uint256 reqId = potBnbull.requestResolve(1);
        coord.fulfill(reqId, word);
        potBnbull.resolve(1);

        assertEq(bnbull.balanceOf(alice), pooled, "the winner gets the pool");
        assertEq(potBnbull.pool(), 0);
        assertEq(potBnbull.totalAwarded(), pooled);
        assertEq(potBnbull.awardCount(), 1);
    }

    function test_minPoolToFireHoldsThePayoutBack() public {
        // The floor is a deploy-day write now, and it is snapshotted into the
        // request — so it is fixed before the word that decides the ticket
        // exists. See `JackpotOwnerDrainBlockedTest`.
        potBnbull.bootstrapPayoutParams(50, 10_000, potBnbull.pool() + 1);

        duel.open(address(potBnbull), alice, 7, 0xF00D, 0);
        uint256 word = _wordThatWins(address(potBnbull), 0xF00D, 7, alice, 0, 50);
        uint256 reqId = potBnbull.requestResolve(1);
        coord.fulfill(reqId, word);

        // ⚠ The assertion that makes this bite. Without it the test would pass
        // just as happily on a LOSING roll and would prove nothing about the
        // floor: `roll == 0` says the ticket genuinely won, `won == false` says
        // `minPoolToFire` is what suppressed the payout.
        vm.expectEmit(true, true, true, true, address(potBnbull));
        emit Jackpot.TicketResolved(0, alice, 7, 0, 50, false);
        potBnbull.resolve(1);

        assertEq(potBnbull.awardCount(), 0);
        assertEq(bnbull.balanceOf(alice), 0);
    }

    function test_payoutShareIsBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidShare.selector, uint256(0)));
        potBnbull.bootstrapPayoutParams(50, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidShare.selector, uint256(10_001)));
        potBnbull.bootstrapPayoutParams(50, 10_001, 0);
        // The same bound on the timelocked route, so it cannot be dodged by
        // proposing rather than bootstrapping.
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidShare.selector, uint256(10_001)));
        potBnbull.proposePayoutParams(50, 10_001, 0);

        potBnbull.bootstrapPayoutParams(50, 10_000, 0); // 100% to the WINNER, the launch value
        assertEq(potBnbull.payoutBps(), 10_000);
    }

    function test_oddsAreBounded() public {
        uint256 tooBig = potBnbull.MAX_ODDS_ONE_IN() + 1;
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, tooBig));
        potBnbull.bootstrapPayoutParams(tooBig, 10_000, 0);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, tooBig));
        potBnbull.proposePayoutParams(tooBig, 10_000, 0);

        // ⛔ AND THE FLOOR, WHICH IS THE HALF THAT MATTERS. `oddsOneIn = 1` is
        // `H % 1 == 0` for every possible word — a certain win with no grinding
        // at all, and the last step of the four-transaction pool drain
        // reproduced in `JackpotOwnerDrainBlockedTest`. Every value below the
        // floor is refused, on BOTH routes in, and `0` is refused with it.
        uint256 floor_ = potBnbull.MIN_ODDS_ONE_IN();
        assertEq(floor_, 10, "the floor moved - the drain regression test is measured against it");
        for (uint256 o = 0; o < floor_; o++) {
            vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, o));
            potBnbull.bootstrapPayoutParams(o, 10_000, 0);
            vm.expectRevert(abi.encodeWithSelector(Jackpot.InvalidOdds.selector, o));
            potBnbull.proposePayoutParams(o, 10_000, 0);
        }

        potBnbull.bootstrapPayoutParams(floor_, 10_000, 0);
        assertEq(potBnbull.oddsOneIn(), floor_);
    }

    function test_fundIsFunderGatedAndOnlyEverAdds() public {
        bnbull.mint(alice, 1_000e18);
        vm.startPrank(alice);
        bnbull.approve(address(potBnbull), type(uint256).max);
        vm.expectRevert(Jackpot.NotFunder.selector);
        potBnbull.fund(1_000e18, "alice");
        vm.stopPrank();

        uint256 pooled = potBnbull.pool();
        potBnbull.setFunder(alice, true);
        vm.prank(alice);
        potBnbull.fund(1_000e18, "alice");
        assertEq(potBnbull.pool(), pooled + 1_000e18);
        assertEq(potBnbull.totalFunded(), pooled + 1_000e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ⚠⚠⚠  FINDING — the one hole in the no-withdraw story  ⚠⚠⚠
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice **THE OWNER CAN FORCE A TICKET IT HOLDS TO WIN, AT WILL.**
     *
     * @dev `Jackpot` inherits `VRFConsumerBaseV2Plus`, whose `setCoordinator`
     *      is `onlyOwnerOrCoordinator` with **NO TIMELOCK**. Every other lever
     *      that could bend a payout — the Duel wire above all — is timelocked
     *      precisely because it can redirect money. The randomness source is
     *      not, and the randomness source decides who gets paid.
     *
     *      The attack costs one transaction plus one legitimately-won duel:
     *        1. own a bull and win a fight, so a ticket exists naming you
     *        2. `setCoordinator(evil)`                      — instant, no delay
     *        3. `requestResolve(1)`                         — evil returns an id
     *        4. grind offline for a `word` where
     *           keccak(word, entropy, tokenId, you, id, pot) % odds == 0
     *           (~`oddsOneIn` keccaks — 50 of them for the BNBULL pot)
     *        5. `evil.fulfill(id, word)`                    — the pot accepts it
     *        6. `resolve(1)`                                — you take 100%
     *
     *      No function called "withdraw" is involved, so §4's surface sweep
     *      above passes and the literal invariant ("no owner path removes the
     *      prize asset") holds. The GUARANTEE the product sells does not: the
     *      pool did not leave through a *random* win, it left through a chosen
     *      one, and it is the owner who chose.
     *
     *      SUGGESTED FIXES (contracts are out of scope for this package):
     *        - route `setCoordinator` through the same `TimelockedAddress` slot
     *          the Duel wire uses, so a repoint is public for `wiringDelay`; or
     *        - pin the coordinator immutable at construction and drop the
     *          inherited setter, accepting that a coordinator migration needs a
     *          redeploy of the pot; or
     *        - at minimum, mix a value the owner cannot choose after the ticket
     *          exists into the roll (e.g. `blockhash(openedAtBlock + 1)`)
     *          alongside the VRF word, so a hand-picked word is not sufficient.
     *
     *      ⚠ THE ASSERTIONS BELOW DOCUMENT TODAY'S BEHAVIOUR. When the fix
     *      lands, step 2 or step 5 should revert and this test must be inverted
     *      rather than deleted.
     */
    function test_FINDING_ownerCanHandPickTheWinningWordViaSetCoordinator() public {
        uint256 pooled = potBnbull.pool();
        assertEq(potBnbull.oddsOneIn(), 50, "harness sanity: real odds, not 1-in-1");

        // 1. A legitimate ticket. `alice` here stands for the owner's own wallet.
        uint256 entropy = 0xDEC1DE;
        uint256 tokenId = 77;
        duel.open(address(potBnbull), alice, tokenId, entropy, 0);
        uint256 ticketId = 0;

        // 2. Repoint the randomness source. Instant. No proposal, no ETA.
        EvilVRFCoordinator evil = new EvilVRFCoordinator();
        potBnbull.setCoordinator(address(evil));
        assertEq(address(potBnbull.s_vrfCoordinator()), address(evil));

        // 3. Ask "VRF" for a word.
        uint256 reqId = potBnbull.requestResolve(1);

        // 4. Grind a word that makes THIS ticket roll a zero. ~50 keccaks.
        uint256 word;
        for (uint256 w = 1; w < 5_000; w++) {
            uint256 roll = uint256(
                keccak256(
                    abi.encodePacked(w, entropy, tokenId, alice, ticketId, address(potBnbull))
                )
            ) % 50;
            if (roll == 0) {
                word = w;
                break;
            }
        }
        assertGt(word, 0, "grind failed");

        // 5. Try to deliver it. FIXED 2026-08-06: the pot no longer accepts a
        //    word just because `s_vrfCoordinator` points at the sender. The
        //    trusted coordinator is a TIMELOCKED slot of its own, so swapping
        //    Chainlink's pointer buys nothing on its own.
        vm.expectRevert(
            abi.encodeWithSelector(Jackpot.UntrustedCoordinator.selector, address(evil))
        );
        evil.fulfill(reqId, word);

        // 6. Nothing moved. The ground word is worthless.
        potBnbull.resolve(1);
        assertEq(potBnbull.awardCount(), 0, "no award: the word was refused");
        assertEq(bnbull.balanceOf(alice), 0, "attacker got nothing");
        assertEq(potBnbull.pool(), pooled, "pool untouched");

        // And the legitimate route out is visible and slow: a real migration
        // must propose, age past `wiringDelay`, then commit.
        potBnbull.proposeCoordinator(address(evil));
        (, address pending, uint64 eta) = potBnbull.coordinatorWire();
        assertEq(pending, address(evil), "coordinator rewire is a two-step");
        assertGt(eta, block.timestamp, "and it has to wait");
    }

    /// @dev `setCoordinator` is still instant — it is Chainlink's, not ours,
    ///      and it is not `virtual` so it cannot be overridden. What changed is
    ///      that it is no longer SUFFICIENT: the pot accepts words only from
    ///      its own timelocked slot, so moving Chainlink's pointer alone
    ///      changes nothing about who can get paid.
    function test_setCoordinatorAloneCannotRedirectRandomness() public {
        MockVRFCoordinator other = new MockVRFCoordinator();

        // The inherited setter still moves Chainlink's pointer, instantly.
        potBnbull.setCoordinator(address(other));
        assertEq(address(potBnbull.s_vrfCoordinator()), address(other));

        // But the trusted slot did NOT move with it.
        assertEq(
            potBnbull.trustedCoordinator(),
            address(coord),
            "trust must not follow the inherited setter"
        );

        // So a word from the new pointer is refused.
        duel.open(address(potBnbull), alice, 1, 0xABC, 0);
        uint256 reqId = potBnbull.requestResolve(1);
        vm.expectRevert(
            abi.encodeWithSelector(Jackpot.UntrustedCoordinator.selector, address(other))
        );
        other.fulfillTo(address(potBnbull), reqId, 1);

        // A non-owner cannot touch either lever.
        vm.prank(alice);
        vm.expectRevert();
        potBnbull.setCoordinator(address(coord));
        vm.prank(alice);
        vm.expectRevert();
        potBnbull.proposeCoordinator(address(other));
    }
}
