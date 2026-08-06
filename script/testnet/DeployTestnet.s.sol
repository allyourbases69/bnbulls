// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";

import {DeployCore} from "../Deploy.s.sol";
import {WireCore} from "../Wire.s.sol";
import {VerifyCore} from "../Verify.s.sol";
import {Duel} from "../../contracts/Duel.sol";

/**
 * @title DeployTestnet
 * @notice The BSC testnet (chain 97) rehearsal: the REAL PancakeSwap routers,
 *         the REAL Chainlink BNB/USD feed and the REAL VRF v2.5 coordinator,
 *         with mocks only where testnet genuinely has no counterpart.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT IS REAL AND WHAT IS MOCKED, AND WHY
 *      ══════════════════════════════════════════════════════════════════════
 *      Real (all five verified on chain 97 before they went into
 *      `.env.example` — see the `_TESTNET` block there for the proof of each):
 *        WBNB, PancakeSwap v2 Router, PancakeSwap v3 SmartRouter,
 *        Chainlink BNB/USD, Chainlink VRF v2.5 Coordinator.
 *
 *      Mocked, because testnet has no counterpart at all:
 *        - **BNBULL.** four.meme is mainnet-only, so `BNBull.sol` is deployed
 *          here. It is our own contract, not a stub — the same bytecode a
 *          self-issued launch would use.
 *      (There used to be a mock payment stablecoin here, deployed with SIX
 *      decimals on purpose so the decimals path was exercised against the value
 *      that is wrong for BSC. `DECISIONS.md §26` deleted the asset. The
 *      read-never-assume discipline it was rehearsing now applies to BNBULL,
 *      whose `decimals()` every contract still READS at wiring time — and
 *      `test/MarketplaceDecimals.t.sol` exercises a non-18dp BNBULL for it.)
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ EVERY BNBULL SWAP LEG WILL DEFER. THAT IS THE POINT.
 *      ══════════════════════════════════════════════════════════════════════
 *      There is no BNBULL/WBNB pool on testnet, so every buyback that needs a
 *      swap fails and accrues. Do not "fix" that by seeding a fake pool: it is
 *      an exact rehearsal of the mainnet launch state (`DECISIONS.md §22`) —
 *      BNBULL trades on four.meme's bonding curve and there is NO PancakeSwap
 *      pair at all until the curve fills. `RehearsePreLiquidity.s.sol` asserts
 *      the deferral happens, the buckets grow, and nothing reverts.
 *
 *      Run `Verify` with `ALLOW_DEFERRALS=true` after any rehearsal traffic.
 */
contract DeployTestnet is DeployCore, WireCore, VerifyCore {
    error NotBscTestnet(uint256 chainid);

    function run() external {
        if (block.chainid != CHAIN_BSC_TESTNET) revert NotBscTestnet(block.chainid);

        address deployer = msg.sender;
        keyGuard(); // no-op off mainnet: testnet may use PRIVATE_KEY
        Cfg memory c = loadConfig(deployer);

        string[] memory names = readNames();
        c.params.namesCommitment = namesCommitment(names);
        c.params.masterSeed = readMasterSeed();

        Deployment memory prev = readDeploymentOrEmpty();

        console2.log("== bnbulls BSC TESTNET rehearsal (chain 97) ==");
        console2.log("  deployer", deployer);
        console2.log("  balance ", deployer.balance);

        vm.startBroadcast();

        vm.stopBroadcast();

        preflight(c);

        vm.startBroadcast();
        Deployment memory d = deployAll(c, prev);
        wireAll(c, d);
        vm.stopBroadcast();

        console2.log("");
        logDeployment(d);
        // Record BEFORE verifying: verify reverts on any gap and the addresses
        // are what you need to fix it.
        writeDeployment(c, d);

        verifyAll(c, d);

        console2.log("");
        console2.log("== NEXT, AND IT CANNOT BE SCRIPTED ==");
        console2.log("  1. vrf.chain.link -> BNB Chain Testnet -> Create Subscription");
        console2.log("  2. Fund it with testnet LINK or testnet BNB");
        console2.log("  3. Add BOTH Jackpot addresses above as consumers");
        console2.log("  4. Put the subscription id in VRF_SUBSCRIPTION_ID_TESTNET");
        console2.log("  5. Re-run this script (it resumes) so setVrfConfig lands");
        console2.log("");
        console2.log("  Until then: tickets OPEN normally on every decisive duel and");
        console2.log("  requestResolve reverts VrfNotConfigured. Fights are unaffected.");
        console2.log("  The pot simply never pays, with no error anywhere.");
        console2.log("");
        console2.log("  THEN: script/Names.s.sol:SetNames, then");
        console2.log("        script/testnet/RehearsePreLiquidity.s.sol");
    }

}
