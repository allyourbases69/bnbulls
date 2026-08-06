// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Stats} from "../contracts/lib/Stats.sol";

/**
 * @title BullsRarityTest
 * @notice PRIORITY 9. Rarity, weapons, and the absence of founders.
 *
 * @dev `DECISIONS.md §7` fixes the ladder and the counts:
 *        common 200 / uncommon 130 / rare 90 / epic 50 / legendary 30 = 500,
 *        plus the 1-of-1 king at #501. "counts and clean-chances carried over
 *        from fefers 1:1, so the rarity maths is unchanged — only the labels
 *        moved."
 *
 *      `DECISIONS.md §11` deletes founders outright — "no founder gold 1-25, no
 *      founder 26-50, no founder badges, no special pot percentage, no founder
 *      freebie revive" — and the fefers `isHouseOutlaw` flag with them, because
 *      it existed only to stop keeper-owned tokens in the founder range
 *      pocketing founder perks. `test_thereIsNoFounderAnything` probes for the
 *      whole family by selector: absence is a decision, so it gets an assertion.
 *
 *      `initialRarityHash` is the fairness proof. It is captured in the
 *      constructor the instant the Fisher-Yates shuffle finishes, so anyone can
 *      re-derive the shuffle off-chain from `masterSeed` alone and check it
 *      matches. It is `immutable`; `rarityHash()` is the live view.
 *
 *      ⚠ SINCE `DECISIONS.md §31` THOSE TWO MUST BE EQUAL FOREVER. The
 *      dev-mint skip-rare swap was the only thing that could ever write
 *      `_rarity` after construction, and it was a correctness bug rather than a
 *      preference: it moved a token's tier away from its dealt name and its
 *      sprite AFTER the commitment, silently, permanently, and depending on
 *      mint ORDER — so no off-chain table could be made correct. `§27` is what
 *      that class of bug costs (377 of 500 tiers wrong, caught with hours to
 *      spare). `test_theLiveRarityHashCanNeverDivergeFromTheCommitment` is the
 *      invariant that replaces the deleted freeze.
 */
