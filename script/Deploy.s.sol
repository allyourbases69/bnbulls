// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "./lib/BnbullsConfig.sol";

import {BNBull} from "../contracts/BNBull.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Duel} from "../contracts/Duel.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {Marketplace} from "../contracts/Marketplace.sol";
import {MintBnbullSplitter} from "../contracts/MintBnbullSplitter.sol";
import {ReviveBuySplitter} from "../contracts/ReviveBuySplitter.sol";

/**
 * @title DeployCore
 * @notice The deployment itself, in dependency order, with nothing wired.
 *         `Deploy` runs it from env; `anvil/DeployLocal` runs the SAME code
 *         against locally-deployed mocks, so the local rehearsal exercises the
 *         real path and not a parallel one.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      OWNERSHIP: EVERYTHING IS DEPLOYED TO THE DEPLOYER, THEN HANDED OVER
 *      ══════════════════════════════════════════════════════════════════════
 *      Every contract here takes an `initialOwner`, and `Wire.s.sol` needs to
 *      make ~50 `onlyOwner` calls. Deploying straight to a cold multisig would
 *      mean 50 multisig transactions. So the deployer owns everything through
 *      the wiring, and `Handover.s.sol` transfers at the end — after
 *      `Verify.s.sol` has proved the wiring is complete.
 *
 *      ⚠ THE TWO JACKPOTS ARE NOT `Ownable`. They are Chainlink
 *      `ConfirmedOwner`, which is TWO-STEP: the constructor's `_owner`
 *      argument only *proposes*, and the intended owner must call
 *      `acceptOwnership()` from its own key. Deploying a pot straight to a
 *      multisig therefore leaves it owned by the DEPLOYER until that
 *      acceptance lands — which reads as "the handover worked" on a block
 *      explorer and is not true. So the pots are deployed with `_owner = 0`
 *      (constructor keeps `msg.sender`) and handed over explicitly, last.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE LP TREASURY CHICKEN-AND-EGG
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop`'s constructor REVERTS on a zero `lpTreasury`, but the
 *      splitter that slot eventually points at is deployed after it (it needs
 *      the pot addresses, which need... nothing, but the ordering in
 *      `DEPLOY-SAFETY-PREFLIGHT §5` puts splitters last and there is no reason
 *      to fight it). So MintDrop is constructed with `LP_TREASURY` — an address
 *      the operator has already confirmed through the treasury guard — and
 *      `Wire.s.sol` repoints it at `MintBnbullSplitter`. `lpShareBps` is 0
 *      throughout, so no money moves through that slot either way.
 *
 *      **Never leave it pointed at an address you do not control, even at 0%.**
 *      On fefers `Graveyard.lpTreasury` is STILL the dead rehearsal wallet,
 *      inert only because the share is zero.
 */
