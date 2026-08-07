// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "./lib/BnbullsConfig.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BNBull} from "../contracts/BNBull.sol";
import {Jackpot} from "../contracts/Jackpot.sol";

/**
 * @title Handover
 * @notice Move ownership from the deployer to the real owner. Runs AFTER
 *         `Verify` is green, and before the one-way switches.
 *
 * @dev ⚠ THE TWO POTS ARE NOT `Ownable`. They are Chainlink `ConfirmedOwner`,
 *      which is TWO-STEP: `transferOwnership` only PROPOSES, and the new owner
 *      must call `acceptOwnership()` from its own key. Until it does, the
 *      DEPLOYER still owns the pot — while a block explorer's "owner" row and
 *      a casual reading of the transfer transaction both suggest the handover
 *      is done. `AcceptJackpotOwnership` below is the second half, and it has
 *      to be run by the new owner, not by the deployer.
 */
contract Handover is BnbullsConfig {
    error OwnerNotRecorded();
    error OwnerDriftedSinceDeploy(address recorded, address fromEnv);

    function run() external {
        // ⚠ THE GATES `Deploy` HAS, BECAUSE THIS RUN IS THE IRREVERSIBLE ONE.
        // `treasuryGuard` / `keyGuard` / `preflight` used to be called from
        // `Deploy.run()` and nowhere else — so `OWNER` was human-confirmed at
        // DEPLOY time and then CONSUMED here, in a separate process, from a
        // fresh `vm.envOr("OWNER", …)` read that nothing checked. Eight
        // contracts move on that one value and `transferOwnership` has no undo.
        keyGuard();
        chainGuard();

        Cfg memory c = loadConfig(msg.sender);
        Deployment memory d = readDeployment();

        // ⚠ BEFORE THE "nothing to hand over" SHORTCUT, ON PURPOSE. With
        // `OWNER` simply missing from this run's env, `vm.envOr` answers with
        // the deployer, the shortcut below fires, and the script exits 0 having
        // done nothing — while the record says the game was meant to end up
        // somewhere else. A silent no-op that reads as success is worse than a
        // failure, because the operator ticks the runbook line.
        _assertOwnerMatchesRecord(c.roles.owner, d.owner);

        // Rule 1 again, on the run that actually spends the address. The $154
        // was lost to a well-formed address nobody re-checked, and this is the
        // last moment anybody can.
        treasuryGuard(c);

        if (c.roles.owner == msg.sender) {
            console2.log("OWNER == the caller. Nothing to hand over.");
            return;
        }

        console2.log("== handover ==");
        console2.log("  from", msg.sender);
        console2.log("  to  ", c.roles.owner);

        vm.startBroadcast();
        _give(d.bulls, c.roles.owner, "Bulls");
        _give(d.mintDrop, c.roles.owner, "MintDrop");
        _give(d.duel, c.roles.owner, "Duel");
        // Left behind, this one stays owned by the deployer key while
        // `Verify`'s `EXPECT_OWNER` gate says the handover landed — and the
        // owner of `Yards` is who sets `ejectDelay`, i.e. who decides how long
        // a holder waits to get a bull out of the arena.
        _give(d.yards, c.roles.owner, "Yards");
        _give(d.graveyard, c.roles.owner, "Graveyard");
        _give(d.marketplace, c.roles.owner, "Marketplace");
        _give(d.mintSplitter, c.roles.owner, "MintBnbullSplitter");
        _give(d.reviveSplitter, c.roles.owner, "ReviveBuySplitter");
        _give(d.marketSplitter, c.roles.owner, "MarketPotSplitter");

        // Two-step. These only PROPOSE.
        Jackpot(d.jackpotBnbull).transferOwnership(c.roles.owner);
        Jackpot(d.jackpotBnb).transferOwnership(c.roles.owner);
        vm.stopBroadcast();

        console2.log("");
        console2.log("  /!\\ THE TWO POTS ARE NOT HANDED OVER YET.");
        console2.log("      ConfirmedOwner is two-step. Run, FROM THE NEW OWNER'S KEY:");
        console2.log("        forge script script/OneWaySwitches.s.sol:AcceptJackpotOwnership \\");
        console2.log("          --rpc-url $RPC_URL --broadcast");
        console2.log("      Until then the DEPLOYER still owns both pots.");
        console2.log("");
        console2.log("  THEN, and there is no green check on any of this until you do:");
        console2.log("        EXPECT_OWNER=<the address above> \\");
        console2.log("          forge script script/Verify.s.sol:Verify --rpc-url $RPC_URL");
        console2.log("      It asserts owner() on all eight Ownable contracts AND both");
        console2.log("      pots, so a proposal that was never accepted shows up as a");
        console2.log("      failure instead of as a transaction that looked fine.");
    }

    /**
     * @dev The env read that fires the handover, diffed against the env read a
     *      human confirmed on deploy day.
     *
     *      They are two different processes reading the same file at two
     *      different times, and everything in `DEPLOY-SAFETY-PREFLIGHT.md §1`
     *      says treat the second read as suspect: a fork rehearsal between the
     *      two runs is exactly what wrote a throwaway address into fefers'
     *      mainnet env file, and that address passed every check there was
     *      because it was well-formed. This one is not a well-formedness check.
     */
    function _assertOwnerMatchesRecord(address fromEnv, address recorded) private {
        if (recorded == address(0)) {
            console2.log("");
            console2.log("  /!\\ THE DEPLOYMENT RECORD HAS NO 'owner' FIELD.");
            console2.log("      It predates the field, so there is nothing to diff this run's");
            console2.log("      OWNER against and the drift check cannot run. Re-record the");
            console2.log("      deployment before handing eight contracts to an env variable.");
            revert OwnerNotRecorded();
        }
        if (recorded != fromEnv) {
            console2.log("");
            console2.log("  /!\\ OWNER HAS CHANGED SINCE THE DEPLOY.");
            console2.log("      recorded at deploy:", recorded);
            console2.log("      this run's env:    ", fromEnv);
            console2.log("      One of these is wrong and transferOwnership has no undo. If");
            console2.log("      the move is deliberate, re-record the deployment first so the");
            console2.log("      file and the chain agree about who owns the game.");
            revert OwnerDriftedSinceDeploy(recorded, fromEnv);
        }
        console2.log("  [ok] OWNER matches the deployment record:", recorded);
    }

    function _give(address target, address to, string memory label) private {
        Ownable(target).transferOwnership(to);
        console2.log("  transferred", label, target);
    }
}

