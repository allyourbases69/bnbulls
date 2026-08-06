// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ForkAddresses
 * @notice Every BSC mainnet address the fork package touches, in ONE place,
 *         each with the read that verified it.
 *
 * @dev ⚠ NOTHING HERE IS A GUESS. `BNB-CHAIN-FACTS.md` tags addresses
 *      `✔ found` / `⚠ VERIFY`; `FOUR-MEME-LAUNCH-ROUTE.md` re-read every
 *      four.meme address off chain. This file carries only addresses that a
 *      test in this directory actually calls and asserts against, so a wrong
 *      one fails loudly rather than sitting in a doc.
 *
 *      ⚠ THE PIN. `FORK_BLOCK` is fixed on purpose. A floating fork makes
 *      every failure unrepeatable and re-downloads state on every run — the
 *      opposite of what a regression suite is for. If you move the pin you
 *      must re-verify the curve-phase specimens below, because a four.meme
 *      token that has graduated since is no longer a pre-graduation specimen
 *      and half this package changes meaning silently.
 */
library ForkAddresses {
    // ─── The pin ──────────────────────────────────────────────────────────

    /// @notice BSC mainnet block every test in this directory forks at.
    ///         Verified at pin time (`cast --block 114260000`):
    ///           - Chainlink BNB/USD answered 59_550_874_000 (8dp = $595.50874)
    ///             with `updatedAt` 25 seconds behind the block timestamp;
    ///           - Gort read `_mode() == 1` (transfer-restricted) and
    ///             `_tokenInfos(...).status == 0` (STATUS_TRADING);
    ///           - the BabyDoge/WBNB v2 pair held 6,102.23 WBNB.
    uint256 internal constant FORK_BLOCK = 114_260_000;

    /// @notice `block.timestamp` at `FORK_BLOCK`. Asserted in ForkBase so a
    ///         silently-moved pin is caught in `setUp` rather than three
    ///         assertions later.
    uint256 internal constant FORK_TIMESTAMP = 1_785_977_321;

    uint256 internal constant BSC_CHAIN_ID = 56;

    // ─── Core BSC ─────────────────────────────────────────────────────────

    /// @dev `BNB-CHAIN-FACTS §3`. Also the compile-time `WETH()` constant
    ///      inside every four.meme token (`FOUR-MEME-LAUNCH-ROUTE §1`).
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ─── PancakeSwap v2 — where four.meme liquidity actually lands ────────

    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    // ─── PancakeSwap v3 — where the splitters currently point, and where ──
    //     four.meme creates NOTHING (`DECISIONS.md §28.3`)

    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant PANCAKE_V3_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant PANCAKE_V3_QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address internal constant PANCAKE_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    /// @dev The four live tiers on BSC. There is **no 3000 tier** — verified
    ///      by `feeAmountTickSpacing()` returning 1/10/50/200
    ///      (`FOUR-MEME-LAUNCH-ROUTE §1`). Our `wbnbBnbullPoolFee = 10_000`
    ///      default is a valid tier that can only ever contain a decoy.
    uint24 internal constant V3_FEE_100 = 100;
    uint24 internal constant V3_FEE_500 = 500;
    uint24 internal constant V3_FEE_2500 = 2500;
    uint24 internal constant V3_FEE_10000 = 10_000;

    // ─── Chainlink ────────────────────────────────────────────────────────

    /// @dev `DECISIONS.md §1` option A. 8 decimals.
    address internal constant CHAINLINK_BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    /// @dev VRF v2.5 coordinator. `s_config()` at the pin reads
    ///      `minimumRequestConfirmations = 3`, `maxGasLimit = 2_500_000`.
    address internal constant VRF_COORDINATOR_V2_5 = 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9;

    address internal constant LINK = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75;

    /// @dev 200 gwei lane.
    bytes32 internal constant VRF_KEY_HASH_200_GWEI =
        0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;

    // ─── four.meme ────────────────────────────────────────────────────────

    /// @dev TokenManager2, the pad. ERC-1967 UUPS proxy behind a 3-of-6 Safe.
    address internal constant FOUR_MEME_TOKEN_MANAGER = 0x5c952063c7fc8610FFDB798152D69F0B9550762b;

    /// @dev The pad's owner. Gnosis Safe v1.3.0, 3-of-6.
    address internal constant FOUR_MEME_SAFE = 0x161dd0CfDb0aa25E2504F725655ef9b799375b71;

    /**
     * @notice Gort — the primary pre-graduation specimen, template B
     *         (13,584-byte runtime, address ends `ffff`).
     *
     * @dev VERIFIED AT THE PIN: `_mode() == 1`, `owner() == TokenManager2`,
     *      `feeRateBuy() == 10`, `v2Factory.getPair(Gort, WBNB) == 0`,
     *      `_tokenInfos(Gort)` → `quote == address(0)` (native BNB, template
     *      0 — the ONE of twenty that graduates into a BNB pool,
     *      `DECISIONS.md §30`), `maxRaising == 18e18`, `status == 0`.
     *
     *      This is the closest live analogue to what BNBULL will be, which is
     *      why the package graduates THIS rather than assuming a graduated
     *      BNBULL that `DECISIONS.md §29` says does not exist.
     */
    address internal constant GORT = 0xe7069592CfbC6F0c95F36e81865107ce2ddbFffF;

    /// @dev Second fresh template-B specimen, also pre-graduation at the pin.
    ///      Used to prove the transfer gate is a property of the template and
    ///      not of one token.
    address internal constant BEAU = 0x950399da67A51D7257476952c6cA6d6EFF49fFfF;

    /// @dev A holder of Gort on mainnet at the pin. `transfer()` from this
    ///      address is the live proof of the gate.
    address internal constant GORT_HOLDER = 0x4Ce7F73BeCDcc97e3CFe97DE22dDeb5bDA05fcB8;

    /// @dev Already graduated on mainnet, template A. The end state we are
    ///      trying to reach, readable without graduating anything.
    address internal constant FOUR_MEME_PRO = 0xB37009178516ebf57741abD09E5bC4A027574444;
    address internal constant FOUR_MEME_PRO_PAIR = 0xAB55A8545AC08CFf697DF5C99fCa6DE49bb776A5;

    /// @dev Graduated four.meme token that ALREADY carries three third-party
    ///      v3 pools on mainnet — the decoy trap, live, today.
    address internal constant BROCCOLI = 0x6d5AD1592ed9D6D1dF9b93c793AB759573Ed6714;

    // ─── A real transfer-taxing ERC-20 we did not write ───────────────────

    /**
     * @notice Baby Doge Coin. **9 decimals**, reflection + liquidity fee on
     *         every pair-touching transfer, and a deep real v2 book
     *         (6,102 WBNB at the pin).
     *
     * @dev Chosen over a mock for three reasons a mock cannot supply: the tax
     *      is real, the decimals are NOT 18 (so a hidden `1e18` divisor shows
     *      up as a 10^9 error rather than a rounding one), and nobody on this
     *      project wrote it, so it cannot have been unconsciously shaped to
     *      pass our tests.
     */
    address internal constant BABYDOGE = 0xc748673057861a797275CD8A068AbB95A902e8de;
    address internal constant BABYDOGE_WBNB_PAIR = 0xc736cA3d9b1E90Af4230BD8F9626528B3D4e0Ee0;

    // ─── Misc ─────────────────────────────────────────────────────────────

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
}
