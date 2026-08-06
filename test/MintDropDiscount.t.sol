// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";

/**
 * @title MintDropDiscountTest
 * @notice PRIORITY 5. The 10% is applied EXACTLY ONCE.
 *
 * @dev `DECISIONS.md §2`: "**BNBULL and only BNBULL carries the discount**",
 *      implemented as a generic `mapping(address => uint16) discountBpsOf` with
 *      a hard `MAX_DISCOUNT_BPS` ceiling, launching at 1000 bps on BNBULL and 0
 *      on every other asset — "the rate is then launch config, and the owner
 *      can retune it without a redeploy".
 *
 *      ⚠ THE DOUBLE-DISCOUNT TRAP, which is what this file is really about.
 *      §2 also says the price-keeper "pegs the BNBULL legs to `dollar sticker −
 *      discount`, exactly as `fight-price-keeper.mjs` did on fefers". Read
 *      literally alongside a contract that ALSO applies `discountBpsOf`, that
 *      is 10% twice: 0.9 × 0.9 = 0.81, i.e. **19% off, not 10%**. The contract
 *      resolves it by being the single source of the discount — the keeper pegs
 *      `bnbullPrice` to the FULL sticker's BNBULL equivalent and the contract
 *      takes the 10% off.
 *
 *      So the three numbers under test, on a rung pegged at 1,000 BNBULL:
 *        900 BNBULL  ✅ the discount applied once   (what a buyer must pay)
 *        810 BNBULL  ❌ the double-discount trap
 *      1,000 BNBULL  ❌ no discount at all
 */
