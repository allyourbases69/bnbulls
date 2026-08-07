// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SplitterBase} from "./SplitterBase.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {MintBnbullSplitter} from "../contracts/MintBnbullSplitter.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {SplitterV2Router, SplitterHostilePot, FourMemeTaxedToken} from "./mocks/SplitterMocks.sol";

/**
 * @title PotSplitterVenueTest
 * @notice THE VENUE FIX AND THE LIQUIDITY FLOOR — `DECISIONS.md §28`, `§29`,
 *         `§30`.
 *
 * @dev The defect this file exists to keep fixed, stated plainly:
 *
 *        > four.meme graduates into PancakeSwap **V2** against WBNB and creates
 *        > **ZERO v3 pools at any tier**. The splitters were v3-only, so the
 *        > BNBULL pot leg could never reach the real book — and because the pad
 *        > never makes a v3 pool, **the only thing a v3 leg could ever find is
 *        > somebody else's decoy.** Measured on a fork: a v3 1% pool seeded
 *        > with 0.01 BNB quoted 112,244 tokens for 1 BNB against 10,704,225 in
 *        > the real v2 pool. **95x worse, silently, on every mint, forever.**
 *
 *      Four things are proved here and each of them is load-bearing on its own:
 *
 *        1. **the venue.** the swap is a v2 hop through the one canonical pair;
 *        2. **the call.** it is `…SupportingFeeOnTransferTokens`, so a taxed
 *           four.meme template B token does not revert `Pancake: K` (`§30`) —
 *           and the router mock's legacy selectors revert exactly that, so a
 *           regression is a red test rather than a mainnet surprise;
 *        3. **the floor.** a missing or dust pair DEFERS. Never trades, never
 *           reverts an entrypoint. This is `§29`'s "launch is BNB-first and the
 *           BNBULL legs accrue" written in code — the NORMAL launch state,
 *           tested as the normal case;
 *        4. **the measurement survives all of it.** a lying router still cannot
 *           overstate a swap, because the fee-supporting call returns nothing
 *           at all and the booked figure is `balanceOf` after minus before.
 */
