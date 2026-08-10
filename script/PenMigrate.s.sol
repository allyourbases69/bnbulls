// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "./lib/BnbullsConfig.sol";
import {LadderRebase} from "./lib/LadderRebase.sol";

import {Bulls} from "../contracts/Bulls.sol";
import {BullPen} from "../contracts/BullPen.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Jackpot} from "../contracts/Jackpot.sol";

/// @dev The two coordinator calls the pre-flight needs. Chainlink's own
///      interface pulls in the whole v2.5 surface; this is the read plus the
///      one write, and nothing else.
interface IVrfSubscription {
    function getSubscription(uint256 subId)
        external
        view
        returns (
            uint96 balance,
            uint96 nativeBalance,
            uint64 reqCount,
            address subOwner,
            address[] memory consumers
        );
    function addConsumer(uint256 subId, address consumer) external;
}

/**
 * @title PenMigrateBase
 * @notice Shared reads for the BullPen migration.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT THIS MIGRATION IS, IN ONE PARAGRAPH
 *      ══════════════════════════════════════════════════════════════════════
 *      `Bulls.rarityOf(id)` is a public view over a table fixed at deploy, and
 *      `Bulls.nextTokenId()` is public. Anyone can therefore call
 *      `rarityOf(nextTokenId())` and know exactly what the next mint yields.
 *      `BullPen` fixes that by taking WHEN you buy out of the decision of WHICH
 *      bull you get. It cannot be retro-fitted to the live `MintDrop`, because
 *      that contract's pen slot has never been bootstrapped and bootstrapping
 *      is the only instant path — so the drop is replaced rather than re-wired.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE ONE IRREVERSIBLE STEP, AND WHY IT IS LAST
 *      ══════════════════════════════════════════════════════════════════════
 *      Stocking the pen means owner-minting the ENTIRE remaining supply to it.
 *      `Bulls` has no burn and `nextTokenId` never goes backwards, so the
 *      moment that lands the collection is permanently fully minted and the
 *      only route to a bull is the pen. If the pen is not wired, not seeded
 *      with VRF, or wired to a drop that is not the one taking money, the
 *      supply is stranded in a contract that will never hand it out.
 *
 *      Every other step in this file is reversible or repeatable. That one is
 *      not, so it is gated behind `PreflightPen`, which asserts all of it on
 *      chain rather than trusting a runbook.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT IS DELIBERATELY *NOT* RE-POINTED, AND WHY
 *      ══════════════════════════════════════════════════════════════════════
 *      Three slots elsewhere in the system name the OLD `MintDrop`. All three
 *      are TIMELOCKED (24h propose -> commit), and none of them needs to move:
 *
 *        `Bulls.Wire.MintDrop`   — the minter role. The new drop never calls
 *                                  `bulls.mint()` at all: with a pen wired,
 *                                  `_mintAndEmit` takes the `reserve` branch.
 *                                  And after the pre-mint `nextTokenId` is 501,
 *                                  so `Bulls.mint()` reverts `SupplyExhausted`
 *                                  for EVERY caller including the owner. The
 *                                  slot is inert.
 *        `Duel.Wire.MintDrop`    — the BNB/USD ORACLE source, not a money
 *                                  route. `bnbUsdPrice()` is a `view` with no
 *                                  `whenNotPaused`, so it keeps answering from
 *                                  the paused old drop.
 *        `PotSplitter.Wire.MintDrop` on the mint + revive splitters — the
 *                                  20/10/never-sell POLICY source. Views only,
 *                                  same reasoning.
 *
 *      ⚠ THE CONSEQUENCE, STATED SO NOBODY HAS TO REDISCOVER IT: the old
 *      `MintDrop` is retired as a SELLER but stays live as an ORACLE and a
 *      POLICY source. Do not treat it as dead. In particular, changing
 *      `bnbullShareBps` on the old drop still moves both splitters' policy.
 *
 *      What DOES have to move is the funder role on both pots — `Jackpot.fund`
 *      reverts `NotFunder` for an unknown caller, and MintDrop catches that and
 *      ACCRUES. So a missed funder wire does not fail a mint: it silently stops
 *      the jackpots growing. That is the failure this migration is most likely
 *      to ship, so `PreflightPen` asserts it twice.
 */
