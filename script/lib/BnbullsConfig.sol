// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title BnbullsConfig
 * @notice Every input the deploy needs, read from env, plus the two BLOCKING
 *         rules from `DEPLOY-SAFETY-PREFLIGHT.md §0`.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS FILE EXISTS AT ALL
 *      ══════════════════════════════════════════════════════════════════════
 *      On 2026-07-30 fighting fefers lost **154 USDT of real mint revenue,
 *      permanently unrecoverable**, because a fork-rehearsal keystore address
 *      was written into the mainnet env file's treasury lines, survived into
 *      the real deploy, collected revenue, and then the keystore was deleted.
 *      The only check on those lines was "is this a valid address" — which the
 *      throwaway address passed.
 *
 *      So this file does three things that a normal deploy script does not:
 *
 *        1. **`treasuryGuard`** diffs EVERY payout/treasury address against the
 *           deployer and refuses to continue on any mismatch until a human has
 *           confirmed that exact address, per line. Well-formedness is not a
 *           check (`DEPLOY-SAFETY-PREFLIGHT.md §0 rule 1`).
 *        2. **Nothing is ever written back into an env file.** The deployment
 *           record goes to `deployments/<chainid>.json`, and the anvil record
 *           goes to `.state/anvil/` — segregated by path, so a rehearsal
 *           structurally cannot overwrite mainnet config. That is the fix the
 *           post-mortem asked for.
 *        3. **Missing required values REVERT, loudly, by name.** There is no
 *           silent fallback and no auto-deployed mock: stable warriors baked a
 *           `MockUSDT` into `MintDrop`'s immutable storage forever because its
 *           script had one (`§2`).
 *
 *      The `⚠ VERIFY` gap left in `.env.example` — PancakeSwap v3 QuoterV2 —
 *      stays blank on purpose. A mainnet run reads it from env and fails by
 *      name if unset. It is never defaulted here. (The payment stablecoin and
 *      its decimals used to be the other two gaps; `DECISIONS.md §26` deleted
 *      the asset, so there is nothing left to leave unchosen.)
 */
