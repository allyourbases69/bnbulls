// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {IAggregatorV3Fork, IERC20Fork} from "./ForkInterfaces.sol";

import {Bulls} from "../../contracts/Bulls.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";
import {Duel} from "../../contracts/Duel.sol";

/**
 * @title ChainlinkFeedForkTest
 * @notice `DECISIONS.md §1` option A, against the LIVE BNB/USD aggregator.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHAT A MOCK CANNOT DO HERE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * `MockAggregator` returns $600 with `updatedAt = block.timestamp` because a
 * test told it to. It cannot tell us:
 *
 *   - what the feed's REAL update cadence is, and therefore whether
 *     `maxOracleAge = 1 hours` is a policy that will hold in honest operation
 *     or one that will start reverting mints on a quiet afternoon;
 *   - whether the feed's `decimals()` is really 8 — `MintDrop._afterWire`
 *     caches it and every conversion divides by it;
 *   - whether `answeredInRound`/`roundId` on the real aggregator satisfy the
 *     `answeredInRound >= roundId` check, which on a phase-shifted proxy is
 *     NOT the obvious pass it looks like (both are phase-encoded 80-bit
 *     values, not counters);
 *   - whether a $10 sticker converts to a BNB amount a human would recognise.
 *
 * Every test below reads the real answer first and derives its expectation
 * from it, so this file does not hardcode a BNB price and does not go stale.
 */
