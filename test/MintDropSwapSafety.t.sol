// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/**
 * @title MintDropSwapSafetyTest
 * @notice PRIORITY 8. Swaps are MEASURED BALANCE DELTAS, and a blind swap is
 *         refused.
 *
 * @dev `LEARNINGS-AND-MISTAKES §B`, carried over verbatim from fefers:
 *
 *        "measure swap output as a balance delta, never trust the router. every
 *         buyback on fighting fefers does `bought = token.balanceOf(after) -
 *         before` and re-checks against `minOut`. **a fee-on-transfer token or
 *         a lying router would otherwise wedge the pot forever.**"
 *        "the min-out floor is quoted OFF-CHAIN and a floor of 0 is refused as
 *         a blind swap."
 *
 *      ⚠ `test/mocks/MockRouter.sol` NEVER ENFORCES `amountOutMin`. That is
 *      deliberate: if MintDrop leaned on the router's own enforcement, or on
 *      its returned `amounts[]`, every test here would pass while the pot
 *      received dust. The contract has to catch it by itself or not at all.
 */
contract MintDropSwapSafetyTest is BnbullsBase {
    /// @dev The router belonging to the most recent `_dropWith` deployment.
    MockRouter internal altRouter;

    // ══════════════════════════════════════════════════════════════════════
    //  A lying router
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Reports the full quote in `amounts[]`, transfers 1% of it. The
    ///         measured delta must be what `minOut` is checked against.
    function test_aLyingRouterDoesNotSatisfyMinOut() public {
        // Park some BNB in the deferred bucket so the sweep has something to
        // spend with an explicit, off-chain-quoted floor.
        router.setRevertOnSwap(true);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);

        router.setRevertOnSwap(false);
        router.setLying(true, 100); // claims 100%, delivers 1%

        uint256 honestOut = 2 ether * BNBULL_PER_BNB;
        uint256 floor = (honestOut * 99) / 100;
        uint256 actuallyDelivered = honestOut / 100;

        // ⛔ OWNER, not keeper: a priced sweep on `MintDrop` is owner-only.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                MintDrop.SwapOutBelowMin.selector, actuallyDelivered, floor
            )
        );
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 2 ether, floor);

        assertEq(potBnbull.pool(), 0, "dust reached the pot");
        assertEq(drop.pendingBnbullBuyNative(), 2 ether, "the bucket must be untouched");
    }

    /// @dev Same router on the INLINE path: the mint still succeeds, the slice
    ///      defers, and the pot receives nothing rather than 1%.
    function test_aLyingRouterOnTheInlinePathDefersRatherThanFundingDust() public {
        router.setLying(true, 100);

        (, uint256 bnbDue,,) = drop.quote(1);
        _mintBnb(alice, 1);

        assertEq(bulls.balanceOf(alice), 1, "the mint must not fail");
        assertEq(potBnbull.pool(), 0, "1% of the quote was accepted as the buy");
        assertEq(drop.pendingBnbullBuyNative(), (bnbDue * 2_000) / 10_000);
    }

    /**
     * @notice The other direction: a router that delivers MORE than it says.
     *         The contract must book the measured delta, not the report.
     */
    function test_theMeasuredDeltaIsWhatGetsBookedEvenWhenItIsLarger() public {
        router.setLying(true, 20_000); // delivers 2x what it reports

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 slice = (bnbDue * 2_000) / 10_000;
        uint256 reported = slice * BNBULL_PER_BNB;

        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbullPotFundedInline(MintDrop.PotSource.Native, slice, reported * 2);
        _mintBnb(alice, 1);

        assertEq(potBnbull.pool(), reported * 2, "the pot got the reported figure, not the real one");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A floor of zero is a blind swap
    // ══════════════════════════════════════════════════════════════════════

    function test_minOutZeroIsRefusedOnEverySwapSweep() public {
        router.setRevertOnSwap(true);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();

        // A BNBULL leg that could not fund the pot, so the BNBULL -> WBNB
        // sweep has a bucket to refuse a blind swap on.
        drop.setBnbullPaymentSellPolicy(true);
        potBnb.setFunder(address(drop), false);
        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);
        assertGt(drop.pendingBnbPotBnbull(), 0, "harness: nothing deferred to sweep");

        vm.startPrank(keeper);
        vm.expectRevert(MintDrop.BlindSwapRefused.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 1 ether, 0);

        vm.expectRevert(MintDrop.BlindSwapRefused.selector);
        drop.sweepBnbPot(MintDrop.PotSource.Bnbull, 1e17, 0);
        vm.stopPrank();
    }

    /// @dev The two legs that are NOT swaps may pass a zero floor, because
    ///      there is no price to be got wrong: a direct BNBULL transfer and a
    ///      1:1 WBNB wrap.
    function test_theNonSwapLegsAcceptAZeroFloorBecauseTheyAreNotSwaps() public {
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);

        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);
        vm.deal(bob, 3 ether);
        vm.prank(bob);
        drop.donatePotNative{value: 3 ether}();

        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);

        vm.startPrank(keeper);
        drop.sweepBnbullPot(MintDrop.PotSource.Bnbull, 0, 0); // already the pot asset
        drop.sweepBnbPot(MintDrop.PotSource.Native, 0, 0); // a wrap, not a swap
        vm.stopPrank();

        assertEq(potBnbull.pool(), 270e18);
        assertEq(potBnb.pool(), 1 ether);
    }

    /// @dev A dead or empty pair quotes ZERO, which makes the on-chain floor
    ///      zero, which `_floor` refuses outright — so the inline leg defers.
    ///      Deferring beats trading into an empty pair.
    function test_aZeroQuoteBecomesABlindSwapAndTheInlineLegDefers() public {
        router.setQuoteZero(true);
        (, uint256 bnbDue,,) = drop.quote(1);
        _mintBnb(alice, 1);
        assertEq(potBnbull.pool(), 0);
        assertEq(drop.pendingBnbullBuyNative(), (bnbDue * 2_000) / 10_000);
    }

    function test_theInlineSlippageToleranceIsBounded() public {
        uint256 cap = drop.MAX_INLINE_SLIPPAGE_BPS();
        assertEq(cap, 2_000);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidShare.selector, cap + 1));
        drop.setInlineSlippageBps(cap + 1);
        drop.setInlineSlippageBps(cap);
        drop.setInlineSlippageBps(0);
        assertEq(drop.inlineSlippageBps(), 0);
    }

    /// @dev With zero tolerance the floor IS the quote, so a router delivering
    ///      one wei less than it promised is caught.
    function test_withZeroToleranceEvenAOneWeiShortfallIsCaught() public {
        drop.setInlineSlippageBps(0);
        router.setLying(true, 9_999); // 99.99% of the quote

        (, uint256 bnbDue,,) = drop.quote(1);
        _mintBnb(alice, 1);

        assertEq(potBnbull.pool(), 0, "a short delivery was accepted");
        assertEq(drop.pendingBnbullBuyNative(), (bnbDue * 2_000) / 10_000);

        // ...and an honest router at the same zero tolerance goes through.
        router.setLying(false, 0);
        vm.prank(owner);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);
        assertGt(potBnbull.pool(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Fee-on-transfer tokens wedge nothing
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A fee-on-transfer PAYMENT token. `_pullMeasured` books what
     *         actually arrived, so every downstream slice is computed off the
     *         real number and no wei is stranded.
     *
     * @dev ⚠ REWRITTEN, NOT DELETED, for `DECISIONS.md §26`: the taxed payment
     *      token is BNBULL rather than the stablecoin. That is the more honest
     *      test — BNBULL is launchpad-issued, so a transfer gate is a thing to
     *      VERIFY at deploy rather than assume, and it is now the only ERC-20 a
     *      buyer can pay with.
     */
    function test_aFeeOnTransferPaymentTokenIsMeasuredNotAssumed() public {
        MockFeeToken feeBull = new MockFeeToken(200); // 2%
        MintDrop d = _dropWith(address(feeBull));
        Jackpot pot = new Jackpot(address(feeBull), address(0), address(coord), 50);
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(pot));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        pot.setFunder(address(d), true);
        potBnb.setFunder(address(d), true);

        feeBull.mint(alice, 100_000e18);
        vm.prank(alice);
        feeBull.approve(address(d), type(uint256).max);

        (,, uint256 due,) = d.quote(1);
        assertEq(due, 900e18, "the sticker is unaffected by the token's fee");

        vm.prank(alice);
        d.mintWithBNBULL(alice, 1);

        uint256 received = (due * 9_800) / 10_000; // 882e18 actually arrived
        assertEq(feeBull.balanceOf(address(d)), 0, "payment currency stranded in MintDrop");
        // `§14`: the whole 30% goes to the BNBULL pot as tokens, less the fee
        // on the way in to the pot. Dev takes 70% of what ARRIVED, less the fee
        // on the way out.
        uint256 potSlice = (received * 3_000) / 10_000;
        uint256 devSlice = received - potSlice;
        assertEq(feeBull.balanceOf(treasury), (devSlice * 9_800) / 10_000);
        assertEq(pot.pool(), (potSlice * 9_800) / 10_000);
    }

    /// @notice A fee-on-transfer SWAP OUTPUT. The measured delta is below the
    ///         floor, so the leg defers instead of quietly under-funding the pot.
    function test_aHeavyFeeOnTheSwapOutputDefersInsteadOfUnderfunding() public {
        MockFeeToken feeBull = new MockFeeToken(0);
        MintDrop d = _dropWith(address(feeBull));
        MockRouter r = altRouter;
        r.setRate(address(wbnb), address(feeBull), BNBULL_PER_BNB, 1);
        feeBull.mint(address(r), 1e30);
        feeBull.setFeeBps(2_000); // 20% — well past the 5% inline tolerance

        Jackpot pot = new Jackpot(address(feeBull), address(0), address(coord), 50);
        pot.setFunder(address(d), true);
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(pot));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnb.setFunder(address(d), true);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        assertEq(pot.pool(), 0, "an 80% fill was accepted against a 95% floor");
        assertEq(d.pendingBnbullBuyNative(), 2 ether);
    }

    /// @dev A LIGHT fee is inside the tolerance, so the leg funds — and what
    ///      lands is the measured amount, fee and all, on both hops.
    function test_aLightFeeOnTheSwapOutputStillFundsAtTheMeasuredAmount() public {
        MockFeeToken feeBull = new MockFeeToken(0);
        MintDrop d = _dropWith(address(feeBull));
        MockRouter r = altRouter;
        r.setRate(address(wbnb), address(feeBull), BNBULL_PER_BNB, 1);
        feeBull.mint(address(r), 1e30);
        feeBull.setFeeBps(100); // 1%, inside the 5% tolerance

        Jackpot pot = new Jackpot(address(feeBull), address(0), address(coord), 50);
        pot.setFunder(address(d), true);
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(pot));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnb.setFunder(address(d), true);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        uint256 quoted = 2 ether * BNBULL_PER_BNB;
        uint256 measured = (quoted * 99) / 100; // what MintDrop actually received
        uint256 landed = (measured * 99) / 100; // less the fee into the pot
        assertEq(pot.pool(), landed);
        assertEq(pot.totalFunded(), landed, "Jackpot must also book the measured delta");
        assertEq(d.pendingBnbullBuyNative(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Hygiene
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Never leave an allowance standing — not to the router, not to a pot.
    function test_noAllowanceIsLeftStandingAfterASwapOrAFunding() public {
        _mintBnb(alice, 1);

        assertEq(wbnb.allowance(address(drop), address(router)), 0);
        assertEq(bnbull.allowance(address(drop), address(potBnbull)), 0);
        assertEq(wbnb.allowance(address(drop), address(potBnb)), 0);

        _giveBnbull(bob, 100_000e18);
        vm.prank(bob);
        drop.mintWithBNBULL(bob, 1);
        assertEq(bnbull.allowance(address(drop), address(router)), 0);
        assertEq(bnbull.allowance(address(drop), address(potBnbull)), 0);
    }

    /// @dev The inline workers are `external` only so the contract can
    ///      try/catch its own call. Nobody else may spend this contract's
    ///      balance through them.
    function test_theInlineWorkersAreUnreachableFromOutside() public {
        vm.prank(alice);
        vm.expectRevert(MintDrop.NotSelf.selector);
        drop.routeToBnbullPotInline(MintDrop.PotSource.Native, 1 ether);

        vm.expectRevert(MintDrop.NotSelf.selector);
        drop.routeToBnbPotInline(MintDrop.PotSource.Native, 1 ether);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _dropWith(address bnbull_) internal returns (MintDrop d) {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(b),
                bnbull: bnbull_,
                wbnb: address(wbnb),
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        d.unpause();
        b.bootstrapWire(Bulls.Wire.MintDrop, address(d));

        MockRouter r = new MockRouter(address(wbnb));
        altRouter = r;
        r.setRate(address(wbnb), bnbull_, BNBULL_PER_BNB, 1);
        MockERC20(bnbull_).mint(address(r), 1e30);
        vm.deal(address(this), address(this).balance + 1e22);
        wbnb.deposit{value: 1e22}();
        wbnb.transfer(address(r), 1e22);

        d.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        d.bootstrapWire(MintDrop.Wire.Router, address(r));
        // Pots are deliberately left unwired: each test picks its own prize
        // token, and a slot can only be bootstrapped once.
        d.setPriceTiers(_launchTiers());
        d.setKeeper(keeper);
    }
}