abstract contract PenMigrateBase is BnbullsConfig {
    /// @dev The launch ladder's boundaries, `DECISIONS.md §12`. Only the
    ///      BOUNDARIES are rebased; the dollar column is copied off the live
    ///      contract, never re-typed here.
    uint16 internal constant LADDER_LAST = 500;

    struct Live {
        address bulls;
        address bnbull;
        address wbnb;
        address oldDrop;
        address jackpotBnbull;
        address jackpotBnb;
        address mintSplitter;
        address priceFeed;
        address routerV2;
        address vrfCoordinator;
        address keeper;
        address treasury;
        address lpTreasury;
    }

    /// @dev Everything the migration touches, read from the deployment record
    ///      and then from the LIVE CONTRACTS. Nothing is hardcoded and nothing
    ///      is taken from env: env is what shipped the 1,250x peg leak twice.
    function readLive() internal view returns (Live memory L) {
        Deployment memory d = readDeployment();
        L.oldDrop = d.mintDrop;
        L.jackpotBnbull = d.jackpotBnbull;
        L.jackpotBnb = d.jackpotBnb;
        L.mintSplitter = d.mintSplitter;

        MintDrop m = MintDrop(d.mintDrop);
        // ⚠ READ OFF THE DROP, NOT OFF THE RECORD. This is what guarantees the
        // replacement is bound to the SAME collection and the SAME token. A
        // record can be edited; an immutable cannot.
        L.bulls = address(m.bulls());
        L.bnbull = address(m.bnbull());
        L.wbnb = address(m.wbnb());
        L.treasury = m.treasury();
        L.lpTreasury = m.lpTreasury();
        L.keeper = m.keeper();
        (L.priceFeed, L.routerV2,,) = m.wires();

        string memory json = vm.readFile(deploymentPath());
        L.vrfCoordinator = vm.parseJsonAddress(json, ".ext.vrfCoordinator");
    }

    /// @dev The pen recorded in `deployments/<chain>.json`, or zero. Optional
    ///      read, like `.contracts.yards`: a record written before the pen
    ///      existed has no such key and `parseJsonAddress` REVERTS on a missing
    ///      one, which would make every step here refuse to open the live
    ///      record.
    function readPen() internal view returns (address pen) {
        string memory json = vm.readFile(deploymentPath());
        if (vm.keyExistsJson(json, ".contracts.bullPen")) {
            pen = vm.parseJsonAddress(json, ".contracts.bullPen");
        }
    }

    /// @dev Write one key back into the record rather than re-serialising the
    ///      whole thing. `writeDeployment` rebuilds the object from a `Cfg`
    ///      this script does not have, and a partial rebuild would silently
    ///      drop `roles`, `params` and `ext`.
    ///
    ///      ⚠ A FUTURE FULL `Deploy` RUN WILL DROP `.contracts.bullPen`, because
    ///      `writeDeployment` serialises a fixed field list. That is the SAFE
    ///      direction: a fresh collection needs a fresh pen, and inheriting a
    ///      pen bound to the previous `Bulls` would be worse than losing the
    ///      key. `deploy-fresh.ps1 -Step deploy` archives the record first, so
    ///      the address is never actually lost.
    function recordAddress(string memory key, address value) internal {
        vm.writeJson(vm.toString(value), deploymentPath(), string.concat(".contracts.", key));
    }

    /**
     * @notice The rebased ladder, derived on chain from what has ALREADY been
     *         minted. Never typed by hand.
     *
     * @dev ⚠⚠ THIS IS THE STEP THAT SILENTLY COSTS MONEY IF IT IS SKIPPED.
     *      A fresh `MintDrop` starts `totalSold = 0`. The live ladder's first
     *      rung is `upToSold: 100`, so on a fresh contract the $10 rung would
     *      run for ANOTHER 100 mints instead of the ~69 that remain — roughly
     *      thirty bulls sold at $10 that should have been $20, and nothing
     *      anywhere would report it. It is not recoverable after the fact
     *      either: those buyers keep their bulls.
     *
     *      So each boundary moves DOWN by the number already minted, the dollar
     *      column is copied verbatim off the live contract, and a rung that has
     *      been fully consumed is dropped rather than emitted as a zero.
     *
     *      ⚠ THE LAST BOUNDARY IS FORCED TO `MAX_MINT`, NOT TO WHAT REMAINS.
     *      `setPriceTiers` reverts `InvalidTiers` unless the final rung covers
     *      `MAX_MINT` (500) — there is no flat-price fallback, so a table that
     *      stops at 469 would leave mints 470..500 UNPRICED and reverting. The
     *      pen's own `PoolTooSmall` is what actually caps the drop at what is
     *      in the pen, so the extra headroom is unreachable, not loose.
     */
    function rebasedTiers(address oldDrop, uint256 minted)
        internal
        view
        returns (MintDrop.PriceTier[] memory out)
    {
        MintDrop m = MintDrop(oldDrop);
        uint256 n = m.priceTierCount();
        require(n > 0, "PenMigrate: live drop has no price ladder to rebase");
        MintDrop.PriceTier[] memory live = new MintDrop.PriceTier[](n);
        for (uint256 i = 0; i < n; i++) {
            live[i] = m.priceTierAt(i);
        }
        return LadderRebase.rebase(live, minted, LADDER_LAST);
    }

    function logTiers(string memory label, MintDrop.PriceTier[] memory t) internal pure {
        console2.log(label);
        for (uint256 i = 0; i < t.length; i++) {
            console2.log("    upToSold", t[i].upToSold);
            console2.log("      usd    ", t[i].usdPrice);
            console2.log("      bnbull ", t[i].bnbullPrice);
        }
    }
}

/**
 * @title DeployPen
 * @notice STEP 1. Deploy `BullPen` and the replacement `MintDrop`. Wires
 *         nothing, takes no money, changes nothing that is live.
 *
 * @dev Resume-safe in the same way `DeployCore` is: an address already in the
 *      record THAT HAS CODE is reused rather than redeployed. A run that dies
 *      between the two deploys therefore does not orphan the first one.
 */
contract DeployPen is PenMigrateBase {
    function run() external {
        keyGuard();
        Live memory L = readLive();

        address pen = readPen();
        address newDrop = _readNewDrop();

        console2.log("== bnbulls: deploy the pen + the replacement drop ==");
        console2.log("  chain      ", block.chainid);
        console2.log("  Bulls      ", L.bulls);
        console2.log("  old MintDrop", L.oldDrop);
        console2.log("  coordinator", L.vrfCoordinator);

        vm.startBroadcast();

        if (pen == address(0) || pen.code.length == 0) {
            // `_owner = msg.sender` because `ConfirmedOwner` is two-step and
            // passing anything else here only PROPOSES — the same trap
            // `DeployCore` documents for the two jackpots. The deployer wires
            // it and hands over later.
            pen = address(new BullPen(L.bulls, L.bnbull, msg.sender, L.vrfCoordinator));
            console2.log("  BullPen deployed   ", pen);
        } else {
            console2.log("  BullPen resumed    ", pen);
        }

        if (newDrop == address(0) || newDrop.code.length == 0) {
            newDrop = address(
                new MintDrop(
                    MintDrop.DeployParams({
                        initialOwner: msg.sender,
                        bulls: L.bulls,
                        bnbull: L.bnbull,
                        wbnb: L.wbnb,
                        // Copied off the LIVE drop, so the replacement pays the
                        // same two addresses the current one pays. Reading them
                        // beats re-confirming them: `lpTreasury` is already the
                        // splitter, so no repoint is needed after the fact.
                        treasury: L.treasury,
                        lpTreasury: L.lpTreasury
                    })
                )
            );
            console2.log("  MintDrop deployed  ", newDrop);
        } else {
            console2.log("  MintDrop resumed   ", newDrop);
        }

        vm.stopBroadcast();

        recordAddress("bullPen", pen);
        recordAddress("mintDropNext", newDrop);

        console2.log("");
        console2.log("  The new drop SHIPS PAUSED and is wired to nothing.");
        console2.log("  NEXT: -Step wire. Nothing is live until -Step switch.");
    }

    function _readNewDrop() private view returns (address a) {
        string memory json = vm.readFile(deploymentPath());
        if (vm.keyExistsJson(json, ".contracts.mintDropNext")) {
            a = vm.parseJsonAddress(json, ".contracts.mintDropNext");
        }
    }
}