/**
 * @title AcceptJackpotOwnership
 * @notice The second half of the pot handover. MUST be run by the new owner.
 */
contract AcceptJackpotOwnership is BnbullsConfig {
    function run() external {
        // Broadcasts, so it gets the same gates. This one runs from the NEW
        // OWNER's key rather than the deployer's, which is precisely the run
        // where "which chain is --rpc-url actually pointed at" is least likely
        // to have been checked recently.
        keyGuard();
        chainGuard();

        Deployment memory d = readDeployment();
        console2.log("== accepting pot ownership as", msg.sender, "==");
        vm.startBroadcast();
        Jackpot(d.jackpotBnbull).acceptOwnership();
        Jackpot(d.jackpotBnb).acceptOwnership();
        vm.stopBroadcast();
        console2.log("  BNBULL pot owner", Jackpot(d.jackpotBnbull).owner());
        console2.log("  BNB pot owner   ", Jackpot(d.jackpotBnb).owner());
        console2.log("");
        console2.log("  Now prove the whole handover landed, all ten contracts at once:");
        console2.log("    EXPECT_OWNER=<owner> forge script script/Verify.s.sol:Verify \\");
        console2.log("      --rpc-url $RPC_URL");
    }
}

/**
 * @title OneWaySwitches
 * @notice The irreversible ones, LAST, in the only order that works.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      ⚠ `liftLimits()` BEFORE `renounceOwnership()`
 *      ══════════════════════════════════════════════════════════════════════
 *      `DEPLOY-SAFETY-PREFLIGHT.md §3`, the load-bearing example from the
 *      parent launch. `liftLimits()` is one-way and owner-only. Renounce first
 *      and the launch caps — 1% maxWallet, 0.5% maxTx — are enforced FOREVER
 *      with nobody able to lift them, which chokes the token permanently.
 *      There is a regression test for exactly this
 *      (`test_renouncingBeforeLiftingLimitsChokesTheTokenForever`).
 *
 *      This script enforces the order in code: `renounce` is refused while
 *      `limitsActive` is still true.
 *
 *      Each switch needs its OWN explicit flag. `§3`: "run every one-way switch
 *      with explicit per-action authorization, not in a loop." Nothing here
 *      fires because you ran the script; it fires because you named it.
 *
 *      ⚠ On mainnet the BNBULL token is four.meme's (`DECISIONS.md §4`), so
 *      none of the token switches apply — four.meme owns that contract. They
 *      matter only if we ever self-issue.
 */
