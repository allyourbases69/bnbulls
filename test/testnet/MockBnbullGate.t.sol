// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestnetDexBase} from "./TestnetDexBase.t.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

/**
 * @title MockBnbullGateTest
 * @notice **The transfer gate — the single most important behaviour in the
 *         whole rehearsal.**
 *
 * @dev `FOUR-MEME-LAUNCH-ROUTE.md §0.1` and `DECISIONS.md §28.1`: pre-graduation
 *      `transfer` and `transferFrom` revert `"Token: Transfer is restricted"`
 *      for every holder. That is not a buyback inconvenience — it means the
 *      always-BNBULL 10% discount, BNBULL fight stakes and BNBULL marketplace
 *      payments are **all dead for the entire curve phase**, because every one
 *      of them moves BNBULL with `transferFrom`.
 *
 *      Verified on chain three ways (§2): disassembled bytecode strings; a live
 *      `eth_call` of `transfer()` from a real holder of a real pre-graduation
 *      token (Gort, holder `0x4ce7f73b…`); and a real transaction on a mainnet
 *      fork after a real curve buy. Reproduced across three templates.
 */
contract MockBnbullGateTest is TestnetDexBase {
    /// @notice The string, byte for byte. Every gate assertion goes through this
    ///         constant so a drifting message cannot be papered over.
    string internal constant GATE = "Token: Transfer is restricted";

    // ══════════════════════════════════════════════════════════════════════
    //  The curve phase: nothing moves
    // ══════════════════════════════════════════════════════════════════════

    function test_transferIsRestrictedForARealHolder() public {
        MockBnbull token = _launchDefault(18 ether);
        uint256 bought = _curveBuy(token, alice, 0.5 ether, 0);
        assertGt(bought, 0, "the buy must actually deliver");

        vm.prank(alice);
        vm.expectRevert(bytes(GATE));
        token.transfer(DEAD, 1e18);
    }

    /**
     * @notice §2 warns explicitly: with NO allowance, `transferFrom` reverts on
     *         the ALLOWANCE check first, "which is why an allowance-less probe
     *         is misleading — do not use one". Both branches are asserted so the
     *         gate proof is the one that actually stages an allowance.
     */
    function test_transferFromIsRestricted_butOnlyAfterTheAllowanceCheck() public {
        MockBnbull token = _launchDefault(18 ether);
        _curveBuy(token, alice, 0.5 ether, 0);

        // The MISLEADING probe: no allowance, so this is not evidence of a gate.
        vm.prank(bob);
        vm.expectRevert(bytes("Token: Invalid transfer"));
        token.transferFrom(alice, bob, 1e18);

        // `approve` WORKS during the restricted phase and returns true (§2), so
        // allowances can be pre-staged.
        vm.prank(alice);
        assertTrue(token.approve(bob, type(uint256).max), "approve must work while restricted");

        // NOW the probe is honest, and it hits the gate.
        vm.prank(bob);
        vm.expectRevert(bytes(GATE));
        token.transferFrom(alice, bob, 1e18);
    }

    /// @notice §2: even a direct `transfer()` called from the PAD's own address
    ///         reverts with the same string. The gate is unconditional; delivery
    ///         goes through `sendToken`.
    function test_evenThePadCannotTransfer() public {
        MockBnbull token = _launchDefault(18 ether);
        vm.prank(address(pad));
        vm.expectRevert(bytes(GATE));
        token.transfer(alice, 1e18);
    }

    /// @notice The custodial delivery path. Owner-gated, so during the curve
    ///         phase the pad can move ANY holder's balance (§2's "treat the
    ///         curve phase as custodial").
    function test_sendTokenIsThePadsOnlyDeliveryPath() public {
        MockBnbull token = _launchDefault(18 ether);
        _curveBuy(token, alice, 0.5 ether, 0);
        uint256 aliceBal = token.balanceOf(alice);

        // A non-owner cannot use it.
        vm.prank(griefer);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.sendToken(alice, griefer, aliceBal);

        // The pad can, and it moves someone else's balance without an allowance.
        vm.prank(address(pad));
        token.sendToken(alice, bob, aliceBal);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), aliceBal);
    }

    /**
     * @notice The product consequence, spelled out as a test so it cannot be
     *         forgotten: **every BNBULL money path in the game is dead during
     *         the curve phase.** `DECISIONS.md §28.1` / route §2's table.
     */
    function test_everyBnbullGameFlowIsDeadDuringTheCurve() public {
        MockBnbull token = _launchDefault(18 ether);
        _curveBuy(token, alice, 0.5 ether, 0);
        vm.prank(alice);
        token.approve(address(this), type(uint256).max);

        // The 10% mint discount: MintDrop pulls the BNBULL payment.
        vm.expectRevert(bytes(GATE));
        token.transferFrom(alice, address(this), 1e18);

        // A duel stake pull (§23).
        vm.expectRevert(bytes(GATE));
        token.transferFrom(alice, address(this), 5e18);

        // A marketplace BNBULL-denominated sale (§14, §21).
        vm.expectRevert(bytes(GATE));
        token.transferFrom(alice, bob, 2e18);

        // And a contract that DID receive tokens from the pad still cannot pay
        // them out — the pot can hold BNBULL, it just cannot spend it.
        vm.prank(address(pad));
        token.sendToken(address(pad), address(this), 1e21);
        assertEq(token.balanceOf(address(this)), 1e21, "a contract CAN be delivered to");
        vm.expectRevert(bytes(GATE));
        token.transfer(bob, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  After graduation: the gate is gone, permanently
    // ══════════════════════════════════════════════════════════════════════

    /// @notice §2, verified by executing a full graduation on a fork and then
    ///         transacting: `_mode` flips `1 -> 0`, `owner()` becomes
    ///         `address(0)`, and the admin surface is unreachable forever.
    function test_afterGraduationTheGateIsGoneAndCannotComeBack() public {
        MockBnbull token = _launchDefault(0.05 ether);
        _curveBuy(token, alice, 0.02 ether, 0);
        assertEq(token._mode(), token.MODE_TRANSFER_RESTRICTED());

        _graduate(token);

        assertEq(token._mode(), token.MODE_NORMAL(), "_mode must flip 1 -> 0");
        assertEq(token.owner(), address(0), "ownership must renounce to address(0)");

        // `setMode` is owner-gated and there is no owner. Not even the pad.
        vm.prank(address(pad));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.setMode(1);

        // `sendToken` from the pad reverts too: **zero custody power** (§2).
        vm.prank(address(pad));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.sendToken(alice, griefer, 1);
    }

    /// @notice §2: `sendToken` on a graduated token reverts `Not allowed` — the
    ///         mode check, distinct from the ownership check. Proven by giving
    ///         the token an owner it will never have on chain, so the second
    ///         guard is reachable and provably present.
    function test_sendTokenRevertsNotAllowedOnceModeIsNormal() public {
        MockBnbull token = new MockBnbull(
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
        token.setMode(token.MODE_NORMAL());
        vm.expectRevert(bytes("Not allowed"));
        token.sendToken(address(this), alice, 1);
    }

    /// @notice §2: plain `transfer` and third-party `transferFrom` move the
    ///         EXACT amount, and there is no max-tx and no max-wallet — a single
    ///         transfer of 10% of supply succeeded on the fork.
    function test_afterGraduationTransfersMoveExactAmountsWithNoCaps() public {
        MockBnbull token = _launchDefault(0.05 ether);
        _graduate(token);

        uint256 whale = token.balanceOf(alice);
        assertGt(whale, SUPPLY_18DP / 10, "alice should hold well over 10% of supply");

        vm.prank(alice);
        token.transfer(DEAD, 1e21);
        assertEq(token.balanceOf(DEAD), 1e21, "sent 1e21, DEAD must receive 1e21");

        // 10% of supply in one move. No cap.
        vm.prank(alice);
        token.transfer(bob, SUPPLY_18DP / 10);
        assertEq(token.balanceOf(bob), SUPPLY_18DP / 10);

        // approve + third-party transferFrom: **our exact game money path.**
        vm.prank(bob);
        token.approve(address(this), 1e24);
        token.transferFrom(bob, carolLike(), 1e24);
        assertEq(token.balanceOf(carolLike()), 1e24, "approved 1e24, pulled 1e24");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Decimals are READ, never assumed
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `DECISIONS.md §4` + `PotSplitter`'s decimals note: four.meme
     *         issues the token, so 18 is an EXPECTATION, not a fact. A whole
     *         non-18dp lifecycle must be one constructor argument away.
     */
    function test_aNon18DecimalTokenRunsTheWholeLifecycle() public {
        uint8 dp = 9;
        uint256 supply = 1_000_000_000 * (10 ** dp);
        FourMemeMock.LaunchParams memory p = FourMemeMock.LaunchParams({
            name: "BNBull",
            symbol: "BNBULL",
            decimals: dp,
            totalSupply: supply,
            maxOffers: (supply * CURVE_SHARE_BPS) / 10_000,
            maxRaising: 0.05 ether,
            quote: address(0),
            founder: creator,
            feeRateBuy: 0,
            feeRateSell: 0,
            rateFounder: 100,
            taxEnabled: false,
            atomicGraduation: true
        });
        MockBnbull token = _launch(p);

        // READ it. Never `assertEq(18, ...)`.
        assertEq(token.decimals(), dp, "decimals must be what the token says");

        _graduate(token);
        (uint256 tokenSide,) = _reserves(address(token));
        // 20% of supply, expressed in the token's OWN units.
        assertEq(tokenSide, supply - p.maxOffers);

        vm.prank(alice);
        token.transfer(bob, 1 * (10 ** dp));
        assertEq(token.balanceOf(bob), 1 * (10 ** dp));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The template-B tax (DECISIONS §30) — a flag, default OFF
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Default configuration is untaxed, which is the `§9.4` target and
    ///         must never require a post-deploy transaction to achieve.
    function test_taxIsOffByDefault() public {
        MockBnbull token = _launchDefault(0.05 ether);
        assertFalse(token.taxEnabled(), "the taxed path is opt-in");
        assertEq(token.feeRateBuy(), 0);
        assertEq(token.feeRateSell(), 0);

        _graduate(token);

        // §4 on PUPP (template A, untaxed): the router buy returned the quote
        // to the wei. Same here.
        uint256 quoted = _quoteBnbIn(address(token), 0.001 ether);
        uint256 got = _routerBuy(address(token), bob, 0.001 ether);
        assertEq(got, quoted, "an untaxed token delivers the quote exactly");
    }

    /**
     * @notice The taxed path, exercised deliberately. §4 measured on BEAU
     *         (`feeRateBuy = feeRateSell = 10`), after graduating it on a fork:
     *
     *           wallet -> wallet transfer of 1e24        -> 1e24     (untaxed)
     *           approve + third-party transferFrom 1e24  -> 1e24     (untaxed)
     *           router swapExactETHForTokens             -> **-10%**
     *           router swapExactTokensForETH (plain)     -> **reverts Pancake: K**
     *           ...SupportingFeeOnTransferTokens         -> -10%, succeeds
     */
    function test_taxedTemplateB_hooksOnlyOnPairTouchingTransfers() public {
        MockBnbull token = _launchTaxed(0.05 ether, 10, 10);
        _graduate(token);
        assertTrue(token.taxEnabled());

        // ── Wallet moves are CLEAN. This is all the game does. ────────────
        vm.prank(alice);
        token.transfer(bob, 1e24);
        assertEq(token.balanceOf(bob), 1e24, "wallet -> wallet must be untaxed");

        vm.prank(bob);
        token.approve(address(this), 1e24);
        token.transferFrom(bob, carolLike(), 1e24);
        assertEq(token.balanceOf(carolLike()), 1e24, "transferFrom must be untaxed");

        // ── The router BUY is taxed exactly 10%. ──────────────────────────
        uint256 quoted = _quoteBnbIn(address(token), 0.001 ether);
        uint256 got = _routerBuy(address(token), griefer, 0.001 ether);
        assertEq(got, quoted - (quoted / 10), "a taxed buy lands exactly 10% short");
    }

    /**
     * @notice **The sharpest edge in the report.** §4: a NON-fee-supporting
     *         router call against a taxed token reverts `Pancake: K`, and v3 has
     *         no fee-supporting variant at all — so a taxed token cannot be
     *         routed on v3 under any circumstances.
     *
     *         This is why another agent is making our swap leg fee-supporting.
     *         Run against the REAL router, so the revert is PancakeSwap's own.
     */
    function test_taxedToken_bricksTheNonFeeSupportingSellRoute() public {
        MockBnbull token = _launchTaxed(0.05 ether, 10, 10);
        _graduate(token);

        uint256 sell = 1e24;
        vm.prank(alice);
        token.transfer(bob, sell);
        vm.prank(bob);
        token.approve(V2_ROUTER, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = WBNB;

        // The plain route BRICKS.
        vm.prank(bob);
        vm.expectRevert(bytes("Pancake: K"));
        router.swapExactTokensForETH(sell, 0, path, bob, block.timestamp);

        // The fee-supporting route SUCCEEDS, short by the tax.
        uint256 before = bob.balance;
        vm.prank(bob);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            sell, 0, path, bob, block.timestamp
        );
        assertGt(bob.balance, before, "the fee-supporting variant must work");
    }

    /// @notice ...and the SAME sell through the SAME plain route works fine on
    ///         an untaxed token. The brick is the tax, not the router.
    function test_untaxedToken_sellsFineThroughThePlainRoute() public {
        MockBnbull token = _launchDefault(0.05 ether);
        _graduate(token);

        uint256 sell = 1e24;
        vm.prank(alice);
        token.transfer(bob, sell);
        vm.prank(bob);
        token.approve(V2_ROUTER, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = WBNB;

        uint256 before = bob.balance;
        vm.prank(bob);
        router.swapExactTokensForETH(sell, 0, path, bob, block.timestamp);
        assertGt(bob.balance, before);
    }

    /// @notice §4's bscscan-sourced bound, reproduced. ⚠ WEAKER EVIDENCE — read
    ///         off a source page through a summariser, not off a contract call.
    function test_feeRatesAreBoundedAtTen() public {
        FourMemeMock.LaunchParams memory p = _taxedParams(1 ether, 11, 10);
        vm.prank(creator);
        vm.expectRevert(bytes("Token: invalid feeRateBuy"));
        pad.launch(p);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function carolLike() internal pure returns (address) {
        return address(0xCA401);
    }

    function _launchTaxed(uint256 maxRaising, uint256 buy, uint256 sell)
        internal
        returns (MockBnbull)
    {
        return _launch(_taxedParams(maxRaising, buy, sell));
    }

    /**
     * @dev ⚠ ONE creator-set rate drives BOTH roles on the live token, and that
     *      is deliberate rather than a conflation here. §3 proved
     *      `feeRateBuy() = 10` is what paid Gort's founder exactly 1.8 BNB on an
     *      18 BNB raise (the CURVE fee); §4 proved the same `feeRateBuy` /
     *      `feeRateSell` pair is what taxes pair-touching transfers by 10% on
     *      BEAU (the TRANSFER tax). Setting one number and getting both
     *      behaviours is the observed shape.
     */
    function _taxedParams(uint256 maxRaising, uint256 buy, uint256 sell)
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
            feeRateBuy: buy,
            feeRateSell: sell,
            rateFounder: 100,
            taxEnabled: true,
            atomicGraduation: true
        });
    }

    /// @dev A real router buy, measured as a `balanceOf` delta.
    function _routerBuy(address token, address who, uint256 bnbIn) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        vm.deal(who, who.balance + bnbIn);
        uint256 before = MockBnbull(token).balanceOf(who);
        vm.prank(who);
        router.swapExactETHForTokens{value: bnbIn}(0, path, who, block.timestamp);
        return MockBnbull(token).balanceOf(who) - before;
    }
}
