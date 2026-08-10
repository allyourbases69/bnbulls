// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IOldBulls {
    /// @dev Mirrors `Bulls.Bull`. Field ORDER is load-bearing — it is the ABI
    ///      tuple layout, not a convenience.
    struct Bull {
        uint8 strength;
        uint8 dexterity;
        uint8 constitution;
        uint8 intelligence;
        uint8 wisdom;
        uint8 charisma;
        uint8 weaponId;
        uint16 level;
        uint32 xp;
        uint32 elo;
        uint16 wins;
        uint16 losses;
        uint16 ties;
        bool isDead;
        string name;
    }

    function nextTokenId() external view returns (uint32);
    function ownerOf(uint256 tokenId) external view returns (address);
    function kingMinted() external view returns (bool);
    function getBull(uint256 tokenId) external view returns (Bull memory);
    function rarityOf(uint256 tokenId) external view returns (uint8);
    function initialRarityHash() external view returns (bytes32);
    function masterSeed() external view returns (uint256);
}

interface INewBulls is IOldBulls {
    function mint(address to) external returns (uint256 tokenId);
    function mintKing(address to) external returns (uint256);
    function owner() external view returns (address);
    function paused() external view returns (bool);
}

/**
 * @title ReissueBulls — re-mint the collection onto a freshly deployed Bulls.
 *
 * @dev WHY THIS IS SAFE, AND WHY IT REPRODUCES THE COLLECTION EXACTLY.
 *
 *      Every trait derives from `masterSeed` and `tokenId` and NOTHING else.
 *      Verified in `contracts/Bulls.sol`:
 *
 *        _rollBull      statsSeed  = masterSeed ^ (tokenId * 0xbf58476d1ce4e5b9)
 *                       weaponSeed = masterSeed ^ (tokenId * 0x94d049bb133111eb)
 *        _initializeRarity  shuffleSeed = masterSeed ^ 0x5348554646  ("SHUFF")
 *
 *      No `block.timestamp`, no `block.number`, no `blockhash`, no
 *      `address(this)`, no `msg.sender` anywhere in the derivation. So a fresh
 *      Bulls constructed with the SAME `masterSeed` holds a byte-identical
 *      `_rarity` table, and token N rolls byte-identical stats and weapon.
 *      `initialRarityHash` is asserted equal below, which proves the table
 *      matched before a single bull is minted.
 *
 *      Names are NOT derived on chain — they are published by `Names.s.sol`
 *      from the same `deployments/names.json`, against the same immutable
 *      `namesCommitment`. Same file in, same names out.
 *
 *      ⚠ TOKEN IDS ARE ASSIGNED SEQUENTIALLY BY `mint`. There is no `mintTo(id)`.
 *      So the ONLY way to reproduce the token -> owner mapping is to mint in
 *      ascending token order, handing each mint to whoever holds that same id
 *      on the old contract. That is exactly what this script does, and it reads
 *      the recipients off the OLD contract rather than a hardcoded list, so a
 *      transfer between the audit and the run cannot desync it.
 *
 *      WHAT IS NOT CARRIED OVER, BY DESIGN: elo, wins, losses, ties, level, xp,
 *      `isDead`, `consecutiveLosses`, `diedAt`, `resurrectsUsed`. Every bull is
 *      re-issued FRESH at starting elo. There is no setter for combat history
 *      and adding one would be a lie in the ABI — the record is meant to be
 *      earned. The runbook states this for owner sign-off.
 *
 *      Env:
 *        OLD_BULLS   address of the retired collection (source of truth)
 *        NEW_BULLS   address of the freshly deployed collection (target)
 *        REISSUE_KING  "true" to also mint #501 to the old king's holder
 */
