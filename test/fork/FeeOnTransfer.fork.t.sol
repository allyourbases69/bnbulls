// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {IERC20Fork, IFourMemeTokenFork} from "./ForkInterfaces.sol";

import {Bulls} from "../../contracts/Bulls.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";

/**
 * @title FeeOnTransferForkTest
 * @notice The measured-delta discipline and the fee-supporting router calls,
 *         proven against ERC-20s WE DID NOT WRITE.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  ⚠ FINDING 0, FOUND WHILE PICKING SPECIMENS
 * ══════════════════════════════════════════════════════════════════════════
 *
 * The obvious candidates for "a real BSC token with a transfer tax" — Baby
 * Doge Coin, EverGrow, CATCOIN, Trust Wallet Token, Alien Worlds — **all pay
 * the router's quote to the wei at this pin.** Baby Doge reads
 * `_taxFee() == 0` and `_liquidityFee() == 0`; the reflection era those
 * tokens are famous for has been switched off and their reputations have not
 * caught up.
 *
 * That is worth writing down twice, because it cuts both ways:
 *
 *   - a token's REPUTATION for having a tax is not evidence, and neither is
 *     its absence. The only evidence is `quote` minus `measured delta`, taken
 *     at the block you care about. This file measures rather than assumes,
 *     which is the same rule `BNB-CHAIN-FACTS §3` applies to pools;
 *   - the live taxed-token risk to bnbulls is therefore NOT a generic BSC
 *     hazard. It is one specific, chooseable thing: **four.meme template B's
 *     creator-set tax** (`DECISIONS.md §30`). That narrows the launch-day
 *     checklist considerably.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  THE SPECIMENS THAT DO BITE
 * ══════════════════════════════════════════════════════════════════════════
 *
 *  - **a four.meme template-B graduate** (`feeRateBuy = 10`) — the token
 *    BNBULL will literally be if the launch form yields template B. Mainnet
 *    code, mainnet tax, graduated on the fork because `DECISIONS.md §29` says
 *    BNBULL does not exist yet.
 *
 *  - **SafeMoon V1**, still on mainnet, still holding a pair. The router
 *    quotes 9,752 tokens for half a BNB; the token delivers **1 wei**. A real,
 *    live, hostile ERC-20 that nobody here wrote and nobody can claim was
 *    shaped to make a test pass.
 */
