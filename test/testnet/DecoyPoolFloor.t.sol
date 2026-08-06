// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestnetDexBase} from "./TestnetDexBase.t.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

/**
 * @title DecoyPoolFloorTest
 * @notice The decoy case: **a dust pool must be REFUSED by a minimum-liquidity
 *         floor, not traded against.**
 *
 * @dev ⚠⚠ THE CONTRACT-SIDE FLOOR DOES NOT EXIST YET. A grep of `contracts/`
 *      for `minPoolLiquidity` returns nothing as of this writing, and
 *      `FOUR-MEME-LAUNCH-ROUTE.md §8 gap 3` confirms that gap. Another agent is
 *      adding it. **These tests are written against the INTENDED behaviour**,
 *      with the floor implemented as `TestnetDexBase._passesLiquidityFloor` so
 *      the rule itself is executable today. When the real getter lands, point
 *      these assertions at it and delete the helper — the expectations do not
 *      change.
 *
 *      Why it is not optional (`§9.2`): a v3 pool seeded with **0.01 BNB** by a
 *      random EOA quoted 112,244 tokens for 1 BNB against 10,704,225 in the real
 *      four.meme v2 pool. **95× worse.** On the mint 20% leg that is real money,
 *      every mint, forever, silently — and the keeper cannot peg `minOut` around
 *      it, because the keeper would read the decoy and peg the floor TO the
 *      decoy. The `minOut` discipline alone does not save us.
 *
 *      The floor's two rules, both asserted below:
 *        - denominated in **WBNB**, never in BNBULL, because a decoy can print
 *          BNBULL freely and cannot print WBNB;
 *        - under the floor means **defer and accrue**, never "trade anyway with
 *          a bigger slippage tolerance".
 */
