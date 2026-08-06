// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "../lib/BnbullsConfig.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

interface IV2Router {
    function factory() external view returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

/**
 * @title SeedLiquidity
 * @notice Turn the chain-97 rehearsal from "everything defers" into a real
 *         end-to-end money-layer test, in two independent phases.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      PHASE A — A REAL GRADUATION THROUGH THE MOCK PAD (`DECISIONS.md §28`)
 *      ══════════════════════════════════════════════════════════════════════
 *      Drives `FourMemeMock` through the ACTUAL §28 sequence against the REAL
 *      PancakeSwap v2 on chain 97: curve phase (transfers gated) -> a contract
 *      buys on the curve -> threshold met -> graduation creates a real v2 pair
 *      -> the gate lifts permanently. `maxRaising` is a test parameter, so the
 *      18 BNB a live curve needs becomes 0.01.
 *
 *      This is the sequence itself, proven live rather than on a fork. It does
 *      NOT feed the game: `MintDrop.bnbull` and `Duel.bnbull` are immutable
 *      constructor args, so the deployed game can only ever trade the BNBULL it
 *      was built against.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      PHASE B — A REAL POOL FOR THE GAME'S OWN BNBULL
 *      ══════════════════════════════════════════════════════════════════════
 *      Adds liquidity for the deployed `BNBull` through the same real router,
 *      so every BNBULL leg in the game has a book to hit for the first time.
 *      Both phases use the SAME router and factory, so a pair created either
 *      way is discovered by the same `wbnbPoolLiquidity()` read.
 *
 *      ⚠ Amounts are micro on purpose and the testnet `minPoolLiquidity` is
 *      lowered to match. THE MAINNET FLOOR OF 1 BNB IS UNCHANGED.
 */
contract SeedLiquidity is BnbullsConfig {
    error NotBscTestnet(uint256 chainid);
    error GateDidNotHold();
    error NoPairAfterGraduation();
    error NoPairAfterAddLiquidity();

    /// Graduation threshold for the rehearsal curve.
    uint256 constant RAISE = 0.01 ether;
    /// WBNB side of the game token's pool. Must clear the testnet floor.
    uint256 constant GAME_POOL_BNB = 0.03 ether;
    /// BNBULL side. 3,000,000 BNBULL against 0.03 BNB.
    uint256 constant GAME_POOL_TOKENS = 3_000_000e18;

    function run() external {
        if (block.chainid != CHAIN_BSC_TESTNET) revert NotBscTestnet(block.chainid);

        Deployment memory d = readDeployment();
        address router = _reqChainAddr("PANCAKE_V2_ROUTER");
        address wbnb = _reqChainAddr("WBNB");
        address factory = IV2Router(router).factory();

        console2.log("== SeedLiquidity (chain 97) ==");
        console2.log("  router ", router);
        console2.log("  factory", factory, "(read off the router, never configured)");
        console2.log("  wbnb   ", wbnb);

        _phaseA(router, wbnb, factory);
        _phaseB(d, router, wbnb, factory);
    }

    // ─── Phase A: the pad, the curve, the graduation ─────────────────────

    function _phaseA(address router, address wbnb, address factory) private {
        console2.log("");
        console2.log("== PHASE A: a real graduation through the mock four.meme pad ==");

        vm.startBroadcast();
        FourMemeMock pad = new FourMemeMock(
            msg.sender, factory, router, wbnb, msg.sender, msg.sender
        );
        console2.log("  pad deployed", address(pad));

        address token = pad.launch(
            FourMemeMock.LaunchParams({
                name: "Rehearsal BNBULL",
                symbol: "rBNBULL",
                decimals: 18,
                totalSupply: 1_000_000_000e18,
                maxOffers: 800_000_000e18,
                maxRaising: RAISE,
                quote: address(0),
                founder: msg.sender,
                // 0 is the §9.4 launch-form target: no creator buy fee.
                feeRateBuy: 0,
                feeRateSell: 0,
                rateFounder: 0,
                // Template B tax OFF for the clean run.
                taxEnabled: false,
                atomicGraduation: true
            })
        );
        console2.log("  curve token  ", token);
        console2.log("  status       ", pad.statusOf(token), "(0 = TRADING, curve phase)");
        vm.stopBroadcast();

        // ⚠ §28.1 — PRE-GRADUATION THE TOKEN CANNOT BE TRANSFERRED AT ALL.
        // The curve phase is custodial. This is the assertion that makes the
        // whole BNBULL-defers-at-launch story true rather than assumed.
        (bool moved,) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", address(0xdead), 1)
        );
        if (moved) revert GateDidNotHold();
        console2.log("  [ok] transfer REVERTS pre-graduation (Token: Transfer is restricted)");

        // A CONTRACT buying on the curve — §28.2. `buyTokenAMAP` returns
        // nothing, so amount-out can only ever be a measured balance delta.
        //
        // ⚠ SENDING EXACTLY `maxRaising` CANNOT GRADUATE THE CURVE, and that is
        // faithful rather than a mock quirk. `_splitBuy` grosses the fee OUT of
        // `funds` (`toCurve = funds * BPS / grossMultiplier`), so the curve only
        // ever receives less than what was sent — §28.2's "you pay 111 to move
        // the curve by 100". A buyer aiming exactly at the threshold lands just
        // short, every time, and the token silently stays in the custodial
        // curve phase with every transfer still gated.
        //
        // Overpaying is the intended path: `_splitBuy` caps `toCurve` at the
        // remaining `room` and the excess is refunded, so the caller needs a
        // payable receive. Here the tx is sent by the EOA, so the refund lands
        // on the EOA — but a CONTRACT doing this on mainnet must be payable or
        // the refund reverts the whole buy.
        uint256 balBefore = msg.sender.balance;
        vm.startBroadcast();
        pad.buyTokenAMAP{value: RAISE * 2}(token, RAISE * 2, 0);
        vm.stopBroadcast();
        console2.log("  sent 2x the threshold; overshoot refunded, spent net");
        console2.log("   ", balBefore - msg.sender.balance, "(incl. gas)");

        console2.log("  status after buy", pad.statusOf(token), "(3 = COMPLETED, graduated)");

        address pair = IV2Factory(factory).getPair(token, wbnb);
        if (pair == address(0)) revert NoPairAfterGraduation();
        (uint112 r0, uint112 r1,) = IV2Pair(pair).getReserves();
        address t0 = IV2Pair(pair).token0();
        console2.log("  [ok] graduation created a REAL v2 pair", pair);
        console2.log("       WBNB reserve  ", t0 == wbnb ? uint256(r0) : uint256(r1));
        console2.log("       token reserve ", t0 == wbnb ? uint256(r1) : uint256(r0));

        // The gate is gone permanently: `_mode` 1 -> 0, ownership renounced.
        vm.startBroadcast();
        IERC20Like(token).transfer(address(0xdead), 1);
        vm.stopBroadcast();
        console2.log("  [ok] transfer WORKS post-graduation - the gate lifted");
    }

