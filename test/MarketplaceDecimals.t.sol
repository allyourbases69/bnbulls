// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketplaceHarness} from "./Marketplace.t.sol";
import {Marketplace} from "../contracts/Marketplace.sol";
import {MockERC20, NoDecimalsToken} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MarketHostileSink} from "./mocks/MarketMocks.sol";
import {SplitterFatDecimalsToken} from "./mocks/SplitterMocks.sol";

/**
 * @title MarketplaceDecimalsTest
 * @notice THE BUG THAT MUST NOT COME BACK.
 *
 * @dev ⚠ MOCKS ONLY, NO MAINNET FORK. That is not a compromise here, it is the
 *      requirement: the point of this file is that the SAME listing must price
 *      correctly under payment tokens of different precision, and a fork gives
 *      you exactly one of each token.
 *
 *      The scar (`BNB-CHAIN-FACTS.md §3` row 6, `LEARNINGS-AND-MISTAKES`): the
 *      Fighting Fefers marketplace stored `price` in USDG smallest units — 6 dp
 *      — and called that "a plain dollar figure", because on Stable the gas
 *      token WAS USDT and 6 dp WAS the dollar. That rule leaked into the
 *      off-chain tooling and rendered an **$80 listing as $0.00** in
 *      production: `80e6` read through an 18-dp lens is 8e-11.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ WHY THIS FILE STILL EXISTS AFTER `DECISIONS.md §26`
 *      ══════════════════════════════════════════════════════════════════════
 *      §26 dropped the stablecoin, and its own write-up says the deletion "also
 *      deletes an entire bug class — the fefers $80-listing-renders-as-$0.00
 *      decimals bug had nowhere to live but a 6dp payment asset."
 *
 *      That is true of the ASSET and false of the RULE, and this file is the
 *      difference. **BNBULL is now the only ERC-20 whose `decimals()` divides
 *      anything on this contract** — `bnbullDue = ceil(usd1e18 *
 *      10**bnbullDecimals / bnbullUsd1e18)` — and it is the one that genuinely
 *      cannot be checked in advance, because four.meme issues it
 *      (`DECISIONS.md §4`). "BEP-20s are usually 18" is an expectation, not
 *      evidence. So every test that used to drive a 6/18/24-dp stablecoin
 *      through the quote now drives a 6/18/24-dp **BNBULL** through it, and the
 *      assertions are unchanged in shape:
 *
 *        - `usdPrice` is not a token amount at all. It is dollars x 1e18, the
 *          same convention as `MintDrop.PriceTier.usdPrice`, so there is no
 *          "the marketplace is N-dp" rule left to get wrong;
 *        - every divisor is derived at call time from a `decimals()` value READ
 *          off chain state — proved by pricing ONE listing through a 6-dp,
 *          an 18-dp and a 24-dp BNBULL and getting the right dollar amount in
 *          each;
 *        - every conversion rounds UP, so no rounding artefact can shave a wei
 *          off the seller;
 *        - the fee is computed AFTER conversion, in the buyer's own asset, so
 *          no cross-unit fee arithmetic exists to hide a second mistake in.
 *
 *      The peg is set to $1.00 a token wherever the old test used a $1
 *      stablecoin, so the arithmetic reads identically: at 6 dp an $80 listing
 *      is `80e6`, at 18 dp it is `80e18`, and the dollar value is the same.
 */