contract BullsRarityTest is Test {
    Bulls internal bulls;
    address internal owner;
    address internal alice = address(0xA11CE);
    address internal dev = address(0xD3FDE5);

    uint256 internal constant SEED = 0xB011;

    function setUp() public {
        owner = address(this);
        bulls = new Bulls(owner, SEED, bytes32(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Tier counts
    // ══════════════════════════════════════════════════════════════════════

    function test_tierCountsAreExactlyTwoHundredOneThirtyNinetyFiftyThirty() public view {
        uint256[6] memory counts = _tierCounts();
        assertEq(counts[0], 200, "common");
        assertEq(counts[1], 130, "uncommon");
        assertEq(counts[2], 90, "rare");
        assertEq(counts[3], 50, "epic");
        assertEq(counts[4], 30, "legendary");
        assertEq(counts[5], 0, "no king inside the 500");
        assertEq(counts[0] + counts[1] + counts[2] + counts[3] + counts[4], 500);
        assertEq(uint256(bulls.MAX_SUPPLY()), 500);
        assertEq(uint256(bulls.KING_TOKEN_ID()), 501);
    }

    function test_theKingIsTierFiveAndTheOnlyOne() public view {
        assertEq(bulls.rarityOf(501), 5);
        for (uint256 i = 1; i <= 500; i++) {
            assertLt(bulls.rarityOf(i), 5, "a regular token rolled the king tier");
        }
    }

    function test_rarityOfRejectsTokensOutsideTheDrop() public {
        vm.expectRevert(abi.encodeWithSelector(Bulls.InvalidTokenId.selector, uint256(0)));
        bulls.rarityOf(0);
        vm.expectRevert(abi.encodeWithSelector(Bulls.InvalidTokenId.selector, uint256(502)));
        bulls.rarityOf(502);
    }

    /// @dev Rarity is fixed at deploy by the shuffle and readable before a
    ///      token is minted — which is what lets the table be audited against
    ///      `masterSeed` before the sale opens.
    function test_rarityIsReadableBeforeAnythingIsMinted() public view {
        assertEq(bulls.nextTokenId(), 1);
        bulls.rarityOf(500); // must not revert
    }

    function test_theShuffleIsDeterministicFromTheMasterSeed() public {
        Bulls same = new Bulls(owner, SEED, bytes32(0));
        Bulls other = new Bulls(owner, SEED + 1, bytes32(0));
        assertEq(same.initialRarityHash(), bulls.initialRarityHash(), "same seed, same shuffle");
        assertTrue(
            other.initialRarityHash() != bulls.initialRarityHash(), "seed change did nothing"
        );

        // ...and the counts are seed-independent.
        uint256[6] memory a = _tierCountsOf(other);
        assertEq(a[0], 200);
        assertEq(a[4], 30);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  `initialRarityHash` — captured before any mutation, never moves
    // ══════════════════════════════════════════════════════════════════════

    function test_initialRarityHashMatchesTheTableAtDeploy() public view {
        assertEq(bulls.initialRarityHash(), bulls.rarityHash());
        assertTrue(bulls.initialRarityHash() != bytes32(0));
    }

    /**
     * @notice THE INVARIANT THAT REPLACED `freezeRarity()` (`DECISIONS.md
     *         §31`). The live table can NEVER diverge from the committed one,
     *         so a difference between these two reads is visible from a block
     *         explorer without anyone reading source.
     *
     * @dev Driven over a FULL 500-token mint, to every kind of recipient, in
     *      mint order — because mint order is precisely what the deleted skip
     *      made the outcome depend on. The distribution is re-counted at the
     *      end for the same reason: a mutation that happened to preserve the
     *      hash by luck would still show up as a moved tier count.
     */
    function test_theLiveRarityHashCanNeverDivergeFromTheCommitment() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        bytes32 captured = b.initialRarityHash();
        assertEq(captured, b.rarityHash(), "they disagreed before a single mint");

        for (uint256 i = 1; i <= 500; i++) {
            // Alternate the recipient, including the address the dev-wallet
            // skip used to key off, so a resurrected version of it would fire.
            b.mint(i % 3 == 0 ? dev : (i % 3 == 1 ? alice : address(0xB0B)));
            assertEq(b.rarityHash(), captured, "the live table MOVED at mint");
            assertEq(b.initialRarityHash(), captured, "the commitment MOVED");
        }

        uint256[6] memory counts = _tierCountsOf(b);
        assertEq(counts[0], 200);
        assertEq(counts[1], 130);
        assertEq(counts[2], 90);
        assertEq(counts[3], 50);
        assertEq(counts[4], 30);
    }

    /// @dev And the dev wallet is no longer special in any direction: owner
    ///      call, `§31` — "dev can mint rare epic or legendary if he pays,
    ///      that's fine". A run of dev mints must contain a rare or better, or
    ///      something is still filtering them.
    function test_theDevWalletIsNoLongerSpecialAndCanPullRareOrBetter() public {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        bool sawRareOrBetter;
        for (uint256 i = 1; i <= 60; i++) {
            b.mint(dev);
            if (b.rarityOf(i) >= 2) sawRareOrBetter = true;
        }
        assertTrue(sawRareOrBetter, "something is still skipping rares for the dev");
    }

    /// @dev The deleted surface is really gone, not merely unused.
    function test_theDevSkipSurfaceIsGoneFromTheAbi() public {
        (bool ok,) = address(bulls).call(abi.encodeWithSignature("devWallet()"));
        assertFalse(ok, "Bulls.devWallet() still exists");
        (ok,) = address(bulls).call(abi.encodeWithSignature("freezeRarity()"));
        assertFalse(ok, "Bulls.freezeRarity() still exists");
        (ok,) = address(bulls).call(abi.encodeWithSignature("rarityFrozen()"));
        assertFalse(ok, "Bulls.rarityFrozen() still exists");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  No founder anything (DECISIONS §11)
    // ══════════════════════════════════════════════════════════════════════

    function test_thereIsNoFounderAnything() public {
        string[10] memory gone = [
            "isHouseOutlaw(uint256)",
            "setHouseOutlaw(uint256,bool)",
            "isFounder(uint256)",
            "founderTier(uint256)",
            "founderBadge(uint256)",
            "FOUNDER_GOLD_MAX()",
            "FOUNDER_MAX()",
            "founderBandOf(uint256)",
            "houseFlag(uint256)",
            "freeRevivesLeft(uint256)"
        ];
        for (uint256 i = 0; i < gone.length; i++) {
            (bool ok,) = address(bulls).call(abi.encodeWithSignature(gone[i], uint256(1)));
            assertFalse(ok, "a founder-era function survives on Bulls");
        }
    }

    /// @dev Rarity is carried entirely by the tier ladder now, so tokens 1-50
    ///      are statistically ordinary rather than special.
    function test_theFirstFiftyTokensAreNotSpecial() public view {
        uint256 rareOrBetter;
        for (uint256 i = 1; i <= 50; i++) {
            if (bulls.rarityOf(i) >= 2) rareOrBetter++;
        }
        assertGt(rareOrBetter, 0, "tokens 1-50 look like a reserved founder band");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The weapon catalog
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Twelve slots, LOCKED, with the fefers damage/speed/type tuples
    ///         slot for slot — the combat balance does not move in the port.
    function test_theWeaponCatalogIsExactlyTheSpecifiedTwelve() public view {
        assertEq(bulls.weaponCount(), 12);

        _assertWeapon(0, "Shiv", 6, 11, 9, 0, 18);
        _assertWeapon(1, "Pitchfork", 8, 13, 6, 1, 17);
        _assertWeapon(2, "Maul", 8, 13, 5, 1, 15);
        _assertWeapon(3, "Cleaver", 10, 15, 6, 0, 12);
        _assertWeapon(4, "Hornbow", 11, 16, 7, 2, 11);
        _assertWeapon(5, "Bolter", 14, 22, 4, 2, 9);
        _assertWeapon(6, "Morningstar", 14, 24, 3, 1, 7);
        _assertWeapon(7, "Reaper", 15, 22, 6, 0, 5);
        _assertWeapon(8, "Sledge", 16, 24, 5, 0, 3);
        _assertWeapon(9, "Ring", 22, 35, 2, 2, 2);
        _assertWeapon(10, "Pike", 25, 40, 6, 2, 1);
        // The king-only twelfth slot. Weight 0 because it is in no weighted pool.
        _assertWeapon(11, "Gilded Pike", 50, 100, 10, 2, 0);
    }

    function test_theDropWeaponWeightsSumToOneHundred() public view {
        uint256 total;
        for (uint8 i = 0; i < 11; i++) {
            total += bulls.getWeapon(i).weight;
        }
        assertEq(total, 100, "slots 0..10 must sum to 100");
        assertEq(bulls.getWeapon(11).weight, 0, "the king weapon must carry no weight");
    }

    function test_getWeaponRejectsAnUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(Bulls.InvalidWeaponId.selector, uint8(12)));
        bulls.getWeapon(12);
    }

    /**
     * @notice THE KING-ONLY SLOT IS NEVER ASSIGNED TO A NORMAL TOKEN, and every
     *         bull's weapon sits inside its own tier's slice.
     *
     * @dev All 500 minted, not sampled. The slices are the fefers slices
     *      unchanged:
     *        common 0-2 / uncommon 3-4 / rare 5-6 / epic 7-8 / legendary 9-10
     *        king 11 — reachable only via `mintKing`.
     */
    function test_theKingWeaponIsNeverAssignedToANormalToken() public {
        uint8[6] memory start = [0, 3, 5, 7, 9, 11];
        uint8[6] memory count = [3, 2, 2, 2, 2, 1];

        for (uint256 i = 1; i <= 500; i++) {
            bulls.mint(alice);
            uint8 tier = bulls.rarityOf(i);
            uint8 w = bulls.getBull(i).weaponId;
            assertTrue(w != 11, "a normal bull was handed the king's Gilded Pike");
            assertGe(w, start[tier], "weapon below its tier slice");
            assertLt(w, start[tier] + count[tier], "weapon above its tier slice");
        }
        assertEq(bulls.nextTokenId(), 501);
    }

    function test_supplyExhaustsAfterFiveHundredAndTheKingIsSeparate() public {
        for (uint256 i = 0; i < 500; i++) {
            bulls.mint(alice);
        }
        vm.expectRevert(Bulls.SupplyExhausted.selector);
        bulls.mint(alice);

        bulls.mintKing(alice);
        assertEq(bulls.ownerOf(501), alice);
        assertEq(bulls.balanceOf(alice), 501);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The king
    // ══════════════════════════════════════════════════════════════════════

    function test_theKingIsLordWagyuAndCanOnlyBeMintedOnce() public {
        bulls.mintKing(alice);
        Bulls.Bull memory k = bulls.getBull(501);

        assertEq(k.name, "Lord Wagyu");
        assertEq(k.strength, 18);
        assertEq(k.dexterity, 18);
        assertEq(k.constitution, 18);
        assertEq(k.intelligence, 18);
        assertEq(k.wisdom, 18);
        assertEq(k.charisma, 18);
        assertEq(k.weaponId, 11, "the king carries the king-only weapon");
        assertEq(k.elo, 2_000);
        assertEq(k.level, 10);
        assertFalse(k.isDead);

        vm.expectRevert(Bulls.KingAlreadyMinted.selector);
        bulls.mintKing(alice);

        vm.prank(alice);
        vm.expectRevert();
        bulls.mintKing(alice);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Stats
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Every rolled bull must spend EXACTLY the 32-point budget and stay
    ///      inside [8, 18]. The roll loop has a bail-out branch, so this is the
    ///      assertion that it never bails out early with points unspent.
    function test_everyRolledBullSpendsTheWholePointBuyBudget() public {
        for (uint256 i = 1; i <= 120; i++) {
            bulls.mint(alice);
            Stats.StatBlock memory s = bulls.getStats(i);
            uint8[6] memory v =
                [s.strength, s.dexterity, s.constitution, s.intelligence, s.wisdom, s.charisma];
            uint256 spent;
            for (uint256 k = 0; k < 6; k++) {
                assertGe(v[k], 8);
                assertLe(v[k], 18);
                spent += _pointCost(v[k]);
            }
            assertEq(spent, 32, "a bull was rolled off-budget");
        }
    }

    function test_aFreshBullStartsAtTheStandardEloAndLevel() public {
        bulls.mint(alice);
        Bulls.Bull memory b = bulls.getBull(1);
        assertEq(b.elo, bulls.STARTING_ELO());
        assertEq(b.elo, 1_000);
        assertEq(b.level, 1);
        assertEq(b.wins, 0);
        assertEq(b.losses, 0);
        assertEq(b.ties, 0);
        assertFalse(b.isDead);
        assertEq(uint256(bulls.MIN_ELO()), 100);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Names are DEALT, not rolled
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `DECISIONS.md §9`: names are dealt off-chain through a shared
    ///      `taken` set (501 names, 501 unique) and published here, checked
    ///      against a commitment made BEFORE the sale.
    function test_namesArePublishedAgainstACommitmentAndThenSealed() public {
        bytes32 commitment = keccak256("the dealt table");
        Bulls b = new Bulls(owner, SEED, commitment);
        assertEq(b.namesCommitment(), commitment);
        assertEq(b.namesWritten(), 0);

        string[] memory names = new string[](3);
        names[0] = "Sid Calverley";
        names[1] = "Sir Ferdinand Shorthose";
        names[2] = "Baron Bovill of Harkaway";
        b.setNames(1, names);
        assertEq(b.namesWritten(), 3);
        assertEq(b.nameOf(2), "Sir Ferdinand Shorthose");

        // Readable before mint, so the table can be audited without minting.
        assertEq(b.nameOf(3), "Baron Bovill of Harkaway");

        string[] memory kingName = new string[](1);
        kingName[0] = "Lord Wagyu";
        b.setNames(501, kingName); // #501 is addressable even though > MAX_SUPPLY

        string[] memory bad = new string[](1);
        bad[0] = "Nobody";
        vm.expectRevert(abi.encodeWithSelector(Bulls.InvalidTokenId.selector, uint256(502)));
        b.setNames(502, bad);

        b.freezeNames();
        assertTrue(b.namesFrozen());
        vm.expectRevert(Bulls.NamesAreFrozen.selector);
        b.setNames(1, names);
    }

    function test_setNamesRejectsAnEmptyBatchAndNonOwners() public {
        string[] memory none = new string[](0);
        vm.expectRevert(Bulls.EmptyBatch.selector);
        bulls.setNames(1, none);

        string[] memory one = new string[](1);
        one[0] = "Old Cliff Beeston";
        vm.prank(alice);
        vm.expectRevert();
        bulls.setNames(1, one);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The resurrection multiplier ladder is a BOUNDED SETTER, not a constant
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Fefers hard-coded `[1, 3, 10, 30, 100, 500]` into a view. The whole
    ///      point of `BUILD-PLAN` rule 2 is that a player-facing number must be
    ///      retunable without a redeploy.
    function test_theRarityCostLadderIsRetunableWithinItsCeiling() public {
        uint16[6] memory expected = [uint16(1), 3, 10, 30, 100, 500];
        for (uint8 i = 0; i < 6; i++) {
            assertEq(bulls.rarityCostMult(i), expected[i]);
        }

        bulls.mint(alice);
        uint8 tier = bulls.rarityOf(1);
        assertEq(bulls.computeResurrectionCost(1, 5e18), 5e18 * expected[tier]);

        bulls.setRarityCostMult(tier, 7);
        assertEq(bulls.computeResurrectionCost(1, 5e18), 35e18);

        uint16 cap = bulls.MAX_RARITY_MULT();
        vm.expectRevert(abi.encodeWithSelector(Bulls.MultTooHigh.selector, cap + 1, cap));
        bulls.setRarityCostMult(0, cap + 1);
        vm.expectRevert(abi.encodeWithSelector(Bulls.MultTooHigh.selector, uint16(0), cap));
        bulls.setRarityCostMult(0, 0);
        vm.expectRevert(abi.encodeWithSelector(Bulls.InvalidTier.selector, uint8(6)));
        bulls.setRarityCostMult(6, 1);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _tierCounts() internal view returns (uint256[6] memory counts) {
        return _tierCountsOf(bulls);
    }

    function _tierCountsOf(Bulls b) internal view returns (uint256[6] memory counts) {
        for (uint256 i = 1; i <= 500; i++) {
            counts[b.rarityOf(i)] += 1;
        }
    }

    function _assertWeapon(
        uint8 id,
        string memory name,
        uint8 dmgMin,
        uint8 dmgMax,
        uint8 speed,
        uint8 wType,
        uint8 weight
    ) internal view {
        Bulls.Weapon memory w = bulls.getWeapon(id);
        assertEq(w.name, name);
        assertEq(w.damageMin, dmgMin, name);
        assertEq(w.damageMax, dmgMax, name);
        assertEq(w.speed, speed, name);
        assertEq(w.weaponType, wType, name);
        assertEq(w.weight, weight, name);
    }

    /// @dev 8-14 cost 1 a step, 15-16 cost 2, 17-18 cost 3.
    function _pointCost(uint8 target) internal pure returns (uint256 cost) {
        for (uint8 i = 9; i <= target; i++) {
            if (i <= 14) cost += 1;
            else if (i <= 16) cost += 2;
            else cost += 3;
        }
    }
}