abstract contract DeployCore is BnbullsConfig {
    /**
     * @notice Deploy in dependency order. MUST be called inside a broadcast.
     * @dev Order is `DEPLOY-SAFETY-PREFLIGHT.md §5.5`:
     *      NFT -> MintDrop -> Duel -> Graveyard -> both Jackpots -> Marketplace
     *      -> splitters. The BNBULL token comes first when we deploy it at all.
     */
    function deployAll(Cfg memory c) internal returns (Deployment memory d) {
        return deployAll(c, readDeploymentOrEmpty());
    }

    /**
     * @notice Resumable deploy. Anything in `prev` that HAS CODE right now is
     *         reused; everything else is deployed.
     * @dev Deliberately keyed on `code.length`, not on the record. A run that
     *      dies mid-broadcast leaves a record written during simulation that
     *      describes contracts which were never delivered — trusting it would
     *      "resume" onto ten empty addresses and produce a deployment that
     *      verifies as fully wired and does nothing.
     */
    function deployAll(Cfg memory c, Deployment memory prev)
        internal
        returns (Deployment memory d)
    {
        // The cursor every keeper and indexer starts from. Taken BEFORE the
        // first deploy tx, so it can only ever be early — an early cursor
        // re-reads a few empty blocks; a late one loses events forever, and a
        // zero one forces a full-chain rescan on every restart
        // (`DEPLOY-SAFETY-PREFLIGHT.md §4`, launch day).
        //
        // Clamped to 1 because a fresh anvil sits at block 0 and "never 0" is
        // the rule the keepers rely on. `scripts/record-deploy.mjs` refines
        // this to the exact receipt block from the broadcast artifact.
        d.deployBlock = prev.deployBlock != 0
            ? prev.deployBlock
            : (block.number == 0 ? 1 : block.number);

        // ── 0. BNBULL token ─────────────────────────────────────────────
        // `DECISIONS.md §4` puts the launch on four.meme, so on mainnet this
        // address normally already exists. `loadConfig` refuses a blank one on
        // chain 56 unless DEPLOY_BNBULL is explicitly true. On chain 97
        // four.meme does not exist at all, so the rehearsal always deploys one.
        if (c.ext.bnbull != address(0)) {
            d.bnbull = c.ext.bnbull;
            console2.log("  BNBULL token (pre-existing)", d.bnbull);
        } else {
            d.bnbull = _resume(prev.bnbull, "BNBull");
            if (d.bnbull == address(0)) {
                d.bnbull = address(
                    new BNBull(c.roles.deployer, c.roles.deployer, c.params.bnbullSupply)
                );
                console2.log("  BNBull deployed", d.bnbull);
            }
            c.ext.bnbull = d.bnbull;
        }

        // ── 1. Bulls (ERC-721) ──────────────────────────────────────────
        // `namesCommitment` is committed HERE, before anything is sold, and is
        // immutable. The dealt table is published afterwards by `SetNames` and
        // checked against it.
        d.bulls = _resume(prev.bulls, "Bulls");
        if (d.bulls == address(0)) {
            d.bulls = address(
                new Bulls(
                    c.roles.deployer,
                    c.params.masterSeed,
                    c.params.namesCommitment
                )
            );
        }

        // ── 2. MintDrop ─────────────────────────────────────────────────
        d.mintDrop = _resume(prev.mintDrop, "MintDrop");
        if (d.mintDrop == address(0)) {
            d.mintDrop = address(
                new MintDrop(
                    MintDrop.DeployParams({
                        initialOwner: c.roles.deployer,
                        bulls: d.bulls,
                        bnbull: d.bnbull,
                        wbnb: c.ext.wbnb,
                        treasury: c.roles.mintTreasury,
                        lpTreasury: c.roles.lpTreasury
                    })
                )
            );
        }

        // ── 3. Duel ─────────────────────────────────────────────────────
        // EIP-712 domain "BNBullsDuel" / version "1" is baked in as a constant
        // and set BEFORE the first deploy (`DECISIONS.md §13`) — fefers carries
        // "Stable WarriorsDuel" sweep scars because that was not done.
        d.duel = _resume(prev.duel, "Duel");
        if (d.duel == address(0)) {
            d.duel = address(
                new Duel(
                    Duel.DeployParams({
                        initialOwner: c.roles.deployer,
                        bulls: d.bulls,
                        bnbull: d.bnbull,
                        wbnb: c.ext.wbnb,
                        trustedSigner: c.roles.trustedSigner,
                        devTreasury: c.roles.devTreasury,
                        defaultDevShareBps: c.params.duelDefaultDevBps
                    })
                )
            );
        }

        // ── 4. Graveyard ────────────────────────────────────────────────
        d.graveyard = _resume(prev.graveyard, "Graveyard");
        if (d.graveyard == address(0)) {
            d.graveyard = address(
                new Graveyard(c.roles.deployer, d.bulls, d.bnbull, c.roles.resurrectTreasury)
            );
        }

        // ── 5. The two pots ─────────────────────────────────────────────
        // Same token-agnostic contract, twice. `address(this)` in the roll is
        // what keeps them from rolling identically — 600 duels on Stable gave
        // 7 payouts on one pot and 0 on the other before that line existed.
        //
        // `_owner = 0` keeps ConfirmedOwner's `msg.sender` (the deployer). See
        // the header: passing the real owner here would only PROPOSE.
        d.jackpotBnbull = _resume(prev.jackpotBnbull, "Jackpot BNBULL");
        if (d.jackpotBnbull == address(0)) {
            d.jackpotBnbull = address(new Jackpot(d.bnbull, address(0), c.ext.vrfCoordinator, 50));
        }
        d.jackpotBnb = _resume(prev.jackpotBnb, "Jackpot BNB");
        if (d.jackpotBnb == address(0)) {
            d.jackpotBnb = address(new Jackpot(c.ext.wbnb, address(0), c.ext.vrfCoordinator, 100));
        }

        // ── 6. Marketplace ──────────────────────────────────────────────
        d.marketplace = _resume(prev.marketplace, "Marketplace");
        if (d.marketplace == address(0)) {
            d.marketplace = address(
                new Marketplace(
                    d.bulls, c.roles.feeTreasury, c.params.marketplaceFeeBps, c.roles.deployer
                )
            );
        }

        // ── 7. Splitters ────────────────────────────────────────────────
        //
        // THREE of them, because there are three different policies:
        //
        //   mintSplitter    20/10/70, retains the dev share. The `lpTreasury`
        //                   hook on MintDrop and Graveyard.
        //   reviveSplitter  100% to the pots, 2:1 BNBULL:BNB. The Graveyard's
        //                   donation target — the caller has ALREADY taken its
        //                   70%, which is what makes a revive 20/10/70 overall.
        //   marketSplitter  100% BNBULL, 0% BNB. The Marketplace's
        //                   `jackpotFeeBps` slice (`DECISIONS.md §21`), which
        //                   the Marketplace header specifies as buying BNBULL
        //                   into the no-withdraw pot — not splitting across
        //                   both. It is a `ReviveBuySplitter` because that is
        //                   the shape with `donatePotToken`, the selector the
        //                   Marketplace pushes tokens with.
        d.mintSplitter = _resume(prev.mintSplitter, "MintBnbullSplitter");
        if (d.mintSplitter == address(0)) {
            d.mintSplitter =
                address(new MintBnbullSplitter(c.roles.deployer, c.ext.wbnb, c.roles.keeper));
        }
        d.reviveSplitter = _resume(prev.reviveSplitter, "ReviveBuySplitter");
        if (d.reviveSplitter == address(0)) {
            d.reviveSplitter =
                address(new ReviveBuySplitter(c.roles.deployer, c.ext.wbnb, c.roles.keeper));
        }
        d.marketSplitter = _resume(prev.marketSplitter, "MarketPotSplitter");
        if (d.marketSplitter == address(0)) {
            d.marketSplitter =
                address(new ReviveBuySplitter(c.roles.deployer, c.ext.wbnb, c.roles.keeper));
        }
    }
}

