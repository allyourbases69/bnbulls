// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Duel} from "../contracts/Duel.sol";
import {Marketplace} from "../contracts/Marketplace.sol";
import {MarketplaceHarness} from "./Marketplace.t.sol";
import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {PermissiveYards} from "./mocks/DuelMocks.sol";

/**
 * @title ReviewAudit
 * @notice SEVENTH-PASS REVIEW OF THE SIX FIXES. Not part of the shipping
 *         suite — these are reproducers for what the 904 do not cover.
 */
contract ReviewAuditTicketFloor is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    // ─────────────────────────────────────────────────────────────────────
    // ⚠ THE ORIGINAL FINDING HERE WAS ARITHMETICALLY WRONG, AND THE WAY IT
    //   WENT WRONG IS THE REASON THIS BLOCK IS NOW WRITTEN AS AN INVARIANT.
    //
    //   It paired the MAINNET floor (25_000e18) with the LOCAL cost (200e18)
    //   and concluded "the floor is 125x the stake". That pair exists on no
    //   chain. `_mainnetReqUint(name, localDefault)` hard-requires the env var
    //   when `block.chainid == 56`, so the local default is dead code there,
    //   and there are exactly two consistent pairs:
    //
    //       local / testnet : cost     200e18  floor     20e18   (10%)
    //       mainnet (env)   : cost 250_000e18  floor 25_000e18   (10%)
    //
    //   `deploy-fresh.ps1:67,98` pins both halves of the mainnet pair. The
    //   shipped floor was exactly the tenth it claimed to be.
    //
    //   Reading a config constant without its chain is how BOTH the original
    //   bug and this false positive happened, so these tests no longer name a
    //   shipped number at all. They assert the RELATION, which is true on both
    //   pairs and is what actually catches a mismatched deploy:
    //
    //       minTicketStakeOf(asset) < fighterCost(asset)
    //
    //   `script/Verify.s.sol` now asserts the same relation at deploy time.
    // ─────────────────────────────────────────────────────────────────────

    /// @dev A consistent pair, whichever chain it came from: floor = 10% of
    ///      cost. The actual magnitudes are irrelevant to what is under test.
    uint256 internal constant COST = 200e18;
    uint256 internal constant FLOOR_OK = COST / 10;
    /// @dev A MISMATCHED pair — a floor above the stake. This is a deliberately
    ///      broken configuration, NOT a shipped one, and it is what a deploy
    ///      that pinned one half of the pair and let the other fall through to
    ///      the repo `.env` would actually produce.
    uint256 internal constant FLOOR_BROKEN = COST * 125;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
    }

    /**
     * @notice ⛔ WHEN THE INVARIANT IS VIOLATED, TICKETING DIES IN SILENCE.
     *
     * @dev The failure mode is what makes a mismatched floor dangerous, not the
     *      size of any particular number. `_rollOnePool` RETURNS on a sub-floor
     *      stake rather than reverting: no revert, no event, no alert. The
     *      fight settles perfectly, the player sees nothing wrong, and the pot
     *      keeps filling from mints, revives and marketplace fees while never
     *      issuing another ticket for that asset.
     *
     *      Nothing here reads a shipped constant. It sets a floor above the
     *      stake ON PURPOSE and shows what that costs.
     */
    function test_AUDIT_aFloorAboveTheStakeKillsTicketingSilently() public {
        duelC.setMinTicketStake(address(bnbull), FLOOR_BROKEN);

        uint256 stake = (COST * 9_000) / 10_000; // 10% BNBULL discount
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _stakeOn(duelC, bulls, r, stake);
        _submit(r);

        assertEq(potBnbull.ticketCount(), 0, "an ordinary fight earns NO ticket");
        assertEq(potBnb.ticketCount(), 0, "and none on the other pool either");
        assertEq(duelC.fightSeq(alice), 1, "the fight settled perfectly - nothing reverted");
    }

    /**
     * @notice And it poisons MIXED duels: both legs are floored independently,
     *         so one mismatched asset vetoes the ticket on BOTH pools even when
     *         the other side is comfortably above its own floor.
     */
    function test_AUDIT_aBrokenFloorOnOneAssetVetoesMixedDuels() public {
        duelC.setMinTicketStake(address(wbnb), 3e14);
        duelC.setMinTicketStake(address(bnbull), FLOOR_BROKEN);

        uint256 bnbullStake = (COST * 9_000) / 10_000;
        _fundForFight(alice, 0, 1 ether);
        bnbull.mint(bob, bnbullStake);
        vm.prank(bob);
        bnbull.approve(address(duelC), type(uint256).max);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.stakeA = 0.01 ether; // ~33x the WBNB floor
        r.assetB = address(bnbull);
        r.stakeB = bnbullStake;
        _submit(r);

        assertEq(potBnb.ticketCount(), 0, "the mismatched leg vetoes the other pool's ticket too");
        assertEq(potBnbull.ticketCount(), 0);
    }

    /// @dev The control: a floor that RESPECTS the invariant tickets the same
    ///      fight, and still refuses dust by nineteen orders of magnitude.
    function test_AUDIT_control_aConsistentFloorTicketsTheSameFight() public {
        duelC.setMinTicketStake(address(bnbull), FLOOR_OK);
        assertLt(FLOOR_OK, duelC.fighterCost(address(bnbull)), "the invariant holds");

        uint256 stake = (COST * 9_000) / 10_000;
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _stakeOn(duelC, bulls, r, stake);
        _submit(r);

        assertEq(potBnbull.ticketCount(), 1, "a correctly sized floor still tickets");

        // ...and the hole the floor exists to close is still shut: a 1-wei
        // stake pays a dev cut of `1 * 1000 / 10000 == 0`, a rake-free ticket
        // against a pot that pays 100%.
        assertGt(FLOOR_OK, 10, "still far above the fee-truncation window");
    }

    /**
     * @notice ⚠ WHY `!= 0` AND `== config` WERE NEVER ENOUGH. A floor above the
     *         stake satisfies both and still kills ticketing, so the preflight
     *         would have signed off green. `Verify.s.sol` now asserts the
     *         relation instead, and this is the test that fails if anyone
     *         weakens it back.
     */
    function test_AUDIT_theOldVerifyAssertionsCannotSeeAMismatchedFloor() public {
        duelC.setMinTicketStake(address(bnbull), FLOOR_BROKEN);

        // The two things Verify.s.sol used to check, verbatim. Both pass.
        assertTrue(duelC.minTicketStakeOf(address(bnbull)) != 0, "old check 1 passes");
        assertEq(duelC.minTicketStakeOf(address(bnbull)), FLOOR_BROKEN, "old check 2 passes");

        // The relation it checks NOW. This is the one that catches it.
        assertGe(
            duelC.minTicketStakeOf(address(bnbull)),
            duelC.fighterCost(address(bnbull)),
            "the invariant is violated, and only the relational check sees it"
        );
    }
}