/**
 * @title WirePen
 * @notice STEPS 2-4. Wire the new drop, rebase the ladder, wire the pen, and
 *         add the pen as a VRF consumer.
 *
 * @dev Idempotent throughout: every write is guarded by a read of what is
 *      already there, so a partial run is re-runnable. `forge script` sends a
 *      SEQUENCE of independent transactions and only the simulation is atomic,
 *      so "re-runnable" is a hard requirement, not a nicety.
 */
contract WirePen is PenMigrateBase {
    function run() external {
        keyGuard();
        Live memory L = readLive();
        address pen = readPen();
        address newDrop = _requireNewDrop();
        require(pen != address(0) && pen.code.length > 0, "WirePen: no BullPen in the record");

        MintDrop nd = MintDrop(newDrop);
        MintDrop od = MintDrop(L.oldDrop);
        BullPen p = BullPen(pen);
        Bulls b = Bulls(L.bulls);

        uint256 minted = uint256(b.nextTokenId()) - 1;

        // ⚠ THE VRF CONFIG IS READ OFF THE LIVE BNB JACKPOT, NOT OFF ENV.
        //  has never carried a keyHash or a subId, and
        // the env pair ( / ) is
        // exactly the class of value that shipped the peg leak twice. The live
        // pot is already funded on that subscription and already answering, so
        // copying it is both the cheapest correct answer and the one that
        // guarantees the pen shares a subscription somebody is topping up.
        bytes32 keyHash = Jackpot(L.jackpotBnb).keyHash();
        uint256 subId = Jackpot(L.jackpotBnb).subscriptionId();
        require(keyHash != bytes32(0) && subId != 0, "WirePen: the live BNB pot has no VRF config to copy");

        console2.log("== wire the pen + the replacement drop ==");
        console2.log("  new MintDrop", newDrop);
        console2.log("  BullPen     ", pen);
        console2.log("  already minted", minted);

        vm.startBroadcast();

        // ── 2. the new drop's own wiring ─────────────────────────────────
        // All four are `bootstrapWire`: the slots are still zero on a fresh
        // contract, which is the entire reason this is a same-day job rather
        // than a 24-hour timelock per slot.
        _dropWire(nd, MintDrop.Wire.PriceFeed, L.priceFeed, "PriceFeed");
        _dropWire(nd, MintDrop.Wire.Router, L.routerV2, "Router(v2)");
        _dropWire(nd, MintDrop.Wire.JackpotBnbull, L.jackpotBnbull, "JackpotBnbull");
        _dropWire(nd, MintDrop.Wire.JackpotBnb, L.jackpotBnb, "JackpotBnb");

        // ── every non-wire setting, COPIED FROM THE LIVE DROP ────────────
        // ⚠ COPIED, NOT RE-TYPED FROM CONFIG. A constant in this file is a
        // second source of truth that drifts; the live contract is the first.
        // `minPoolLiquidity` and `inlineSlippageBps` are named in the brief
        // specifically because the constructor defaults (1 ether / 500 bps)
        // happen to match today, so a re-typed value would look right while
        // being unpinned.
        if (nd.keeper() != L.keeper) {
            nd.setKeeper(L.keeper);
            console2.log("  [set] keeper", L.keeper);
        }
        if (nd.inlineSlippageBps() != od.inlineSlippageBps()) {
            nd.setInlineSlippageBps(od.inlineSlippageBps());
            console2.log("  [set] inlineSlippageBps", od.inlineSlippageBps());
        }
        if (nd.minPoolLiquidity() != od.minPoolLiquidity()) {
            nd.setMinPoolLiquidity(od.minPoolLiquidity());
            console2.log("  [set] minPoolLiquidity", od.minPoolLiquidity());
        }
        if (nd.minPoolLiquidityAlt() != od.minPoolLiquidityAlt()) {
            nd.setMinPoolLiquidityAlt(od.minPoolLiquidityAlt());
            console2.log("  [set] minPoolLiquidityAlt", od.minPoolLiquidityAlt());
        }
        if (
            nd.bnbullShareBps() != od.bnbullShareBps() || nd.bnbShareBps() != od.bnbShareBps()
        ) {
            nd.setPotShares(od.bnbullShareBps(), od.bnbShareBps());
            console2.log("  [set] potShares bnbull", od.bnbullShareBps());
            console2.log("  [set] potShares bnb   ", od.bnbShareBps());
        }
        if (nd.bnbullPaymentSellsForBnbLeg() != od.bnbullPaymentSellsForBnbLeg()) {
            nd.setBnbullPaymentSellPolicy(od.bnbullPaymentSellsForBnbLeg());
            console2.log("  [set] bnbullPaymentSellsForBnbLeg");
        }
        if (nd.lpShareBps() != od.lpShareBps()) {
            nd.setLpShare(od.lpShareBps());
            console2.log("  [set] lpShareBps", od.lpShareBps());
        }
        if (
            nd.maxOracleAge() != od.maxOracleAge() || nd.minBnbUsd() != od.minBnbUsd()
                || nd.maxBnbUsd() != od.maxBnbUsd()
        ) {
            nd.setOraclePolicy(od.maxOracleAge(), od.minBnbUsd(), od.maxBnbUsd());
            console2.log("  [set] oraclePolicy maxAge", od.maxOracleAge());
        }
        if (nd.airdropPerMint() != od.airdropPerMint()) {
            nd.setAirdropPerMint(od.airdropPerMint());
            console2.log("  [set] airdropPerMint", od.airdropPerMint());
        }
        if (nd.discountBpsOf(L.bnbull) != od.discountBpsOf(L.bnbull)) {
            nd.setDiscountBps(L.bnbull, od.discountBpsOf(L.bnbull));
            console2.log("  [set] discount bnbull", od.discountBpsOf(L.bnbull));
        }
        if (nd.discountBpsOf(address(0)) != od.discountBpsOf(address(0))) {
            nd.setDiscountBps(address(0), od.discountBpsOf(address(0)));
            console2.log("  [set] discount native", od.discountBpsOf(address(0)));
        }

        // ── 3. THE LADDER REBASE ─────────────────────────────────────────
        if (nd.priceTierCount() == 0) {
            MintDrop.PriceTier[] memory t = rebasedTiers(L.oldDrop, minted);
            nd.setPriceTiers(t);
            logTiers("  [set] REBASED price ladder:", t);
        } else {
            console2.log("  [ok]  price ladder already set");
        }

        // ── the funder roles: the silent-deferral wires ──────────────────
        // ⚠ MISS EITHER OF THESE AND NOTHING REVERTS. `Jackpot.fund` reverts
        // `NotFunder`, `MintDrop._toBnbPotOrAccrue` CATCHES it, and the slice
        // accrues into `pendingBnbPotNative` instead. Mints keep working, the
        // site keeps saying the pot grows, and the pot does not grow.
        _funder(Jackpot(L.jackpotBnbull), newDrop, "BNBULL pot <- new drop");
        _funder(Jackpot(L.jackpotBnb), newDrop, "BNB pot <- new drop");

        // ── 4. the pen ───────────────────────────────────────────────────
        if (p.seller() == address(0)) {
            p.bootstrapSeller(newDrop);
            console2.log("  [set] BullPen.seller ->", newDrop);
        } else {
            require(p.seller() == newDrop, "WirePen: pen seller points somewhere else");
            console2.log("  [ok]  BullPen.seller");
        }
        if (p.keyHash() != keyHash || p.subscriptionId() != subId) {
            p.setVrfConfig(keyHash, subId, 3, 200_000, true);
            console2.log("  [set] BullPen.vrfConfig");
        } else {
            console2.log("  [ok]  BullPen.vrfConfig");
        }

        // ⚠ THE UNIT IS THE TRAP, and it is the same trap as `DECISIONS.md
        // §40`: this bounds ORACLE LATENCY, which is time, but it counts
        // BLOCKS, so every BSC block-time reduction silently shortens it. The
        // house number is `VRF_REQUEST_TIMEOUT_BLOCKS` = 24,000, chosen after a
        // measured first live fulfilment of 3,169 blocks. Written explicitly so
        // it is a decision in the record rather than a constructor default that
        // shipped by accident, which is exactly how the jackpots got a 1,200
        // block timeout nobody chose.
        uint256 wantTimeout = vm.envOr("VRF_REQUEST_TIMEOUT_BLOCKS", uint256(24_000));
        if (p.vrfTimeoutBlocks() != wantTimeout) {
            p.setVrfTimeoutBlocks(wantTimeout);
            console2.log("  [set] BullPen.vrfTimeoutBlocks", wantTimeout);
        }

        // The pen slot on the new drop. Bootstrap, so instant — and once it
        // holds an address it can NEVER return to zero (`propose` refuses a
        // zero target), so the replacement drop can only ever sell through a
        // pen. That is asserted again in the pre-flight.
        if (nd.penContract() == address(0)) {
            nd.bootstrapWire(MintDrop.Wire.Pen, pen);
            console2.log("  [set] MintDrop.pen ->", pen);
        } else {
            require(nd.penContract() == pen, "WirePen: drop pen points somewhere else");
            console2.log("  [ok]  MintDrop.pen");
        }

        // The VRF consumer. Silent until the first `reserve`, and then every
        // mint reverts — fail-closed, but the drop is dead until it is fixed.
        _addConsumer(L.vrfCoordinator, subId, pen);

        vm.stopBroadcast();

        console2.log("");
        console2.log("  NEXT: -Step preflight. It REFUSES the pre-mint until every");
        console2.log("        one of the above is verified on chain.");
    }

    function _requireNewDrop() private view returns (address a) {
        string memory json = vm.readFile(deploymentPath());
        require(
            vm.keyExistsJson(json, ".contracts.mintDropNext"),
            "WirePen: no mintDropNext in the record - run -Step deploy first"
        );
        a = vm.parseJsonAddress(json, ".contracts.mintDropNext");
        require(a.code.length > 0, "WirePen: mintDropNext has no code");
    }

    function _dropWire(MintDrop m, MintDrop.Wire slot, address target, string memory label)
        private
    {
        (address cur,,) = m.wireOf(slot);
        if (cur == target) {
            console2.log("  [ok]  wire", label);
            return;
        }
        require(cur == address(0), string.concat("WirePen: wire already set elsewhere: ", label));
        m.bootstrapWire(slot, target);
        console2.log("  [set] wire", label);
    }

    function _funder(Jackpot p, address who, string memory label) private {
        if (p.isFunder(who)) {
            console2.log("  [ok]  funder", label);
            return;
        }
        p.setFunder(who, true);
        console2.log("  [set] funder", label);
    }

    /// @dev The subscription owner is the only caller `addConsumer` accepts.
    ///      A revert here is loud and harmless (nothing else in the run depends
    ///      on it landing), but it MUST be fixed before the pre-mint, so the
    ///      pre-flight asserts membership independently.
    function _addConsumer(address coordinator, uint256 subId, address pen) private {
        (,,,, address[] memory consumers) = IVrfSubscription(coordinator).getSubscription(subId);
        for (uint256 i = 0; i < consumers.length; i++) {
            if (consumers[i] == pen) {
                console2.log("  [ok]  VRF consumer");
                return;
            }
        }
        IVrfSubscription(coordinator).addConsumer(subId, pen);
        console2.log("  [set] VRF consumer ->", pen);
    }
}