/**
 * @title Deploy
 * @notice `forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast`
 *
 * @dev Blocking pre-flight, in this order, before a single byte is broadcast:
 *        1. `keyGuard`      — mainnet refuses a plaintext key and demands the
 *                             keystore snapshot (rules 2 + §2).
 *        2. `loadConfig`    — every required address by name, no fallbacks.
 *        3. `treasuryGuard` — every payout line diffed against the deployer
 *                             (rule 1). This is the one that was missing.
 *
 *      Nothing is written back into any env file. The record lands in
 *      `deployments/<chainid>.json` (or `.state/anvil/` locally), which is why
 *      a fork rehearsal cannot poison the mainnet config.
 */
contract Deploy is DeployCore {
    function run() external {
        address deployer = msg.sender;

        keyGuard();
        Cfg memory c = loadConfig(deployer);

        string[] memory names = readNames();
        c.params.namesCommitment = namesCommitment(names);
        c.params.masterSeed = readMasterSeed();

        treasuryGuard(c);
        preflight(c);

        console2.log("== bnbulls deploy ==");
        console2.log("  chain   ", block.chainid);
        console2.log("  deployer", deployer);
        console2.log("  seed    ", c.params.masterSeed);
        console2.log("  names   ", names.length);
        console2.logBytes32(c.params.namesCommitment);

        vm.startBroadcast();
        Deployment memory d = deployAll(c);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== deployed ==");
        logDeployment(d);
        writeDeployment(c, d);

        console2.log("");
        console2.log("  NEXT: script/Wire.s.sol, then script/Verify.s.sol.");
        console2.log("  NOTHING IS WIRED YET. An unwired pot silently defers every buyback.");
    }
}
