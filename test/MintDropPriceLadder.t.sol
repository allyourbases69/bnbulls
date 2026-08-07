// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Bulls} from "../contracts/Bulls.sol";

/**
 * @title MintDropPriceLadderTest
 * @notice PRIORITY 4. The `$10 -> $75` ladder of `DECISIONS.md §12`.
 *
 * @dev        | upToSold | USD sticker |
 *             |      100 |         $10 |
 *             |      200 |         $20 |
 *             |      300 |         $35 |
 *             |      400 |         $50 |
 *             |      500 |         $75 |
 *
 *      Two things matter more than the five numbers:
 *
 *      1. **THERE IS NO FLAT-PRICE FALLBACK.** Fefers fell back to a flat
 *         `ethPrice`/`usdgPrice` when no tier matched, and
 *         `LEARNINGS-AND-MISTAKES §A` records what that cost: "the parent
 *         shipped testnet-era 0.0001-ETH flat pricing to mainnet because an env
 *         flag wasn't set; T1 cost $0.21." An unpriced mint here must REVERT.
 *
 *      2. **THE TABLE IS REPLACED WHOLE AND MUST COVER THE WHOLE DROP.** An
 *         off-by-one table with no fallback behind it would brick the drop
 *         rather than mispricing it, so `setPriceTiers` refuses a last rung
 *         below `MAX_MINT`.
 */
