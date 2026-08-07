// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {FourMemeTaxedToken} from "./mocks/SplitterMocks.sol";

/**
 * @title MintDropLiquidityFloorTest
 * @notice THE MINT BUY LEG'S MINIMUM-LIQUIDITY FLOOR — `DECISIONS.md §28`,
 *         `§29`, `§30`.
 *
 * @dev `MintDrop` was already the only leg in the codebase on the right venue
 *      (PancakeSwap **v2**, where four.meme actually graduates), and it was the
 *      only leg with **no liquidity floor at all**. That combination is worse
 *      than it sounds: being on the right venue is what makes it capable of
 *      trading, and the mint's 20% slice is the biggest single buy in the game.
 *
 *      The window the floor closes is PRE-GRADUATION. v2 has one canonical pair
 *      per token pair, so this is not the "which of several pools is real"
 *      question v3 posed — it is "has anybody front-run the pair into existence
 *      with dust". Anyone can `createPair(BNBULL, WBNB)` on the v2 factory
 *      before the curve completes (VERIFIED on a fork), and a pair that EXISTS
 *      is a pair a naive leg will trade against.
 *
 *      And it is what makes the whole curve phase *deliberately* deferred
 *      rather than accidentally so (`§29`): phase 1 launches BNB-first, every
 *      BNBULL leg reads as "not available yet" and accrues. **That is the
 *      normal launch state, so it is tested here as the normal case.**
 */
