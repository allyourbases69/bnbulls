// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {TimelockedAddress} from "../contracts/lib/TimelockedAddress.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/**
 * @title TimelockedWiringTest
 * @notice PRIORITY 10. Bootstrap once, timelocked forever after.
 *
 * @dev THE MISTAKE THIS PREVENTS, from `LEARNINGS-AND-MISTAKES §A`:
 *
 *        "💸🔗 **frozen constants: the game-rule numbers were unchangeable
 *         forever.** the live NFT contract one-time-set-pinned Duel +
 *         Graveyard, so `CONSECUTIVE_LOSSES_TO_DIE=3`, `MAX_RESURRECTS=3` and
 *         every founder band froze. the owner asked for 4-losses-to-die;
 *         impossible without a whole new collection."
 *
 *      `BUILD-PLAN.md` rule 2 is the response: "wiring legs are two-step
 *      propose/accept or timelocked, **never one-time-set**". Propose/accept is
 *      wrong for these slots — the target is a game contract, not an EOA, and
 *      it cannot call `accept` — so the pattern is a timelock, and the pending
 *      target and its ETA are PUBLIC for the whole delay so a compromised key
 *      cannot repoint the money silently.
 *
 *      Covered here: all three `Bulls` slots, all five `MintDrop` slots, and
 *      the `Jackpot` Duel slot (whose own timelock is separately load-bearing
 *      for the no-withdraw guarantee — see `JackpotNoWithdraw.t.sol`).
 */
