// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "./lib/BnbullsConfig.sol";

import {Bulls} from "../contracts/Bulls.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";

/**
 * @title MigrateNative
 * @notice Replace the live `Duel` with `DuelNative` and the WBNB `Jackpot`
 *         with `JackpotNative`, so no player ever holds or receives WBNB.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS EXISTS
 *      ══════════════════════════════════════════════════════════════════════
 *      The deployed `Duel._payStake` is `IERC20.safeTransfer` and the deployed
 *      `Jackpot.prizeToken` is `immutable` WBNB, so a duel winner and a
 *      jackpot winner both receive WBNB TOKENS. That is not a configuration we
 *      chose; it is what the bytecode does, and it cannot be fixed by any
 *      setter, any wiring change or any amount of UI copy. Hence new
 *      contracts.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT IS **NOT** REPLACED, AND WHY THAT IS THE WHOLE TRICK
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop`, the three splitters and the BNBULL pot are UNTOUCHED.
 *
 *      `JackpotNative.fund(uint256,string)` keeps the OLD WBNB ABI byte for
 *      byte and unwraps inside the same transaction (`_unwrap`, measured on
 *      both legs). So every existing funder — MintDrop and the three
 *      splitters — keeps calling exactly what it called yesterday and needs no
 *      redeploy. That single decision is what turns "replace the money layer"
 *      into "replace two contracts".
 *
 *      The BNBULL pot stays ERC-20 on purpose: $BNBULL genuinely IS a token,
 *      so there is no WBNB to remove there and replacing it would strand its
 *      balance for nothing.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      TWO STAGES, BECAUSE **SEVEN** WIRES ARE TIMELOCKED
 *      ══════════════════════════════════════════════════════════════════════
 *      `TimelockedAddress.bootstrap` REVERTS once a slot is set, so every slot
 *      that already points at an old contract must go the long way round:
 *
 *        Bulls.Duel                propose -> delay -> commit
 *        Graveyard.Duel            propose -> delay -> commit
 *        JackpotBnbull.duel        propose -> delay -> commit
 *        MintDrop.JackpotBnb       propose -> delay -> commit
 *        mintSplitter.JackpotBnb   propose -> delay -> commit
 *        reviveSplitter.JackpotBnb propose -> delay -> commit
 *        marketSplitter.JackpotBnb propose -> delay -> commit
 *
 *      ⚠ THE LAST FOUR ARE THE ONES AN EARLIER DRAFT MISSED. "MintDrop and the
 *      splitters need no REDEPLOY" is true, and was mistaken for "need no
 *      REWIRE". Each of them holds its own timelocked `Wire.JackpotBnb`, and on
 *      chain today all four still read the OLD pot. `MintDrop._toBnbPot` and
 *      `PotSplitter` read that slot and `fund()` whatever is in it, so without
 *      these four repoints every mint and every revive would keep paying real
 *      money into a pot whose balance can never be withdrawn, only won —
 *      forever, and silently, with the new pot earning nothing.
 *
 *      The delay is `wiringDelay` on each contract: 24h as deployed, and
 *      lowered to the 6h floor (`MIN_WIRING_DELAY`) for this migration. There
 *      is no owner path to zero — the contracts' own comment is that a shorter
 *      delay "would make the timelock decorative".
 *
 *      Stage 1 (`MigrateNative`) deploys, wires everything that can be wired
 *      immediately, and PROPOSES those seven. Stage 2 (`MigrateNativeCommit`)
 *      COMMITS them after the delay, checking before AND after that each slot
 *      holds the address it was told to expect.
 *
 *      ⚠ THE OLD DUEL KEEPS WORKING THROUGHOUT STAGE 1. Nothing points at the
 *      new one until stage 2 commits, so there is no downtime and no partial
 *      state: fights keep settling on the old contract while the clock runs.
 *      Do NOT flip the frontend until stage 2 has committed and verified.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT IS PERMANENTLY LOST AT CUTOVER
 *      ══════════════════════════════════════════════════════════════════════
 *      `Jackpot.sweepForeignToken` REVERTS on the prize token — pot money can
 *      never be withdrawn, only won. Whatever sits in the OLD WBNB pot when
 *      the wires flip is stranded forever. It was ~0.0045 WBNB (~$2.72) when
 *      this was written and it grows with every mint and every fight, so the
 *      cheapest cutover is the earliest one. `stage1` prints the live figure.
 */
