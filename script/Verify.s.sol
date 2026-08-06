// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from
    "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {BnbullsConfig} from "./lib/BnbullsConfig.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Duel} from "../contracts/Duel.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {Marketplace} from "../contracts/Marketplace.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";

/**
 * @title VerifyCore
 * @notice Assert every wiring leg after `Wire.s.sol`, and FAIL LOUDLY on any
 *         gap. **A wiring checklist that is only a comment will be missed.**
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS FILE IS THE POINT OF PACKAGE F
 *      ══════════════════════════════════════════════════════════════════════
 *      Almost nothing in the wiring fails loudly. The whole money layer is
 *      built on the never-fail pattern — `try this.…Inline() catch { accrue }`
 *      — which means a missing funder role, an unwired pot, a stale floor and
 *      an outright bug all produce the SAME observable behaviour as a healthy
 *      contract having a quiet day: the player's transaction succeeds, and an
 *      event nobody is watching says the slice deferred.
 *
 *      That is the correct behaviour in production and the wrong behaviour on
 *      deploy day. So every leg gets asserted here, once, while somebody is
 *      still looking.
 *
 *      Failures are collected and printed together rather than reverting on
 *      the first one: three missing funder roles should be three lines on one
 *      screen, not three separate runs.
 */
abstract contract VerifyCore is BnbullsConfig {
    uint256 internal failures;
    uint256 internal warnings;
    uint256 internal checks;

    error VerificationFailed(uint256 count);

    function _ok(bool cond, string memory what) internal {
        checks++;
        if (cond) return;
        failures++;
        console2.log("  [FAIL]", what);
    }

    function _okAddr(address got, address want, string memory what) internal {
        checks++;
        if (got == want) return;
        failures++;
        console2.log("  [FAIL]", what);
        console2.log("         want", want);
        console2.log("         got ", got);
    }

    function _okUint(uint256 got, uint256 want, string memory what) internal {
        checks++;
        if (got == want) return;
        failures++;
        console2.log("  [FAIL]", what);
        console2.log("         want", want);
        console2.log("         got ", got);
    }

    function _okBytes32(bytes32 got, bytes32 want, string memory what) internal {
        checks++;
        if (got == want) return;
        failures++;
        console2.log("  [FAIL]", what);
        console2.log("         want");
        console2.logBytes32(want);
        console2.log("         got ");
        console2.logBytes32(got);
    }

    function _warn(bool cond, string memory what) internal {
        checks++;
        if (cond) return;
        warnings++;
        console2.log("  [warn]", what);
    }

    /// @dev A mis-wired slot pointing at an EOA is INVISIBLE: a call to an EOA
    ///      succeeds with empty returndata, and neither `fund` nor
    ///      `donatePotToken` returns anything for the decode to choke on. Duel
    ///      guards with `target.code.length > 0` for exactly this reason; every
    ///      wired game address gets the same check here.
    function _hasCode(address a, string memory what) internal {
        checks++;
        if (a != address(0) && a.code.length > 0) return;
        failures++;
        console2.log("  [FAIL] no code at wired slot:", what);
        console2.log("         addr", a);
    }

    // ══════════════════════════════════════════════════════════════════════

    function verifyAll(Cfg memory c, Deployment memory d) internal {
        console2.log("== bnbulls verify ==");
        console2.log("  chain", block.chainid);

        _verifyBulls(c, d);
        _verifyMintDrop(c, d);
        _verifyDuel(c, d);
        _verifyGraveyard(c, d);
        _verifyPot(c, d, Jackpot(d.jackpotBnbull), d.bnbull, 50, "BNBULL pot");
        _verifyPot(c, d, Jackpot(d.jackpotBnb), c.ext.wbnb, 100, "BNB pot");
        _verifyMarketplace(c, d);
        _verifySplitter(c, d, PotSplitter(d.mintSplitter), "MintBnbullSplitter", true);
        _verifySplitter(c, d, PotSplitter(d.reviveSplitter), "ReviveBuySplitter", true);
        _verifySplitter(c, d, PotSplitter(d.marketSplitter), "MarketPotSplitter", false);
        _verifyCrossCutting(c, d);

        console2.log("");
        console2.log("== verify summary ==");
        console2.log("  checks  ", checks);
        console2.log("  warnings", warnings);
        console2.log("  FAILURES", failures);
        if (failures > 0) {
            console2.log("");
            console2.log("  /!\\ DO NOT PROCEED. Every line above is a leg that fails SILENTLY");
            console2.log("      in production: the game works, the money goes elsewhere.");
            revert VerificationFailed(failures);
        }
        console2.log("  all green.");
    }

    // ─── Bulls ──────────────────────────────────────────────────────────

    function _verifyBulls(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Bulls --");
        Bulls b = Bulls(d.bulls);

        _okAddr(b.duelContract(), d.duel, "Bulls.duelContract");
        _okAddr(b.graveyardContract(), d.graveyard, "Bulls.graveyardContract");
        _okAddr(b.mintDropContract(), d.mintDrop, "Bulls.mintDropContract");
        _hasCode(b.duelContract(), "Bulls.Duel");
        _hasCode(b.graveyardContract(), "Bulls.Graveyard");
        _hasCode(b.mintDropContract(), "Bulls.MintDrop");
        _noPending(b, Bulls.Wire.Duel, "Bulls.Duel");
        _noPending(b, Bulls.Wire.Graveyard, "Bulls.Graveyard");
        _noPending(b, Bulls.Wire.MintDrop, "Bulls.MintDrop");

        // The fairness commitments. `masterSeed` binds the traits and the
        // rarity shuffle; `namesCommitment` binds the dealt name table. Both
        // are immutable, so a mismatch here means the ART and the CHAIN
        // disagree and the only fix is a redeploy.
        _okUint(b.masterSeed(), c.params.masterSeed, "Bulls.masterSeed == generator MASTER_SEED");
        _ok(
            b.namesCommitment() == c.params.namesCommitment,
            "Bulls.namesCommitment == keccak256(abi.encode(dealt names))"
        );
        _ok(b.initialRarityHash() != bytes32(0), "Bulls.initialRarityHash is set");
        // ⚠ `DECISIONS.md §31`: `Bulls.devWallet` / `freezeRarity()` are GONE.
        // The invariant that replaced them is that the live table can never
        // diverge from the commitment — assert it here, because a difference
        // means a token's tier has moved away from its dealt name AND its
        // sprite, permanently, which is `§27`'s failure with no way back.
        _okBytes32(
            b.rarityHash(), b.initialRarityHash(), "Bulls.rarityHash == initialRarityHash"
        );

        // On mainnet a zero commitment disables the check entirely, which is
        // documented as local/testnet only.
        if (block.chainid == CHAIN_BSC) {
            _ok(b.namesCommitment() != bytes32(0), "Bulls.namesCommitment is NOT zero on mainnet");
        }

        _verifyNameTable(b);
    }

    function _verifyNameTable(Bulls b) private {
        bool required = vm.envOr("REQUIRE_NAMES", false);
        uint256 written = b.namesWritten();

        if (written != 501) {
            if (required || b.namesFrozen()) {
                failures++;
                checks++;
                console2.log("  [FAIL] Bulls.namesWritten != 501 (got", written, ")");
                if (b.namesFrozen()) {
                    console2.log("         AND the table is FROZEN. This is permanent.");
                }
            } else {
                warnings++;
                checks++;
                console2.log("  [warn] names not published yet:", written, "/ 501");
                console2.log("         run script/SetNames.s.sol, then re-verify with");
                console2.log("         REQUIRE_NAMES=true.");
            }
            return;
        }

        _ok(true, "Bulls.namesWritten == 501");

        if (vm.envOr("SKIP_NAME_TABLE_CHECK", false)) {
            console2.log("  [skip] full 501-name table comparison");
            return;
        }

        // The real check: every published name is byte-identical to the
        // generator's dealt table, so the chain and the art agree on which
        // bull is `His Grace the Duke of Blandford`.
        string[] memory names = readNames();
        uint256 bad = 0;
        for (uint256 i = 1; i <= 501; i++) {
            if (!_eq(b.nameOf(i), names[i - 1])) {
                if (bad < 5) {
                    console2.log("  [FAIL] name mismatch at token", i);
                    console2.log("         chain:", b.nameOf(i));
                    console2.log("         table:", names[i - 1]);
                }
                bad++;
            }
        }
        checks++;
        if (bad > 0) {
            failures++;
            console2.log("  [FAIL] name table mismatches:", bad);
        }
    }

    /// @dev A pending timelocked wiring change at launch is somebody mid-way
    ///      through repointing a money slot. Nobody should be.
    function _noPending(Bulls b, Bulls.Wire slot, string memory what) private {
        (, address pending,) = b.wireOf(slot);
        checks++;
        if (pending == address(0)) return;
        warnings++;
        console2.log("  [warn] a timelocked wiring change is PENDING on", what);
        console2.log("         pending", pending);
    }

    // ─── MintDrop ───────────────────────────────────────────────────────

    function _verifyMintDrop(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- MintDrop --");
        MintDrop m = MintDrop(d.mintDrop);

        (address feed, address router, address potA, address potB) = m.wires();
        _okAddr(feed, c.ext.priceFeed, "MintDrop.PriceFeed");
        _okAddr(router, c.ext.routerV2, "MintDrop.Router (pancake v2)");
        _okAddr(potA, d.jackpotBnbull, "MintDrop.JackpotBnbull");
        _okAddr(potB, d.jackpotBnb, "MintDrop.JackpotBnb");
        _hasCode(feed, "MintDrop.PriceFeed");
        _hasCode(router, "MintDrop.Router");
        _hasCode(potA, "MintDrop.JackpotBnbull");
        _hasCode(potB, "MintDrop.JackpotBnb");

        _okAddr(address(m.bulls()), d.bulls, "MintDrop.bulls");
        _okAddr(address(m.bnbull()), d.bnbull, "MintDrop.bnbull");
        _okAddr(address(m.wbnb()), c.ext.wbnb, "MintDrop.wbnb");
        _okAddr(m.treasury(), c.roles.mintTreasury, "MintDrop.treasury");
        _okAddr(m.keeper(), c.roles.keeper, "MintDrop.keeper");

        // ⚠ THE DECIMALS TRAP. Read, never assumed.
        _okUint(
            m.feedDecimals(), AggregatorV3Interface(feed).decimals(),
            "MintDrop.feedDecimals == feed.decimals()"
        );

        // `DECISIONS.md §12`: the $10 -> $75 ladder.
        _okUint(m.priceTierCount(), 5, "MintDrop has 5 price tiers");
        if (m.priceTierCount() == 5) {
            _okUint(m.priceTierAt(0).usdPrice, 10e18, "tier 1 = $10");
            _okUint(m.priceTierAt(1).usdPrice, 20e18, "tier 2 = $20");
            _okUint(m.priceTierAt(2).usdPrice, 35e18, "tier 3 = $35");
            _okUint(m.priceTierAt(3).usdPrice, 50e18, "tier 4 = $50");
            _okUint(m.priceTierAt(4).usdPrice, 75e18, "tier 5 = $75");
            _okUint(m.priceTierAt(4).upToSold, 500, "last tier covers MAX_MINT");
            _ok(m.priceTierAt(4).bnbullPrice != 0, "the BNBULL leg is priced (tier 5)");
        }

        // `DECISIONS.md §13`: 20% BNBULL / 10% BNB / 70% dev.
        _okUint(m.bnbullShareBps(), 2_000, "MintDrop.bnbullShareBps == 2000");
        _okUint(m.bnbShareBps(), 1_000, "MintDrop.bnbShareBps == 1000");
        // `DECISIONS.md §14`: never sell BNBULL. This is a DEFAULT, so a `true`
        // here means somebody actively turned it on.
        _ok(!m.bnbullPaymentSellsForBnbLeg(), "MintDrop never sells BNBULL (DECISIONS 14)");
        // `DECISIONS.md §2`: the discount is ALWAYS BNBULL and only BNBULL.
        _okUint(m.discountBpsOf(d.bnbull), 1_000, "MintDrop BNBULL discount = 1000bps");
        // DECISIONS.md 40: 1500, not the contract default of 500. At 500 a 10%
        // token tax makes every mint's BNBULL buy defer forever, silently.
        _okUint(
            m.inlineSlippageBps(),
            c.params.inlineSlippageBps,
            "MintDrop inlineSlippageBps (40: must clear the token tax)"
        );
        _okUint(m.discountBpsOf(address(0)), 0, "MintDrop BNB discount = 0");

        // ⚠ THE MINIMUM-LIQUIDITY FLOOR (`DECISIONS.md §28`). Pre-graduation
        // there is no pair and the mint's 20% buy is MEANT to defer (`§29`), so
        // a thin or absent pool is a WARNING rather than a failure. It is loud
        // so nobody mistakes months of correct deferral for a working buy leg.
        _okUint(m.minPoolLiquidity(), c.params.minPoolLiquidity, "MintDrop.minPoolLiquidity");
        (address mdPair, uint256 mdReserve) = m.wbnbPoolLiquidity();
        if (mdPair == address(0)) {
            _warn(false, "MintDrop: NO v2 pair yet - the mint BNBULL buy will DEFER (DECISIONS 29)");
        } else {
            _warn(
                mdReserve >= m.minPoolLiquidity(),
                "MintDrop: v2 pair is under minPoolLiquidity - the mint buy will DEFER"
            );
        }

        // The LP slot: pointed somewhere we control, share at zero. On fefers
        // `Graveyard.lpTreasury` on mainnet is STILL a dead rehearsal wallet,
        // inert only because the share happens to be 0.
        _okUint(m.lpShareBps(), 0, "MintDrop.lpShareBps == 0 at launch");
        _okAddr(m.lpTreasury(), d.mintSplitter, "MintDrop.lpTreasury -> MintBnbullSplitter");

        _ok(!m.paused(), "MintDrop is not paused");

        // Does the oracle actually answer? Option A prices EVERYTHING through
        // it, so a mis-wired or stale feed is a total sale outage.
        try m.bnbUsdPrice() returns (uint256 p) {
            _ok(p > 0, "MintDrop.bnbUsdPrice() answers");
            console2.log("  [info] BNB/USD 1e18 =", p);
        } catch {
            failures++;
            checks++;
            console2.log("  [FAIL] MintDrop.bnbUsdPrice() REVERTS - no mint can be priced");
        }
    }

    // ─── Duel ───────────────────────────────────────────────────────────

    function _verifyDuel(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Duel --");
        Duel du = Duel(d.duel);

        (address gy, address potA, address potB, address md) = du.wires();
        _okAddr(gy, d.graveyard, "Duel.Graveyard");
        _okAddr(potA, d.jackpotBnbull, "Duel.JackpotBnbull");
        _okAddr(potB, d.jackpotBnb, "Duel.JackpotBnb");
        _okAddr(md, d.mintDrop, "Duel.MintDrop");
        _hasCode(gy, "Duel.Graveyard");
        _hasCode(potA, "Duel.JackpotBnbull");
        _hasCode(potB, "Duel.JackpotBnb");
        _hasCode(md, "Duel.MintDrop");

        _okAddr(address(du.bulls()), d.bulls, "Duel.bulls");
        _okAddr(address(du.bnbull()), d.bnbull, "Duel.bnbull");
        _okAddr(address(du.wbnb()), c.ext.wbnb, "Duel.wbnb");
        _okAddr(du.devTreasury(), c.roles.devTreasury, "Duel.devTreasury");
        _okAddr(du.trustedSigner(), c.roles.trustedSigner, "Duel.trustedSigner");
        _ok(du.trustedSigner() != address(0), "Duel.trustedSigner is set");

        // ⚠⚠ THE NATIVE FIGHT PATH. Without this asset registered, every WBNB
        // stake reverts `UnsupportedAsset` and the BNB fight does not exist.
        _ok(du.maxFightCostOf(c.ext.wbnb) != 0, "Duel.addFightAsset(WBNB) - THE NATIVE FIGHT PATH");
        _ok(du.maxFightCostOf(d.bnbull) != 0, "Duel.addFightAsset(BNBULL)");
        _ok(du.fightAssetCount() >= 2, "Duel has >= 2 stake assets");
        // ⚠ `DECISIONS.md §26`: the BNB stake is priced from the STORED DOLLAR
        // STICKER through Chainlink, not from `fightCostOf[wbnb]` — that entry
        // is zero forever and `setFightCost` refuses to write it.
        _warn(du.usdFightPrice1e18() != 0, "Duel USD fight sticker is set (0 = BNB fights free)");
        _warn(du.fightCostOf(d.bnbull) != 0, "Duel BNBULL fight cost is priced");
        _okUint(du.fightCostOf(c.ext.wbnb), 0, "Duel has NO stored WBNB peg (oracle-priced)");

        // The listing lockout. Zero means a listed bull can fight, die, and
        // leave the buyer holding a corpse.
        _okAddr(du.marketplace(), d.marketplace, "Duel.setMarketplace");
        _hasCode(du.marketplace(), "Duel.marketplace");

        // `DECISIONS.md §16`: a wallet cannot fight itself, by default.
        _ok(!du.allowSelfDuel(), "Duel.allowSelfDuel == false (DECISIONS 16)");
        // DECISIONS.md 39: NO discount on fights, in any currency. A $2 duel
        // costs $2. The discount belongs to minting. Asserted as ZERO on
        // purpose so a stray setDiscountBps before launch fails the preflight.
        _okUint(du.discountBpsOf(d.bnbull), 0, "Duel BNBULL discount = 0 (39: fights are undiscounted)");
        _okUint(du.discountBpsOf(c.ext.wbnb), 0, "Duel WBNB discount = 0");
        _ok(du.lossesToDie() >= 1 && du.lossesToDie() <= 20, "Duel.lossesToDie in range");
        _ok(du.jackpotResolvePerDuel() > 0, "Duel resolves tickets on its way past");
        _ok(!du.paused(), "Duel is not paused");

        // `DECISIONS.md §13`: the EIP-712 domain is LOCKED to "BNBullsDuel"/"1"
        // and was set before the first deploy. fefers carries "Stable
        // WarriorsDuel" sweep scars because that was not done, and a wrong
        // domain makes EVERY signature fail with `InvalidSignature`.
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("BNBullsDuel")),
                keccak256(bytes("1")),
                block.chainid,
                d.duel
            )
        );
        _ok(du.domainSeparator() == expected, 'Duel EIP-712 domain == "BNBullsDuel" / "1"');
    }

    // ─── Graveyard ──────────────────────────────────────────────────────

    function _verifyGraveyard(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Graveyard --");
        Graveyard g = Graveyard(d.graveyard);

        (address duelAddr, address donateTo, address feed) = g.wires();
        _okAddr(duelAddr, d.duel, "Graveyard.Duel");
        _okAddr(donateTo, d.reviveSplitter, "Graveyard.MintDrop slot -> ReviveBuySplitter");
        _okAddr(feed, c.ext.priceFeed, "Graveyard.PriceFeed");
        // ⚠ The Graveyard donates to this slot with NO try/catch on its side.
        // An EOA here silently swallows the whole pot slice on every revive.
        _hasCode(donateTo, "Graveyard donation target");
        _hasCode(duelAddr, "Graveyard.Duel");
        _hasCode(feed, "Graveyard.PriceFeed");

        _okAddr(address(g.bulls()), d.bulls, "Graveyard.bulls");
        _okAddr(address(g.bnbull()), d.bnbull, "Graveyard.bnbull");
        _okAddr(g.treasury(), c.roles.resurrectTreasury, "Graveyard.treasury");
        _okAddr(g.keeper(), c.roles.keeper, "Graveyard.keeper");
        _okUint(
            g.feedDecimals(), AggregatorV3Interface(feed).decimals(),
            "Graveyard.feedDecimals == feed.decimals()"
        );

        // Zero disables the BNBULL revive leg (`BnbullPathNotPriced`).
        _ok(g.bnbullPerUsd() != 0, "Graveyard.bnbullPerUsd is set (else no BNBULL revive)");
        _okUint(g.potShareBps(), 3_000, "Graveyard.potShareBps == 3000 (70% dev)");
        _okUint(g.lpShareBps(), 0, "Graveyard.lpShareBps == 0 at launch");
        _ok(g.lpTreasury() != address(0), "Graveyard.lpTreasury is not the zero address");
        _okUint(g.discountBpsOf(d.bnbull), 1_000, "Graveyard BNBULL discount = 1000bps");
        _ok(g.maxResurrects() != 0, "Graveyard.maxResurrects != 0");
        _ok(!g.paused(), "Graveyard is not paused");

        // ⚠ A ZERO TAKEOVER RUNG WOULD LET ANYONE WALK OFF WITH A DEAD BULL
        // FOR FREE. The constructor seeds real economics for this reason;
        // `setLadders` can still write a zero, so check the live values.
        uint256[] memory owned = g.ownerLadder();
        uint256[] memory take = g.takeoverLadder();
        _ok(owned.length > 0, "Graveyard owner ladder is non-empty");
        _ok(take.length > 0, "Graveyard takeover ladder is non-empty");
        for (uint256 i = 0; i < take.length; i++) {
            _ok(take[i] != 0, "Graveyard takeover rung is non-zero (free corpses otherwise)");
        }
        for (uint256 i = 0; i < owned.length; i++) {
            _ok(owned[i] != 0, "Graveyard owner rung is non-zero");
        }
    }

    // ─── The two pots ───────────────────────────────────────────────────

    function _verifyPot(
        Cfg memory c,
        Deployment memory d,
        Jackpot p,
        address prize,
        uint256 odds,
        string memory tag
    ) private {
        console2.log("");
        console2.log(string.concat("-- ", tag), "--");

        _okAddr(address(p.prizeToken()), prize, string.concat(tag, ".prizeToken"));
        _okUint(p.oddsOneIn(), odds, string.concat(tag, ".oddsOneIn"));

        // Without this, `recordWin` reverts `NotDuel`, Duel's try/catch eats
        // it, and NO TICKET IS EVER OPENED. The jackpot simply never happens.
        _okAddr(p.duel(), d.duel, string.concat(tag, ".bootstrapDuel(duel)"));
        _hasCode(p.duel(), string.concat(tag, ".duel"));
        (, address pendingDuel,) = p.duelWire();
        _warn(pendingDuel == address(0), string.concat(tag, " has no pending Duel change"));

        // THE FUNDER ROLES. Each missing one is a permanent silent deferral of
        // an entire buyback leg.
        _ok(p.isFunder(d.mintDrop), string.concat(tag, ".setFunder(MintDrop)"));
        _ok(p.isFunder(d.duel), string.concat(tag, ".setFunder(Duel) - the dev-cut direct leg"));
        _ok(
            p.isFunder(d.mintSplitter),
            string.concat(tag, ".setFunder(MintBnbullSplitter) - else every buyback defers")
        );
        _ok(
            p.isFunder(d.reviveSplitter),
            string.concat(tag, ".setFunder(ReviveBuySplitter) - else every revive leg defers")
        );
        _ok(p.isRequester(c.roles.keeper), string.concat(tag, ".setRequester(keeper)"));

        // No VRF config -> `requestResolve` reverts `VrfNotConfigured` and the
        // ticket queue can never move. Fights are unaffected, so nothing looks
        // broken until somebody asks why the pot has never paid out.
        _ok(p.keyHash() != bytes32(0), string.concat(tag, ".keyHash is set"));
        _ok(p.subscriptionId() != 0, string.concat(tag, ".subscriptionId is set"));
        _ok(
            p.requestConfirmations() >= p.MIN_REQUEST_CONFIRMATIONS(),
            string.concat(tag, ".requestConfirmations >= MIN")
        );
        _ok(p.callbackGasLimit() > 0, string.concat(tag, ".callbackGasLimit > 0"));

        // ⚠ `DECISIONS.md §38` — THE KEYHASH NOBODY SERVES.
        // `requestRandomWords` does NOT consult the proving-key registry, so a
        // typo'd gas lane returns a REAL request id, sets `pendingRequestId`,
        // and then `RequestInFlight` wedges the entire ticket queue until
        // timeout. Rejection would have been a five-minute deploy bug;
        // acceptance is a silent one. The registry is public, so this is
        // checkable here and nowhere else in the deploy path.
        _provingKeyRegistered(p, tag);

        // `DECISIONS.md §18` — THE most serious defect found so far. The
        // trusted coordinator is a TIMELOCKED slot on the pot itself, and
        // `fulfillRandomWords` refuses a word from anyone else. Chainlink's own
        // `setCoordinator` is still owner-callable with no timelock, so it is
        // no longer SUFFICIENT: a real migration is propose -> wait -> commit
        // here AND `setCoordinator` there.
        _okAddr(
            p.trustedCoordinator(), c.ext.vrfCoordinator,
            string.concat(tag, ".trustedCoordinator (timelocked, DECISIONS 18)")
        );
        _hasCode(p.trustedCoordinator(), string.concat(tag, ".trustedCoordinator"));
        (, address pendingCoord, uint64 coordEta) = p.coordinatorWire();
        checks++;
        if (pendingCoord != address(0)) {
            failures++;
            console2.log("  [FAIL] A COORDINATOR CHANGE IS PENDING on", tag);
            console2.log("         pending", pendingCoord);
            console2.log("         eta    ", coordEta);
            console2.log("         Whoever delivers the word decides who gets paid.");
        }

        _ok(p.payoutBps() > 0 && p.payoutBps() <= 10_000, string.concat(tag, ".payoutBps in range"));
        _okAddr(p.owner(), c.roles.deployer, string.concat(tag, ".owner is still the deployer"));
    }

    /**
     * @notice Assert the pot's configured keyHash is a lane the coordinator
     *         ACTUALLY SERVES — `DECISIONS.md §38`.
     *
     * @dev `s_provingKeys(bytes32)` returns `(bool exists, uint64 maxGas)` and
     *      is public on every real VRF v2.5 coordinator. Three outcomes, and
     *      only one of them is silence:
     *
     *        - `exists == true`  → the lane is registered. Reported with its
     *          `maxGas` so the gas price the lane's NAME claims can be eyeballed
     *          against the number the coordinator actually holds.
     *        - `exists == false` → **LOUD, NAMED FAILURE, on every chain.** This
     *          is the §38 defect: the request would be accepted and never
     *          fulfilled.
     *        - the coordinator does not answer at all → a failure on a real
     *          chain (a v2.5 coordinator that cannot answer is not the contract
     *          we think we are pointed at), a warning on anvil, where
     *          `MockVRFCoordinator` has no registry to answer from.
     *
     *      ⚠ REGISTRATION IS NOT PROOF OF SERVICE. Only a real fulfilment
     *      proves a lane is being served. This closes the typo, not the outage.
     */
    function _provingKeyRegistered(Jackpot p, string memory tag) private {
        bytes32 kh = p.keyHash();
        // A zero keyHash already failed above as ".keyHash is set"; there is no
        // lane to look up, and a second failure on the same cause is noise.
        if (kh == bytes32(0)) {
            console2.log(
                "  [info] no keyHash configured, so no lane to check:", tag
            );
            return;
        }

        checks++;
        (bool ok, bytes memory ret) = p.trustedCoordinator().staticcall(
            abi.encodeWithSignature("s_provingKeys(bytes32)", kh)
        );

        if (!ok || ret.length < 64) {
            if (block.chainid == CHAIN_ANVIL) {
                warnings++;
                console2.log(
                    "  [warn] coordinator has no s_provingKeys registry (mock):", tag
                );
                return;
            }
            failures++;
            console2.log("  [FAIL]", string.concat(tag, ".keyHash lane CANNOT BE PROVEN"));
            console2.log("         the coordinator does not answer s_provingKeys(bytes32).");
            console2.log("         coordinator", p.trustedCoordinator());
            console2.log("         That is not a VRF v2.5 coordinator, or not the one we think.");
            return;
        }

        (bool exists, uint64 maxGas) = abi.decode(ret, (bool, uint64));
        if (!exists) {
            failures++;
            console2.log("  [FAIL]", string.concat(tag, ".keyHash IS NOT A REGISTERED LANE"));
            console2.log("         keyHash");
            console2.logBytes32(kh);
            console2.log("         coordinator", p.trustedCoordinator());
            console2.log("         DECISIONS 38: requestRandomWords ACCEPTS this anyway. It");
            console2.log("         returns a real request id, sets pendingRequestId, and then");
            console2.log("         RequestInFlight wedges the whole ticket queue until timeout.");
            console2.log("         The pot fills and never pays, with no error anywhere.");
            return;
        }

        console2.log(string.concat("  [ok]    ", tag, ".keyHash lane is registered, maxGas"), maxGas);
    }

    // ─── Marketplace ────────────────────────────────────────────────────

    function _verifyMarketplace(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Marketplace --");
        Marketplace mk = Marketplace(payable(d.marketplace));

        (address feed, address bull) = mk.wires();
        _okAddr(feed, c.ext.priceFeed, "Marketplace.PriceFeed");
        _okAddr(bull, d.bnbull, "Marketplace.Bnbull");
        _hasCode(feed, "Marketplace.PriceFeed");
        _hasCode(bull, "Marketplace.Bnbull");

        _okAddr(address(mk.collection()), d.bulls, "Marketplace.collection");
        _okAddr(mk.feeTreasury(), c.roles.feeTreasury, "Marketplace.feeTreasury");
        _okAddr(mk.keeper(), c.roles.keeper, "Marketplace.keeper");
        // `DECISIONS.md §21`: 750 bps total, of which 250 bps OF THE SALE buys
        // BNBULL into the pot. `jackpotFeeBps <= feeBps` or the dev leg
        // underflows — enforced on chain, asserted here too.
        _okUint(mk.feeBps(), c.params.marketplaceFeeBps, "Marketplace.feeBps");
        _okUint(mk.jackpotFeeBps(), c.params.marketplaceJackpotFeeBps, "Marketplace.jackpotFeeBps");
        _ok(mk.feeBps() <= mk.MAX_FEE_BPS(), "Marketplace.feeBps <= MAX_FEE_BPS");
        _ok(mk.jackpotFeeBps() <= mk.feeBps(), "Marketplace.jackpotFeeBps <= feeBps");

        // ⚠ THE JACKPOT SINK. Unwired means every jackpot slice of every sale
        // accrues instead of buying BNBULL — which is also the legitimate
        // pre-liquidity state, so it is invisible either way.
        _okAddr(mk.jackpotSink(), d.marketSplitter, "Marketplace.JackpotSink");
        _hasCode(mk.jackpotSink(), "Marketplace.JackpotSink");

        // Bulls CAN die, so a corpse must not be listable.
        _ok(mk.blocksDeadListings(), "Marketplace.setBlocksDeadListings(true)");
        _ok(mk.bnbullUsd1e18() != 0, "Marketplace BNBULL/USD peg is seeded");
        _okUint(
            mk.bnbullDecimals(), IERC20Metadata(bull).decimals(),
            "Marketplace.bnbullDecimals == BNBULL.decimals()"
        );
        _okUint(
            mk.feedDecimals(), AggregatorV3Interface(feed).decimals(),
            "Marketplace.feedDecimals == feed.decimals()"
        );
        _ok(!mk.paused(), "Marketplace is not paused");
    }

    // ─── The splitters ──────────────────────────────────────────────────

    /// @param pooled true for the two 20/10 splitters; false for the
    ///        marketplace sink, which must be 100% BNBULL / 0% BNB off its own
    ///        local fallback with the `MintDrop` policy slot left UNWIRED.
    function _verifySplitter(
        Cfg memory c,
        Deployment memory d,
        PotSplitter s,
        string memory tag,
        bool pooled
    ) private {
        console2.log("");
        console2.log(string.concat("-- ", tag), "--");

        (address bull, address router, address potA, address potB, address policy) = s.wires();

        _okAddr(bull, d.bnbull, string.concat(tag, ".Bnbull"));
        // ⚠ THE **v2** ROUTER — `DECISIONS.md §28`. If this ever reads back as
        // the v3 SmartRouter again, the BNBULL buy leg cannot reach four.meme's
        // book at all and the only pool it could find would be a stranger's
        // decoy (measured at 95x worse). Verifying the address is verifying the
        // venue.
        _okAddr(router, c.ext.routerV2, string.concat(tag, ".Router (pancake v2)"));
        _okAddr(potA, d.jackpotBnbull, string.concat(tag, ".JackpotBnbull"));
        _okAddr(potB, d.jackpotBnb, string.concat(tag, ".JackpotBnb"));
        if (pooled) {
            _okAddr(policy, d.mintDrop, string.concat(tag, ".MintDrop (live policy read)"));
            _hasCode(policy, string.concat(tag, ".MintDrop"));
        } else {
            // ⚠ MUST STAY UNWIRED. `potPolicy()` prefers the MintDrop read, so
            // wiring it here would make the marketplace sink read 2000/1000 and
            // quietly route a third of every jackpot slice into the BNB pot,
            // when the whole point of this instance is 100% BNBULL.
            _okAddr(
                policy, address(0),
                string.concat(tag, ".MintDrop policy slot is UNWIRED (100% BNBULL by design)")
            );
        }
        _hasCode(bull, string.concat(tag, ".Bnbull"));
        _hasCode(router, string.concat(tag, ".Router"));
        _hasCode(potA, string.concat(tag, ".JackpotBnbull"));
        _hasCode(potB, string.concat(tag, ".JackpotBnb"));

        _okAddr(address(s.wbnb()), c.ext.wbnb, string.concat(tag, ".wbnb"));
        _okAddr(s.keeper(), c.roles.keeper, string.concat(tag, ".setKeeper"));

        // ⚠⚠ MANDATORY. No floors -> `floorsFresh()` is false -> the pre-check
        // on every swap leg fails -> EVERY slice defers into a `pending*`
        // bucket instead of buying anything. Nothing reverts. Nothing warns.
        _ok(s.floorsFresh(), string.concat(tag, ".setFloors - FRESH (else EVERY swap defers)"));
        _ok(s.bnbullPerBnb() != 0, string.concat(tag, ".bnbullPerBnb != 0 (BNB -> BNBULL leg)"));
        // Only reachable if the never-sell-BNBULL policy is ever switched off,
        // so a zero here is a warning rather than a failure.
        _warn(s.wbnbPerBnbull() != 0, string.concat(tag, ".wbnbPerBnbull != 0 (only used if DECISIONS 14 off)"));
        _ok(s.maxFloorAge() > 0, string.concat(tag, ".maxFloorAge > 0"));

        // ⚠ THE MINIMUM-LIQUIDITY FLOOR (`DECISIONS.md §28`). The contract
        // refuses a zero, so this can only fail if the wiring never ran. Then
        // the pool read: pre-graduation there is no pair and the leg is MEANT
        // to defer (`§29`), so a thin or absent pool is a WARNING, not a
        // failure — it is the expected launch state, and the deploy must not
        // stop on it. It is loud so nobody mistakes months of deferral for a
        // working buy leg.
        _okUint(
            s.minPoolLiquidity(), c.params.minPoolLiquidity,
            string.concat(tag, ".minPoolLiquidity")
        );
        (address pair, uint256 wbnbReserve) = s.wbnbPoolLiquidity();
        if (pair == address(0)) {
            _warn(false, string.concat(tag, ": NO v2 pair yet - every BNBULL buy will DEFER (DECISIONS 29)"));
        } else {
            _warn(
                wbnbReserve >= s.minPoolLiquidity(),
                string.concat(tag, ": v2 pair is under minPoolLiquidity - buys will DEFER")
            );
        }

        _okUint(
            s.bnbullDecimals(), IERC20Metadata(bull).decimals(),
            string.concat(tag, ".bnbullDecimals == BNBULL.decimals()")
        );

        // The local fallback must match the live policy, or a MintDrop read
        // outage silently changes the split. For the marketplace sink the
        // fallback IS the policy, and it is a ratio: (2000, 0) means all of it
        // to BNBULL.
        uint256 wantBnb = pooled ? 1_000 : 0;
        _okUint(s.fallbackBnbullShareBps(), 2_000, string.concat(tag, ".fallback BNBULL share"));
        _okUint(s.fallbackBnbShareBps(), wantBnb, string.concat(tag, ".fallback BNB share"));
        _ok(
            !s.fallbackSellsForBnbLeg(),
            string.concat(tag, " fallback never sells BNBULL (DECISIONS 14)")
        );

        // And the live read has to actually work.
        (uint256 a, uint256 b, bool sells) = s.potPolicy();
        _okUint(a, 2_000, string.concat(tag, ".potPolicy() live BNBULL share"));
        _okUint(b, wantBnb, string.concat(tag, ".potPolicy() live BNB share"));
        _ok(!sells, string.concat(tag, ".potPolicy() never sells BNBULL"));

        // Deferred money at verify time means a slice already failed to reach a
        // pot. Before launch that is a wiring bug; ALLOW_DEFERRALS=true is for
        // the chain-97 rehearsal, where there is no BNBULL pool and deferring
        // is the correct, expected behaviour being rehearsed.
        if (!vm.envOr("ALLOW_DEFERRALS", false)) {
            _ok(s.pendingBnbullBuyNative() == 0, string.concat(tag, " has no deferred BNB->BNBULL"));
            _ok(s.pendingBnbPotNative() == 0, string.concat(tag, " has no deferred BNB pot slice"));
        }
    }

    // ─── Cross-cutting ──────────────────────────────────────────────────

    function _verifyCrossCutting(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- cross-cutting --");

        // ⚠ `address(this)` IS IN THE ROLL PREIMAGE. Two pots at the SAME
        // address would hash identically and, with 50 dividing 100, every win
        // on the 1-in-100 pot would come with a win on the 1-in-50 pot, which
        // claims the duel key first — so the second pot pays NEVER. Measured on
        // Stable: 600 duels, 7 payouts on one pot, 0 on the other.
        _ok(
            d.jackpotBnbull != d.jackpotBnb,
            "the two pots are DISTINCT deployments (roll separation)"
        );
        _ok(
            Jackpot(d.jackpotBnbull).oddsOneIn() != Jackpot(d.jackpotBnb).oddsOneIn(),
            "the two pots carry different odds"
        );
        _ok(d.mintSplitter != d.reviveSplitter, "the mint and revive splitters are distinct");
        _ok(
            d.marketSplitter != d.mintSplitter && d.marketSplitter != d.reviveSplitter,
            "the marketplace pot splitter is its own instance (100% BNBULL policy)"
        );

        // The cursor every keeper and indexer starts from. A zero forces a
        // full-chain rescan on every restart, and a wrong one loses events.
        _ok(d.deployBlock != 0, "deployBlock is recorded and non-zero");
        // `+ 1` of slack, deliberately: in a combined deploy-then-verify run
        // the simulation's `block.number` has not moved since the cursor was
        // taken, and a fresh anvil sits at 0 with the cursor clamped to 1.
        _ok(d.deployBlock <= block.number + 1, "deployBlock is not in the future");

        // Everything deployed exists.
        _hasCode(d.bnbull, "BNBULL token");
        _hasCode(d.bulls, "Bulls");
        _hasCode(d.mintDrop, "MintDrop");
        _hasCode(d.duel, "Duel");
        _hasCode(d.graveyard, "Graveyard");
        _hasCode(d.jackpotBnbull, "Jackpot BNBULL");
        _hasCode(d.jackpotBnb, "Jackpot BNB");
        _hasCode(d.marketplace, "Marketplace");
        _hasCode(d.mintSplitter, "MintBnbullSplitter");
        _hasCode(d.reviveSplitter, "ReviveBuySplitter");
        _hasCode(d.marketSplitter, "MarketPotSplitter");

        // The one-way switches must NOT have run yet at verify time.
        if (d.bnbull.code.length > 0) {
            (bool ok, bytes memory ret) =
                d.bnbull.staticcall(abi.encodeWithSignature("limitsActive()"));
            if (ok && ret.length == 32) {
                _warn(
                    abi.decode(ret, (bool)),
                    "BNBull.limitsActive - liftLimits() already ran (fine if intended)"
                );
            }
        }

        console2.log("  [info] deployer  ", c.roles.deployer);
        console2.log("  [info] final owner", c.roles.owner);
        if (c.roles.owner != c.roles.deployer) {
            console2.log("  [info] ownership has NOT been handed over yet - run Handover.s.sol");
            console2.log("         LAST, and remember the two pots are ConfirmedOwner:");
            console2.log("         the new owner must call acceptOwnership() itself.");
        }
    }
}

/**
 * @title Verify
 * @notice `forge script script/Verify.s.sol:Verify --rpc-url $RPC_URL`
 *         Read-only. No broadcast, no keys, safe to run against mainnet.
 */
contract Verify is VerifyCore {
    function run() external {
        Deployment memory d = readDeployment();
        // Built from the RECORD, not from env — see `loadVerifyConfig`. Any
        // external address env disagrees about is a hard failure there.
        Cfg memory c = loadVerifyConfig(d);
        verifyAll(c, d);
    }
}
