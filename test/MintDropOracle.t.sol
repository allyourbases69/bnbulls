// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20, NoDecimalsToken} from "./mocks/MockERC20.sol";

/**
 * @title MintDropOracleTest
 * @notice PRIORITY 3. Oracle safety on the money path.
 *
 * @dev `DECISIONS.md §3` is blunt about why this file is the heart of the port:
 *
 *        "| `$USDT0` | `$BNB` | the native gas token — **but BNB is
 *         volatile**, so every site that treated USDT0 as 'the dollar' needs
 *         the oracle, not a rename ... a mechanical find-and-replace of
 *         USDT0→BNB produces code that compiles and is economically wrong."
 *
 *      On Stable, `native == USDT == the dollar` and a $10 mint cost 10 native,
 *      forever, with no feed anywhere. On BNB a $10 mint costs whatever $10 of
 *      BNB is worth in the block it lands in. So there are two things to prove:
 *
 *        1. THE FEED IS ACTUALLY BEING READ AND USED. The strongest statement
 *           of that is `test_theSameDollarStickerCostsDifferentBnb...`: move
 *           the feed, and the BNB due moves inversely. A rename would not do
 *           that.
 *        2. EVERY UNHEALTHY FEED STATE REVERTS, NEVER CLAMPS. A clamp is a
 *           wrong price presented as a right one — `DECISIONS.md §1` says
 *           "revert, don't clamp silently", and each of the five states below
 *           gets its own test on the VIEW *and* on the MONEY PATH, because a
 *           guard that only protects `quote()` protects nothing.
 */