abstract contract MigrateCore is BnbullsConfig {
    /// @dev Everything stage 2 needs to find, written by stage 1.
    struct Migration {
        address newDuel;
        address newJackpotBnb;
        address oldDuel;
        address oldJackpotBnb;
        address jackpotBnbull;
        address bulls;
        address graveyard;
        address mintDrop;
        address marketplace;
        address mintSplitter;
        address reviveSplitter;
        address marketSplitter;
        /// ⚠ THE CONSENT GATE. `DuelNative._requireInYards` returns EARLY on an
        ///   unwired slot, so a zero here is not "no yards", it is NO CHECK AT
        ///   ALL — every bull in the collection becomes fightable by anyone who
        ///   can get a signature, whether or not its owner ever entered it, and
        ///   `eject()` becomes decorative. Losses still accrue and the fifth
        ///   kills. The first draft of this script omitted it entirely.
        address yards;
        /// The BNBULL token, taken from the RECORD not the env. It is a
        /// constructor `immutable` on the new Duel, so a mismatch is a
        /// redeploy, not a setter call. Same override `Wire.s.sol:899` makes.
        address bnbull;
    }

    /**
     * @dev Read the live deployment and refuse if anything the migration
     *      touches is missing. A migration onto a half-read record is how you
     *      wire a live game to an empty address.
     */
    function loadMigration() internal view returns (Migration memory m) {
        Deployment memory d = readDeploymentOrEmpty();

        m.oldDuel = d.duel;
        m.oldJackpotBnb = d.jackpotBnb;
        m.jackpotBnbull = d.jackpotBnbull;
        m.bulls = d.bulls;
        m.graveyard = d.graveyard;
        m.mintDrop = d.mintDrop;
        m.marketplace = d.marketplace;
        m.mintSplitter = d.mintSplitter;
        m.reviveSplitter = d.reviveSplitter;
        m.marketSplitter = d.marketSplitter;
        m.yards = d.yards;
        m.bnbull = d.bnbull;

        // Envs let stage 2 (and a resumed stage 1) find what stage 1 built.
        m.newDuel = vm.envOr("NEW_DUEL", address(0));
        m.newJackpotBnb = vm.envOr("NEW_JACKPOT_BNB", address(0));

        _requireCodeAt("bulls", m.bulls);
        _requireCodeAt("graveyard", m.graveyard);
        _requireCodeAt("mintDrop", m.mintDrop);
        _requireCodeAt("marketplace", m.marketplace);
        _requireCodeAt("jackpotBnbull", m.jackpotBnbull);
        _requireCodeAt("oldDuel", m.oldDuel);
        _requireCodeAt("oldJackpotBnb", m.oldJackpotBnb);
        _requireCodeAt("mintSplitter", m.mintSplitter);
        _requireCodeAt("reviveSplitter", m.reviveSplitter);
        _requireCodeAt("marketSplitter", m.marketSplitter);
        // ⚠ THIS ONE IS LOAD-BEARING AND ITS ABSENCE IS SILENT. Without the
        // check, an unread `yards` reaches `bootstrapWire` as address(0), the
        // gate is disabled for the whole collection, and nothing reverts.
        _requireCodeAt("yards", m.yards);
        _requireCodeAt("bnbull", m.bnbull);
    }

    error MigrationTargetHasNoCode(string what, address addr);

    function _requireCodeAt(string memory what, address a) private view {
        if (a == address(0) || a.code.length == 0) {
            console2.log("  /!\\ live deployment is missing", what);
            console2.log("      address:", a);
            revert MigrationTargetHasNoCode(what, a);
        }
    }

    function _logMigration(Migration memory m) internal pure {
        console2.log("  bulls          ", m.bulls);
        console2.log("  graveyard      ", m.graveyard);
        console2.log("  mintDrop       ", m.mintDrop);
        console2.log("  marketplace    ", m.marketplace);
        console2.log("  yards          ", m.yards);
        console2.log("  bnbull         ", m.bnbull);
        console2.log("  mintSplitter   ", m.mintSplitter);
        console2.log("  reviveSplitter ", m.reviveSplitter);
        console2.log("  marketSplitter ", m.marketSplitter);
        console2.log("  jackpotBnbull  ", m.jackpotBnbull);
        console2.log("  OLD duel       ", m.oldDuel);
        console2.log("  OLD jackpotBnb ", m.oldJackpotBnb);
        console2.log("  NEW duel       ", m.newDuel);
        console2.log("  NEW jackpotBnb ", m.newJackpotBnb);
    }

    /**
     * @dev Should this slot be proposed at all? Read-first/skip, the same shape
     *      `Wire.s.sol` uses, so a re-run after a PARTIAL BROADCAST is a no-op
     *      rather than a revert.
     *
     *      ⚠ `TimelockedAddress.propose` has NO overwrite guard: a second
     *      propose silently replaces `pending` and RESTARTS the clock. Skipping
     *      when it already matches is what stops a resumed stage 1 quietly
     *      adding another 6h to a proposal that was nearly ripe.
     */
    function _needsPropose(address cur, address pending, address target, string memory label)
        internal
        pure
        returns (bool)
    {
        if (cur == target) return false;
        if (pending == target) return false;
        // A slot already pending a DIFFERENT address is the dangerous case —
        // proposing over it restarts the clock and stage 2 would commit
        // whichever landed last. Surface it rather than silently overwriting.
        if (pending != address(0)) {
            console2.log(string.concat("  /!\\ ", label), " already pending a DIFFERENT address:");
            console2.log("      pending:", pending);
            console2.log("      wanted :", target);
        }
        return true;
    }

    /// @dev MintDrop and PotSplitter both expose `proposeWire(uint8,address)`
    ///      and both put JackpotBnb at index 3, but they are DIFFERENT types
    ///      with different enums. Kept as two typed helpers rather than one
    ///      cross-cast, because a cast that works only because two unrelated
    ///      enums happen to agree is a landmine for whoever reorders one.
    function _proposeMintDropPot(address who, address target) internal returns (uint64 eta) {
        (address cur, address pending,) = MintDrop(who).wireOf(MintDrop.Wire.JackpotBnb);
        if (!_needsPropose(cur, pending, target, "MintDrop.JackpotBnb")) {
            console2.log("  skip  MintDrop.JackpotBnb (already wired or pending)");
            return 0;
        }
        eta = MintDrop(who).proposeWire(MintDrop.Wire.JackpotBnb, target);
        console2.log("  proposed  MintDrop.JackpotBnb      eta", eta);
    }

    function _proposeSplitterPot(address who, address target, string memory label)
        internal
        returns (uint64 eta)
    {
        (address cur, address pending,) = PotSplitter(who).wireOf(PotSplitter.Wire.JackpotBnb);
        if (!_needsPropose(cur, pending, target, label)) {
            console2.log(string.concat("  skip  ", label), "(already wired or pending)");
            return 0;
        }
        eta = PotSplitter(who).proposeWire(PotSplitter.Wire.JackpotBnb, target);
        console2.log(string.concat("  proposed  ", label), "eta", eta);
    }

    error WireConflict(string slot, address wanted, address found);

    /**
     * @dev `bootstrapWire` on a slot that is already set REVERTS `AlreadyWired`,
     *      so a resumed stage 1 would die on the first one. Skip when it
     *      already holds the target; REFUSE loudly when it holds something
     *      else, because silently continuing past a slot pointed at a stranger
     *      is how a live game ends up half-wired to an address nobody chose.
     */
    function _bootstrapWireIfNeeded(
        DuelNative duel,
        DuelNative.Wire slot,
        address target,
        string memory label
    ) internal {
        (address cur,,) = duel.wireOf(slot);
        if (cur == target) {
            console2.log(string.concat("  skip  Duel.", label), "(already wired)");
            return;
        }
        if (cur != address(0)) revert WireConflict(label, target, cur);
        duel.bootstrapWire(slot, target);
        console2.log(string.concat("  wired Duel.", label), target);
    }
}

