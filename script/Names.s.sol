// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "./lib/BnbullsConfig.sol";
import {Bulls} from "../contracts/Bulls.sol";

/**
 * @title PrintNamesCommitment
 * @notice `forge script script/Names.s.sol:PrintNamesCommitment`
 *
 *         Prints the commitment the `Bulls` constructor will be given, and —
 *         more importantly — PROVES that the off-chain rarity port in
 *         `scripts/gen-names.mjs` matches the real constructor.
 *
 * @dev No RPC, no keys, no broadcast. It deploys a throwaway `Bulls` inside the
 *      script VM with the same `masterSeed` and compares all 500 tiers against
 *      `deployments/rarity.json`.
 *
 *      ⚠ WHY THIS CHECK EXISTS. `DECISIONS.md §9` makes the peerage rank in a
 *      name the rarity ladder itself, so a name is only right if it was dealt
 *      against the tier the CHAIN assigns. The generator's `assignBands()` uses
 *      an LCG over the ID list; `Bulls._initializeRarity()` uses Xorshift128+
 *      over the tier array. They are different shuffles and they do not agree.
 *      `gen-names.mjs` therefore ports the on-chain one — and a port is only
 *      worth having if something checks it. `namesCommitment` is immutable and
 *      `freezeNames()` is one-way, so there is no second chance here.
 */
contract PrintNamesCommitment is BnbullsConfig {
    error RarityPortMismatch(uint256 tokenId, uint8 chainTier, uint256 fileTier);

    function run() external {
        string[] memory names = readNames();
        uint256 seed = readMasterSeed();
        bytes32 commitment = namesCommitment(names);

        console2.log("== dealt name table ==");
        console2.log("  count     ", names.length);
        console2.log("  masterSeed", seed);
        console2.log("  commitment (keccak256(abi.encode(string[501]))):");
        console2.logBytes32(commitment);
        console2.log("");
        console2.log("  #1  ", names[0]);
        console2.log("  #250", names[249]);
        console2.log("  #500", names[499]);
        console2.log("  #501", names[500]);

        _checkRarityPort(seed, commitment);
    }

    function _checkRarityPort(uint256 seed, bytes32 commitment) private {
        string memory path = vm.envOr("RARITY_JSON", string("deployments/rarity.json"));
        uint256[] memory tiers = vm.parseJsonUintArray(vm.readFile(path), ".tiers");
        require(tiers.length == 500, "rarity.json must hold 500 tiers");

        // The real constructor, run locally. Nothing is broadcast.
        Bulls scratch = new Bulls(msg.sender, seed, commitment);

        uint256[5] memory counts;
        for (uint256 id = 1; id <= 500; id++) {
            uint8 onChain = scratch.rarityOf(id);
            if (uint256(onChain) != tiers[id - 1]) {
                console2.log("  [FAIL] rarity port mismatch at token", id);
                console2.log("         chain", onChain);
                console2.log("         file ", tiers[id - 1]);
                revert RarityPortMismatch(id, onChain, tiers[id - 1]);
            }
            counts[onChain]++;
        }

        console2.log("");
        console2.log("== rarity port verified against the real constructor ==");
        console2.log("  common   ", counts[0]);
        console2.log("  uncommon ", counts[1]);
        console2.log("  rare     ", counts[2]);
        console2.log("  epic     ", counts[3]);
        console2.log("  legendary", counts[4]);
        console2.log("  initialRarityHash:");
        console2.logBytes32(scratch.initialRarityHash());
        console2.log("");
        console2.log("  Publish that hash with the seed before the first mint. Anyone can");
        console2.log("  re-derive the shuffle and check it, which is the whole point.");
    }
}