/**
 * @title PreflightPen
 * @notice STEP 5. The gate. Read-only, and it REVERTS rather than printing a
 *         warning, because a warning in a green run is a warning nobody reads.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT THIS REFUSES, AND WHY EACH ONE IS HERE
 *      ══════════════════════════════════════════════════════════════════════
 *      Every check below corresponds to a way the pre-mint could strand the
 *      whole remaining supply in a contract that cannot hand it out, or to a
 *      way money silently stops reaching a pot. None of them are style points.
 */
abstract contract PreflightCore is PenMigrateBase {
    string[] internal _fail;
    string[] internal _warn;

    /// @dev ⛔ `internal`, NOT a separate script, so `PreMintPen` runs the
    ///      IDENTICAL code rather than a copy that drifts. A pre-flight that
    ///      lives in a different contract from the thing it gates is a
    ///      pre-flight that will eventually gate nothing.
    function runPreflight() internal {
        Live memory L = readLive();
        address pen = readPen();
        address newDrop = _readNewDrop();

        console2.log("== BULLPEN PRE-FLIGHT ==");
        console2.log("  old MintDrop", L.oldDrop);
        console2.log("  new MintDrop", newDrop);
        console2.log("  BullPen     ", pen);
        console2.log("");

        _check(pen != address(0) && pen.code.length > 0, "BullPen is missing or has no code");
        _check(
            newDrop != address(0) && newDrop.code.length > 0,
            "the replacement MintDrop is missing or has no code"
        );
        // Post-switch the record's `mintDrop` IS the new drop, and every "new
        // vs old" comparison below would then be comparing a contract with
        // itself and passing for the wrong reason.
        _check(newDrop != L.oldDrop, "the record already names the new drop as live - the switch has already happened, this pre-flight no longer means anything");
        if (_fail.length > 0) return _report();

        MintDrop nd = MintDrop(newDrop);
        MintDrop od = MintDrop(L.oldDrop);
        BullPen p = BullPen(pen);
        Bulls b = Bulls(L.bulls);

        // ── 1. the two contracts are bound to the SAME collection ────────
        // A pen over a different `Bulls` accepts the stock and can never hand
        // out anything the drop is selling. Immutables, so this can only be
        // wrong at deploy, and it is the cheapest thing to be certain about.
        _check(address(p.bulls()) == L.bulls, "BullPen.bulls is not the live collection");
        _check(address(nd.bulls()) == L.bulls, "new MintDrop.bulls is not the live collection");
        _check(address(nd.bnbull()) == L.bnbull, "new MintDrop.bnbull differs from the live drop");
        _check(address(nd.wbnb()) == L.wbnb, "new MintDrop.wbnb differs from the live drop");

        // ── 2. the pen loop is closed in BOTH directions ─────────────────
        // Half a loop is the worst outcome available here: the drop reserves
        // into a pen that refuses it (`NotSeller`), which reverts the whole
        // mint, or the pen trusts a seller that is not the one taking money.
        _check(nd.penContract() == pen, "new MintDrop is not wired to this pen");
        _check(p.seller() == newDrop, "BullPen.seller is not the new MintDrop");
        // ⚠ THE LIVE DROP PREDATES THE PEN AND HAS NO `penContract()` SELECTOR
        // AT ALL, so this REVERTS rather than returning zero. That is the
        // expected state and it is not a failure — but a bare call would take
        // the whole pre-flight down with it, which is how a safety check turns
        // into the thing that stops you running the safety check.
        try od.penContract() returns (address oldPen) {
            _check(oldPen == address(0), "the OLD drop has a pen wired - not expected");
        } catch {
            console2.log("  [info] the old drop has no pen surface at all (it predates it)");
        }

        // ── 3. VRF: the pen cannot deal a bull without a word ────────────
        _check(p.keyHash() != bytes32(0), "BullPen.keyHash is unset - reserve() reverts");
        _check(p.subscriptionId() != 0, "BullPen.subscriptionId is unset - reserve() reverts");

        // ── the two clocks a stuck buyer depends on ──────────────────────
        // The refund window MUST open before the forced-draw window, or a
        // stranger can settle a reservation whose buyer was still entitled to
        // walk away from it. The setters enforce this, but the setters are not
        // what runs on deploy day.
        _check(
            p.refundAfterBlocks() < p.vrfTimeoutBlocks(),
            "BullPen: the refund window does not open before the forced-draw window - a buyer could have an outcome forced on them before they were allowed to leave"
        );
        _check(
            p.refundAfterBlocks() >= p.MIN_REFUND_AFTER_BLOCKS(),
            "BullPen: the refund window is below the floor - it would open while VRF could still plausibly deliver"
        );
        console2.log("  [info] refund window opens after blocks", p.refundAfterBlocks());
        console2.log("  [info] forced draw opens after blocks  ", p.vrfTimeoutBlocks());

        // ⚠ ESCROW MEANS THE PEN HOLDS PLAYERS' MONEY. It should be empty
        // before the drop opens; anything here now is a leftover that will be
        // mixed with live escrow and become impossible to attribute.
        _check(address(p).balance == 0, "BullPen already holds BNB before the drop has opened - it cannot be told apart from live escrow later");
        _check(p.unroutedNative() == 0 && p.unroutedToken() == 0, "BullPen already has unrouted escrow");
        _checkVrf(L.vrfCoordinator, p.subscriptionId(), pen, b);

        // ── 4. the money path, field by field against the live drop ──────
        // ⚠ THE ONE THE OWNER RAISED. A fresh MintDrop is wired to nothing, so
        // every one of these defaults to "leg disabled" and mints keep working
        // while the pots stop growing. `_toBnbPotOrAccrue` catches and accrues,
        // so there is no revert, no alert, and no way to tell it from the
        // ordinary pre-graduation deferral.
        (address feed, address router, address potBull, address potBnb) = nd.wires();
        _check(feed == L.priceFeed, "new drop: PriceFeed wire does not match the live drop");
        _check(router == L.routerV2, "new drop: Router wire does not match the live drop");
        _check(potBull == L.jackpotBnbull, "new drop: JackpotBnbull wire is wrong");
        _check(potBnb == L.jackpotBnb, "new drop: JackpotBnb wire is wrong - MINT PROCEEDS WOULD STOP REACHING THE BNB JACKPOT");
        _check(nd.swapIntermediate() == address(0), "new drop: SwapIntermediate is wired - it must stay dormant");

        _check(Jackpot(L.jackpotBnbull).isFunder(newDrop), "BNBULL pot does not accept the new drop as a funder - every BNBULL slice would silently accrue");
        _check(Jackpot(L.jackpotBnb).isFunder(newDrop), "BNB pot does not accept the new drop as a funder - THE BNB JACKPOT WOULD SILENTLY STOP GROWING");

        _check(nd.treasury() == od.treasury(), "new drop: treasury differs from the live drop");
        _check(nd.lpTreasury() == od.lpTreasury(), "new drop: lpTreasury differs from the live drop");
        _check(nd.lpTreasury() == L.mintSplitter, "new drop: lpTreasury is not MintBnbullSplitter");
        _check(nd.keeper() == L.keeper, "new drop: keeper differs from the live drop");
        _check(nd.bnbullShareBps() == od.bnbullShareBps(), "new drop: bnbullShareBps differs");
        _check(nd.bnbShareBps() == od.bnbShareBps(), "new drop: bnbShareBps differs");
        _check(nd.lpShareBps() == od.lpShareBps(), "new drop: lpShareBps differs");
        _check(nd.bnbullPaymentSellsForBnbLeg() == od.bnbullPaymentSellsForBnbLeg(), "new drop: BNBULL sell policy differs");
        _check(nd.minPoolLiquidity() == od.minPoolLiquidity(), "new drop: minPoolLiquidity differs from the live drop");
        _check(nd.minPoolLiquidity() == 1 ether, "new drop: minPoolLiquidity is not the 1 BNB thin-pool floor");
        _check(nd.minPoolLiquidityAlt() == od.minPoolLiquidityAlt(), "new drop: minPoolLiquidityAlt differs");
        _check(nd.inlineSlippageBps() == od.inlineSlippageBps(), "new drop: inlineSlippageBps differs from the live drop");
        _check(nd.inlineSlippageBps() == 500, "new drop: inlineSlippageBps is not 500");
        _check(nd.maxOracleAge() == od.maxOracleAge(), "new drop: maxOracleAge differs");
        _check(nd.minBnbUsd() == od.minBnbUsd(), "new drop: minBnbUsd band differs");
        _check(nd.maxBnbUsd() == od.maxBnbUsd(), "new drop: maxBnbUsd band differs");
        _check(nd.airdropPerMint() == od.airdropPerMint(), "new drop: airdropPerMint differs");
        _check(nd.discountBpsOf(L.bnbull) == od.discountBpsOf(L.bnbull), "new drop: BNBULL discount differs - the always-BNBULL 10% is the whole point");
        _check(nd.discountBpsOf(address(0)) == od.discountBpsOf(address(0)), "new drop: native discount differs");
        _check(nd.feedDecimals() == od.feedDecimals(), "new drop: feedDecimals differs - the oracle wire did not read decimals()");

        // The oracle has to actually answer. `bnbUsdPrice()` reverts on a
        // stale, out-of-band or incomplete round, and a mint that reverts on
        // the price is a dead drop.
        try nd.bnbUsdPrice() returns (uint256 px) {
            console2.log("  [info] BNB/USD reads", px);
        } catch {
            _fail.push("new drop: bnbUsdPrice() REVERTS - the oracle wire is bad or the feed is stale");
        }

        // ── 5. THE LADDER REBASE ─────────────────────────────────────────
        _checkLadder(nd, od, b);

        // ── 6. the BNBULL pegs must read ZERO pre-graduation ─────────────
        // ⚠ `Wire.s.sol` WRITES this column from env and the env placeholders
        // are TESTNET values. That is the 1,250x leak that has now shipped
        // twice. This script derives the column by COPYING the live contract
        // rather than re-deriving it from env, so the leak cannot be
        // re-introduced here - but the assertion stays, because "it cannot
        // happen" is what was believed the last two times.
        uint256 tiers = nd.priceTierCount();
        for (uint256 i = 0; i < tiers; i++) {
            if (nd.priceTierAt(i).bnbullPrice != 0) {
                _fail.push("new drop: a price tier carries a NON-ZERO BNBULL peg pre-graduation");
                break;
            }
        }

        // ── 7. the pen is empty and ready to be stocked ──────────────────
        uint256 minted = uint256(b.nextTokenId()) - 1;
        uint256 remaining = uint256(b.MAX_SUPPLY()) - minted;
        console2.log("  [info] minted so far     ", minted);
        console2.log("  [info] left to pre-mint  ", remaining);
        console2.log("  [info] pen holds         ", p.poolSize());
        _check(remaining > 0, "nothing left to pre-mint - the collection is already fully minted");
        _check(
            b.mintDropContract() == L.oldDrop || b.mintDropContract() == newDrop,
            "Bulls.MintDrop points at neither drop"
        );
        _check(!b.paused(), "Bulls is PAUSED - the pre-mint would revert");
        _check(nd.paused(), "the new drop is NOT paused - it must stay closed until the switch");

        // ── 8. the retired drop still owes nobody ────────────────────────
        // ⚠ DO NOT REVOKE THE OLD DROP'S FUNDER ROLE while these are non-zero:
        // `sweepBnbullPot` / `sweepBnbPot` end in `Jackpot.fund`, so revoking
        // it strands whatever is still accrued.
        uint256 owed = od.pendingBnbullBuyNative() + od.pendingBnbullDirect()
            + od.pendingBnbPotNative() + od.pendingBnbPotBnbull();
        if (owed != 0) {
            console2.log("  [info] the OLD drop still holds deferred pot money:", owed);
            _warn.push("old drop has pending pot buckets - drain them BEFORE revoking its funder role");
        }
        if (od.lpUndelivered() != 0) {
            _warn.push("old drop has undelivered LP money - withdrawLpUndelivered before retiring it");
        }

        // ── 9. the pre-mint's own caller ─────────────────────────────────
        // `Bulls.mint` accepts the wired MintDrop or the OWNER. The wired drop
        // is the old one and it is about to be paused, so the pre-mint runs as
        // the owner. A mismatch here is a run that reverts 469 times.
        _check(b.owner() == msg.sender, "the signing wallet does not own Bulls - the pre-mint would revert NotMintDropOrOwner");
        _check(nd.owner() == msg.sender, "the signing wallet does not own the new MintDrop");
        _check(p.owner() == msg.sender, "the signing wallet does not own the BullPen");

        _report();
    }

    function _checkLadder(MintDrop nd, MintDrop od, Bulls b) private {
        uint256 minted = uint256(b.nextTokenId()) - 1;
        MintDrop.PriceTier[] memory want = rebasedTiers(address(od), minted);
        uint256 have = nd.priceTierCount();

        logTiers("  [info] the ladder the rebase demands:", want);

        if (have != want.length) {
            _fail.push("LADDER REBASE MISSING: the new drop's tier count does not match the rebase");
            return;
        }
        for (uint256 i = 0; i < want.length; i++) {
            MintDrop.PriceTier memory got = nd.priceTierAt(i);
            if (got.upToSold != want[i].upToSold) {
                // The single most expensive silent failure in this migration:
                // an un-rebased $10 rung runs for another 100 mints instead of
                // the ~69 that remain, and nobody finds out until the money is
                // gone.
                _fail.push("LADDER NOT REBASED: a tier boundary is wrong. A fresh drop starts totalSold=0, so an un-rebased $10 rung sells ~30 extra bulls at $10 that should have been $20.");
                return;
            }
            if (got.usdPrice != want[i].usdPrice) {
                _fail.push("LADDER CORRUPT: a dollar sticker moved. The rebase must move BOUNDARIES ONLY.");
                return;
            }
        }
        console2.log("  [ok]   ladder rebase matches");
    }

    function _checkVrf(address coordinator, uint256 subId, address pen, Bulls b) private {
        try IVrfSubscription(coordinator).getSubscription(subId) returns (
            uint96 linkBal, uint96 nativeBal, uint64, address, address[] memory consumers
        ) {
            bool found;
            for (uint256 i = 0; i < consumers.length; i++) {
                if (consumers[i] == pen) found = true;
            }
            _check(found, "BullPen is NOT a consumer on the VRF subscription - EVERY MINT WOULD REVERT");

            console2.log("  [info] VRF native balance", nativeBal);
            console2.log("  [info] VRF LINK balance  ", linkBal);

            // `payWithNative = true`, so the native side is the one that pays.
            // One request per RESERVATION, and a reservation can carry up to 20
            // bulls, so the worst case is one request per remaining bull.
            uint256 requests = uint256(b.MAX_SUPPLY()) - (uint256(b.nextTokenId()) - 1);
            // A deliberately blunt floor. The point is not to model Chainlink's
            // pricing, it is to refuse a subscription that is obviously empty.
            uint256 floorWei = 0.25 ether;
            if (uint256(nativeBal) < floorWei) {
                _fail.push("VRF subscription native balance is below 0.25 BNB - reserve() reverts when it runs dry, and every mint reverts with it");
            }
            console2.log("  [info] worst-case requests to drain the pen", requests);
        } catch {
            _fail.push("could not read the VRF subscription - check the coordinator and subId");
        }
    }

    function _check(bool ok, string memory why) internal {
        if (!ok) _fail.push(why);
    }

    function _readNewDrop() internal view returns (address a) {
        string memory json = vm.readFile(deploymentPath());
        if (vm.keyExistsJson(json, ".contracts.mintDropNext")) {
            a = vm.parseJsonAddress(json, ".contracts.mintDropNext");
        }
    }

    function _report() internal view {
        console2.log("");
        for (uint256 i = 0; i < _warn.length; i++) {
            console2.log("  /!\\ WARN:", _warn[i]);
        }
        if (_fail.length == 0) {
            console2.log("  PRE-FLIGHT OK. The pre-mint is permitted.");
            return;
        }
        console2.log("");
        console2.log("  REFUSING THE PRE-MINT. The pre-mint is IRREVERSIBLE:");
        console2.log("  Bulls has no burn and nextTokenId never goes backwards, so a");
        console2.log("  pen that cannot hand the supply out strands it permanently.");
        console2.log("");
        for (uint256 i = 0; i < _fail.length; i++) {
            console2.log("   X ", _fail[i]);
        }
        revert("PRE-FLIGHT FAILED - see the list above. The pre-mint is refused.");
    }
}

