// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestnetDexBase, IPancakePairV2} from "./TestnetDexBase.t.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

/**
 * @title GraduationLiquidityTest
 * @notice Graduation into a **GENUINE** PancakeSwap v2 pair, created by the
 *         REAL chain-97 factory, seeded with real liquidity, LP burned.
 *
 * @dev `FOUR-MEME-LAUNCH-ROUTE.md §5`, verified by executing three complete
 *      graduations on mainnet forks (Gort, BEAU, PUPP) and by reading two
 *      already-graduated mainnet tokens:
 *
 *        venue            PancakeSwap **V2**; zero v3 pools at any tier
 *        quote asset      WBNB
 *        opening reserves 17.64 WBNB / 200,000,000 tokens from an 18 BNB raise
 *                         (98% of the raise, 20% of supply) — identical on all
 *                         three fork graduations
 *        LP disposition   BURNED. total 59,396.969616568150296050, at DEAD
 *                         …295050 — the 1000-wei difference is uniswap's
 *                         MINIMUM_LIQUIDITY at address(0)
 *        who can pull it  **nobody**
 *
 *      Every number below is reproduced against that measurement, and the pair
 *      is a real `PancakePair` deployed by the real factory's own CREATE2 — not
 *      something this repo wrote.
 */
contract GraduationLiquidityTest is TestnetDexBase {
    /// @notice The shape §5 measured, to the wei.
    function test_graduationReproducesTheMeasuredOpeningShape() public {
        FourMemeMock.LaunchParams memory p = _params(18 ether, 10, true);
        MockBnbull token = _launch(p);

        uint256 founderBefore = creator.balance;

        // 19.98 BNB gross moves the curve by 18 (111 to move 100). Overpay; the
        // pad caps at the threshold and refunds the rest.
        _curveBuy(token, alice, 25 ether, 0);

        assertEq(pad.statusOf(address(token)), pad.STATUS_COMPLETED(), "status must be 3");

        address pair = _pair(address(token));
        assertTrue(pair != address(0), "the v2 pair must exist");
        assertEq(pair, _create2Pair(address(token)), "must be the deterministic factory pair");

        (uint256 tokenSide, uint256 wbnbSide) = _reserves(address(token));
        assertEq(wbnbSide, 17.64 ether, "98% of an 18 BNB raise, exactly as measured");
        assertEq(tokenSide, 2e26, "200,000,000 tokens = 20% of supply");

        // ── LP is BURNED. Nobody can pull it. ─────────────────────────────
        IPancakePairV2 lp = IPancakePairV2(pair);
        assertEq(
            lp.totalSupply() - lp.balanceOf(DEAD),
            MINIMUM_LIQUIDITY,
            "everything except uniswap's 1000-wei MINIMUM_LIQUIDITY goes to DEAD"
        );
        assertEq(lp.balanceOf(address(0)), MINIMUM_LIQUIDITY, "the 1000 sits at address(0)");
        assertEq(lp.balanceOf(address(pad)), 0, "nothing at the pad");
        assertEq(lp.balanceOf(address(token)), 0, "nothing at the token");
        assertEq(lp.balanceOf(creator), 0, "nothing at the founder");

        // ── What the creator keeps: feeRateBuy% of the raise, as measured on
        //    Gort (1.8 BNB out of 18). ────────────────────────────────────
        assertEq(creator.balance - founderBefore, 1.8 ether, "founder takes exactly 10%");
        // ── What the pad retains: the other 2% of the raise. ──────────────
        assertEq(address(pad).balance, 0.36 ether, "the pad keeps 2% of the raise");
    }

    /// @notice §6: v2 `getPair` is a single deterministic address per token
    ///         pair, so there is no "which v2 pair is real" ambiguity at all —
    ///         the stable/fefers decoy came from v2-vs-v3 divergence, not from
    ///         two v2 pairs.
    function test_thePairAddressIsDeterministicAndUnique() public {
        MockBnbull token = _launchDefault(0.05 ether);
        address predicted = _create2Pair(address(token));
        assertEq(_pair(address(token)), address(0), "no pair before graduation");
        _graduate(token);
        assertEq(_pair(address(token)), predicted);
        assertEq(factory.getPair(WBNB, address(token)), predicted, "order-independent");
    }

    /// @notice After graduation the pool is a working book: a real router buy
    ///         out of it moves the price the way constant product says it must.
    function test_theGraduatedPoolIsARealTradeableBook() public {
        MockBnbull token = _launchDefault(1 ether);
        _graduate(token);

        uint256 q1 = _quoteBnbIn(address(token), 0.1 ether);
        assertGt(q1, 0);

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(token);
        vm.deal(bob, 1 ether);
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        router.swapExactETHForTokens{value: 0.1 ether}(q1, path, bob, block.timestamp);
        assertEq(token.balanceOf(bob) - before, q1, "the real router delivers the real quote");

        // Price moved against the next buyer. Constant product, not a mock.
        assertLt(_quoteBnbIn(address(token), 0.1 ether), q1, "the curve of the pool must move");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Template A — the keeper dependency (DECISIONS §30)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice §4, reproduced on PUPP and on a clean control fork: the curve
     *         fills, the token goes to `STATUS_ADDING_LIQUIDITY` **and stays
     *         there** — no pair, `_mode` still 1, `owner()` still the pad. **The
     *         token is fully transfer-locked with the curve closed**, and the
     *         whole game stays frozen for as long as four.meme's keeper takes.
     */
    function test_templateA_stallsTransferLockedWithTheCurveClosed() public {
        MockBnbull token = _launch(_params(0.05 ether, 0, false));
        _curveBuy(token, alice, 1 ether, 0);

        assertEq(
            pad.statusOf(address(token)),
            pad.STATUS_ADDING_LIQUIDITY(),
            "template A parks at status 2"
        );
        assertEq(_pair(address(token)), address(0), "no pancakeswap pair yet");
        assertEq(token._mode(), token.MODE_TRANSFER_RESTRICTED(), "still transfer-locked");
        assertEq(token.owner(), address(pad), "still owned by the pad");

        // The curve is CLOSED: further buys fail.
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(FourMemeMock.Disabled.selector);
        pad.buyTokenAMAP{value: 0.01 ether}(address(token), 0.01 ether, 0);

        // And nothing can move. This is the frozen-game window.
        vm.prank(alice);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        token.transfer(bob, 1);
    }

    /// @notice §4: it only completes when a `ROLE_OPERATOR` calls
    ///         `addLiquidity(address)`. A random EOA is refused.
    function test_templateA_onlyAnOperatorCanFinishIt() public {
        MockBnbull token = _launch(_params(0.05 ether, 0, false));
        _curveBuy(token, alice, 1 ether, 0);

        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(FourMemeMock.MissingOperatorRole.selector, griefer));
        pad.addLiquidity(address(token));

        vm.prank(fourMemeOperator);
        pad.addLiquidity(address(token));

        assertEq(pad.statusOf(address(token)), pad.STATUS_COMPLETED());
        assertEq(token._mode(), token.MODE_NORMAL());
        assertEq(token.owner(), address(0));
        (uint256 tokenSide, uint256 wbnbSide) = _reserves(address(token));
        assertEq(tokenSide, 2e26);
        assertEq(wbnbSide, (0.05 ether * 9_800) / 10_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The griefer (route §6)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice §6: anyone can permissionlessly `createPair(BNBULL, WBNB)` before
     *         graduation — **but they cannot put BNBULL into it**, because
     *         seeding reverts on the transfer gate. So no pre-graduation pool
     *         can ever hold a token balance, quote a price, or be traded
     *         against. Verified from a random EOA on a fork; reproduced here
     *         against the real factory.
     */
    function test_griefer_canCreateThePairButCanNeverSeedIt() public {
        MockBnbull token = _launchDefault(1 ether);
        _curveBuy(token, griefer, 0.1 ether, 0);

        vm.prank(griefer);
        address pair = factory.createPair(address(token), WBNB);
        assertEq(pair, _create2Pair(address(token)));

        // The pair EXISTS. `getPair != 0` is therefore not evidence of anything.
        assertTrue(_pair(address(token)) != address(0));

        // ...and it can never be seeded.
        vm.prank(griefer);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        token.transfer(pair, 1e18);

        (uint256 tokenSide,) = _reserves(address(token));
        assertEq(tokenSide, 0, "a pre-graduation pair holds zero BNBULL, always");
    }

    /// @notice §6: a griefer CAN donate WBNB to the deterministic future pair.
    ///         It does not break graduation; it only nudges the opening price,
    ///         at the griefer's own expense, because the donation is burned with
    ///         the LP.
    function test_griefer_wbnbDonationDoesNotBreakGraduation() public {
        MockBnbull token = _launchDefault(1 ether);

        vm.prank(griefer);
        address pair = factory.createPair(address(token), WBNB);
        _giveWbnb(pair, 1 ether);

        _graduate(token);

        assertEq(_pair(address(token)), pair, "graduation must REUSE the pre-created pair");
        (uint256 tokenSide, uint256 wbnbSide) = _reserves(address(token));
        assertEq(tokenSide, 2e26);
        assertEq(wbnbSide, 0.98 ether + 1 ether, "the donation is simply in the pool");

        IPancakePairV2 lp = IPancakePairV2(pair);
        assertEq(lp.totalSupply() - lp.balanceOf(DEAD), MINIMUM_LIQUIDITY, "LP still burned");
        assertEq(lp.balanceOf(griefer), 0, "the griefer gets nothing back");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev The uniswap-v2 CREATE2 address, computed from the factory's OWN
    ///      `INIT_CODE_PAIR_HASH`. If this matches, the pair is genuinely the
    ///      factory's.
    function _create2Pair(address token) internal pure returns (address) {
        (address t0, address t1) = token < WBNB ? (token, WBNB) : (WBNB, token);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V2_FACTORY,
                            keccak256(abi.encodePacked(t0, t1)),
                            INIT_CODE_PAIR_HASH
                        )
                    )
                )
            )
        );
    }

    function _params(uint256 maxRaising, uint256 feeRateBuy, bool atomic)
        internal
        view
        returns (FourMemeMock.LaunchParams memory)
    {
        return FourMemeMock.LaunchParams({
            name: "BNBull",
            symbol: "BNBULL",
            decimals: 18,
            totalSupply: SUPPLY_18DP,
            maxOffers: (SUPPLY_18DP * CURVE_SHARE_BPS) / 10_000,
            maxRaising: maxRaising,
            quote: address(0),
            founder: creator,
            feeRateBuy: feeRateBuy,
            feeRateSell: 0,
            rateFounder: 100,
            taxEnabled: false,
            atomicGraduation: atomic
        });
    }
}
