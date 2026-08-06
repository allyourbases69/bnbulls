// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SplitterBase} from "./SplitterBase.t.sol";
import {Marketplace} from "../contracts/Marketplace.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {ReviveBuySplitter} from "../contracts/ReviveBuySplitter.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {TimelockedAddress} from "../contracts/lib/TimelockedAddress.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {
    IMarketExec,
    MarketAwkwardSeller,
    MarketHostileSink,
    MarketReentrantBuyer,
    MarketBlindReceiver
} from "./mocks/MarketMocks.sol";

/**
 * @title MarketplaceHarness
 * @notice Shared fixture for the marketplace suites.
 *
 * @dev ⚠ NO MAINNET FORK. Mocks only — see `Base.t.sol` and
 *      `SplitterBase.t.sol`. This extends the splitter harness because the
 *      marketplace's jackpot-fee sink IS a `PotSplitter`: the 2.5% leg
 *      market-buys BNBULL and locks it in the no-withdraw pot.
 *
 *      Economic frame, so the arithmetic in each test reads:
 *        BNB/USD = $600, BNBULL = $0.01,
 *        listing sticker = $80 (the exact figure that rendered as **$0.00** on
 *        fefers, `BNB-CHAIN-FACTS.md §3` row 6).
 *
 *      ⚠ `DECISIONS.md §26` dropped the stablecoin, so the ERC-20 payment leg
 *      under test is BNBULL. Where a test wants an EXACT token amount (the
 *      thing the 18dp stablecoin used to give for free) it lists in
 *      `BnbullMode.Fixed`, which names the token amount outright and never
 *      touches the keeper's peg.
 *
 *      THE SINK IS A SECOND `ReviveBuySplitter`, NOT A NEW CONTRACT. Its pot
 *      ratio is not a constructor argument — it is the live `bnbullShareBps :
 *      bnbShareBps` policy with a local fallback — so leaving `Wire.MintDrop`
 *      unwired and setting the fallback to (2000, 0) gives 100% BNBULL / 0%
 *      BNB with no new deploy artefact.
 */