/**
 * @title MigrateNative (STAGE 1) — deploy, wire what is immediate, propose the rest.
 * @dev Broadcast-safe to re-run: deployment is skipped for anything already in
 *      `NEW_DUEL`/`NEW_JACKPOT_BNB` with code, exactly as `Deploy.s.sol`
 *      resumes on `code.length` rather than on a record written in simulation.
 */
contract MigrateNative is MigrateCore {
    function run() external {
        address deployer = msg.sender;

        keyGuard();
        Cfg memory c = loadConfig(deployer);
        Migration memory m = loadMigration();

        // ⚠ THE TOKEN COMES FROM THE RECORD, NOT THE ENV. `bnbull` is a
        // constructor immutable on the new Duel, so a BNBULL_TOKEN that drifted
        // in a rehearsal would be baked in unfixably — a redeploy, not a
        // setter. `Wire.s.sol:899` makes the same override for the same reason.
        c.ext.bnbull = m.bnbull;

        treasuryGuard(c);
        preflight(c);

        console2.log("");
        console2.log("== NATIVE MIGRATION, STAGE 1 ==");
        _logMigration(m);

        // ── the stranded-money figure, printed before anything is signed ──
        uint256 stranded = Jackpot(m.oldJackpotBnb).pool();
        console2.log("");
        console2.log("  /!\\ WBNB STRANDED AT CUTOVER (never recoverable):", stranded);
        console2.log("      Jackpot.sweepForeignToken reverts on the prize token.");
        console2.log("      This grows with every mint and fight. Cut over early.");

        vm.startBroadcast();

        // ── 1. deploy ────────────────────────────────────────────────────
        if (m.newDuel == address(0) || m.newDuel.code.length == 0) {
            DuelNative.DeployParams memory p = DuelNative.DeployParams({
                initialOwner: deployer,
                bulls: m.bulls,
                bnbull: c.ext.bnbull,
                wbnb: c.ext.wbnb,
                trustedSigner: c.roles.trustedSigner,
                devTreasury: c.roles.devTreasury,
                defaultDevShareBps: uint16(c.params.duelDefaultDevBps)
            });
            m.newDuel = address(new DuelNative(p));
            console2.log("  deployed DuelNative     ", m.newDuel);
        } else {
            console2.log("  reusing DuelNative      ", m.newDuel);
        }

        if (m.newJackpotBnb == address(0) || m.newJackpotBnb.code.length == 0) {
            // `_owner = 0` keeps msg.sender: the pots are Chainlink
            // ConfirmedOwner (two-step), so naming another owner here would
            // leave it owned by the deployer until that party accepts, which
            // reads as a completed handover and is not one. Same rule as
            // Deploy.s.sol.
            // Odds 75 — the same literal `Deploy.s.sol:212` uses for the BNB
            // pot. It is not in `Params` because it is a launch constant, not
            // a tunable, and the constructor enforces MIN/MAX_ODDS_ONE_IN.
            m.newJackpotBnb =
                address(new JackpotNative(c.ext.wbnb, address(0), c.ext.vrfCoordinator, 75));
            console2.log("  deployed JackpotNative  ", m.newJackpotBnb);
        } else {
            console2.log("  reusing JackpotNative   ", m.newJackpotBnb);
        }

        // ── 2. wire the NEW pot (all immediate — it is a fresh contract) ──
        // EVERY step below is read-first/skip. `forge script --broadcast` sends
        // a SEQUENCE of independent transactions, not one atomic unit: if tx 7
        // reverts, txs 1-6 are already mined. Raw `bootstrap*` calls revert on
        // repeat (`AlreadyWired`, `PayoutParamsAlreadyBootstrapped`,
        // `AssetAlreadyAdded`), so a raw version of this script could never be
        // resumed after a partial run — which is exactly when you need to.
        JackpotNative pot = JackpotNative(payable(m.newJackpotBnb));

        if (pot.duel() == address(0)) pot.bootstrapDuel(m.newDuel);

        // Funders: exactly the set the old pot had. These keep calling the
        // WBNB `fund(amount, source)` ABI and the pot unwraps internally, so
        // MintDrop and the splitters need no redeploy.
        //
        // ⚠ THE FUNDER ROLE IS ONLY HALF THE JOB. It lets these contracts call
        // `fund` on the new pot; it does NOT make them do it. Each one holds
        // its own timelocked `Wire.JackpotBnb` still pointing at the OLD pot,
        // repointed in step 4 below. Granting the role and stopping there is
        // what leaves every mint paying into a stranded contract forever.
        pot.setFunder(m.mintDrop, true);
        pot.setFunder(m.mintSplitter, true);
        pot.setFunder(m.reviveSplitter, true);
        pot.setFunder(m.marketSplitter, true);
        // The new Duel's dev-cut slice: `routePotSliceInline` wraps to WBNB and
        // calls `fund(amount,"duel-devcut")` — NOT `fundNative`, which
        // `IDuelJackpot` does not declare. That is the last wrap left in the
        // system and it is a BNB->WBNB->BNB round trip, since the pot unwraps
        // it straight back. Functionally correct, deliberately noted rather
        // than described as something it is not.
        pot.setFunder(m.newDuel, true);

        pot.setRequester(c.roles.keeper, true);

        // Confirmations/gas limit are the contract's own launch defaults, the
        // same ones the live pot runs (3 / 200_000) — `Params` carries neither,
        // so reading them off the contract keeps one source of truth.
        pot.setVrfConfig(
            c.ext.vrfKeyHash,
            c.ext.vrfSubId,
            pot.requestConfirmations(),
            pot.callbackGasLimit(),
            true // payWithNative — no LINK to keep topped up
        );
        pot.setTimeouts(c.params.vrfRequestTimeoutBlocks, c.params.vrfPublicRequestDelayBlocks);
        // Same shape as `Wire.s.sol:477`: odds and payoutBps come off the pot's
        // own defaults, and the BNB pot carries the $10 dust guard. A high
        // floor makes a winning ticket silently lose, so this is a guard, not
        // a threshold.
        if (!pot.payoutParamsBootstrapped()) {
            pot.bootstrapPayoutParams(pot.oddsOneIn(), pot.payoutBps(), 0.0168 ether);
        }

        console2.log("  new pot wired: duel, 5 funders, requester, vrf, timeouts, payout params");

        // ── 3. wire the NEW Duel's own slots (fresh contract, immediate) ──
        // ⚠ `DuelNative.Wire` HAS FIVE MEMBERS. An earlier draft of this script
        // wired four and dropped `Yards` — see the struct comment. All five.
        DuelNative duel = DuelNative(payable(m.newDuel));
        _bootstrapWireIfNeeded(duel, DuelNative.Wire.Graveyard, m.graveyard, "Graveyard");
        _bootstrapWireIfNeeded(duel, DuelNative.Wire.JackpotBnbull, m.jackpotBnbull, "JackpotBnbull");
        _bootstrapWireIfNeeded(duel, DuelNative.Wire.JackpotBnb, m.newJackpotBnb, "JackpotBnb");
        _bootstrapWireIfNeeded(duel, DuelNative.Wire.MintDrop, m.mintDrop, "MintDrop");
        _bootstrapWireIfNeeded(duel, DuelNative.Wire.Yards, m.yards, "Yards (CONSENT GATE)");
        duel.setMarketplace(m.marketplace);

        // ⚠ `addFightAsset` IS ONE-SHOT AND THE CEILING IS PERMANENT. Without
        // it `_takeSide` reverts `UnsupportedAsset` and the native fight path
        // is not a thing — the UI offers it and every submit reverts.
        //
        // ⚠⚠ `type(uint16).max` IS THE "USE THE DEFAULT" SENTINEL, NOT ZERO.
        //    `addFightAsset` reads:
        //        uint16 bps = devBps == type(uint16).max ? defaultDevShareBps : devBps;
        //    so a literal 0 stores a REAL dev share of zero. `_distributePot`
        //    then skips `_payDevCut` entirely (`if (devCutA > 0)`), and
        //    `potShareBps` is a share OF the dev cut — so passing 0 here silently
        //    deletes the 10% dev revenue AND the only fight-driven funding of
        //    BOTH jackpots. Live today: devShareBpsOf = 1000 on both assets.
        //    `Wire.s.sol:370` passes the sentinel; an earlier draft here passed 0.
        if (duel.maxFightCostOf(c.ext.wbnb) == 0) {
            duel.addFightAsset(c.ext.wbnb, c.params.maxFightWbnb, type(uint16).max);
        }
        if (duel.maxFightCostOf(c.ext.bnbull) == 0) {
            duel.addFightAsset(c.ext.bnbull, c.params.maxFightBnbull, type(uint16).max);
        }

        // `fightWbnb` is a DOLLAR figure (1e18), not a WBNB amount — the BNB
        // stake is oracle-derived (`DECISIONS.md §26`).
        duel.setUsdFightPrice(c.params.fightWbnb);
        duel.setFightCost(c.ext.bnbull, c.params.fightBnbull);
        console2.log("  new duel wired: 5 slots, marketplace, 2 fight assets, usd price, bnbull cost");

        // ── 4. PROPOSE the SIX timelocked slots ──────────────────────────
        // Nothing below takes effect for `wiringDelay`. The old Duel keeps
        // serving every fight until stage 2 commits.
        //
        // ⚠⚠ THE FOUR FUNDER SLOTS ARE NOT OPTIONAL. "MintDrop and the
        //    splitters need no REDEPLOY" is true and was mistaken for "need no
        //    REWIRE". Each holds its own `Wire.JackpotBnb`, all four still
        //    reading the OLD pot (verified on chain: every one is
        //    0xb83eAf...62dA with no pending). `MintDrop._toBnbPot` and
        //    `PotSplitter` read that slot and `fund()` whatever is in it — so
        //    without these four, after cutover EVERY MINT AND EVERY REVIVE
        //    KEEPS PAYING REAL MONEY INTO THE PERMANENTLY STRANDED OLD POT and
        //    the new pot earns nothing but the duel dev-cut slice.
        uint64 e1 = Bulls(m.bulls).proposeWire(Bulls.Wire.Duel, m.newDuel);
        uint64 e2 = Graveyard(m.graveyard).proposeWire(Graveyard.Wire.Duel, m.newDuel);
        uint64 e3 = Jackpot(m.jackpotBnbull).proposeDuel(m.newDuel);
        uint64 e4 = _proposeMintDropPot(m.mintDrop, m.newJackpotBnb);
        uint64 e5 = _proposeSplitterPot(m.mintSplitter, m.newJackpotBnb, "mintSplitter.JackpotBnb  ");
        uint64 e6 = _proposeSplitterPot(m.reviveSplitter, m.newJackpotBnb, "reviveSplitter.JackpotBnb");
        // marketSplitter is 100% BNBULL / 0% BNB so its BNB leg is inert today
        // — repointed anyway, so a future policy change cannot resurrect the
        // dead pot.
        uint64 e7 = _proposeSplitterPot(m.marketSplitter, m.newJackpotBnb, "marketSplitter.JackpotBnb");

        vm.stopBroadcast();

        console2.log("");
        console2.log("== PROPOSED (timelocked, commit after the eta) ==");
        console2.log("  Bulls.Duel                eta", e1);
        console2.log("  Graveyard.Duel            eta", e2);
        console2.log("  JackpotBnbull.duel        eta", e3);
        console2.log("  MintDrop.JackpotBnb       eta", e4);
        console2.log("  mintSplitter.JackpotBnb   eta", e5);
        console2.log("  reviveSplitter.JackpotBnb eta", e6);
        console2.log("  marketSplitter.JackpotBnb eta", e7);
        console2.log("  (an eta of 0 means that slot was already wired or already pending)");
        console2.log("");
        console2.log("  NOTHING HAS CHANGED FOR PLAYERS YET. The old Duel still serves");
        console2.log("  every fight. Do NOT flip the frontend until stage 2 commits.");
        console2.log("");
        console2.log("  RECORD THESE, stage 2 needs them:");
        console2.log("    NEW_DUEL       =", m.newDuel);
        console2.log("    NEW_JACKPOT_BNB=", m.newJackpotBnb);
    }
}