abstract contract BnbullsConfig is Script {
    // ─── Chains ──────────────────────────────────────────────────────────

    uint256 internal constant CHAIN_BSC = 56;
    uint256 internal constant CHAIN_BSC_TESTNET = 97;
    uint256 internal constant CHAIN_ANVIL = 31337;

    // ─── Types ───────────────────────────────────────────────────────────

    /// @notice The outside world: things we do not deploy on mainnet.
    struct Ext {
        address wbnb;
        address priceFeed;
        /// @dev PancakeSwap v2 router. **`MintDrop` AND both splitters swap
        ///      here** — `DECISIONS.md §28`. four.meme graduates into v2 and
        ///      creates no v3 pool at any tier, so there is one venue.
        address routerV2;
        /// @dev PancakeSwap v3 SmartRouter. ⚠ NOTHING SWAPS HERE ANY MORE. It
        ///      is still read and code-checked so the pre-flight record names
        ///      the address we deliberately did NOT point at, per `§28`.
        address routerV3;
        address vrfCoordinator;
        bytes32 vrfKeyHash;
        uint256 vrfSubId;
        /// @dev The BNBULL token. Zero means "deploy `BNBull.sol` ourselves",
        ///      which is refused on chain 56 unless `DEPLOY_BNBULL=true` —
        ///      `DECISIONS.md §4` puts the launch on four.meme.
        address bnbull;
    }

    /// @notice Every address that can receive money, plus the operational keys.
    ///         EVERY field here is diffed against the deployer by `treasuryGuard`.
    struct Roles {
        address deployer;
        address owner;
        address keeper;
        address trustedSigner;
        address mintTreasury;
        address lpTreasury;
        address feeTreasury;
        address devTreasury;
        address resurrectTreasury;
    }

    /// @notice Launch numbers. Every one is an owner-settable variable on the
    ///         contract (`BNBULLS-BOOTSTRAP.md §0`); these are the launch values.
    struct Params {
        uint256 masterSeed;
        bytes32 namesCommitment;
        /// @dev `DECISIONS.md §21`: the whole protocol fee, 750 bps (7.5%).
        uint16 marketplaceFeeBps;
        /// @dev The slice OF THE SALE that market-buys BNBULL into the pot,
        ///      250 bps. `jackpotFeeBps <= feeBps` is an enforced invariant.
        uint16 marketplaceJackpotFeeBps;
        uint16 duelDefaultDevBps;
        uint256 bnbullSupply;
        // Duel stake assets. `maxFight*` is a PERMANENT per-asset ceiling —
        // `addFightAsset` is one-shot and the ceiling can never be raised.
        uint256 maxFightWbnb;
        uint256 maxFightBnbull;
        // ⚠ `fightWbnb` is a DOLLAR figure (1e18), not a WBNB amount:
        // `DECISIONS.md §26` made the BNB stake oracle-derived, so what is
        // configured is `Duel.setUsdFightPrice`, never a WBNB peg.
        uint256 fightWbnb;
        uint256 fightBnbull;
        // Splitter swap floors. A ZERO here means that leg defers on every
        // payment, silently, forever. See `setFloors` in `PotSplitter`.
        uint256 floorBnbullPerBnb;
        uint256 floorWbnbPerBnbull;
        /// @dev Minimum WBNB-side reserve of the canonical WBNB/BNBULL v2 pair
        ///      before any leg will trade into it. Replaced the v3 fee tier:
        ///      v2 has no fee tiers. Reference points measured on chain —
        ///      graduation opens at 17.64 WBNB, the demonstrated decoy held
        ///      0.01 WBNB. ZERO IS REFUSED by the contracts.
        uint256 minPoolLiquidity;
        uint256 inlineSlippageBps;
        // Keeper pegs, seeded at deploy so the legs are live before the first
        // keeper tick.
        uint256 graveyardBnbullPerUsd;
        uint256 marketplaceBnbullUsd;
        string baseURI;
    }

    struct Cfg {
        Ext ext;
        Roles roles;
        Params params;
    }

    /// @notice Everything the deploy produced. `deployBlock` is the block the
    ///         run STARTED at — never 0, and never later than the first deploy
    ///         tx, so a keeper cursor set to it can only ever be early.
    struct Deployment {
        address bnbull;
        address bulls;
        address mintDrop;
        address duel;
        address graveyard;
        address jackpotBnbull;
        address jackpotBnb;
        address marketplace;
        address mintSplitter;
        address reviveSplitter;
        /// @dev A THIRD `PotSplitter`, wired 100% BNBULL / 0% BNB, that the
        ///      Marketplace hands its `jackpotFeeBps` slice to. Separate from
        ///      `reviveSplitter` because that one splits 2:1 across both pots.
        address marketSplitter;
        uint256 deployBlock;
    }

    // ─── Errors ──────────────────────────────────────────────────────────

    error MissingEnv(string name);
    error ForeignTreasuryUnconfirmed(string name, address value);
    error PlaintextKeyRefusedOnMainnet();
    error KeystoreRequiredOnMainnet();
    error WrongChain(uint256 expected, uint256 actual);
    error NamesTableWrongLength(uint256 got, uint256 want);

    // ─── Env helpers: fail loud, never default a required value ──────────

    function _optAddr(string memory name) internal view returns (address) {
        return vm.envOr(name, address(0));
    }

    function _reqAddr(string memory name) internal view returns (address a) {
        a = vm.envOr(name, address(0));
        if (a == address(0)) {
            console2.log("");
            console2.log("  MISSING REQUIRED ENV VAR (no default, by design):");
            console2.log("   ", name);
            console2.log("  See .env.example. The three '/!\\ VERIFY' gaps stay blank until");
            console2.log("  somebody has checked them against the live chain.");
            revert MissingEnv(name);
        }
    }

    function _reqUint(string memory name) internal view returns (uint256 v) {
        v = vm.envOr(name, uint256(0));
        if (v == 0) {
            console2.log("  MISSING REQUIRED ENV VAR (must be non-zero):", name);
            revert MissingEnv(name);
        }
    }

    /// @dev Required on mainnet, defaulted anywhere else. Used for values that
    ///      are permanent ceilings or that silently disable a money leg when
    ///      wrong, but that nobody should have to type to spin up anvil.
    function _mainnetReqUint(string memory name, uint256 localDefault)
        internal
        view
        returns (uint256)
    {
        if (block.chainid == CHAIN_BSC) return _reqUint(name);
        return vm.envOr(name, localDefault);
    }

    function _mainnetReqAddr(string memory name, address localDefault)
        internal
        view
        returns (address)
    {
        if (block.chainid == CHAIN_BSC) return _reqAddr(name);
        address a = vm.envOr(name, address(0));
        return a == address(0) ? localDefault : a;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /**
     * @notice Read a chain-scoped address: `NAME_TESTNET` on chain 97,
     *         `NAME` everywhere else.
     *
     * @dev ⚠ THE SUFFIX IS THE POINT. The mainnet lines in `.env.example` are
     *      never read on chain 97 and the testnet lines are never read on chain
     *      56 — the two sets cannot be confused by an operator editing the
     *      wrong block, and a testnet rehearsal physically cannot pick up a
     *      mainnet address. Same reasoning as `deployments/<chainid>.json`:
     *      the 154 USDT was lost because a rehearsal and the real thing shared
     *      one file (`DEPLOY-SAFETY-PREFLIGHT.md §1`).
     */
    function _chainAddr(string memory name) internal view returns (address) {
        if (block.chainid == CHAIN_BSC_TESTNET) {
            return vm.envOr(string.concat(name, "_TESTNET"), address(0));
        }
        return vm.envOr(name, address(0));
    }

    function _reqChainAddr(string memory name) internal view returns (address a) {
        a = _chainAddr(name);
        if (a == address(0)) {
            string memory full =
                block.chainid == CHAIN_BSC_TESTNET ? string.concat(name, "_TESTNET") : name;
            console2.log("");
            console2.log("  MISSING REQUIRED ENV VAR (no default, by design):");
            console2.log("   ", full);
            console2.log("  See .env.example. Verify it against the live chain before you");
            console2.log("  fill it in - a wrong-but-plausible address reverts silently.");
            revert MissingEnv(full);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Loading
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Build the config from env. Mainnet requires every '/!\ VERIFY'
     *         value explicitly; nothing falls back to a mock, ever.
     * @param deployer The broadcasting address. Passed in rather than guessed,
     *        because the treasury guard diffs against exactly this.
     */
    function loadConfig(address deployer) internal view returns (Cfg memory c) {
        bool mainnet = block.chainid == CHAIN_BSC;
        bool testnet = block.chainid == CHAIN_BSC_TESTNET;

        c.ext.wbnb = _reqChainAddr("WBNB");
        c.ext.priceFeed = _reqChainAddr("CHAINLINK_BNB_USD");
        c.ext.routerV2 = _reqChainAddr("PANCAKE_V2_ROUTER");
        c.ext.routerV3 = _reqChainAddr("PANCAKE_V3_SMART_ROUTER");
        c.ext.vrfCoordinator = _reqChainAddr("CHAINLINK_VRF_COORDINATOR");
        c.ext.vrfKeyHash = testnet
            ? vm.envOr("VRF_KEY_HASH_TESTNET", bytes32(0))
            : vm.envOr("VRF_KEY_HASH_200GWEI", bytes32(0));
        c.ext.vrfSubId = testnet
            ? vm.envOr("VRF_SUBSCRIPTION_ID_TESTNET", uint256(0))
            : vm.envOr("VRF_SUBSCRIPTION_ID", uint256(0));
        c.ext.bnbull = testnet ? _optAddr("BNBULL_TOKEN_TESTNET") : _optAddr("BNBULL_TOKEN");

        if (mainnet) {
            // A pot with no VRF config accepts tickets forever and can never
            // resolve one — `requestResolve` reverts `VrfNotConfigured`. The
            // fights still work, so nothing looks broken. Require it.
            if (c.ext.vrfKeyHash == bytes32(0)) revert MissingEnv("VRF_KEY_HASH_200GWEI");
            if (c.ext.vrfSubId == 0) revert MissingEnv("VRF_SUBSCRIPTION_ID");
            if (c.ext.bnbull == address(0) && !vm.envOr("DEPLOY_BNBULL", false)) {
                console2.log("  BNBULL_TOKEN is unset on chain 56.");
                console2.log("  DECISIONS.md 4: the token launches on four.meme, so we do NOT");
                console2.log("  deploy it. Set BNBULL_TOKEN, or DEPLOY_BNBULL=true if the call");
                console2.log("  really has changed.");
                revert MissingEnv("BNBULL_TOKEN");
            }
        }

        c.roles.deployer = deployer;
        c.roles.owner = vm.envOr("OWNER", deployer);
        c.roles.keeper = vm.envOr("KEEPER", deployer);
        c.roles.trustedSigner = vm.envOr("TRUSTED_SIGNER", deployer);
        c.roles.mintTreasury = vm.envOr("MINT_TREASURY", deployer);
        c.roles.lpTreasury = vm.envOr("LP_TREASURY", deployer);
        c.roles.feeTreasury = vm.envOr("FEE_TREASURY", deployer);
        c.roles.devTreasury = vm.envOr("DEV_TREASURY", deployer);
        c.roles.resurrectTreasury = vm.envOr("RESURRECT_TREASURY", deployer);

        // `DECISIONS.md §21`: 7.5% total fee, of which 2.5% OF THE SALE buys
        // BNBULL into the pot. Both are bps of the sale so they compare
        // directly, and `jackpotFeeBps <= feeBps` is enforced on chain.
        c.params.marketplaceFeeBps = uint16(vm.envOr("MARKETPLACE_FEE_BPS", uint256(750)));
        c.params.marketplaceJackpotFeeBps =
            uint16(vm.envOr("MARKETPLACE_JACKPOT_FEE_BPS", uint256(250)));
        c.params.duelDefaultDevBps = uint16(vm.envOr("DUEL_DEFAULT_DEV_BPS", uint256(1_000)));
        c.params.bnbullSupply = vm.envOr("BNBULL_SUPPLY", uint256(1_000_000_000e18));

        // `addFightAsset` is ONE-SHOT per asset and `maxCost` can never be
        // raised afterwards. Wrong here means a redeploy, so mainnet must say
        // it out loud.
        c.params.maxFightWbnb = _mainnetReqUint("FIGHT_MAX_COST_WBNB", 1e18);
        c.params.maxFightBnbull = _mainnetReqUint("FIGHT_MAX_COST_BNBULL", 1_000_000e18);
        // ⚠ A DOLLAR figure, 1e18-scaled — `Duel.setUsdFightPrice`, not a WBNB
        // peg. `DECISIONS.md §26` made the BNB stake oracle-derived, so
        // `FIGHT_COST_WBNB` is retired; the env var is `FIGHT_COST_USD`.
        c.params.fightWbnb = vm.envOr("FIGHT_COST_USD", uint256(2e18)); // $2 (DECISIONS 41)
        c.params.fightBnbull = vm.envOr("FIGHT_COST_BNBULL", uint256(250e18));

        // A zero floor DISABLES that swap leg: the pre-check fails and every
        // slice defers into a `pending*` bucket, silently, on every payment.
        // On mainnet that is a launch-day money bug, so require both.
        c.params.floorBnbullPerBnb = _mainnetReqUint("FLOOR_BNBULL_PER_BNB", 40_000e18);
        c.params.floorWbnbPerBnbull = _mainnetReqUint("FLOOR_WBNB_PER_BNBULL", 1e10);
        c.params.minPoolLiquidity = vm.envOr("MIN_POOL_LIQUIDITY_WBNB", uint256(1 ether));
        // DECISIONS.md 40. Owner call: 1500, up from the contract's own 500.
        // 500 CANNOT clear a 10% four.meme template-B transfer tax: the swap
        // succeeds, 10% is skimmed, the measured delta misses minOut by 5%,
        // and every mint's BNBULL buy defers FOREVER, indistinguishable from
        // the ordinary pre-graduation deferral except that it never stops.
        // Measured floor is 1100; 1500 leaves headroom. Ceiling is 2000.
        c.params.inlineSlippageBps = vm.envOr("MINT_INLINE_SLIPPAGE_BPS", uint256(1_500));

        c.params.graveyardBnbullPerUsd = _mainnetReqUint("GRAVEYARD_BNBULL_PER_USD", 100e18);
        c.params.marketplaceBnbullUsd = _mainnetReqUint("MARKETPLACE_BNBULL_USD", 0.01e18);

        c.params.baseURI = vm.envOr("NFT_BASE_URI", string(""));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  BLOCKING RULE 1 — the treasury guard
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Diff every payout/treasury address against the deployer and stop
     *         on any that does not match, per line.
     *
     * @dev This is the check that did not exist on 2026-07-30. Read
     *      `DEPLOY-SAFETY-PREFLIGHT.md §1` before weakening any of it.
     *
     *      Two confirmation modes, chosen with `TREASURY_CONFIRM_MODE`:
     *        - `prompt` (default): forge asks at the terminal, per line, and
     *          the operator must type the address back. Typing "yes" is not
     *          enough — the whole failure was an address nobody looked at.
     *        - `env`: `CONFIRM_<NAME>` must be set to the SAME address. For CI
     *          and for the fork rehearsal, where there is no terminal.
     *
     *      Local chains skip it: on anvil every role defaults to the deployer
     *      anyway, so there is nothing to diff, and an interactive prompt in a
     *      one-command local script would defeat the point of the command.
     */
    function treasuryGuard(Cfg memory c) internal {
        if (block.chainid == CHAIN_ANVIL) return;

        console2.log("");
        console2.log("== TREASURY GUARD (DEPLOY-SAFETY-PREFLIGHT rule 1) ==");
        console2.log("  deployer:", c.roles.deployer);

        _guardOne("OWNER", c.roles.owner, c.roles.deployer);
        _guardOne("MINT_TREASURY", c.roles.mintTreasury, c.roles.deployer);
        _guardOne("LP_TREASURY", c.roles.lpTreasury, c.roles.deployer);
        _guardOne("FEE_TREASURY", c.roles.feeTreasury, c.roles.deployer);
        _guardOne("DEV_TREASURY", c.roles.devTreasury, c.roles.deployer);
        _guardOne("RESURRECT_TREASURY", c.roles.resurrectTreasury, c.roles.deployer);
        _guardOne("KEEPER", c.roles.keeper, c.roles.deployer);
        _guardOne("TRUSTED_SIGNER", c.roles.trustedSigner, c.roles.deployer);

        console2.log("== treasury guard passed ==");
        console2.log("");
    }

    function _guardOne(string memory name, address value, address deployer) private {
        if (value == deployer) {
            console2.log("  [same as deployer]", name);
            return;
        }

        string memory mode = vm.envOr("TREASURY_CONFIRM_MODE", string("prompt"));

        console2.log("");
        console2.log("  /!\\ FOREIGN ADDRESS ON A PAYOUT LINE");
        console2.log("      line:  ", name);
        console2.log("      value: ", value);
        console2.log("      This is NOT the deployer. On fighting fefers exactly this");
        console2.log("      shape - a well-formed address nobody re-checked - collected");
        console2.log("      154 USDT into a deleted throwaway keystore. Unrecoverable.");

        if (_eq(mode, "env")) {
            string memory key = string.concat("CONFIRM_", name);
            address confirmed = vm.envOr(key, address(0));
            if (confirmed != value) {
                console2.log("      Set", key, "to this exact address to confirm.");
                revert ForeignTreasuryUnconfirmed(name, value);
            }
            console2.log("      confirmed via", key);
            return;
        }

        string memory answer = vm.prompt(
            string.concat("Type the FULL address to confirm ", name, " is intentional")
        );
        if (!_eq(_lower(answer), _lower(vm.toString(value)))) {
            console2.log("      Mismatch. Refusing to deploy.");
            revert ForeignTreasuryUnconfirmed(name, value);
        }
        console2.log("      confirmed at the prompt");
    }

    function _lower(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Key discipline — mainnet refuses a plaintext private key
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev `DEPLOY-SAFETY-PREFLIGHT.md §2`: mainnet decrypts a keystore with a
     *      password file. It does not accept a raw key env var. And §0 rule 2:
     *      snapshot `~/.foundry/keystores` before ANY run that creates or
     *      deletes a wallet — a fork rehearsal does both. That copy is the
     *      owner's to make; this only refuses to run until it is claimed.
     */
    function keyGuard() internal view {
        if (block.chainid != CHAIN_BSC) return;

        if (!_eq(vm.envOr("PRIVATE_KEY", string("")), "")) {
            console2.log("  PRIVATE_KEY is set in the environment on chain 56.");
            console2.log("  Mainnet deploys use --account <keystore> --password-file <path>.");
            revert PlaintextKeyRefusedOnMainnet();
        }
        if (!vm.envOr("USE_KEYSTORE", false)) {
            console2.log("  USE_KEYSTORE is not true on chain 56.");
            revert KeystoreRequiredOnMainnet();
        }
        if (!vm.envOr("KEYSTORE_SNAPSHOT_TAKEN", false)) {
            console2.log("  KEYSTORE_SNAPSHOT_TAKEN is not true.");
            console2.log("  DEPLOY-SAFETY-PREFLIGHT rule 2: copy ~/.foundry/keystores");
            console2.log("  somewhere safe and OFF this box before any wallet-touching run,");
            console2.log("  then set KEYSTORE_SNAPSHOT_TAKEN=true.");
            revert KeystoreRequiredOnMainnet();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PREFLIGHT — runs before the FIRST broadcast, refuses on any doubt
    // ══════════════════════════════════════════════════════════════════════

    error ChainMismatch(uint256 expected, uint256 actual);
    error MainnetNotConfirmed();
    error NoCodeAt(string what, address addr);
    error InsufficientBalance(uint256 have, uint256 need);
    error OracleUnusable(address feed);

    /**
     * @notice Resolved chain, deployer + balance, gas price, an estimate, and a
     *         live code check on every external address.
     *
     * @dev ⚠ THE CHAIN ASSERTION IS THE POINT. `--rpc-url` is a string; nothing
     *      else in the toolchain checks that the chain behind it is the chain
     *      you meant. Set `EXPECT_CHAIN_ID` and a testnet rehearsal pointed at
     *      a mainnet RPC dies here instead of writing a mainnet record — the
     *      exact class of accident that cost fighting fefers 154 USDT.
     *
     *      And every external address is checked for CODE, not for
     *      well-formedness. A wrong-but-plausible address is a contract call
     *      into empty space: `_potLegReady` shows why that is invisible — a
     *      call to an address with no code SUCCEEDS with empty returndata.
     */
    function preflight(Cfg memory c) internal view {
        uint256 expect = vm.envOr("EXPECT_CHAIN_ID", uint256(0));
        console2.log("");
        console2.log("======================= PREFLIGHT =======================");
        console2.log("  chain id        ", block.chainid);
        if (expect != 0 && expect != block.chainid) {
            console2.log("  /!\\ EXPECT_CHAIN_ID is", expect);
            console2.log("      The RPC behind --rpc-url is a DIFFERENT chain.");
            console2.log("      Refusing to broadcast.");
            revert ChainMismatch(expect, block.chainid);
        }
        if (block.chainid == CHAIN_BSC && !vm.envOr("CONFIRM_MAINNET", false)) {
            console2.log("  /!\\ THIS IS BNB CHAIN MAINNET (56).");
            console2.log("      Set CONFIRM_MAINNET=true only when that is what you mean.");
            revert MainnetNotConfirmed();
        }

        uint256 bal = c.roles.deployer.balance;
        uint256 gp = tx.gasprice;
        console2.log("  deployer        ", c.roles.deployer);
        console2.log("  balance (wei)   ", bal);
        console2.log("  gas price (wei) ", gp);

        // ~46M gas covers the ten deployments, ~70 wiring calls and the eleven
        // `setNames` batches with room to spare. Deliberately generous: the
        // point is to catch an empty wallet, not to shave a deploy.
        uint256 estGas = 46_000_000;
        uint256 estCost = estGas * gp;
        console2.log("  est. gas        ", estGas);
        console2.log("  est. cost (wei) ", estCost);
        if (gp > 0 && bal < estCost) {
            console2.log("  /!\\ deployer balance is below the estimate.");
            revert InsufficientBalance(bal, estCost);
        }

        console2.log("");
        console2.log("  external contracts (code length, live):");
        _requireCode("WBNB", c.ext.wbnb);
        _requireCode("CHAINLINK_BNB_USD", c.ext.priceFeed);
        _requireCode("PANCAKE_V2_ROUTER", c.ext.routerV2);
        _requireCode("PANCAKE_V3_SMART_ROUTER", c.ext.routerV3);
        _requireCode("CHAINLINK_VRF_COORDINATOR", c.ext.vrfCoordinator);
        if (c.ext.bnbull != address(0)) _requireCode("BNBULL_TOKEN", c.ext.bnbull);
        else console2.log("    BNBULL_TOKEN              unset - BNBull.sol will be deployed");

        _checkFeed(c.ext.priceFeed);

        console2.log("");
        console2.log("  VRF keyHash set  ", c.ext.vrfKeyHash != bytes32(0));
        console2.log("  VRF subId        ", c.ext.vrfSubId);
        if (c.ext.vrfSubId == 0) {
            console2.log("  /!\\ NO VRF SUBSCRIPTION. Tickets will open and NEVER resolve.");
            console2.log("      Create + fund one at vrf.chain.link, then add BOTH Jackpot");
            console2.log("      addresses as consumers. This cannot be scripted away.");
        }
        console2.log("=========================================================");
    }

    function _requireCode(string memory what, address a) private view {
        uint256 len = a.code.length;
        console2.log("   ", what, a, len);
        if (len == 0) {
            console2.log("  /!\\ NO CODE AT THAT ADDRESS. Refusing to broadcast.");
            revert NoCodeAt(what, a);
        }
    }

    /// @dev A price feed that answers is not the same as a feed that answers
    ///      SANELY. `DECISIONS.md §1` prices everything through this thing, so
    ///      a stale or non-positive answer is a total sale outage on day one.
    function _checkFeed(address feed) private view {
        (bool ok, bytes memory ret) =
            feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!ok || ret.length < 160) {
            console2.log("  /!\\ CHAINLINK_BNB_USD does not answer latestRoundData().");
            revert OracleUnusable(feed);
        }
        (, int256 answer,, uint256 updatedAt,) =
            abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        console2.log("  BNB/USD raw answer", uint256(answer < 0 ? int256(0) : answer));
        console2.log("  BNB/USD updatedAt ", updatedAt);
        if (answer <= 0 || updatedAt == 0) {
            console2.log("  /!\\ non-positive answer or missing timestamp.");
            revert OracleUnusable(feed);
        }
        if (block.timestamp > updatedAt + 6 hours) {
            console2.log("  /!\\ the feed is more than 6 hours stale. Every mint would revert.");
            revert OracleUnusable(feed);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The deployment record — NEVER an env file
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Where a deployment record for this chain lives.
     * @dev Mainnet/testnet records go to `deployments/<chainid>.json` and are
     *      meant to be committed. The anvil record goes to `.state/anvil/`,
     *      which `.gitignore` already blocks. **They are different paths on
     *      purpose**: the $154 loss happened because a rehearsal wrote into the
     *      mainnet config file. Two files cannot overwrite each other.
     */
    function deploymentPath() internal view returns (string memory) {
        if (block.chainid == CHAIN_ANVIL) return ".state/anvil/deployment.json";
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function writeDeployment(Cfg memory c, Deployment memory d) internal {
        string memory ext = "ext";
        vm.serializeAddress(ext, "wbnb", c.ext.wbnb);
        vm.serializeAddress(ext, "priceFeed", c.ext.priceFeed);
        vm.serializeAddress(ext, "routerV2", c.ext.routerV2);
        vm.serializeAddress(ext, "routerV3", c.ext.routerV3);
        string memory extJson = vm.serializeAddress(ext, "vrfCoordinator", c.ext.vrfCoordinator);

        string memory con = "contracts";
        vm.serializeAddress(con, "bnbull", d.bnbull);
        vm.serializeAddress(con, "bulls", d.bulls);
        vm.serializeAddress(con, "mintDrop", d.mintDrop);
        vm.serializeAddress(con, "duel", d.duel);
        vm.serializeAddress(con, "graveyard", d.graveyard);
        vm.serializeAddress(con, "jackpotBnbull", d.jackpotBnbull);
        vm.serializeAddress(con, "jackpotBnb", d.jackpotBnb);
        vm.serializeAddress(con, "marketplace", d.marketplace);
        vm.serializeAddress(con, "mintSplitter", d.mintSplitter);
        vm.serializeAddress(con, "reviveSplitter", d.reviveSplitter);
        string memory conJson = vm.serializeAddress(con, "marketSplitter", d.marketSplitter);

        // The roles go in the record too, so `Verify` is self-contained: it can
        // answer "is this wired the way it was MEANT to be" from the record
        // alone, without an env file that may have been edited since.
        string memory rol = "roles";
        vm.serializeAddress(rol, "owner", c.roles.owner);
        vm.serializeAddress(rol, "keeper", c.roles.keeper);
        vm.serializeAddress(rol, "trustedSigner", c.roles.trustedSigner);
        vm.serializeAddress(rol, "mintTreasury", c.roles.mintTreasury);
        vm.serializeAddress(rol, "lpTreasury", c.roles.lpTreasury);
        vm.serializeAddress(rol, "feeTreasury", c.roles.feeTreasury);
        vm.serializeAddress(rol, "devTreasury", c.roles.devTreasury);
        string memory rolJson =
            vm.serializeAddress(rol, "resurrectTreasury", c.roles.resurrectTreasury);

        string memory root = "root";
        vm.serializeString(root, "roles", rolJson);
        vm.serializeUint(root, "chainId", block.chainid);
        // NEVER 0. Every keeper/indexer cursor starts here, and a 0 means a
        // full-chain rescan on every restart (`DEPLOY-SAFETY-PREFLIGHT §4`).
        vm.serializeUint(root, "deployBlock", d.deployBlock);
        vm.serializeAddress(root, "deployer", c.roles.deployer);
        vm.serializeAddress(root, "owner", c.roles.owner);
        vm.serializeAddress(root, "keeper", c.roles.keeper);
        vm.serializeString(root, "ext", extJson);
        string memory out = vm.serializeString(root, "contracts", conJson);

        vm.writeJson(out, deploymentPath());
        console2.log("  deployment record ->", deploymentPath());
    }

    function readDeployment() internal view returns (Deployment memory d) {
        string memory json = vm.readFile(deploymentPath());
        d.bnbull = vm.parseJsonAddress(json, ".contracts.bnbull");
        d.bulls = vm.parseJsonAddress(json, ".contracts.bulls");
        d.mintDrop = vm.parseJsonAddress(json, ".contracts.mintDrop");
        d.duel = vm.parseJsonAddress(json, ".contracts.duel");
        d.graveyard = vm.parseJsonAddress(json, ".contracts.graveyard");
        d.jackpotBnbull = vm.parseJsonAddress(json, ".contracts.jackpotBnbull");
        d.jackpotBnb = vm.parseJsonAddress(json, ".contracts.jackpotBnb");
        d.marketplace = vm.parseJsonAddress(json, ".contracts.marketplace");
        d.mintSplitter = vm.parseJsonAddress(json, ".contracts.mintSplitter");
        d.reviveSplitter = vm.parseJsonAddress(json, ".contracts.reviveSplitter");
        d.marketSplitter = vm.parseJsonAddress(json, ".contracts.marketSplitter");
        d.deployBlock = vm.parseJsonUint(json, ".deployBlock");
    }

    /**
     * @notice The record from a previous run, or an all-zero struct.
     * @dev THE RESUME PRIMITIVE. A run that dies half way through leaves real
     *      contracts on chain and a record that may or may not describe them,
     *      so `DeployCore` re-uses a recorded address only when that address
     *      HAS CODE right now — never on the record's say-so. A record written
     *      during simulation that the broadcast never delivered therefore
     *      resolves to "redeploy", which is the safe answer.
     */
    function readDeploymentOrEmpty() internal view returns (Deployment memory d) {
        // ⚠ NOT try/catch on `this.…()`: forge bans `address(this)` in a script
        // (script contracts are ephemeral and their address means nothing), so
        // the file has to be probed rather than the call.
        string memory path = deploymentPath();
        if (!vm.isFile(path)) return d;
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, ".contracts.bulls")) return d;
        return readDeployment();
    }

    /**
     * @notice Rebuild the config from the DEPLOYMENT RECORD, cross-checking
     *         every external address against env where env has an opinion.
     *
     * @dev `Verify` uses this rather than `loadConfig`, for two reasons.
     *
     *      1. **It has to work on a chain whose "external world" was deployed
     *         by the run itself.** On anvil the WBNB, the feed and the router
     *         are mocks with addresses that exist nowhere but the record, so an
     *         env-only load simply cannot verify a local deployment.
     *
     *      2. **The record is the better source of truth.** It says what was
     *         ACTUALLY wired. An env file can be edited between the deploy and
     *         the verify — which is exactly the accident class that lost 154
     *         USDT — so re-reading env and calling agreement "verified" would
     *         be checking the wrong document against itself.
     *
     *      Where env DOES carry a value, a disagreement is a hard failure and
     *      not a shrug: it means the deployment on chain and the file the team
     *      is reading describe two different systems.
     */
    function loadVerifyConfig(Deployment memory d) internal view returns (Cfg memory c) {
        string memory json = vm.readFile(deploymentPath());

        c.ext.wbnb = vm.parseJsonAddress(json, ".ext.wbnb");
        c.ext.priceFeed = vm.parseJsonAddress(json, ".ext.priceFeed");
        c.ext.routerV2 = vm.parseJsonAddress(json, ".ext.routerV2");
        c.ext.routerV3 = vm.parseJsonAddress(json, ".ext.routerV3");
        c.ext.vrfCoordinator = vm.parseJsonAddress(json, ".ext.vrfCoordinator");
        c.ext.bnbull = d.bnbull;

        _crossCheckEnv("WBNB", c.ext.wbnb);
        _crossCheckEnv("CHAINLINK_BNB_USD", c.ext.priceFeed);
        _crossCheckEnv("PANCAKE_V2_ROUTER", c.ext.routerV2);
        _crossCheckEnv("PANCAKE_V3_SMART_ROUTER", c.ext.routerV3);
        _crossCheckEnv("CHAINLINK_VRF_COORDINATOR", c.ext.vrfCoordinator);

        c.roles.deployer = vm.parseJsonAddress(json, ".deployer");
        c.roles.owner = vm.parseJsonAddress(json, ".owner");
        c.roles.keeper = vm.parseJsonAddress(json, ".keeper");
        c.roles.trustedSigner = vm.parseJsonAddress(json, ".roles.trustedSigner");
        c.roles.mintTreasury = vm.parseJsonAddress(json, ".roles.mintTreasury");
        c.roles.lpTreasury = vm.parseJsonAddress(json, ".roles.lpTreasury");
        c.roles.feeTreasury = vm.parseJsonAddress(json, ".roles.feeTreasury");
        c.roles.devTreasury = vm.parseJsonAddress(json, ".roles.devTreasury");
        c.roles.resurrectTreasury = vm.parseJsonAddress(json, ".roles.resurrectTreasury");

        c.params.masterSeed = readMasterSeed();
        c.params.namesCommitment = namesCommitment(readNames());
        c.params.marketplaceFeeBps = uint16(vm.envOr("MARKETPLACE_FEE_BPS", uint256(750)));
        c.params.marketplaceJackpotFeeBps =
            uint16(vm.envOr("MARKETPLACE_JACKPOT_FEE_BPS", uint256(250)));
        // ⚠ MUST USE THE SAME EXPRESSION AS `loadConfig`, INCLUDING THE DEFAULT.
        // It is not in the deployment record, so leaving it unset here left it
        // at 0 and `Verify` compared the live 1 BNB floor against 0 — FOUR
        // false failures (MintDrop + all three splitters) on every chain,
        // including mainnet. The combined deploy-then-verify path never showed
        // it because that one builds its Cfg with `loadConfig`; the standalone
        // `Verify` the runbook actually tells you to run is the broken one.
        //
        // A verifier that always fails is worse than no verifier: it teaches
        // the operator that Verify failures are noise, which is exactly how a
        // REAL one — an unconfigured VRF, a missing funder role — gets waved
        // through on deploy day.
        c.params.minPoolLiquidity = vm.envOr("MIN_POOL_LIQUIDITY_WBNB", uint256(1 ether));
        // DECISIONS.md 40. Owner call: 1500, up from the contract's own 500.
        // 500 CANNOT clear a 10% four.meme template-B transfer tax: the swap
        // succeeds, 10% is skimmed, the measured delta misses minOut by 5%,
        // and every mint's BNBULL buy defers FOREVER, indistinguishable from
        // the ordinary pre-graduation deferral except that it never stops.
        // Measured floor is 1100; 1500 leaves headroom. Ceiling is 2000.
        c.params.inlineSlippageBps = vm.envOr("MINT_INLINE_SLIPPAGE_BPS", uint256(1_500));
    }

    error RecordDisagreesWithEnv(string name, address record, address env);

    function _crossCheckEnv(string memory name, address recorded) private view {
        address fromEnv = _chainAddr(name);
        if (fromEnv == address(0) || fromEnv == recorded) return;
        console2.log("");
        console2.log("  /!\\ THE DEPLOYMENT AND THE ENV FILE DISAGREE:", name);
        console2.log("      wired on chain:", recorded);
        console2.log("      .env says:     ", fromEnv);
        console2.log("      One of them is wrong and the team is reading the other one.");
        revert RecordDisagreesWithEnv(name, recorded, fromEnv);
    }

    /// @notice A single value out of the record, or zero when there is no
    ///         record yet. Used by the testnet rehearsal to resume a mock it
    ///         already deployed rather than deploy a second one.
    function recordedAddress(string memory key) internal view returns (address) {
        string memory path = deploymentPath();
        if (!vm.isFile(path)) return address(0);
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, key)) return address(0);
        return vm.parseJsonAddress(json, key);
    }

    /// @dev Reuse `recorded` if something is actually deployed there.
    function _resume(address recorded, string memory label) internal view returns (address) {
        if (recorded != address(0) && recorded.code.length > 0) {
            console2.log("  [resume]", label, recorded);
            return recorded;
        }
        return address(0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The dealt name table (DECISIONS §9)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Read the 501 dealt names produced by `scripts/gen-names.mjs`.
     * @dev The table is generated from the generator's `assignNames()` against
     *      the rarity map re-derived from the SAME on-chain shuffle the Bulls
     *      constructor runs, so the peerage rank in a name always matches the
     *      tier the chain assigned. See the header of `gen-names.mjs`.
     */
    function readNames() internal view returns (string[] memory names) {
        string memory path = vm.envOr("NAMES_JSON", string("deployments/names.json"));
        string memory json = vm.readFile(path);
        names = vm.parseJsonStringArray(json, ".names");
        if (names.length != 501) revert NamesTableWrongLength(names.length, 501);
    }

    /// @notice The commitment the `Bulls` constructor is given.
    /// @dev ONE definition, in Solidity, so the chain and the generator can
    ///      never drift: `keccak256(abi.encode(string[501]))` in token-id
    ///      order 1..501. `abi.encode` of a string array is length-prefixed and
    ///      offset-encoded, so two different tables cannot collide the way a
    ///      naive concatenation of names could.
    function namesCommitment(string[] memory names) internal pure returns (bytes32) {
        return keccak256(abi.encode(names));
    }

    function readMasterSeed() internal view returns (uint256) {
        string memory path = vm.envOr("NAMES_JSON", string("deployments/names.json"));
        string memory json = vm.readFile(path);
        return vm.parseJsonUint(json, ".masterSeed");
    }

    // ─── Logging ─────────────────────────────────────────────────────────

    function logDeployment(Deployment memory d) internal pure {
        console2.log("  BNBULL token      ", d.bnbull);
        console2.log("  Bulls (ERC-721)   ", d.bulls);
        console2.log("  MintDrop          ", d.mintDrop);
        console2.log("  Duel              ", d.duel);
        console2.log("  Graveyard         ", d.graveyard);
        console2.log("  Jackpot BNBULL    ", d.jackpotBnbull);
        console2.log("  Jackpot BNB       ", d.jackpotBnb);
        console2.log("  Marketplace       ", d.marketplace);
        console2.log("  MintBnbullSplitter", d.mintSplitter);
        console2.log("  ReviveBuySplitter ", d.reviveSplitter);
        console2.log("  MarketPotSplitter ", d.marketSplitter);
        console2.log("  deploy block      ", d.deployBlock);
    }
}