/// @notice STEP 5, standalone and read-only. Run it, read it, and only then
///         run `-Step premint` — which runs the identical checks again.
contract PreflightPen is PreflightCore {
    function run() external {
        runPreflight();
    }

}

/**
 * @title PreMintPen
 * @notice STEP 6. ⛔ THE IRREVERSIBLE ONE. Owner-mints every remaining bull
 *         straight into the pen.
 *
 * @dev Runs `PreflightPen`'s assertions again, in the same transaction batch,
 *      because the gap between a green pre-flight and this run is exactly where
 *      "somebody ran one more script" lives.
 *
 *      ⚠ RESUMABLE BY CONSTRUCTION. `Bulls.mint` advances `nextTokenId` one at
 *      a time, so a run that dies half way leaves a pen holding N bulls and a
 *      collection at `31 + N`. Re-running mints exactly the remainder. There is
 *      no separate resume flag to get wrong.
 */
contract PreMintPen is PreflightCore {
    function run() external {
        keyGuard();
        Live memory L = readLive();
        address pen = readPen();
        Bulls b = Bulls(L.bulls);

        require(pen != address(0) && pen.code.length > 0, "PreMint: no BullPen");

        // ⛔ THE GATE, AND IT IS THE SAME CODE `-Step preflight` RUNS, not a
        // copy of it. `_report()` REVERTS on any failure, and a revert during
        // `forge script`'s simulation stops the run before a single transaction
        // is broadcast. That is the whole safety property: there is no path
        // from a failing check to a landed mint.
        console2.log("== re-running the pre-flight inside the pre-mint ==");
        runPreflight();

        uint256 minted = uint256(b.nextTokenId()) - 1;
        uint256 remaining = uint256(b.MAX_SUPPLY()) - minted;
        require(remaining > 0, "PreMint: nothing left to mint");

        uint256 cap = vm.envOr("PREMINT_MAX", remaining);
        uint256 toMint = cap < remaining ? cap : remaining;

        console2.log("");
        console2.log("== PRE-MINT ==");
        console2.log("  minting into the pen", toMint);
        console2.log("  pen                 ", pen);
        console2.log("  first id            ", minted + 1);
        console2.log("  last id             ", minted + toMint);

        vm.startBroadcast();
        for (uint256 i = 0; i < toMint; i++) {
            b.mint(pen);
        }
        vm.stopBroadcast();

        console2.log("");
        console2.log("  pen now holds", BullPen(pen).poolSize());
        console2.log("  NEXT: -Step switch (pause the old drop, open the new one).");
    }
}

