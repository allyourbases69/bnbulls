// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Duel} from "../contracts/Duel.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {Jackpot} from "../contracts/Jackpot.sol";

/**
 * @title DuelGraveyardBase
 * @notice Shared harness for the `Duel` + `Graveyard` suites.
 *
 * @dev ⚠ MOCKS ONLY — NO MAINNET FORK, DELIBERATELY. `BNBULLS-BOOTSTRAP.md §5`
 *      and `Base.t.sol` both say why: nothing is deployed on chain 56 yet, and
 *      a BSC-fork E2E against the real PancakeSwap router, the real Chainlink
 *      BNB/USD feed and the real VRF coordinator is a LATER SLICE. Everything
 *      here is mocks, driven into failure modes a fork could not reproduce on
 *      demand.
 *
 *      This extends `BnbullsBase` rather than standing up a parallel harness,
 *      so the economic frame is the same one every other suite reads against:
 *        BNB/USD  = $600            (feed, 8 decimals)
 *        BNBULL   = $0.01           (so $50 pegs at 5,000 BNBULL undiscounted)
 *
 *      What this file adds on top: the REAL `Duel` and the REAL `Graveyard`
 *      (the base harness only carries `MockDuel`), fully cross-wired to Bulls,
 *      both Jackpots and MintDrop, plus an EIP-712 signing helper and a
 *      `_fight` helper that drives real signed duels — which is the only
 *      honest way to produce a corpse for the Graveyard suites.
 */
