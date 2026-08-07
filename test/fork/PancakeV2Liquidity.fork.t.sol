// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {IERC20Fork} from "./ForkInterfaces.sol";

import {Bulls} from "../../contracts/Bulls.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";

/**
 * @title PancakeV2LiquidityForkTest
 * @notice `MintDrop`'s BNBULL buy leg, driven against a REAL PancakeSwap v2
 *         pool holding REAL liquidity.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHY THE STAND-IN IS CAKE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * `DECISIONS.md §29`: BNBULL does not exist on mainnet, and could not be
 * transferred if it did. So the "BNBULL" in these tests is **CAKE**, chosen
 * because it is the one thing four.meme cannot give us on demand: a deep,
 * untaxed, 18-decimal WBNB book (11,926 WBNB at the pin) whose price impact
 * is genuine constant-product arithmetic rather than a mock's fixed rate.
 *
 * `FourMeme.fork.t.sol` covers the token that BNBULL will actually be;
 * `FeeOnTransfer.fork.t.sol` covers what a taxed one does to this same leg.
 * This file isolates the swap machinery from both.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHAT A MOCK ROUTER CANNOT SHOW
 * ══════════════════════════════════════════════════════════════════════════
 *
 *  - `MockRouter.setRate()` is linear: 1 BNB and 100 BNB get the same price.
 *    A real pool's marginal price MOVES, which is the only reason `minOut`
 *    and a liquidity floor exist at all.
 *  - A mock's `getAmountsOut` and its actual payout are the same number by
 *    construction, so "book the measured delta, never the router's word"
 *    cannot fail in the mock suite whether it is implemented or not.
 *  - A mock pair has whatever reserves a test gave it. Only a real book can
 *    tell us whether `minPoolLiquidity = 1 ether` is a floor that real
 *    liquidity clears.
 */