/**
 * @title SwitchPen
 * @notice STEP 7. Close the old drop, open the new one. The only step a buyer
 *         can observe, and the only one that should be quick.
 *
 * @dev ORDER IS LOAD-BEARING: pause first, then unpause. The reverse leaves a
 *      window in which BOTH drops sell — and the old one would sell by minting,
 *      which after the pre-mint reverts `SupplyExhausted`, so that window is
 *      only reverted mints rather than double-sold bulls. It is still the wrong
 *      way round, and getting it right costs nothing.
 */
contract SwitchPen is PenMigrateBase {
    function run() external {
        keyGuard();
        Live memory L = readLive();
        address pen = readPen();
        address newDrop = _requireNewDrop();

        MintDrop od = MintDrop(L.oldDrop);
        MintDrop nd = MintDrop(newDrop);
        BullPen p = BullPen(pen);
        Bulls b = Bulls(L.bulls);

        // The pen must actually be stocked. Opening a drop over an empty pen
        // makes every mint revert `PoolTooSmall`, which is fail-closed but is
        // still a dead shop with a live button.
        uint256 sellable = p.sellable();
        require(sellable > 0, "Switch: the pen is EMPTY - run -Step premint first");
        require(
            uint256(b.nextTokenId()) - 1 == uint256(b.MAX_SUPPLY()),
            "Switch: the pre-mint did not finish - re-run -Step premint"
        );
        require(nd.penContract() == pen, "Switch: the new drop is not wired to the pen");
        require(p.seller() == newDrop, "Switch: the pen does not trust the new drop");

        console2.log("== switch ==");
        console2.log("  pen sellable", sellable);

        vm.startBroadcast();
        if (!od.paused()) {
            od.pause();
            console2.log("  [set] OLD drop paused");
        } else {
            console2.log("  [ok]  OLD drop already paused");
        }
        if (nd.paused()) {
            nd.unpause();
            console2.log("  [set] NEW drop OPEN");
        } else {
            console2.log("  [ok]  NEW drop already open");
        }
        vm.stopBroadcast();

        // The record's `mintDrop` now names the live seller. Everything that
        // reads addresses from the record repoints at once.
        recordAddress("mintDropRetired", L.oldDrop);
        recordAddress("mintDrop", newDrop);

        console2.log("");
        console2.log("  deployments record repointed: contracts.mintDrop ->", newDrop);
        console2.log("  /!\\ THE FLEET AND THE FRONTEND STILL CARRY THE OLD ADDRESS.");
        console2.log("    marketing/keeper/env/common.env  MINTDROP=");
        console2.log("    frontend NEXT_PUBLIC_MINTDROP / NEXT_PUBLIC_BULLPEN");
    }

    function _requireNewDrop() private view returns (address a) {
        string memory json = vm.readFile(deploymentPath());
        require(vm.keyExistsJson(json, ".contracts.mintDropNext"), "Switch: no mintDropNext");
        a = vm.parseJsonAddress(json, ".contracts.mintDropNext");
    }
}
