// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployCore} from "../Deploy.s.sol";
import {WireCore} from "../Wire.s.sol";
import {VerifyCore} from "../Verify.s.sol";

import {BNBull} from "../../contracts/BNBull.sol";
import {Bulls} from "../../contracts/Bulls.sol";
import {LocalWBNB, LocalAggregator, LocalRouter, LocalVRFCoordinator}
    from "./mocks/LocalMocks.sol";

/**
 * @title DeployLocal
 * @notice The whole game on a local anvil: mocks for the outside world, then
 *         the REAL `Deploy` -> `Wire` -> `Verify` path, unmodified.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      IT RUNS THE SAME CODE AS MAINNET, ON PURPOSE
 *      ══════════════════════════════════════════════════════════════════════
 *      `deployAll`, `wireAll` and `verifyAll` are inherited from
 *      `script/Deploy.s.sol`, `script/Wire.s.sol` and `script/Verify.s.sol`.
 *      A local rehearsal that exercised a parallel copy of the wiring would
 *      prove nothing about the wiring that actually ships — that is how a
 *      "tested" deploy still misses a funder role.
 *
 *      The ONLY thing this file adds is the outside world: WBNB, an 18-dp
 *      stablecoin, a drivable BNB/USD feed, a router with real reserves, and a
 *      VRF coordinator you fulfil by hand.
 *
 *      ⚠ CHAIN-GUARDED. It refuses to run anywhere but 31337, and
 *      `script/Deploy.s.sol` imports nothing from `mocks/`, so the mock
 *      bytecode is not even in scope on a mainnet run. Stable warriors baked an
 *      auto-deployed `MockUSDT` into `MintDrop`'s immutable storage forever
 *      because a deploy script had a silent mock fallback
 *      (`DEPLOY-SAFETY-PREFLIGHT.md §2`). This is that hole, welded shut.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE LOCAL ECONOMY
 *      ══════════════════════════════════════════════════════════════════════
 *        BNB/USD  $600      (feed, 8 decimals)
 *        BNBULL   $0.01     (so the $10 rung pegs at 1,000 BNBULL)
 *      Pool: 100 WBNB / 6,000,000 BNBULL. One pool, because `DECISIONS.md §26`
 *      leaves one swap route.
 *      Constant product with a 0.25% fee, so the price genuinely MOVES and a
 *      too-optimistic `setFloors` really does make a swap defer.
 */