contract ChainlinkFeedForkTest is ForkBase {
    Bulls internal bulls;
    MintDrop internal drop;
    Duel internal duel;

    /// @dev The dollar sticker for one fight. `DECISIONS.md §26` removed the
    ///      stablecoin that used to be the anchor, so this stored figure plus
    ///      the feed IS the anchor now.
    uint256 internal constant USD_FIGHT_PRICE = 5e18;

    function setUp() public override {
        super.setUp();

        bulls = new Bulls(owner, 0xB011, bytes32(0));

        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                // Any real ERC-20 will do for the ORACLE tests — the oracle
                // path never touches BNBULL. A real one is used rather than a
                // mock so nothing in this directory is our own code answering
                // our own questions.
                bnbull: A.BABYDOGE,
                wbnb: A.WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
           })
        );
        bulls.bootstrapWire(Bulls.Wire.MintDrop, address(drop));

        // THE wire under test: the real aggregator.
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, A.CHAINLINK_BNB_USD);
        drop.setPriceTiers(_launchTiers());

        duel = new Duel(
            Duel.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: A.BABYDOGE,
                wbnb: A.WBNB,
                trustedSigner: address(0x519E2),
                devTreasury: treasury,
                defaultDevShareBps: 1_000
           })
        );
        duel.bootstrapWire(Duel.Wire.MintDrop, address(drop));
        duel.addFightAsset(A.WBNB, 1 ether, 1_000);
        duel.setUsdFightPrice(USD_FIGHT_PRICE);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The feed itself
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The four properties `MintDrop.bnbUsdPrice` depends on, read off
     *         the live aggregator rather than assumed.
     *
     * @dev `feedDecimals` is cached at wiring time and every dollar→BNB
     *      conversion in the codebase divides by it. `BNB-CHAIN-FACTS.md`
     *      calls the decimals trap the reason an $80 listing rendered as
     *      $0.00 on Fefers. This is the one read that stops it recurring on
     *      the price feed.
     */
    function test_theLiveFeedHasTheShapeEveryConversionAssumes() public view {
        assertEq(bnbUsdFeed.decimals(), 8, "feed decimals moved");
        assertEq(drop.feedDecimals(), 8, "MintDrop cached the wrong feed decimals");

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            bnbUsdFeed.latestRoundData();

        assertGt(answer, 0, "non-positive answer");
        assertGt(updatedAt, 0, "zero timestamp");
        assertGe(answeredIn, roundId, "answeredInRound < roundId on the real proxy");
        assertGt(startedAt, 0, "zero startedAt");
        assertLe(updatedAt, block.timestamp, "feed answered from the future");

        console2.log("live BNB/USD (8dp):", uint256(answer));
        console2.log("answer age at the pin (s):", block.timestamp - updatedAt);
        console2.log("feed description:", bnbUsdFeed.description());
    }

    /**
     * @notice THE STALENESS-POLICY SANITY CHECK, measured not guessed.
     *
     * @dev Walks the real aggregator backwards through its recent rounds and
     *      reports the LARGEST observed gap between updates. `maxOracleAge`
     *      is 1 hour and `MAX_ORACLE_AGE` is 24; if the real feed's worst
     *      observed gap were anywhere near an hour, the policy would revert
     *      honest mints during ordinary quiet periods and someone would
     *      "fix" it by raising the age — which is how a staleness check
     *      quietly stops being one.
     *
     *      This is the number that says the policy is safe to ship. A mock
     *      cannot produce it.
     */
    function test_theRealHeartbeatIsFarInsideTheStalenessPolicy() public view {
        (uint80 latestRound,,, uint256 latestUpdated,) = bnbUsdFeed.latestRoundData();

        uint256 worstGap;
        uint256 sampled;
        uint256 next = latestUpdated;

        // 40 rounds back. The proxy's round ids are phase-encoded, so stepping
        // by 1 stays inside the current phase for a window this small.
        for (uint80 i = 1; i <= 40; i++) {
            try bnbUsdFeed.getRoundData(latestRound - i) returns (
                uint80, int256 a, uint256, uint256 u, uint80
            ) {
                if (u == 0 || a <= 0) break;
                if (next > u) {
                    uint256 gap = next - u;
                    if (gap > worstGap) worstGap = gap;
                }
                next = u;
                sampled++;
            } catch {
                break;
            }
        }

        assertGt(sampled, 10, "could not sample enough history to judge the heartbeat");
        console2.log("rounds sampled:", sampled);
        console2.log("worst observed update gap (s):", worstGap);
        console2.log("maxOracleAge (s):", drop.maxOracleAge());

        // A four-times margin. Anything tighter and ordinary jitter starts
        // reverting mints; anything looser and the check stops being one.
        assertLt(
            worstGap * 4,
            drop.maxOracleAge(),
            "maxOracleAge is not comfortably above the feed's real cadence"
        );
        assertLe(drop.maxOracleAge(), drop.MAX_ORACLE_AGE(), "policy above its own ceiling");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The conversion
    // ══════════════════════════════════════════════════════════════════════

    /// @notice `bnbUsdPrice()` is the live answer, rescaled 8dp → 18dp, and
    ///         nothing else. Derived from the live read, so it cannot go stale.
    function test_bnbUsdPriceIsTheLiveAnswerRescaledToEighteenDecimals() public view {
        (, int256 answer,,,) = bnbUsdFeed.latestRoundData();
        assertEq(drop.bnbUsdPrice(), uint256(answer) * 1e10, "rescale is wrong");

        // Plausibility, not precision: this catches a feed swap or a decimals
        // slip by three orders of magnitude, which is the failure that
        // actually happens.
        assertGt(drop.bnbUsdPrice(), 50e18, "BNB/USD below $50 - wrong feed?");
        assertLt(drop.bnbUsdPrice(), 10_000e18, "BNB/USD above $10,000 - wrong feed?");
    }

    /**
     * @notice A $10 mint priced through the real feed lands on a BNB amount
     *         that converts back to $10.
     *
     * @dev The round trip is the assertion, not a hardcoded BNB figure. It
     *      catches an inverted conversion (`usd * price` instead of
     *      `usd / price`), which at a $600 BNB is a 360,000× error and at a
     *      $1 BNB would look almost right — exactly the class of bug that
     *      survives a mock priced at a round number.
     */
    function test_aTenDollarMintConvertsToASaneBnbAmountAndBack() public view {
        (uint256 usdTotal, uint256 bnbDue,, uint256 price) = drop.quote(1);

        assertEq(usdTotal, 10e18, "launch ladder rung 1 is $10 (DECISIONS.md 12)");
        assertEq(price, drop.bnbUsdPrice(), "quote used a different price than the oracle");

        uint256 backToUsd = (bnbDue * price) / 1e18;
        // Ceil-division of a 1e18 quantity: at most 1 wei of BNB of rounding,
        // which is `price` wei of dollars.
        assertGe(backToUsd, usdTotal, "the drop is undercharging");
        assertLe(backToUsd - usdTotal, price / 1e18 + 1, "round trip drifted");

        console2.log("$10 mint costs (BNB wei):", bnbDue);
        _log("  ... at BNB/USD (1e18):", price);
    }

    /**
     * @notice `Duel.stickerCost(wbnb)` — the second oracle consumer, reached
     *         through a DIFFERENT contract, against the same live feed.
     *
     * @dev `Duel` has no feed wire of its own by design (its header: "a second
     *      feed wire here would mean a second, independently-drifting
     *      staleness policy"). This proves the delegation actually reaches the
     *      real aggregator rather than a stale cache, and that both contracts
     *      quote the same dollar in the same block.
     */
    function test_duelStickerCostConvertsTheDollarAnchorThroughTheSameLiveFeed() public view {
        uint256 price = drop.bnbUsdPrice();
        assertEq(duel.bnbUsdPrice(), price, "Duel and MintDrop disagree in the same block");

        uint256 sticker = duel.stickerCost(A.WBNB);
        assertGt(sticker, 0, "WBNB fight is unpriced");

        uint256 backToUsd = (sticker * price) / 1e18;
        assertGe(backToUsd, USD_FIGHT_PRICE, "fights are underpriced");
        assertLe(backToUsd - USD_FIGHT_PRICE, price / 1e18 + 1, "round trip drifted");

        // The one bound that survives to pay time on the oracle leg.
        assertLt(sticker, duel.maxFightCostOf(A.WBNB), "sticker above its permanent ceiling");

        console2.log("$5 fight costs (BNB wei):", sticker);
    }

    /// @notice `DECISIONS.md §2/§13`: the discount comes off the RESULT of the
    ///         conversion, never off the dollar anchor. Two-step conversion
    ///         makes the double-discount trap easy to fall into; the live feed
    ///         is where it would actually bite.
    function test_theDiscountIsAppliedAfterTheOracleConversionNotBefore() public {
        duel.setDiscountBps(A.WBNB, 1_000); // 10%
        uint256 sticker = duel.stickerCost(A.WBNB);
        assertEq(duel.fighterCost(A.WBNB), (sticker * 9_000) / 10_000, "double discount");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The policy: REVERT, never clamp
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE HEADLINE ORACLE TEST. Warp real time past the real
     *         answer's real age and prove every consumer REVERTS rather than
     *         clamping.
     *
     * @dev `DECISIONS.md §1`: *"handle stale … and non-positive answers —
     *      revert, don't clamp silently."* A clamped price is a wrong price
     *      presented as a right one. On the fork this is not a mock returning
     *      an old timestamp on request: it is the genuine last answer the
     *      genuine aggregator produced, aging naturally, with nothing in the
     *      contract able to tell the difference between this and a real
     *      Chainlink outage.
     */
    function test_pastTheHeartbeatEveryPricedPathRevertsAndNothingIsClamped() public {
        (,,, uint256 updatedAt,) = bnbUsdFeed.latestRoundData();
        uint256 maxAge = drop.maxOracleAge();

        // One second inside the policy: everything still prices.
        vm.warp(updatedAt + maxAge);
        uint256 healthy = drop.bnbUsdPrice();
        assertGt(healthy, 0);

        // One second outside: nothing prices, and no number is invented.
        vm.warp(updatedAt + maxAge + 1);

        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleStale.selector, updatedAt, maxAge));
        drop.bnbUsdPrice();

        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleStale.selector, updatedAt, maxAge));
        drop.quote(1);

        // The fight leg, through Duel's delegation.
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleStale.selector, updatedAt, maxAge));
        duel.stickerCost(A.WBNB);

        // And, most importantly, the PAYING path. A stale feed must not sell a
        // bull at a price nobody chose.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleStale.selector, updatedAt, maxAge));
        drop.mintWithBNB{ value: 1 ether }(alice, 1);

        assertEq(bulls.nextTokenId(), 1, "a bull was minted against a stale feed");
    }

    /// @notice The staleness window is measured from the ANSWER, not from the
    ///         wiring or from any cached value. Warping far past it keeps it
    ///         shut — there is no self-healing.
    function test_stalenessDoesNotSelfHealAsTimePasses() public {
        (,,, uint256 updatedAt,) = bnbUsdFeed.latestRoundData();
        vm.warp(updatedAt + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.OracleStale.selector, updatedAt, drop.maxOracleAge())
        );
        drop.bnbUsdPrice();
    }

    /**
     * @notice The sanity band bites the real answer when the band is wrong,
     *         and only then.
     *
     * @dev Both bounds are derived from the live price, so this test states a
     *      property ("a band that excludes the truth refuses to quote")
     *      rather than a number that rots.
     */
    function test_theSanityBandRefusesAPriceOutsideItRatherThanClampingToIt() public {
        uint256 live = drop.bnbUsdPrice();

        drop.setOraclePolicy(drop.maxOracleAge(), live + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleOutOfBand.selector, live));
        drop.bnbUsdPrice();

        drop.setOraclePolicy(drop.maxOracleAge(), 0, live - 1);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleOutOfBand.selector, live));
        drop.bnbUsdPrice();

        // A band that contains the truth is transparent.
        drop.setOraclePolicy(drop.maxOracleAge(), live / 2, live * 2);
        assertEq(drop.bnbUsdPrice(), live);
    }

    /**
     * @notice The aggregator behind the proxy is where a real Chainlink
     *         failure shows up. Force the REAL proxy to hand back a negative
     *         answer and prove the contract refuses it.
     *
     * @dev `vm.mockCall` on the live proxy is the only way to reach this
     *      branch: the real feed has never returned a negative BNB price, and
     *      hopefully never will. The point of doing it HERE rather than in the
     *      mock suite is that everything else in the transaction — the proxy's
     *      real code path, the cached `feedDecimals`, the real consumer — is
     *      genuine, so this proves the guard sits where the real data enters.
     */
    function test_aNegativeAnswerFromTheRealProxyIsRefused() public {
        (uint80 r,, uint256 s, uint256 u, uint80 ar) = bnbUsdFeed.latestRoundData();
        vm.mockCall(
            A.CHAINLINK_BNB_USD,
            abi.encodeWithSelector(IAggregatorV3Fork.latestRoundData.selector),
            abi.encode(r, int256(-1), s, u, ar)
        );
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleBadAnswer.selector, int256(-1)));
        drop.bnbUsdPrice();
    }

    /// @notice An incomplete round (`answeredInRound < roundId`) is refused —
    ///         the classic Chainlink integration bug, checked against the real
    ///         proxy's real phase-encoded round ids.
    function test_anIncompleteRoundFromTheRealProxyIsRefused() public {
        (uint80 r, int256 a, uint256 s, uint256 u,) = bnbUsdFeed.latestRoundData();
        vm.mockCall(
            A.CHAINLINK_BNB_USD,
            abi.encodeWithSelector(IAggregatorV3Fork.latestRoundData.selector),
            abi.encode(r, a, s, u, r - 1)
        );
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleBadRound.selector, r, r - 1, u));
        drop.bnbUsdPrice();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev `DECISIONS.md §12`, the launch ladder. Copied in shape, not
    ///      imported, because `test/Base.t.sol` is not ours to touch.
    function _launchTiers() internal view returns (MintDrop.PriceTier[] memory t) {
        // READ, never assumed — the whole decimals discipline in one line.
        // The BNBULL column is derived from the token's own `decimals()`, so
        // the table is correct at 18dp, at 9dp, or at whatever four.meme
        // actually issues.
        uint256 unit = 10 ** IERC20Fork(A.BABYDOGE).decimals();
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({upToSold: 100, usdPrice: 10e18, bnbullPrice: uint128(1_000 * unit)});
        t[1] = MintDrop.PriceTier({upToSold: 200, usdPrice: 20e18, bnbullPrice: uint128(2_000 * unit)});
        t[2] = MintDrop.PriceTier({upToSold: 300, usdPrice: 35e18, bnbullPrice: uint128(3_500 * unit)});
        t[3] = MintDrop.PriceTier({upToSold: 400, usdPrice: 50e18, bnbullPrice: uint128(5_000 * unit)});
        t[4] = MintDrop.PriceTier({upToSold: 500, usdPrice: 75e18, bnbullPrice: uint128(7_500 * unit)});
    }
}