contract MintDropOracleTest is BnbullsBase {
    function setUp() public override {
        super.setUp();
        // A realistic clock, so "an hour stale" means an hour.
        vm.warp(1_800_000_000);
        feed.setAnswer(BNB_USD_8);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A healthy feed prices a mint correctly, at several BNB/USD levels
    // ══════════════════════════════════════════════════════════════════════

    function test_healthyFeedNormalisesTo1e18() public view {
        assertEq(drop.bnbUsdPrice(), BNB_USD_1E18);
        assertEq(drop.feedDecimals(), 8);
    }

    /// @dev The $10 rung, priced at four very different BNB/USD levels. Each
    ///      expectation is computed independently of the contract.
    function test_healthyFeedPricesTheFirstRungAtEveryBnbLevel() public {
        uint256[4] memory usdPerBnb8 = [uint256(200e8), 600e8, 1_000e8, 37e8];
        for (uint256 i = 0; i < usdPerBnb8.length; i++) {
            feed.setAnswer(int256(usdPerBnb8[i]));
            uint256 p1e18 = usdPerBnb8[i] * 1e10; // 8dp -> 18dp
            assertEq(drop.bnbUsdPrice(), p1e18);

            (uint256 usdTotal, uint256 bnbDue,, uint256 quotedPrice) = drop.quote(1);
            assertEq(usdTotal, 10e18, "the sticker is a DOLLAR figure, always");
            assertEq(quotedPrice, p1e18, "the quote publishes the answer it used");
            assertEq(bnbDue, _ceilDiv(10e18 * 1e18, p1e18));
        }
    }

    /// @dev $600/BNB, $10 sticker -> 0.016666666666666667 BNB, rounded UP so a
    ///      rounding artefact can never undercharge the drop.
    function test_theArithmeticInFull() public {
        feed.setAnswer(600e8);
        (, uint256 bnbDue,,) = drop.quote(1);
        assertEq(bnbDue, 16_666_666_666_666_667);
        assertGt(bnbDue * 600, 10e18, "rounds up, never down");
    }

    /**
     * @notice THE `$USDT0 -> $BNB` REWRITE, STATED AS AN ASSERTION.
     *
     * @dev Double the BNB price and the same dollar sticker costs half the BNB.
     *      A find-and-replace port would have a fixed native amount here and
     *      this test would fail — which is the whole point of writing it.
     */
    function test_theSameDollarStickerCostsDifferentBnbAsThePriceMoves() public {
        feed.setAnswer(600e8);
        (, uint256 dueAt600,,) = drop.quote(1);

        feed.setAnswer(1_200e8);
        (, uint256 dueAt1200,,) = drop.quote(1);

        assertApproxEqAbs(dueAt1200 * 2, dueAt600, 2, "BNB due did not track the feed");
        assertLt(dueAt1200, dueAt600);

        // And the actual money moved matches, not just the quote.
        uint256 spent = _mintBnb(alice, 1);
        assertEq(spent, dueAt1200, "the mint charged something other than the quote");
    }

    /// @dev The BNBULL leg is keeper-pegged and needs no feed, so it must keep
    ///      working when the oracle is unusable. Two independent legs, two
    ///      independent failure modes — that is the shape `DECISIONS.md §1`
    ///      describes ("the fiat-anchored legs need no keeper — the oracle does
    ///      that job", and vice versa).
    function test_theBnbullLegDoesNotTouchTheOracle() public {
        feed.setReadReverts(true);

        _giveBnbull(bob, 100_000e18);
        vm.prank(bob);
        drop.mintWithBNBULL(bob, 1);
        assertEq(bulls.balanceOf(bob), 1);

        // ...while the BNB leg is correctly dead.
        vm.deal(carol, 10 ether);
        vm.prank(carol);
        vm.expectRevert();
        drop.mintWithBNB{value: 1 ether}(carol, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Every unhealthy state REVERTS. Nothing is clamped.
    // ══════════════════════════════════════════════════════════════════════

    function test_revertsOnZeroAnswer() public {
        feed.setAnswer(0);
        _expectOracleRevertEverywhere(abi.encodeWithSelector(MintDrop.OracleBadAnswer.selector, int256(0)));
    }

    function test_revertsOnNegativeAnswer() public {
        feed.setAnswer(-1);
        _expectOracleRevertEverywhere(
            abi.encodeWithSelector(MintDrop.OracleBadAnswer.selector, int256(-1))
        );
    }

    function test_revertsOnIncompleteRound_answeredInRoundBelowRoundId() public {
        feed.setRound(9, BNB_USD_8, block.timestamp, block.timestamp, 8);
        _expectOracleRevertEverywhere(
            abi.encodeWithSelector(
                MintDrop.OracleBadRound.selector, uint80(9), uint80(8), block.timestamp
            )
        );
    }

    function test_revertsOnZeroUpdatedAt() public {
        feed.setRound(9, BNB_USD_8, block.timestamp, 0, 9);
        _expectOracleRevertEverywhere(
            abi.encodeWithSelector(
                MintDrop.OracleBadRound.selector, uint80(9), uint80(9), uint256(0)
            )
        );
    }

    function test_revertsOnAStaleAnswer() public {
        uint256 t = block.timestamp;
        feed.setAnswer(BNB_USD_8);
        vm.warp(t + drop.maxOracleAge() + 1);
        _expectOracleRevertEverywhere(
            abi.encodeWithSelector(MintDrop.OracleStale.selector, t, drop.maxOracleAge())
        );
    }

    /// @dev The boundary is `>`, not `>=`: an answer EXACTLY at the age limit
    ///      is still good. Worth pinning, because the off-by-one here is the
    ///      difference between "heartbeat just landed" and a dead drop.
    function test_answerExactlyAtMaxAgeIsStillAccepted() public {
        uint256 t = block.timestamp;
        feed.setAnswer(BNB_USD_8);
        vm.warp(t + drop.maxOracleAge());
        assertEq(drop.bnbUsdPrice(), BNB_USD_1E18);

        vm.warp(t + drop.maxOracleAge() + 1);
        vm.expectRevert();
        drop.bnbUsdPrice();
    }

    /// @dev A timestamp in the future is not "stale". `block.timestamp >
    ///      updatedAt` guards the subtraction, so this must not underflow.
    function test_futureTimestampIsNotStaleAndDoesNotUnderflow() public {
        feed.setRound(2, BNB_USD_8, block.timestamp, block.timestamp + 10_000, 2);
        assertEq(drop.bnbUsdPrice(), BNB_USD_1E18);
    }

    function test_revertsBelowTheSanityBand() public {
        drop.setOraclePolicy(1 hours, 100e18, 5_000e18);
        feed.setAnswer(50e8); // $50/BNB — the LUNA circuit-breaker failure mode
        _expectOracleRevertEverywhere(
            abi.encodeWithSelector(MintDrop.OracleOutOfBand.selector, uint256(50e18))
        );
    }

    function test_revertsAboveTheSanityBand() public {
        drop.setOraclePolicy(1 hours, 100e18, 5_000e18);
        feed.setAnswer(9_000e8);
        _expectOracleRevertEverywhere(
            abi.encodeWithSelector(MintDrop.OracleOutOfBand.selector, uint256(9_000e18))
        );
    }

    function test_theBandEdgesThemselvesAreInside() public {
        drop.setOraclePolicy(1 hours, 100e18, 5_000e18);
        feed.setAnswer(100e8);
        assertEq(drop.bnbUsdPrice(), 100e18);
        feed.setAnswer(5_000e8);
        assertEq(drop.bnbUsdPrice(), 5_000e18);
    }

    function test_revertsWhenTheOracleIsNotWiredAtAll() public {
        MintDrop fresh = _freshDrop();
        vm.expectRevert(MintDrop.OracleNotWired.selector);
        fresh.bnbUsdPrice();
    }

    /// @dev Not a clamp anywhere: prove the price the contract returns is never
    ///      a substituted default when the feed misbehaves. Fuzzed over the
    ///      whole int256 domain — every non-positive answer reverts, every
    ///      positive one either reverts (band/stale) or returns exactly itself.
    function testFuzz_answerIsNeverClampedOrSubstituted(int256 answer) public {
        vm.assume(answer < int256(uint256(type(uint160).max))); // keep 1e10 scaling sane
        feed.setAnswer(answer);
        if (answer <= 0) {
            vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleBadAnswer.selector, answer));
            drop.bnbUsdPrice();
        } else {
            assertEq(drop.bnbUsdPrice(), uint256(answer) * 1e10);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Feed decimals: read, never assumed
    // ══════════════════════════════════════════════════════════════════════

    function test_an18DecimalFeedGivesTheSamePriceAsAn8DecimalOne() public {
        MintDrop fresh = _freshDrop();
        MockAggregator feed18 = new MockAggregator(18, 600e18);
        fresh.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed18));
        assertEq(fresh.feedDecimals(), 18);
        assertEq(fresh.bnbUsdPrice(), BNB_USD_1E18);
    }

    function test_aTwentyDecimalFeedIsScaledDownNotAssumed() public {
        MintDrop fresh = _freshDrop();
        MockAggregator feed20 = new MockAggregator(20, 600e20);
        fresh.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed20));
        assertEq(fresh.bnbUsdPrice(), BNB_USD_1E18);
    }

    function test_anUnusableFeedDecimalsFailsTheWiringTxNotTheFirstMint() public {
        MintDrop fresh = _freshDrop();
        MockAggregator silly = new MockAggregator(37, 1e8);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.FeedDecimalsUnusable.selector, uint8(37)));
        fresh.bootstrapWire(MintDrop.Wire.PriceFeed, address(silly));
    }

    /// @dev ⚠ THE DECIMALS TRAP, on the only side `MintDrop` has left.
    ///      `DECISIONS.md §26` removed the stablecoin and with it
    ///      `stableDecimals`, so the FEED is now the only thing here whose
    ///      decimals divide anything — and a feed without `decimals()` must
    ///      fail the WIRING transaction, not the first mint.
    ///
    ///      (`MintDrop`'s BNBULL leg needs no decimals read: `PriceTier
    ///      .bnbullPrice` is a keeper peg already denominated in BNBULL wei.
    ///      Where BNBULL's decimals DO divide something — `Marketplace` — they
    ///      are read, and `MarketplaceDecimals.t.sol` proves it against a
    ///      non-18dp token.)
    function test_aFeedWithoutDecimalsFailsTheWiringTxNotTheFirstMint() public {
        MintDrop fresh = _freshDrop();
        NoDecimalsToken dud = new NoDecimalsToken();
        vm.expectRevert();
        fresh.bootstrapWire(MintDrop.Wire.PriceFeed, address(dud));
        assertEq(fresh.feedDecimals(), 0, "a half-wired feed left its decimals behind");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Policy bounds
    // ══════════════════════════════════════════════════════════════════════

    function test_oraclePolicyIsBounded() public {
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, uint256(0)));
        drop.setOraclePolicy(0, 0, 0);

        uint256 tooOld = drop.MAX_ORACLE_AGE() + 1;
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, tooOld));
        drop.setOraclePolicy(tooOld, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleOutOfBand.selector, uint256(500e18)));
        drop.setOraclePolicy(1 hours, 500e18, 100e18);

        drop.setOraclePolicy(drop.MAX_ORACLE_AGE(), 0, 0);
        assertEq(drop.maxOracleAge(), 24 hours);
    }

    function test_onlyOwnerSetsOraclePolicy() public {
        vm.prank(alice);
        vm.expectRevert();
        drop.setOraclePolicy(1 hours, 0, 0);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /**
     * @dev The same bad feed state must bite on the VIEW, on `quote()` and on
     *      the MONEY PATH. A guard that only protects the read-only surface
     *      protects nothing — the UI would show an error while the mint sold a
     *      bull at whatever the fallback happened to be.
     */
    function _expectOracleRevertEverywhere(bytes memory expected) internal {
        vm.expectRevert(expected);
        drop.bnbUsdPrice();

        vm.expectRevert(expected);
        drop.quote(1);

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(expected);
        drop.mintWithBNB{value: 10 ether}(alice, 1);

        assertEq(drop.totalSold(), 0, "a bull was sold on a bad oracle");
        assertEq(bulls.balanceOf(alice), 0);
    }

    function _freshDrop() internal returns (MintDrop d) {
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
        b.bootstrapWire(Bulls.Wire.MintDrop, address(d));
    }
}