contract MintDropPriceLadderTest is BnbullsBase {
    // ══════════════════════════════════════════════════════════════════════
    //  The ladder itself, rung by rung and boundary by boundary
    // ══════════════════════════════════════════════════════════════════════

    function test_theLaunchLadderIsExactlyDecisions12() public view {
        assertEq(drop.priceTierCount(), 5);

        uint16[5] memory bounds = [uint16(100), 200, 300, 400, 500];
        uint128[5] memory stickers = [uint128(10e18), 20e18, 35e18, 50e18, 75e18];
        for (uint256 i = 0; i < 5; i++) {
            MintDrop.PriceTier memory t = drop.priceTierAt(i);
            assertEq(t.upToSold, bounds[i]);
            assertEq(t.usdPrice, stickers[i]);
        }
    }

    /// @dev Every boundary, from both sides. 100 and 101 are the pair the brief
    ///      calls out; 500 is the last mint the contract will ever price.
    function test_everyBoundaryChargesTheRightRung() public view {
        _assertRung(1, 10e18);
        _assertRung(99, 10e18);
        _assertRung(100, 10e18); // exactly at the boundary: still the $10 rung
        _assertRung(101, 20e18); // one past it: the $20 rung
        _assertRung(200, 20e18);
        _assertRung(201, 35e18);
        _assertRung(300, 35e18);
        _assertRung(301, 50e18);
        _assertRung(400, 50e18);
        _assertRung(401, 75e18);
        _assertRung(500, 75e18); // the last bull in the drop
    }

    function test_priceForMintRevertsPastTheEndOfTheTable() public {
        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(501)));
        drop.priceForMint(501);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(1_000_000)));
        drop.priceForMint(1_000_000);
    }

    /// @notice `DECISIONS.md §12`: "gross at full mint ~ $19,000".
    function test_theWholeDropGrossesNineteenThousandDollars() public view {
        uint256 gross;
        for (uint256 i = 1; i <= 500; i++) {
            (uint256 usd,) = drop.priceForMint(i);
            gross += usd;
        }
        assertEq(gross, 19_000e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  An unpriced mint REVERTS. It does not fall back to anything.
    // ══════════════════════════════════════════════════════════════════════

    function test_aDropWithNoTableSellsNothingAtAnyPrice() public {
        MintDrop fresh = _freshWiredDrop();
        assertEq(fresh.priceTierCount(), 0);

        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(1)));
        fresh.priceForMint(1);

        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(1)));
        fresh.quote(1);

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(1)));
        fresh.mintWithBNB{value: 50 ether}(alice, 1);

        _giveBnbull(alice, 100_000e18);
        vm.prank(alice);
        bnbull.approve(address(fresh), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(1)));
        fresh.mintWithBNBULL(alice, 1);

        _giveBnbull(alice, 1_000_000e18);
        vm.prank(alice);
        bnbull.approve(address(fresh), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.NotPriced.selector, uint256(1)));
        fresh.mintWithBNBULL(alice, 1);

        assertEq(fresh.totalSold(), 0);
    }

    /// @dev And there is no flat-price setter to fall back TO. The fefers
    ///      `setPrices` pair is simply absent from the ABI.
    function test_thereIsNoFlatPriceSetterAtAll() public {
        string[4] memory gone = [
            "setPrices(uint256,uint256)",
            "setPrice(uint256)",
            "ethPrice()",
            "usdgPrice()"
        ];
        for (uint256 i = 0; i < gone.length; i++) {
            (bool ok,) = address(drop).call(abi.encodeWithSignature(gone[i]));
            assertFalse(ok, "a flat-price fallback exists on MintDrop");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  `setPriceTiers` guards
    // ══════════════════════════════════════════════════════════════════════

    function test_refusesATableWhoseLastRungDoesNotCoverFiveHundred() public {
        MintDrop.PriceTier[] memory t = new MintDrop.PriceTier[](2);
        t[0] = MintDrop.PriceTier({upToSold: 100, usdPrice: 10e18, bnbullPrice: 1_000e18});
        t[1] = MintDrop.PriceTier({upToSold: 499, usdPrice: 75e18, bnbullPrice: 7_500e18});
        vm.expectRevert(MintDrop.InvalidTiers.selector);
        drop.setPriceTiers(t);

        // 500 exactly is fine; more than 500 is fine too (headroom is harmless).
        t[1].upToSold = 500;
        drop.setPriceTiers(t);
        t[1].upToSold = 900;
        drop.setPriceTiers(t);
    }

    function test_refusesAnEmptyTable() public {
        MintDrop.PriceTier[] memory none = new MintDrop.PriceTier[](0);
        vm.expectRevert(MintDrop.InvalidTiers.selector);
        drop.setPriceTiers(none);
    }

    function test_refusesUnsortedOrDuplicateBoundaries() public {
        MintDrop.PriceTier[] memory t = new MintDrop.PriceTier[](3);
        t[0] = MintDrop.PriceTier({upToSold: 200, usdPrice: 10e18, bnbullPrice: 0});
        t[1] = MintDrop.PriceTier({upToSold: 100, usdPrice: 20e18, bnbullPrice: 0});
        t[2] = MintDrop.PriceTier({upToSold: 500, usdPrice: 75e18, bnbullPrice: 0});
        vm.expectRevert(MintDrop.InvalidTiers.selector);
        drop.setPriceTiers(t);

        t[0].upToSold = 100;
        t[1].upToSold = 100; // duplicate
        vm.expectRevert(MintDrop.InvalidTiers.selector);
        drop.setPriceTiers(t);
    }

    function test_enforcesThePriceCeilings() public {
        MintDrop.PriceTier[] memory t = new MintDrop.PriceTier[](1);
        uint256 cap = drop.MAX_USD_PRICE();
        t[0] = MintDrop.PriceTier({upToSold: 500, usdPrice: uint128(cap + 1), bnbullPrice: 0});
        vm.expectRevert(abi.encodeWithSelector(MintDrop.PriceTooHigh.selector, cap + 1, cap));
        drop.setPriceTiers(t);

        uint256 bcap = drop.MAX_BNBULL_PRICE();
        t[0] = MintDrop.PriceTier({
            upToSold: 500,
            usdPrice: 10e18,
            bnbullPrice: uint128(bcap + 1)
        });
        vm.expectRevert(abi.encodeWithSelector(MintDrop.PriceTooHigh.selector, bcap + 1, bcap));
        drop.setPriceTiers(t);
    }

    /// @dev The whole table is replaced, not merged — a shorter table must not
    ///      leave the tail of a longer one behind.
    function test_theTableIsReplacedWholesale() public {
        MintDrop.PriceTier[] memory t = new MintDrop.PriceTier[](1);
        t[0] = MintDrop.PriceTier({upToSold: 500, usdPrice: 42e18, bnbullPrice: 4_200e18});
        drop.setPriceTiers(t);

        assertEq(drop.priceTierCount(), 1);
        (uint256 usd,) = drop.priceForMint(1);
        assertEq(usd, 42e18);
        (usd,) = drop.priceForMint(500);
        assertEq(usd, 42e18);
    }

    function test_onlyOwnerCanRepriceTheDrop() public {
        // ⚠ Built BEFORE the prank. `_launchTiers()` reads `bnbull.decimals()`
        // since the tiers became decimals-derived, and an external view call
        // inside the pranked expression spends the prank on the read.
        MintDrop.PriceTier[] memory t = _launchTiers();
        vm.prank(alice);
        vm.expectRevert();
        drop.setPriceTiers(t);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The ladder, charged for real
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Sell the whole first rung, then check the 101st mint really does
    ///      step up to $20 — the boundary as the buyer experiences it.
    function test_theHundredthAndHundredAndFirstMintsAreChargedDifferently() public {
        for (uint256 i = 0; i < 5; i++) {
            _mintBnb(alice, 20); // 100 mints, MAX_BATCH is 20
        }
        assertEq(drop.totalSold(), 100);
        assertEq(bulls.balanceOf(alice), 100);

        (uint256 usdTotal, uint256 bnbDue,,) = drop.quote(1);
        assertEq(usdTotal, 20e18, "the 101st mint must be the $20 rung");
        assertEq(bnbDue, _ceilDiv(20e18 * 1e18, BNB_USD_1E18));

        uint256 spent = _mintBnb(bob, 1);
        assertEq(spent, bnbDue);
    }

    /// @dev A batch that straddles a boundary is summed PER UNIT, not priced
    ///      off the first or last mint in the batch.
    function test_aBatchStraddlingABoundaryIsSummedPerUnit() public {
        for (uint256 i = 0; i < 4; i++) {
            _mintBnb(alice, 20); // 80 sold
        }
        _mintBnb(alice, 15); // 95 sold
        assertEq(drop.totalSold(), 95);

        // Mints 96..105: five at $10 and five at $20.
        (uint256 usdTotal,,,) = drop.quote(10);
        assertEq(usdTotal, 5 * 10e18 + 5 * 20e18);

        _mintBnb(bob, 10);
        assertEq(drop.totalSold(), 105);
        (uint256 next,,,) = drop.quote(1);
        assertEq(next, 20e18);
    }

    function test_batchSizeAndSupplyAreBounded() public {
        uint256 max = drop.MAX_BATCH();
        vm.deal(alice, 1_000 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidCount.selector, uint256(0)));
        drop.mintWithBNB{value: 1 ether}(alice, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidCount.selector, max + 1));
        drop.mintWithBNB{value: 100 ether}(alice, max + 1);

        vm.prank(alice);
        vm.expectRevert(MintDrop.ZeroAddress.selector);
        drop.mintWithBNB{value: 1 ether}(address(0), 1);
    }

    /// @dev `MintDrop.MAX_MINT` and `Bulls.MAX_SUPPLY` must be the same number,
    ///      so the last mint either contract allows is the same event.
    function test_maxMintMatchesTheCollectionSupply() public view {
        assertEq(drop.MAX_MINT(), 500);
        assertEq(uint256(bulls.MAX_SUPPLY()), drop.MAX_MINT());
    }

    function test_supplyExhaustsAtFiveHundred() public {
        for (uint256 i = 0; i < 25; i++) {
            _mintBnb(alice, 20);
        }
        assertEq(drop.totalSold(), 500);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(MintDrop.SupplyExhausted.selector);
        drop.mintWithBNB{value: 10 ether}(bob, 1);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _assertRung(uint256 mintNumber, uint256 expectedUsd) internal view {
        (uint256 usd,) = drop.priceForMint(mintNumber);
        assertEq(usd, expectedUsd);
    }

    function _freshWiredDrop() internal returns (MintDrop d) {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(b),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        d.unpause();
        b.bootstrapWire(Bulls.Wire.MintDrop, address(d));
        d.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        d.bootstrapWire(MintDrop.Wire.Router, address(router));
    }
}
