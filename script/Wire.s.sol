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
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";

/**
 * @title WireCore
 * @notice THE DANGEROUS PART. Everything here fails SILENTLY if it is missed:
 *         the game keeps working, players keep paying, and the money quietly
 *         goes somewhere other than where the design says it goes.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      THE SILENT FAILURE MODES THIS FILE CLOSES
 *      ══════════════════════════════════════════════════════════════════════
 *      Each of these is reported by the contract authors as a miss that does
 *      NOT revert, does NOT log an error, and does NOT stop a single player.
 *      `Verify.s.sol` asserts every one of them afterwards, because a wiring
 *      checklist that is only a comment WILL be missed.
 *
 *      1. **`Jackpot.setFunder(splitter, true)` on BOTH pots.** `Jackpot.fund`
 *         reverts `NotFunder`, that revert is caught by the splitter's
 *         `try this.routeTo…Inline() catch { accrue }`, and the slice lands in
 *         a `pending*` bucket. Every buyback defers. Forever. The only symptom
 *         is a `…Deferred` event nobody is watching on day one.
 *
 *      2. **`Jackpot.setFunder(duel, true)` on both pots.** The Duel routes a
 *         BNBULL or WBNB dev cut STRAIGHT into the matching pot (`§14`: nothing
 *         sells BNBULL). Without the role, `_payDevCut`'s try/catch swallows it
 *         and the whole cut silently goes to dev instead of the pot.
 *
 *      3. **`Jackpot.bootstrapDuel(duel)` on both pots.** Without it
 *         `recordWin` reverts `NotDuel`; `Duel._rollOnePool` wraps the call so
 *         the fight still settles — and NO TICKET IS EVER OPENED. A jackpot
 *         that never pays, with no error anywhere.
 *
 *      4. **`Jackpot.setVrfConfig(...)` on both pots.** `requestResolve`
 *         reverts `VrfNotConfigured`. Tickets pile up and none can ever be
 *         decided. Again: fights are unaffected.
 *
 *      5. **`Duel.addFightAsset(WBNB)`.** Without it `_takeSide` reverts
 *         `UnsupportedAsset` and **the native fight path simply is not a
 *         thing** — the UI offers it and every submit reverts. ⚠ `maxCost` is
 *         ONE-SHOT and permanent per asset.
 *
 *      6. **The splitters' five wires + `setFloors`.** A splitter with no floors
 *         has `floorsFresh() == false`, its pre-check fails, and EVERY swap
 *         defers. `setFloors` is mandatory at deploy, not a keeper nicety.
 *
 *      7. **`Marketplace.setBlocksDeadListings` / `Duel.setMarketplace`.**
 *         Without the second one a listed bull can be sent into a fight, die,
 *         and leave the buyer holding a corpse.
 *
 *      8. **`BNBull.setWhitelist` on every contract that moves BNBULL.**
 *         ⛔ THE WORST OF THE LOT, AND IT WAS NOT IN THIS FILE AT ALL —
 *         `setWhitelist` was called only by `script/anvil/DeployLocal.s.sol`,
 *         so the real deploy path whitelisted nothing. `tradingEnabled` ships
 *         FALSE, which is the LAUNCH STATE and not an error state
 *         (`DECISIONS.md §29`), so a WINNING jackpot ticket's `safeTransfer`
 *         reverts `TradingNotEnabled`, `Duel._resolveOnly` swallows it exactly
 *         as it must, and the ticket queue wedges with nothing reverting for a
 *         player and nothing logged. Observed live on chain 97: the queue
 *         stopped at the first winning ticket and 77 more piled up behind it
 *         while the game read perfectly healthy.
 *
 *      9. **`Jackpot.setTimeouts` on both pots.** The contract's own default
 *         used to be SHORTER than a measured VRF fulfilment, so a keeper
 *         obeying it cancelled requests that were about to land. Nothing set
 *         it here, which is `DECISIONS.md §40`'s bug for the third time.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      RE-RUNNABLE ON PURPOSE
 *      ══════════════════════════════════════════════════════════════════════
 *      `bootstrapWire` reverts once a slot is filled and `addFightAsset` reverts
 *      on a repeat, so a naive script cannot be resumed after a partial run —
 *      which is exactly when you most want to resume it. Every step here reads
 *      the current value first and skips a match, so a re-run is safe. A slot
 *      already pointing somewhere ELSE is reported loudly and left alone: that
 *      needs `proposeWire` -> wait `wiringDelay` -> `commitWire`, deliberately.
 */