contract DecoyPoolFloorTest is TestnetDexBase {
    /// @notice The floor a launch-week keeper would actually publish. Anything
    ///         thinner than this much WBNB on the pool's WBNB side is not a
    ///         book, it is bait.
    uint256 internal constant MIN_POOL_WBNB = 1 ether;

    // ══════════════════════════════════════════════════════════════════════
    //  Pre-graduation: the pair exists and is worthless
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A dust pair created BEFORE graduation must be refused.
     *
     *         §6: a griefer can create the deterministic pair and donate WBNB to
     *         it, but can never seed BNBULL because the transfer gate blocks it.
     *         So the pool looks alive to a naive `getPair != 0` check while
     *         holding zero of the token — the exact shape a liveness test must
     *         not be fooled by.
     */
    function test_dustPairBeforeGraduationIsRefusedByTheFloor() public {
        MockBnbull token = _launchDefault(1 ether);

        vm.prank(griefer);
        address pair = factory.createPair(address(token), WBNB);
        _giveWbnb(pair, 0.01 ether);

        // ── What a NAIVE liveness check sees ──────────────────────────────
        assertTrue(_pair(address(token)) != address(0), "getPair answers: 'yes, there is a pool'");

        // ── What is actually in it ────────────────────────────────────────
        (uint256 tokenSide, uint256 wbnbSide) = _reserves(address(token));
        assertEq(tokenSide, 0, "zero BNBULL: the gate makes seeding impossible");
        assertEq(wbnbSide, 0, "and the donation is not even in reserves until a sync");

        // ── The floor refuses it. Defer and accrue. ───────────────────────
        assertFalse(
            _passesLiquidityFloor(address(token), MIN_POOL_WBNB),
            "a pool with no token side must never be traded against"
        );

        // The router agrees, loudly: it cannot even quote.
        vm.expectRevert();
        this.quote(address(token), 1 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Post-graduation: a REAL pool can still be a dust pool
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The measurable version. Two identical tokens — identical supply,
     *         identical curve, identical 20%-of-supply token side in the pool —
     *         one graduated on a proper raise, one on dust. Both pools are real
     *         PancakeSwap pairs running real constant-product maths. The ONLY
     *         difference is WBNB depth, which is exactly why `§9.2` says the
     *         floor must be denominated in WBNB.
     *
     * @dev ⚠ THE DIRECTION MATTERS, and getting it backwards is itself a trap
     *      worth writing down. A thin pool does not simply "quote a worse
     *      price": it quotes a *meaningless* one, and which way it hurts depends
     *      on which side is thin.
     *
     *        - **selling into it is a massacre**, because the WBNB side is the
     *          entire ceiling on what you can get out. That is the direction
     *          `PotSplitter`'s BNBULL -> WBNB leg uses;
     *        - **buying into it looks like a bargain** and is a trap of a
     *          different kind — one 0.5 BNB order eats essentially the whole
     *          token reserve, so the pot ends up holding a bag priced off a book
     *          that no longer exists.
     *
     *      Both are asserted. Either one on its own would let a floor be written
     *      that defends the wrong direction.
     */
    function test_aDustGraduatedPoolPricesNothingHonestly_andTheFloorRefusesIt() public {
        MockBnbull real = _launchDefault(10 ether);
        _graduate(real);

        MockBnbull dust = _launchDefault(0.001 ether);
        _graduate(dust);

        (uint256 realTokens, uint256 realWbnb) = _reserves(address(real));
        (uint256 dustTokens, uint256 dustWbnb) = _reserves(address(dust));
        assertEq(realWbnb, 9.8 ether);
        assertEq(dustWbnb, 0.00098 ether);
        assertEq(realTokens, dustTokens, "identical token side, wildly different price");

        // ── SELLING: the direction our pot leg actually uses ──────────────
        uint256 sell = 1e24;
        uint256 goodOut = _quoteTokenIn(address(real), sell);
        uint256 badOut = _quoteTokenIn(address(dust), sell);
        emit log_named_uint("WBNB for 1e24 BNBULL, real pool", goodOut);
        emit log_named_uint("WBNB for 1e24 BNBULL, dust pool", badOut);
        assertGt(goodOut, badOut * 1_000, "a sell into a dust pool is a massacre");

        // ── BUYING: no book left afterwards ──────────────────────────────
        uint256 badBuy = _quoteBnbIn(address(dust), 0.5 ether);
        assertGt(
            badBuy,
            (dustTokens * 99) / 100,
            "one order eats the entire reserve: there is no book here"
        );

        // ── The floor is the whole defence ────────────────────────────────
        assertTrue(_passesLiquidityFloor(address(real), MIN_POOL_WBNB), "the real book passes");
        assertFalse(_passesLiquidityFloor(address(dust), MIN_POOL_WBNB), "the dust pool is refused");
    }

    /**
     * @notice **The floor must be denominated in WBNB, never in BNBULL.**
     *         §9.2, stated as a rule; demonstrated here as an attack: a decoy
     *         can put an arbitrarily huge BNBULL side into a pool for free,
     *         because it is the side nobody has to buy. A floor that measured
     *         "is there a lot of BNBULL in here?" would wave it straight
     *         through, and the price would be worse, not better.
     */
    function test_theFloorMustNotBeDenominatedInBnbull() public {
        MockBnbull token = _launchDefault(0.001 ether);
        _graduate(token);

        // A whale dumps a huge BNBULL side into the pool and syncs it. Free.
        address pair = _pair(address(token));
        uint256 dumped = 1e26;
        vm.prank(alice);
        token.transfer(pair, dumped);
        IPairSync(pair).sync();

        (uint256 tokenSide, uint256 wbnbSide) = _reserves(address(token));
        assertGt(tokenSide, dumped, "an enormous BNBULL side, at no cost to anyone");
        assertLt(wbnbSide, MIN_POOL_WBNB, "and still almost no WBNB");

        // A BNBULL-denominated floor would pass this. The WBNB one refuses it.
        assertFalse(
            _passesLiquidityFloor(address(token), MIN_POOL_WBNB),
            "WBNB depth is the only honest measure of a pool"
        );
    }

    /**
     * @notice The floor is a *deferral* trigger, not a slippage dial. §9.2:
     *         "under the floor must mean defer and accrue, never trade anyway
     *         with a bigger slippage tolerance".
     * @dev Modelled here the way the never-fail splitters model it: a leg that
     *      fails its precondition leaves the money in a bucket, and the bucket
     *      is still spendable later — when the pool is real.
     */
    function test_underTheFloorTheLegDefersAndTheMoneyIsStillThere() public {
        MockBnbull token = _launchDefault(0.001 ether);
        _graduate(token);

        uint256 accrued = 0;
        uint256 slice = 0.25 ether;

        // Under the floor -> defer. Nothing is traded, nothing is lost.
        if (!_passesLiquidityFloor(address(token), MIN_POOL_WBNB)) accrued += slice;
        assertEq(accrued, slice, "the slice must accrue, not trade");

        // Someone deepens the pool for real.
        _giveWbnb(_pair(address(token)), 5 ether);
        IPairSync(_pair(address(token))).sync();

        assertTrue(_passesLiquidityFloor(address(token), MIN_POOL_WBNB), "now it is a book");
        uint256 out = _quoteBnbIn(address(token), accrued);
        assertGt(out, 0, "and the accrued slice can finally be spent");
    }

    /// @dev `external` so `vm.expectRevert` can catch a view that reverts.
    function quote(address token, uint256 bnbIn) external view returns (uint256) {
        return _quoteBnbIn(token, bnbIn);
    }

    /// @dev WBNB out for BNBULL in — the direction the pot's sell leg uses.
    function _quoteTokenIn(address token, uint256 amountIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;
        return router.getAmountsOut(amountIn, path)[1];
    }
}

interface IPairSync {
    function sync() external;
}