contract MarketplaceDecimalsTest is MarketplaceHarness {
    /// @notice A peg of exactly one dollar per BNBULL. Not a realistic price —
    ///         a deliberate one, so `bnbullDue` in the token's own units IS the
    ///         dollar figure and the decimals are the only thing under test.
    uint256 internal constant PEG_ONE_DOLLAR = 1e18;

    // ══════════════════════════════════════════════════════════════════════
    //  THE REGRESSION: one listing, three precisions of token
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The same $80 sticker must come out as 80 whole tokens whether the
     *         wired BNBULL is 6 dp or 18 dp. four.meme issues the token, so
     *         which one it will be is not knowable here.
     */
    function test_theSame80DollarListingPricesCorrectlyAt6dpAnd18dp() public {
        MockERC20 b6 = new MockERC20("BNBull", "BNBULL", 6);
        MockERC20 b18 = new MockERC20("BNBull", "BNBULL", 18);

        Marketplace m6 = _marketWithBnbull(address(b6), PEG_ONE_DOLLAR);
        Marketplace m18 = _marketWithBnbull(address(b18), PEG_ONE_DOLLAR);
        assertEq(m6.bnbullDecimals(), 6, "decimals are READ off the token, never assumed");
        assertEq(m18.bnbullDecimals(), 18);

        _listPeggedOn(m6, alice, 1, LIST_USD);
        _listPeggedOn(m18, alice, 2, LIST_USD);

        (,, uint256 due6,) = m6.quote(1);
        (,, uint256 due18,) = m18.quote(2);

        assertEq(due6, 80_000_000, "$80 at 6dp is 80e6 units");
        assertEq(due18, 80e18, "$80 at 18dp is 80e18 units");

        // The identity that matters: both are EIGHTY DOLLARS.
        assertEq(due6 / 10 ** 6, 80, "the 6dp leg is eighty whole dollars");
        assertEq(due18 / 10 ** 18, 80, "and so is the 18dp leg");
    }

    /// @dev A 24-dp token — the `d > 18` branch, which the fefers code had no
    ///      concept of at all.
    function test_theSameListingAlsoPricesAtMoreThan18Decimals() public {
        MockERC20 b24 = new MockERC20("BNBull", "BNBULL", 24);
        Marketplace m = _marketWithBnbull(address(b24), PEG_ONE_DOLLAR);
        assertEq(m.bnbullDecimals(), 24);

        _listPeggedOn(m, alice, 1, LIST_USD);
        (,, uint256 due,) = m.quote(1);
        assertEq(due, 80e24);
        assertEq(due / 10 ** 24, 80, "still eighty whole dollars");
    }

    /**
     * @notice THE $0.00 TEST, stated as bluntly as the bug was. No leg of an
     *         $80 listing may ever be zero, or round to less than a cent of
     *         value in its own units.
     */
    function test_no80DollarLegEverRendersAsZero() public {
        MockERC20 b6 = new MockERC20("BNBull", "BNBULL", 6);
        Marketplace m = _marketWithBnbull(address(b6), BNBULL_USD_1E18); // $0.01

        _listPeggedOn(m, alice, 1, LIST_USD);

        (uint256 usd, uint256 bnbDue, uint256 bullDue, uint256 px) = m.quote(1);
        assertEq(usd, 80e18, "the sticker itself is dollars x 1e18");
        assertGt(bnbDue, 0);
        assertGt(bullDue, 0);
        assertEq(px, BNB_USD_1E18);

        // And each one really is worth $80 at the harness rates.
        assertApproxEqAbs(bnbDue * 600 / 1e18, 80, 1, "BNB leg is ~$80");
        assertEq(bullDue, 8_000 * 10 ** 6, "BNBULL leg is 8,000 tokens at $0.01 = $80, at 6dp");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  BNB is 18 dp — a CHAIN fact, not a token property
    // ══════════════════════════════════════════════════════════════════════

    function test_bnbIs18dpAndConvertsThroughTheOracle() public {
        _list(alice, 1, LIST_USD);
        (, uint256 bnbDue,,) = market.quote(1);

        // $80 at $600/BNB = 0.13333... BNB.
        assertEq(bnbDue, 133_333_333_333_333_334);
        assertGe(bnbDue * 600e18 / 1e18, 80e18, "the rounding never shortchanges the seller");
    }

    /// @dev The FEED's decimals are read too. BNB/USD is 8 dp on BSC, but
    ///      nothing here assumes it.
    function test_theFeedDecimalsAreReadNotAssumed() public {
        MockAggregator feed18 = new MockAggregator(18, 600e18);
        Marketplace m = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        m.bootstrapWire(Marketplace.Wire.PriceFeed, address(feed18));
        assertEq(m.feedDecimals(), 18);
        assertEq(m.bnbUsdPrice(), 600e18, "an 18dp feed normalises to the same 1e18 price");

        MockAggregator feed20 = new MockAggregator(20, 600e20);
        Marketplace m20 = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        m20.bootstrapWire(Marketplace.Wire.PriceFeed, address(feed20));
        assertEq(m20.feedDecimals(), 20);
        assertEq(m20.bnbUsdPrice(), 600e18, "and so does a 20dp one, by dividing instead");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  BNBULL at a real, awkward price
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `DECISIONS.md §4`: the token is four.meme's, so "BEP-20s are
    ///      usually 18" is not evidence.
    function test_bnbullAtNon18DecimalsPricesCorrectly() public {
        MockERC20 bull9 = new MockERC20("BNBull", "BNBULL", 9);
        Marketplace m = _marketWithBnbull(address(bull9), 5e14); // $0.0005
        assertEq(m.bnbullDecimals(), 9);

        _listPeggedOn(m, alice, 1, LIST_USD);
        (,, uint256 due,) = m.quote(1);

        // $80 / $0.0005 = 160,000 BNBULL, expressed in 9dp units.
        assertEq(due, 160_000 * 10 ** 9);
        assertEq(due / 10 ** 9, 160_000, "one hundred and sixty thousand whole tokens");
    }

    function test_bnbullAt6DecimalsPricesCorrectlyToo() public {
        MockERC20 bull6 = new MockERC20("BNBull", "BNBULL", 6);
        Marketplace m = _marketWithBnbull(address(bull6), BNBULL_USD_1E18); // $0.01
        _listPeggedOn(m, alice, 1, LIST_USD);

        (,, uint256 due,) = m.quote(1);
        assertEq(due, 8_000 * 10 ** 6, "$80 / $0.01 = 8,000 tokens, at 6dp");
    }

    /// @dev And a bull is actually BOUGHT at that price, so the divisor is
    ///      proved on the settlement path, not only in the view.
    function test_aNon18DecimalBnbullSaleSettlesAtTheQuotedAmount() public {
        MockERC20 bull9 = new MockERC20("BNBull", "BNBULL", 9);
        Marketplace m = _marketWithBnbull(address(bull9), 5e14);
        _listPeggedOn(m, alice, 1, LIST_USD);

        uint256 gross = 160_000 * 10 ** 9;
        bull9.mint(bob, gross);
        vm.startPrank(bob);
        bull9.approve(address(m), gross);
        m.buyWithBNBULL(1, LIST_USD, type(uint256).max);
        vm.stopPrank();

        assertEq(bulls.ownerOf(1), bob);
        assertEq(bull9.balanceOf(bob), 0, "exactly the quote, no more and no less");
        assertEq(bull9.balanceOf(alice), gross - (gross * FEE_BPS) / 10_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  EVERY CONVERSION ROUNDS UP
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `_ceilDiv` everywhere, so a rounding artefact can never shave a
     *         wei off the seller. Proved on a sticker chosen to be indivisible
     *         in the target precision.
     */
    function test_theBnbullConversionRoundsUpAtSixDecimals() public {
        MockERC20 b6 = new MockERC20("BNBull", "BNBULL", 6);
        Marketplace m = _marketWithBnbull(address(b6), PEG_ONE_DOLLAR);

        // $80.000000000000000001 — one wei of a dollar above a clean number.
        uint128 awkward = 80e18 + 1;
        _listPeggedOn(m, alice, 1, awkward);

        (,, uint256 due,) = m.quote(1);
        assertEq(due, 80_000_001, "rounded UP to the next whole 6dp unit");
        assertGe(due * 1e12, uint256(awkward), "and it covers the sticker");
    }

    function test_theBnbConversionRoundsUp() public {
        // $1 at $600/BNB = 0.001666...  BNB, which never divides evenly.
        _list(alice, 1, 1e18);
        (, uint256 due,,) = market.quote(1);
        assertEq(due, 1_666_666_666_666_667);
        assertEq(due, _ceilDiv(1e18 * 1e18, BNB_USD_1E18));
        assertGe(due * BNB_USD_1E18, 1e18 * 1e18, "the buyer covers the dollar, always");
    }

    function test_theBnbullConversionRoundsUpAtAnAwkwardPeg() public {
        MockERC20 bull9 = new MockERC20("BNBull", "BNBULL", 9);
        Marketplace m = _marketWithBnbull(address(bull9), 3e14); // $0.0003
        _listPeggedOn(m, alice, 1, LIST_USD);

        (,, uint256 due,) = m.quote(1);
        // 80e18 * 1e9 / 3e14 = 266,666.666... -> ceil
        assertEq(due, 266_666_666_666_667);
        assertGe(due * 3e14, uint256(LIST_USD) * 10 ** 9, "the buyer covers the sticker");
    }

    function testFuzz_everyLegAlwaysCoversTheDollarSticker(uint96 usdRaw) public {
        uint128 usd = uint128(bound(uint256(usdRaw), 1, 1e30));
        MockERC20 b6 = new MockERC20("BNBull", "BNBULL", 6);
        Marketplace m = _marketWithBnbull(address(b6), PEG_ONE_DOLLAR);
        _listPeggedOn(m, alice, 1, usd);

        (, uint256 bnbDue, uint256 bullDue,) = m.quote(1);
        assertGe(bnbDue * BNB_USD_1E18, uint256(usd) * 1e18, "the BNB leg under-charged");
        assertGe(bullDue * PEG_ONE_DOLLAR, uint256(usd) * 10 ** 6, "the BNBULL leg under-charged");
        assertGt(bnbDue, 0, "a real amount is never zero");
        assertGt(bullDue, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE FEE IS COMPUTED AFTER CONVERSION, IN THE BUYER'S OWN ASSET
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice No cross-unit fee arithmetic exists. The fee on a 6-dp sale is
     *         6-dp units of that token; the fee on the identical listing paid
     *         in BNB is wei. There is nowhere for a second decimals mistake to
     *         hide.
     */
    function test_theFeeIsTakenInTheBuyersOwnUnits() public {
        MockERC20 b6 = new MockERC20("BNBull", "BNBULL", 6);
        MarketHostileSink sink = new MarketHostileSink();
        sink.setTakeTokens(true);
        Marketplace m = _marketWithBnbull(address(b6), PEG_ONE_DOLLAR);
        m.bootstrapWire(Marketplace.Wire.JackpotSink, address(sink));

        _listPeggedOn(m, alice, 1, LIST_USD);

        uint256 gross = 80_000_000; // 6dp
        uint256 fee = (gross * FEE_BPS) / 10_000; // 6,000,000 = $6.00
        uint256 potCut = (fee * JACKPOT_FEE_BPS) / FEE_BPS;

        b6.mint(bob, gross);
        vm.startPrank(bob);
        b6.approve(address(m), gross);
        m.buyWithBNBULL(1, LIST_USD, type(uint256).max);
        vm.stopPrank();

        assertEq(fee, 6_000_000, "7.5% of $80 is $6.00, in 6dp units");
        assertEq(b6.balanceOf(alice), gross - fee, "$74.00 to the seller");
        assertEq(b6.balanceOf(address(sink)), potCut, "$2.00 to the jackpot leg");
        assertEq(b6.balanceOf(treasury), fee - potCut, "$4.00 to the dev");

        // The identical listing in BNB: same DOLLARS, different UNITS.
        _list(alice, 2, LIST_USD);
        uint256 bnbGross = _bnbGross(LIST_USD);
        vm.deal(bob, bnbGross);
        vm.prank(bob);
        market.buyWithBNB{value: bnbGross}(2, LIST_USD, type(uint256).max);
        assertEq(treasury.balance, (bnbGross * FEE_BPS) / 10_000 - _potOf(bnbGross));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE DECIMALS TRAP IS CAUGHT AT WIRING TIME
    // ══════════════════════════════════════════════════════════════════════

    function test_wiringATokenWithNoDecimalsFailsTheWiringTransaction() public {
        Marketplace m = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        NoDecimalsToken bad = new NoDecimalsToken();
        vm.expectRevert();
        m.bootstrapWire(Marketplace.Wire.Bnbull, address(bad));
        assertEq(m.bnbullDecimals(), 0, "a half-wired token left its divisor behind");
    }

    function test_wiringATokenWithAbsurdDecimalsFailsTheWiringTransaction() public {
        Marketplace m = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        SplitterFatDecimalsToken bad = new SplitterFatDecimalsToken(); // 37 dp
        vm.expectRevert(abi.encodeWithSelector(Marketplace.TokenDecimalsUnusable.selector, 37));
        m.bootstrapWire(Marketplace.Wire.Bnbull, address(bad));
    }

    /// @dev Re-pointing BNBULL re-reads its decimals, so the divisor can never
    ///      be left describing the previous token. That matters more than it
    ///      used to: `DECISIONS.md §22` expects the token's venue — and in a
    ///      relaunch, the token itself — to be re-pointed after graduation.
    function test_repointingBnbullReReadsItsDecimals() public {
        MockERC20 b6 = new MockERC20("BNBull", "BNBULL", 6);
        Marketplace m = _marketWithBnbull(address(b6), PEG_ONE_DOLLAR);
        assertEq(m.bnbullDecimals(), 6);

        MockERC20 b18 = new MockERC20("BNBull", "BNBULL", 18);
        uint64 eta = m.proposeWire(Marketplace.Wire.Bnbull, address(b18));
        assertEq(m.bnbullDecimals(), 6, "decimals moved before the commit");
        vm.warp(eta);
        m.commitWire(Marketplace.Wire.Bnbull);
        // The timelock sailed past `maxBnbullPegAge` (1 hour) and `maxOracleAge`
        // — republish both, or this asserts staleness rather than the divisor.
        m.setBnbullUsd(PEG_ONE_DOLLAR);
        feed.setAnswer(BNB_USD_8);

        assertEq(m.bnbullDecimals(), 18, "the divisor followed the token");
        _listPeggedOn(m, alice, 1, LIST_USD);
        (,, uint256 due,) = m.quote(1);
        assertEq(due, 80e18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _marketWithBnbull(address token, uint256 peg) internal returns (Marketplace m) {
        m = new Marketplace(address(bulls), treasury, FEE_BPS, owner);
        m.bootstrapWire(Marketplace.Wire.PriceFeed, address(feed));
        m.bootstrapWire(Marketplace.Wire.Bnbull, token);
        m.setBnbullUsd(peg);
        vm.prank(alice);
        bulls.setApprovalForAll(address(m), true);
    }

    function _listPeggedOn(Marketplace m, address seller, uint256 tokenId, uint128 usd) internal {
        vm.prank(seller);
        m.list(tokenId, usd, Marketplace.BnbullMode.Pegged, 0);
    }

    function _potOf(uint256 gross) internal pure returns (uint256) {
        return ((gross * FEE_BPS) / 10_000 * JACKPOT_FEE_BPS) / FEE_BPS;
    }
}