contract ReissueBulls is Script {
    error SeedMismatch(uint256 oldSeed, uint256 newSeed);
    error RarityMismatch(bytes32 oldHash, bytes32 newHash);
    error TargetNotEmpty(uint32 nextTokenId);
    error NotOwner(address expected, address actual);
    error TargetPaused();
    error OwnerMismatch(uint256 tokenId, address expected, address actual);
    error TraitMismatch(uint256 tokenId);

    function run() external {
        address oldBulls = vm.envAddress("OLD_BULLS");
        address newBulls = vm.envAddress("NEW_BULLS");
        bool reissueKing = vm.envOr("REISSUE_KING", false);
        address deployer = msg.sender;

        IOldBulls o = IOldBulls(oldBulls);
        INewBulls n = INewBulls(newBulls);

        console2.log("== reissue bulls ==");
        console2.log("  from (retired)", oldBulls);
        console2.log("  to   (fresh)  ", newBulls);

        // ── GATE 1: the two collections must share a seed ────────────────
        // If the seeds differ, every trait differs and re-issuing would hand
        // people DIFFERENT bulls under the same numbers. Refuse.
        uint256 oldSeed = o.masterSeed();
        uint256 newSeed = n.masterSeed();
        if (oldSeed != newSeed) revert SeedMismatch(oldSeed, newSeed);
        console2.log("  masterSeed matches", oldSeed);

        // ── GATE 2: the shuffled rarity table must be identical ──────────
        // This is the strongest single proof available before minting: it is
        // the keccak of the whole post-shuffle table, taken in the constructor.
        bytes32 oldHash = o.initialRarityHash();
        bytes32 newHash = n.initialRarityHash();
        if (oldHash != newHash) revert RarityMismatch(oldHash, newHash);
        console2.log("  initialRarityHash matches");
        console2.logBytes32(newHash);

        // ── GATE 3: the target must be empty, unpaused, and ours ─────────
        // Minting into a partially populated collection would shift every
        // subsequent token id and silently hand out the wrong bulls.
        uint32 targetNext = n.nextTokenId();
        if (targetNext != 1) revert TargetNotEmpty(targetNext);
        address targetOwner = n.owner();
        if (targetOwner != deployer) revert NotOwner(deployer, targetOwner);
        if (n.paused()) revert TargetPaused();

        uint32 lastId = o.nextTokenId() - 1;
        console2.log("  bulls to re-issue", lastId);

        // ── Read every recipient BEFORE broadcasting ─────────────────────
        // Reading first means the whole recipient set is resolved against one
        // consistent view, and a revert here costs nothing.
        address[] memory recipients = new address[](lastId + 1);
        for (uint256 id = 1; id <= lastId; id++) {
            recipients[id] = o.ownerOf(id);
        }

        vm.startBroadcast();
        for (uint256 id = 1; id <= lastId; id++) {
            uint256 minted = n.mint(recipients[id]);
            // `mint` assigns sequentially; if that ever drifts, stop dead
            // rather than continue handing out mismatched ids.
            require(minted == id, "ReissueBulls: token id drifted");
        }
        if (reissueKing && o.kingMinted()) {
            n.mintKing(o.ownerOf(501));
            console2.log("  king #501 re-issued");
        }
        vm.stopBroadcast();

        _verifyAll(oldBulls, newBulls, lastId, recipients);
    }

    /**
     * @dev Post-mint verification, in its own stack frame.
     *
     *      `run()` already carries the config, both interfaces, the seed and
     *      hash pairs and the recipient array; folding this loop into it blows
     *      the stack. Splitting is not cosmetic — it is what lets the check
     *      exist at all without `--via-ir`.
     */
    function _verifyAll(
        address oldBulls,
        address newBulls,
        uint32 lastId,
        address[] memory recipients
    ) private view {
        console2.log("");
        console2.log("== verifying every token against the retired collection ==");
        for (uint256 id = 1; id <= lastId; id++) {
            address got = INewBulls(newBulls).ownerOf(id);
            if (recipients[id] != got) revert OwnerMismatch(id, recipients[id], got);

            // Traits must match to the byte. Combat history deliberately does
            // NOT — the fingerprint covers only what the seed determines.
            if (_seedFingerprint(oldBulls, id) != _seedFingerprint(newBulls, id)) {
                revert TraitMismatch(id);
            }
        }

        console2.log("  all", lastId, "bulls match on owner, stats, weapon, tier and name.");
        console2.log("");
        console2.log("  NOT carried over (by design): elo, wins/losses/ties, level,");
        console2.log("  xp, death flag, loss streaks, revive count. Every bull starts fresh.");
    }

    /**
     * @dev Hash of ONLY the seed-determined traits, in its own stack frame.
     *
     *      Two reasons it is a hash and not a field-by-field compare: the
     *      fifteen-field struct blows the stack when destructured twice in one
     *      frame, and a hash cannot be accidentally written to compare fewer
     *      fields than it appears to.
     *
     *      DELIBERATELY EXCLUDED: level, xp, elo, wins, losses, ties, isDead.
     *      Those are earned history, not seed output, and are expected to
     *      differ — a fresh bull starts at 1000 elo with a clean record.
     */
    function _seedFingerprint(address bulls, uint256 id) private view returns (bytes32) {
        IOldBulls.Bull memory b = IOldBulls(bulls).getBull(id);
        return keccak256(
            abi.encode(
                b.strength,
                b.dexterity,
                b.constitution,
                b.intelligence,
                b.wisdom,
                b.charisma,
                b.weaponId,
                b.name,
                IOldBulls(bulls).rarityOf(id)
            )
        );
    }
}