/**
 * @notice The buy-side ceiling, measured against the numbers the FRONTEND
 *         actually passes rather than numbers the test picked.
 *
 * @dev ✅ CLOSED. Both tests below were REPROS and are now REGRESSIONS: the
 *      setups, the numbers and the names are unchanged, and only the outcome
 *      has flipped. Deliberately left in the reviewer's file rather than
 *      folded into `Marketplace.t.sol` — the finding and its proof-of-closure
 *      belong in the same place, and the next reviewer should be able to see
 *      the exact attack that was reported and watch it bounce.
 *
 *      What changed: the ceiling moved OFF the total and ONTO the seller's own
 *      sticker. `buyerPays` cannot distinguish oracle drift (legitimate, and
 *      the whole reason the frontend sends a cushion) from a re-price (theft),
 *      so any ceiling loose enough for the first admitted the second — which is
 *      precisely what these two tests caught. `maxUsdPrice` is checked against
 *      `l.usdPrice` upstream of the oracle, so drift roams inside the cushion
 *      while a re-price is refused at any size. `maxPay` stays as the bound on
 *      the total, which is the ONLY bound on `Fixed`-mode BNBULL.
 */
contract ReviewAuditMaxPay is MarketplaceHarness {
    /// @dev `frontend/src/lib/constants.ts:10` — `BNB_QUOTE_CUSHION_BPS`.
    uint256 internal constant CUSHION_BPS = 150;

    function _withCushion(uint256 due) internal pure returns (uint256) {
        return due + (due * CUSHION_BPS) / 10_000;
    }

    /**
     * @notice WAS: the BNB leg's ceiling is the cushion, so it bounds nothing.
     *         NOW: the same front-run is refused, and nothing moves.
     *
     * @dev The reported defect. `ListingCard.tsx` sent
     *      `value = withCushion(due)` AND `maxPay = withCushion(due)` — the
     *      SAME number — so a seller re-pricing to exactly the cushioned figure
     *      landed on `buyerPays == maxPay`, cleared the `>` check, and settled.
     *      The identical attack the fix's own docstring described, succeeding at
     *      the identical amount as before the fix, because pre-fix the ceiling
     *      was `msg.value` and post-fix it was `maxPay` and the frontend set
     *      them equal.
     *
     *      Everything below is byte-for-byte the reported repro except the last
     *      four lines. `maxPay` is still exactly what the frontend passes; the
     *      third argument is the new one, and it is the sticker THIS SCREEN
     *      SHOWED, uncushioned.
     */
    function test_AUDIT_sellerStillPocketsTheWholeCushionAtTheFrontendsMaxPay() public {
        _list(alice, 1, LIST_USD);
        uint256 due = _bnbGross(LIST_USD);
        uint256 sent = _withCushion(due);
        uint256 maxPay = sent; // EXACTLY what ListingCard.tsx passes.
        uint256 maxUsdPrice = LIST_USD; // ...and the sticker it showed.

        // Alice front-runs, re-pricing to swallow exactly the cushion.
        uint128 repriced = uint128(LIST_USD + (LIST_USD * CUSHION_BPS) / 10_000);
        vm.prank(alice);
        market.updatePrice(1, repriced, Marketplace.BnbullMode.Off, 0);

        uint256 sellerBefore = alice.balance;
        vm.deal(bob, sent);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.ListingRepriced.selector, uint256(repriced), maxUsdPrice
            )
        );
        market.buyWithBNB{value: sent}(1, maxUsdPrice, maxPay);

        assertEq(bulls.ownerOf(1), alice, "FIXED: the sale was refused, the bull never moved");
        assertEq(bob.balance, sent, "FIXED: the cushion was not consumed, refund is moot");
        assertEq(alice.balance, sellerBefore, "FIXED: the seller banked nothing");
    }

    /**
     * @notice WAS: the BNBULL leg is bounded to the cushion, not to zero.
     *         NOW: bounded to zero — the re-price is refused outright.
     *
     * @dev The BNBULL leg was genuinely improved by the first fix (the old
     *      ceiling was an often-infinite approval, the new one was the cushion)
     *      but 1.5% of every sale was still extractable, for the same reason as
     *      the BNB leg. The sticker bound takes it to nothing.
     */
    function test_AUDIT_bnbullLegIsBoundedToTheCushionNotToZero() public {
        _listPegged(alice, 1, LIST_USD);
        uint256 due = 8_000e18; // $80 / $0.01
        uint256 maxPay = _withCushion(due);
        uint256 maxUsdPrice = LIST_USD;

        bnbull.mint(bob, due * 100);
        vm.prank(bob);
        bnbull.approve(address(market), type(uint256).max);

        // Re-price by exactly the cushion rather than 10x.
        uint128 repriced = uint128(LIST_USD + (LIST_USD * CUSHION_BPS) / 10_000);
        vm.prank(alice);
        market.updatePrice(1, repriced, Marketplace.BnbullMode.Pegged, 0);

        uint256 before = bnbull.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Marketplace.ListingRepriced.selector, uint256(repriced), maxUsdPrice
            )
        );
        market.buyWithBNBULL(1, maxUsdPrice, maxPay);

        assertEq(bulls.ownerOf(1), alice, "FIXED: the sale was refused");
        assertEq(bnbull.balanceOf(bob), before, "FIXED: not one token left the approval");
    }

    /// @dev The other half of the claim, and the reason the sticker is the
    ///      bound rather than a tighter `maxPay`: the cushion still does its
    ///      real job. Nobody cheats, the oracle drifts inside the cushion, and
    ///      the sale settles at the frontend's own arguments.
    function test_AUDIT_theHonestCushionedBuyStillSettles() public {
        _list(alice, 1, LIST_USD);
        uint256 due = _bnbGross(LIST_USD);
        uint256 sent = _withCushion(due);

        uint256 drifted = (BNB_USD_1E18 * 99) / 100; // BNB down 1%.
        feed.setAnswer(int256(drifted / 1e10));
        uint256 dueNow = _ceilDiv(uint256(LIST_USD) * 1e18, drifted);

        vm.deal(bob, sent);
        vm.prank(bob);
        market.buyWithBNB{value: sent}(1, LIST_USD, sent);

        assertEq(bulls.ownerOf(1), bob, "the honest path is untouched");
        assertEq(bob.balance, sent - dueNow, "and the surplus still comes back");
    }
}

