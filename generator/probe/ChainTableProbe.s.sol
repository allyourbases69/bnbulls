// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {Bulls} from "../../contracts/Bulls.sol";

/**
 * @title ChainTableProbe
 * @notice Prints the two hashes that anchor the off-chain art to the chain:
 *         the rarity table and the WEAPON table, both taken from a real
 *         `Bulls` deployed inside the script VM.
 *
 *         Run it:
 *           FOUNDRY_SCRIPT=generator/probe \
 *           forge script generator/probe/ChainTableProbe.s.sol:ChainTableProbe
 *
 * @dev ⚠ WHY IT LIVES HERE AND NOT IN `script/`.
 *      `foundry.toml` sets `script = "script"`, so this file is invisible to
 *      `forge build`, `forge test` and every normal `forge script` run — it
 *      only compiles when you point `FOUNDRY_SCRIPT` at this directory. It is
 *      a verification probe owned by the art generator, and it must not be
 *      able to break anyone else's build.
 *
 *      ⚠ WHY IT EXISTS. `generator/bull.mjs` ports two contract functions to
 *      JavaScript: `_initializeRarity()` (which tier each token is) and
 *      `_rollWeaponInTier()` (which weapon it carries). A port nobody checks
 *      against the original is a guess. `script/Names.s.sol:PrintNamesCommitment`
 *      already proves the rarity port token by token; this adds the weapon
 *      table, which needed real mints to observe because `weaponId` is only
 *      written by `_rollBull` at mint time.
 *
 *      The two hashes printed here are PINNED in
 *      `frontend/scripts/verify-rarity-port.ts`. If the master seed or either
 *      algorithm ever changes, that verifier fails until someone re-runs this
 *      probe — which forces the comparison against the contract to happen
 *      again rather than being quietly skipped.
 *
 *      Nothing is broadcast. No RPC, no keys.
 */
contract ChainTableProbe is Script {
    address private constant HOLDER = address(0xB0115);
    address private constant OWNER = address(0xB011E5);

    function run() external {
        uint256 seed = _readMasterSeed();
        console2.log("== ChainTableProbe ==");
        console2.log("  masterSeed", seed);

        // ⚠ THE CONSTRUCTOR LOST ITS `devWallet` ARGUMENT (`DECISIONS.md §31`
        // — the dev rarity skip is deleted, not deprecated), and this probe was
        // never updated, so it had stopped compiling. Nothing noticed, because
        // it lives outside `foundry.toml`'s `script` path precisely so that
        // `forge build` and `forge test` cannot see it. That is the trade: it
        // can never break anyone else's build, and it can also rot silently.
        // If you are re-pinning hashes and this file does not compile, fix the
        // signature — do not reach for the old pinned values instead.
        //
        // Nothing mutates `_rarity` after construction now, so the observed
        // table IS the constructor's table: the one the names were dealt
        // against and the one `initialRarityHash` covers.
        Bulls bulls = new Bulls(OWNER, seed, bytes32(0));
        // a fixed owner rather than `address(this)`: forge rejects a script
        // relying on its own ephemeral address.
        vm.startPrank(OWNER);

        bytes memory weapons = new bytes(500);
        uint256[12] memory histogram;
        for (uint256 id = 1; id <= 500; id++) {
            bulls.mint(HOLDER);
            uint8 w = bulls.getBull(id).weaponId;
            weapons[id - 1] = bytes1(w);
            histogram[w]++;

            // Belt and braces: the weapon must be inside the token's own tier
            // slice. This is the invariant the generator was violating for 362
            // of the 500 tokens.
            uint8 tier = bulls.rarityOf(id);
            (uint8 start, uint8 count) = _slice(tier);
            require(w >= start && w < start + count, "weapon outside its tier slice");
        }

        bulls.mintKing(HOLDER);
        require(bulls.getBull(501).weaponId == 11, "king must carry slot 11");
        require(bulls.rarityOf(501) == 5, "king must be tier 5");
        vm.stopPrank();

        console2.log("");
        console2.log("  initialRarityHash (keccak256 of the 500 tier bytes):");
        console2.logBytes32(bulls.initialRarityHash());
        console2.log("  rarityHash now (must be identical - no dev skip ran):");
        console2.logBytes32(bulls.rarityHash());
        console2.log("  weaponTableHash (keccak256 of the 500 weaponId bytes):");
        console2.logBytes32(keccak256(weapons));
        console2.log("");
        console2.log("  weapon distribution, catalog index -> count:");
        for (uint256 i = 0; i < 12; i++) {
            console2.log("   ", i, histogram[i]);
        }
        console2.log("");
        console2.log("  Pin both hashes in frontend/scripts/verify-rarity-port.ts.");
    }

    /// @dev Mirror of `Bulls._tierWeaponRange()`, which is private.
    function _slice(uint8 tier) private pure returns (uint8 start, uint8 count) {
        if (tier == 0) return (0, 3);
        if (tier == 1) return (3, 2);
        if (tier == 2) return (5, 2);
        if (tier == 3) return (7, 2);
        if (tier == 4) return (9, 2);
        if (tier == 5) return (11, 1);
        revert("bad tier");
    }

    function _readMasterSeed() private view returns (uint256) {
        string memory path = vm.envOr("NAMES_JSON", string("deployments/names.json"));
        return vm.parseJsonUint(vm.readFile(path), ".masterSeed");
    }
}