abstract contract DuelGraveyardBase is BnbullsBase {
    // ─── The two contracts under test ─────────────────────────────────────

    /// @dev Named `duelC` because `BnbullsBase.duel` is the `MockDuel` the
    ///      Jackpot suites use. Both exist; only this one is the real thing.
    Duel internal duelC;
    Graveyard internal grave;

    // ─── The signer ───────────────────────────────────────────────────────

    /// @notice Private key of the trusted duel signer. The API's key stands
    ///         in here; nothing else in the suite may hold it.
    uint256 internal constant SIGNER_PK = 0xB011_51_6E;
    uint256 internal constant ROGUE_PK = 0xBADBAD;
    address internal signer;
    address internal rogueSigner;

    /// @notice Dev cut recipient for fights. Distinct from `treasury` (which
    ///         takes mint and revive proceeds) so the two ledgers never blur.
    address internal duelTreasury = address(0xDE7);

    // ─── Fight economics used by the expectations ─────────────────────────

    /// @notice Per-asset ceilings, fixed at registration and immutable after.
    uint256 internal constant MAX_COST_WBNB = 100 ether;
    uint256 internal constant MAX_COST_BNBULL = 1_000_000e18;
    /// @dev A real, ordinary BNBULL stake. Well under the ceiling, and non-zero
    ///      so a decisive duel actually earns its jackpot ticket (`§25`).
    uint256 internal constant STAKE_BNBULL = 250e18;
    /// @notice 10% dev cut on every stake asset at launch.
    uint16 internal constant DEV_BPS = 1_000;

    /// @notice The keeper's BNBULL peg for the Graveyard: BNBULL wei per ONE
    ///         DOLLAR at the FULL undiscounted sticker. $0.01 a token.
    uint256 internal constant BNBULL_PER_USD = 100e18;

    /// @notice THE DOLLAR ANCHOR (`DECISIONS.md §26`). $10 a fighter, stored on
    ///         `Duel` as a plain dollar figure and converted to BNB through the
    ///         Chainlink feed at read time. There is no WBNB peg to set.
    uint256 internal constant USD_FIGHT_PRICE = 10e18;
    /// @notice What that sticker comes to in BNB at the harness's $600. This is
    ///         `Duel.stickerCost(wbnb)` and it MOVES with the feed — a test that
    ///         warps the price and expects this constant is testing the wrong
    ///         thing.
    uint256 internal constant STAKE_WBNB_AT_600 = (USD_FIGHT_PRICE * 1e18) / BNB_USD_1E18;

    // ─── Bookkeeping ──────────────────────────────────────────────────────

    uint256 internal _nonceSeq;

    // ══════════════════════════════════════════════════════════════════════
    //  Setup
    // ══════════════════════════════════════════════════════════════════════

    function setUp() public virtual override {
        super.setUp();

        signer = vm.addr(SIGNER_PK);
        rogueSigner = vm.addr(ROGUE_PK);

        duelC = _newDuel(address(bulls));
        grave = new Graveyard(owner, address(bulls), address(bnbull), treasury);

        // Bulls -> the two game contracts.
        bulls.bootstrapWire(Bulls.Wire.Duel, address(duelC));
        bulls.bootstrapWire(Bulls.Wire.Graveyard, address(grave));

        // Duel -> everything it can push money at.
        duelC.bootstrapWire(Duel.Wire.Graveyard, address(grave));
        duelC.bootstrapWire(Duel.Wire.JackpotBnbull, address(potBnbull));
        duelC.bootstrapWire(Duel.Wire.JackpotBnb, address(potBnb));
        duelC.bootstrapWire(Duel.Wire.MintDrop, address(drop));

        // The pots have to know which Duel may open tickets, and that Duel's
        // dev-cut leg has to be an allowed funder.
        potBnbull.bootstrapDuel(address(duelC));
        potBnb.bootstrapDuel(address(duelC));
        potBnbull.setFunder(address(duelC), true);
        potBnb.setFunder(address(duelC), true);

        // Graveyard -> the ladder's dependencies.
        grave.bootstrapWire(Graveyard.Wire.Duel, address(duelC));
        grave.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        grave.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));
        grave.setKeeper(keeper);
        grave.setBnbullPerUsd(BNBULL_PER_USD);
    }

    /// @dev A fully configured `Duel` over an arbitrary Bulls collection.
    ///      Stake assets are registered here so every suite reads the same
    ///      ceilings and dev cuts.
    function _newDuel(address bulls_) internal returns (Duel d) {
        d = new Duel(
            Duel.DeployParams({
                initialOwner: owner,
                bulls: bulls_,
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                trustedSigner: vm.addr(SIGNER_PK),
                devTreasury: duelTreasury,
                defaultDevShareBps: DEV_BPS
            })
        );
        d.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        d.addFightAsset(address(bnbull), MAX_COST_BNBULL, DEV_BPS);
        // The keeper's peg, at the FULL undiscounted sticker. $10 a fight.
        d.setFightCost(address(bnbull), 1_000e18);
        // ⚠ THE BNB LEG IS NOT A PEG (`DECISIONS.md §26`). `setFightCost` on
        // WBNB reverts `OraclePricedAsset`; the dollar sticker is stored and
        // converted through `MintDrop.bnbUsdPrice()` at read time, so the Duel
        // needs its MintDrop wire before a BNB fight can be quoted at all.
        d.setUsdFightPrice(USD_FIGHT_PRICE);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Bulls
    // ══════════════════════════════════════════════════════════════════════

    function _mintBull(address to) internal returns (uint256 tokenId) {
        return bulls.mint(to);
    }

    function _mintBullOn(Bulls b, address to) internal returns (uint256 tokenId) {
        return b.mint(to);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Signing — EIP-712, exactly as `api/run-duel` does it
    // ══════════════════════════════════════════════════════════════════════

    function _sign(Duel.DuelResult memory r) internal view returns (bytes memory) {
        return _signWith(duelC, SIGNER_PK, r);
    }

    function _signOn(Duel d, Duel.DuelResult memory r) internal view returns (bytes memory) {
        return _signWith(d, SIGNER_PK, r);
    }

    function _signWith(Duel d, uint256 pk, Duel.DuelResult memory r)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(pk, d.hashDuelResult(r));
        return abi.encodePacked(rs, ss, v);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Building and submitting a fight
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev A signable `DuelResult` with LIVE sequence numbers, a fresh nonce
     *      and no stakes. Tests mutate the fields they care about.
     *
     *      ⚠ The `oa == ob` branch is the composition rule from
     *      `DECISIONS.md §16`: with `allowSelfDuel` on, both sides are the same
     *      wallet's, the sequence is consumed twice in order, so the signer
     *      names `seq` and `seq + 1`.
     */
    function _newResult(uint256 tokenA, uint256 tokenB, uint32 winnerId)
        internal
        returns (Duel.DuelResult memory r)
    {
        return _newResultOn(duelC, bulls, tokenA, tokenB, winnerId);
    }

    function _newResultOn(Duel d, Bulls b, uint256 tokenA, uint256 tokenB, uint32 winnerId)
        internal
        returns (Duel.DuelResult memory r)
    {
        address oa = b.ownerOf(tokenA);
        address ob = b.ownerOf(tokenB);
        uint64 sa = d.nextFightSeq(oa);
        uint64 sb = d.nextFightSeq(ob);
        if (oa == ob) sb = sa + 1;

        _nonceSeq += 1;
        r = Duel.DuelResult({
            tokenA: tokenA,
            tokenB: tokenB,
            winnerId: winnerId,
            rounds: 7,
            seed: uint256(keccak256(abi.encodePacked("bnbulls-seed", _nonceSeq))),
            newEloA: 1_050,
            newEloB: 950,
            assetA: address(0),
            assetB: address(0),
            stakeA: 0,
            stakeB: 0,
            seqA: sa,
            seqB: sb,
            nonce: _nonceSeq,
            expiry: block.timestamp + 1 hours
        });
    }

    /**
     * @dev Submit as side A's owner, which is the ordinary player path.
     *
     *      ⚠ The signature is computed BEFORE `vm.prank`. `hashDuelResult` is
     *      an external view call, so signing inside the pranked expression
     *      would spend the prank on the hash read and let the real submit
     *      through as the test contract. Every submit helper here therefore
     *      builds `sig` on its own line first — do not "tidy" it back inline.
     */
    function _submit(Duel.DuelResult memory r) internal {
        bytes memory sig = _sign(r);
        vm.prank(bulls.ownerOf(r.tokenA));
        duelC.submitDuel(r, sig);
    }

    function _submitAs(address who, Duel.DuelResult memory r) internal {
        bytes memory sig = _sign(r);
        vm.prank(who);
        duelC.submitDuel(r, sig);
    }

    function _submitValue(address who, Duel.DuelResult memory r, uint256 value) internal {
        bytes memory sig = _sign(r);
        vm.prank(who);
        duelC.submitDuel{value: value}(r, sig);
    }

    function _submitOn(Duel d, Bulls b, Duel.DuelResult memory r) internal {
        bytes memory sig = _signOn(d, r);
        vm.prank(b.ownerOf(r.tokenA));
        d.submitDuel(r, sig);
    }

    /// @dev Submit and require an exact revert. Same prank-ordering rule.
    function _expectSubmitRevert(address who, Duel.DuelResult memory r, bytes memory err)
        internal
    {
        bytes memory sig = _sign(r);
        vm.prank(who);
        vm.expectRevert(err);
        duelC.submitDuel(r, sig);
    }

    function _expectSubmitRevertValue(
        address who,
        Duel.DuelResult memory r,
        uint256 value,
        bytes memory err
    ) internal {
        bytes memory sig = _sign(r);
        vm.prank(who);
        vm.expectRevert(err);
        duelC.submitDuel{value: value}(r, sig);
    }

    /// @dev A whole no-stakes fight, start to finish.
    function _fight(uint256 tokenA, uint256 tokenB, uint32 winnerId) internal {
        _submit(_newResult(tokenA, tokenB, winnerId));
    }

    /**
     * @dev Drive `loser` into the graveyard by losing `lossesToDie` fights in
     *      a row to `winner`. Real signed duels all the way down — the death
     *      stamp the Graveyard's priority window reads only exists because a
     *      real `applyDuelResult` wrote it.
     */
    function _killBull(uint256 loser, uint256 winner) internal {
        uint8 n = duelC.lossesToDie();
        for (uint8 i = 0; i < n; i++) {
            _fight(loser, winner, uint32(winner));
        }
        assertTrue(bulls.isDead(loser), "harness: the bull did not die");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Money helpers
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev A fight that actually STAKES something, on both sides, in BNBULL.
     *
     *      ⚠ Use this for anything asserting on jackpot TICKETS. Since
     *      `DECISIONS.md §25` a ticket is earned by funding the pot, so
     *      `_newResult`'s zero-stake default — fine for streaks, deaths and
     *      settlement — opens no ticket at all and an assertion on
     *      `ticketCount()` will read zero for a reason that has nothing to do
     *      with what the test is checking.
     *
     *      BNBULL rather than BNB on purpose: a WBNB stake would need the
     *      wrap/allowance dance on both sides, and BNBULL is the leg whose
     *      never-sell rule (`§14`) most of these tests care about anyway.
     */
    function _newStakedResult(uint256 tokenA, uint256 tokenB, uint32 winnerId, uint256 stake)
        internal
        returns (Duel.DuelResult memory r)
    {
        _fundForFight(bulls.ownerOf(tokenA), stake, 0);
        _fundForFight(bulls.ownerOf(tokenB), stake, 0);
        r = _newResult(tokenA, tokenB, winnerId);
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = stake;
        r.stakeB = stake;
    }

    /// @dev `_fight`, but staked, so the pots actually get a ticket.
    function _stakedFight(uint256 tokenA, uint256 tokenB, uint32 winnerId) internal {
        _submit(_newStakedResult(tokenA, tokenB, winnerId, STAKE_BNBULL));
    }

    /// @dev The same, against an arbitrary stack from `_stack`. Registers
    ///      BNBULL on that Duel if it is not registered yet, funds and approves
    ///      both owners against THAT Duel, and stakes both sides.
    function _stakeOn(Duel d, Bulls b, Duel.DuelResult memory r, uint256 stake) internal {
        if (d.maxFightCostOf(address(bnbull)) == 0) {
            d.addFightAsset(address(bnbull), MAX_COST_BNBULL, DEV_BPS);
        }
        address oa = b.ownerOf(r.tokenA);
        address ob = b.ownerOf(r.tokenB);
        bnbull.mint(oa, stake);
        bnbull.mint(ob, stake);
        vm.prank(oa);
        bnbull.approve(address(d), type(uint256).max);
        vm.prank(ob);
        bnbull.approve(address(d), type(uint256).max);
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = stake;
        r.stakeB = stake;
    }

    function _fundForFight(address who, uint256 bnbullAmt, uint256 wbnbAmt) internal {
        if (bnbullAmt > 0) {
            bnbull.mint(who, bnbullAmt);
            vm.prank(who);
            bnbull.approve(address(duelC), type(uint256).max);
        }
        if (wbnbAmt > 0) {
            vm.deal(address(this), address(this).balance + wbnbAmt);
            wbnb.deposit{value: wbnbAmt}();
            wbnb.transfer(who, wbnbAmt);
            vm.prank(who);
            wbnb.approve(address(duelC), type(uint256).max);
        }
    }

    /// @dev Give `who` every revive currency, approved to the Graveyard.
    function _fundForRevive(address who) internal {
        vm.deal(who, who.balance + 100 ether);
        bnbull.mint(who, 10_000_000e18);
        vm.prank(who);
        bnbull.approve(address(grave), type(uint256).max);
    }

    /// @dev BNB owed for a dollar rung at the harness price, matching
    ///      `Graveyard._collect`'s ceil-division exactly.
    function _bnbDue(uint256 usd1e18) internal pure returns (uint256) {
        return _ceilDiv(usd1e18 * 1e18, BNB_USD_1E18);
    }

    /// @dev BNBULL owed for a dollar rung: the keeper's full sticker, then the
    ///      10% BNBULL discount applied EXACTLY ONCE.
    function _bnbullDue(uint256 usd1e18) internal pure returns (uint256) {
        uint256 full = _ceilDiv(usd1e18 * BNBULL_PER_USD, 1e18);
        return (full * 9_000) / 10_000;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Re-wiring helpers (every wiring slot is timelocked after bootstrap)
    // ══════════════════════════════════════════════════════════════════════

    function _repointGraveyardWire(Graveyard.Wire slot, address target) internal {
        grave.proposeWire(slot, target);
        vm.warp(block.timestamp + grave.wiringDelay() + 1);
        grave.commitWire(slot);
        _refreshPrices();
    }

    function _repointDuelWire(Duel.Wire slot, address target) internal {
        duelC.proposeWire(slot, target);
        vm.warp(block.timestamp + duelC.wiringDelay() + 1);
        duelC.commitWire(slot);
        _refreshPrices();
    }

    /**
     * @dev Republish the BNB/USD round and the BNBULL peg at the current
     *      timestamp.
     *
     *      ⚠ Call this after ANY `vm.warp` past `maxOracleAge` (1 hour) or
     *      `maxBnbullPegAge` (6 hours) — a 24-hour wiring timelock or a
     *      takeover window sails past both. Staleness is a deliberate subject
     *      of its own tests; it must never sneak into a test about something
     *      else and turn a real assertion into an `OracleStale`.
     */
    function _refreshPrices() internal {
        feed.setAnswer(BNB_USD_8);
        grave.setBnbullPerUsd(BNBULL_PER_USD);
    }

    /**
     * @dev Swap a different Graveyard into the live stack. Needed because a
     *      wiring slot is bootstrap-ONCE and `propose` refuses a zero target,
     *      so "the MintDrop slot was never wired" is only reachable on a fresh
     *      Graveyard — and a fresh Graveyard can revive nothing until Bulls
     *      and the Duel both point at it.
     */
    function _installGraveyard(Graveyard g) internal {
        bulls.proposeWire(Bulls.Wire.Graveyard, address(g));
        duelC.proposeWire(Duel.Wire.Graveyard, address(g));
        vm.warp(block.timestamp + 24 hours + 1);
        bulls.commitWire(Bulls.Wire.Graveyard);
        duelC.commitWire(Duel.Wire.Graveyard);
        _refreshPrices();
        g.setBnbullPerUsd(BNBULL_PER_USD);
    }
}