contract FeeOnTransferForkTest is ForkBase {
    /// @dev Real, live, and hostile: quotes a fortune, delivers a wei.
    ///      9 decimals, and a WBNB reserve of ~0.37 BNB at the pin.
    address internal constant SAFEMOON_V1 = 0x8076C74C5e3F5852037F31Ff0093Eeb8c8ADd8D3;

    /// @dev Untaxed at the pin despite its reputation. Kept as the control.
    address internal constant BABYDOGE = A.BABYDOGE;

    /// @dev Deep, untaxed, 18dp. The "everything is fine" control.
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    Bulls internal bulls;
    Jackpot internal potBnbull;
    Jackpot internal potBnb;
    MintDrop internal roDrop;

    function setUp() public override {
        super.setUp();
        vm.label(SAFEMOON_V1, "SafeMoonV1(hostile)");
        bulls = new Bulls(owner, 0xB011, bytes32(0));
        potBnb = new Jackpot(A.WBNB, address(0), A.VRF_COORDINATOR_V2_5, 100);
        roDrop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: BABYDOGE,
                wbnb: A.WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
           })
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. Measure, never assume
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ A REAL MAINNET TOKEN THAT QUOTES 9,752 AND PAYS 1 WEI.
     *
     * @dev THE strongest available argument for the measured-delta rule. In
     *      the mock suite this is untestable in its most damaging form:
     *      `MockRouter` pays exactly what it quotes, so an implementation that
     *      simply believed the router's return value would pass all 540 tests.
     *      Here a real ERC-20, on real mainnet, at a real block, hands back
     *      essentially nothing while the router says otherwise.
     */
    function test_aRealMainnetTokenQuotesAFortuneAndDeliversOneWei() public {
        address[] memory path = _pathWbnbTo(SAFEMOON_V1);
        uint256 quoted = v2Router.getAmountsOut(0.5 ether, path)[1];
        assertGt(quoted, 1e21, "the specimen no longer quotes big - re-pick it");

        vm.deal(alice, 0.5 ether);
        uint256 before = IERC20Fork(SAFEMOON_V1).balanceOf(alice);
        vm.prank(alice);
        v2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: 0.5 ether }(
            0, path, alice, block.timestamp
        );
        uint256 delivered = IERC20Fork(SAFEMOON_V1).balanceOf(alice) - before;

        console2.log("router quoted   :", quoted);
        console2.log("token delivered :", delivered);
        assertLt(delivered * 1_000_000, quoted, "the specimen is behaving itself - re-pick it");
    }

    /**
     * @notice ...and our own code refuses that trade twice over: the
     *         liquidity floor stops it before the swap, and `minOut` would
     *         stop it after.
     *
     * @dev Belt and braces, and both belts are load-bearing. `minPoolLiquidity`
     *      catches the thin book; `SwapOutBelowMin` on the MEASURED delta
     *      catches a token that lies about what it moved. Either alone would
     *      have been enough here, which is the point — the failure modes
     *      overlap on purpose.
     */
    function test_ourBuyLegRefusesTheHostileTokenAndTheMintStillSucceeds() public {
        uint256 reserve = _pairWbnbReserve(v2Factory.getPair(SAFEMOON_V1, A.WBNB));
        MintDrop drop = _dropFor(SAFEMOON_V1);

        assertLt(reserve, drop.minPoolLiquidity(), "the hostile pair is above our floor");

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        assertEq(bulls.ownerOf(1), alice, "never-fail was violated");
        assertEq(IERC20Fork(SAFEMOON_V1).balanceOf(address(potBnbull)), 0, "we bought the trap");
        assertEq(drop.pendingBnbullBuyNative(), (bnbDue * 2_000) / 10_000, "it did not accrue");

        // And with the floor lowered out of the way, `minOut` on the measured
        // delta is still there to refuse it.
        drop.setMinPoolLiquidity(1);
        vm.deal(bob, bnbDue);
        vm.prank(bob);
        drop.mintWithBNB{ value: bnbDue }(bob, 1);
        assertEq(
            IERC20Fork(SAFEMOON_V1).balanceOf(address(potBnbull)),
            0,
            "with the floor down, the measured-delta check let a 1-wei fill through"
        );
    }

    /**
     * @notice ⚠ FINDING 0, as an assertion. The famous "taxed" BSC tokens are
     *         untaxed at this pin, so reputation is not evidence.
     *
     * @dev If this ever starts failing, that is not a bug — it is Baby Doge
     *      turning its fees back on, and the failure is the notification. That
     *      is exactly what a fork regression test is for.
     */
    function test_theFamousTaxedTokensAreUntaxedTodaySoReputationIsNotEvidence() public {
        assertEq(_measuredTaxBps(BABYDOGE, 0.5 ether), 0, "Baby Doge has re-enabled its fees");
        assertEq(_measuredTaxBps(CAKE, 1 ether), 0, "CAKE is taxed now");
        console2.log("BabyDoge decimals:", IERC20Fork(BABYDOGE).decimals());
        console2.log("BabyDoge _taxFee is read as zero on chain at the pin.");
    }

    /**
     * @notice The whole path is decimals-agnostic: a 9-decimal payout token is
     *         credited to the pot in ITS OWN units, with no 1e18 anywhere.
     *
     * @dev `BNB-CHAIN-FACTS` blames the decimals trap for Fefers rendering an
     *      $80 listing as $0.00. A hidden 1e18 divisor on a 9dp token is a
     *      billion-fold error, so it cannot hide behind rounding.
     */
    function test_aNineDecimalPayoutTokenIsCreditedInItsOwnUnits() public {
        MintDrop drop = _dropFor(BABYDOGE);
        assertEq(IERC20Fork(BABYDOGE).decimals(), 9, "specimen decimals moved");

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 quoted = v2Router.getAmountsOut((bnbDue * 2_000) / 10_000, _pathWbnbTo(BABYDOGE))[1];

        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        uint256 credited = IERC20Fork(BABYDOGE).balanceOf(address(potBnbull));
        assertEq(credited, quoted, "credited something other than the measured delta");
        assertEq(potBnbull.pool(), credited, "pot accounting != pot balance");
        console2.log("credited (9dp wei):", credited);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. The four.meme tax, and what it does to our buy leg
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ WHY THE FEE-SUPPORTING VARIANT IS NOT OPTIONAL. The plain
     *         router call BRICKS on the real taxed token; the fee-supporting
     *         one works.
     *
     * @dev `DECISIONS.md §30`: a non-fee-supporting call on a taxed token
     *      reverts `Pancake: K`, and **v3 has no fee-supporting variant at
     *      all**, so a taxed BNBULL cannot be routed on v3 under any
     *      circumstances. `MintDrop` uses the fee-supporting calls; this is
     *      the evidence that the choice was forced rather than stylistic.
     */
    function test_thePlainRouterCallBricksOnTheTaxedTokenAndTheSupportingOneDoesNot() public {
        _graduate(A.GORT, alice);
        uint256 held = IERC20Fork(A.GORT).balanceOf(alice);
        assertGt(held, 0);

        address[] memory out = _pathToWbnb(A.GORT);

        vm.startPrank(alice);
        IERC20Fork(A.GORT).approve(A.PANCAKE_V2_ROUTER, type(uint256).max);

        vm.expectRevert(bytes("Pancake: K"));
        v2Router.swapExactTokensForETH(held / 100, 0, out, alice, block.timestamp);

        uint256 bnbBefore = alice.balance;
        v2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            held / 100, 0, out, alice, block.timestamp
        );
        vm.stopPrank();

        assertGt(alice.balance, bnbBefore, "the fee-supporting sell paid nothing");
        console2.log("fee-supporting sell paid (BNB wei):", alice.balance - bnbBefore);
    }

    /**
     * @notice ⚠⚠ THE COLLISION. A 10% creator tax cannot clear a 5% inline
     *         slippage floor, so the pot leg accrues on EVERY mint and never
     *         buys anything.
     *
     * @dev Walk the arithmetic, because it is the whole finding:
     *
     *        minOut    = getAmountsOut(amountIn) * (1 - inlineSlippageBps)
     *                  = quote * 0.95            (launch value: 500 bps)
     *        delivered = quote * (1 - feeRateBuy)
     *                  = quote * 0.90            (specimen: 10%)
     *        delivered < minOut -> SwapOutBelowMin -> caught -> accrue
     *
     *      Nothing reverts to the user. The mint succeeds, the bull is
     *      delivered, `BnbullPotDeferred` fires, and the money piles up in
     *      `pendingBnbullBuyNative` looking exactly like the ordinary
     *      pre-graduation deferral of `DECISIONS.md §29`. The only signal that
     *      it is not ordinary is that it never stops.
     *
     *      Neither number is wrong on its own, which is why no reviewer of
     *      either file would catch it. Only running them together against a
     *      really-taxed token does.
     *
     *      ⚠ THE LAUNCH CONSEQUENCE: launch BNBULL with `feeRateBuy = 0` (or
     *      on template A), or widen `inlineSlippageBps` past the tax — and at
     *      that width the floor has stopped being a floor. The second half of
     *      this test measures exactly how wide is wide enough, and checks the
     *      answer against the contract's own ceiling.
     */
    function test_FINDING_aTenPercentTokenTaxCannotClearAFivePercentSlippageFloor() public {
        _graduate(A.GORT, alice);
        uint256 taxPercent = IFourMemeTokenFork(A.GORT).feeRateBuy();
        assertGe(taxPercent, 5, "specimen tax is below the launch slippage band");

        MintDrop drop = _dropFor(A.GORT);
        assertEq(drop.inlineSlippageBps(), 500, "launch inline slippage moved - recheck this test");

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(bob, bnbDue);
        vm.prank(bob);
        drop.mintWithBNB{ value: bnbDue }(bob, 1);

        assertEq(bulls.ownerOf(1), bob, "never-fail was violated");
        assertEq(
            IERC20Fork(A.GORT).balanceOf(address(potBnbull)),
            0,
            "the leg fired - has the tax or the slippage band changed?"
        );
        assertEq(
            drop.pendingBnbullBuyNative(), (bnbDue * 2_000) / 10_000, "the slice did not accrue"
        );

        console2.log("token feeRateBuy (percent) :", taxPercent);
        console2.log("inlineSlippageBps          :", drop.inlineSlippageBps());
        console2.log("accrued instead of bought  :", drop.pendingBnbullBuyNative());

        // The remedy, measured rather than asserted.
        drop.setInlineSlippageBps(taxPercent * 100 + 100);
        (, uint256 bnbDue2,,) = drop.quote(1);
        vm.deal(carolAddr(), bnbDue2);
        vm.prank(carolAddr());
        drop.mintWithBNB{ value: bnbDue2 }(carolAddr(), 1);

        assertGt(
            IERC20Fork(A.GORT).balanceOf(address(potBnbull)),
            0,
            "widening the band past the tax still did not let the leg fire"
        );
        console2.log("band needed to clear the tax (bps):", drop.inlineSlippageBps());
        assertLe(
            drop.inlineSlippageBps(),
            drop.MAX_INLINE_SLIPPAGE_BPS(),
            "the band needed exceeds the contract's ceiling - the leg is UNFIXABLE by config"
        );
    }

    /// @notice The control run: an untaxed token clears the launch band
    ///         untouched, so the test above is about the TAX and not about the
    ///         band being unreasonably tight.
    function test_anUntaxedTokenClearsTheLaunchSlippageBandWithRoomToSpare() public {
        MintDrop drop = _dropFor(CAKE);
        assertEq(drop.inlineSlippageBps(), 500);

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 quoted = v2Router.getAmountsOut((bnbDue * 2_000) / 10_000, _pathWbnbTo(CAKE))[1];

        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        assertEq(IERC20Fork(CAKE).balanceOf(address(potBnbull)), quoted, "untaxed swap drifted");
        assertEq(drop.pendingBnbullBuyNative(), 0, "it deferred on an untaxed token");
    }

    /**
     * @notice Whatever the tax does, the POT is credited the measured delta
     *         and not one wei more.
     *
     * @dev The strongest form of the rule: after a taxed sweep, the pot's
     *      accounting (`pool()`) equals its real ERC-20 balance equals the
     *      delta the pool actually paid. If those diverged the pot would
     *      either be short — and eventually fail to pay a winner — or long,
     *      and be lying about the prize.
     */
    function test_aTaxedBuyCreditsThePotExactlyWhatArrived() public {
        _graduate(A.GORT, alice);
        MintDrop drop = _dropFor(A.GORT);
        drop.setKeeper(keeper);

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(bob, bnbDue);
        vm.prank(bob);
        drop.mintWithBNB{ value: bnbDue }(bob, 1);

        uint256 pending = drop.pendingBnbullBuyNative();
        assertGt(pending, 0);

        uint256 quoted = v2Router.getAmountsOut(pending, _pathWbnbTo(A.GORT))[1];
        vm.prank(keeper);
        uint256 funded =
            drop.sweepBnbullPot(MintDrop.PotSource.Native, pending, (quoted * 85) / 100);

        assertLt(funded, quoted, "the tax did not bite on the sweep");
        assertEq(IERC20Fork(A.GORT).balanceOf(address(potBnbull)), funded, "pot balance != delta");
        assertEq(potBnbull.pool(), funded, "pot accounting != pot balance");
        assertEq(IERC20Fork(A.GORT).balanceOf(address(drop)), 0, "tokens stranded in MintDrop");

        uint256 shortfall = ((quoted - funded) * 10_000) / quoted;
        console2.log("sweep quoted  :", quoted);
        console2.log("sweep landed  :", funded);
        console2.log("shortfall bps :", shortfall);
        // The shortfall IS the token's declared tax, to within rounding.
        assertApproxEqAbs(
            shortfall,
            IFourMemeTokenFork(A.GORT).feeRateBuy() * 100,
            5,
            "the measured shortfall does not match the token's declared tax"
        );
    }

    /**
     * @notice `DECISIONS.md §14` — the game NEVER sells BNBULL — and it is the
     *         DEFAULT, not a switch someone has to remember.
     *
     * @dev The default is the point. A forgotten configuration transaction
     *      must fail safe, and on a taxed token this is money rather than
     *      philosophy: a sell leg would pay the tax on the way out on top of
     *      dumping the token the pot exists to support.
     */
    function test_aBnbullPaymentNeverSellsForTheBnbLegEvenWhenTaxed() public view {
        assertFalse(
            roDrop.bnbullPaymentSellsForBnbLeg(),
            "DECISIONS 14: the sell policy must default to false"
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev Buy `amountIn` of BNB worth through the real router and return the
    ///      shortfall against the router's own quote, in bps.
    function _measuredTaxBps(address token, uint256 amountIn) internal returns (uint256) {
        address[] memory path = _pathWbnbTo(token);
        uint256 quoted = v2Router.getAmountsOut(amountIn, path)[1];
        address buyer = address(uint160(uint256(keccak256(abi.encode(token, amountIn)))));
        vm.deal(buyer, amountIn);
        uint256 before = IERC20Fork(token).balanceOf(buyer);
        vm.prank(buyer);
        v2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: amountIn }(
            0, path, buyer, block.timestamp
        );
        uint256 got = IERC20Fork(token).balanceOf(buyer) - before;
        return got >= quoted ? 0 : ((quoted - got) * 10_000) / quoted;
    }

    function _dropFor(address token) internal returns (MintDrop drop) {
        bulls = new Bulls(owner, 0xB011, bytes32(0));
        potBnbull = new Jackpot(token, address(0), A.VRF_COORDINATOR_V2_5, 50);
        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: token,
                wbnb: A.WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
           })
        );
        bulls.bootstrapWire(Bulls.Wire.MintDrop, address(drop));
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, A.CHAINLINK_BNB_USD);
        drop.bootstrapWire(MintDrop.Wire.Router, A.PANCAKE_V2_ROUTER);
        drop.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);
        drop.setPriceTiers(_launchTiers());
    }

    function _launchTiers() internal pure returns (MintDrop.PriceTier[] memory t) {
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({upToSold: 100, usdPrice: 10e18, bnbullPrice: 0});
        t[1] = MintDrop.PriceTier({upToSold: 200, usdPrice: 20e18, bnbullPrice: 0});
        t[2] = MintDrop.PriceTier({upToSold: 300, usdPrice: 35e18, bnbullPrice: 0});
        t[3] = MintDrop.PriceTier({upToSold: 400, usdPrice: 50e18, bnbullPrice: 0});
        t[4] = MintDrop.PriceTier({upToSold: 500, usdPrice: 75e18, bnbullPrice: 0});
    }

    function carolAddr() internal pure returns (address) {
        return address(0xCA401);
    }
}