abstract contract WireCore is BnbullsConfig {
    uint256 internal wiresWritten;
    uint256 internal wiresSkipped;
    uint256 internal wiresConflicted;

    function _note(string memory what, bool wrote) private {
        if (wrote) {
            wiresWritten++;
            console2.log("  [set]  ", what);
        } else {
            wiresSkipped++;
            console2.log("  [ok]   ", what);
        }
    }

    function _conflict(string memory what, address want, address have) private {
        wiresConflicted++;
        console2.log("");
        console2.log("  /!\\ SLOT ALREADY POINTS SOMEWHERE ELSE:", what);
        console2.log("      want:", want);
        console2.log("      have:", have);
        console2.log("      Wiring is TIMELOCKED, not one-time-set. Change it with");
        console2.log("      proposeWire -> wait wiringDelay -> commitWire. Not here.");
        console2.log("");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The wiring, in order
    // ══════════════════════════════════════════════════════════════════════

    /// @dev MUST be called inside a broadcast, by the OWNER of every contract.
    function wireAll(Cfg memory c, Deployment memory d) internal {
        _wireBulls(c, d);
        _wireMintDrop(c, d);
        _wireDuel(c, d);
        _wireGraveyard(c, d);
        _wireJackpot(c, d, Jackpot(d.jackpotBnbull), "BNBULL pot");
        _wireJackpot(c, d, Jackpot(d.jackpotBnb), "BNB pot");
        _wireMarketplace(c, d);
        _wireSplitter(c, d, PotSplitter(d.mintSplitter), "MintBnbullSplitter", true);
        _wireSplitter(c, d, PotSplitter(d.reviveSplitter), "ReviveBuySplitter", true);
        _wireSplitter(c, d, PotSplitter(d.marketSplitter), "MarketPotSplitter", false);
        _wireMarketSplitterPolicy(d);
        wireTokenWhitelist(c, d);

        console2.log("");
        console2.log("== wiring summary ==");
        console2.log("  written  ", wiresWritten);
        console2.log("  already  ", wiresSkipped);
        console2.log("  CONFLICTS", wiresConflicted);
    }

    // ─── 1. Bulls: the collection has to know who may mutate a bull ──────

    function _wireBulls(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Bulls --");
        Bulls b = Bulls(d.bulls);

        // Without MintDrop: `mint` reverts NotMintDropOrOwner.
        _bullsWire(b, Bulls.Wire.MintDrop, d.mintDrop, "Bulls.MintDrop");
        // Without Duel: `applyDuelResult` reverts NotAuthorized -> EVERY fight
        // reverts. This one is loud, at least.
        _bullsWire(b, Bulls.Wire.Duel, d.duel, "Bulls.Duel");
        // Without Graveyard: `resurrect` / `graveyardClaim` revert -> no revive
        // can ever complete.
        _bullsWire(b, Bulls.Wire.Graveyard, d.graveyard, "Bulls.Graveyard");

        if (bytes(c.params.baseURI).length > 0) {
            b.setBaseURI(c.params.baseURI);
            _note("Bulls.baseURI", true);
        }
    }

    function _bullsWire(Bulls b, Bulls.Wire slot, address target, string memory label) private {
        (address cur,,) = b.wireOf(slot);
        if (cur == target) return _note(label, false);
        if (cur != address(0)) return _conflict(label, target, cur);
        b.bootstrapWire(slot, target);
        _note(label, true);
    }

    // ─── 2. MintDrop: the money layer ───────────────────────────────────

    function _wireMintDrop(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- MintDrop --");
        MintDrop m = MintDrop(d.mintDrop);

        // Wiring the feed READS `decimals()`, so a feed that does not
        // implement it fails HERE and not on the first mint.
        _dropWire(m, MintDrop.Wire.PriceFeed, c.ext.priceFeed, "MintDrop.PriceFeed");
        _dropWire(m, MintDrop.Wire.Router, c.ext.routerV2, "MintDrop.Router(v2)");
        _dropWire(m, MintDrop.Wire.JackpotBnbull, d.jackpotBnbull, "MintDrop.JackpotBnbull");
        _dropWire(m, MintDrop.Wire.JackpotBnb, d.jackpotBnb, "MintDrop.JackpotBnb");
        // ⚠ `Wire.SwapIntermediate` IS DELIBERATELY NOT WIRED, AND MUST NOT BE
        // ADDED HERE. Dormant backup for `DECISIONS.md §30`; see the identical
        // note in `_wireSplitter`. Recovery is two owner transactions by hand:
        // `setMinPoolLiquidityAlt` first, then `bootstrapWire`.
        console2.log("  [info] SwapIntermediate LEFT UNWIRED (one hop, WBNB - DECISIONS 28)");

        if (m.keeper() != c.roles.keeper) {
            m.setKeeper(c.roles.keeper);
            _note("MintDrop.keeper", true);
        } else {
            _note("MintDrop.keeper", false);
        }

        // ⚠ NOTHING SET THIS BEFORE, AND THAT WAS THE BUG (DECISIONS.md 40).
        // The contract's own default is 500, which cannot clear a 10% token
        // tax. Wiring it explicitly means the launch value is a decision in
        // the config rather than whatever the constructor happened to hold.
        if (m.inlineSlippageBps() != c.params.inlineSlippageBps) {
            m.setInlineSlippageBps(c.params.inlineSlippageBps);
            _note("MintDrop.inlineSlippageBps", true);
        } else {
            _note("MintDrop.inlineSlippageBps", false);
        }

        // ⚠ THE SAME BUG AS `inlineSlippageBps`, ONE LINE LOWER. The three
        // splitters get `minPoolLiquidity` wired from config by `_wireSplitter`;
        // MintDrop — which runs the mint's OWN inline BNBULL buy — never did,
        // so its floor could only ever be the constructor default of 1 ether.
        //
        // On mainnet the config default is ALSO 1 ether, so the two agree by
        // coincidence and the gap is invisible. Move the config value for any
        // reason — a thinner launch pool, a re-measured decoy threat (`§28`) —
        // and MintDrop silently keeps 1 ether while the splitters follow, so
        // the mint's buy leg defers forever while every other leg trades. That
        // is a `§37`-shaped failure: nothing reverts, nothing logs, and the
        // deferral is indistinguishable from the ordinary `§29` one.
        //
        // `Verify` already asserted this value; nothing had ever SET it.
        if (m.minPoolLiquidity() != c.params.minPoolLiquidity) {
            m.setMinPoolLiquidity(c.params.minPoolLiquidity);
            _note("MintDrop.minPoolLiquidity", true);
        } else {
            _note("MintDrop.minPoolLiquidity", false);
        }

        // The LP slot: repointed at the splitter, share left at 0. See the
        // DeployCore header for why it could not be constructed this way.
        if (m.lpTreasury() != d.mintSplitter) {
            m.setLpTreasury(d.mintSplitter);
            _note("MintDrop.lpTreasury -> MintBnbullSplitter", true);
        } else {
            _note("MintDrop.lpTreasury", false);
        }

        // `DECISIONS.md §12`: the $10 -> $75 ladder. The BNBULL column is the
        // keeper's peg of the FULL, UNDISCOUNTED sticker — MintDrop takes the
        // 10% off itself, so pre-discounting here would double-apply it.
        if (m.priceTierCount() == 0) {
            m.setPriceTiers(launchTiers(c));
            _note("MintDrop.priceTiers (10/20/35/50/75)", true);
        } else {
            _note("MintDrop.priceTiers", false);
        }
    }

    function _dropWire(MintDrop m, MintDrop.Wire slot, address target, string memory label)
        private
    {
        (address cur,,) = m.wireOf(slot);
        if (cur == target) return _note(label, false);
        if (cur != address(0)) return _conflict(label, target, cur);
        m.bootstrapWire(slot, target);
        _note(label, true);
    }

    /// @notice `DECISIONS.md §12`. 100 -> $10, 200 -> $20, 300 -> $35,
    ///         400 -> $50, 500 -> $75. Gross at full mint ~ $19,000.
    /// @dev The BNBULL column is derived from `MARKETPLACE_BNBULL_USD` so the
    ///      table and the pegs cannot disagree at deploy. The keeper re-pegs it
    ///      afterwards; `assertTableSafe` on the keeper side refuses a write
    ///      that moves a dollar column or an `upToSold` boundary.
    function launchTiers(Cfg memory c) internal pure returns (MintDrop.PriceTier[] memory t) {
        uint256 usdPerBnbull = c.params.marketplaceBnbullUsd; // 1e18-scaled
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({
            upToSold: 100,
            usdPrice: 10e18,
            bnbullPrice: uint128(_pegBnbull(10e18, usdPerBnbull))
        });
        t[1] = MintDrop.PriceTier({
            upToSold: 200,
            usdPrice: 20e18,
            bnbullPrice: uint128(_pegBnbull(20e18, usdPerBnbull))
        });
        t[2] = MintDrop.PriceTier({
            upToSold: 300,
            usdPrice: 35e18,
            bnbullPrice: uint128(_pegBnbull(35e18, usdPerBnbull))
        });
        t[3] = MintDrop.PriceTier({
            upToSold: 400,
            usdPrice: 50e18,
            bnbullPrice: uint128(_pegBnbull(50e18, usdPerBnbull))
        });
        t[4] = MintDrop.PriceTier({
            upToSold: 500,
            usdPrice: 75e18,
            bnbullPrice: uint128(_pegBnbull(75e18, usdPerBnbull))
        });
    }

    function _pegBnbull(uint256 usd1e18, uint256 usdPerBnbull1e18) private pure returns (uint256) {
        if (usdPerBnbull1e18 == 0) return 0;
        return (usd1e18 * 1e18) / usdPerBnbull1e18;
    }

    // ─── 3. Duel ────────────────────────────────────────────────────────

    function _wireDuel(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Duel --");
        Duel du = Duel(d.duel);

        _duelWire(du, Duel.Wire.Graveyard, d.graveyard, "Duel.Graveyard");
        _duelWire(du, Duel.Wire.JackpotBnbull, d.jackpotBnbull, "Duel.JackpotBnbull");
        _duelWire(du, Duel.Wire.JackpotBnb, d.jackpotBnb, "Duel.JackpotBnb");
        // ⚠ NOW THE ORACLE SOURCE, NOT A MONEY ROUTE (`DECISIONS.md §26`).
        // `Duel.bnbUsdPrice()` reads MintDrop's Chainlink view to convert the
        // stored dollar sticker into a BNB stake. Leave this unwired and every
        // BNB fight quote reverts `OracleNotWired` — fail-closed, but the BNB
        // fight does not exist until it is set.
        _duelWire(du, Duel.Wire.MintDrop, d.mintDrop, "Duel.MintDrop (oracle)");
        // ⚠⚠ THE CONSENT GATE, AND IT IS THE ONE WHOSE MISS IS SILENT IN THE
        // MOST DANGEROUS DIRECTION. Every other slot in this file fails toward
        // "the money went somewhere else"; this one fails toward "there is no
        // check at all". `Duel._requireInYards` reads the slot and RETURNS
        // EARLY when it is zero, so an unwired Yards does not close the arena,
        // it opens it: every bull in the collection is fightable by anyone who
        // can get a signature, including on the zero-stake path that touches no
        // allowance and still kills a bull on its `lossesToDie`-th loss.
        // `test_anUnwiredYardsSlotLeavesEveryDuelUngated` runs exactly that.
        _duelWire(du, Duel.Wire.Yards, d.yards, "Duel.Yards (THE consent gate)");

        // ⚠ THE NATIVE FIGHT PATH. Miss this and `submitDuel` reverts
        // `UnsupportedAsset` on every WBNB stake — the BNB fight does not
        // exist. `maxCost` is a PERMANENT ceiling; `addFightAsset` is one-shot.
        _addAsset(du, c.ext.wbnb, c.params.maxFightWbnb, 0, "Duel asset WBNB");
        _addAsset(
            du, d.bnbull, c.params.maxFightBnbull, c.params.fightBnbull, "Duel asset BNBULL"
        );

        // ⚠ THE DOLLAR ANCHOR (`DECISIONS.md §26`). WBNB has NO stored peg —
        // `setFightCost` refuses it — so this one number is what prices every
        // BNB fight, converted through Chainlink at read time.
        if (du.usdFightPrice1e18() != c.params.fightWbnb) {
            du.setUsdFightPrice(c.params.fightWbnb);
            _note("Duel.setUsdFightPrice (BNB stake sticker)", true);
        } else {
            _note("Duel.setUsdFightPrice (BNB stake sticker)", false);
        }

        // The listing lockout. Zero here means a listed bull can be sent into
        // a fight and die under the buyer.
        if (du.marketplace() != d.marketplace) {
            du.setMarketplace(d.marketplace);
            _note("Duel.marketplace", true);
        } else {
            _note("Duel.marketplace", false);
        }
    }

    function _duelWire(Duel du, Duel.Wire slot, address target, string memory label) private {
        (address cur,,) = du.wireOf(slot);
        if (cur == target) return _note(label, false);
        if (cur != address(0)) return _conflict(label, target, cur);
        du.bootstrapWire(slot, target);
        _note(label, true);
    }

    function _addAsset(Duel du, address asset, uint256 maxCost, uint256 cost, string memory label)
        private
    {
        if (du.maxFightCostOf(asset) == 0) {
            du.addFightAsset(asset, maxCost, type(uint16).max);
            _note(label, true);
        } else {
            _note(label, false);
        }
        // `cost == 0` means "this asset has no stored peg" — the WBNB case,
        // where `setFightCost` reverts `OraclePricedAsset` by design.
        if (cost != 0 && du.fightCostOf(asset) != cost) {
            du.setFightCost(asset, cost);
            _note(string.concat(label, " cost"), true);
        }
    }

    // ─── 4. Graveyard ───────────────────────────────────────────────────

    function _wireGraveyard(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Graveyard --");
        Graveyard g = Graveyard(d.graveyard);

        _gyWire(g, Graveyard.Wire.Duel, d.duel, "Graveyard.Duel");
        // ⚠ POINTED AT THE SPLITTER, NOT AT MintDrop. The Graveyard donates its
        // pot slice to whatever sits in this slot with NO try/catch of its own;
        // `ReviveBuySplitter` implements the same two selectors and divides the
        // slice across both pots in the live 2:1 ratio. Pointing it straight at
        // MintDrop also works and sends the whole slice through MintDrop's own
        // split — but then the BNB pot only ever gets fed from BNB revives.
        _gyWire(g, Graveyard.Wire.MintDrop, d.reviveSplitter, "Graveyard.MintDrop -> splitter");
        _gyWire(g, Graveyard.Wire.PriceFeed, c.ext.priceFeed, "Graveyard.PriceFeed");

        if (g.keeper() != c.roles.keeper) {
            g.setKeeper(c.roles.keeper);
            _note("Graveyard.keeper", true);
        } else {
            _note("Graveyard.keeper", false);
        }

        // Zero disables the BNBULL revive leg entirely — `resurrectWithBNBULL`
        // reverts `BnbullPathNotPriced`. Seeded here so the leg is live before
        // the first keeper tick.
        if (g.bnbullPerUsd() != c.params.graveyardBnbullPerUsd) {
            g.setBnbullPerUsd(c.params.graveyardBnbullPerUsd);
            _note("Graveyard.bnbullPerUsd", true);
        } else {
            _note("Graveyard.bnbullPerUsd", false);
        }

        // lpShareBps stays 0. The slot is pointed at something we control so it
        // is never the fefers situation: a live payout slot aimed at a dead
        // rehearsal wallet, inert only because the share happens to be zero.
        if (g.lpTreasury() != d.mintSplitter) {
            g.setLpTreasury(d.mintSplitter);
            _note("Graveyard.lpTreasury -> MintBnbullSplitter", true);
        } else {
            _note("Graveyard.lpTreasury", false);
        }
    }

    function _gyWire(Graveyard g, Graveyard.Wire slot, address target, string memory label)
        private
    {
        (address cur,,) = g.wireOf(slot);
        if (cur == target) return _note(label, false);
        if (cur != address(0)) return _conflict(label, target, cur);
        g.bootstrapWire(slot, target);
        _note(label, true);
    }

    // ─── 5. The two pots ────────────────────────────────────────────────

    function _wireJackpot(Cfg memory c, Deployment memory d, Jackpot p, string memory tag)
        private
    {
        console2.log("");
        console2.log(string.concat("-- Jackpot: ", tag), " --");

        // No Duel wired -> `recordWin` reverts NotDuel -> the roll is swallowed
        // by Duel's try/catch -> NO TICKET IS EVER OPENED.
        if (p.duel() == address(0)) {
            p.bootstrapDuel(d.duel);
            _note(string.concat(tag, ".duel"), true);
        } else if (p.duel() == d.duel) {
            _note(string.concat(tag, ".duel"), false);
        } else {
            _conflict(string.concat(tag, ".duel"), d.duel, p.duel());
        }

        // ⛔ SPEND THE ONE FREE PAYOUT-PARAM WRITE, HERE, ON DEPLOY DAY.
        //
        // `oddsOneIn` / `payoutBps` / `minPoolToFire` decide WHO wins and HOW
        // MUCH they take, so they are money slots: once `payoutParamsBootstrapped`
        // is set, every later change is propose -> wait `wiringDelay` -> commit,
        // in public, with an ETA. Leaving the free instant write UNSPENT on a
        // live pot leaves a one-shot, no-notice change to the payout terms
        // sitting available to whoever holds the owner key — which is the whole
        // thing the timelock exists to remove.
        //
        // Odds come from the constructor (BNB 1-in-75, BNBULL 1-in-150) and
        // payoutBps stays the 100% full-drain default (owner: "winner takes the
        // lot"). The one value set HERE is the minPoolToFire dust guard (owner
        // decision 2026-08-08): ~$10 of WBNB on the BNB pot so a near-empty pot
        // never "pays", and 0 on the BNBULL pot, which has no USD peg
        // pre-graduation. A dust guard need not track USD precisely, so a fixed
        // WBNB wei is fine. Spends the one free payout-param write; `Verify`
        // asserts it happened.
        if (!p.payoutParamsBootstrapped()) {
            uint256 minPool = address(p) == d.jackpotBnb ? 0.0168 ether : 0;
            p.bootstrapPayoutParams(p.oddsOneIn(), p.payoutBps(), minPool);
            _note(string.concat(tag, ".payoutParams bootstrapped"), true);
        } else {
            _note(string.concat(tag, ".payoutParams bootstrapped"), false);
        }

        // THE FUNDER ROLES. Every one of these is a silent deferral if missed.
        _funder(p, d.mintDrop, string.concat(tag, ".funder MintDrop"));
        _funder(p, d.duel, string.concat(tag, ".funder Duel"));
        _funder(p, d.mintSplitter, string.concat(tag, ".funder MintBnbullSplitter"));
        _funder(p, d.reviveSplitter, string.concat(tag, ".funder ReviveBuySplitter"));
        _funder(p, d.marketSplitter, string.concat(tag, ".funder MarketPotSplitter"));

        // The keeper needs the requester role or nothing resolves until a
        // ticket is `publicRequestDelayBlocks` old.
        if (!p.isRequester(c.roles.keeper)) {
            p.setRequester(c.roles.keeper, true);
            _note(string.concat(tag, ".requester keeper"), true);
        } else {
            _note(string.concat(tag, ".requester keeper"), false);
        }

        // No VRF config -> `requestResolve` reverts VrfNotConfigured and the
        // ticket queue can never move. Fights are unaffected, so nothing looks
        // wrong until someone asks why the pot has never paid.
        if (p.keyHash() == bytes32(0) || p.subscriptionId() == 0) {
            if (c.ext.vrfKeyHash == bytes32(0) || c.ext.vrfSubId == 0) {
                console2.log("  /!\\ VRF NOT CONFIGURED.");
                console2.log("      keyHash supplied:", c.ext.vrfKeyHash != bytes32(0));
                console2.log("      subId supplied:  ", c.ext.vrfSubId);
                // ⚠ `setVrfConfig` REFUSES a zero on either field, so a keyHash
                // alone cannot be landed — both or neither. Name the env vars
                // for the chain actually being deployed to: printing the
                // mainnet names during a chain-97 run sends the operator to
                // edit two lines that are never read here, and the symptom of
                // that is another full run that changes nothing.
                if (block.chainid == CHAIN_BSC_TESTNET) {
                    console2.log("      Set VRF_KEY_HASH_TESTNET + VRF_SUBSCRIPTION_ID_TESTNET,");
                } else {
                    console2.log("      Set VRF_KEY_HASH_200GWEI + VRF_SUBSCRIPTION_ID,");
                }
                console2.log("      then re-run. Until then tickets open and NEVER resolve:");
                console2.log("      requestResolve reverts VrfNotConfigured, the Duel's");
                console2.log("      try/catch swallows it, and the pot fills and never pays.");
                wiresConflicted++;
            } else {
                p.setVrfConfig(c.ext.vrfKeyHash, c.ext.vrfSubId, 3, 200_000, true);
                _note(string.concat(tag, ".vrfConfig"), true);
            }
        } else {
            _note(string.concat(tag, ".vrfConfig"), false);
        }

        // ⚠ THE TWO TIMEOUTS, WRITTEN EXPLICITLY. `DECISIONS.md §40` for the
        // third time: nothing set these, so the contract's own defaults shipped
        // by accident — and `requestTimeoutBlocks` defaulted to 1,200 blocks
        // (~9 minutes at ~0.45s) when the FIRST live chain-97 fulfilment took
        // **3,169 blocks, ~24 minutes**. A keeper obeying that number cancels a
        // request that is about to be answered: the subscription payment is
        // spent, and the word that finally arrives is DISCARDED because its id
        // no longer matches. Both numbers now come from the config, and
        // `setTimeouts` writes them together because that is its signature.
        if (
            p.requestTimeoutBlocks() != c.params.vrfRequestTimeoutBlocks
                || p.publicRequestDelayBlocks() != c.params.vrfPublicRequestDelayBlocks
        ) {
            p.setTimeouts(
                c.params.vrfRequestTimeoutBlocks, c.params.vrfPublicRequestDelayBlocks
            );
            _note(string.concat(tag, ".setTimeouts (VRF stall + dead-keeper)"), true);
        } else {
            _note(string.concat(tag, ".setTimeouts (VRF stall + dead-keeper)"), false);
        }

        // ⚠ THE COORDINATOR IS BOOTSTRAPPED IN THE CONSTRUCTOR and is
        // TIMELOCKED thereafter (`DECISIONS.md §18`). Nothing to do here — but
        // a real Chainlink VRF migration later is BOTH halves:
        //     p.proposeCoordinator(new)  -> wait wiringDelay -> p.commitCoordinator()
        //     p.setCoordinator(new)      (VRFConsumerBaseV2Plus, no timelock)
        // Until both agree, words from the new coordinator are REFUSED with
        // `UntrustedCoordinator`. Doing only `setCoordinator` is precisely the
        // hand-pick-a-winner attack the timelock exists to stop.
        console2.log("  [info] trustedCoordinator", p.trustedCoordinator());
    }

    function _funder(Jackpot p, address who, string memory label) private {
        if (p.isFunder(who)) return _note(label, false);
        p.setFunder(who, true);
        _note(label, true);
    }

    // ─── 6. Marketplace ─────────────────────────────────────────────────

    function _wireMarketplace(Cfg memory c, Deployment memory d) private {
        console2.log("");
        console2.log("-- Marketplace --");
        Marketplace mk = Marketplace(payable(d.marketplace));

        _mkWire(mk, Marketplace.Wire.PriceFeed, c.ext.priceFeed, "Marketplace.PriceFeed");
        _mkWire(mk, Marketplace.Wire.Bnbull, d.bnbull, "Marketplace.Bnbull");

        if (mk.keeper() != c.roles.keeper) {
            mk.setKeeper(c.roles.keeper);
            _note("Marketplace.keeper", true);
        } else {
            _note("Marketplace.keeper", false);
        }

        // Defaults true, but set explicitly and asserted: this collection CAN
        // die, so a corpse must not be listable.
        if (!mk.blocksDeadListings()) {
            mk.setBlocksDeadListings(true);
            _note("Marketplace.blocksDeadListings", true);
        } else {
            _note("Marketplace.blocksDeadListings", false);
        }

        // Seeds the BNBULL/USD peg so `BnbullMode.Pegged` listings work from
        // block one rather than reverting on a stale peg.
        if (mk.bnbullUsd1e18() != c.params.marketplaceBnbullUsd) {
            mk.setBnbullUsd(c.params.marketplaceBnbullUsd);
            _note("Marketplace.bnbullUsd", true);
        } else {
            _note("Marketplace.bnbullUsd", false);
        }

        // `DECISIONS.md §21`: 7.5% fee, of which 2.5% OF THE SALE buys BNBULL
        // into the pot. Set `feeBps` FIRST — `setJackpotFeeBps` is bounded by
        // the live `feeBps`, and `setFee` refuses a fee below the live jackpot
        // leg, so lowering both at once has an order that works and an order
        // that reverts.
        if (mk.feeBps() != c.params.marketplaceFeeBps) {
            mk.setFee(c.params.marketplaceFeeBps);
            _note("Marketplace.feeBps", true);
        } else {
            _note("Marketplace.feeBps", false);
        }
        if (mk.jackpotFeeBps() != c.params.marketplaceJackpotFeeBps) {
            mk.setJackpotFeeBps(c.params.marketplaceJackpotFeeBps);
            _note("Marketplace.jackpotFeeBps", true);
        } else {
            _note("Marketplace.jackpotFeeBps", false);
        }

        // ⚠ THE JACKPOT SINK. Leave it zero and every jackpot slice of every
        // sale accrues to `potFeeUndelivered` instead of reaching the pot —
        // which is a LEGITIMATE launch state (there is no BNBULL pool until
        // four.meme's curve fills), and therefore indistinguishable from the
        // mistake of never wiring it at all. Wire it, and let the accrual mean
        // what it is supposed to mean: no liquidity yet.
        _mkWire(
            mk, Marketplace.Wire.JackpotSink, d.marketSplitter,
            "Marketplace.JackpotSink -> MarketPotSplitter"
        );
    }

    function _mkWire(Marketplace mk, Marketplace.Wire slot, address target, string memory label)
        private
    {
        (address cur,,) = mk.wireOf(slot);
        if (cur == target) return _note(label, false);
        if (cur != address(0)) return _conflict(label, target, cur);
        mk.bootstrapWire(slot, target);
        _note(label, true);
    }

    // ─── 7. The splitters: six wires each, plus floors ──────────────────

    /**
     * @param wirePolicy Wire `MintDrop` as the live policy source. TRUE for the
     *        two 20/10 splitters. **FALSE for the marketplace sink**, which has
     *        to stay on its own local 100%-BNBULL fallback — wiring MintDrop
     *        there would make it read 2000/1000 and quietly send a third of
     *        every marketplace jackpot slice to the BNB pot instead.
     */
    function _wireSplitter(
        Cfg memory c,
        Deployment memory d,
        PotSplitter s,
        string memory tag,
        bool wirePolicy
    ) private {
        console2.log("");
        console2.log(string.concat("-- Splitter: ", tag), " --");

        _spWire(s, PotSplitter.Wire.Bnbull, d.bnbull, string.concat(tag, ".Bnbull"));
        // ⚠ THE **v2** ROUTER, THE SAME ONE MintDrop USES — `DECISIONS.md §28`.
        // This slot used to carry the v3 SmartRouter, which could never reach
        // four.meme's book: the pad graduates into PancakeSwap v2 against WBNB
        // and creates NO v3 pool at any tier, so the only thing a v3 leg could
        // ever find is somebody else's decoy (measured at 95x worse). The
        // factory — and therefore the minimum-liquidity floor — is derived from
        // this router's own `factory()`, never wired separately.
        _spWire(s, PotSplitter.Wire.Router, c.ext.routerV2, string.concat(tag, ".Router(v2)"));
        _spWire(
            s, PotSplitter.Wire.JackpotBnbull, d.jackpotBnbull,
            string.concat(tag, ".JackpotBnbull")
        );
        _spWire(s, PotSplitter.Wire.JackpotBnb, d.jackpotBnb, string.concat(tag, ".JackpotBnb"));
        // Read live for the 20/10/never-sell policy, so the split has ONE
        // source of truth on chain.
        if (wirePolicy) {
            _spWire(
                s, PotSplitter.Wire.MintDrop, d.mintDrop, string.concat(tag, ".MintDrop(policy)")
            );
        } else {
            console2.log("  [info] MintDrop policy slot LEFT UNWIRED on purpose (100% BNBULL)");
        }
        // ⚠ `Wire.SwapIntermediate` IS DELIBERATELY NOT WIRED HERE, AND MUST
        // NOT BE ADDED TO THIS SCRIPT. It is the dormant backup for
        // `DECISIONS.md §30` — 19 of four.meme's 20 templates graduate into a
        // NON-BNB pool — and BNBULL is expected to graduate against WBNB, which
        // is the one-hop route this whole file assumes. Wiring it turns every
        // swap into two hops. If a graduation ever lands somewhere else, the
        // recovery is TWO owner transactions, in this order and by hand:
        //   1. setMinPoolLiquidityAlt(<floor in X's own smallest unit>)
        //   2. bootstrapWire(Wire.SwapIntermediate, X)   (timelocked after)
        // Doing (2) first is safe but stops every swap until (1) lands.
        console2.log("  [info] SwapIntermediate LEFT UNWIRED (one hop, WBNB - DECISIONS 28)");

        if (s.keeper() != c.roles.keeper) {
            s.setKeeper(c.roles.keeper);
            _note(string.concat(tag, ".keeper"), true);
        } else {
            _note(string.concat(tag, ".keeper"), false);
        }

        // ⚠ THE MINIMUM-LIQUIDITY FLOOR. Under it, every swap leg defers and
        // accrues instead of trading — which is the EXPECTED launch state
        // (`DECISIONS.md §29`), not an error state. It replaced the v3 fee
        // tier: v2 has no fee tiers, and a dial that picks a pool is a dial
        // that can pick the wrong pool.
        if (s.minPoolLiquidity() != c.params.minPoolLiquidity) {
            s.setMinPoolLiquidity(c.params.minPoolLiquidity);
            _note(string.concat(tag, ".minPoolLiquidity"), true);
        } else {
            _note(string.concat(tag, ".minPoolLiquidity"), false);
        }

        // ⚠ MANDATORY. With no floors published, `floorsFresh()` is false, the
        // pre-check on every swap leg fails, and EVERY slice defers into a
        // `pending*` bucket instead of buying anything. A zero rate is a
        // deliberate per-leg kill switch, not a default.
        if (!s.floorsFresh()) {
            s.setFloors(c.params.floorBnbullPerBnb, c.params.floorWbnbPerBnbull);
            _note(string.concat(tag, ".setFloors"), true);
        } else {
            _note(string.concat(tag, ".setFloors"), false);
        }
    }

    /**
     * @dev The marketplace sink is 100% BNBULL / 0% BNB, per the `Marketplace`
     *      header: its `jackpotFeeBps` slice buys BNBULL into the no-withdraw
     *      BNBULL pot, it does not divide across both pots the way a revive
     *      does.
     *
     *      `ReviveBuySplitter._route` divides in the `bnbullBps : bnbBps` RATIO,
     *      so (2000, 0) means "all of it to BNBULL" — the absolute numbers do
     *      not matter, only the ratio. And `false` on the third argument is
     *      `DECISIONS.md §14` again: a buyer paying IN BNBULL is never sold.
     */
    function _wireMarketSplitterPolicy(Deployment memory d) private {
        PotSplitter s = PotSplitter(d.marketSplitter);
        if (
            s.fallbackBnbullShareBps() == 2_000 && s.fallbackBnbShareBps() == 0
                && !s.fallbackSellsForBnbLeg()
        ) {
            _note("MarketPotSplitter policy 100% BNBULL / 0% BNB", false);
            return;
        }
        s.setFallbackPolicy(2_000, 0, false);
        _note("MarketPotSplitter policy 100% BNBULL / 0% BNB", true);
    }

    function _spWire(PotSplitter s, PotSplitter.Wire slot, address target, string memory label)
        private
    {
        (address cur,,) = s.wireOf(slot);
        if (cur == target) return _note(label, false);
        if (cur != address(0)) return _conflict(label, target, cur);
        s.bootstrapWire(slot, target);
        _note(label, true);
    }

    // ─── 8. The BNBULL transfer whitelist ───────────────────────────────

    /**
     * @notice ⛔ LET THE GAME MOVE BNBULL WHILE THE LAUNCH GATE IS SHUT.
     *
     * @dev THE DEFECT THIS CLOSES, exactly as it happened on chain 97.
     *      `BNBull` ships `tradingEnabled = false` and whitelists only the
     *      initial owner and holder. That is the real launch state, not a
     *      mistake — `DECISIONS.md §29` launches BNB-first and opens BNBULL
     *      after the curve. But `_update` then refuses any transfer with
     *      neither side whitelisted, so the moment a BNBULL jackpot ticket
     *      WINS, `prizeToken.safeTransfer(winner, paid)` reverts
     *      `TradingNotEnabled`. `Duel._resolveOnly` swallows that — correctly,
     *      a pot fault must never revert a fight — and the queue stops dead at
     *      that ticket with **nothing reverting for a player and nothing
     *      logged**. 77 tickets piled up behind the first winner while every
     *      dashboard read healthy.
     *
     *      ⚠ WHY THIS IS A NO-OP ON MAINNET, AND WHY THAT IS PROBED RATHER
     *      THAN ASSUMED. `DECISIONS.md §4` launches on four.meme, whose token
     *      is theirs and has no whitelist to write — so this must be a skip,
     *      not a revert that stops the wiring half way through. The probe is a
     *      `staticcall` of `whitelisted(address)`, because a chain-id test
     *      would be wrong the day we self-issue on mainnet and right for the
     *      wrong reason on chain 97.
     *
     *      ⚠ AND OWNERSHIP IS CHECKED BEFORE WRITING. A BNBULL that HAS a
     *      whitelist but is not ours cannot be written to, and the whole point
     *      of this file is that a broadcast which dies half way through is far
     *      worse than one that reports a gap. Reported as a CONFLICT, loudly,
     *      and `Verify` fails on the missing entries afterwards.
     *
     *      Read-first / skip / bulk-write, so a re-run costs nothing and a
     *      partial run resumes — the same idiom as every other step here. The
     *      write is ONE `setWhitelistBulk` rather than ten `setWhitelist`
     *      transactions, because the reads that make it idempotent are free.
     */
    function wireTokenWhitelist(Cfg memory c, Deployment memory d) internal {
        console2.log("");
        console2.log("-- BNBULL transfer whitelist --");

        if (!tokenHasWhitelist(d.bnbull)) {
            console2.log("  [info] this BNBULL has no whitelist (four.meme's - DECISIONS 4).");
            console2.log("         Nothing to write, and nothing to miss. Skipped.");
            return;
        }

        BNBull token = BNBull(d.bnbull);
        if (token.owner() != c.roles.deployer) {
            wiresConflicted++;
            console2.log("");
            console2.log("  /!\\ THIS BNBULL HAS A WHITELIST AND WE DO NOT OWN IT.");
            console2.log("      token owner:", token.owner());
            console2.log("      broadcaster:", c.roles.deployer);
            console2.log("      setWhitelist is onlyOwner, so every entry below is unwritable");
            console2.log("      from here. Until they are set, a WINNING BNBULL jackpot ticket");
            console2.log("      reverts TradingNotEnabled, Duel swallows it, and the ticket");
            console2.log("      queue wedges with no error anywhere. Verify fails on this.");
            console2.log("");
            return;
        }

        (address[] memory movers, string[] memory labels) = bnbullMovers(d);

        // ⚠ THE ROUTER IS NOT A MOVER AND IS LISTED ANYWAY. No game leg needs
        // it — `_update` passes on ONE whitelisted side, so a pair-to-MintDrop
        // swap output already clears — but an LP seed moves BNBULL through it
        // in amounts far over the launch window's 1%/0.5% caps, and those caps
        // bite whitelisted-neither transfers even after `enableTrading()`. It
        // is deliberately outside `bnbullMovers` so `Verify` treats a missing
        // router as a warning and a missing POT as a failure.
        //
        // The PAIR is not listed because it does not exist yet: it is created
        // by the first `addLiquidity`. Whitelist it by hand at launch if the
        // caps are still active.
        address[] memory want = new address[](movers.length + 1);
        for (uint256 i = 0; i < movers.length; i++) {
            want[i] = movers[i];
        }
        want[movers.length] = c.ext.routerV2;

        address[] memory missing = new address[](want.length);
        uint256 n;
        for (uint256 i = 0; i < want.length; i++) {
            string memory label = i < movers.length
                ? string.concat("BNBULL whitelist: ", labels[i])
                : "BNBULL whitelist: PancakeSwap v2 router";
            if (want[i] == address(0)) {
                // A zero here means the deployment record is incomplete. The
                // token would happily whitelist address(0) and teach nobody
                // anything, so say so instead.
                wiresConflicted++;
                console2.log("  /!\\ ZERO ADDRESS in the whitelist set:", label);
                continue;
            }
            if (tokenWhitelists(d.bnbull, want[i])) {
                _note(label, false);
                continue;
            }
            missing[n++] = want[i];
            _note(label, true);
        }

        if (n == 0) return;
        address[] memory batch = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            batch[i] = missing[i];
        }
        token.setWhitelistBulk(batch, true);
        console2.log("  [set]   setWhitelistBulk entries written:", n);
    }
}