contract PotSplitterVenueTest is SplitterBase {
    // ══════════════════════════════════════════════════════════════════════
    //  1. THE VENUE — v2, through the router's own factory
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The regression sentinel. `SplitterV2Router`'s legacy, NON
    ///      fee-supporting selectors revert `Pancake: K` while `taxedPair` is
    ///      on (the default), and count their entries. A swap that funds the
    ///      pot while `legacyCalls` stays 0 is proof of which call was made.
    function test_theSwapUsesTheFeeSupportingV2CallAndNeverTheLegacyOne() public {
        assertTrue(dex.taxedPair(), "the mock must assume the taxed template");

        _sendNative(address(mintSplit), 10 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "the v2 buy landed");
        assertEq(dex.swapCalls(), 1, "exactly one v2 hop");
        assertEq(dex.legacyCalls(), 0, "a NON-fee-supporting call was made; a taxed token reverts it");
    }

    /// @dev The deadline a v2 router needs. A zero or past deadline reverts
    ///      `EXPIRED` on the real thing, which would defer every buy forever.
    function test_theSwapPassesALiveDeadline() public {
        _sendNative(address(mintSplit), 10 ether);
        assertGe(dex.lastDeadline(), block.timestamp, "a stale deadline reverts EXPIRED on chain");
    }

    /**
     * @notice The factory is DERIVED FROM THE ROUTER, so the pool the floor is
     *         measured on cannot be a different pool from the one the swap
     *         hits.
     *
     * @dev A second factory wire is what makes the two able to disagree, and
     *      that disagreement IS the `BNB-CHAIN-FACTS.md §3` bug: on Stable a
     *      $50 dev buy priced through the pool that answered the lookup was
     *      published as $13.26 because the money was in a different pool.
     */
    function test_theFactoryComesFromTheRouterAndNotASecondWire() public view {
        (address pair, uint256 reserve) = mintSplit.wbnbPoolLiquidity();
        assertEq(pair, address(dex.v2Pair()), "the pair must come from router.factory()");
        assertEq(reserve, uint256(dex.HEALTHY_RESERVE()));
    }

    function test_thePoolLiquidityViewIsZeroWhileNothingIsWired() public {
        MintBnbullSplitter s = _bareMintSplitter();
        (address pair, uint256 reserve) = s.wbnbPoolLiquidity();
        assertEq(pair, address(0));
        assertEq(reserve, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE MINIMUM-LIQUIDITY FLOOR
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice **THE LAUNCH STATE, AND IT IS THE NORMAL CASE.** `DECISIONS.md
     *         §29`: BNBULL cannot participate in any game flow until four.meme's
     *         curve completes, so every BNBULL leg is expected to defer from
     *         day one. No pair means DEFER — never revert, never trade.
     */
    function test_noPairAtAllDefersAndNeverReverts() public {
        dex.setPairMissing(true);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(mintSplit));
        emit PotSplitter.BnbullPotDeferred(PotSplitter.PotSource.Native, 2 ether, 2 ether);
        (bool ok,) = address(mintSplit).call{value: 10 ether}("");

        assertTrue(ok, "the LP-slot call must never fail: every native mint depends on it");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "the slice is kept, not lost");
        assertEq(dex.swapCalls(), 0, "nothing may be traded into a pair that does not exist");
        assertEq(potBnb.pool(), 1 ether, "the wrap leg needs no pair and still lands");
    }

    /**
     * @notice THE DECOY, TO SCALE. A pair front-run into existence with 0.01
     *         WBNB quotes a price 95x worse than the real book. Without the
     *         floor the mint's 20% slice buys 1.05% of what it should, silently,
     *         on every mint, forever.
     *
     * @dev The keeper floor alone does NOT save us here, and that is the point
     *      worth spelling out: at launch the keeper has no honest price to peg
     *      to, so it would read the decoy and peg `minOut` TO the decoy. The
     *      rate here is deliberately set so the swap would CLEAR the published
     *      floor — the only thing that stops it is the reserve check.
     */
    function test_aDustPairIsRefusedEvenWhenTheSwapWouldClearTheKeepersFloor() public {
        // 0.01 WBNB of liquidity — the measured decoy.
        dex.setPairReserves(0.01 ether, 1e24);

        // ...and a rate generous enough that `minOut` is comfortably met, so
        // the ONLY thing that can defer this is the liquidity floor.
        dex.setRate(address(wbnb), address(bnbull), 100_000, 1);

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);

        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "the dust pair must defer");
        assertEq(dex.swapCalls(), 0, "the 95x trade must never be made");
        assertEq(potBnbull.pool(), 0);
    }

    /// @dev The boundary is INCLUSIVE: exactly at the floor is allowed, one wei
    ///      under is not. An off-by-one here is a leg that silently never fires.
    function test_theLiquidityBoundaryIsInclusive() public {
        dex.setPairReserves(uint112(mintSplit.minPoolLiquidity()), 1e24);
        _sendNative(address(mintSplit), 10 ether);
        assertEq(dex.swapCalls(), 1, "exactly at the floor must trade");

        dex.resetSwapCalls();
        dex.setPairReserves(uint112(mintSplit.minPoolLiquidity() - 1), 1e24);
        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "one wei under the floor must defer");
    }

    /// @dev The floor is read off the WBNB SIDE, whichever side that is. A
    ///      decoy can mint an unlimited supply of its own token; it cannot mint
    ///      BNB, which is why the BNBULL side is never the measure.
    function test_theFloorReadsTheWbnbSideNotTheTokenSide() public {
        // A pool stuffed with BNBULL and holding almost no WBNB. Reading the
        // wrong side would call this deep liquidity.
        dex.setPairReserves(0.001 ether, type(uint112).max);

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "the floor was read off the side a decoy can print");
    }

    /// @dev `token0()` is READ off the pair, never derived from address
    ///      ordering — so the reserves are still identified correctly when WBNB
    ///      is token1.
    function test_theReserveIsIdentifiedByToken0NotByAddressOrdering() public {
        // Flip the pair so WBNB is token1 and the reserves are swapped to match.
        dex.v2Pair().setTokens(address(bnbull), address(wbnb));
        dex.setPairReserves(type(uint112).max, 0.001 ether); // r0 = BNBULL, r1 = WBNB

        (, uint256 reserve) = mintSplit.wbnbPoolLiquidity();
        assertEq(reserve, 0.001 ether, "the WBNB side was misidentified");

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0, "a thin pool read as deep would be the whole bug again");
    }

    /**
     * @notice The KEEPER sweep is floored too, and there it is allowed to fail
     *         LOUDLY — a keeper draining the backlog into a dust pair is the
     *         same 95x loss in one large transaction instead of many small ones.
     */
    function test_theSweepRefusesAThinPoolLoudly() public {
        dex.setPairMissing(true);
        _sendNative(address(mintSplit), 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether);

        // The pair appears, but with dust in it.
        dex.setPairMissing(false);
        dex.setPairReserves(0.01 ether, 1e24);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PotSplitter.PoolTooThin.selector, 0.01 ether, 1 ether)
        );
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether));

        // And once the pool is real, the same backlog clears.
        dex.setPairReserves(20 ether, 1e24);
        vm.prank(keeper);
        uint256 funded = mintSplit.sweepBnbullPot(
            PotSplitter.PotSource.Native, 0, _bnbullFromBnb(2 ether)
        );
        assertEq(funded, _bnbullFromBnb(2 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), 0, "the backlog cleared once the pool was real");
    }

    /// @dev The whole curve phase, then graduation: accrue, accrue, accrue,
    ///      then sweep. `DECISIONS.md §29` end to end.
    function test_theCurvePhaseAccruesAndGraduationClearsTheBacklog() public {
        dex.setPairMissing(true); // pre-graduation: no pair exists

        _sendNative(address(mintSplit), 10 ether);
        _sendNative(address(mintSplit), 10 ether);
        _sendNative(address(mintSplit), 10 ether);
        assertEq(mintSplit.pendingBnbullBuyNative(), 6 ether, "three mints' worth, all kept");
        assertEq(potBnb.pool(), 3 ether, "the BNB pot never depended on the curve");

        // Graduation: the pad creates the pair with 17.64 WBNB against
        // 200,000,000 tokens — the figure measured on three fork graduations.
        dex.setPairMissing(false);
        dex.setPairReserves(17.64 ether, 200_000_000e18);

        vm.prank(keeper);
        mintSplit.sweepBnbullPot(PotSplitter.PotSource.Native, 0, _bnbullFromBnb(6 ether));
        assertEq(mintSplit.pendingBnbullBuyNative(), 0);
        assertEq(potBnbull.pool(), _bnbullFromBnb(6 ether), "the whole backlog bought in");
    }

    /// @dev Raising the floor above a live pool defers rather than reverting —
    ///      the owner cannot brick the game with a fat finger, only slow it.
    function test_raisingTheFloorAboveTheLivePoolOnlyDefers() public {
        dex.setPairReserves(5 ether, 1e24);
        mintSplit.setMinPoolLiquidity(mintSplit.MAX_MIN_POOL_LIQUIDITY());

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);
        assertEq(dex.swapCalls(), 0);
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "nothing lost, only deferred");
    }

    /// @dev A router with no `factory()` at all — a mis-wire, or a v3 router
    ///      left in the slot by an old script. It must DEFER, not brick.
    function test_aRouterThatCannotAnswerFactoryDefersRatherThanBricking() public {
        MintBnbullSplitter s = _bareMintSplitter();
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
        // A contract that is emphatically not a v2 router.
        s.bootstrapWire(PotSplitter.Wire.Router, address(potBnbull));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(potBnbull));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(s), true);
        potBnb.setFunder(address(s), true);
        _publishFloors(s);

        _sendNative(address(s), 10 ether);
        assertEq(s.pendingBnbullBuyNative(), 2 ether, "a mis-wired router defers");
        assertEq(potBnb.pool(), 1 ether, "the wrap leg is untouched by a bad router");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. A TAXED four.meme TEMPLATE B TOKEN
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `DECISIONS.md §30`: template B carries a creator-set buy AND sell
     *         tax, measured at -10%. The fee-supporting call is what makes the
     *         swap possible at all; the measured delta is what keeps the pot
     *         honest about what actually arrived.
     *
     * @dev The keeper's floor has to be pegged NET OF THE TAX, and this is the
     *      test that says so out loud. A floor pegged to the gross price is one
     *      the post-tax delta cannot meet, and every buy defers — safe, and
     *      money is never lost, but the leg quietly stops working.
     */
    function test_aTaxedTokenIsBoughtOnWhatActuallyArrived() public {
        (MintBnbullSplitter s, FourMemeTaxedToken bull, SplitterV2Router r, Jackpot pot) =
            _taxedWorld(1_000); // 10% buy tax

        // The keeper pegs its floor NET of the 10% tax, with 1% of headroom.
        vm.prank(keeper);
        s.setFloors((60_000e18 * 90 * 99) / (100 * 100), 1);

        _sendNative(address(s), 10 ether);

        uint256 gross = _bnbullFromBnb(2 ether);
        uint256 net = (gross * 90) / 100;
        assertEq(pot.pool(), net, "the pot was funded with the POST-TAX amount");
        assertEq(r.swapCalls(), 1);
        assertEq(r.legacyCalls(), 0, "the taxed token would have reverted `Pancake: K`");
        assertEq(bull.balanceOf(address(s)), 0, "no orphan tokens left behind");
    }

    /**
     * @notice ⚠ THE OTHER HALF OF `§30`, AND IT IS AN OPERATIONAL TRAP.
     *         A floor pegged to the GROSS price on a taxed token defers every
     *         single buy. Nothing is lost — but the leg is dead until somebody
     *         notices, and the only thing that says so is the `…Deferred` event.
     */
    function test_aTaxedTokenWithAGrossPeggedFloorDefersEveryBuy() public {
        (MintBnbullSplitter s,,, Jackpot pot) = _taxedWorld(1_000);

        // The keeper pegs to the untaxed price, 1% under market — the natural
        // mistake, because that is exactly what it does for an untaxed token.
        vm.prank(keeper);
        s.setFloors(FLOOR_BNBULL_PER_BNB, 1);

        _sendNativeAndAssertNothingLost(s, 10 ether);
        assertEq(pot.pool(), 0, "a 10% tax against 1% headroom cannot clear");
        assertEq(s.pendingBnbullBuyNative(), 2 ether, "deferred, not lost");
    }

    /// @dev The legacy selector is what a taxed pair reverts. Proving the mock
    ///      really does it keeps the sentinel above honest.
    function test_theLegacySelectorRevertsPancakeKOnATaxedPair() public {
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(bnbull);

        vm.expectRevert("Pancake: K");
        dex.swapExactTokensForTokens(1 ether, 0, path, address(this), block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. A LYING ROUTER STILL CANNOT WEDGE OR OVERSTATE A SWAP
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The fee-supporting call RETURNS NOTHING, so there is no reported
     *         output left for a router to overstate. The only lie available is
     *         under-delivery, and the measured delta catches that.
     */
    function test_aLyingRouterCannotFundThePotWithAlmostNothing() public {
        dex.setLying(100); // deliver 1% of the honest figure

        _sendNativeAndAssertNothingLost(mintSplit, 10 ether);

        assertEq(potBnbull.pool(), 0, "1% of the quote must never be booked as the buy");
        assertEq(mintSplit.pendingBnbullBuyNative(), 2 ether, "the whole slice deferred");
        assertEq(bnbull.balanceOf(address(mintSplit)), 0, "the caught swap rolled back cleanly");
    }

    /// @dev The other half: a router that DELIVERS MORE than the floor is
    ///      booked at what it actually delivered, not at the floor and not at
    ///      any number it reported.
    function test_theBookedFigureIsTheMeasuredDeltaAndNothingElse() public {
        dex.setRate(address(wbnb), address(bnbull), 120_000, 1); // 2x the market

        _sendNative(address(mintSplit), 10 ether);

        assertEq(potBnbull.pool(), 2 ether * 120_000, "the pot books what arrived, not the floor");
        assertGt(potBnbull.pool(), dex.lastMinOut(), "and the surplus is not thrown away");
    }

    /// @dev A router that reports a huge `amounts[]` on the LEGACY selector
    ///      cannot influence anything, because that selector is never called.
    function test_anOverreportingRouterHasNoSurfaceToLieOn() public {
        dex.setOverreport(1_000_000); // claim 100x on the legacy path
        _sendNative(address(mintSplit), 10 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "the honest, measured figure");
        assertEq(dex.legacyCalls(), 0, "the only path that reports anything was never taken");
    }

    /// @dev And a router that enforces the floor honestly — the real thing —
    ///      still works, so the contract is not accidentally depending on a
    ///      permissive mock.
    function test_anHonestlyEnforcingRouterStillCompletesTheBuy() public {
        dex.setEnforceMinOut(true);
        _sendNative(address(mintSplit), 10 ether);
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    function _sendNative(address to, uint256 amount) internal {
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        (bool ok,) = to.call{value: amount}("");
        assertTrue(ok, "a never-fail entrypoint reverted");
    }

    /// @dev Send, then prove conservation: every wei either reached a pot or is
    ///      sitting here backed by a bucket. Nothing evaporates.
    function _sendNativeAndAssertNothingLost(MintBnbullSplitter s, uint256 amount) internal {
        uint256 balBefore = address(s).balance;
        uint256 wrappedBefore = potBnb.pool();

        _sendNative(address(s), amount);

        uint256 wrappedAway = potBnb.pool() - wrappedBefore;
        assertEq(
            address(s).balance,
            balBefore + amount - wrappedAway,
            "value left the splitter without reaching a pot"
        );
        assertGe(
            address(s).balance,
            s.reservedOf(PotSplitter.PotSource.Native),
            "a bucket is not actually backed by balance"
        );
    }

    /**
     * @dev A whole world running on a four.meme **template B** token: a
     *      creator-set tax that bites only on transfers touching the pair, and
     *      a router that reverts `Pancake: K` on any non-fee-supporting call —
     *      exactly the two behaviours measured on chain.
     */
    function _taxedWorld(uint256 buyTaxBps)
        private
        returns (MintBnbullSplitter s, FourMemeTaxedToken bull, SplitterV2Router r, Jackpot pot)
    {
        bull = new FourMemeTaxedToken("TaxBull", "TBULL", 18);
        r = new SplitterV2Router(address(wbnb));
        r.setRate(address(wbnb), address(bull), 60_000, 1);
        r.setRate(address(bull), address(wbnb), 1, 60_000);
        // The router mock stands in for the pair, so it is what the tax bites on.
        bull.setPair(address(r));
        bull.setTax(buyTaxBps, buyTaxBps);
        bull.mint(address(r), 1e30);

        pot = new Jackpot(address(bull), address(0), address(coord), 50);

        s = new MintBnbullSplitter(owner, address(wbnb), keeper);
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bull));
        s.bootstrapWire(PotSplitter.Wire.Router, address(r));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(pot));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        pot.setFunder(address(s), true);
        potBnb.setFunder(address(s), true);
    }
}