/**
 * @notice Fix #3, the submitter exemption, measured at the MAINNET ceilings
 *         rather than at the harness's.
 *
 * @dev `.env`: `FIGHT_MAX_COST_WBNB = 1e18` (permanent, one-shot) and
 *      `FIGHT_COST_USD = 2e18`. At the harness's $600/BNB a fighter is quoted
 *      ~0.00333 BNB, so `maxFightCostOf[wbnb]` is **300 fights' worth**.
 */
contract ReviewAuditSubmitterExemption is BnbullsBase {
    DuelNative internal duelN;

    uint256 internal constant SIGNER_PK = 0xB011_51_6E;
    uint16 internal constant DEV_BPS = 1_000;

    /// @dev `.env:71` — the one-shot, permanent WBNB ceiling.
    uint256 internal constant MAINNET_MAX_COST_WBNB = 1e18;
    /// @dev `.env:74` — the dollar anchor, $2 a fighter.
    uint256 internal constant MAINNET_USD_FIGHT_PRICE = 2e18;

    uint256 internal _nonceSeq;

    function setUp() public virtual override {
        super.setUp();
        duelN = new DuelNative(
            DuelNative.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                trustedSigner: vm.addr(SIGNER_PK),
                devTreasury: address(0xDE7),
                defaultDevShareBps: DEV_BPS
            })
        );
        duelN.addFightAsset(address(wbnb), MAINNET_MAX_COST_WBNB, DEV_BPS);
        duelN.setUsdFightPrice(MAINNET_USD_FIGHT_PRICE);
        bulls.bootstrapWire(Bulls.Wire.Duel, address(duelN));
        duelN.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));
        duelN.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    /**
     * @notice ⛔ THE AWAY BUDGET IS THE ONLY CUMULATIVE BOUND, AND THE
     *         SUBMITTER EXEMPTION REMOVES IT FOR THE WALLET DOING THE CLICKING.
     *
     * @dev A compromised signer cannot touch a wallet that is not signing —
     *      fix #2 holds, and `test_REVIEW_signerDrainsDepositorCredit` proves
     *      it. But the moment the victim clicks "fight" in the UI they ARE the
     *      sender, and the signed stake for their own side is bounded by
     *      nothing but `maxFightCostOf[wbnb]` = 1 BNB.
     *
     *      The player attaches the HONEST quote as `msg.value`. It is short of
     *      the signed stake, so `_takeSide` falls through to `_debitBnb` for
     *      the FULL amount and refunds the `msg.value` untouched. The wallet
     *      balance therefore does not move at all — the loss is entirely
     *      inside the fight balance, where nothing surfaces it until the player
     *      goes looking.
     *
     *      300x per click, and the away budget the player set is bypassed by
     *      construction.
     */
    function test_AUDIT_submitterExemptionCosts300xTheQuotePerClick() public {
        uint256 aBull = bulls.mint(alice);
        uint256 bBull = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 20 ether}();
        // Alice is careful. She caps her away exposure at two fights' worth.
        uint256 quote = duelN.fighterCost(address(wbnb));
        vm.prank(alice);
        duelN.setPassiveAllowance(quote * 2);

        assertApproxEqAbs(quote, 0.00333 ether, 0.0001 ether, "$2 at $600/BNB");
        assertEq(
            MAINNET_MAX_COST_WBNB / quote, 299, "the permanent ceiling is ~300 fights' worth"
        );

        // The signer is compromised. Alice's UI still quotes her $2.
        // ✅ FIXED: the FIRST click is refused now, not the fifth.
        uint256 walletBefore = alice.balance;
        DuelNative.DuelResult memory r = _result(aBull, bBull, uint32(bBull));
        r.assetA = address(wbnb);
        r.stakeA = MAINNET_MAX_COST_WBNB; // the ceiling, not the quote
        r.assetB = address(0);
        r.stakeB = 0;
        bytes memory sig = _sign(r);

        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector,
                alice,
                MAINNET_MAX_COST_WBNB,
                quote * 2
            )
        );
        vm.prank(alice); // SHE clicks. She is the submitter.
        duelN.submitDuel{value: quote}(r, sig); // pays the HONEST quote

        assertEq(
            duelN.passiveAllowance(alice), quote * 2, "FIXED: her away budget is intact"
        );
        assertEq(duelN.bnbCredit(alice), 20 ether, "FIXED: the ledger never paid the ceiling");
        assertEq(alice.balance, walletBefore, "FIXED: and the wallet is untouched");
    }

    /**
     * @notice THE POSITIVE CONTROL, so the pair proves both directions. The
     *         exemption was never wrong to exist — it is what lets you fight
     *         with money you attached yourself. What it must not do is reach
     *         PAST the attached value into a budget you set for being away.
     *
     * @dev Away budget of exactly ZERO, and the fight still settles, because
     *      `msg.value` covers the whole stake. If this ever fails alongside the
     *      test above, the fix has been over-tightened into a ban.
     */
    function test_AUDIT_control_valueThatCoversTheStakeNeverTouchesTheBudget() public {
        uint256 aBull = bulls.mint(alice);
        uint256 bBull = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 20 ether}();
        uint256 quote = duelN.fighterCost(address(wbnb));
        vm.prank(alice);
        duelN.setPassiveAllowance(0); // no away budget at all

        DuelNative.DuelResult memory r = _result(aBull, bBull, uint32(bBull));
        r.assetA = address(wbnb);
        r.stakeA = quote; // the honest quote, and she attaches all of it
        r.assetB = address(0);
        r.stakeB = 0;

        // ⚠ Signed BEFORE the prank. `_sign` reads `hashDuelResult` off the
        // contract, so signing inside the argument list spends the prank on the
        // getter and `submitDuel` runs as the test contract — which owns
        // neither bull, and reports `NotOwnerOfEither()` rather than anything
        // to do with what is under test.
        bytes memory sig = _sign(r);
        vm.prank(alice);
        duelN.submitDuel{value: quote}(r, sig);

        assertEq(duelN.fightSeq(alice), 1, "a self-funded fight settles");
        assertEq(duelN.passiveAllowance(alice), 0, "and never touches the away budget");
    }

    /**
     * @notice The `msg.value`-short branch is what makes it invisible: the
     *         honest payment is refunded IN FULL and the whole stake is taken
     *         from the ledger instead.
     */
    function test_AUDIT_theHonestMsgValueIsRefundedAndTheLedgerPaysEverything() public {
        uint256 aBull = bulls.mint(alice);
        uint256 bBull = bulls.mint(bob);
        vm.prank(alice);
        duelN.deposit{value: 5 ether}();

        uint256 quote = duelN.fighterCost(address(wbnb));
        DuelNative.DuelResult memory r = _result(aBull, bBull, uint32(bBull));
        r.assetA = address(wbnb);
        r.stakeA = 1 ether;
        r.assetB = address(0);
        r.stakeB = 0;

        uint256 walletBefore = alice.balance;
        bytes memory sig = _sign(r);
        // ✅ FIXED. The exemption is now the ATTACHED VALUE, not the submitter:
        // `msg.value` of `quote` does not cover a 1 BNB stake, so the uncovered
        // remainder goes through the away budget — which is zero, and refuses.
        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector, alice, 1 ether, 0
            )
        );
        vm.prank(alice);
        duelN.submitDuel{value: quote}(r, sig);

        assertEq(alice.balance, walletBefore, "FIXED: nothing left the wallet");
        assertEq(duelN.bnbCredit(alice), 5 ether, "FIXED: the ledger paid nothing");
    }

    function _result(uint256 tokenA, uint256 tokenB, uint32 winnerId)
        internal
        returns (DuelNative.DuelResult memory r)
    {
        address oa = bulls.ownerOf(tokenA);
        address ob = bulls.ownerOf(tokenB);
        _nonceSeq += 1;
        r = DuelNative.DuelResult({
            tokenA: tokenA,
            tokenB: tokenB,
            winnerId: winnerId,
            rounds: 7,
            seed: uint256(keccak256(abi.encodePacked("audit", _nonceSeq))),
            newEloA: 1_050,
            newEloB: 950,
            assetA: address(0),
            assetB: address(0),
            stakeA: 0,
            stakeB: 0,
            seqA: duelN.nextFightSeq(oa),
            seqB: duelN.nextFightSeq(ob),
            nonce: _nonceSeq,
            expiry: block.timestamp + 1 hours
        });
    }

    function _sign(DuelNative.DuelResult memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, duelN.hashDuelResult(r));
        return abi.encodePacked(rs, ss, v);
    }
}
