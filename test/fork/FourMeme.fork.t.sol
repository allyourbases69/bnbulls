// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {
    IERC20Fork,
    IFourMemeTokenFork,
    ITokenManager2Fork,
    IPancakePairFork,
    IPancakeFactoryFork
} from "./ForkInterfaces.sol";

/**
 * @notice A contract that buys on the four.meme curve and can receive the
 *         refund. `FOUR-MEME-LAUNCH-ROUTE §9.1` calls the missing payable
 *         fallback "a live footgun" — this pair of helpers turns that sentence
 *         into a test.
 */
contract CurveBuyerWithFallback {
    function buy(address pad, address token, uint256 funds, uint256 minAmount) external payable {
        ITokenManager2Fork(pad).buyTokenAMAP{ value: msg.value }(token, funds, minAmount);
    }

    /// @dev Measured delta, because `buyTokenAMAP` returns nothing at all.
    function buyMeasured(address pad, address token, uint256 funds, uint256 minAmount)
        external
        payable
        returns (uint256 received)
    {
        uint256 before = IERC20Fork(token).balanceOf(address(this));
        ITokenManager2Fork(pad).buyTokenAMAP{ value: msg.value }(token, funds, minAmount);
        received = IERC20Fork(token).balanceOf(address(this)) - before;
    }

    function push(address token, address to, uint256 amount) external {
        IERC20Fork(token).transfer(to, amount);
    }

    receive() external payable { }
}

/// @notice Identical, minus the payable fallback. Exists only to prove the
///         refund footgun is real.
contract CurveBuyerNoFallback {
    function buy(address pad, address token, uint256 funds, uint256 minAmount) external payable {
        ITokenManager2Fork(pad).buyTokenAMAP{ value: msg.value }(token, funds, minAmount);
    }
}

/**
 * @title FourMemeForkTest
 * @notice The four.meme facts `DECISIONS.md §28/§29/§30` are built on, RE-RUN
 *         as executable assertions against the live pad.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHY THIS FILE IS A REGRESSION SUITE AND NOT A REPORT
 * ══════════════════════════════════════════════════════════════════════════
 *
 * `FOUR-MEME-LAUNCH-ROUTE.md` closes with a RE-VERIFY WARNING: the pad is a
 * UUPS proxy behind a 3-of-6 Safe with **unverified implementation source**,
 * so "a single Safe transaction can change every fact in this document
 * without any warning or event we watch for."
 *
 * A markdown file cannot notice that. This file can. Every load-bearing claim
 * in §28 is asserted here, so re-running the package at a newer pin is the
 * re-verify drill rather than a manual afternoon with `cast`.
 *
 * ⚠ THE SPECIMEN IS NOT BNBULL. `DECISIONS.md §29`: BNBULL does not exist on
 * mainnet, and could not be transferred if it did. Nothing here assumes
 * otherwise — the graduated state is MANUFACTURED on the fork by filling a
 * real curve with real BNB.
 */