/**
 * @title Wire
 * @notice `forge script script/Wire.s.sol:Wire --rpc-url $RPC_URL --broadcast`
 *         Run straight after `Deploy`, then `Verify`.
 */
contract Wire is WireCore {
    function run() external {
        address deployer = msg.sender;

        // ⚠ THIS SCRIPT BROADCASTS, SO IT GETS THE SAME GATES `Deploy` DOES.
        // It used to have none: no key discipline, no chain assertion, no
        // mainnet confirmation. Every money route in the game is set here, and
        // several slots are bootstrap-once — pointing one at the wrong address
        // because `--rpc-url` resolved somewhere unexpected costs a redeploy,
        // not a re-run.
        keyGuard();
        chainGuard();

        Cfg memory c = loadConfig(deployer);
        Deployment memory d = readDeployment();

        // The BNBULL token address is fixed by the deployment record, not by
        // env — a rehearsal that changed BNBULL_TOKEN must not silently rewire
        // a live deployment at a different token.
        c.ext.bnbull = d.bnbull;

        console2.log("== bnbulls wiring ==");
        console2.log("  chain ", block.chainid);
        console2.log("  caller", deployer);
        logDeployment(d);

        vm.startBroadcast();
        wireAll(c, d);
        vm.stopBroadcast();

        console2.log("");
        console2.log("  NEXT: script/Verify.s.sol. It asserts every silent-failure leg.");
        console2.log("  THEN: script/SetNames.s.sol (501 names + freeze).");
    }
}
