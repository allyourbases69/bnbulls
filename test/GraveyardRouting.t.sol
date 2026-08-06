// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/**
 * @title GraveyardRoutingTest
 * @notice PRIORITY 9. Where a revive's money actually lands — `DECISIONS.md
 *         §13` and §14 — plus the oracle policy the dollar ladder rests on.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      `potShareBps` (30%) of every revive is handed to MintDrop's donation
 *      entrypoints, which split it 2:1, so a revive lands **20% BNBULL / 10%
 *      BNB / 70% dev** — the same shape as a mint.
 *
 *      **Except a BNBULL revive, which lands 30% BNBULL / 0% BNB / 70% dev and
 *      sells nothing.** `DECISIONS.md §14`: read literally, "20/10/70 on
 *      everything" would have the contract sell 10% of a BNBULL payment to
 *      fund the BNB pot — the game dumping the one token whose chart its
 *      holders watch, partly cancelling the buy pressure the pot exists to
 *      create. `MintDrop.bnbullPaymentSellsForBnbLeg` defaults to FALSE, and
 *      that default is the decision: if the configuration transaction is ever
 *      forgotten, the safe behaviour is the one that happens anyway.
 *
 *      The proof that nothing is sold is `router.swapCalls() == 0`, asserted
 *      against a mock that counts every entry into a swap function.
 */
contract GraveyardRoutingTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    uint256 internal constant USD_RUNG_1 = 50e18;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
        _fundForRevive(alice);
        _fundForRevive(bob);
        router.resetSwapCalls();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  20 / 10 / 70, end to end
    // ══════════════════════════════════════════════════════════════════════

    function test_aBnbReviveLandsTwentyTenSeventy() public {
        _killBull(aliceBull, bobBull);

        uint256 paid = _bnbDue(USD_RUNG_1);
        uint256 potShare = (paid * 3_000) / 10_000;
        uint256 toBnbull = (potShare * 2_000) / 3_000;
        uint256 toBnb = potShare - toBnbull;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        grave.resurrectWithBNB{value: paid * 2}(aliceBull);

        assertEq(treasury.balance - treasuryBefore, paid - potShare, "dev's 70%");
        assertEq(potBnb.pool(), toBnb, "the WBNB pot's 10%");
        assertEq(potBnbull.pool(), toBnbull * BNBULL_PER_BNB, "the BNBULL pot's 20%, swapped");

        // The 20/10/70 shape, checked against the payment rather than against
        // the intermediate arithmetic. Two wei of rounding, no more.
        assertApproxEqAbs(toBnbull, (paid * 2_000) / 10_000, 2, "the BNBULL leg is not 20%");
        assertApproxEqAbs(toBnb, (paid * 1_000) / 10_000, 2, "the BNB leg is not 10%");
        assertApproxEqAbs(paid - potShare, (paid * 7_000) / 10_000, 2, "dev is not 70%");
    }

    /**
     * @notice 🔒 NEVER SELL BNBULL — `DECISIONS.md §14`.
     */
    function test_aBnbullReviveLandsThirtyZeroSeventyAndSellsNothing() public {
        _killBull(aliceBull, bobBull);

        uint256 paid = _bnbullDue(USD_RUNG_1);
        uint256 potShare = (paid * 3_000) / 10_000;
        uint256 treasuryBefore = bnbull.balanceOf(treasury);
        uint256 bnbPotBefore = potBnb.pool();

        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);

        assertEq(bnbull.balanceOf(treasury) - treasuryBefore, paid - potShare, "dev's 70%");
        assertEq(potBnbull.pool(), potShare, "the WHOLE 30% belongs in the BNBULL pot");
        assertEq(potBnb.pool(), bnbPotBefore, "the BNB pot took a cut of a BNBULL payment");
        assertEq(router.swapCalls(), 0, "BNBULL WAS SOLD");
        assertFalse(drop.bnbullPaymentSellsForBnbLeg(), "the safe default was not the default");
    }

    /// @dev And flipping the flag on restores the literal 20/10/70 read, which
    ///      is what makes it a decision rather than an accident.
    function test_flippingTheSellFlagOnDoesStartSellingBnbull() public {
        drop.setBnbullPaymentSellPolicy(true);
        _killBull(aliceBull, bobBull);

        uint256 paid = _bnbullDue(USD_RUNG_1);
        uint256 potShare = (paid * 3_000) / 10_000;
        uint256 toBnbull = (potShare * 2_000) / 3_000;
        uint256 toBnb = potShare - toBnbull;

        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);

        assertEq(potBnbull.pool(), toBnbull);
        assertEq(potBnb.pool(), toBnb / BNBULL_PER_BNB, "the BNB leg sold BNBULL for WBNB");
        assertEq(router.swapCalls(), 1);
    }

    function test_thePotShareIsBoundedAndRetunable() public {
        assertEq(grave.potShareBps(), 3_000, "DECISIONS 13: 30% to the pots");
        assertEq(grave.MAX_POT_SHARE_BPS(), 5_000);

        vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidShare.selector, uint256(5_001)));
        grave.setShares(5_001, 0);

        grave.setShares(0, 0);
        _killBull(aliceBull, bobBull);
        uint256 due = _bnbDue(USD_RUNG_1);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        grave.resurrectWithBNB{value: due * 2}(aliceBull);
        assertEq(treasury.balance - treasuryBefore, due, "a zero pot share");
        assertEq(potBnbull.pool(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Pricing the BNBULL leg
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE DOUBLE-DISCOUNT TRAP. The keeper pegs the FULL sticker; this
     *         contract owns the discount. A BNBULL revive is 10% off, not 19%.
     */
    function test_theBnbullDiscountIsAppliedExactlyOnce() public {
        assertEq(grave.discountBpsOf(address(bnbull)), 1_000);
        assertEq(grave.discountBpsOf(grave.NATIVE()), 0, "BNB carries no discount");

        // $50 at $0.01 a token is 5,000 BNBULL at the full sticker, 4,500 after
        // the single 10% cut. 4,050 would be the double-discount bug.
        (, uint256 bnbullDue,) = grave.quotePayment(USD_RUNG_1);
        assertEq(bnbullDue, 4_500e18);

        _killBull(aliceBull, bobBull);
        uint256 before = bnbull.balanceOf(alice);
        vm.prank(alice);
        grave.resurrectWithBNBULL(aliceBull);
        assertEq(before - bnbull.balanceOf(alice), 4_500e18, "charged a different number");
    }

    /// @dev A stale peg DISABLES the leg rather than selling lives at last
    ///      week's price. Same principle as the oracle staleness check:
    ///      refuse, never guess.
    function test_aStaleBnbullPegDisablesTheLegRatherThanGuessing() public {
        _killBull(aliceBull, bobBull);

        vm.warp(block.timestamp + 7 hours); // past the 6-hour peg age
        feed.setAnswer(BNB_USD_8); // the ORACLE is fresh; the peg is not

        (, uint256 bnbullDue,) = grave.quotePayment(USD_RUNG_1);
        assertEq(bnbullDue, 0, "a stale leg must quote zero, not a wrong number");

        // ⚠ Read the peg timestamp BEFORE the prank: it is an external view
        // call, and evaluating it inside the pranked expression would spend
        // the prank on the read.
        bytes memory stale = abi.encodeWithSelector(
            Graveyard.BnbullPegStale.selector, grave.bnbullPegUpdatedAt(), uint256(6 hours)
        );
        vm.prank(alice);
        vm.expectRevert(stale);
        grave.resurrectWithBNBULL(aliceBull);

        // The BNB leg is unaffected — one dead leg does not close the door.
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        assertTrue(bulls.isAlive(aliceBull));
    }

    function test_anUnpricedBnbullLegRefusesOutright() public {
        grave.setBnbullPerUsd(0);
        _killBull(aliceBull, bobBull);

        vm.prank(alice);
        vm.expectRevert(Graveyard.BnbullPathNotPriced.selector);
        grave.resurrectWithBNBULL(aliceBull);
    }

    function test_thePegIsBoundedAndKeeperSettable() public {
        uint256 cap = grave.MAX_BNBULL_PER_USD();
        vm.expectRevert(abi.encodeWithSelector(Graveyard.PegTooHigh.selector, cap + 1, cap));
        grave.setBnbullPerUsd(cap + 1);

        vm.prank(keeper);
        grave.setBnbullPerUsd(123e18);
        assertEq(grave.bnbullPerUsd(), 123e18);

        vm.prank(alice);
        vm.expectRevert(Graveyard.NotKeeperOrOwner.selector);
        grave.setBnbullPerUsd(1e18);

        vm.expectRevert(abi.encodeWithSelector(Graveyard.ValueOutOfRange.selector, 0, 30 days));
        grave.setMaxBnbullPegAge(0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Decimals are READ, never assumed
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE DECIMALS TRAP, handled — READ, NEVER ASSUMED.
     *
     * @dev REWRITTEN, NOT DELETED, for `DECISIONS.md §26`. This used to drive a
     *      6dp stablecoin through `quotePayment` and assert `50e6`. That asset
     *      is gone and with it the whole 6dp-payment-token bug class — but the
     *      RULE is not gone, it just has one place left to live on this
     *      contract: the price feed. A feed reporting anything other than 8
     *      would silently scale every rung, and the value is read off the
     *      aggregator at wiring time rather than hardcoded.
     *
     *      (The BNBULL leg needs no decimals read here at all: `bnbullPerUsd`
     *      is a keeper peg denominated directly in BNBULL WEI per dollar, so
     *      the token's own decimals never enter the arithmetic. Where BNBULL's
     *      decimals DO divide something — `Marketplace` — they are read, and
     *      `MarketplaceDecimals.t.sol` drives a non-18dp token through it.)
     */
    function test_theFeedDecimalsAreReadAtWiringTime() public {
        assertEq(grave.feedDecimals(), 8, "BNB/USD is 8dp");

        MockAggregator odd = new MockAggregator(18, int256(600e18));
        Graveyard g = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        g.bootstrapWire(Graveyard.Wire.PriceFeed, address(odd));

        assertEq(g.feedDecimals(), 18, "the decimals were assumed, not read");
        (uint256 bnbDue,, uint256 price) = g.quotePayment(USD_RUNG_1);
        assertEq(price, BNB_USD_1E18, "an 18dp feed must normalise to the same 1e18 dollar");
        assertEq(bnbDue, _bnbDue(USD_RUNG_1), "the same $50 rung, a different feed scale");
    }

    /// @dev A payment asset with a transfer tax is refused LOUDLY rather than
    ///      selling a life at a discount nobody chose.
    ///
    ///      ⚠ REWRITTEN for `§26` to tax BNBULL rather than the stablecoin, and
    ///      that is the more honest test: BNBULL is launchpad-issued, so "it
    ///      has no fee on transfer" is a thing to VERIFY at deploy, not assume,
    ///      and it is now the ONLY ERC-20 a player can pay with.
    function test_aFeeOnTransferPaymentIsRefused() public {
        MockFeeToken taxed = new MockFeeToken(100); // 1%
        Graveyard g = new Graveyard(owner, address(bulls), address(taxed), treasury);
        g.bootstrapWire(Graveyard.Wire.Duel, address(duelC));
        g.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        g.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));
        _installGraveyard(g);
        g.setBnbullPerUsd(BNBULL_PER_USD);

        taxed.mint(alice, 10_000_000e18);
        vm.prank(alice);
        taxed.approve(address(g), type(uint256).max);

        _killBull(aliceBull, bobBull);
        uint256 due = _bnbullDue(USD_RUNG_1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graveyard.PaymentShortfall.selector,
                address(taxed),
                due,
                (due * 9_900) / 10_000
            )
        );
        g.resurrectWithBNBULL(aliceBull);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The oracle REFUSES, it never clamps
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice "a clamped price is a wrong price presented as a right one, and
     *          here it would either sell lives for dust or price them out of
     *          reach."
     */
    function test_everyBadOracleStateRevertsRatherThanClamping() public {
        _killBull(aliceBull, bobBull);

        // Non-positive answer.
        feed.setAnswer(0);
        _expectReviveOracleRevert(abi.encodeWithSelector(Graveyard.OracleBadAnswer.selector, 0));
        feed.setAnswer(-1);
        _expectReviveOracleRevert(
            abi.encodeWithSelector(Graveyard.OracleBadAnswer.selector, int256(-1))
        );

        // Incomplete round.
        feed.setRound(9, BNB_USD_8, block.timestamp, block.timestamp, 8);
        _expectReviveOracleRevert(
            abi.encodeWithSelector(
                Graveyard.OracleBadRound.selector, uint80(9), uint80(8), block.timestamp
            )
        );

        // No timestamp at all.
        feed.setRound(10, BNB_USD_8, 0, 0, 10);
        _expectReviveOracleRevert(
            abi.encodeWithSelector(
                Graveyard.OracleBadRound.selector, uint80(10), uint80(10), uint256(0)
            )
        );

        // Stale.
        feed.setAnswer(BNB_USD_8);
        uint256 updatedAt = block.timestamp;
        vm.warp(block.timestamp + 2 hours);
        _expectReviveOracleRevert(
            abi.encodeWithSelector(Graveyard.OracleStale.selector, updatedAt, 1 hours)
        );

        // Outside the sanity band — the LUNA failure mode, where a feed pinned
        // at its circuit-breaker floor would sell lives for dust.
        feed.setAnswer(BNB_USD_8);
        grave.setOraclePolicy(1 hours, 100e18, 2_000e18);
        feed.setAnswer(1e8); // $1 a BNB
        _expectReviveOracleRevert(
            abi.encodeWithSelector(Graveyard.OracleOutOfBand.selector, uint256(1e18))
        );
        feed.setAnswer(50_000e8);
        _expectReviveOracleRevert(
            abi.encodeWithSelector(Graveyard.OracleOutOfBand.selector, uint256(50_000e18))
        );

        // ...and a healthy feed inside the band still works.
        feed.setAnswer(BNB_USD_8);
        vm.prank(alice);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
        assertTrue(bulls.isAlive(aliceBull));
    }

    function test_anUnwiredFeedRefuses() public {
        Graveyard g = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        vm.expectRevert(Graveyard.OracleNotWired.selector);
        g.bnbUsdPrice();
    }

    function test_theOraclePolicyIsBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Graveyard.ValueOutOfRange.selector, 0, 24 hours));
        grave.setOraclePolicy(0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Graveyard.ValueOutOfRange.selector, 24 hours + 1, 24 hours)
        );
        grave.setOraclePolicy(24 hours + 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.OracleOutOfBand.selector, uint256(2e18)));
        grave.setOraclePolicy(1 hours, 2e18, 1e18);

        grave.setOraclePolicy(2 hours, 0, 0);
        assertEq(grave.maxOracleAge(), 2 hours);
    }

    /// @dev A feed with an absurd decimals value fails the WIRING transaction,
    ///      not the first revive.
    function test_anUnusableFeedFailsTheWiringNotTheFirstRevive() public {
        MockAggregator wide = new MockAggregator(37, BNB_USD_8);
        Graveyard g = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.FeedDecimalsUnusable.selector, 37));
        g.bootstrapWire(Graveyard.Wire.PriceFeed, address(wide));
    }

    /// @dev A feed with fewer than 18 decimals is scaled UP, one with more is
    ///      scaled down — the conversion is read off `decimals()`, never
    ///      assumed to be 8.
    function test_theFeedScaleIsReadNotAssumed() public {
        MockAggregator tenDp = new MockAggregator(10, 600e10);
        Graveyard g = new Graveyard(owner, address(bulls), address(bnbull), treasury);
        g.bootstrapWire(Graveyard.Wire.PriceFeed, address(tenDp));
        assertEq(g.feedDecimals(), 10);
        assertEq(g.bnbUsdPrice(), BNB_USD_1E18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _expectReviveOracleRevert(bytes memory err) internal {
        vm.prank(alice);
        vm.expectRevert(err);
        grave.resurrectWithBNB{value: 5 ether}(aliceBull);
    }
}
