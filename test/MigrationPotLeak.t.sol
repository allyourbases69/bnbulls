// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ══════════════════════════════════════════════════════════════════════════
//  EXTERNAL SECURITY REVIEW — REPRODUCER
//
//  `script/MigrateNative.s.sol` deploys JackpotNative, marks MintDrop and the
//  three splitters as FUNDERS on it, and never repoints any of their
//  `Wire.JackpotBnb` slots. They keep funding the OLD pot. After stage 2 the
//  old pot's `duel()` is a Duel that `Bulls` no longer accepts, so it can
//  never open another ticket — and `sweepForeignToken` reverts on its prize
//  token. Every wei sent there afterwards is burned, forever, continuously.
// ══════════════════════════════════════════════════════════════════════════

import {console2} from "forge-std/console2.sol";
import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";

contract MigrationPotLeakTest is BnbullsBase {
    DuelNative internal newDuel;
    JackpotNative internal newPot;
    Graveyard internal graveN;

    uint256 internal constant SIGNER_PK = 0xB011_51_6E;
    uint16 internal constant DEV_BPS = 1_000;

    /// @dev Replays MigrateNative stage 1 + stage 2, faithfully — every wiring
    ///      call the script makes, and no others.
    function _runMigration() internal {
        graveN = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        graveN.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        graveN.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));
        bulls.bootstrapWire(Bulls.Wire.Graveyard, address(graveN));

        // ── stage 1: deploy ───────────────────────────────────────────────
        newDuel = new DuelNative(
            DuelNative.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                trustedSigner: vm.addr(SIGNER_PK),
                devTreasury: address(0xDE7),
                defaultDevShareBps: DEV_BPS
            })
        );
        newPot = new JackpotNative(address(wbnb), address(0), address(coord), 75);

        // ── stage 1: wire the NEW pot (exactly MigrateNative.s.sol:211-241) ─
        newPot.bootstrapDuel(address(newDuel));
        newPot.setFunder(address(drop), true);
        newPot.setFunder(address(newDuel), true);
        newPot.setRequester(keeper, true);
        newPot.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        newPot.bootstrapPayoutParams(75, 10_000, 0.0168 ether);

        // ── stage 1: wire the NEW duel (MigrateNative.s.sol:248-262) ───────
        newDuel.bootstrapWire(DuelNative.Wire.Graveyard, address(graveN));
        newDuel.bootstrapWire(DuelNative.Wire.JackpotBnbull, address(potBnbull));
        newDuel.bootstrapWire(DuelNative.Wire.JackpotBnb, address(newPot));
        newDuel.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));
        newDuel.addFightAsset(address(wbnb), 100 ether, DEV_BPS);
        newDuel.addFightAsset(address(bnbull), 1_000_000e18, DEV_BPS);

        // ── stage 1: propose the three timelocked slots ────────────────────
        bulls.proposeWire(Bulls.Wire.Duel, address(newDuel));
        graveN.proposeWire(Graveyard.Wire.Duel, address(newDuel));
        potBnbull.proposeDuel(address(newDuel));

        // ── stage 2: commit, 24h later ─────────────────────────────────────
        vm.warp(block.timestamp + 25 hours);
        feed.setUpdatedAt(block.timestamp); // the oracle keeps ticking in reality
        bulls.commitWire(Bulls.Wire.Duel);
        graveN.commitWire(Graveyard.Wire.Duel);
        potBnbull.commitDuel();
    }

    /**
     * @notice ⛔ THE LEAK. After a complete, correctly-executed migration,
     *         MintDrop still funds the DEAD pot and the live pot gets nothing.
     */
    function test_LEAK_mintDropStillFundsTheDeadPotAfterMigration() public {
        _runMigration();

        // The migration's own verification step passes...
        assertTrue(newPot.isFunder(address(drop)), "runbook step 7: mintDrop is a funder");
        // ...while the wire it would have to use still points at the old pot.
        (address wired,,) = drop.wireOf(MintDrop.Wire.JackpotBnb);
        assertEq(wired, address(potBnb), "MintDrop still wired to the OLD pot");

        uint256 oldBefore = potBnb.pool();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        drop.mintWithBNB{value: 5 ether}(alice, 1);

        uint256 leaked = potBnb.pool() - oldBefore;
        console2.log("BNB-pot slice from ONE mint, sent to the dead pot (wei):", leaked);
        console2.log("live pot pool after the same mint (wei):", newPot.pool());

        assertGt(leaked, 0, "the slice went somewhere");
        assertEq(newPot.pool(), 0, "THE LIVE POT RECEIVED NOTHING");
    }

    /**
     * @notice And it is not recoverable. The old pot cannot pay it out and
     *         cannot be swept.
     */
    function test_LEAK_theDeadPotCanNeverReturnTheMoney() public {
        _runMigration();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        drop.mintWithBNB{value: 5 ether}(alice, 1);
        assertGt(potBnb.pool(), 0, "money is in the dead pot");

        // 1. The owner cannot sweep it: the prize token is refused, by design.
        uint256 stuck = potBnb.pool();
        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnb.sweepForeignToken(address(wbnb), owner, stuck);

        // 2. Nothing can open a ticket on it any more. Its `duel()` still
        //    points at the OLD duel, and the new one is refused.
        assertTrue(potBnb.duel() != address(newDuel), "old pot still points at the old duel");
        vm.prank(address(newDuel));
        vm.expectRevert(Jackpot.NotDuel.selector);
        potBnb.recordWin(alice, 1, 1, 1);

        // 3. And the old Duel it does point at can no longer settle a fight,
        //    because Bulls only accepts the new one now.
        assertEq(bulls.duelContract(), address(newDuel), "Bulls cut over");

        // 4. So the queue is empty and will stay empty: no ticket can ever win
        //    this money.
        assertEq(potBnb.pendingTickets(), 0, "no ticket can ever claim it");
    }

    /// @dev The size of the leak scales with mint volume — it is not a one-off.
    function test_LEAK_growsWithEveryMint() public {
        _runMigration();
        vm.deal(alice, 1_000 ether);

        uint256 start = potBnb.pool();
        for (uint256 i; i < 5; i++) {
            vm.prank(alice);
            drop.mintWithBNB{value: 5 ether}(alice, 1);
        }
        uint256 burned = potBnb.pool() - start;
        console2.log("burned after 5 mints (wei):", burned);
        assertGt(burned, 0);
        assertEq(newPot.pool(), 0, "live pot still empty after 5 mints");
    }
}
