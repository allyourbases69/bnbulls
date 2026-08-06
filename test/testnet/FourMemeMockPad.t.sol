// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestnetDexBase} from "./TestnetDexBase.t.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

/**
 * @title FourMemeMockPadTest
 * @notice The pad's own behaviours: the curve buy, its cost shape, its floor,
 *         its refund, its failure modes, and the two doors that are nailed shut.
 *
 * @dev Every assertion here is anchored to a specific measurement in
 *      `FOUR-MEME-LAUNCH-ROUTE.md`. Where the rehearsal deviates from the real
 *      pad the test says so in its own name or comment rather than quietly
 *      passing.
 */
contract FourMemeMockPadTest is TestnetDexBase {
    /// @notice The selector §3 resolved for the curve buy.
    bytes4 internal constant SEL_BUY_AMAP_3 = 0x87f27655;
    /// @notice The 4-argument overload with an explicit recipient.
    bytes4 internal constant SEL_BUY_AMAP_4 = 0x7f79f6df;

    // ══════════════════════════════════════════════════════════════════════
    //  The rig itself
    // ══════════════════════════════════════════════════════════════════════

    /// @notice If the real DEX were not really there, every other test in this
    ///         directory would be theatre. Prove it first.
    function test_realDexIsWiredToItself() public view {
        // The factory is read OFF THE ROUTER, exactly as §1 established the
        // mainnet one. A mismatch here means a bad address, not a bad test.
        assertEq(router.factory(), V2_FACTORY, "router.factory()");
        assertEq(router.WETH(), WBNB, "router.WETH()");
        assertEq(factory.INIT_CODE_PAIR_HASH(), INIT_CODE_PAIR_HASH, "init code hash");
        // ⚠ READ, never assumed — the same rule the money layer applies to
        //   BNBULL's decimals.
        assertEq(wbnb.decimals(), 18, "WBNB decimals");
        assertEq(wbnb.symbol(), "WBNB", "WBNB symbol");
        assertEq(block.chainid, 97, "rehearsal must think it is on chain 97");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Creation
    // ══════════════════════════════════════════════════════════════════════

    /// @notice §3: the pad holds the whole float at creation — 999,999,720.6 of
    ///         a 1e27 supply on Gort. The curve phase is custodial.
    function test_padHoldsTheWholeFloatAtCreation() public {
        MockBnbull token = _launchDefault(1 ether);
        assertEq(token.totalSupply(), SUPPLY_18DP);
        assertEq(token.balanceOf(address(pad)), SUPPLY_18DP, "pad must hold everything");
        assertEq(token.owner(), address(pad), "pad must own the token");
        assertEq(token._mode(), token.MODE_TRANSFER_RESTRICTED(), "_mode() must be 1");
    }

    /// @notice §3: the struct decodes as (base, quote, config, totalSupply,
    ///         maxOffers, maxRaising, launchTime, offers, funds, lastPrice, K,
    ///         T, status), with `quote == address(0)` meaning NATIVE BNB.
    function test_tokenInfosShapeMatchesTheDecodedStruct() public {
        MockBnbull token = _launchDefault(18 ether);
        FourMemeMock.TokenInfo memory i = pad._tokenInfos(address(token));

        assertEq(i.base, address(token));
        assertEq(i.quote, address(0), "template 0: native BNB");
        assertEq(i.totalSupply, SUPPLY_18DP);
        assertEq(i.maxOffers, 8e26, "80% on the curve, as measured on Gort");
        assertEq(i.maxRaising, 18 ether, "the graduation threshold Gort carried");
        assertEq(i.offers, 8e26);
        assertEq(i.funds, 0);
        assertEq(i.status, pad.STATUS_TRADING());
        assertEq(pad.STATUS_TRADING(), 0);
        assertEq(pad.STATUS_HALT(), 1);
        assertEq(pad.STATUS_ADDING_LIQUIDITY(), 2);
        assertEq(pad.STATUS_COMPLETED(), 3);
    }

    /**
     * @notice `createToken(bytes,bytes)` is not permissionless and never will
     *         be. §3: the request is signed, single-use and time-limited by
     *         four.meme's backend; replaying reverts `RequestTracing: executed
     *         request` and mutating the id reverts `Expired`.
     *
     *         **The launch cannot be driven from a foundry script.** This test
     *         exists so nobody rediscovers that on launch day.
     */
    function test_createTokenIsNotPermissionless() public {
        vm.expectRevert(FourMemeMock.Expired.selector);
        pad.createToken(hex"deadbeef", hex"c0ffee");
    }

    /// @notice `DECISIONS.md §30`: 19 of the 20 live templates graduate into a
    ///         NON-BNB pool, which kills the money layer with no contract fix.
    ///         This rig refuses to model one — the refusal IS the warning.
    function test_nonNativeQuoteIsRefused() public {
        FourMemeMock.LaunchParams memory p = _defaultParams(1 ether);
        p.quote = address(0xCA4E); // "CAKE"
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(FourMemeMock.NonNativeQuoteUnsupported.selector, address(0xCA4E))
        );
        pad.launch(p);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The curve buy
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The live selector, payable in native BNB, **returning nothing**.
     * @dev §3: "does it return the amount out? NO. the only way to know the
     *      amount is a `balanceOf` delta." Proven here with a raw call so the
     *      empty return is an assertion, not an assumption.
     */
    function test_buyTokenAMAP_liveSelector_payable_returnsNothing() public {
        MockBnbull token = _launchDefault(1 ether);
        assertEq(
            SEL_BUY_AMAP_3,
            bytes4(keccak256("buyTokenAMAP(address,uint256,uint256)")),
            "selector drift"
        );
        assertEq(
            SEL_BUY_AMAP_4,
            bytes4(keccak256("buyTokenAMAP(address,address,uint256,uint256)")),
            "overload selector drift"
        );

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(pad).call{value: 0.1 ether}(
            abi.encodeWithSelector(SEL_BUY_AMAP_3, address(token), uint256(0.1 ether), uint256(0))
        );
        assertTrue(ok, "the live selector must be the callable one");
        assertEq(ret.length, 0, "buyTokenAMAP returns NOTHING - measure a balanceOf delta");
        assertGt(token.balanceOf(alice), 0, "tokens land with msg.sender");
    }

    /// @notice The 4-argument overload delivers to an explicit recipient.
    function test_buyTokenAMAP_recipientOverload() public {
        MockBnbull token = _launchDefault(1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        pad.buyTokenAMAP{value: 0.1 ether}(address(token), bob, 0.1 ether, 0);
        assertEq(token.balanceOf(alice), 0);
        assertGt(token.balanceOf(bob), 0);
    }

    /**
     * @notice **You pay 111 to move the curve by 100.**
     * @dev The exact split §3 measured off a real 0.1 BNB receipt on Gort:
     *        curve     0.090090090090 BNB   (90.0901%)
     *        founder   0.009009009009 BNB   ( 9.0090%)
     *        pad fee   0.000855855856 BNB   ( 0.8559%)
     *        referral  0.000045045045 BNB   ( 0.0450%)
     *      with `_tradingFeeRate = 100`, `_referralRewardRate = 5`,
     *      `feeRateBuy = 10`.
     */
    function test_costShape_pay111ToMoveTheCurveBy100() public {
        FourMemeMock.LaunchParams memory p = _defaultParams(18 ether);
        p.feeRateBuy = 10; // the rate Gort carried
        MockBnbull token = _launch(p);

        uint256 padBefore = padFeeRecipient.balance;
        uint256 refBefore = referralKeeper.balance;

        _curveBuy(token, alice, 0.1 ether, 0);

        assertEq(pad.fundsOf(address(token)), 90_090_090_090_090_090, "curve leg");
        assertEq(pad.founderAccrued(address(token)), 9_009_009_009_009_009, "founder leg");
        assertEq(padFeeRecipient.balance - padBefore, 855_855_855_855_855, "pad fee leg");
        assertEq(referralKeeper.balance - refBefore, 45_045_045_045_045, "referral leg");

        // 111 in, 100 onto the curve, to the wei.
        assertEq((pad.fundsOf(address(token)) * 111) / 100, 99_999_999_999_999_999);
    }

    /// @notice With `feeRateBuy = 0` — the `§9.4` target — the 9% founder leg
    ///         disappears entirely and a buyer pays 101 to move the curve by 100.
    function test_costShape_withZeroFounderFee() public {
        MockBnbull token = _launchDefault(18 ether);
        _curveBuy(token, alice, 0.1 ether, 0);
        assertEq(pad.founderAccrued(address(token)), 0, "no founder leg at feeRateBuy = 0");
        // 0.1 / 1.01
        assertEq(pad.fundsOf(address(token)), 99_009_900_990_099_009);
    }

    /// @notice §3: `minAmount` is a hard floor and reverts **`Slippage`**. There
    ///         is never an excuse for a blind buy.
    function test_slippageFloorIsReal() public {
        MockBnbull token = _launchDefault(1 ether);
        uint256 quoted = pad.calcBuyAmount(address(token), 0.1 ether);
        assertGt(quoted, 0);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(FourMemeMock.Slippage.selector);
        pad.buyTokenAMAP{value: 0.1 ether}(address(token), 0.1 ether, quoted + 1);
    }

    /// @notice The off-chain quote must equal the measured delta, or a
    ///         keeper-pegged `minAmount` would be a guess. §9.1 requires
    ///         `calcBuyAmount` to be usable for exactly this.
    function test_calcBuyAmountMatchesTheMeasuredDelta() public {
        MockBnbull token = _launchDefault(5 ether);
        uint256 quoted = pad.calcBuyAmount(address(token), 0.25 ether);
        uint256 delivered = _curveBuy(token, alice, 0.25 ether, quoted);
        assertEq(delivered, quoted, "quote and delta must agree");
    }

    /// @notice §3: overpayment is refunded. Sent 0.5 with funds 0.1, net spend
    ///         was 0.1 plus gas.
    function test_overpaymentIsRefunded() public {
        MockBnbull token = _launchDefault(18 ether);
        vm.deal(alice, 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        pad.buyTokenAMAP{value: 0.5 ether}(address(token), 0.1 ether, 0);
        uint256 spent = before - alice.balance;
        assertApproxEqAbs(spent, 0.1 ether, 10, "the excess must come back");
    }

    /**
     * @notice §3, proven twice on chain: **a contract can buy on the curve.** No
     *         EOA gate, no `tx.origin == msg.sender`, no signature, no referral.
     */
    function test_aContractCanBuy_noEoaGate_noSignature() public {
        MockBnbull token = _launchDefault(1 ether);
        ContractBuyer buyer = new ContractBuyer(address(pad));
        vm.deal(address(buyer), 1 ether);

        uint256 delivered = buyer.buy(address(token), 0.1 ether, 0);
        assertGt(delivered, 0, "a contract must be able to buy");
        assertEq(token.balanceOf(address(buyer)), delivered, "tokens land with the contract");
        assertTrue(tx.origin != address(buyer));
    }

    /**
     * @notice **THE LIVE FOOTGUN (§9.1).** A contract caller with no payable
     *         fallback reverts on the refund. Better to trip on it here than on
     *         chain 56.
     */
    function test_refundBricksACallerWithNoPayableFallback() public {
        MockBnbull token = _launchDefault(18 ether);
        NoFallbackBuyer buyer = new NoFallbackBuyer(address(pad));
        vm.deal(address(buyer), 1 ether);

        // msg.value 0.5, funds 0.1 — 0.4 comes back and there is nowhere to
        // put it.
        vm.expectRevert(FourMemeMock.RefundFailed.selector);
        buyer.buy(address(token), 0.5 ether, 0.1 ether, 0);
    }

    /// @notice ...and it does NOT trip when `funds == msg.value`, which is the
    ///         shape `§9.1` tells the integration to use.
    function test_noRefundWhenFundsEqualsMsgValue() public {
        MockBnbull token = _launchDefault(18 ether);
        NoFallbackBuyer buyer = new NoFallbackBuyer(address(pad));
        vm.deal(address(buyer), 1 ether);
        // 1 wei of rounding dust is still a refund, so the exact-spend case is
        // asserted through the pad's own arithmetic: fee-free config, no dust.
        vm.prank(padOwner);
        pad.setTradingFeeRate(0);
        vm.prank(padOwner);
        pad.setReferralRewardRate(0);
        buyer.buy(address(token), 0.1 ether, 0.1 ether, 0);
        assertGt(token.balanceOf(address(buyer)), 0);
    }

    /// @notice §3: after graduation the call **reverts `Disabled`**. It does not
    ///         merely stop being useful — a venue switch must be state-driven.
    function test_buyRevertsDisabledAfterGraduation() public {
        MockBnbull token = _launchDefault(0.05 ether);
        _graduate(token);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(FourMemeMock.Disabled.selector);
        pad.buyTokenAMAP{value: 0.01 ether}(address(token), 0.01 ether, 0);
    }

    /// @notice `curveOpen` is the state read a venue switch should key off.
    function test_curveOpenFlipsWithStatus() public {
        MockBnbull token = _launchDefault(0.05 ether);
        assertTrue(pad.curveOpen(address(token)));
        _graduate(token);
        assertFalse(pad.curveOpen(address(token)));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  four.meme's hand on the switch
    // ══════════════════════════════════════════════════════════════════════

    /// @notice §2: `suspendTrading` and the global `_tradingHalt()` are gated to
    ///         `ROLE_OPERATOR`. **four.meme can freeze our curve.**
    function test_operatorCanFreezeOurCurve() public {
        MockBnbull token = _launchDefault(18 ether);

        vm.prank(fourMemeOperator);
        pad.suspendTrading(address(token), true);
        assertFalse(pad.curveOpen(address(token)));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(FourMemeMock.TradingHalted.selector);
        pad.buyTokenAMAP{value: 0.1 ether}(address(token), 0.1 ether, 0);

        vm.prank(fourMemeOperator);
        pad.suspendTrading(address(token), false);
        assertGt(_curveBuy(token, alice, 0.1 ether, 0), 0);

        vm.prank(fourMemeOperator);
        pad.setTradingHalt(true);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(FourMemeMock.TradingHalted.selector);
        pad.buyTokenAMAP{value: 0.1 ether}(address(token), 0.1 ether, 0);
    }

    /// @notice A random caller is not an operator. §2 measured
    ///         `BasicAccessControl: … missing role ROLE_OPERATOR` on the live
    ///         pad; the shape, not the string, is what matters here.
    function test_randomCallerHasNoOperatorRole() public {
        MockBnbull token = _launchDefault(18 ether);
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(FourMemeMock.MissingOperatorRole.selector, griefer));
        pad.suspendTrading(address(token), true);
    }

    /// @notice The role hash the launch-week `RoleGranted` sweep will use (§7).
    function test_operatorRoleHashMatchesTheLivePad() public view {
        assertEq(
            pad.ROLE_OPERATOR(),
            0xaa3edb77f7c8cc9e38e8afe78954f703aeeda7fffe014eeb6e56ea84e62f6da7
        );
    }

    /**
     * @notice The rehearsal dials. A live curve needs 18 BNB to graduate; a test
     *         must be able to do it in one small buy, and the fee rates must be
     *         movable so both the live shape (`_tradingFeeRate = 100`,
     *         `feeRateBuy = 10`) and the `§9.4` target (`feeRateBuy = 0`) can be
     *         exercised deliberately.
     */
    function test_theThresholdAndFeesAreDials() public {
        MockBnbull token = _launchDefault(18 ether);
        assertEq(pad.maxRaisingOf(address(token)), 18 ether);

        vm.prank(padOwner);
        pad.setMaxRaising(address(token), 0.02 ether);
        assertEq(pad.maxRaisingOf(address(token)), 0.02 ether);

        vm.prank(padOwner);
        pad.setFeeRateBuy(address(token), 3); // one of the live observed rates
        vm.prank(padOwner);
        pad.setTradingFeeRate(100);
        vm.prank(padOwner);
        pad.setReferralRewardRate(5);
        vm.prank(padOwner);
        pad.setLpRaiseBps(9_800);

        // One small buy is now a whole lifecycle.
        _curveBuy(token, alice, 0.05 ether, 0);
        assertEq(pad.statusOf(address(token)), pad.STATUS_COMPLETED());
        (, uint256 wbnbSide) = _reserves(address(token));
        assertEq(wbnbSide, (0.02 ether * 9_800) / 10_000);
        // 3% of the raise to the founder.
        assertEq(creator.balance, (0.02 ether * 3) / 100);

        // A dial cannot be turned by a passer-by.
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(FourMemeMock.NotOwner.selector, griefer));
        pad.setTradingFeeRate(0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The mainnet guard
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE STRUCTURAL GUARANTEE. These are testnet artefacts and they
     *         refuse to exist on chain 56 — not by convention, by revert.
     */
    function test_mainnetDeploymentIsRefused() public {
        vm.chainId(56);

        vm.expectRevert(abi.encodeWithSelector(FourMemeMock.MainnetDeploymentForbidden.selector, 56));
        new FourMemeMock(padOwner, V2_FACTORY, V2_ROUTER, WBNB, padFeeRecipient, referralKeeper);

        vm.expectRevert(abi.encodeWithSelector(MockBnbull.MainnetDeploymentForbidden.selector, 56));
        new MockBnbull(
            MockBnbull.InitParams({
                name: "BNBull",
                symbol: "BNBULL",
                decimals: 18,
                totalSupply: SUPPLY_18DP,
                manager: address(this),
                founder: creator,
                taxEnabled: false,
                feeRateBuy: 0,
                feeRateSell: 0,
                rateFounder: 100,
                pancakeFactory: V2_FACTORY,
                pancakeRouter: V2_ROUTER,
                weth: WBNB
            })
        );

        vm.chainId(97);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _defaultParams(uint256 maxRaising)
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
            feeRateBuy: 0,
            feeRateSell: 0,
            rateFounder: 100,
            taxEnabled: false,
            atomicGraduation: true
        });
    }
}

// ══════════════════════════════════════════════════════════════════════════
//  Callers
// ══════════════════════════════════════════════════════════════════════════

/// @dev A contract buyer that does the two things §3/§9.1 say a contract buyer
///      must do: keep a payable fallback for the refund, and measure the amount
///      out as a `balanceOf` delta because the call returns nothing.
contract ContractBuyer {
    address public immutable pad;

    constructor(address pad_) {
        pad = pad_;
    }

    function buy(address token, uint256 funds, uint256 minAmount)
        external
        returns (uint256 delivered)
    {
        uint256 before = IBal(token).balanceOf(address(this));
        (bool ok,) = pad.call{value: funds}(
            abi.encodeWithSelector(0x87f27655, token, funds, minAmount)
        );
        require(ok, "ContractBuyer: buy failed");
        delivered = IBal(token).balanceOf(address(this)) - before;
    }

    receive() external payable {}
}

/// @dev The same, minus the payable fallback. Overpay and the refund kills it.
contract NoFallbackBuyer {
    address public immutable pad;

    constructor(address pad_) {
        pad = pad_;
    }

    function buy(address token, uint256 value, uint256 funds, uint256 minAmount) external {
        (bool ok, bytes memory ret) = pad.call{value: value}(
            abi.encodeWithSelector(0x87f27655, token, funds, minAmount)
        );
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

interface IBal {
    function balanceOf(address) external view returns (uint256);
}
