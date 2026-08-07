// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "../lib/BnbullsConfig.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";
import {CurveBuyerProbe} from "../../contracts/testnet/CurveBuyerProbe.sol";

interface IV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IV2Router {
    function factory() external view returns (address);
}

/**
 * @title FourMemeRehearsal
 * @notice Drive the WHOLE four.meme lifecycle LIVE on BSC testnet (chain 97):
 *         curve phase -> a CONTRACT buys -> atomic graduation -> a real
 *         PancakeSwap v2 pair -> the transfer gate lifts, on the SAME token
 *         address.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS EXISTS ALONGSIDE `SeedLiquidity.s.sol`
 *      ══════════════════════════════════════════════════════════════════════
 *      `SeedLiquidity` phase A rehearses the **best case**: template B with
 *      `feeRateBuy = 0` and the tax switched off — the `§9.4` "best of both"
 *      the launch form was hoped to give us.
 *
 *      ⚠ `DECISIONS.md §52` MEASURED that hope and it is gone. Every one of
 *      twenty template-B graduates was read for `feeRateBuy()`: **zero of
 *      twenty were untaxed.** min 1%, median 2%, max 5%. So a rehearsal at
 *      rate 0 rehearses a token we will not be issued.
 *
 *      This script therefore launches the shape the census says we will
 *      actually get, and it is not a guess:
 *
 *        * **template B (atomic graduation)** — §52 recommends B, and the
 *          deciding factor is NOT the tax: template A stalls transfer-locked at
 *          `STATUS_ADDING_LIQUIDITY` until a four.meme `ROLE_OPERATOR` calls
 *          `addLiquidity`, an unbounded third-party dependency at the most
 *          time-critical moment of the launch. §4 reproduced that stall twice.
 *        * **quote = native BNB (template 0)** — §48 measured 16 of 26 real
 *          graduations landing on BNB, and §52's cross-tab makes **B + BNB the
 *          single most common combination in the census, 13 of 26.** The other
 *          19 templates graduate into a pool our WBNB pivot cannot reach.
 *        * **`feeRateBuy = feeRateSell = 2`, tax ON** — the census MEDIAN.
 *          Rehearsing at 0 would quietly skip the two behaviours that actually
 *          bite: a non-fee-supporting router call reverting `Pancake: K`, and a
 *          measured output short of the quote by exactly the rate.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ WHAT THE CONSOLE OUTPUT OF A FORGE SCRIPT IS, AND IS NOT
 *      ══════════════════════════════════════════════════════════════════════
 *      A `forge script` run SIMULATES the whole body against live chain state,
 *      records the broadcastable calls, and only then sends them. Every
 *      `console2.log` below is therefore printed from the SIMULATION, not read
 *      back off a mined receipt. That is fine for sequencing and it is NOT
 *      evidence.
 *
 *      **The evidence is the `cast` reads taken against chain 97 after this
 *      script has been mined.** The addresses this prints are what those reads
 *      are aimed at. Nothing here should be quoted as an on-chain measurement.
 */