contract PancakeV2LiquidityForkTest is ForkBase {
    /// @dev The BNBULL stand-in. See the header.
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    Bulls internal bulls;
    Jackpot internal potBnbull;
    Jackpot internal potBnb;
    MintDrop internal drop;

    function setUp() public override {
        super.setUp();
        vm.label(CAKE, "CAKE(BNBULL stand-in)");

        bulls = new Bulls(owner, 0xB011, bytes32(0));
        potBnbull = new Jackpot(CAKE, address(0), A.VRF_COORDINATOR_V2_5, 50);
        potBnb = new Jackpot(A.WBNB, address(0), A.VRF_COORDINATOR_V2_5, 100);

        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: CAKE,
                wbnb: A.WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
           })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        drop.unpause();

        bulls.bootstrapWire(Bulls.Wire.MintDrop, address(drop));
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, A.CHAINLINK_BNB_USD);
        drop.bootstrapWire(MintDrop.Wire.Router, A.PANCAKE_V2_ROUTER);
        drop.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);
        drop.setKeeper(keeper);
        drop.setPriceTiers(_launchTiers());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The book itself
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The wired router agrees with the wired factory about which pair
     *         the swap will hit.
     *
     * @dev `MintDrop`'s header: *"`factory()` IS THE ONLY SOURCE OF THE PAIR.
     *      Never a second wire — a separate factory address could point at a
     *      different book than the one the swap hits, which is
     *      `BNB-CHAIN-FACTS.md §3` all over again."* This asserts that the
     *      real router's real factory answers the real pair, so the reserve
     *      the floor measures IS the book the swap trades in.
     */
    function test_theLiquidityFloorMeasuresTheSamePairTheSwapWillHit() public view {
        (address pair, uint256 reserve) = drop.wbnbPoolLiquidity();
        assertEq(pair, v2Factory.getPair(A.WBNB, CAKE), "floor is reading a different pair");
        assertEq(reserve, _pairWbnbReserve(pair), "floor read a different reserve");
        assertGt(reserve, drop.minPoolLiquidity(), "real book is below our own floor");
        console2.log("real WBNB reserve (wei):", reserve);
        console2.log("minPoolLiquidity (wei):", drop.minPoolLiquidity());
    }

    /**
     * @notice ⚠ PRICE IMPACT IS REAL. 100 BNB buys materially less per BNB
     *         than 1 BNB does, on the same pool, in the same block.
     *
     * @dev This is the property `MockRouter` structurally cannot have — its
     *      rate is a stored ratio, so it quotes the same price for any size.
     *      Everything downstream (`inlineSlippageBps`, keeper-pegged `minOut`,
     *      `minPoolLiquidity`) exists BECAUSE this number moves. If it did not
     *      move, none of those mechanisms would be needed and the whole decoy
     *      class of bug would be impossible.
     */
    function test_theRealBookMovesWithSizeWhichIsWhyEveryFloorExists() public view {
        address[] memory path = _pathWbnbTo(CAKE);
        uint256 small = v2Router.getAmountsOut(1 ether, path)[1];
        uint256 large = v2Router.getAmountsOut(100 ether, path)[1];

        uint256 perBnbSmall = small;
        uint256 perBnbLarge = large / 100;

        assertLt(perBnbLarge, perBnbSmall, "the book did not move - is this really a real pool?");
        console2.log("CAKE per BNB at 1 BNB   :", perBnbSmall);
        console2.log("CAKE per BNB at 100 BNB :", perBnbLarge);
        console2.log("impact (bps):", ((perBnbSmall - perBnbLarge) * 10_000) / perBnbSmall);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The buy leg, end to end
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A real BNB mint funds BOTH pots off a REAL pool, and the BNBULL
     *         pot is credited the MEASURED delta.
     *
     * @dev The swap call `MintDrop` makes is
     *      `swapExactETHForTokensSupportingFeeOnTransferTokens`, which returns
     *      **nothing at all** — there is no router-reported number to trust
     *      even if someone wanted to. The assertion below is therefore the
     *      strongest available form of "booked on a measured balance delta":
     *      the pot's real token balance, read off the real ERC-20, equals what
     *      the pot was told it received.
     */
    function test_aRealMintFundsBothPotsThroughTheRealRouter() public {
        (, uint256 bnbDue,,) = drop.quote(1);

        uint256 treasuryBefore = treasury.balance;

        vm.deal(alice, bnbDue * 2);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue * 2 }(alice, 1);

        // 20% BNBULL leg: a real swap happened.
        uint256 potBnbullBal = IERC20Fork(CAKE).balanceOf(address(potBnbull));
        assertGt(potBnbullBal, 0, "the BNBULL pot was not funded by a real swap");
        assertEq(potBnbull.pool(), potBnbullBal, "pot accounting != real ERC-20 balance");
        assertEq(drop.pendingBnbullBuyNative(), 0, "the leg deferred against a deep real pool");

        // 10% BNB leg: a WRAP against the real WBNB contract, exactly 1:1.
        uint256 potBnbBal = IERC20Fork(A.WBNB).balanceOf(address(potBnb));
        assertEq(potBnbBal, (bnbDue * 1_000) / 10_000, "the WBNB wrap is not 1:1");
        assertEq(potBnb.pool(), potBnbBal, "pot accounting != real WBNB balance");

        // 70% dev, and the overpayment came back.
        assertEq(treasury.balance - treasuryBefore, bnbDue - (bnbDue * 3_000) / 10_000, "dev cut");
        assertEq(alice.balance, bnbDue, "overpayment was not refunded");

        // Nothing stranded in the drop.
        assertEq(address(drop).balance, 0, "BNB stranded in MintDrop");
        assertEq(IERC20Fork(CAKE).balanceOf(address(drop)), 0, "CAKE stranded in MintDrop");

        console2.log("mint cost (BNB wei):", bnbDue);
        console2.log("BNBULL pot credited (token wei):", potBnbullBal);
        console2.log("WBNB pot credited (wei):", potBnbBal);
    }

    /**
     * @notice The credited amount is the delta the pool actually paid, and it
     *         sits inside the slippage band the router quoted a moment before.
     *
     * @dev The quote is taken in the same block from the same pool, so on an
     *      untaxed token the delta lands between `quote * (1 - slippage)` and
     *      `quote` itself. Below the band would mean the floor is not being
     *      enforced; ABOVE the quote would mean we booked a number the pool
     *      never paid.
     */
    function test_theBookedAmountIsBoundedByTheRealQuoteOnBothSides() public {
        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 legIn = (bnbDue * 2_000) / 10_000;
        uint256 quoted = v2Router.getAmountsOut(legIn, _pathWbnbTo(CAKE))[1];

        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        uint256 credited = IERC20Fork(CAKE).balanceOf(address(potBnbull));
        uint256 floor_ = (quoted * (10_000 - drop.inlineSlippageBps())) / 10_000;

        assertGe(credited, floor_, "credited below the floor the code claims to enforce");
        assertLe(credited, quoted, "credited MORE than the pool could possibly have paid");
        console2.log("router quote:", quoted);
        console2.log("measured delta:", credited);
    }

    /// @notice `minOut == 0` is refused outright on the keeper sweep path
    ///         against the real router. A blind swap hands the slice to
    ///         whoever is watching the mempool.
    function test_aBlindSweepIsRefusedAgainstTheRealRouter() public {
        // Force an accrual by un-wiring the pot, then re-wire and sweep.
        _accrueBnbullLeg();

        vm.prank(keeper);
        vm.expectRevert(MintDrop.BlindSwapRefused.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 0);
    }

    /**
     * @notice The deferred sweep works against the real pool with an
     *         off-chain-quoted floor — and REFUSES a floor the real pool
     *         cannot meet.
     *
     * @dev This is the keeper's actual job in production. The second half
     *      matters more than the first: a floor quoted a minute ago against a
     *      book that has since moved must fail the sweep, not silently take a
     *      worse fill.
     */
    function test_theKeeperSweepClearsAnHonestFloorAndRefusesAnImpossibleOne() public {
        uint256 pending = _accrueBnbullLeg();
        assertGt(pending, 0, "nothing accrued");

        uint256 honest = v2Router.getAmountsOut(pending, _pathWbnbTo(CAKE))[1];

        // Impossible floor: 1% better than the pool can pay.
        vm.prank(keeper);
        vm.expectRevert();
        drop.sweepBnbullPot(MintDrop.PotSource.Native, pending, (honest * 101) / 100);

        assertEq(drop.pendingBnbullBuyNative(), pending, "a failed sweep consumed the accrual");

        // Honest floor: 1% of slack.
        vm.prank(keeper);
        uint256 funded =
            drop.sweepBnbullPot(MintDrop.PotSource.Native, pending, (honest * 99) / 100);

        assertGe(funded, (honest * 99) / 100);
        assertEq(drop.pendingBnbullBuyNative(), 0, "accrual not cleared");
        assertEq(IERC20Fork(CAKE).balanceOf(address(potBnbull)), funded, "pot != measured delta");
    }

    /**
     * @notice ⚠ NEVER-FAIL, against real infrastructure. A mint still
     *         succeeds when the buy leg cannot run, and the money accrues
     *         rather than vanishing.
     *
     * @dev `BNBULLS-BOOTSTRAP §6`. On the fork the failure is manufactured by
     *      un-wiring the router, which is exactly the state the contracts ship
     *      in during `DECISIONS.md §29`'s BNB-only phase 1: BNBULL has no pool
     *      because the curve has not completed.
     */
    function test_theMintSurvivesAnUnroutableBuyLegAndTheMoneyAccrues() public {
        (MintDrop fresh, Bulls freshBulls) = _freshDropWithoutRouter();

        (, uint256 bnbDue,,) = fresh.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        fresh.mintWithBNB{ value: bnbDue }(alice, 1);

        assertEq(freshBulls.ownerOf(1), alice, "the mint failed because a buyback could not run");
        assertEq(
            fresh.pendingBnbullBuyNative(),
            (bnbDue * 2_000) / 10_000,
            "the BNBULL slice did not accrue"
        );
        assertEq(address(fresh).balance, (bnbDue * 2_000) / 10_000, "accrual is not backed by BNB");
    }

    /**
     * @notice ⚠ THE STABLE-ISM THAT HAD TO DIE. On Stable a contract holding
     *         native could approve a router directly, because native WAS the
     *         ERC-20. On BNB it cannot: EVERY leg goes through WBNB.
     *
     * @dev Proven by the real WBNB contract's own `totalSupply`. One mint
     *      mints exactly 30% of the payment as new WBNB — 10% for the pot
     *      leg's WRAP (1:1, no router, no liquidity dependency) and 20% for
     *      the buy leg, which the router wraps on its way into the pair.
     *      Neither number is visible in the mock suite: `MockWBNB` is not the
     *      thing the router uses.
     */
    function test_everyLegReachesThePoolThroughRealWbnbNotNativeBnb() public {
        uint256 supplyBefore = IERC20Fork(A.WBNB).totalSupply();

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        uint256 wrapLeg = (bnbDue * 1_000) / 10_000;
        uint256 buyLeg = (bnbDue * 2_000) / 10_000;

        // The pot's own leg: an exact 1:1 wrap, measured.
        assertEq(IERC20Fork(A.WBNB).balanceOf(address(potBnb)), wrapLeg, "wrap is not 1:1");

        // And the proof that the buy leg is a WBNB route, not a native one.
        assertEq(
            IERC20Fork(A.WBNB).totalSupply() - supplyBefore,
            wrapLeg + buyLeg,
            "real WBNB supply did not move by wrap + buy"
        );
        console2.log("new WBNB minted by one mint (wei):", wrapLeg + buyLeg);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev Drive one mint with the BNBULL pot un-wired so its slice accrues,
    ///      then re-wire it so a sweep can be tested.
    function _accrueBnbullLeg() internal returns (uint256 pending) {
        // Pointing the pot slot at zero is impossible once set
        // (`TimelockedAddress` refuses it), so the failure is manufactured by
        // removing the funder permission instead: `fund` reverts, the inline
        // leg reverts, the slice accrues. Which is itself worth noticing — the
        // wiring cannot be un-set, only re-pointed through the timelock.
        potBnbull.setFunder(address(drop), false);

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        potBnbull.setFunder(address(drop), true);
        pending = drop.pendingBnbullBuyNative();
    }

    /// @dev A second collection is deployed alongside because `Bulls.Wire`
    ///      slots are one-shot bootstraps — which is itself the right shape,
    ///      and worth noticing: the minter cannot be swapped out casually.
    function _freshDropWithoutRouter() internal returns (MintDrop d, Bulls b) {
        b = new Bulls(owner, 0xB011, bytes32(0));
        d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(b),
                bnbull: CAKE,
                wbnb: A.WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
           })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        d.unpause();
        d.bootstrapWire(MintDrop.Wire.PriceFeed, A.CHAINLINK_BNB_USD);
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(d), true);
        potBnb.setFunder(address(d), true);
        d.setPriceTiers(_launchTiers());
        b.bootstrapWire(Bulls.Wire.MintDrop, address(d));
    }

    function _launchTiers() internal pure returns (MintDrop.PriceTier[] memory t) {
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({upToSold: 100, usdPrice: 10e18, bnbullPrice: 1_000e18});
        t[1] = MintDrop.PriceTier({upToSold: 200, usdPrice: 20e18, bnbullPrice: 2_000e18});
        t[2] = MintDrop.PriceTier({upToSold: 300, usdPrice: 35e18, bnbullPrice: 3_500e18});
        t[3] = MintDrop.PriceTier({upToSold: 400, usdPrice: 50e18, bnbullPrice: 5_000e18});
        t[4] = MintDrop.PriceTier({upToSold: 500, usdPrice: 75e18, bnbullPrice: 7_500e18});
    }
}