contract MintDropLiquidityFloorTest is BnbullsBase {
    // ══════════════════════════════════════════════════════════════════════
    //  1. The floor itself
    // ══════════════════════════════════════════════════════════════════════

    function test_theLaunchDefaultIsOneBnbAndItIsBoundedAndRefusesZero() public {
        assertEq(drop.minPoolLiquidity(), 1 ether, "launch default");

        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidMinLiquidity.selector, uint256(0)));
        drop.setMinPoolLiquidity(0);

        uint256 tooBig = drop.MAX_MIN_POOL_LIQUIDITY() + 1;
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidMinLiquidity.selector, tooBig));
        drop.setMinPoolLiquidity(tooBig);

        vm.prank(alice);
        vm.expectRevert();
        drop.setMinPoolLiquidity(4 ether);

        vm.expectEmit(false, false, false, true, address(drop));
        emit MintDrop.MinPoolLiquidityChanged(4 ether);
        drop.setMinPoolLiquidity(4 ether);
        assertEq(drop.minPoolLiquidity(), 4 ether);
    }

    /// @dev The pair is derived from `router.factory()`, never a second wire,
    ///      so the reserve the floor measures cannot belong to a different pool
    ///      from the one the swap hits.
    function test_thePairIsDerivedFromTheRoutersOwnFactory() public view {
        (address pair, uint256 reserve) = drop.wbnbPoolLiquidity();
        assertEq(pair, address(router.v2Pair()));
        assertEq(reserve, uint256(router.HEALTHY_RESERVE()));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE LAUNCH STATE — no pair, and it is the NORMAL case
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `DECISIONS.md §29`: BNBULL cannot participate in any game flow
     *         until four.meme's curve completes. A mint on day one must sell the
     *         bull, take the money, wrap the BNB pot leg, and ACCRUE the BNBULL
     *         leg. Nothing may revert.
     */
    function test_aMintWithNoPairAtAllStillSellsTheBullAndAccruesTheBuy() public {
        router.setPairMissing(true);

        uint256 spent = _mintBnb(alice, 1);

        assertEq(bulls.balanceOf(alice), 1, "the mint itself must not care");
        assertEq(potBnbull.pool(), 0, "nothing may be bought pre-graduation");
        assertGt(drop.pendingBnbullBuyNative(), 0, "the slice accrued instead");
        assertEq(router.swapCalls(), 0, "no pair means no trade, at all");
        assertEq(potBnb.pool(), (spent * 1_000) / 10_000, "the wrap leg needs no pair");
    }

    /// @dev The un-guarded donation entrypoint — the one the Graveyard calls on
    ///      every revive with no try/catch of its own. If it reverts, every
    ///      revive in the game bricks.
    function test_theDonationEntrypointNeverRevertsWithNoPair() public {
        router.setPairMissing(true);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbullPotDeferred(MintDrop.PotSource.Native, 2 ether, 2 ether);
        drop.donatePotNative{value: 3 ether}();

        assertEq(drop.pendingBnbullBuyNative(), 2 ether);
        assertEq(address(drop).balance, 2 ether, "the deferred slice is genuinely still here");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. THE DECOY — a pair front-run into existence with dust
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The 95x trade, refused. `MintDrop`'s inline floor is quoted off
     *         `getAmountsOut` over the very reserves the swap will hit, so a
     *         dust pair quotes a dust price and the swap CLEARS its own floor
     *         happily. The slippage guard cannot see this. Only the reserve
     *         check can.
     */
    function test_aDustPairIsRefusedEvenThoughTheSwapWouldClearItsOwnQuote() public {
        router.setPairReserves(0.01 ether, 1e24);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();

        assertEq(router.swapCalls(), 0, "the dust trade must never be made");
        assertEq(potBnbull.pool(), 0);
        assertEq(drop.pendingBnbullBuyNative(), 2 ether, "deferred, not lost");
    }

    function test_theLiquidityBoundaryIsInclusive() public {
        router.setPairReserves(uint112(drop.minPoolLiquidity()), 1e24);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        assertEq(router.swapCalls(), 1, "exactly at the floor must trade");

        router.setPairReserves(uint112(drop.minPoolLiquidity() - 1), 1e24);
        vm.deal(bob, 3 ether);
        vm.prank(bob);
        drop.donatePotNative{value: 3 ether}();
        assertEq(router.swapCalls(), 1, "one wei under the floor must defer");
    }

    /// @dev Read off the WBNB SIDE. A decoy can mint an unlimited supply of its
    ///      own token; it cannot mint BNB, which is why the BNBULL side is
    ///      never the measure.
    function test_theFloorReadsTheWbnbSideNotTheTokenSide() public {
        router.setPairReserves(0.001 ether, type(uint112).max);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();

        assertEq(router.swapCalls(), 0, "the floor was read off the side a decoy can print");
    }

    /// @dev `token0()` is READ off the pair rather than derived from address
    ///      ordering, so the reserves are still identified correctly when WBNB
    ///      is token1.
    function test_theReserveIsIdentifiedByToken0NotAddressOrdering() public {
        router.v2Pair().setTokens(address(bnbull), address(wbnb));
        router.setPairReserves(type(uint112).max, 0.001 ether); // r0 BNBULL, r1 WBNB

        (, uint256 reserve) = drop.wbnbPoolLiquidity();
        assertEq(reserve, 0.001 ether, "the WBNB side was misidentified");

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        assertEq(router.swapCalls(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. The sweeps are floored too, and they fail LOUDLY
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A keeper draining the whole backlog into a dust pair is the same
     *         loss as many inline buys, in one transaction. The sweep is not a
     *         never-fail path, so here the floor reverts rather than defers.
     */
    function test_theSweepRefusesAThinPoolLoudlyAndClearsOnceItIsReal() public {
        router.setPairMissing(true);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);

        router.setPairMissing(false);
        router.setPairReserves(0.01 ether, 1e24);

        // ⛔ The OWNER drives it: a priced sweep on `MintDrop` is owner-only,
        //    because this contract carries no published floor to measure a
        //    keeper's `minOut` against. See `MintDrop.sweepBnbullPot`.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.PoolTooThin.selector, 0.01 ether, 1 ether)
        );
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);
        assertEq(drop.pendingBnbullBuyNative(), 2 ether, "the bucket must be untouched");

        // Graduation: 17.64 WBNB against 200,000,000 tokens, the figure measured
        // on three mainnet-fork graduations.
        router.setPairReserves(17.64 ether, 200_000_000e18);
        vm.prank(owner);
        uint256 funded = drop.sweepBnbullPot(
            MintDrop.PotSource.Native, 0, 1 ether * BNBULL_PER_BNB
        );
        assertEq(funded, 2 ether * BNBULL_PER_BNB);
        assertEq(drop.pendingBnbullBuyNative(), 0, "the backlog cleared");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. THE FEE-SUPPORTING CALL — `DECISIONS.md §30`
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The regression sentinel. `MockRouter`'s legacy, NON
     *         fee-supporting selectors revert `Pancake: K` — exactly what the
     *         real router does on a four.meme template B token, whose creator
     *         can set a buy AND sell tax (measured -10%). A buy that lands is
     *         proof the fee-supporting variant was the one called.
     */
    function test_theBuyUsesTheFeeSupportingVariant() public {
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();

        assertEq(potBnbull.pool(), 2 ether * BNBULL_PER_BNB, "the buy landed");
        assertEq(router.swapCalls(), 1);
    }

    /// @dev And the legacy selector really does revert `Pancake: K`, so the
    ///      sentinel above means what it says.
    function test_theLegacySelectorRevertsPancakeK() public {
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(bnbull);

        vm.expectRevert("Pancake: K");
        router.swapExactTokensForTokens(1 ether, 0, path, address(this), block.timestamp);

        vm.expectRevert("Pancake: K");
        router.swapExactETHForTokens{value: 0}(0, path, address(this), block.timestamp);
    }

    /// @dev The BNBULL -> WBNB direction uses the fee-supporting token variant
    ///      too. Reached only with the `§14` never-sell default switched OFF,
    ///      which is the one configuration where BNBULL is ever sold.
    function test_theSellDirectionAlsoUsesTheFeeSupportingVariant() public {
        drop.setBnbullPaymentSellPolicy(true);

        _giveBnbull(alice, 1_000e18);
        vm.prank(alice);
        drop.donatePotToken(address(bnbull), 300e18);

        assertEq(router.swapCalls(), 1, "the sell leg went through the router");
        assertGt(potBnb.pool(), 0, "and the WBNB pot was funded from it");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. ⚠ THE TAX vs THE QUOTE — the half the router call does NOT fix
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ AN OPERATIONAL TRAP WORTH MORE THAN THE CONTRACT CHANGE.
     *
     *         `MintDrop`'s inline floor is `getAmountsOut` minus
     *         `inlineSlippageBps`. `getAmountsOut` prices the constant-product
     *         curve and knows **nothing** about a token's transfer tax. On a
     *         four.meme template B token — creator-set buy AND sell tax,
     *         measured -10% (`DECISIONS.md §30`) — the quote overstates what
     *         lands by the full tax.
     *
     *         So at the launch `inlineSlippageBps = 500` (5%), the
     *         fee-supporting call succeeds, 10% is skimmed, the measured delta
     *         misses `minOut`, and **every inline buy defers.** Nothing is lost
     *         and nothing reverts — but the leg is silently dead until somebody
     *         reads the `…Deferred` events.
     *
     *         The fix is configuration, not code: raise `inlineSlippageBps`
     *         above the tax (the cap is 20%). Both halves are pinned here.
     */
    function test_aTaxedTokenDefersUntilTheSlippageToleranceClearsTheTax() public {
        (MintDrop d, Jackpot pot) = _taxedDrop(1_000); // 10% buy tax

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        assertEq(pot.pool(), 0, "a 10% tax against 5% tolerance cannot clear the quote");
        assertEq(d.pendingBnbullBuyNative(), 2 ether, "deferred, not lost");

        // Raise the tolerance above the tax and the same buy goes through.
        d.setInlineSlippageBps(1_500);
        vm.prank(owner);
        uint256 funded = d.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);

        assertEq(funded, (2 ether * BNBULL_PER_BNB * 90) / 100, "booked POST-tax, as measured");
        assertEq(pot.pool(), funded);
        assertEq(d.pendingBnbullBuyNative(), 0);
    }

    /// @dev And with the tolerance set correctly from the start, the inline
    ///      buy on a taxed token just works — proving the fee-supporting call
    ///      is what makes it possible at all.
    function test_aTaxedTokenBuysInlineOnceTheToleranceIsRight() public {
        (MintDrop d, Jackpot pot) = _taxedDrop(1_000);
        d.setInlineSlippageBps(1_500);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        assertEq(pot.pool(), (2 ether * BNBULL_PER_BNB * 90) / 100, "the post-tax amount landed");
        assertEq(d.pendingBnbullBuyNative(), 0, "nothing had to defer");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A whole `MintDrop` running on a four.meme **template B** token: a
    ///      creator-set tax that bites only on transfers touching the pair
    ///      (here, the router mock, which holds the other side of the book).
    function _taxedDrop(uint256 taxBps) private returns (MintDrop d, Jackpot pot) {
        FourMemeTaxedToken bull = new FourMemeTaxedToken("TaxBull", "TBULL", 18);
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(b),
                bnbull: address(bull),
                wbnb: address(wbnb),
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        d.unpause();
        b.bootstrapWire(Bulls.Wire.MintDrop, address(d));

        MockRouter r = new MockRouter(address(wbnb));
        r.setRate(address(wbnb), address(bull), BNBULL_PER_BNB, 1);
        bull.setPair(address(r));
        bull.setTax(taxBps, taxBps);
        bull.mint(address(r), 1e30);

        pot = new Jackpot(address(bull), address(0), address(coord), 50);
        pot.setFunder(address(d), true);

        d.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        d.bootstrapWire(MintDrop.Wire.Router, address(r));
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(pot));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnb.setFunder(address(d), true);
        d.setPriceTiers(_launchTiers());
        d.setKeeper(keeper);
    }
}