abstract contract MarketplaceHarness is SplitterBase {
    Marketplace internal market;
    ReviveBuySplitter internal potSink;

    /// @notice $80, 1e18-scaled. NOT a token amount — that is the whole point.
    uint128 internal constant LIST_USD = 80e18;
    /// @notice BNBULL/USD at $0.01.
    uint256 internal constant BNBULL_USD_1E18 = 1e16;
    /// @notice Launch fee: 7.5% total.
    uint16 internal constant FEE_BPS = 750;
    /// @notice Of which 2.5% of the sale buys BNBULL for the pot.
    uint16 internal constant JACKPOT_FEE_BPS = 250;
    /// @dev `Marketplace.NATIVE`, as a local constant. Reading it off the
    ///      contract inside a `vm.prank` / `vm.expectRevert` window would
    ///      consume the cheatcode on the getter instead of the call under test.
    address internal constant NATIVE_KEY = address(0);

    function setUp() public virtual override {
        super.setUp();

        potSink = _newPotSink();
        market = _marketWithSink(address(potSink));

        bulls.mint(alice); // #1
        bulls.mint(alice); // #2
        bulls.mint(bob); //   #3
        vm.prank(alice);
        bulls.setApprovalForAll(address(market), true);
        vm.prank(bob);
        bulls.setApprovalForAll(address(market), true);

        // So a test can kill a bull the way a duel would.
        bulls.bootstrapWire(Bulls.Wire.Duel, address(this));
    }

    // ─── Fixtures ─────────────────────────────────────────────────────────

    /// @dev A `PotSplitter` configured 100% BNBULL / 0% BNB: the live-policy
    ///      slot is left unwired so the local fallback governs, and the
    ///      fallback's two shares are (2000, 0).
    function _newPotSink() internal returns (ReviveBuySplitter s) {
        s = new ReviveBuySplitter(owner, address(wbnb), keeper);
        _wireSplitter(s, address(0));
        s.setFallbackPolicy(2_000, 0, false);
    }

    function _marketWithSink(address sink) internal returns (Marketplace m) {
        m = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        m.bootstrapWire(Marketplace.Wire.PriceFeed, address(feed));
        m.bootstrapWire(Marketplace.Wire.Bnbull, address(bnbull));
        if (sink != address(0)) m.bootstrapWire(Marketplace.Wire.JackpotSink, sink);
        m.setKeeper(keeper);
        m.setBnbullUsd(BNBULL_USD_1E18);
        vm.prank(alice);
        bulls.setApprovalForAll(address(m), true);
        vm.prank(bob);
        bulls.setApprovalForAll(address(m), true);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _list(address seller, uint256 tokenId, uint128 usd) internal {
        vm.prank(seller);
        market.list(tokenId, usd, Marketplace.BnbullMode.Off, 0);
    }

    function _listPegged(address seller, uint256 tokenId, uint128 usd) internal {
        vm.prank(seller);
        market.list(tokenId, usd, Marketplace.BnbullMode.Pegged, 0);
    }

    /// @dev A listing whose BNBULL leg is an EXACT token amount. This is the
    ///      shape the 18dp stablecoin leg used to give for free before
    ///      `DECISIONS.md §26`: gross is a number the test names, with no peg
    ///      and no conversion in the way of the fee arithmetic.
    function _listFixed(address seller, uint256 tokenId, uint128 usd, uint128 bull) internal {
        vm.prank(seller);
        market.list(tokenId, usd, Marketplace.BnbullMode.Fixed, bull);
    }

    /// @dev BNB owed for a dollar sticker, at the harness's $600/BNB.
    function _bnbGross(uint256 usd1e18) internal pure returns (uint256) {
        return _ceilDiv(usd1e18 * 1e18, BNB_USD_1E18);
    }

    function _grossFee(uint256 gross, uint16 feeBps) internal pure returns (uint256) {
        return (gross * feeBps) / 10_000;
    }

    function _legs(uint256 fee, uint16 feeBps, uint16 jackpotBps)
        internal
        pure
        returns (uint256 potCut, uint256 devCut)
    {
        potCut = feeBps == 0 ? 0 : (fee * jackpotBps) / feeBps;
        devCut = fee - potCut;
    }

    /// @dev Kill a bull exactly as a lost duel would.
    function _kill(uint256 tokenId) internal {
        uint256 other = tokenId == 3 ? 1 : 3;
        bulls.applyDuelResult(uint256(tokenId), other, 1_000, 1_000, uint32(other), true, false);
        assertTrue(bulls.isDead(tokenId));
    }
}

/**
 * @title MarketplaceTest
 * @notice The mechanics: the 92.5 / 2.5 / 5 split, the hard-capped fee, the
 *         fee-funded discount, the duel lock-out, the never-fail jackpot leg,
 *         and the awkward-receiver fallbacks.
 */
contract MarketplaceTest is MarketplaceHarness {
    // ══════════════════════════════════════════════════════════════════════
    //  THE FEE: 92.5% SELLER / 2.5% JACKPOT / 5% DEV
    // ══════════════════════════════════════════════════════════════════════

    function test_theLaunchNumbersAre750And250() public view {
        assertEq(market.feeBps(), FEE_BPS, "7.5% total");
        assertEq(market.jackpotFeeBps(), JACKPOT_FEE_BPS, "2.5% of the SALE, not of the fee");
        assertEq(market.MAX_FEE_BPS(), 1_000, "the ceiling was NOT raised to make room");
    }

    function test_aBnbSaleSplits92_5_2_5_5() public {
        _list(alice, 1, LIST_USD);
        uint256 gross = _bnbGross(LIST_USD);
        uint256 fee = _grossFee(gross, FEE_BPS);
        (uint256 potCut, uint256 devCut) = _legs(fee, FEE_BPS, JACKPOT_FEE_BPS);

        uint256 sellerBefore = alice.balance;
        vm.deal(bob, gross);
        vm.prank(bob);
        market.buyWithBNB{value: gross}(1);

        assertEq(bulls.ownerOf(1), bob);
        assertEq(alice.balance - sellerBefore, gross - fee, "92.5% to the seller");
        assertEq(treasury.balance, devCut, "5% to the dev");
        assertEq(potBnbull.pool(), _bnbullFromBnb(potCut), "2.5% market-bought BNBULL for the pot");
        assertEq(market.potFeeUndelivered(), 0, "nothing had to defer");

        // The three legs re-add to what the buyer paid, exactly.
        assertEq(gross, (gross - fee) + potCut + devCut);
    }

    /// @dev `DECISIONS.md §14`: a buyer paying IN BNBULL is never swapped. The
    ///      2.5% goes straight into the pot as tokens.
    function test_aBnbullSaleRoutesStraightIntoThePotWithNoSwap() public {
        _listPegged(alice, 1, LIST_USD);
        uint256 gross = 8_000e18; // $80 / $0.01
        uint256 fee = _grossFee(gross, FEE_BPS);
        (uint256 potCut, uint256 devCut) = _legs(fee, FEE_BPS, JACKPOT_FEE_BPS);

        bnbull.mint(bob, gross);
        vm.startPrank(bob);
        bnbull.approve(address(market), gross);
        market.buyWithBNBULL(1);
        vm.stopPrank();

        assertEq(bnbull.balanceOf(alice), gross - fee);
        assertEq(bnbull.balanceOf(treasury), devCut);
        assertEq(potBnbull.pool(), potCut, "tokens, not a swap");
        assertEq(dex.swapCalls(), 0, "NOT ONE SWAP");
    }

    /**
     * @notice THE INVARIANT: `buyer == seller + potCut + devCut`, exactly, for
     *         every price, every fee, every jackpot leg and every rebate.
     */
    function testFuzz_buyerAlwaysEqualsSellerPlusPotCutPlusDevCut(
        uint96 usd,
        uint16 feeRaw,
        uint16 jackpotRaw,
        uint16 discountRaw
    ) public {
        uint128 usdPrice = uint128(bound(uint256(usd), 1, type(uint96).max));
        uint16 feeBps = uint16(bound(uint256(feeRaw), 0, market.MAX_FEE_BPS()));
        uint16 jackpotBps = uint16(bound(uint256(jackpotRaw), 0, feeBps));
        uint16 discountBps = uint16(bound(uint256(discountRaw), 0, market.MAX_DISCOUNT_BPS()));

        MarketHostileSink sink = new MarketHostileSink();
        sink.setTakeTokens(true);
        Marketplace m = _marketWithSink(address(sink));
        m.setJackpotFeeBps(0); // clear the way to move `feeBps` freely
        m.setFee(feeBps);
        m.setJackpotFeeBps(jackpotBps);
        m.setDiscountBps(address(bnbull), discountBps);

        vm.prank(alice);
        // `Fixed`, so gross IS `usdPrice` in BNBULL wei and the fee arithmetic
        // is not obscured by a peg conversion.
        m.list(1, usdPrice, Marketplace.BnbullMode.Fixed, usdPrice);

        uint256 gross = uint256(usdPrice);
        uint256 grossFee = (gross * feeBps) / 10_000;
        uint256 rebate = (gross * discountBps) / 10_000;
        if (rebate > grossFee) rebate = grossFee;
        uint256 buyerPays = gross - rebate;

        bnbull.mint(bob, buyerPays);
        vm.startPrank(bob);
        bnbull.approve(address(m), buyerPays);
        m.buyWithBNBULL(1);
        vm.stopPrank();

        uint256 sellerGot = bnbull.balanceOf(alice);
        uint256 devGot = bnbull.balanceOf(treasury);
        uint256 potGot = bnbull.balanceOf(address(sink));

        assertEq(sellerGot, gross - grossFee, "seller proceeds are NEVER touched by the rebate");
        assertEq(sellerGot + devGot + potGot, buyerPays, "buyer != seller + potCut + devCut");
        assertEq(bnbull.balanceOf(address(m)), 0, "nothing was stranded in the marketplace");
    }

    function test_theSplitHoldsAtOneWeiOfAPrice() public {
        MarketHostileSink sink = new MarketHostileSink();
        sink.setTakeTokens(true);
        Marketplace m = _marketWithSink(address(sink));

        vm.prank(alice);
        m.list(1, 1, Marketplace.BnbullMode.Fixed, 1); // $1e-18, 1 wei of BNBULL

        bnbull.mint(bob, 1);
        vm.startPrank(bob);
        bnbull.approve(address(m), 1);
        m.buyWithBNBULL(1);
        vm.stopPrank();

        assertEq(bnbull.balanceOf(alice), 1, "one wei, all of it to the seller");
        assertEq(bnbull.balanceOf(treasury), 0);
        assertEq(bnbull.balanceOf(address(sink)), 0);
    }

    // ─── The caps ─────────────────────────────────────────────────────────

    function test_theFeeIsHardCappedByAConstant() public {
        vm.expectRevert(abi.encodeWithSelector(Marketplace.FeeTooHigh.selector, uint16(1_001)));
        market.setFee(1_001);

        vm.expectRevert(abi.encodeWithSelector(Marketplace.FeeTooHigh.selector, uint16(1_001)));
        new Marketplace(address(bulls), treasury, 1_001, owner);

        market.setFee(1_000);
        assertEq(market.feeBps(), 1_000, "the ceiling itself is reachable");
    }

    /**
     * @notice The jackpot leg can never exceed the fee it is carved out of —
     *         that would underflow the dev leg. Enforced in BOTH directions and
     *         in the constructor.
     */
    function test_theJackpotLegCanNeverExceedTheFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(Marketplace.JackpotFeeTooHigh.selector, uint16(751), FEE_BPS)
        );
        market.setJackpotFeeBps(751);

        // Lowering the WHOLE fee under the jackpot leg reverts rather than
        // silently inverting the two.
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.JackpotFeeTooHigh.selector, JACKPOT_FEE_BPS, uint16(200)
            )
        );
        market.setFee(200);

        // And a deployment whose launch fee is under the launch jackpot leg
        // never gets off the ground.
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.JackpotFeeTooHigh.selector, JACKPOT_FEE_BPS, uint16(100)
            )
        );
        new Marketplace(address(bulls), treasury, 100, owner);

        market.setJackpotFeeBps(750);
        assertEq(market.jackpotFeeBps(), 750, "the whole fee CAN be the jackpot leg");
    }

    function test_theWholeFeeCanBeGivenToTheJackpot() public {
        market.setJackpotFeeBps(750);
        _list(alice, 1, LIST_USD);
        uint256 gross = _bnbGross(LIST_USD);
        uint256 fee = _grossFee(gross, FEE_BPS);

        vm.deal(bob, gross);
        vm.prank(bob);
        market.buyWithBNB{value: gross}(1);

        assertEq(treasury.balance, 0, "the dev leg went to zero, never negative");
        assertEq(potBnbull.pool(), _bnbullFromBnb(fee));
    }

    // ─── The discount (DECISIONS §2) ──────────────────────────────────────

    /**
     * @notice The rebate is funded from the PROTOCOL FEE and nowhere else. On a
     *         mint the discount is the protocol's to give; on a peer-to-peer
     *         sale it is not, and a naive discount would come out of the
     *         seller's pocket for a buyer's currency choice they never agreed
     *         to.
     */
    function test_theDiscountNeverComesOutOfTheSellersPocket() public {
        market.setDiscountBps(address(bnbull), 500); // 5% off for BNBULL buyers
        _listPegged(alice, 1, LIST_USD);

        uint256 gross = 8_000e18;
        uint256 grossFee = _grossFee(gross, FEE_BPS);
        uint256 rebate = (gross * 500) / 10_000;
        uint256 buyerPays = gross - rebate;

        (,, uint256 quoted,) = market.quote(1);
        assertEq(quoted, buyerPays, "the quote already carries the rebate");

        bnbull.mint(bob, buyerPays);
        vm.startPrank(bob);
        bnbull.approve(address(market), buyerPays);
        market.buyWithBNBULL(1);
        vm.stopPrank();

        assertEq(bnbull.balanceOf(alice), gross - grossFee, "seller: price - fee, untouched");
        assertEq(bnbull.balanceOf(bob), 0);
        assertEq(
            bnbull.balanceOf(treasury) + potBnbull.pool(),
            grossFee - rebate,
            "the whole rebate came out of the protocol's share"
        );
    }

    /// @dev And it is clamped at the extreme: a discount above the fee cannot
    ///      drive the protocol's share negative, it just reaches zero.
    function test_theRebateIsClampedToTheLiveFee() public {
        market.setFee(500);
        market.setDiscountBps(address(bnbull), market.MAX_DISCOUNT_BPS()); // 10% > 5% fee
        _listFixed(alice, 1, LIST_USD, 80e18);

        uint256 gross = 80e18;
        uint256 grossFee = _grossFee(gross, 500);

        _buyWithBnbull(bob, 1, gross - grossFee);

        assertEq(bnbull.balanceOf(alice), gross - grossFee, "the seller is untouched");
        assertEq(bnbull.balanceOf(treasury), 0, "the dev share reached zero");
        assertEq(potBnbull.pool(), 0, "so did the jackpot leg");
        assertEq(bnbull.balanceOf(bob), 0, "and the buyer paid exactly seller proceeds");
    }

    /// @dev With no fee there is nothing to fund a rebate from, so it evaporates
    ///      rather than being conjured out of the seller.
    function test_aRebateWithNoFeeEvaporates() public {
        market.setJackpotFeeBps(0);
        market.setFee(0);
        market.setDiscountBps(address(bnbull), 1_000);
        _listFixed(alice, 1, LIST_USD, 80e18);

        _buyWithBnbull(bob, 1, 80e18);
        assertEq(bnbull.balanceOf(alice), 80e18, "the seller got the whole sticker");
    }

    function test_theDiscountIsCappedAndGenericPerAsset() public {
        vm.expectRevert(
            abi.encodeWithSelector(Marketplace.DiscountTooHigh.selector, uint16(1_001))
        );
        market.setDiscountBps(address(bnbull), 1_001);

        // `DECISIONS.md §2`: do NOT hardcode which asset is discounted.
        market.setDiscountBps(market.NATIVE(), 100);
        market.setDiscountBps(address(bnbull), 300);
        assertEq(market.discountBpsOf(market.NATIVE()), 100);
        assertEq(market.discountBpsOf(address(bnbull)), 300);
        assertEq(market.discountBpsOf(address(wbnb)), 0, "an unset asset carries none");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE JACKPOT LEG IS NEVER-FAIL — AND IT FAILS ON DAY ONE
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE EXPECTED LAUNCH STATE. BNBULL trades on four.meme's bonding
     *         curve (`DECISIONS.md §4`) and there is NO PancakeSwap pair, so
     *         the 2.5% buy cannot run. A sale must not revert because of it.
     */
    function test_theLaunchStateIsNoPoolAndTheSaleStillSettles() public {
        dex.setQuoteZero(true); // no pair for BNBULL, at all
        _list(alice, 1, LIST_USD);
        uint256 gross = _bnbGross(LIST_USD);
        uint256 fee = _grossFee(gross, FEE_BPS);
        (uint256 potCut, uint256 devCut) = _legs(fee, FEE_BPS, JACKPOT_FEE_BPS);

        vm.deal(bob, gross);
        vm.prank(bob);
        market.buyWithBNB{value: gross}(1);

        assertEq(bulls.ownerOf(1), bob, "THE SALE SETTLED");
        assertEq(alice.balance, gross - fee, "and the seller was paid in full");
        assertEq(treasury.balance, devCut);
        assertEq(potBnbull.pool(), 0, "nothing was bought with nothing");
        assertEq(
            potSink.pendingBnbullBuyNative(),
            potCut,
            "the slice accrued inside the splitter, where a keeper can sweep it later"
        );

        // ...and once the token graduates the curve, the keeper buys the backlog.
        dex.setQuoteZero(false);
        vm.prank(keeper);
        uint256 funded = potSink.sweepBnbullPot(
            PotSplitter.PotSource.Native, 0, (_bnbullFromBnb(potCut) * 99) / 100
        );
        assertEq(funded, _bnbullFromBnb(potCut));
        assertEq(potBnbull.pool(), funded);
    }

    /// @dev The other launch shape: the marketplace goes live BEFORE the
    ///      splitter exists. The slice accrues here instead.
    function test_withNoSinkWiredTheSliceAccruesOnTheMarketplace() public {
        Marketplace m = _marketWithSink(address(0));
        assertEq(m.jackpotSink(), address(0));

        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);
        uint256 gross = _bnbGross(LIST_USD);
        uint256 fee = _grossFee(gross, FEE_BPS);
        (uint256 potCut, uint256 devCut) = _legs(fee, FEE_BPS, JACKPOT_FEE_BPS);

        vm.deal(bob, gross);
        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(m));
        emit Marketplace.PotFeeDeferred(NATIVE_KEY, potCut, potCut);
        m.buyWithBNB{value: gross}(1);

        assertEq(bulls.ownerOf(1), bob);
        assertEq(m.potFeeUndelivered(), potCut);
        assertEq(address(m).balance, potCut, "and it is really held, not just counted");
        assertEq(treasury.balance, devCut);
    }

    function test_aSinkThatRevertsCannotBlockASale() public {
        MarketHostileSink sink = new MarketHostileSink();
        sink.setRevertOnNative(true);
        sink.setRevertOnToken(true);
        Marketplace m = _marketWithSink(address(sink));

        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);
        uint256 gross = _bnbGross(LIST_USD);
        (uint256 potCut,) = _legs(_grossFee(gross, FEE_BPS), FEE_BPS, JACKPOT_FEE_BPS);

        vm.deal(bob, gross);
        vm.prank(bob);
        m.buyWithBNB{value: gross}(1);
        assertEq(m.potFeeUndelivered(), potCut);

        // ...and the same on the token leg.
        vm.prank(alice);
        m.list(2, LIST_USD, Marketplace.BnbullMode.Fixed, 80e18);
        uint256 bullFee = _grossFee(80e18, FEE_BPS);
        (uint256 bullPot,) = _legs(bullFee, FEE_BPS, JACKPOT_FEE_BPS);

        bnbull.mint(bob, 80e18);
        vm.startPrank(bob);
        bnbull.approve(address(m), 80e18);
        m.buyWithBNBULL(2);
        vm.stopPrank();

        assertEq(bulls.ownerOf(2), bob);
        assertEq(m.potFeeUndeliveredToken(address(bnbull)), bullPot);
        assertEq(bnbull.balanceOf(address(m)), bullPot);
    }

    /**
     * @notice A sink that RETURNS NORMALLY having taken nothing is booked as a
     *         shortfall. `PotSplitter.donatePotToken` does exactly this when
     *         its own pull fails, so a successful call is not evidence that
     *         anything moved — the measured balance delta is.
     */
    function test_aSinkThatTakesNothingIsBookedAsAShortfall() public {
        MarketHostileSink sink = new MarketHostileSink();
        sink.setTakeTokens(false); // succeeds, moves nothing
        Marketplace m = _marketWithSink(address(sink));

        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Fixed, 80e18);
        (uint256 potCut,) = _legs(_grossFee(80e18, FEE_BPS), FEE_BPS, JACKPOT_FEE_BPS);

        bnbull.mint(bob, 80e18);
        vm.startPrank(bob);
        bnbull.approve(address(m), 80e18);
        vm.expectEmit(true, false, false, true, address(m));
        emit Marketplace.PotFeeDeferred(address(bnbull), potCut, potCut);
        m.buyWithBNBULL(1);
        vm.stopPrank();

        assertEq(m.potFeeUndeliveredToken(address(bnbull)), potCut);
        assertEq(bnbull.balanceOf(address(sink)), 0);
        assertEq(bnbull.allowance(address(m), address(sink)), 0, "no allowance left standing");
    }

    function test_theAccrualIsRecoverableAndReBuyable() public {
        Marketplace m = _marketWithSink(address(0));
        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);
        uint256 gross = _bnbGross(LIST_USD);
        (uint256 potCut,) = _legs(_grossFee(gross, FEE_BPS), FEE_BPS, JACKPOT_FEE_BPS);

        vm.deal(bob, gross);
        vm.prank(bob);
        m.buyWithBNB{value: gross}(1);
        assertEq(m.potFeeUndelivered(), potCut);

        // The sink appears later; `to == 0` retries it, so the backlog is
        // re-bought rather than merely withdrawn.
        m.bootstrapWire(Marketplace.Wire.JackpotSink, address(potSink));
        m.sweepPotFee(NATIVE_KEY, address(0));

        assertEq(m.potFeeUndelivered(), 0);
        assertEq(potBnbull.pool(), _bnbullFromBnb(potCut), "the backlog reached the pot");

        vm.expectRevert(Marketplace.NothingToWithdraw.selector);
        m.sweepPotFee(NATIVE_KEY, address(0));
    }

    function test_theTokenAccrualSweepsToTheSinkForRouteHeld() public {
        MarketHostileSink dead = new MarketHostileSink();
        Marketplace m = _marketWithSink(address(dead));
        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Fixed, 80e18);
        (uint256 potCut,) = _legs(_grossFee(80e18, FEE_BPS), FEE_BPS, JACKPOT_FEE_BPS);

        bnbull.mint(bob, 80e18);
        vm.startPrank(bob);
        bnbull.approve(address(m), 80e18);
        m.buyWithBNBULL(1);
        vm.stopPrank();

        m.sweepPotFee(address(bnbull), address(potSink));
        assertEq(m.potFeeUndeliveredToken(address(bnbull)), 0);
        assertEq(bnbull.balanceOf(address(potSink)), potCut);

        // ⚠ `DECISIONS.md §14`: routing BNBULL held by the sink touches no DEX
        // at all — it is already the pot's prize token, so the whole slice
        // lands as tokens and `_bnbullFrom…` has nothing to convert.
        vm.prank(keeper);
        potSink.routeHeld(PotSplitter.PotSource.Bnbull, 0);
        assertEq(potBnbull.pool(), potCut);
        assertEq(dex.swapCalls(), 0, "BNBULL WAS SOLD");
    }

    /// @dev A token balance is no longer always stray, so `rescueToken` is
    ///      bounded by what is NOT spoken for.
    function test_rescueCannotDipIntoAnAccruedJackpotSlice() public {
        MarketHostileSink dead = new MarketHostileSink();
        Marketplace m = _marketWithSink(address(dead));
        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Fixed, 80e18);
        (uint256 potCut,) = _legs(_grossFee(80e18, FEE_BPS), FEE_BPS, JACKPOT_FEE_BPS);

        bnbull.mint(bob, 80e18);
        vm.startPrank(bob);
        bnbull.approve(address(m), 80e18);
        m.buyWithBNBULL(1);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(Marketplace.ReservedForPot.selector, potCut, uint256(0))
        );
        m.rescueToken(address(bnbull), owner, potCut);

        // A genuinely stray token is rescuable in full.
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(m), 5e18);
        m.rescueToken(address(stray), owner, 5e18);
        assertEq(stray.balanceOf(owner), 5e18);
    }

    /// @dev There is deliberately NO native rescue: native here is either
    ///      mid-sale, owed through `nativeCredit`, or an accrued pot slice.
    function test_thereIsNoNativeRescue() public {
        (bool ok,) =
            address(market).call(abi.encodeWithSignature("rescueNative(address,uint256)", owner, 1));
        assertFalse(ok, "a native rescue exists on the Marketplace");
    }

    function test_theSinkWireIsTimelockedLikeEveryOtherMoneySlot() public {
        MarketHostileSink other = new MarketHostileSink();
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAddress.AlreadyWired.selector, address(potSink))
        );
        market.bootstrapWire(Marketplace.Wire.JackpotSink, address(other));

        uint64 eta = market.proposeWire(Marketplace.Wire.JackpotSink, address(other));
        vm.expectRevert();
        market.commitWire(Marketplace.Wire.JackpotSink);
        vm.warp(eta);
        market.commitWire(Marketplace.Wire.JackpotSink);
        assertEq(market.jackpotSink(), address(other));

        // ...and `wires()` still leaves `JackpotSink` out of its tuple, so the
        // preflight's destructuring did not break when the slot was added.
        (address f, address b) = market.wires();
        assertEq(f, address(feed));
        assertEq(b, address(bnbull));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  APPROVAL-BASED, AND THE DUEL LOCK-OUT
    // ══════════════════════════════════════════════════════════════════════

    function test_theSellerKeepsCustodyUntilTheMomentOfSale() public {
        _list(alice, 1, LIST_USD);
        assertEq(bulls.ownerOf(1), alice, "no NFT is ever locked in this contract");
        assertEq(bulls.balanceOf(address(market)), 0);

        uint256 gross = _bnbGross(LIST_USD);
        vm.deal(bob, gross);
        vm.prank(bob);
        market.buyWithBNB{value: gross}(1);
        assertEq(bulls.ownerOf(1), bob, "and it moves straight from seller to buyer");
    }

    /**
     * @notice THE DUEL LOCK-OUT VIEW. One storage read, no oracle, no external
     *         call, cannot revert — a fight must never fail because of a market
     *         fault.
     */
    function test_isListedIsOneReadAndCannotRevert() public {
        assertFalse(market.isListed(1));
        assertFalse(market.isListed(999_999), "a token that does not exist is simply not listed");

        _list(alice, 1, LIST_USD);
        assertTrue(market.isListed(1));

        // With the oracle DEAD it still answers, while pricing is refused.
        feed.setReadReverts(true);
        assertTrue(market.isListed(1), "a stale feed must never block a fight");
        vm.expectRevert();
        market.bnbUsdPrice();

        market.isListed(1); // warm
        uint256 g0 = gasleft();
        market.isListed(1);
        uint256 used = g0 - gasleft();
        assertLt(used, 5_000, "isListed is doing more than one SLOAD");
    }

    function test_cancellingReleasesTheBullBackToTheDuel() public {
        _list(alice, 1, LIST_USD);
        vm.prank(alice);
        market.cancel(1);
        assertFalse(market.isListed(1));

        // ...and cancelling works even during an emergency freeze: a seller
        // must always be able to leave.
        _list(alice, 1, LIST_USD);
        market.pause();
        vm.prank(alice);
        market.cancel(1);
        assertFalse(market.isListed(1));
    }

    function test_onlyTheSellerMayCancelOrRePrice() public {
        _list(alice, 1, LIST_USD);

        vm.prank(bob);
        vm.expectRevert(Marketplace.NotSeller.selector);
        market.cancel(1);

        vm.prank(bob);
        vm.expectRevert(Marketplace.NotSeller.selector);
        market.updatePrice(1, 50e18, Marketplace.BnbullMode.Off, 0);

        vm.prank(alice);
        market.updatePrice(1, 50e18, Marketplace.BnbullMode.Off, 0);
        assertEq(market.listingOf(1).usdPrice, 50e18);
    }

    function test_listingRequiresOwnershipApprovalAndANonZeroPrice() public {
        vm.prank(bob);
        vm.expectRevert(Marketplace.NotTokenOwner.selector);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);

        vm.prank(alice);
        vm.expectRevert(Marketplace.ZeroPrice.selector);
        market.list(1, 0, Marketplace.BnbullMode.Off, 0);

        vm.prank(alice);
        bulls.setApprovalForAll(address(market), false);
        vm.prank(alice);
        vm.expectRevert(Marketplace.NotApproved.selector);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);
    }

    function test_bnbullTermsAreValidatedAtListTime() public {
        vm.prank(alice);
        vm.expectRevert(Marketplace.ZeroPrice.selector);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Fixed, 0);

        vm.prank(alice);
        vm.expectRevert(Marketplace.InvalidBnbullMode.selector);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 1e18);

        vm.prank(alice);
        vm.expectRevert(Marketplace.InvalidBnbullMode.selector);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Pegged, 1e18);
    }

    // ─── Dead bulls ───────────────────────────────────────────────────────

    function test_aDeadBullCannotBeListedWhileTheFlagIsOn() public {
        _kill(1);
        assertTrue(market.blocksDeadListings());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Marketplace.BullIsDead.selector, uint256(1)));
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);

        // ⚠ The phase-2 calves instance sets this false, because that
        // collection may not implement `isDead(uint256)` at all.
        market.setBlocksDeadListings(false);
        vm.prank(alice);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);
        assertTrue(market.isListed(1));
    }

    function test_aBullThatDiesAfterListingCannotBeBoughtAndIsSweepable() public {
        _list(alice, 1, LIST_USD);
        _kill(1);

        uint256 gross = _bnbGross(LIST_USD);
        vm.deal(bob, gross);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Marketplace.BullIsDead.selector, uint256(1)));
        market.buyWithBNB{value: gross}(1);

        assertTrue(market.isStale(1));
        vm.prank(carol); // anyone may clear it
        market.sweep(1);
        assertFalse(market.isListed(1));
    }

    /// @dev A listing is a standing offer, not a guarantee. Move the token or
    ///      revoke approval and it goes stale; anyone may sweep it, but a GOOD
    ///      listing may only be cancelled by its seller.
    function test_staleListingsAreSweepableAndGoodOnesAreNot() public {
        _list(alice, 1, LIST_USD);

        vm.expectRevert(Marketplace.NotStale.selector);
        market.sweep(1);

        vm.prank(alice);
        bulls.transferFrom(alice, carol, 1);
        assertTrue(market.isStale(1));

        // The new owner cannot list over it, and cannot cancel it — but the
        // sweep is open to everyone, which is what keeps it from being stuck.
        vm.prank(carol);
        bulls.setApprovalForAll(address(market), true);
        vm.prank(carol);
        vm.expectRevert(Marketplace.AlreadyListed.selector);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);

        vm.prank(carol);
        market.sweep(1);
        assertFalse(market.isListed(1));

        vm.prank(carol);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Off, 0);
        assertTrue(market.isListed(1));
    }

    function test_revokingApprovalMakesAListingStale() public {
        _list(alice, 1, LIST_USD);
        vm.prank(alice);
        bulls.setApprovalForAll(address(market), false);

        assertTrue(market.isStale(1));
        uint256 gross = _bnbGross(LIST_USD);
        vm.deal(bob, gross);
        vm.prank(bob);
        vm.expectRevert(Marketplace.NotApproved.selector);
        market.buyWithBNB{value: gross}(1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  QUOTE NEVER REVERTS
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A grid renders hundreds of listings at once, so one stale feed
     *         must not blank the page. A ZERO leg means "unavailable"; a real
     *         amount is never zero, because every conversion rounds up from a
     *         non-zero price.
     */
    function test_quoteNeverRevertsAndZeroMeansUnavailable() public {
        // Not listed at all.
        (uint256 usd, uint256 bnbDue, uint256 bullDue, uint256 px) = market.quote(1);
        assertEq(usd + bnbDue + bullDue + px, 0);

        _listPegged(alice, 1, LIST_USD);
        (usd, bnbDue, bullDue, px) = market.quote(1);
        assertEq(usd, LIST_USD);
        assertEq(bnbDue, _bnbGross(LIST_USD));
        assertEq(bullDue, 8_000e18);
        assertEq(px, BNB_USD_1E18);

        // A dead feed zeroes only the BNB leg.
        feed.setReadReverts(true);
        (, bnbDue, bullDue, px) = market.quote(1);
        assertEq(bnbDue, 0, "unavailable");
        assertEq(px, 0);
        assertEq(bullDue, 8_000e18, "the other leg is untouched");
        feed.setReadReverts(false);

        // A stale peg zeroes only the BNBULL leg. (The feed is refreshed so the
        // BNB leg is unambiguously answering for itself.)
        vm.warp(block.timestamp + 2 hours);
        feed.setAnswer(BNB_USD_8);
        (, bnbDue, bullDue,) = market.quote(1);
        assertEq(bullDue, 0, "unavailable");
        assertGt(bnbDue, 0);
    }

    function test_quoteReturnsZeroForALegWhoseAssetIsNotWired() public {
        Marketplace bare = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        vm.prank(alice);
        bulls.setApprovalForAll(address(bare), true);
        vm.prank(alice);
        bare.list(1, LIST_USD, Marketplace.BnbullMode.Pegged, 0);

        (uint256 usd, uint256 bnbDue, uint256 bullDue,) = bare.quote(1);
        assertEq(usd, LIST_USD, "the sticker is always readable");
        assertEq(bnbDue, 0);
        assertEq(bullDue, 0);
    }

    function test_quoteIsExactlyWhatTheBuyWillTake() public {
        market.setDiscountBps(market.NATIVE(), 250);
        _list(alice, 1, LIST_USD);

        (, uint256 bnbDue,,) = market.quote(1);
        vm.deal(bob, bnbDue);
        vm.prank(bob);
        market.buyWithBNB{value: bnbDue}(1);
        assertEq(bob.balance, 0, "the quote was the price, to the wei");
    }

    function testFuzz_quoteNeverRevertsForAnyTokenId(uint256 tokenId) public view {
        market.quote(tokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE BNBULL PEG
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A stale or absent peg REFUSES the sale outright. It never falls
     *         back to a guess: the failure mode of an out-of-date peg is a bull
     *         sold for too few tokens, and that is not recoverable.
     */
    function test_aStalePegRefusesTheSaleOutright() public {
        _listPegged(alice, 1, LIST_USD);
        vm.warp(block.timestamp + 2 hours); // maxBnbullPegAge is 1h

        bnbull.mint(bob, 100_000e18);
        vm.startPrank(bob);
        bnbull.approve(address(market), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.BnbullPegUnavailable.selector,
                BNBULL_USD_1E18,
                market.bnbullUsdUpdatedAt()
            )
        );
        market.buyWithBNBULL(1);
        vm.stopPrank();

        assertTrue(market.isListed(1), "and the listing survives to be bought another way");
    }

    /// @dev Writing zero is the kill switch for a keeper that lost its price
    ///      source, and it takes effect immediately.
    function test_writingAZeroPegDisablesTheBnbullLegImmediately() public {
        _listPegged(alice, 1, LIST_USD);
        vm.prank(keeper);
        market.setBnbullUsd(0);

        (,, uint256 bullDue,) = market.quote(1);
        assertEq(bullDue, 0);

        bnbull.mint(bob, 100_000e18);
        vm.startPrank(bob);
        bnbull.approve(address(market), type(uint256).max);
        vm.expectRevert();
        market.buyWithBNBULL(1);
        vm.stopPrank();
    }

    /// @dev A `Fixed` listing names an exact BNBULL amount and never touches
    ///      the peg, so a keeper outage cannot mis-price it — the seller
    ///      carries the drift instead.
    function test_aFixedBnbullListingNeedsNoPegAtAll() public {
        vm.prank(alice);
        market.list(1, LIST_USD, Marketplace.BnbullMode.Fixed, 9_000e18);
        vm.prank(keeper);
        market.setBnbullUsd(0);

        (,, uint256 bullDue,) = market.quote(1);
        assertEq(bullDue, 9_000e18);

        bnbull.mint(bob, 9_000e18);
        vm.startPrank(bob);
        bnbull.approve(address(market), 9_000e18);
        market.buyWithBNBULL(1);
        vm.stopPrank();
        assertEq(bulls.ownerOf(1), bob);
    }

    function test_bnbullIsRefusedOnAListingThatDidNotOptIn() public {
        _list(alice, 1, LIST_USD); // BnbullMode.Off
        bnbull.mint(bob, 100_000e18);
        vm.startPrank(bob);
        bnbull.approve(address(market), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Marketplace.BnbullNotAccepted.selector, uint256(1)));
        market.buyWithBNBULL(1);
        vm.stopPrank();
    }

    function test_thePegPolicyIsBoundedAndKeeperWritable() public {
        vm.expectRevert(abi.encodeWithSelector(Marketplace.BadOraclePolicy.selector, uint256(0)));
        market.setMaxBnbullPegAge(0);

        uint256 tooLong = market.MAX_PEG_AGE() + 1;
        vm.expectRevert(abi.encodeWithSelector(Marketplace.BadOraclePolicy.selector, tooLong));
        market.setMaxBnbullPegAge(tooLong);

        vm.prank(alice);
        vm.expectRevert(Marketplace.NotKeeperOrOwner.selector);
        market.setBnbullUsd(1e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  AWKWARD RECEIVERS
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A seller with a receiver that refuses native cannot make their
     *         own listing unbuyable. They are paid by credit instead.
     */
    function test_anAwkwardSellerIsPaidByCreditAndCanPullItLater() public {
        MarketAwkwardSeller seller = new MarketAwkwardSeller();
        uint256 tokenId = _giveBullTo(address(seller));
        uint256 gross = _bnbGross(LIST_USD);
        uint256 proceeds = gross - _grossFee(gross, FEE_BPS);

        vm.deal(bob, gross);
        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(market));
        emit Marketplace.NativeCredited(address(seller), proceeds);
        market.buyWithBNB{value: gross}(tokenId);

        assertEq(bulls.ownerOf(tokenId), bob, "the sale still settled");
        assertEq(market.nativeCredit(address(seller)), proceeds);

        seller.setAccepts(true);
        seller.exec(address(market), abi.encodeWithSignature("withdrawCredit()"));
        assertEq(address(seller).balance, proceeds);
        assertEq(market.nativeCredit(address(seller)), 0);

        vm.expectRevert(Marketplace.NothingToWithdraw.selector);
        seller.exec(address(market), abi.encodeWithSignature("withdrawCredit()"));
    }

    /// @dev A plain contract with no `receive()` at all — the commonest case.
    function test_aSellerWithNoReceiveIsCreditedToo() public {
        MarketBlindReceiver seller = new MarketBlindReceiver();
        uint256 tokenId = _giveBullTo(address(seller));
        uint256 gross = _bnbGross(LIST_USD);

        vm.deal(bob, gross);
        vm.prank(bob);
        market.buyWithBNB{value: gross}(tokenId);
        assertEq(market.nativeCredit(address(seller)), gross - _grossFee(gross, FEE_BPS));
    }

    /**
     * @notice ...and a seller who BURNS gas on receipt cannot charge the buyer
     *         for the privilege. `NATIVE_PAY_GAS` bounds the stipend, so the
     *         grief costs 60k and lands them in the credit queue.
     */
    function test_aGasBurningSellerCannotGriefTheBuyer() public {
        MarketAwkwardSeller seller = new MarketAwkwardSeller();
        seller.setBurnGas(true);
        uint256 tokenId = _giveBullTo(address(seller));
        uint256 gross = _bnbGross(LIST_USD);

        vm.deal(bob, gross);
        uint256 g0 = gasleft();
        vm.prank(bob);
        market.buyWithBNB{value: gross}(tokenId);
        uint256 used = g0 - gasleft();

        assertEq(bulls.ownerOf(tokenId), bob);
        assertEq(market.nativeCredit(address(seller)), gross - _grossFee(gross, FEE_BPS));
        assertLt(used, 700_000, "the seller burned more than the bounded stipend");
    }

    function test_overpayingInBnbIsRefundedAndUnderpayingReverts() public {
        _list(alice, 1, LIST_USD);
        uint256 gross = _bnbGross(LIST_USD);

        vm.deal(bob, gross * 3);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(Marketplace.InsufficientBNB.selector, gross, gross - 1)
        );
        market.buyWithBNB{value: gross - 1}(1);

        vm.prank(bob);
        market.buyWithBNB{value: gross * 3}(1);
        assertEq(bob.balance, gross * 2, "the surplus came straight back");
    }

    function test_bareNativeSendsAreRefused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok, "BNB is a payment currency here, but only through buyWithBNB");
    }

    /// @dev A fee-on-transfer payment token would silently shortchange the
    ///      seller, so the measured pull refuses the sale outright.
    function test_aFeeOnTransferPaymentTokenRefusesTheSale() public {
        MockFeeToken fot = new MockFeeToken(100);
        Marketplace m = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        // ⚠ Wired as BNBULL, not as a stablecoin (`DECISIONS.md §26`). That is
        // the more honest test anyway: BNBULL is launchpad-issued, so "no fee
        // on transfer" is a thing to VERIFY at deploy, not to assume.
        m.bootstrapWire(Marketplace.Wire.Bnbull, address(fot));
        m.bootstrapWire(Marketplace.Wire.PriceFeed, address(feed));
        vm.prank(alice);
        bulls.setApprovalForAll(address(m), true);
        vm.prank(alice);
        m.list(1, LIST_USD, Marketplace.BnbullMode.Fixed, 80e18);

        fot.mint(bob, 100e18);
        vm.startPrank(bob);
        fot.approve(address(m), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.PaymentShortfall.selector, uint256(80e18), uint256(792e17)
            )
        );
        m.buyWithBNBULL(1);
        vm.stopPrank();

        assertEq(bulls.ownerOf(1), alice, "the bull never moved");
    }

    /**
     * @notice A re-entrant buyer gets nowhere: `nonReentrant` and CEI both
     *         stop it, and the outer sale still completes.
     */
    function test_aReentrantBuyerCannotDoubleSpendAListing() public {
        MarketReentrantBuyer buyer = new MarketReentrantBuyer();
        buyer.setMarket(address(market));
        _list(alice, 1, LIST_USD);

        uint256 gross = _bnbGross(LIST_USD);
        vm.deal(address(buyer), gross * 2);
        buyer.buy(1, gross);

        assertEq(bulls.ownerOf(1), address(buyer), "the outer sale settled");
        assertEq(buyer.innerAttempts(), 1);
        assertFalse(buyer.innerSucceeded(), "the re-entrant buy got nothing");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE ORACLE — refuses rather than clamps
    // ══════════════════════════════════════════════════════════════════════

    function test_theOracleRefusesRatherThanClamping() public {
        _list(alice, 1, LIST_USD);
        vm.deal(bob, 100 ether);

        feed.setRound(2, 0, block.timestamp, block.timestamp, 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Marketplace.OracleBadAnswer.selector, int256(0)));
        market.buyWithBNB{value: 1 ether}(1);

        feed.setRound(5, BNB_USD_8, block.timestamp, block.timestamp, 4);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.OracleBadRound.selector, uint80(5), uint80(4), block.timestamp
            )
        );
        market.buyWithBNB{value: 1 ether}(1);

        feed.setAnswer(BNB_USD_8);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bob);
        vm.expectRevert();
        market.buyWithBNB{value: 1 ether}(1);
    }

    /// @dev The sanity band exists because a feed pinned at a circuit-breaker
    ///      floor would otherwise sell every listed bull for dust.
    function test_theSanityBandRefusesAnAbsurdPrice() public {
        market.setOraclePolicy(1 hours, 100e18, 5_000e18);
        _list(alice, 1, LIST_USD);

        feed.setAnswer(1e8); // $1/BNB
        vm.deal(bob, 500 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Marketplace.OracleOutOfBand.selector, uint256(1e18)));
        market.buyWithBNB{value: 500 ether}(1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Pause
    // ══════════════════════════════════════════════════════════════════════

    function test_pauseStopsListingAndBuyingButNeverCancelling() public {
        _list(alice, 1, LIST_USD);
        market.pause();

        vm.prank(alice);
        vm.expectRevert();
        market.list(2, LIST_USD, Marketplace.BnbullMode.Off, 0);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert();
        market.buyWithBNB{value: 1 ether}(1);

        vm.prank(alice);
        market.cancel(1);

        market.unpause();
        _list(alice, 1, LIST_USD);
        assertTrue(market.isListed(1));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _buyWithBnbull(address buyer, uint256 tokenId, uint256 amount) internal {
        bnbull.mint(buyer, amount);
        vm.startPrank(buyer);
        bnbull.approve(address(market), amount);
        market.buyWithBNBULL(tokenId);
        vm.stopPrank();
    }

    /// @dev Mint a fresh bull to a contract and list it from there.
    function _giveBullTo(address who) internal returns (uint256 tokenId) {
        tokenId = bulls.nextTokenId();
        bulls.mint(who);
        IMarketExec(who).exec(
            address(bulls),
            abi.encodeWithSignature("setApprovalForAll(address,bool)", address(market), true)
        );
        IMarketExec(who).exec(
            address(market),
            abi.encodeWithSignature(
                "list(uint256,uint128,uint8,uint128)", tokenId, LIST_USD, uint8(0), uint128(0)
            )
        );
    }
}
