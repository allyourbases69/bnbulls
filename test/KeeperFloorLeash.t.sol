// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SplitterBase} from "./SplitterBase.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title KeeperFloorLeash
 * @notice `DECISIONS.md §42` gave the keeper its own least-privileged key on a
 *         written promise: *"every keeper setter is bounded by a constant a
 *         compromised key cannot exceed. It holds no owner power."*
 *
 *         **The promise was false, in both directions, and this file is the
 *         proof that it now holds.**
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT WAS ACTUALLY BROKEN
 *      ══════════════════════════════════════════════════════════════════════
 *      Two unbounded surfaces, either of which drained a pot bucket to an
 *      attacker without an owner key touching anything:
 *
 *        1. `setFloors` took any two `uint256`s from the keeper. A rate of 1
 *           wei made every inline swap — the ones inside every player's mint,
 *           revive and fight payment — a blind swap wearing a floor. `_floor`
 *           only refuses a minimum that rounds to ZERO, and 1 wei does not;
 *        2. the sweeps' `minOut` REPLACED the published floor rather than
 *           tightening it, and `amountIn == 0` means "the whole bucket". So
 *           `sweepBnbullPot(Native, 0, 1)` spent an entire accrued bucket at
 *           any price the mempool felt like, in ONE transaction — and it did
 *           not even need step 1.
 *
 *      ⚠ AND `_requireLiquidity` DOES NOT COVER THIS, which is worth stating
 *      because it looks like it should. The liquidity floor guards against a
 *      dead or decoy pair. A sandwicher's front-run is a BUY, and a buy makes
 *      the quote-side reserve LARGER — so the attack sails through the floor it
 *      appears to be blocked by.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY THE FIX IS NOT A CONSTANT
 *      ══════════════════════════════════════════════════════════════════════
 *      A floor is a market price. Any `MIN_BNBULL_PER_BNB` written at deploy
 *      time is a rug if it is low and a permanent outage if it is high, because
 *      nobody knows what BNBULL is worth a year out. What CAN be bounded
 *      without knowing the price is the DIRECTION of a move and its SPEED:
 *
 *        - raises and kill switches stay free, because both only ever cause
 *          deferral, which is this contract's safe state;
 *        - cuts are capped per step and per hour;
 *        - arming a dead leg is owner-only;
 *        - a sweep's `minOut` may tighten the published floor, never loosen it.
 *
 *      `MintDrop` gets a different cut, and the reason is in its own header: it
 *      publishes no floor at all, and an on-chain `getAmountsOut` is not a
 *      bound — it prices the very reserves the swap is about to hit, so an
 *      attacker moves them first and the quote is simply taken at the
 *      attacker's price. With nothing manipulation-resistant to measure a
 *      keeper against, pricing there is owner authority.
 */