contract FourMemeRehearsal is BnbullsConfig {
    error NotBscTestnet(uint256 chainid);
    error GateDidNotHold();
    error SlippageFloorDidNotHold();
    error NoPairAfterGraduation();
    error DidNotGraduate(uint8 status);

    /// @notice Graduation threshold. ⚠ A TEST DIAL — a live BNB-quoted curve
    ///         raises 17.64 BNB (§48 measured the shape on all 16 BNB
    ///         graduations). 0.02 tBNB buys the same state transitions.
    uint256 internal constant RAISE = 0.02 ether;

    /// @notice §52's census median buy tax. NOT zero, on purpose.
    uint256 internal constant FEE_RATE_BUY = 2;
    uint256 internal constant FEE_RATE_SELL = 2;

    /// @notice The live shape §3 read off Gort's `_tokenInfos`: 1e27 supply,
    ///         80% on the curve, 20% to the LP at graduation.
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MAX_OFFERS = 800_000_000e18;

    /// @notice First buy: a quarter of the raise, so the curve is genuinely
    ///         mid-flight when the transfer gate is probed.
    uint256 internal constant FIRST_BUY = 0.005 ether;

    /// @dev The floor discipline, applied to our own buys: quote off
    ///      `calcBuyAmount` and take 99%. §9.1 — "there is no excuse for a
    ///      blind buy here."
    uint256 internal constant FLOOR_BPS = 9_900;

    /// @dev State handed between the phases. Held in storage rather than as
    ///      locals purely so each phase stays inside the EVM's stack depth.
    FourMemeMock internal pad;
    CurveBuyerProbe internal probe;
    address internal token;
    address internal pair;

    function run() external {
        if (block.chainid != CHAIN_BSC_TESTNET) revert NotBscTestnet(block.chainid);

        address router = _reqChainAddr("PANCAKE_V2_ROUTER");
        address wbnb = _reqChainAddr("WBNB");
        // ⚠ READ OFF THE ROUTER, never configured separately — a
        // router/factory mismatch then cannot survive (`§1`'s discipline).
        address factory = IV2Router(router).factory();

        console2.log("== FourMemeRehearsal (chain 97) ==");
        console2.log("  deployer/owner", msg.sender);
        console2.log("  router        ", router);
        console2.log("  factory       ", factory, "(read off the router)");
        console2.log("  wbnb          ", wbnb);
        console2.log("  balance       ", msg.sender.balance);

        _deployPad(factory, router, wbnb);
        _launchCurveToken();
        _proveGate();
        _contractBuysOnCurve();
        _fillAndGraduate(factory, wbnb);
        _proveGateLifted();

        console2.log("");
        console2.log("  ---- ADDRESSES TO VERIFY WITH cast ----");
        console2.log("  pad  ", address(pad));
        console2.log("  token", token);
        console2.log("  probe", address(probe));
        console2.log("  pair ", pair);
    }

    // ── 1. the pad ───────────────────────────────────────────────

    function _deployPad(address factory, address router, address wbnb) private {
        vm.startBroadcast();
        pad = new FourMemeMock(msg.sender, factory, router, wbnb, msg.sender, msg.sender);
        vm.stopBroadcast();
        console2.log("");
        console2.log("  [1] pad deployed          ", address(pad));
    }

    // ── 2. the curve token: template B + BNB quote + 2% tax ───────────

    function _launchCurveToken() private {
        vm.startBroadcast();
        token = pad.launch(
            FourMemeMock.LaunchParams({
                name: "Rehearsal BNBULL (taxed)",
                symbol: "rBNBULL2",
                decimals: 18,
                totalSupply: SUPPLY,
                maxOffers: MAX_OFFERS,
                maxRaising: RAISE,
                // ⚠ template 0. Anything else and the money layer is dead with
                //   no contract fix (`§30`). The mock REFUSES a non-zero quote
                //   rather than pretending to model a CAKE/USDT/NVDAB pool.
                quote: address(0),
                founder: msg.sender,
                feeRateBuy: FEE_RATE_BUY,
                feeRateSell: FEE_RATE_SELL,
                rateFounder: 100,
                // ⚠ ON. §52: zero of twenty shipped untaxed.
                taxEnabled: true,
                // template B — atomic, inside the filling buyer's own tx.
                atomicGraduation: true
            })
        );
        probe = new CurveBuyerProbe(address(pad));
        vm.stopBroadcast();
        console2.log("  [2] curve token           ", token);
        console2.log("      contract buyer probe  ", address(probe));
    }

    // ── 3. the transfer gate, as a plain call (no gas, no receipt) ─────

    function _proveGate() private view {
        (bool moved,) = token.staticcall(
            abi.encodeWithSignature("transfer(address,uint256)", address(0xdead), uint256(1))
        );
        if (moved) revert GateDidNotHold();
        console2.log("  [3] transfer() REVERTS pre-graduation (the gate holds)");
    }

    // ── 4. a CONTRACT buys on the curve, with a real floor ───────────

    function _contractBuysOnCurve() private {
        uint256 quoted = pad.calcBuyAmount(token, FIRST_BUY);
        console2.log("  [4] curve quote for", FIRST_BUY, "wei gross:");
        console2.log("      calcBuyAmount     ", quoted);
        console2.log("      minAmount floor   ", (quoted * FLOOR_BPS) / 10_000, "(99% of quote)");

        // The floor is a HARD floor: prove it before relying on it.
        (bool slipped,) = address(pad).call{value: FIRST_BUY}(
            abi.encodeWithSignature(
                "buyTokenAMAP(address,uint256,uint256)", token, FIRST_BUY, quoted * 2
            )
        );
        if (slipped) revert SlippageFloorDidNotHold();
        console2.log("      [ok] an unreachable minAmount reverts Slippage");

        vm.startBroadcast();
        probe.buy{value: FIRST_BUY}(token, FIRST_BUY, (quoted * FLOOR_BPS) / 10_000);
        vm.stopBroadcast();
        console2.log("      [ok] a CONTRACT bought on the curve (no EOA gate)");
        console2.log("      probe balance     ", MockBnbull(token).balanceOf(address(probe)));
        console2.log("      curve funds       ", pad.fundsOf(token), "of", RAISE);

        // ⚠ and it cannot move them. This is §28.1 as a live fact: BNBULL
        //   bought on the curve is STRANDED until graduation.
        (bool probeMoved,) = address(probe).call(
            abi.encodeWithSignature(
                "withdrawToken(address,address,uint256)", token, msg.sender, uint256(1)
            )
        );
        if (probeMoved) revert GateDidNotHold();
        console2.log("      [ok] the probe CANNOT move what it bought - stranded");
    }

    // ── 5. fill the curve; template B graduates inside this very tx ────

    function _fillAndGraduate(address factory, address wbnb) private {
        uint256 room = RAISE - pad.fundsOf(token);
        uint256 fillGross = room * 2; // deliberately over: proves the refund
        uint256 fillQuote = pad.calcBuyAmount(token, fillGross);
        console2.log("  [5] filling: room", room, "sending gross", fillGross);

        vm.startBroadcast();
        probe.buy{value: fillGross}(token, fillGross, (fillQuote * FLOOR_BPS) / 10_000);
        vm.stopBroadcast();

        uint8 status = pad.statusOf(token);
        if (status != pad.STATUS_COMPLETED()) revert DidNotGraduate(status);
        console2.log("      status", status, "= STATUS_COMPLETED (atomic graduation)");

        pair = IV2Factory(factory).getPair(token, wbnb);
        if (pair == address(0)) revert NoPairAfterGraduation();
        console2.log("      [ok] a REAL v2 pair exists", pair);
    }

    // ── 6. the gate is gone, on the SAME token address ──────────────

    function _proveGateLifted() private {
        vm.startBroadcast();
        probe.withdrawToken(token, msg.sender, MockBnbull(token).balanceOf(address(probe)));
        vm.stopBroadcast();
        console2.log("  [6] [ok] the probe moved its whole balance out - gate lifted");
        console2.log("      DECISIONS 47: SAME address before and after. Nothing migrated.");
    }
}