/**
 * @title MigrateNativeCommit (STAGE 2) — commit the three timelocked wires.
 * @dev Run only after every eta printed by stage 1 has passed. `commit`
 *      reverts `TooEarly` otherwise, which is the safety net, not a nuisance.
 */
contract MigrateNativeCommit is MigrateCore {
    error MissingStage1Address();
    error PendingMismatch(string slot, address expected, address pending);
    error CommitDidNotTake(string slot, address expected, address got);

    function run() external {
        // ⚠ CHAIN FIRST. `loadMigration` reads the deployment record and
        // staticcalls every address in it, so on a wrong RPC it fails with
        // `MigrationTargetHasNoCode` — which reads like a corrupt record when
        // the real problem is that you are pointed at the wrong chain.
        chainGuard();
        keyGuard();
        Migration memory m = loadMigration();

        if (m.newDuel == address(0) || m.newDuel.code.length == 0) {
            console2.log("  /!\\ NEW_DUEL is unset or has no code. Stage 1 first.");
            revert MissingStage1Address();
        }

        console2.log("");
        console2.log("== NATIVE MIGRATION, STAGE 2: COMMIT ==");
        _logMigration(m);

        // ── PRE-COMMIT: is every slot pending the address we were given? ──
        // `TimelockedAddress.propose` has NO expiry and NO overwrite guard, and
        // `commit` checks only that `pending != 0` and the eta has passed — it
        // never checks WHAT it is committing. Combined with a partial stage 1
        // that was resumed without -NewDuel (deploying a SECOND pair and
        // proposing that instead), a stage 2 run with the FIRST address on the
        // command line would commit the SECOND Duel into Bulls/Graveyard while
        // the frontend and fleet point at the first. The game would split in
        // half with nothing reverting. These checks are that scenario's only
        // tripwire.
        _requirePending("Bulls.Duel", _pendingBulls(m.bulls), m.newDuel);
        _requirePending("Graveyard.Duel", _pendingGraveyard(m.graveyard), m.newDuel);
        _requirePending("JackpotBnbull.duel", _pendingJackpotDuel(m.jackpotBnbull), m.newDuel);
        _requirePending("MintDrop.JackpotBnb", _pendingMintDropPot(m.mintDrop), m.newJackpotBnb);
        _requirePending("mintSplitter.JackpotBnb", _pendingSplitterPot(m.mintSplitter), m.newJackpotBnb);
        _requirePending(
            "reviveSplitter.JackpotBnb", _pendingSplitterPot(m.reviveSplitter), m.newJackpotBnb
        );
        _requirePending(
            "marketSplitter.JackpotBnb", _pendingSplitterPot(m.marketSplitter), m.newJackpotBnb
        );
        console2.log("  pre-commit: all pending slots match the addresses given. proceeding.");

        vm.startBroadcast();
        Bulls(m.bulls).commitWire(Bulls.Wire.Duel);
        Graveyard(m.graveyard).commitWire(Graveyard.Wire.Duel);
        Jackpot(m.jackpotBnbull).commitDuel();
        // The four funders. Without these the new pot has no income.
        MintDrop(m.mintDrop).commitWire(MintDrop.Wire.JackpotBnb);
        PotSplitter(m.mintSplitter).commitWire(PotSplitter.Wire.JackpotBnb);
        PotSplitter(m.reviveSplitter).commitWire(PotSplitter.Wire.JackpotBnb);
        PotSplitter(m.marketSplitter).commitWire(PotSplitter.Wire.JackpotBnb);
        vm.stopBroadcast();

        // ── POST-COMMIT: prove it took. A commit that silently did not land
        //    leaves the game pointed at the old contract while every dashboard
        //    says "migrated". Assert, do not log-and-hope.
        _requireCommitted("Bulls.Duel", Bulls(m.bulls).duelContract(), m.newDuel);
        _requireCommitted("Graveyard.Duel", Graveyard(m.graveyard).duelContract(), m.newDuel);
        _requireCommitted("JackpotBnbull.duel", Jackpot(m.jackpotBnbull).duel(), m.newDuel);
        (address md,,) = MintDrop(m.mintDrop).wireOf(MintDrop.Wire.JackpotBnb);
        _requireCommitted("MintDrop.JackpotBnb", md, m.newJackpotBnb);
        (address ms,,) = PotSplitter(m.mintSplitter).wireOf(PotSplitter.Wire.JackpotBnb);
        _requireCommitted("mintSplitter.JackpotBnb", ms, m.newJackpotBnb);
        (address rs,,) = PotSplitter(m.reviveSplitter).wireOf(PotSplitter.Wire.JackpotBnb);
        _requireCommitted("reviveSplitter.JackpotBnb", rs, m.newJackpotBnb);
        (address ks,,) = PotSplitter(m.marketSplitter).wireOf(PotSplitter.Wire.JackpotBnb);
        _requireCommitted("marketSplitter.JackpotBnb", ks, m.newJackpotBnb);

        console2.log("");
        console2.log("== COMMITTED AND VERIFIED (all seven slots) ==");
        console2.log("  Bulls.Duel                ->", Bulls(m.bulls).duelContract());
        console2.log("  Graveyard.Duel            ->", Graveyard(m.graveyard).duelContract());
        console2.log("  JackpotBnbull.duel        ->", Jackpot(m.jackpotBnbull).duel());
        console2.log("  MintDrop.JackpotBnb       ->", md);
        console2.log("  mintSplitter.JackpotBnb   ->", ms);
        console2.log("  reviveSplitter.JackpotBnb ->", rs);
        console2.log("  marketSplitter.JackpotBnb ->", ks);
        console2.log("");
        console2.log("  THE CHAIN IS CUT OVER. Now flip the frontend and the fleet:");
        console2.log("    NEXT_PUBLIC_DUEL        =", m.newDuel);
        console2.log("    NEXT_PUBLIC_JACKPOT_BNB =", m.newJackpotBnb);
        console2.log("    NEXT_PUBLIC_DUEL_NATIVE = true   <- same deploy, or the UI stays dark");
        console2.log("  Then run the runbook checklist.");
    }

    function _pendingBulls(address a) private view returns (address p) {
        (, p,) = Bulls(a).wireOf(Bulls.Wire.Duel);
    }

    function _pendingGraveyard(address a) private view returns (address p) {
        (, p,) = Graveyard(a).wireOf(Graveyard.Wire.Duel);
    }

    function _pendingJackpotDuel(address a) private view returns (address p) {
        (, p,) = Jackpot(a).duelWire();
    }

    function _pendingMintDropPot(address a) private view returns (address p) {
        (, p,) = MintDrop(a).wireOf(MintDrop.Wire.JackpotBnb);
    }

    function _pendingSplitterPot(address a) private view returns (address p) {
        (, p,) = PotSplitter(a).wireOf(PotSplitter.Wire.JackpotBnb);
    }

    function _requirePending(string memory slot, address pending, address expected) private view {
        if (pending == expected) return;
        console2.log(string.concat("  /!\\ ", slot), "is not pending the address you passed.");
        console2.log("      pending :", pending);
        console2.log("      expected:", expected);
        console2.log("      Committing this would wire the game to an address you did not choose.");
        revert PendingMismatch(slot, expected, pending);
    }

    function _requireCommitted(string memory slot, address got, address expected) private pure {
        if (got != expected) revert CommitDidNotTake(slot, expected, got);
    }
}