contract TimelockedWiringTest is BnbullsBase {
    address internal constant TARGET_A = address(0xAAA1);
    address internal constant TARGET_B = address(0xBBB2);

    // ══════════════════════════════════════════════════════════════════════
    //  The one-time-set is gone
    // ══════════════════════════════════════════════════════════════════════

    function test_theFefersOneTimeSettersDoNotExist() public {
        string[3] memory gone = [
            "setDuelContract(address)",
            "setGraveyardContract(address)",
            "setMintDropContract(address)"
        ];
        for (uint256 i = 0; i < gone.length; i++) {
            (bool ok,) = address(bulls).call(abi.encodeWithSignature(gone[i], TARGET_A));
            assertFalse(ok, "a one-time-set wiring function survives on Bulls");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Bootstrap: immediate, once, only while the slot is zero
    // ══════════════════════════════════════════════════════════════════════

    function test_bootstrapWorksOnceWhileTheSlotIsZero() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));

        (address cur, address pend, uint64 eta) = b.wireOf(Bulls.Wire.Duel);
        assertEq(cur, address(0));
        assertEq(pend, address(0));
        assertEq(eta, 0);

        b.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        assertEq(b.duelContract(), TARGET_A, "bootstrap must be immediate on deploy day");

        vm.expectRevert(abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, TARGET_A));
        b.bootstrapWire(Bulls.Wire.Duel, TARGET_B);
    }

    function test_bootstrapRefusesTheZeroTarget() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        vm.expectRevert(TimelockedAddress.ZeroTarget.selector);
        b.bootstrapWire(Bulls.Wire.Graveyard, address(0));
    }

    function test_everySlotIsIndependent() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        b.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        assertEq(b.graveyardContract(), address(0), "wiring one slot wired another");
        assertEq(b.mintDropContract(), address(0));
        b.bootstrapWire(Bulls.Wire.Graveyard, TARGET_B);
        b.bootstrapWire(Bulls.Wire.MintDrop, address(drop));
        assertEq(b.duelContract(), TARGET_A);
        assertEq(b.graveyardContract(), TARGET_B);
        assertEq(b.mintDropContract(), address(drop));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Every later change: propose -> wait -> commit
    // ══════════════════════════════════════════════════════════════════════

    function test_aLaterChangeMustBeProposedAndAged() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        b.bootstrapWire(Bulls.Wire.Duel, TARGET_A);

        uint64 eta = b.proposeWire(Bulls.Wire.Duel, TARGET_B);
        assertEq(uint256(eta), block.timestamp + b.wiringDelay());

        // The pending target and the ETA are PUBLIC for the whole delay.
        (address cur, address pend, uint64 storedEta) = b.wireOf(Bulls.Wire.Duel);
        assertEq(cur, TARGET_A, "the live wire must not move on propose");
        assertEq(pend, TARGET_B);
        assertEq(storedEta, eta);

        vm.warp(eta - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockedAddress.TimelockNotElapsed.selector, eta, uint64(block.timestamp)
            )
        );
        b.commitWire(Bulls.Wire.Duel);
        assertEq(b.duelContract(), TARGET_A);

        vm.warp(eta);
        b.commitWire(Bulls.Wire.Duel);
        assertEq(b.duelContract(), TARGET_B);

        (, pend, storedEta) = b.wireOf(Bulls.Wire.Duel);
        assertEq(pend, address(0), "the proposal must be cleared on commit");
        assertEq(storedEta, 0);
    }

    function test_commitWithNothingPendingReverts() public {
        vm.expectRevert(TimelockedAddress.NothingPending.selector);
        bulls.commitWire(Bulls.Wire.Duel);
        vm.expectRevert(TimelockedAddress.NothingPending.selector);
        bulls.cancelWire(Bulls.Wire.Duel);
    }

    function test_cancelDropsThePendingChange() public {
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        uint64 eta = bulls.proposeWire(Bulls.Wire.Duel, TARGET_B);

        bulls.cancelWire(Bulls.Wire.Duel);
        (address cur, address pend, uint64 storedEta) = bulls.wireOf(Bulls.Wire.Duel);
        assertEq(cur, TARGET_A);
        assertEq(pend, address(0));
        assertEq(storedEta, 0);

        vm.warp(eta + 1);
        vm.expectRevert(TimelockedAddress.NothingPending.selector);
        bulls.commitWire(Bulls.Wire.Duel);
        assertEq(bulls.duelContract(), TARGET_A);
    }

    /// @dev A second proposal overwrites the first AND restarts the clock, so
    ///      the published ETA is always the real one — a stale proposal can
    ///      never be used to short-circuit the delay on a new target.
    function test_reproposingRestartsTheClock() public {
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        bulls.proposeWire(Bulls.Wire.Duel, TARGET_B);

        vm.warp(block.timestamp + 23 hours);
        uint64 eta2 = bulls.proposeWire(Bulls.Wire.Duel, address(0xC0FFEE));
        assertEq(uint256(eta2), block.timestamp + bulls.wiringDelay());

        vm.warp(eta2 - 1);
        vm.expectRevert();
        bulls.commitWire(Bulls.Wire.Duel);

        vm.warp(eta2);
        bulls.commitWire(Bulls.Wire.Duel);
        assertEq(bulls.duelContract(), address(0xC0FFEE));
    }

    function test_proposeRefusesTheZeroTarget() public {
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        vm.expectRevert(TimelockedAddress.ZeroTarget.selector);
        bulls.proposeWire(Bulls.Wire.Duel, address(0));
    }

    function test_everyWiringCallIsOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert();
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        vm.expectRevert();
        bulls.proposeWire(Bulls.Wire.Duel, TARGET_A);
        vm.expectRevert();
        bulls.commitWire(Bulls.Wire.Duel);
        vm.expectRevert();
        bulls.cancelWire(Bulls.Wire.Duel);
        vm.expectRevert();
        bulls.setWiringDelay(12 hours);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The delay itself is bounded
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A delay below the floor makes the timelock decorative; above the
    ///      ceiling it becomes "never". Both are refused, on all three
    ///      contracts.
    function test_theDelayIsBoundedOnEveryContract() public {
        assertEq(bulls.MIN_WIRING_DELAY(), 6 hours);
        assertEq(bulls.MAX_WIRING_DELAY(), 30 days);
        assertEq(bulls.wiringDelay(), 24 hours);
        assertEq(drop.wiringDelay(), 24 hours);
        assertEq(potBnbull.wiringDelay(), 24 hours);

        vm.expectRevert(abi.encodeWithSelector(Bulls.DelayOutOfRange.selector, uint256(1 hours)));
        bulls.setWiringDelay(1 hours);
        vm.expectRevert(abi.encodeWithSelector(Bulls.DelayOutOfRange.selector, uint256(31 days)));
        bulls.setWiringDelay(31 days);

        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.DelayOutOfRange.selector, uint256(1 hours))
        );
        drop.setWiringDelay(1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.DelayOutOfRange.selector, uint256(31 days))
        );
        drop.setWiringDelay(31 days);

        bulls.setWiringDelay(30 days);
        drop.setWiringDelay(6 hours);
        assertEq(bulls.wiringDelay(), 30 days);
        assertEq(drop.wiringDelay(), 6 hours);
    }

    /// @dev The delay in force is the one at PROPOSE time; shortening it later
    ///      must not pull an in-flight proposal forward.
    function test_shorteningTheDelayDoesNotPullAnInFlightProposalForward() public {
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        uint64 eta = bulls.proposeWire(Bulls.Wire.Duel, TARGET_B);

        bulls.setWiringDelay(6 hours);
        vm.warp(block.timestamp + 6 hours);
        vm.expectRevert();
        bulls.commitWire(Bulls.Wire.Duel);

        vm.warp(eta);
        bulls.commitWire(Bulls.Wire.Duel);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  MintDrop's money slots
    // ══════════════════════════════════════════════════════════════════════

    function test_everyMintDropMoneySlotIsTimelocked() public {
        MintDrop.Wire[4] memory slots = [
            MintDrop.Wire.PriceFeed,
            MintDrop.Wire.Router,
            MintDrop.Wire.JackpotBnbull,
            MintDrop.Wire.JackpotBnb
        ];
        for (uint256 i = 0; i < slots.length; i++) {
            (address cur,,) = drop.wireOf(slots[i]);
            assertTrue(cur != address(0), "harness sanity: the slot is wired");
            vm.expectRevert(abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, cur));
            drop.bootstrapWire(slots[i], TARGET_A);
        }

        (address priceFeed, address router_, address jbull, address jbnb) = drop.wires();
        assertEq(priceFeed, address(feed));
        assertEq(router_, address(router));
        assertEq(jbull, address(potBnbull));
        assertEq(jbnb, address(potBnb));
    }

    function test_committingANewPriceFeedReReadsItsDecimals() public {
        assertEq(drop.feedDecimals(), 8);
        MockAggregator feed18 = new MockAggregator(18, 600e18);

        uint64 eta = drop.proposeWire(MintDrop.Wire.PriceFeed, address(feed18));
        vm.warp(eta);
        drop.commitWire(MintDrop.Wire.PriceFeed);
        feed18.setAnswer(600e18); // the clock moved a day; republish the round

        assertEq(drop.feedDecimals(), 18);
        assertEq(drop.bnbUsdPrice(), BNB_USD_1E18);
    }

    /// @dev A treasury is NOT in the timelocked set, deliberately: it is the
    ///      owner's own revenue, not a lever over anyone else's money.
    function test_theRevenueSlotsAreNotTimelocked() public {
        drop.setTreasury(TARGET_A);
        assertEq(drop.treasury(), TARGET_A);
        drop.setLpTreasury(TARGET_B);
        assertEq(drop.lpTreasury(), TARGET_B);
        drop.setKeeper(TARGET_A);
        assertEq(drop.keeper(), TARGET_A);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The wires actually gate something
    // ══════════════════════════════════════════════════════════════════════

    function test_onlyTheWiredDuelMayMutateABull() public {
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        bulls.mint(alice);
        bulls.mint(alice);

        vm.prank(TARGET_B);
        vm.expectRevert(Bulls.NotAuthorized.selector);
        bulls.applyDuelResult(1, 2, 1_100, 900, 1, false, true);

        vm.prank(TARGET_A);
        bulls.applyDuelResult(1, 2, 1_100, 900, 1, false, true);
        assertEq(bulls.getBull(1).wins, 1);
        assertEq(bulls.getBull(2).losses, 1);
        assertTrue(bulls.isDead(2));
        assertEq(bulls.diedAt(2), block.timestamp);
    }

    function test_onlyTheWiredGraveyardMayReviveOrClaim() public {
        bulls.bootstrapWire(Bulls.Wire.Duel, TARGET_A);
        bulls.bootstrapWire(Bulls.Wire.Graveyard, TARGET_B);
        bulls.mint(alice);
        bulls.mint(alice);
        vm.prank(TARGET_A);
        bulls.applyDuelResult(1, 2, 1_100, 900, 1, false, true);

        vm.prank(alice);
        vm.expectRevert(Bulls.NotAuthorized.selector);
        bulls.resurrect(2);

        // A LIVING bull can never be moved by the takeover path.
        vm.prank(TARGET_B);
        vm.expectRevert(abi.encodeWithSelector(Bulls.NotDead.selector, uint256(1)));
        bulls.graveyardClaim(1, bob);

        vm.prank(TARGET_B);
        bulls.graveyardClaim(2, bob);
        assertEq(bulls.ownerOf(2), bob);

        vm.prank(TARGET_B);
        bulls.resurrect(2);
        assertTrue(bulls.isAlive(2));
    }

    function test_onlyTheWiredMintDropOrTheOwnerMayMint() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Bulls.NotMintDropOrOwner.selector);
        b.mint(alice);

        b.mint(alice); // the owner may, for the dev allocation
        b.bootstrapWire(Bulls.Wire.MintDrop, TARGET_A);
        vm.prank(TARGET_A);
        b.mint(alice);
        assertEq(b.balanceOf(alice), 2);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Jackpot's Duel slot
    // ══════════════════════════════════════════════════════════════════════

    function test_theJackpotDuelSlotFollowsTheSamePattern() public {
        Jackpot pot = new Jackpot(address(bnbull), address(0), address(coord), 50);

        (address cur, address pend, uint64 eta) = pot.duelWire();
        assertEq(cur, address(0));
        assertEq(pend, address(0));
        assertEq(eta, 0);

        pot.bootstrapDuel(TARGET_A);
        assertEq(pot.duel(), TARGET_A);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, TARGET_A));
        pot.bootstrapDuel(TARGET_B);

        uint64 newEta = pot.proposeDuel(TARGET_B);
        (cur, pend,) = pot.duelWire();
        assertEq(cur, TARGET_A);
        assertEq(pend, TARGET_B);

        vm.warp(newEta - 1);
        vm.expectRevert();
        pot.commitDuel();
        vm.warp(newEta);
        pot.commitDuel();
        assertEq(pot.duel(), TARGET_B);

        pot.proposeDuel(TARGET_A);
        pot.cancelDuel();
        vm.expectRevert(TimelockedAddress.NothingPending.selector);
        pot.commitDuel();
    }
}