    // ─── Phase B: a pool for the game's own BNBULL ───────────────────────

    function _phaseB(Deployment memory d, address router, address wbnb, address factory)
        private
    {
        console2.log("");
        console2.log("== PHASE B: a real v2 pool for the GAME's BNBULL ==");
        console2.log("  BNBULL", d.bnbull);

        vm.startBroadcast();
        IERC20Like(d.bnbull).approve(router, GAME_POOL_TOKENS);
        IV2Router(router).addLiquidityETH{value: GAME_POOL_BNB}(
            d.bnbull, GAME_POOL_TOKENS, 0, 0, msg.sender, block.timestamp + 1200
        );
        vm.stopBroadcast();

        address pair = IV2Factory(factory).getPair(d.bnbull, wbnb);
        if (pair == address(0)) revert NoPairAfterAddLiquidity();
        (uint112 r0, uint112 r1,) = IV2Pair(pair).getReserves();
        address t0 = IV2Pair(pair).token0();
        uint256 wbnbReserve = t0 == wbnb ? uint256(r0) : uint256(r1);

        console2.log("  [ok] pair", pair);
        console2.log("       WBNB reserve  ", wbnbReserve);
        console2.log("       BNBULL reserve", t0 == wbnb ? uint256(r1) : uint256(r0));
        console2.log("");
        console2.log("  PAIR ADDRESS for the keeper fleet:");
        console2.log("   ", pair);
    }
}