contract MintDropDiscountTest is BnbullsBase {
    /// @dev The $10 rung's keeper peg — the FULL sticker in BNBULL at $0.01.
    uint256 internal constant STICKER_BNBULL = 1_000e18;
    uint256 internal constant CORRECT = 900e18; // −10%, once
    uint256 internal constant DOUBLE_DISCOUNTED = 810e18; // −19%, the trap
    uint256 internal constant NO_DISCOUNT = 1_000e18;

    // ══════════════════════════════════════════════════════════════════════
    //  Launch configuration
    // ══════════════════════════════════════════════════════════════════════

    function test_discountLaunchesAtTenPercentOnBnbullAndZeroEverywhereElse() public view {
        assertEq(drop.discountBpsOf(address(bnbull)), 1_000, "BNBULL must launch at 1000 bps");
        assertEq(drop.discountBpsOf(drop.NATIVE()), 0, "BNB must carry no discount");
        assertEq(drop.discountBpsOf(address(wbnb)), 0);
        assertEq(drop.NATIVE(), address(0), "address(0) is the native sentinel");
    }

    /// @dev Not hardcoded to one asset: the mapping is generic, exactly as §2
    ///      requires ("do NOT hardcode which asset is discounted").
    function test_theDiscountIsGenericPerAssetNotHardcodedToBnbull() public {
        drop.setDiscountBps(drop.NATIVE(), 2_500);
        (, uint256 bnbDue,,) = drop.quote(1);
        // $10 sticker, 25% off, at $600/BNB.
        assertEq(bnbDue, _ceilDiv(7.5e18 * 1e18, BNB_USD_1E18));

        // ...and taking it back off restores the full sticker, so the mapping
        // is a live per-asset dial and not a one-way switch.
        drop.setDiscountBps(drop.NATIVE(), 0);
        (, bnbDue,,) = drop.quote(1);
        assertEq(bnbDue, _ceilDiv(10e18 * 1e18, BNB_USD_1E18));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Applied EXACTLY once
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The keeper's peg is the UNDISCOUNTED figure; the quote is the
    ///         discounted one. Two different reads, and that separation is what
    ///         makes double-discounting structurally impossible.
    function test_theKeeperPegIsTheFullStickerAndTheQuoteIsTheDiscountedOne() public view {
        (, uint256 peg) = drop.priceForMint(1);
        assertEq(peg, STICKER_BNBULL, "priceForMint must return the UNDISCOUNTED peg");

        (,, uint256 bnbullDue,) = drop.quote(1);
        assertEq(bnbullDue, CORRECT, "quote must return what the buyer pays");
    }

    function test_aBnbullMintCostsStickerMinusTenPercentExactly() public {
        (,, uint256 bnbullDue,) = drop.quote(1);

        assertEq(bnbullDue, CORRECT, "not sticker - 10%");
        assertTrue(bnbullDue != DOUBLE_DISCOUNTED, "DOUBLE DISCOUNT: 19% off, not 10%");
        assertTrue(bnbullDue != NO_DISCOUNT, "the discount was not applied at all");

        // ...and the money that actually moves is that number, to the wei.
        _giveBnbull(alice, 10_000e18);
        uint256 before = bnbull.balanceOf(alice);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);
        assertEq(before - bnbull.balanceOf(alice), CORRECT, "the mint pulled the wrong amount");
        assertEq(bulls.balanceOf(alice), 1);
    }

    /// @dev The event publishes the UNDISCOUNTED dollar sticker plus the bps,
    ///      so an indexer can reconstruct the discount rather than infer it.
    function test_theReceiptPublishesTheStickerAndTheBps() public {
        _giveBnbull(alice, 10_000e18);
        vm.expectEmit(true, false, false, true, address(drop));
        // ⚠ `paymentType` is 1, not 2: `DECISIONS.md §26` renumbered the
        // currency codes when the stablecoin went (0 = BNB, 1 = BNBULL).
        emit MintDrop.MintPaid(alice, 1, address(bnbull), CORRECT, 10e18, 1_000, 0);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);
    }

    /// @dev The discount is applied to the BATCH TOTAL, once, not per unit with
    ///      compounding rounding.
    function test_theDiscountAppliesOnceToTheWholeBatch() public {
        (,, uint256 due5,) = drop.quote(5);
        assertEq(due5, (STICKER_BNBULL * 5 * 9_000) / 10_000);
        assertEq(due5, 4_500e18);

        // A batch straddling the $10/$20 boundary: pegs sum first, discount
        // once afterwards.
        for (uint256 i = 0; i < 5; i++) {
            _mintBnb(alice, 20);
        }
        assertEq(drop.totalSold(), 100);
        (,, uint256 dueAcross,) = drop.quote(2); // mints 101 and 102, both $20
        assertEq(dueAcross, (2_000e18 * 2 * 9_000) / 10_000);
    }

    /// @dev Zero discount is the identity, not a rounding path.
    function test_zeroDiscountIsExactlyTheSticker() public {
        drop.setDiscountBps(address(bnbull), 0);
        (,, uint256 bnbullDue,) = drop.quote(1);
        assertEq(bnbullDue, STICKER_BNBULL);
    }

    function testFuzz_discountIsExactlyOneApplicationOfBps(uint16 bps) public {
        bps = uint16(bound(uint256(bps), 0, drop.MAX_DISCOUNT_BPS()));
        drop.setDiscountBps(address(bnbull), bps);
        (,, uint256 due,) = drop.quote(1);
        assertEq(due, (STICKER_BNBULL * (10_000 - bps)) / 10_000);
        // The double application, for contrast — never equal unless bps == 0.
        uint256 twice = (((STICKER_BNBULL * (10_000 - bps)) / 10_000) * (10_000 - bps)) / 10_000;
        if (bps != 0) assertTrue(due != twice, "quote matched a double application");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Only BNBULL carries it
    // ══════════════════════════════════════════════════════════════════════

    function test_theBnbLegPaysTheFullSticker() public {
        (uint256 usdTotal, uint256 bnbDue,,) = drop.quote(1);
        assertEq(usdTotal, 10e18);
        assertEq(bnbDue, _ceilDiv(10e18 * 1e18, BNB_USD_1E18), "BNB got a discount it must not");

        vm.deal(alice, 10 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        drop.mintWithBNB{value: bnbDue}(alice, 1);
        assertEq(before - alice.balance, bnbDue);
    }

    /// @dev The headline claim, as one comparison: paying in BNBULL is exactly
    ///      10% cheaper in dollar terms than paying in BNB.
    function test_bnbullIsTenPercentCheaperThanTheOtherCurrency() public view {
        (uint256 usdTotal, uint256 bnbDue, uint256 bnbullDue, uint256 px) = drop.quote(1);
        // The BNB leg, valued back through the oracle, IS the dollar sticker.
        // (Ceil-division can round it a hair UP; never down.)
        uint256 bnbDueInUsd = (bnbDue * px) / 1e18;
        // `_ceilDiv` rounds the BNB leg UP by at most one wei of BNB, which is
        // `px / 1e18` of a dollar. It may never round DOWN.
        assertGe(bnbDueInUsd, usdTotal, "the BNB leg under-charged the sticker");
        assertLt(bnbDueInUsd, usdTotal + px / 1e18 + 1);
        // The BNBULL leg, valued back at the keeper's peg ($0.01), is $9.
        uint256 bnbullDueInUsd = (bnbullDue * 10e18) / STICKER_BNBULL;
        assertEq(bnbullDueInUsd, 9e18);
        assertEq((usdTotal * 9_000) / 10_000, bnbullDueInUsd);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The ceiling
    // ══════════════════════════════════════════════════════════════════════

    /// @notice `MAX_DISCOUNT_BPS` is a TRUE security ceiling: "this bound
    ///         exists so a stolen key cannot sell the drop for pennies".
    function test_maxDiscountBpsIsEnforced() public {
        uint16 cap = drop.MAX_DISCOUNT_BPS();
        assertEq(cap, 5_000);

        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, uint256(cap) + 1));
        drop.setDiscountBps(address(bnbull), cap + 1);

        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, uint256(10_000)));
        drop.setDiscountBps(address(bnbull), 10_000); // "free mints" is refused

        drop.setDiscountBps(address(bnbull), cap); // the edge is allowed
        (,, uint256 due,) = drop.quote(1);
        assertEq(due, STICKER_BNBULL / 2, "50% is the most a compromised key can give away");
    }

    function testFuzz_discountAboveTheCeilingAlwaysReverts(uint16 bps) public {
        vm.assume(bps > drop.MAX_DISCOUNT_BPS());
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, uint256(bps)));
        drop.setDiscountBps(address(bnbull), bps);
    }

    function test_onlyOwnerSetsTheDiscount() public {
        vm.prank(alice);
        vm.expectRevert();
        drop.setDiscountBps(address(bnbull), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The un-pegged case
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `bnbullPrice == 0` means "the keeper has not pegged this rung yet"
    ///      (pre-pool). The BNBULL path must refuse rather than sell for zero —
    ///      a poison sentinel would have overflowed the moment a later priced
    ///      rung was added to it, which is why the quote carries a flag.
    function test_anUnpeggedRungRefusesTheBnbullPathInsteadOfSellingFree() public {
        MintDrop.PriceTier[] memory t = _launchTiers();
        t[0].bnbullPrice = 0;
        drop.setPriceTiers(t);

        (,, uint256 bnbullDue,) = drop.quote(1);
        assertEq(bnbullDue, 0, "an unpriced BNBULL leg quotes zero, not a wrong number");

        _giveBnbull(alice, 1_000_000e18);
        vm.prank(alice);
        vm.expectRevert(MintDrop.BnbullPathNotPriced.selector);
        drop.mintWithBNBULL(alice, 1);

        // The dollar legs are unaffected — one leg being unpegged must not
        // take the drop down.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        drop.mintWithBNB{value: 1 ether}(alice, 1);
        assertEq(drop.totalSold(), 1);
    }

    /// @dev A batch where ONE rung is unpegged must fail as a whole, not
    ///      silently charge for the priced rungs only.
    function test_aBatchTouchingAnUnpeggedRungIsRefusedEntirely() public {
        MintDrop.PriceTier[] memory t = _launchTiers();
        t[1].bnbullPrice = 0; // the $20 rung
        drop.setPriceTiers(t);

        for (uint256 i = 0; i < 5; i++) {
            _mintBnb(alice, 20);
        }
        assertEq(drop.totalSold(), 100);

        _giveBnbull(bob, 1_000_000e18);
        vm.prank(bob);
        vm.expectRevert(MintDrop.BnbullPathNotPriced.selector);
        drop.mintWithBNBULL(bob, 1);
    }
}