contract KeeperFloorLeashTest is SplitterBase {
    /**
     * ⚠⚠ EVERY HELPER BELOW MAKES AN EXTERNAL VIEW CALL, SO ITS RESULT IS
     *     HOISTED INTO A LOCAL **BEFORE** ANY `vm.prank`, ALWAYS.
     *
     *     `vm.prank` applies to the next external call, and a view read is an
     *     external call. Written inline in an argument list —
     *     `vm.prank(keeper); s.setFloors(_lowestKeeperStep(x), y);` — the read
     *     eats the prank and `setFloors` runs as the OWNER, which is exempt
     *     from the leash. The test then passes while proving nothing at all.
     *     Four of the tests in this file did exactly that before this note
     *     existed. If a keeper test here ever starts passing suspiciously
     *     easily, look here first.
     */

    /// @dev 25% of the launch floor, cut off — the deepest single step the
    ///      launch leash allows. Spelled as the contract spells it.
    function _lowestKeeperStep(uint256 live) internal view returns (uint256) {
        return live - (live * mintSplit.keeperFloorDropBps()) / 10_000;
    }

    /// @dev The floor the contract itself computes for a spend out of the
    ///      NATIVE bucket. ⚠ `bnbullPerBnb` over 1e18 — the BUY leg's pair.
    function _publishedBuyFloor(uint256 spend) internal view returns (uint256) {
        return (spend * mintSplit.bnbullPerBnb()) / 1e18;
    }

    /// @dev Park money in the native BNBULL-buy bucket by breaking the route
    ///      while a payment lands. The never-fail path turns it into an accrual.
    function _accrueNative(uint256 amount) internal returns (uint256 bucket) {
        dex.setRevertOnSwap(true);
        _sendNative(address(mintSplit), amount);
        dex.setRevertOnSwap(false);
        bucket = mintSplit.pendingBnbullBuyNative();
    }

    function _sendNative(address to, uint256 amount) internal {
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        (bool ok,) = to.call{value: amount}("");
        assertTrue(ok, "a never-fail entrypoint reverted");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE FINDING, AS AN EXECUTABLE PROOF OF CONCEPT
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The whole attack, run by a stolen keeper key, start to finish:
     *         publish a dust floor, then sweep the bucket into it. Both halves
     *         are refused and the money does not move.
     */
    function test_theCompromisedKeeperAttack_dustFloorThenSweep_isRefused() public {
        uint256 bucket = _accrueNative(10 ether);
        assertEq(bucket, 2 ether, "harness: the buy leg must have deferred");

        uint256 lowest = _lowestKeeperStep(FLOOR_BNBULL_PER_BNB);
        uint256 published = _publishedBuyFloor(bucket);

        // ── Step 1: publish a floor of 1 wei. The leash refuses the cut. ───
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.FloorDropTooLarge.selector, uint256(1), lowest)
        );
        mintSplit.setFloors(1, 1);
        assertEq(mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB, "the floor must be untouched");

        // ── Step 2: the sweep does not need step 1. It used to carry its own
        //    price. Now it may only tighten the published one. ───────────────
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                PotSplitter.SweepFloorBelowPublished.selector, uint256(1), published
            )
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, 1);

        // ── And nothing moved. ────────────────────────────────────────────
        assertEq(mintSplit.pendingBnbullBuyNative(), bucket, "the bucket must be intact");
        assertEq(potBnbull.pool(), 0, "no dust may have reached the pot");
    }

    /// @notice The quantified version of the claim `§42` makes. An hour of a
    ///         stolen key, spending every step the leash allows and retrying
    ///         once a minute, buys exactly ONE 25% cut.
    function test_anHourOfAStolenKeyBuysExactlyOneStep() public {
        uint256 start = mintSplit.bnbullPerBnb();
        uint256 step = _lowestKeeperStep(start);

        vm.prank(keeper);
        mintSplit.setFloors(step, FLOOR_WBNB_PER_BNBULL);

        for (uint256 i = 1; i < 60; i++) {
            vm.warp(block.timestamp + 1 minutes);
            vm.prank(keeper);
            vm.expectRevert(); // FloorDropTooLarge, then FloorDropTooSoon
            mintSplit.setFloors(1, FLOOR_WBNB_PER_BNBULL);
        }

        assertEq(
            mintSplit.bnbullPerBnb(),
            step,
            "fifty-nine minutes and sixty transactions must not beat one step"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE LEASH: WHAT A HONEST KEEPER MAY STILL DO
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A real market move still publishes. The launch step (25%) sits
    ///         above `floor-keeper.mjs`'s own 20% repeg trigger on purpose, so
    ///         a normal repeg is never refused.
    function test_aLegitimateMarketMoveStillPublishes() public {
        uint256 next = (FLOOR_BNBULL_PER_BNB * 80) / 100; // BNBULL rallied 25%

        vm.prank(keeper);
        mintSplit.setFloors(next, FLOOR_WBNB_PER_BNBULL);

        assertEq(mintSplit.bnbullPerBnb(), next);
        assertTrue(mintSplit.floorsFresh());
    }

    /// @notice And the same move a second time, once the gap has elapsed.
    function test_aSecondCutWaitsForTheGapAndThenLands() public {
        uint256 gap = mintSplit.keeperFloorDropGap();
        uint256 first = (FLOOR_BNBULL_PER_BNB * 90) / 100;
        vm.prank(keeper);
        mintSplit.setFloors(first, FLOOR_WBNB_PER_BNBULL);

        uint256 second = (first * 90) / 100;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.FloorDropTooSoon.selector, block.timestamp + gap)
        );
        mintSplit.setFloors(second, FLOOR_WBNB_PER_BNBULL);

        vm.warp(block.timestamp + gap);
        vm.prank(keeper);
        mintSplit.setFloors(second, FLOOR_WBNB_PER_BNBULL);
        assertEq(mintSplit.bnbullPerBnb(), second);
    }

    /// @notice Raising is free and unlimited, because a higher floor is a
    ///         STRICTER floor: the worst it can do is make swaps miss `minOut`
    ///         and defer, which is the safe state.
    function test_raisingAFloorIsFreeAndUnlimited() public {
        uint256 rate = FLOOR_BNBULL_PER_BNB;
        for (uint256 i = 0; i < 5; i++) {
            rate *= 10;
            vm.prank(keeper);
            mintSplit.setFloors(rate, FLOOR_WBNB_PER_BNBULL);
        }
        assertEq(mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB * 100_000);
    }

    /// @notice The kill switch is never restricted. A keeper that has lost its
    ///         price source must always be one transaction from "stop trading",
    ///         and stopping means everything accrues.
    function test_theKillSwitchIsAlwaysAvailableToTheKeeper() public {
        vm.prank(keeper);
        mintSplit.setFloors(0, 0);
        assertEq(mintSplit.bnbullPerBnb(), 0);

        _sendNative(address(mintSplit), 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "a killed leg must accrue");
        assertEq(dex.swapCalls(), 0, "and must never reach the router");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. ARMING A DEAD LEG IS OWNER AUTHORITY
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⛔ THE BYPASS THAT WOULD HAVE MADE THE WHOLE LEASH DECORATIVE:
     *         publish 0 to kill, publish 1 to re-arm at dust, and the step cap
     *         is walked around in two transactions — because 0 -> 1 compares as
     *         a RAISE however you write the integers.
     */
    function test_theKeeperCannotReArmALegItKilled() public {
        vm.prank(keeper);
        mintSplit.setFloors(0, 0);

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.FloorArmingIsOwnerOnly.selector);
        mintSplit.setFloors(1, 0);

        // The owner turns it back on, at whatever the market actually is.
        vm.prank(owner);
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB, FLOOR_WBNB_PER_BNBULL);
        assertEq(mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB);
    }

    /**
     * @notice `DECISIONS.md §14` — never sell BNBULL — and `floor-keeper.mjs`'s
     *         written promise that *"this keeper must never be the thing that
     *         turns BNBULL-selling on"*. That promise is now bytecode.
     *
     * @dev ⚠ AND THIS IS THE SHORT-CIRCUIT REGRESSION TEST. The publish below
     *      carries a legal CUT on the buy rate and an illegal ARMING on the
     *      sell rate in the same call. If `_leashKeeperFloors` ever gets folded
     *      into `_isKeeperDrop(a) || _isKeeperDrop(b)`, `||` stops evaluating
     *      after the first true and this test is the only thing that notices.
     */
    function test_theKeeperCannotTurnTheBnbullSellLegOn() public {
        uint256 legalCut = _lowestKeeperStep(FLOOR_BNBULL_PER_BNB);

        vm.prank(keeper);
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB, 0); // kill the sell leg only
        assertEq(mintSplit.wbnbPerBnbull(), 0);

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.FloorArmingIsOwnerOnly.selector);
        mintSplit.setFloors(legalCut, FLOOR_WBNB_PER_BNBULL);

        assertEq(mintSplit.wbnbPerBnbull(), 0, "the sell leg must still be off");
        assertEq(
            mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB, "and the buy cut must not have landed"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE OWNER KEEPS ITS LARGE CORRECTION (`BNBULLS-BOOTSTRAP §0`)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A 99% correction, then a 100x one, in consecutive blocks with no
    ///         gap. The owner is exempt because it already holds
    ///         `withdrawPendingForManualBuy` — leashing a price it can route
    ///         around would bound nothing and cost the correction `§0` requires.
    function test_theOwnerCanStillMakeALargeCorrectionInstantly() public {
        vm.prank(owner);
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB / 100, 1);
        assertEq(mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB / 100);

        vm.prank(owner);
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB * 100, FLOOR_WBNB_PER_BNBULL);
        assertEq(mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB * 100);
    }

    /// @notice The leash is an owner-settable variable inside hard ceilings —
    ///         `§0` again — and the keeper cannot touch it.
    function test_theLeashIsOwnerSettableWithinHardCeilings() public {
        assertEq(mintSplit.MAX_KEEPER_FLOOR_DROP_BPS(), 5_000);
        assertEq(mintSplit.MIN_KEEPER_FLOOR_DROP_GAP(), 15 minutes);

        uint256 maxBps = mintSplit.MAX_KEEPER_FLOOR_DROP_BPS();
        uint256 minGap = mintSplit.MIN_KEEPER_FLOOR_DROP_GAP();

        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidFloorLeash.selector, maxBps + 1, minGap)
        );
        mintSplit.setKeeperFloorLeash(maxBps + 1, minGap);

        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidFloorLeash.selector, maxBps, minGap - 1)
        );
        mintSplit.setKeeperFloorLeash(maxBps, minGap - 1);

        uint256 maxGap = mintSplit.MAX_FLOOR_AGE();
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidFloorLeash.selector, maxBps, maxGap + 1)
        );
        mintSplit.setKeeperFloorLeash(maxBps, maxGap + 1);

        vm.expectEmit(false, false, false, true, address(mintSplit));
        emit PotSplitter.KeeperFloorLeashChanged(1_000, 2 hours);
        mintSplit.setKeeperFloorLeash(1_000, 2 hours);
        assertEq(mintSplit.keeperFloorDropBps(), 1_000);
        assertEq(mintSplit.keeperFloorDropGap(), 2 hours);

        vm.prank(keeper);
        vm.expectRevert();
        mintSplit.setKeeperFloorLeash(maxBps, minGap);
    }

    /// @notice Zero is legal and is the STRICTEST setting: the keeper may raise
    ///         or kill a floor but never lower one. It costs availability and
    ///         nothing else, which is why it is allowed where a zero
    ///         `minPoolLiquidity` is not.
    function test_aZeroDropLeashFreezesEveryKeeperCut() public {
        mintSplit.setKeeperFloorLeash(0, 15 minutes);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                PotSplitter.FloorDropTooLarge.selector,
                FLOOR_BNBULL_PER_BNB - 1,
                FLOOR_BNBULL_PER_BNB
            )
        );
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB - 1, FLOOR_WBNB_PER_BNBULL);

        // A raise still lands, so the keeper is never wedged.
        vm.prank(keeper);
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB + 1, FLOOR_WBNB_PER_BNBULL);
        assertEq(mintSplit.bnbullPerBnb(), FLOOR_BNBULL_PER_BNB + 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. THE SWEEP MAY TIGHTEN THE FLOOR, NEVER LOOSEN IT
    // ══════════════════════════════════════════════════════════════════════

    function test_aKeeperSweepIsRefusedOneWeiBelowThePublishedFloor() public {
        uint256 bucket = _accrueNative(10 ether);
        uint256 published = _publishedBuyFloor(bucket);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                PotSplitter.SweepFloorBelowPublished.selector, published - 1, published
            )
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, published - 1);

        // Exactly at the floor is fine, and above it — a TIGHTER floor — is the
        // whole point of the argument still existing.
        vm.prank(keeper);
        uint256 funded =
            mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));
        assertEq(funded, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), 0);
    }

    /**
     * @notice ⚠ AND THIS IS THE CAP ON HOW MUCH OF A BUCKET ONE KEEPER SWEEP
     *         MAY SPEND, with no magic fraction anywhere in the contract.
     *
     * @dev The published floor scales LINEARLY with `spend`, so an off-chain
     *      quote sized for half a bucket cannot authorise the whole one. On a
     *      real constant-product pool the same arithmetic bites harder, because
     *      what the book actually pays scales SUB-linearly — price impact. The
     *      slice size falls out of the pool's real depth and retunes itself as
     *      the pool grows.
     */
    function test_thePublishedFloorScalesWithTheSpendWhichSlicesTheSweep() public {
        uint256 bucket = _accrueNative(10 ether);
        uint256 halfFloor = _publishedBuyFloor(bucket / 2);
        uint256 wholeFloor = _publishedBuyFloor(bucket);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                PotSplitter.SweepFloorBelowPublished.selector, halfFloor, wholeFloor
            )
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, halfFloor);

        // The slice it was actually quoted for clears.
        vm.prank(keeper);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, bucket / 2, halfFloor);
        assertEq(mintSplit.pendingBnbullBuyNative(), bucket / 2, "exactly one slice was spent");
    }

    /// @notice ⚠ THE PROMISE THAT MUST NOT REGRESS: a stale floor DEFERS. The
    ///         keeper's sweep reverts, the bucket is untouched, and the owner
    ///         is still able to act on it.
    function test_aStaleFloorMakesTheKeeperSweepDeferAndTheOwnerCanStillAct() public {
        uint256 bucket = _accrueNative(10 ether);

        vm.warp(block.timestamp + mintSplit.maxFloorAge() + 1);
        assertFalse(mintSplit.floorsFresh(), "harness: the floors must have gone stale");

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.FloorsStale.selector);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), bucket, "deferred, never traded");
        assertEq(potBnbull.pool(), 0);

        vm.prank(owner);
        uint256 funded =
            mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));
        assertEq(funded, _bnbullFromBnb(2 ether), "the owner is the escape hatch");
    }

    /// @notice A leg whose rate was KILLED cannot be swept by the keeper at
    ///         all: there is no floor to be measured against, so `_floor`
    ///         refuses it as the blind swap it would be.
    function test_aKilledLegCannotBeSweptByTheKeeper() public {
        uint256 bucket = _accrueNative(10 ether);

        vm.prank(keeper);
        mintSplit.setFloors(0, FLOOR_WBNB_PER_BNBULL);

        vm.prank(keeper);
        vm.expectRevert(PotSplitter.BlindSwapRefused.selector);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), bucket);

        vm.prank(owner);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), 0);
    }

    /// @notice The BNBULL bucket needs no floor at all — it is already the pot
    ///         asset, so no swap and no price happen. The keeper keeps it.
    function test_theKeeperKeepsTheSweepThatNeedsNoPrice() public {
        _giveSplitterBnbull(alice, address(mintSplit), 100e18);
        potBnbull.setFunder(address(mintSplit), false);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);
        potBnbull.setFunder(address(mintSplit), true);
        assertEq(mintSplit.pendingBnbullDirect(), 30e18);

        vm.prank(keeper);
        uint256 funded = mintSplit.sweepBnbullPot(PotSplitter.PotSource.Bnbull, 0, 0);
        assertEq(funded, 30e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. THE TWO FLOORS ARE STILL IN DIFFERENT UNITS (`§43`)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE SELL LEG IS MEASURED AGAINST `wbnbPerBnbull` OVER
     *         `10 ** bnbullDecimals`, NEVER AGAINST THE BUY LEG'S PAIR. Two
     *         numbers that look alike and mean different things is the bug
     *         class this project has been bitten by twice
     *         (`BNB-CHAIN-FACTS.md §3`, and the fefers 1e12 trap).
     *
     * @dev The margin here is not subtle: at the harness rates the buy floor
     *      for the same spend is about 3.6 BILLION times the sell floor. If the
     *      new check ever reached for the wrong pair the sweep below could not
     *      possibly clear, and the assertion on the reverted `published` figure
     *      pins WHICH number was used rather than merely that one was.
     */
    function test_theBuyAndSellFloorsAreNeverInterchanged() public {
        drop.setBnbullPaymentSellPolicy(true); // `§14`'s switch, owner-only

        dex.setRevertOnSwap(true);
        _giveSplitterBnbull(alice, address(mintSplit), 100e18);
        vm.prank(alice);
        mintSplit.routePayment(address(bnbull), 100e18);
        dex.setRevertOnSwap(false);

        uint256 bucket = mintSplit.pendingBnbPotBnbull();
        assertEq(bucket, 10e18, "harness: the sell leg must have deferred");

        uint256 sellFloor = (bucket * mintSplit.wbnbPerBnbull()) / (10 ** bnbull.decimals());
        uint256 buyFloor = (bucket * mintSplit.bnbullPerBnb()) / 1e18;
        assertGt(buyFloor, sellFloor * 1_000_000, "harness: the two units must be far apart");

        // One wei under the SELL floor names the sell floor, not the buy one.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                PotSplitter.SweepFloorBelowPublished.selector, sellFloor - 1, sellFloor
            )
        );
        mintSplit.sweepBnbPot(PotSplitter.PotSource.Bnbull, 0, sellFloor - 1);

        // And at the sell floor it clears — which it could not if the buy
        // floor were being applied.
        vm.prank(keeper);
        uint256 funded = mintSplit.sweepBnbPot(PotSplitter.PotSource.Bnbull, 0, sellFloor);
        assertGe(funded, sellFloor);
        assertEq(mintSplit.pendingBnbPotBnbull(), 0);
    }

    /// @notice `§43`: an unset `minPoolLiquidityAlt` still means REFUSE TO
    ///         TRADE, and the new keeper check does not mask it or slip past
    ///         it — a compliant `minOut` still lands on the missing alt floor.
    function test_theAltRouteStillRefusesToTradeWithNoAltFloor() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 18);
        mintSplit.bootstrapWire(PotSplitter.Wire.SwapIntermediate, address(usdt));

        uint256 bucket = _accrueNative(10 ether);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.InvalidMinLiquidity.selector, uint256(0))
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), bucket, "still deferred, never traded");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  7. NO REGRESSION ON THE NEVER-FAIL PATH
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A leashed floor that is too HIGH for the market still defers
    ///         rather than bricking — the inline swap misses `minOut`, the
    ///         revert is caught, the slice accrues, and the player is paid.
    function test_aTooHighLeashedFloorStillDefersAndNeverBricks() public {
        vm.prank(keeper);
        mintSplit.setFloors(FLOOR_BNBULL_PER_BNB * 10, FLOOR_WBNB_PER_BNBULL);

        _sendNative(address(mintSplit), 10 ether);

        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "nothing lost, only deferred");
        assertEq(potBnbull.pool(), 0);
        assertEq(potBnb.pool(), 1 ether, "and the wrap leg is untouched by any of it");
    }
}