/**
 * @title SetNames
 * @notice `forge script script/Names.s.sol:SetNames --rpc-url $RPC_URL --broadcast`
 *
 *         Publish the 501 dealt names in batches, then optionally seal them.
 *
 * @dev A separate script from `Wire` because it is ~11 transactions of pure
 *      calldata and it must be resumable: a run that dies on batch 7 should
 *      pick up at batch 7, not start over. Already-correct names are skipped.
 *
 *      ⚠ `freezeNames()` IS ONE-WAY. It runs only when `FREEZE_NAMES=true` AND
 *      all 501 slots match the dealt table exactly. Freezing a table with a
 *      typo in it is permanent: the name is what a marketplace, the site and
 *      every buyer will see forever.
 */
contract SetNames is BnbullsConfig {
    error CommitmentMismatch(bytes32 onChain, bytes32 computed);
    error TableIncomplete(uint256 written);

    function run() external {
        Deployment memory d = readDeployment();
        Bulls b = Bulls(d.bulls);

        string[] memory names = readNames();
        bytes32 computed = namesCommitment(names);

        console2.log("== SetNames ==");
        console2.log("  Bulls        ", d.bulls);
        console2.log("  names written", b.namesWritten(), "/ 501");
        console2.log("  frozen       ", b.namesFrozen());

        // The commitment was made BEFORE the sale and is immutable. If it does
        // not match the table we are about to publish, the table is not the one
        // that was committed to and publishing it would break the fairness
        // claim rather than prove it.
        bytes32 onChain = b.namesCommitment();
        if (onChain != bytes32(0) && onChain != computed) {
            console2.log("  [FAIL] the dealt table does not match Bulls.namesCommitment.");
            console2.log("         on chain:");
            console2.logBytes32(onChain);
            console2.log("         computed:");
            console2.logBytes32(computed);
            console2.log("         Either names.json changed after deploy, or this is the");
            console2.log("         wrong deployment. Do not publish.");
            revert CommitmentMismatch(onChain, computed);
        }

        if (b.namesFrozen()) {
            console2.log("  names are already frozen. Nothing to do.");
            return;
        }

        uint256 batch = vm.envOr("NAMES_BATCH", uint256(50));
        require(batch > 0 && batch <= 501, "NAMES_BATCH out of range");

        vm.startBroadcast();
        uint256 written = 0;
        for (uint256 start = 1; start <= 501; start += batch) {
            uint256 end = start + batch - 1;
            if (end > 501) end = 501;

            // Skip a batch that is already correct, so a failed run resumes.
            bool dirty = false;
            for (uint256 id = start; id <= end; id++) {
                if (!_eq(b.nameOf(id), names[id - 1])) {
                    dirty = true;
                    break;
                }
            }
            if (!dirty) {
                console2.log("  [ok]  batch", start, end);
                continue;
            }

            string[] memory chunk = new string[](end - start + 1);
            for (uint256 i = 0; i < chunk.length; i++) {
                chunk[i] = names[start - 1 + i];
            }
            b.setNames(start, chunk);
            written += chunk.length;
            console2.log("  [set] batch", start, end);
        }
        vm.stopBroadcast();

        console2.log("  published this run:", written);
        console2.log("  namesWritten now:  ", b.namesWritten());

        if (!vm.envOr("FREEZE_NAMES", false)) {
            console2.log("");
            console2.log("  NOT FROZEN. Re-run with FREEZE_NAMES=true once the table has been");
            console2.log("  read back and eyeballed. freezeNames() is ONE-WAY.");
            return;
        }

        // Belt and braces before a one-way switch: every slot re-read off chain
        // and compared, not just the counter.
        for (uint256 id = 1; id <= 501; id++) {
            if (!_eq(b.nameOf(id), names[id - 1])) {
                console2.log("  [FAIL] token", id, "does not match the dealt table.");
                revert TableIncomplete(id);
            }
        }
        if (b.namesWritten() != 501) revert TableIncomplete(b.namesWritten());

        vm.startBroadcast();
        b.freezeNames();
        vm.stopBroadcast();
        console2.log("  FROZEN. The name table is now permanent.");
    }
}