contract FourMemeForkTest is ForkBase {
    IFourMemeTokenFork internal gort = IFourMemeTokenFork(A.GORT);

    // ══════════════════════════════════════════════════════════════════════
    //  1. The transfer gate  (`DECISIONS.md §28.1`)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE PRODUCT-LEVEL CONSTRAINT. A real holder of a real
     *         pre-graduation four.meme token cannot move one wei of it.
     *
     * @dev This is the DyorSwap failure class Fefers rejected, and four.meme
     *      has it. Every BNBULL money path in the game is `transferFrom` —
     *      the 10% mint discount, duel stakes, marketplace payments — so all
     *      of them are dead for the whole curve phase. That is not a buyback
     *      inconvenience; it is why `DECISIONS.md §29` forces a BNB-only
     *      phase 1.
     *
     *      No mock in `test/mocks/` reverts like this, and none should: the
     *      point is that the REAL token does.
     */
    function test_aRealHolderCannotMoveAPreGraduationFourMemeToken() public {
        uint256 held = gort.balanceOf(A.GORT_HOLDER);
        assertGt(held, 0, "specimen holder is empty at the pin - re-pick a holder");
        assertEq(gort._mode(), 1, "specimen is no longer transfer-restricted at the pin");

        vm.prank(A.GORT_HOLDER);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        gort.transfer(A.DEAD, 1e18);
    }

    /**
     * @notice `transferFrom` WITH a real allowance reverts on the same gate.
     *
     * @dev `FOUR-MEME-LAUNCH-ROUTE §2` flags the trap explicitly: without an
     *      allowance the call reverts on the allowance check FIRST, which
     *      looks like the same failure and is not. `approve` itself succeeds
     *      even during the restricted phase, so a probe that only checks
     *      `approve` concludes the opposite of the truth.
     */
    function test_theGateIsTheTransferNotTheAllowance() public {
        vm.prank(A.GORT_HOLDER);
        assertTrue(gort.approve(alice, type(uint256).max), "approve must work during the gate");
        assertEq(gort.allowance(A.GORT_HOLDER, alice), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        gort.transferFrom(A.GORT_HOLDER, alice, 1e18);
    }

    /// @notice The gate is a property of the TEMPLATE, not of one unlucky
    ///         token. Second live specimen, same revert string.
    function test_theGateHoldsOnASecondLiveSpecimen() public {
        IFourMemeTokenFork beau = IFourMemeTokenFork(A.BEAU);
        assertEq(beau._mode(), 1, "second specimen already graduated at the pin");
        // Give the caller a balance the honest way: buy it on the curve.
        uint256 got = _curveBuy(A.BEAU, alice, 0.05 ether, 1);
        assertGt(got, 0, "curve buy delivered nothing");

        vm.prank(alice);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        beau.transfer(A.DEAD, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. A contract CAN buy on the curve  (`DECISIONS.md §28.2`)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `buyTokenAMAP` from a CONTRACT, with the output booked as a
     *         measured balance delta.
     *
     * @dev The owner's instinct was right and this proves it end to end: no
     *      EOA gate, no `tx.origin == msg.sender`, no signature, no referral.
     *      The pot's buy leg can therefore accumulate BNBULL at curve prices
     *      during the whole pre-graduation window instead of sitting on idle
     *      BNB.
     *
     *      ⚠ AND THE CATCH, IN THE SAME TEST: what it buys, it cannot spend.
     *      The final assertion is the one that decides the launch order.
     */
    function test_aContractCanBuyOnTheCurveButCannotSpendWhatItBought() public {
        CurveBuyerWithFallback buyer = new CurveBuyerWithFallback();
        vm.deal(address(buyer), 1 ether);

        uint256 received =
            buyer.buyMeasured{ value: 0.1 ether }(A.FOUR_MEME_TOKEN_MANAGER, A.GORT, 0.1 ether, 1);

        assertGt(received, 0, "a contract could not buy on the curve");
        assertEq(gort.balanceOf(address(buyer)), received, "tokens did not land with msg.sender");
        console2.log("0.1 BNB bought (curve, token wei):", received);

        // The whole point: it holds them, and it can do nothing with them.
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        buyer.push(A.GORT, treasury, 1);
    }

    /**
     * @notice `minAmount` is a REAL slippage floor, so our no-blind-swap rule
     *         survives on this venue.
     *
     * @dev `BNBULLS-BOOTSTRAP §6` and every splitter in the tree refuse a
     *      `minOut` of zero. A curve integration would be worthless if the
     *      pad ignored the floor. It does not: an unreachable floor reverts
     *      `Slippage`, which lands in the never-fail try/catch and accrues.
     */
    function test_theCurveHasARealSlippageFloorSoNoBuyHasToBeBlind() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Slippage"));
        fourMeme.buyTokenAMAP{ value: 0.1 ether }(A.GORT, 0.1 ether, type(uint128).max);
    }

    /**
     * @notice ⚠ THE REFUND FOOTGUN, made concrete.
     *
     * @dev The pad refunds overpayment to `msg.sender`. A buyer contract
     *      without a payable fallback therefore reverts on a successful buy —
     *      the money layer would appear to "not work on this venue" for a
     *      reason that has nothing to do with the venue. Any curve integration
     *      we build must carry a payable receive.
     */
    function test_aBuyerContractWithoutAPayableFallbackIsBrickedByTheRefund() public {
        CurveBuyerNoFallback bad = new CurveBuyerNoFallback();
        vm.deal(address(bad), 1 ether);
        // funds < msg.value forces a refund.
        vm.expectRevert();
        bad.buy{ value: 0.5 ether }(A.FOUR_MEME_TOKEN_MANAGER, A.GORT, 0.1 ether, 1);

        // The same call from a contract that CAN receive succeeds.
        CurveBuyerWithFallback good = new CurveBuyerWithFallback();
        vm.deal(address(good), 1 ether);
        uint256 got =
            good.buyMeasured{ value: 0.5 ether }(A.FOUR_MEME_TOKEN_MANAGER, A.GORT, 0.1 ether, 1);
        assertGt(got, 0);
        assertGt(address(good).balance, 0.35 ether, "overpayment was not refunded");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. The launch-form checkbox  (`DECISIONS.md §30`)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE ONE READ THAT DECIDES WHETHER THE MONEY LAYER EXISTS.
     *
     * @dev 19 of the pad's 20 templates graduate into a NON-BNB pool. With the
     *      stablecoin dropped (`DECISIONS.md §26`), WBNB is our only pivot, so
     *      a token created on any other template graduates into a book our
     *      contracts cannot reach — permanently, because the LP is burned and
     *      the token is immutable.
     *
     *      This test is the executable form of the pre-announcement checklist
     *      in `FOUR-MEME-LAUNCH-ROUTE §7`. Point it at OUR token on launch day.
     */
    function test_theSpecimenIsOnTheOneTemplateThatGraduatesIntoABnbPool() public view {
        CurveState memory c = _curve(A.GORT);
        assertEq(c.quote, address(0), "quote asset is NOT native BNB - wrong template");
        assertEq(c.status, 0, "specimen is not STATUS_TRADING at the pin");
        assertEq(c.totalSupply, 1e27, "supply shape moved");
        assertEq(c.maxOffers, 8e26, "80% on the curve moved");
        assertGt(c.maxRaising, 0, "no graduation target");
        console2.log("maxRaising (BNB wei):", c.maxRaising);
        console2.log("raised so far (BNB wei):", c.funds);
    }

    /// @notice The pad's DEX constants are compile-time constants inside the
    ///         token, not pad config: whatever the pad's Safe does later, a
    ///         token already created still graduates to THIS router.
    function test_theTokenItselfHardcodesTheV2VenueWeTargeted() public view {
        assertEq(gort.PANCAKE_FACTORY(), A.PANCAKE_V2_FACTORY, "v2 factory constant moved");
        assertEq(gort.PANCAKE_ROUTER(), A.PANCAKE_V2_ROUTER, "v2 router constant moved");
        assertEq(gort.WETH(), A.WBNB, "quote wrapper constant moved");
    }

    /// @notice Template B carries a creator-set tax. Reading it is the launch
    ///         decision in `DECISIONS.md §30`; this records what the live
    ///         specimen actually carries so a zero-tax launch can be compared
    ///         against a known-taxed one.
    function test_theSpecimenCarriesTheCreatorSetTaxTemplateBIsKnownFor() public view {
        uint256 buyFee = gort.feeRateBuy();
        uint256 sellFee = gort.feeRateSell();
        console2.log("specimen feeRateBuy  (percent):", buyFee);
        console2.log("specimen feeRateSell (percent):", sellFee);
        assertLe(buyFee, 10, "buy tax above the template bound");
        assertLe(sellFee, 10, "sell tax above the template bound");
        assertGt(buyFee, 0, "specimen is untaxed - it is no longer a template-B specimen");
    }

    /// @notice The curve phase is CUSTODIAL: the token's owner is the pad.
    ///         Recorded because it is the fact that makes `sendToken` /
    ///         `setMode` / `suspendTrading` reachable at all.
    function test_duringTheCurveThePadOwnsTheToken() public view {
        assertEq(gort.owner(), A.FOUR_MEME_TOKEN_MANAGER, "curve-phase owner moved");
        assertEq(fourMeme.owner(), A.FOUR_MEME_SAFE, "the pad's own owner moved");
        assertFalse(fourMeme._tradingHalt(), "four.meme has halted trading globally");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. A REAL GRADUATION  (`DECISIONS.md §28.3`)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE END STATE, MANUFACTURED. Fill a real curve with real BNB
     *         and assert every property the money layer depends on.
     *
     * @dev This is the only way to test anything about graduated BNBULL:
     *      `DECISIONS.md §29` says the token does not exist yet. Rather than
     *      assume the end state, the test buys its way into it.
     *
     *      Assertions, in the order they would kill us if wrong:
     *        1. liquidity lands in PancakeSwap **v2** against **WBNB**;
     *        2. **zero** v3 pools are created, at any tier - so a v3-only leg
     *           can only ever find somebody else's decoy;
     *        3. the LP is BURNED, so nobody can pull the book;
     *        4. the transfer gate lifts permanently and ownership renounces.
     */
    function test_graduationLandsInV2AgainstWbnbWithNoV3PoolAndABurnedLp() public {
        assertEq(v2Factory.getPair(A.GORT, A.WBNB), address(0), "pair exists before graduation");

        _graduate(A.GORT, alice);

        // 1. The venue.
        address pair = v2Factory.getPair(A.GORT, A.WBNB);
        assertTrue(pair != address(0), "no v2 pair after graduation");
        assertEq(gort.pair(), pair, "token disagrees with the factory about its own pair");

        uint256 wbnbReserve = _pairWbnbReserve(pair);
        assertGt(wbnbReserve, 10 ether, "opening book is thinner than a graduation should be");
        console2.log("opening WBNB reserve (wei):", wbnbReserve);
        console2.log("opening token reserve (wei):", IERC20Fork(A.GORT).balanceOf(pair));

        // 2. The venue we point at today, and what is in it: nothing.
        assertEq(v3Factory.getPool(A.GORT, A.WBNB, A.V3_FEE_100), address(0), "v3 100 exists");
        assertEq(v3Factory.getPool(A.GORT, A.WBNB, A.V3_FEE_500), address(0), "v3 500 exists");
        assertEq(v3Factory.getPool(A.GORT, A.WBNB, A.V3_FEE_2500), address(0), "v3 2500 exists");
        assertEq(
            v3Factory.getPool(A.GORT, A.WBNB, A.V3_FEE_10000),
            address(0),
            "v3 10000 exists - four.meme created one after all"
        );

        // 3. The LP.
        IPancakePairFork lp = IPancakePairFork(pair);
        assertEq(
            lp.balanceOf(A.DEAD),
            lp.totalSupply() - 1000,
            "LP is not burned (1000 wei is Uniswap's MINIMUM_LIQUIDITY)"
        );
        assertEq(lp.balanceOf(A.FOUR_MEME_TOKEN_MANAGER), 0, "the pad kept LP");
        assertEq(lp.balanceOf(A.GORT), 0, "the token kept LP");

        // 4. The gate, gone for good.
        assertEq(gort._mode(), 0, "transfer gate did not lift");
        assertEq(gort.owner(), address(0), "ownership was not renounced");
        assertEq(_curve(A.GORT).status, 3, "curve is not STATUS_COMPLETED");
    }

    /**
     * @notice After graduation the game's money paths work — EXACT amounts,
     *         no max-tx, no max-wallet.
     *
     * @dev `approve` + third-party `transferFrom` is literally the duel stake
     *      pull and the marketplace payment pull. `Duel._takeSide` reverts
     *      `StakeShortfall` if a pull delivers less than signed, so "exact" is
     *      not a nicety here — an inexact wallet-to-wallet transfer would make
     *      BNBULL unusable as a stake asset even after graduation.
     */
    function test_afterGraduationTheGameMoneyPathsMoveExactAmounts() public {
        _graduate(A.GORT, alice);

        uint256 held = gort.balanceOf(alice);
        assertGt(held, 1e21, "buyer holds too little to test with");

        // Wallet to wallet.
        uint256 beforeBob = gort.balanceOf(bob);
        vm.prank(alice);
        gort.transfer(bob, 1e21);
        assertEq(gort.balanceOf(bob) - beforeBob, 1e21, "plain transfer is not exact");

        // approve + third-party transferFrom: the duel stake pull.
        vm.prank(bob);
        gort.approve(carolAddr(), 1e21);
        uint256 beforeCarol = gort.balanceOf(carolAddr());
        vm.prank(carolAddr());
        gort.transferFrom(bob, carolAddr(), 1e21);
        assertEq(gort.balanceOf(carolAddr()) - beforeCarol, 1e21, "stake pull is not exact");

        // No max-wallet: move 10% of supply in one go.
        uint256 big = gort.balanceOf(alice);
        vm.prank(alice);
        gort.transfer(bob, big);
        assertEq(gort.balanceOf(alice), 0, "a max-tx or max-wallet cap exists");
    }

    /**
     * @notice The curve leg must be STATE-driven, not date-driven: after
     *         graduation `buyTokenAMAP` does not merely stop being useful, it
     *         REVERTS.
     *
     * @dev `FOUR-MEME-LAUNCH-ROUTE §9.1`. A venue switch scheduled by date
     *      would brick the pot leg for however long the two disagreed.
     */
    function test_theCurveBuyRevertsOnceTheTokenHasGraduated() public {
        _graduate(A.GORT, alice);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("Disabled"));
        fourMeme.buyTokenAMAP{ value: 0.1 ether }(A.GORT, 0.1 ether, 1);
    }

    /**
     * @notice The pad has ZERO custody power over a graduated token.
     *
     * @dev The curve phase is custodial (`sendToken`, `setMode`,
     *      `suspendTrading` all reachable by the pad or its operators). This
     *      proves that power ends at graduation — impersonating the pad
     *      itself cannot move a holder's balance afterwards.
     */
    function test_thePadCannotTouchAGraduatedTokensBalances() public {
        _graduate(A.GORT, alice);
        uint256 held = gort.balanceOf(alice);
        assertGt(held, 0);

        vm.prank(A.FOUR_MEME_TOKEN_MANAGER);
        (bool ok,) = A.GORT
            .call(
                abi.encodeWithSignature("sendToken(address,address,uint256)", alice, A.DEAD, held)
            );
        assertFalse(ok, "the pad could still move a graduated holder's balance");
        assertEq(gort.balanceOf(alice), held, "balance moved");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. Mainnet corroboration, no graduation required
    // ══════════════════════════════════════════════════════════════════════

    /// @notice An ALREADY-graduated four.meme token on mainnet shows the same
    ///         end state, so the fork graduation is not an artefact of the
    ///         fork.
    function test_anAlreadyGraduatedMainnetTokenShowsTheSameEndState() public view {
        address pair = v2Factory.getPair(A.FOUR_MEME_PRO, A.WBNB);
        assertEq(pair, A.FOUR_MEME_PRO_PAIR, "known graduate's pair moved");

        IPancakePairFork lp = IPancakePairFork(pair);
        assertEq(lp.balanceOf(A.DEAD), lp.totalSupply() - 1000, "known graduate's LP is not burned");
        assertEq(IFourMemeTokenFork(A.FOUR_MEME_PRO)._mode(), 0, "known graduate is still gated");
        assertEq(
            IFourMemeTokenFork(A.FOUR_MEME_PRO).owner(), address(0), "known graduate has an owner"
        );
    }

    /**
     * @notice ⚠ THE TRAP, SITTING ON A REAL GRADUATE TODAY. Broccoli has a v2
     *         pair AND third-party v3 pools that four.meme never created.
     *
     * @dev This is `BNB-CHAIN-FACTS §3` on BSC, live, with no help from us. It
     *      is the standing argument for the minimum-liquidity floor and for
     *      moving the BNBULL leg off v3 (`DECISIONS.md §28.3`). See
     *      `DecoyPool.fork.t.sol` for the measured cost.
     */
    function test_aRealFourMemeGraduateAlreadyCarriesThirdPartyV3Pools() public view {
        address v2 = v2Factory.getPair(A.BROCCOLI, A.WBNB);
        assertTrue(v2 != address(0), "the real book vanished");

        uint256 decoyTiers;
        uint24[4] memory tiers = [A.V3_FEE_100, A.V3_FEE_500, A.V3_FEE_2500, A.V3_FEE_10000];
        for (uint256 i = 0; i < tiers.length; i++) {
            address p = v3Factory.getPool(A.BROCCOLI, A.WBNB, tiers[i]);
            if (p != address(0)) {
                decoyTiers++;
                console2.log("third-party v3 pool at tier", uint256(tiers[i]));
                console2.log("   ->", p);
            }
        }
        assertGt(
            decoyTiers,
            0,
            "no third-party v3 pool on a real four.meme graduate - re-read DECISIONS 28.3"
        );
        console2.log("real v2 WBNB reserve (wei):", _pairWbnbReserve(v2));
    }

    // ─── local actor ──────────────────────────────────────────────────────

    function carolAddr() internal pure returns (address) {
        return address(0xCA401);
    }
}