/**
 * @title MintDropKeeperSweep
 * @notice The same finding on `MintDrop`, where the cure has to be different.
 *
 * @dev `MintDrop` publishes no floor. Its inline legs quote on chain, and an
 *      on-chain quote is not a slippage bound — it prices the very reserves the
 *      swap is about to hit, in the same call, so a front-run moves them first
 *      and the quote is taken at the attacker's price. Anchoring a keeper's
 *      sweep `minOut` to it would bound nothing at all, and giving this
 *      contract its own published floor is ~2KB against 877 bytes of EIP-170
 *      headroom (`§43`).
 *
 *      So the cut is drawn where it is real: **the keeper may move money that
 *      needs no price; pricing is owner authority.**
 */
contract MintDropKeeperSweepTest is SplitterBase {
    function _accrueNativeBuy() internal returns (uint256 bucket) {
        router.setRevertOnSwap(true);
        vm.deal(alice, alice.balance + 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        router.setRevertOnSwap(false);
        bucket = drop.pendingBnbullBuyNative();
    }

    /// @notice The attack, refused, and the bucket still there afterwards.
    function test_aCompromisedKeeperCannotDrainAPricedBucket() public {
        uint256 bucket = _accrueNativeBuy();
        assertEq(bucket, 2 ether, "harness: the buy leg must have deferred");

        vm.prank(keeper);
        vm.expectRevert(MintDrop.PricedSweepIsOwnerOnly.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);

        assertEq(drop.pendingBnbullBuyNative(), bucket, "the bucket must be intact");
        assertEq(potBnbull.pool(), 0, "no dust may have reached the pot");
    }

    /// @notice And the owner still clears the backlog — the large, deliberate,
    ///         post-graduation trade `§29` says this bucket exists for.
    function test_theOwnerStillClearsThePricedBacklog() public {
        uint256 bucket = _accrueNativeBuy();

        vm.prank(owner);
        uint256 funded = drop.sweepBnbullPot(
            MintDrop.PotSource.Native, 0, (bucket * BNBULL_PER_BNB * 99) / 100
        );

        assertEq(funded, bucket * BNBULL_PER_BNB);
        assertEq(drop.pendingBnbullBuyNative(), 0);
    }

    /// @notice The SELL leg is owner-only too. `§14` keeps it off entirely, so
    ///         a keeper reaching it is already a surprise.
    function test_theSellLegIsOwnerOnlyToo() public {
        drop.setBnbullPaymentSellPolicy(true);
        potBnb.setFunder(address(drop), false);
        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);
        potBnb.setFunder(address(drop), true);

        uint256 bucket = drop.pendingBnbPotBnbull();
        assertGt(bucket, 0, "harness: nothing deferred to sweep");

        vm.prank(keeper);
        vm.expectRevert(MintDrop.PricedSweepIsOwnerOnly.selector);
        drop.sweepBnbPot(MintDrop.PotSource.Bnbull, 0, 1);
        assertEq(drop.pendingBnbPotBnbull(), bucket);
    }

    /// @notice The keeper keeps both legs that carry no price: a BNBULL bucket
    ///         going into the BNBULL pot, and a native bucket wrapping 1:1 into
    ///         the WBNB pot. Neither touches a router.
    function test_theKeeperKeepsTheLegsThatHaveNoPrice() public {
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);

        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);
        vm.deal(bob, bob.balance + 3 ether);
        vm.prank(bob);
        drop.donatePotNative{value: 3 ether}();

        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);

        vm.startPrank(keeper);
        drop.sweepBnbullPot(MintDrop.PotSource.Bnbull, 0, 0); // already the pot asset
        drop.sweepBnbPot(MintDrop.PotSource.Native, 0, 0); // a wrap, not a swap
        vm.stopPrank();

        assertEq(potBnbull.pool(), 270e18);
        assertEq(potBnb.pool(), 1 ether);
    }

    /// @notice ⚠ ORDERING PIN. A blind sweep is still refused as a BLIND SWAP
    ///         before the owner gate is reached, so the error a keeper sees
    ///         names the real problem rather than the authority one.
    function test_aBlindSweepIsStillNamedBlindNotUnauthorised() public {
        _accrueNativeBuy();

        vm.prank(keeper);
        vm.expectRevert(MintDrop.BlindSwapRefused.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 0);
    }

    /// @notice And a stranger is still refused first of all, by the modifier.
    function test_aStrangerIsStillRefusedByTheModifier() public {
        _accrueNativeBuy();

        vm.prank(alice);
        vm.expectRevert(MintDrop.NotKeeperOrOwner.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);
    }
}