contract DeployLocal is DeployCore, WireCore, VerifyCore {
    error NotAnvil(uint256 chainid);

    LocalWBNB internal wbnb;
    LocalAggregator internal feed;
    LocalRouter internal router;
    LocalVRFCoordinator internal coord;

    function run() external {
        if (block.chainid != CHAIN_ANVIL) revert NotAnvil(block.chainid);

        address deployer = msg.sender;
        console2.log("== bnbulls LOCAL deploy (anvil) ==");
        console2.log("  deployer", deployer);

        vm.startBroadcast();

        _deployMocks();
        Cfg memory c = _localCfg(deployer);
        Deployment memory d = deployAll(c);
        c.ext.bnbull = d.bnbull;

        _openToken(c, d);
        _seedLiquidity(c, d);
        wireAll(c, d);
        _publishNames(d);

        vm.stopBroadcast();

        console2.log("");
        logDeployment(d);

        // ⚠ RECORD BEFORE VERIFYING. `verifyAll` reverts on any gap, and the
        // addresses are exactly what you need to debug that gap. Losing the
        // record because the verification did its job would be perverse.
        writeDeployment(c, d);
        _writeEnvLocal(c, d);
        verifyAll(c, d);
    }

    // ─── The outside world ──────────────────────────────────────────────

    /// @dev Resumed off the record like everything else, so a re-run against a
    ///      live anvil does not strand the deployment on a second, empty set of
    ///      mocks — which would leave every wire pointing at the old ones and
    ///      verify green against a chain nothing works on.
    function _deployMocks() private {
        wbnb = LocalWBNB(payable(_resume(recordedAddress(".ext.wbnb"), "mock WBNB")));
        if (address(wbnb) == address(0)) wbnb = new LocalWBNB();

        feed = LocalAggregator(_resume(recordedAddress(".ext.priceFeed"), "mock feed"));
        if (address(feed) == address(0)) {
            feed = new LocalAggregator(int256(vm.envOr("LOCAL_BNB_USD_8", uint256(600e8))));
        }

        router = LocalRouter(payable(_resume(recordedAddress(".ext.routerV2"), "mock router")));
        if (address(router) == address(0)) router = new LocalRouter(address(wbnb));

        coord = LocalVRFCoordinator(_resume(recordedAddress(".ext.vrfCoordinator"), "mock VRF"));
        if (address(coord) == address(0)) coord = new LocalVRFCoordinator();

        console2.log("");
        console2.log("-- local mocks --");
        console2.log("  WBNB           ", address(wbnb));
        console2.log("  BNB/USD feed   ", address(feed));
        console2.log("  router (v2+v3) ", address(router));
        console2.log("  VRF coordinator", address(coord));
    }

    function _localCfg(address deployer) private view returns (Cfg memory c) {
        c.ext.wbnb = address(wbnb);
        c.ext.priceFeed = address(feed);
        c.ext.routerV2 = address(router);
        // ⚠ ONE VENUE NOW (`DECISIONS.md §28`): MintDrop and both splitters
        // swap on v2. This slot is kept only so the deploy record names the
        // address nothing points at.
        c.ext.routerV3 = address(router);
        c.ext.vrfCoordinator = address(coord);
        c.ext.vrfKeyHash = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;
        c.ext.vrfSubId = 1;
        c.ext.bnbull = address(0); // deploy BNBull.sol locally

        // Every role is the deployer, so the treasury guard has nothing to
        // diff and the one-command flow stays one command.
        c.roles.deployer = deployer;
        c.roles.owner = deployer;
        c.roles.keeper = deployer;
        c.roles.trustedSigner = vm.envOr("LOCAL_TRUSTED_SIGNER", deployer);
        c.roles.mintTreasury = deployer;
        c.roles.lpTreasury = deployer;
        c.roles.feeTreasury = deployer;
        c.roles.devTreasury = deployer;
        c.roles.resurrectTreasury = deployer;

        c.params.masterSeed = readMasterSeed();
        c.params.namesCommitment = namesCommitment(readNames());
        c.params.marketplaceFeeBps = 750; // DECISIONS 21
        c.params.marketplaceJackpotFeeBps = 250; // of the SALE, not of the fee
        c.params.duelDefaultDevBps = 1_000;
        c.params.bnbullSupply = 1_000_000_000e18;

        // $600 BNB, $0.01 BNBULL.
        c.params.maxFightWbnb = 1e18; // ~$600 ceiling, permanent
        c.params.maxFightBnbull = 1_000_000e18;
        // ⚠ A DOLLAR figure — `Duel.setUsdFightPrice`. The BNB stake is derived
        // from it through the feed (`DECISIONS.md §26`), so it does NOT need
        // repegging when BNB moves.
        c.params.fightWbnb = 2.5e18; // $2.50
        c.params.fightBnbull = 250e18; // ~$2.50

        // Floors sit BELOW the seeded market so an ordinary swap clears them.
        // Market: 60,000 BNBULL/BNB.
        c.params.floorBnbullPerBnb = 40_000e18;
        c.params.floorWbnbPerBnbull = 1e10;
        // The local router's mock pair is seeded far above this, so an ordinary
        // local swap clears the minimum-liquidity floor.
        c.params.minPoolLiquidity = 1 ether;

        c.params.graveyardBnbullPerUsd = 100e18; // $1 -> 100 BNBULL
        c.params.marketplaceBnbullUsd = 0.01e18; // BNBULL = $0.01
        c.params.baseURI = vm.envOr("NFT_BASE_URI", string("http://localhost:3000/api/token/"));
    }

    // ─── Token: open trading so the local chain can actually move BNBULL ─

    /**
     * @dev ⚠ `liftLimits()` IS ONE-WAY, AND IT GOES BEFORE `renounceOwnership()`.
     *      That ordering is the whole of `DEPLOY-SAFETY-PREFLIGHT.md §3`:
     *      renounce first and the 1%/0.5% launch caps are enforced forever with
     *      nobody able to lift them. Locally the caps have to go anyway — a
     *      6,000,000 BNBULL liquidity seed is far over a 1% wallet cap — and
     *      nothing is renounced here at all. On mainnet the token is
     *      four.meme's (`DECISIONS.md §4`), so none of this runs; if we ever do
     *      deploy `BNBull.sol` ourselves, use `script/OneWaySwitches.s.sol`,
     *      which enforces the order.
     */
    function _openToken(Cfg memory c, Deployment memory d) private {
        if (c.ext.bnbull != d.bnbull) return;
        BNBull t = BNBull(d.bnbull);
        if (t.owner() != c.roles.deployer) return; // a pre-existing token
        // Idempotent: a resumed run must not die on `TradingAlreadyOpen`.
        if (t.tradingEnabled() && !t.limitsActive()) return;

        if (!t.tradingEnabled()) {
            t.setAntiBotBlocks(0);
            t.enableTrading();
        }
        if (t.limitsActive()) t.liftLimits();

        address[] memory wl = new address[](8);
        wl[0] = d.mintDrop;
        wl[1] = d.duel;
        wl[2] = d.graveyard;
        wl[3] = d.jackpotBnbull;
        wl[4] = d.jackpotBnb;
        wl[5] = d.marketplace;
        wl[6] = d.mintSplitter;
        wl[7] = d.reviveSplitter;
        t.setWhitelistBulk(wl, true);

        address[] memory wl2 = new address[](1);
        wl2[0] = c.ext.routerV2;
        t.setWhitelistBulk(wl2, true);

        console2.log("");
        console2.log("-- BNBULL opened for local trading (limits lifted, anti-bot off) --");
    }

    // ─── Liquidity ──────────────────────────────────────────────────────

    function _seedLiquidity(Cfg memory, Deployment memory d) private {
        // Idempotent: a resumed run must not double the book and halve the
        // price everything downstream was configured against.
        if (router.reserve(address(wbnb), d.bnbull) > 0) {
            console2.log("");
            console2.log("-- liquidity already seeded, skipping --");
            return;
        }
        uint256 bnbSide = 100e18;
        uint256 bullSide = 6_000_000e18; // 60,000 BNBULL per BNB -> $0.01

        // Wrap the BNB the pool needs.
        wbnb.deposit{value: bnbSide * 2}();

        IERC20(address(wbnb)).approve(address(router), type(uint256).max);
        IERC20(d.bnbull).approve(address(router), type(uint256).max);

        router.seed(address(wbnb), d.bnbull, bnbSide, bullSide);

        console2.log("");
        console2.log("-- liquidity seeded --");
        console2.log("  WBNB/BNBULL   100 WBNB / 6,000,000 BNBULL");
        console2.log("  1 BNB quotes ", router.quote(1e18, address(wbnb), d.bnbull), "BNBULL");
    }

    // ─── Names ──────────────────────────────────────────────────────────

    /// @dev Published and FROZEN locally, so the local chain exercises the
    ///      one-way path rather than leaving it for the day it matters.
    function _publishNames(Deployment memory d) private {
        Bulls b = Bulls(d.bulls);
        if (b.namesFrozen()) return;

        string[] memory names = readNames();
        for (uint256 start = 1; start <= 501; start += 100) {
            uint256 end = start + 99;
            if (end > 501) end = 501;
            string[] memory chunk = new string[](end - start + 1);
            for (uint256 i = 0; i < chunk.length; i++) {
                chunk[i] = names[start - 1 + i];
            }
            b.setNames(start, chunk);
        }
        b.freezeNames();

        console2.log("");
        console2.log("-- names published and FROZEN --");
        console2.log("  #1  ", b.nameOf(1));
        console2.log("  #501", b.nameOf(501));
    }

    // ─── Output ─────────────────────────────────────────────────────────

    function _writeEnvLocal(Cfg memory c, Deployment memory d) private {
        string memory env = string.concat(
            "# bnbulls - LOCAL ANVIL. Generated by script/anvil/DeployLocal.s.sol.\n",
            "# Paste into frontend/.env.local. These addresses are worthless off\n",
            "# this anvil instance and are regenerated on every fresh chain.\n",
            "NEXT_PUBLIC_CHAIN_ID=31337\n",
            "NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545\n",
            "NEXT_PUBLIC_RPC_URL_FALLBACK=http://127.0.0.1:8545\n",
            "NEXT_PUBLIC_EXPLORER_BASE_URL=http://127.0.0.1:8545\n",
            "NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=\n"
        );
        env = string.concat(
            env,
            "NEXT_PUBLIC_BNBULL_TOKEN=", vm.toString(d.bnbull), "\n",
            "NEXT_PUBLIC_BULLS_NFT=", vm.toString(d.bulls), "\n",
            "NEXT_PUBLIC_MINTDROP=", vm.toString(d.mintDrop), "\n",
            "NEXT_PUBLIC_DUEL=", vm.toString(d.duel), "\n",
            "NEXT_PUBLIC_GRAVEYARD=", vm.toString(d.graveyard), "\n",
            "NEXT_PUBLIC_JACKPOT_BNBULL=", vm.toString(d.jackpotBnbull), "\n",
            "NEXT_PUBLIC_JACKPOT_BNB=", vm.toString(d.jackpotBnb), "\n",
            "NEXT_PUBLIC_MARKETPLACE=", vm.toString(d.marketplace), "\n",
            "NEXT_PUBLIC_DEPLOY_BLOCK=", vm.toString(d.deployBlock), "\n"
        );
        env = string.concat(
            env,
            "NEXT_PUBLIC_SITE_URL=http://localhost:3000\n",
            "NEXT_PUBLIC_X_URL=https://x.com/WeAreBNBulls\n",
            "NEXT_PUBLIC_TELEGRAM_URL=https://t.me/WeAreBNBulls\n",
            "\n# not read by the frontend, but the keepers and the seed step need them:\n",
            "# LOCAL_WBNB=", vm.toString(c.ext.wbnb), "\n",
            "# LOCAL_ROUTER=", vm.toString(c.ext.routerV2), "\n",
            "# LOCAL_FEED=", vm.toString(c.ext.priceFeed), "\n",
            "# LOCAL_VRF=", vm.toString(c.ext.vrfCoordinator), "\n",
            "# MINT_SPLITTER=", vm.toString(d.mintSplitter), "\n",
            "# REVIVE_SPLITTER=", vm.toString(d.reviveSplitter), "\n"
        );

        vm.writeFile(".state/anvil/frontend.env.local", env);

        console2.log("");
        console2.log("================ paste into frontend/.env.local ================");
        console2.log(env);
        console2.log("===============================================================");
        console2.log("also written to .state/anvil/frontend.env.local");
    }
}