contract OneWaySwitches is BnbullsConfig {
    error LimitsStillActive();
    error NothingSelected();

    function run() external {
        // Broadcasts, and every transaction it sends is permanent. Same gates.
        keyGuard();
        chainGuard();

        Deployment memory d = readDeployment();

        bool doLift = vm.envOr("SWITCH_LIFT_LIMITS", false);
        bool doLockBlacklist = vm.envOr("SWITCH_LOCK_BLACKLIST", false);
        bool doRenounceToken = vm.envOr("SWITCH_RENOUNCE_TOKEN", false);

        console2.log("== one-way switches ==");
        console2.log("  SWITCH_LIFT_LIMITS    ", doLift);
        console2.log("  SWITCH_LOCK_BLACKLIST ", doLockBlacklist);
        console2.log("  SWITCH_RENOUNCE_TOKEN ", doRenounceToken);

        if (!doLift && !doLockBlacklist && !doRenounceToken) {
            console2.log("");
            console2.log("  Nothing selected. Every switch here is PERMANENT, so each one");
            console2.log("  needs its own env flag - there is no 'do them all'.");
            console2.log("");
            console2.log("  Looking for SWITCH_FREEZE_NAMES? It is GONE. Freezing the name");
            console2.log("  table is:");
            console2.log("    FREEZE_NAMES=true forge script script/Names.s.sol:SetNames \\");
            console2.log("      --rpc-url $RPC_URL --broadcast");
            revert NothingSelected();
        }

        BNBull token = BNBull(d.bnbull);

        vm.startBroadcast();

        // 1. Rarity: NOTHING TO FREEZE (`DECISIONS.md §31`). The dev-mint
        //    skip-rare swap was the only thing that could write `_rarity` after
        //    construction, and it is deleted — so the table has been immutable
        //    since deploy and `SWITCH_FREEZE_RARITY` is gone with it. The
        //    invariant is asserted in `Verify`: `rarityHash ==
        //    initialRarityHash`, always.

        // 2. Names: NOT HERE ANY MORE, AND DELETED RATHER THAN DEPRECATED.
        //
        //    `SWITCH_FREEZE_NAMES` sealed the table on a COUNTER —
        //    `namesWritten() == 501` — and 501 correct-length wrong names count
        //    to 501 exactly as well as 501 right ones. `SetNames` does the real
        //    check: `namesCommitment` compared against the dealt table, then
        //    all 501 slots re-read off chain and compared byte for byte. Two
        //    routes to a one-way switch, one of them strictly weaker, is an
        //    invitation to take the weaker one on a busy launch day — and
        //    sealing a WRONG name table is unrecoverable, because the name is
        //    what a marketplace, the site and every buyer see forever.
        //
        //    Deleted, not left in place with a warning, for `DECISIONS.md §27`'s
        //    reason: a second path that returns a plausible-but-wrong answer is
        //    exactly how this recurs. `FREEZE_NAMES=true` on `SetNames` is now
        //    the only way to freeze, so the full verification is structural
        //    rather than remembered.

        // 3. Token caps. ⚠ BEFORE any renounce.
        if (doLift) {
            token.liftLimits();
            console2.log("  [done] BNBull.liftLimits()");
        }

        // 4. Blacklist sealed. The strongest trust signal short of renouncing.
        if (doLockBlacklist) {
            token.lockBlacklist();
            console2.log("  [done] BNBull.lockBlacklist()");
        }

        // 5. Renounce. LAST, and refused while the caps are still on.
        if (doRenounceToken) {
            if (token.limitsActive()) {
                console2.log("");
                console2.log("  /!\\ REFUSING TO RENOUNCE: BNBull.limitsActive is still true.");
                console2.log("      Renouncing now would enforce the 1% wallet / 0.5% tx caps");
                console2.log("      FOREVER, with nobody able to lift them. Run with");
                console2.log("      SWITCH_LIFT_LIMITS=true first, confirm limitsActive is");
                console2.log("      false, THEN renounce.");
                revert LimitsStillActive();
            }
            token.renounceOwnership();
            console2.log("  [done] BNBull.renounceOwnership()");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("  Publish every tx hash above. On a fresh contract the receipts");
        console2.log("  ARE the trust story - rug-checkers have nothing else to go on.");
    }
}
