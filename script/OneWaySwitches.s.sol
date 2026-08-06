// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "./lib/BnbullsConfig.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BNBull} from "../contracts/BNBull.sol";
import {Bulls} from "../contracts/Bulls.sol";
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
    function run() external {
        Cfg memory c = loadConfig(msg.sender);
        Deployment memory d = readDeployment();

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
        Deployment memory d = readDeployment();
        console2.log("== accepting pot ownership as", msg.sender, "==");
        vm.startBroadcast();
        Jackpot(d.jackpotBnbull).acceptOwnership();
        Jackpot(d.jackpotBnb).acceptOwnership();
        vm.stopBroadcast();
        console2.log("  BNBULL pot owner", Jackpot(d.jackpotBnbull).owner());
        console2.log("  BNB pot owner   ", Jackpot(d.jackpotBnb).owner());
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
        Deployment memory d = readDeployment();

        bool doLift = vm.envOr("SWITCH_LIFT_LIMITS", false);
        bool doLockBlacklist = vm.envOr("SWITCH_LOCK_BLACKLIST", false);
        bool doFreezeNames = vm.envOr("SWITCH_FREEZE_NAMES", false);
        bool doRenounceToken = vm.envOr("SWITCH_RENOUNCE_TOKEN", false);

        console2.log("== one-way switches ==");
        console2.log("  SWITCH_LIFT_LIMITS    ", doLift);
        console2.log("  SWITCH_LOCK_BLACKLIST ", doLockBlacklist);
        console2.log("  SWITCH_FREEZE_NAMES   ", doFreezeNames);
        console2.log("  SWITCH_RENOUNCE_TOKEN ", doRenounceToken);

        if (
            !doLift && !doLockBlacklist && !doFreezeNames && !doRenounceToken
        ) {
            console2.log("");
            console2.log("  Nothing selected. Every switch here is PERMANENT, so each one");
            console2.log("  needs its own env flag - there is no 'do them all'.");
            revert NothingSelected();
        }

        BNBull token = BNBull(d.bnbull);
        Bulls bulls = Bulls(d.bulls);

        vm.startBroadcast();

        // 1. Rarity: NOTHING TO FREEZE (`DECISIONS.md §31`). The dev-mint
        //    skip-rare swap was the only thing that could write `_rarity` after
        //    construction, and it is deleted — so the table has been immutable
        //    since deploy and `SWITCH_FREEZE_RARITY` is gone with it. The
        //    invariant is asserted in `Verify`: `rarityHash ==
        //    initialRarityHash`, always.

        // 2. Names: the table is sealed forever.
        if (doFreezeNames) {
            require(bulls.namesWritten() == 501, "names table incomplete - do NOT freeze");
            bulls.freezeNames();
            console2.log("  [done] Bulls.freezeNames()");
        }

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
