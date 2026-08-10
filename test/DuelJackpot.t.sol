// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Duel} from "../contracts/Duel.sol";
import {
    DuelGuzzlerJackpot, DuelRecordingJackpot, DuelRevertingJackpot
} from "./mocks/DuelMocks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title DuelJackpotTest
 * @notice PRIORITY 5. A pot fault must never stop a fight — and both pools
 *         must get a ticket carrying the SAME `duelKey`.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      Two separate guarantees live in `_rollJackpot`, and they pull in
 *      opposite directions, which is why they are tested together.
 *
 *      **Never block a fight.** "A pot fault — a paused token, a pool that has
 *      not whitelisted us, an outright bug — must never stop a fight from
 *      settling. A failed roll costs a ticket, never the duel." Every pot call
 *      is wrapped in try/catch, and the hostile modes below are a reverting
 *      pool, an unwired pool, and one that eats its entire gas allowance
 *      before giving up.
 *
 *      **Never pay twice.** `DECISIONS.md §13`: every decisive duel opens a
 *      ticket on BOTH pools at their own true odds, carrying the same
 *      `duelKey`; whichever ticket rolls a win FIRST claims exclusivity, so
 *      one fight never pays both pots. The choice of which pot pays is
 *      deliberately NOT computable at submit time — on fefers it was a coin
 *      flip over values readable inside the submitting transaction, so a
 *      wrapper contract could revert and retry until it got the pot it wanted.
 */
contract DuelJackpotTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Both pools, one key
    // ══════════════════════════════════════════════════════════════════════

    function test_bothPoolsGetATicketCarryingTheSameDuelKey() public {
        DuelRecordingJackpot potA = new DuelRecordingJackpot();
        DuelRecordingJackpot potB = new DuelRecordingJackpot();
        (Bulls b, Duel d) = _stack(address(potA), address(potB));

        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);

        Duel.DuelResult memory r = _newResultOn(d, b, t1, t2, uint32(t1));
        _stakeOn(d, b, r, STAKE_BNBULL); // §25: no stake, no ticket
        _submitOn(d, b, r);

        assertEq(potA.count(), 1, "the BNBULL pool got no ticket");
        assertEq(potB.count(), 1, "the WBNB pool got no ticket");

        uint256 key = d.duelJackpotKey(r.nonce);
        assertEq(potA.keyAt(0), key);
        assertEq(potB.keyAt(0), key, "the two pools disagree about which fight this was");
        assertTrue(key != 0, "a zero key reads as -no exclusivity- on a pot");
    }

    /// @dev Derived rather than the raw nonce so it can never be zero, and
    ///      bound to `address(this)` so two Duel deployments sharing a pool
    ///      cannot collide.
    function test_theDuelKeyIsBoundToTheDeployment() public {
        Duel other = _newDuel(address(bulls));
        assertTrue(
            duelC.duelJackpotKey(7) != other.duelJackpotKey(7),
            "two Duels sharing a pool would collide on keys"
        );
        assertTrue(duelC.duelJackpotKey(0) != 0, "nonce zero must not produce key zero");
    }

    function test_bothRealPoolsOpenATicketForTheWinner() public {
        _stakedFight(aliceBull, bobBull, uint32(aliceBull)); // §25: no stake, no ticket

        assertEq(potBnbull.ticketCount(), 1);
        assertEq(potBnb.ticketCount(), 1);

        (address winner,, uint256 tokenId,, uint256 keyA) = potBnbull.tickets(0);
        assertEq(winner, alice);
        assertEq(tokenId, aliceBull);
        (,,,, uint256 keyB) = potBnb.tickets(0);
        assertEq(keyA, keyB);
    }

    function test_aTieOpensNoTicketAtAll() public {
        _submit(_newResult(aliceBull, bobBull, 0));
        assertEq(potBnbull.ticketCount(), 0);
        assertEq(potBnb.ticketCount(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  A pot fault never blocks a fight
    // ══════════════════════════════════════════════════════════════════════

    function test_aRevertingPotLeavesTheFightSettled() public {
        DuelRevertingJackpot bad = new DuelRevertingJackpot();
        DuelRecordingJackpot good = new DuelRecordingJackpot();
        (Bulls b, Duel d) = _stack(address(bad), address(good));

        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);

        Duel.DuelResult memory r = _newResultOn(d, b, t1, t2, uint32(t1));
        _stakeOn(d, b, r, STAKE_BNBULL); // §25: no stake, no ticket
        bytes memory sig = _signOn(d, r);

        vm.expectEmit(true, false, false, false, address(d));
        emit Duel.JackpotRollFailed(t1);
        vm.prank(alice);
        d.submitDuel(r, sig);

        assertEq(d.fightSeq(alice), 1, "the fight did not settle");
        assertEq(b.getBull(t1).wins, 1, "the win was not recorded");
        assertEq(good.count(), 1, "the healthy pool still got its ticket");
    }

    function test_bothPotsRevertingStillLeavesTheFightSettled() public {
        DuelRevertingJackpot bad1 = new DuelRevertingJackpot();
        DuelRevertingJackpot bad2 = new DuelRevertingJackpot();
        (Bulls b, Duel d) = _stack(address(bad1), address(bad2));

        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);
        _submitOn(d, b, _newResultOn(d, b, t1, t2, uint32(t1)));

        assertEq(d.fightSeq(alice), 1);
        assertEq(b.getBull(t2).losses, 1);
    }

    /// @dev The pre-check short-circuits an unwired slot without a try/catch,
    ///      so a pre-launch fight settles just the same.
    function test_anUnwiredPotLeavesTheFightSettled() public {
        DuelRecordingJackpot only = new DuelRecordingJackpot();
        (Bulls b, Duel d) = _stack(address(only), address(0));

        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);
        Duel.DuelResult memory r = _newResultOn(d, b, t1, t2, uint32(t1));
        _stakeOn(d, b, r, STAKE_BNBULL); // §25: no stake, no ticket
        _submitOn(d, b, r);

        assertEq(d.fightSeq(alice), 1);
        assertEq(only.count(), 1);

        (, address wiredBnbull, address wiredBnb,) = d.wires();
        assertEq(wiredBnbull, address(only));
        assertEq(wiredBnb, address(0), "the second pool was never wired");
    }

    function test_neitherPotWiredAtAllLeavesTheFightSettled() public {
        (Bulls b, Duel d) = _stack(address(0), address(0));
        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);
        _submitOn(d, b, _newResultOn(d, b, t1, t2, uint32(t1)));
        assertEq(d.fightSeq(alice), 1);
    }

    /**
     * @notice A pot that eats its whole gas allowance still cannot stop a
     *         fight.
     *
     * @dev EIP-150 forwards 63/64 of the remaining gas to a sub-call, so the
     *      1/64 left behind has to be enough to finish `submitDuel`. It is,
     *      because the roll is the LAST substantive thing the duel does — the
     *      stakes, the streaks, the NFT write and the payouts are all already
     *      behind it. This test is really about that ordering.
     */
    function test_aPotThatBurnsItsWholeGasAllowanceLeavesTheFightSettled() public {
        DuelGuzzlerJackpot guzzler = new DuelGuzzlerJackpot();
        DuelRecordingJackpot good = new DuelRecordingJackpot();
        (Bulls b, Duel d) = _stack(address(guzzler), address(good));

        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);
        Duel.DuelResult memory r = _newResultOn(d, b, t1, t2, uint32(t1));
        _stakeOn(d, b, r, STAKE_BNBULL); // §25: no stake, no ticket
        _submitOn(d, b, r);

        assertEq(d.fightSeq(alice), 1, "a gas-hungry pot blocked the fight");
        assertEq(b.getBull(t1).wins, 1);
        assertEq(good.count(), 1, "the healthy pool still got its ticket");
    }

    /// @dev The queue nudge is swallowed too. `resolve` is best-effort: any
    ///      duel traffic pays for draining earlier winners' tickets, and a
    ///      failure there is not the submitting player's problem.
    function test_aRevertingResolveNudgeIsSwallowed() public {
        DuelRevertingJackpot bad = new DuelRevertingJackpot();
        (Bulls b, Duel d) = _stack(address(bad), address(bad));

        uint256 t1 = _mintBullOn(b, alice);
        uint256 t2 = _mintBullOn(b, bob);
        // A TIE opens no ticket, so `resolve` is the only pot call made.
        _submitOn(d, b, _newResultOn(d, b, t1, t2, 0));
        assertEq(d.fightSeq(alice), 1);
    }

    function test_theResolveBudgetIsBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Duel.ResolveCountOutOfRange.selector, uint8(26)));
        duelC.setJackpotResolvePerDuel(26);

        duelC.setJackpotResolvePerDuel(25);
        assertEq(duelC.jackpotResolvePerDuel(), 25);
        duelC.setJackpotResolvePerDuel(0);
        assertEq(duelC.jackpotResolvePerDuel(), 0, "zero disables the nudge");
        _submit(_newResult(aliceBull, bobBull, uint32(aliceBull)));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The one-pot-per-fight lock
    // ══════════════════════════════════════════════════════════════════════

    function test_onlyAWiredPoolCanClaimAndOnlyOnce() public {
        uint256 key = duelC.duelJackpotKey(1234);

        vm.prank(address(potBnbull));
        assertTrue(duelC.claimJackpotForDuel(key), "the first wired pool must win the key");
        assertTrue(duelC.duelJackpotPaid(key));

        vm.prank(address(potBnb));
        assertFalse(duelC.claimJackpotForDuel(key), "one fight paid both pots");
    }

    /**
     * @notice A stranger gets `false`, not a revert.
     *
     * @dev "a stranger must not be able to pre-claim keys and quietly switch
     *      every payout off." A revert would be safe; returning false without
     *      writing is what keeps the key available for the real pool.
     */
    function test_aStrangerGetsFalseAndCannotPreClaimAKey() public {
        uint256 key = duelC.duelJackpotKey(1234);

        vm.prank(alice);
        assertFalse(duelC.claimJackpotForDuel(key));
        assertFalse(duelC.duelJackpotPaid(key), "a stranger burned a key");

        vm.prank(address(potBnb));
        assertTrue(duelC.claimJackpotForDuel(key), "the real pool lost its claim");
    }

    function test_keyZeroIsNeverClaimable() public {
        vm.prank(address(potBnbull));
        assertFalse(duelC.claimJackpotForDuel(0));
        assertFalse(duelC.duelJackpotPaid(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The dev-cut slice into the pots
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A WBNB dev cut is ALREADY the WBNB pot's prize token, so it goes
    ///      straight in — no router, no swap, no slippage.
    function test_aWbnbDevCutSliceGoesStraightIntoTheWbnbPot() public {
        _fundForFight(bob, 0, 1 ether);
        vm.deal(alice, 5 ether);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = 0.01 ether;
        r.stakeB = 0.01 ether;

        uint256 cutPerSide = (uint256(0.01 ether) * DEV_BPS) / 10_000;
        uint256 slicePerSide = (cutPerSide * 3_000) / 10_000;

        vm.expectEmit(true, false, false, true, address(duelC));
        emit Duel.PotSliceFunded(address(wbnb), slicePerSide);
        _submitValue(alice, r, 1 ether);

        assertEq(potBnb.pool(), slicePerSide * 2, "the pot slice never landed");
        assertEq(router.swapCalls(), 0, "a WBNB dev cut must never touch a DEX");
        assertEq(
            wbnb.balanceOf(duelTreasury), (cutPerSide - slicePerSide) * 2, "dev's share of the cut"
        );
    }

    /// @dev `DECISIONS.md §14`: a BNBULL slice is already the BNBULL pot's
    ///      prize token. NOTHING IS EVER SOLD.
    function test_aBnbullDevCutSliceGoesStraightIntoTheBnbullPotAndSellsNothing() public {
        _fundForFight(alice, 100_000e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = 1_000e18;

        _submitAs(alice, r);

        uint256 cut = (uint256(1_000e18) * DEV_BPS) / 10_000;
        uint256 slice = (cut * 3_000) / 10_000;
        assertEq(potBnbull.pool(), slice);
        assertEq(router.swapCalls(), 0, "BNBULL was sold");
    }

    /**
     * @notice A pot that refuses our funding does not block the fight — the
     *         slice simply stays with dev, and says so on chain.
     */
    function test_aBrokenPotSliceStaysWithDevRatherThanBlockingTheFight() public {
        potBnb.setFunder(address(duelC), false);
        _fundForFight(bob, 0, 1 ether);
        vm.deal(alice, 5 ether);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.stakeA = 0.01 ether;

        uint256 cut = (uint256(0.01 ether) * DEV_BPS) / 10_000;
        uint256 slice = (cut * 3_000) / 10_000;

        vm.expectEmit(true, false, false, true, address(duelC));
        emit Duel.PotSliceFailed(address(wbnb), slice);
        _submitValue(alice, r, 1 ether);

        assertEq(potBnb.pool(), 0);
        assertEq(wbnb.balanceOf(duelTreasury), cut, "the whole cut should fall back to dev");
        assertEq(duelC.fightSeq(alice), 1, "the fight did not settle");
    }

    /**
     * @notice `code.length` is load-bearing, not belt-and-braces.
     *
     * @dev A call to an EOA SUCCEEDS with empty returndata, and `Jackpot.fund`
     *      returns nothing to choke on — so without the check a mis-wired slot
     *      pointing at a wallet would report a funded pot, the slice would be
     *      deducted from dev, and the tokens would sit stranded in the Duel
     *      with nothing having happened.
     *
     *      ⚠ REWRITTEN, NOT DELETED, for `DECISIONS.md §26`. It used to point
     *      the MintDrop slot at an EOA and stake the stablecoin, because a
     *      stablecoin cut was the one that routed through MintDrop. That route
     *      is gone — every remaining asset IS a pot's prize token — so the same
     *      `code.length` guard is exercised through a mis-wired POT slot
     *      instead. The subject is unchanged: a wallet in a money slot must
     *      refuse the leg, not silently swallow it.
     */
    function test_aMisWiredSlotPointingAtAWalletRefusesTheLegOutright() public {
        _repointDuelWire(Duel.Wire.JackpotBnbull, address(0xEEEE)); // an EOA
        _fundForFight(alice, 1_000e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = 100e18;
        _submitAs(alice, r);

        uint256 cut = (uint256(100e18) * DEV_BPS) / 10_000;
        assertEq(bnbull.balanceOf(duelTreasury), cut, "the whole cut must go where it is visible");
        assertEq(bnbull.balanceOf(address(duelC)), 0, "tokens stranded in the Duel");
    }

    /// @notice An asset that is neither BNBULL nor WBNB has NO pot leg at all
    ///         since `DECISIONS.md §26`, and the whole dev cut stays visibly
    ///         with dev rather than being routed somewhere that cannot use it.
    function test_anUnknownStakeAssetKeepsItsWholeDevCutWithDev() public {
        MockERC20 odd = new MockERC20("Odd", "ODD", 18);
        duelC.addFightAsset(address(odd), 1_000e18, DEV_BPS);
        odd.mint(alice, 1_000e18);
        vm.prank(alice);
        odd.approve(address(duelC), type(uint256).max);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(odd);
        r.stakeA = 100e18;

        uint256 cut = (uint256(100e18) * DEV_BPS) / 10_000;
        // No `PotSliceFunded`, no `PotSliceFailed` — the leg was never ready,
        // so nothing was ever attempted.
        _submitAs(alice, r);

        assertEq(odd.balanceOf(duelTreasury), cut, "the whole cut goes to dev");
        assertEq(odd.balanceOf(address(duelC)), 0, "nothing stranded in the Duel");
        assertEq(potBnbull.pool(), 0);
        assertEq(potBnb.pool(), 0);
    }

    /// @dev And if it somehow reached the inline worker anyway, that worker
    ///      refuses it by name rather than doing something surprising.
    function test_theInlinePotLegRefusesAnUnknownAsset() public {
        MockERC20 odd = new MockERC20("Odd", "ODD", 18);
        vm.prank(address(duelC));
        vm.expectRevert(abi.encodeWithSelector(Duel.UnsupportedAsset.selector, address(odd)));
        duelC.routePotSliceInline(address(odd), 1e18);
    }

    /// @dev The inline worker is `external` ONLY so the contract can try/catch
    ///      its own call. It is not a door into this contract's balance.
    function test_theInlinePotLegIsUnreachableFromOutside() public {
        vm.prank(alice);
        vm.expectRevert(Duel.NotSelf.selector);
        duelC.routePotSliceInline(address(bnbull), 1e18);

        vm.expectRevert(Duel.NotSelf.selector);
        duelC.routePotSliceInline(address(bnbull), 1e18);
    }

    function test_thePotShareIsBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Duel.InvalidShare.selector, uint256(10_001)));
        duelC.setPotShareBps(10_001);
        duelC.setPotShareBps(10_000);
        assertEq(duelC.potShareBps(), 10_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  🔴 FINDING
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice 🔴 FINDING — A DUEL WITH ZERO STAKES STILL MINTS A FULL-ODDS
     *         TICKET ON BOTH POOLS. Nothing on chain requires a fight to have
     *         cost anybody anything before it buys a claim on the pots.
     *
     * @dev THE SHAPE, and it is `DECISIONS.md §18`'s lesson in a new costume.
     *      §18 asks the right audit question — "can the owner cause the money
     *      to leave to a chosen address?" — and closed the direct answer by
     *      timelocking the VRF coordinator, so a chosen random word is no
     *      longer deliverable. This is the STATISTICAL answer to the same
     *      question, and it needs no VRF at all:
     *
     *        1. `setTrustedSigner` is a PLAIN, un-timelocked owner setter (by
     *           design — a leaked key must be rotatable in one transaction).
     *           So the owner can become the signer in one transaction, with no
     *           ETA published and nothing for holders to react to.
     *        2. `assetA`/`assetB` of `address(0)` with zero stakes is legal,
     *           and `_distributePot` returns early, so NO money moves and NO
     *           dev cut is taken — the fight contributes nothing to the pots.
     *        3. Two bulls in two DIFFERENT wallets is not a self-duel, so
     *           `allowSelfDuel` never has to be touched — the §16 protection
     *           does not apply.
     *        4. `_rollJackpot` opens a ticket on BOTH pools at their true odds
     *           for every decisive duel, with no stake floor of any kind.
     *        5. Alternating the winner keeps both bulls' loss streaks at zero
     *           forever, so nothing ever dies and the loop never ends.
     *
     *      Net: for the price of two mints and some gas, whoever holds the
     *      signing key mints unlimited 1-in-50 and 1-in-100 tickets on a pool
     *      that everybody else funded. With enough free tickets, draining the
     *      pot is not a gamble, it is a schedule.
     *
     *      WHAT DOES NOT FIX IT: more entropy in the roll (§18 already
     *      establishes that), or timelocking the signer (that would be worse —
     *      it is the leaked-key valve).
     *
     *      ✅ FIXED 2026-08-06 (`DECISIONS.md §25`). `_rollOnePool` now refuses
     *      a zero stake on either side, unconditionally — a ticket is EARNED by
     *      funding the pot. `minTicketStakeOf` can tighten it per asset, but the
     *      zero check needs no configuration on purpose: an unset mapping is
     *      zero, and a forgotten wiring tx must fail SAFE.
     *
     *      Nothing legitimate is lost. A free promotional fight still settles,
     *      still records the win, still moves the loss streaks — it just does
     *      not buy a lottery ticket funded by other players.
     *
     *      THIS TEST NOW ASSERTS THE FIX. It runs the exact original attack —
     *      rogue signer, twelve free fights, two wallets — and proves not one
     *      ticket is minted.
     */
    function test_FINDING_zeroStakeDuelsMintFreeFullOddsJackpotTickets() public {
        // The pools hold real money that other players' mints and fights put
        // there. This is what the free tickets are claims on.
        bnbull.mint(address(this), 1_000_000e18);
        bnbull.approve(address(potBnbull), type(uint256).max);
        potBnbull.topUp(1_000_000e18);
        assertGt(potBnbull.pool(), 0);

        // ONE transaction, no timelock, no published ETA.
        duelC.setTrustedSigner(rogueSigner);

        uint256 poolBefore = potBnbull.pool();
        uint256 aliceBnbBefore = alice.balance;

        for (uint256 i = 0; i < 12; i++) {
            // Two different wallets, so `allowSelfDuel` is never involved.
            bool aWins = i % 2 == 0;
            Duel.DuelResult memory r =
                _newResult(aliceBull, bobBull, uint32(aWins ? aliceBull : bobBull));
            bytes memory sig = _signWith(duelC, ROGUE_PK, r);
            vm.prank(alice);
            duelC.submitDuel(r, sig);
        }

        // The attack still RUNS — the fights settle, and that is deliberate.
        // What it no longer does is mint a claim on other people's money.
        assertEq(potBnbull.ticketCount(), 0, "SS25: a zero stake must earn no BNBULL ticket");
        assertEq(potBnb.ticketCount(), 0, "SS25: a zero stake must earn no WBNB ticket");
        assertEq(potBnbull.pool(), poolBefore, "and it contributed nothing, which is the point");
        assertEq(alice.balance, aliceBnbBefore, "the fights still cost the wallet nothing but gas");
        assertEq(duelC.fightSeq(alice), 12, "the fights themselves still settled");
        assertTrue(bulls.isAlive(aliceBull) && bulls.isAlive(bobBull), "and nothing ever dies");
        assertFalse(duelC.allowSelfDuel(), "DECISIONS 16: the self-duel block was never involved");

        // And the same fight WITH a real stake does earn its ticket, so the
        // guard blocks the exploit rather than the game. Hand the key back to
        // the honest signer first — `_stakedFight` signs as the real one.
        duelC.setTrustedSigner(signer);
        _stakedFight(aliceBull, bobBull, uint32(aliceBull));
        assertEq(potBnbull.ticketCount(), 1, "a staked fight still earns its ticket");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /**
     * @dev A fresh Bulls + Duel pair with arbitrary pot wiring, so "unwired"
     *      is testable at all: wiring slots are bootstrap-once and `propose`
     *      refuses a zero target, so a pot can never be un-wired in place.
     */
    function _stack(address potA, address potB) internal returns (Bulls b, Duel d) {
        b = new Bulls(owner, SEED, bytes32(0));
        d = _newDuel(address(b));
        b.bootstrapWire(Bulls.Wire.Duel, address(d));
        if (potA != address(0)) d.bootstrapWire(Duel.Wire.JackpotBnbull, potA);
        if (potB != address(0)) d.bootstrapWire(Duel.Wire.JackpotBnb, potB);
    }

    /**
     * @notice §25's hole with the numbers filed off: ONE WEI buys a full-odds
     *         ticket, and the rake on it rounds to nothing.
     *
     * @dev `_rollOnePool` refuses a stake of exactly 0 — that is §25, and it is
     *      unconditional so a forgotten wiring tx fails SAFE. But the check
     *      immediately below it, `stakeA < minTicketStakeOf[assetA]`, is
     *      configuration, and NO DEPLOY, WIRE OR MIGRATION SCRIPT EVER CALLED
     *      `setMinTicketStake`. The mapping was reachable only through the
     *      admin UI, so it read ZERO on mainnet and nothing said so.
     *
     *      Zero means one wei clears it. And `devCut = stake * 1000 / 10000`
     *      truncates to 0 for any stake under 10 wei, so the ticket is not
     *      merely cheap — it is literally rake-free, against a pot that pays
     *      100% and was funded by other people's mints.
     *
     *      The floor is a DUST GUARD and nothing more. It does not price a
     *      ticket meaningfully and it is not the answer to the self-dealt duel
     *      farm (two wallets, one owner, the stake circulating so only the rake
     *      is a real cost) — that needs a product decision.
     */
    function test_FINDING_aOneWeiStakeMintsARakeFreeFullOddsTicket() public {
        _fundForFight(bob, 0, 1 ether);
        vm.deal(alice, 5 ether);

        // Unset, exactly as it shipped.
        assertEq(duelC.minTicketStakeOf(address(wbnb)), 0, "the floor ships unset");

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = 1 wei;
        r.stakeB = 1 wei;

        _submitValue(alice, r, 1 ether);

        // The attack, unmitigated: a ticket on BOTH pools for two wei total,
        // and the dev cut truncated away so the pot got nothing for it.
        assertEq(potBnb.ticketCount(), 1, "one wei bought a full-odds WBNB ticket");
        assertEq(potBnbull.ticketCount(), 1, "and a full-odds BNBULL one");
        assertEq((uint256(1) * DEV_BPS) / 10_000, 0, "the rake on it truncates to nothing");
    }

    /// @notice The floor `Wire.s.sol` now sets refuses that dust, and still
    ///         lets an ordinary fight earn its ticket.
    function test_theDustFloorRefusesAOneWeiStakeButNotARealOne() public {
        _fundForFight(bob, 0, 1 ether);
        vm.deal(alice, 5 ether);

        // What `Wire.s.sol` wires: ~10% of the live $2 stake.
        duelC.setMinTicketStake(address(wbnb), 3e14);
        duelC.setMinTicketStake(address(bnbull), 25_000e18);

        Duel.DuelResult memory dust = _newResult(aliceBull, bobBull, uint32(aliceBull));
        dust.assetA = address(wbnb);
        dust.assetB = address(wbnb);
        dust.stakeA = 1 wei;
        dust.stakeB = 1 wei;
        _submitValue(alice, dust, 1 ether);

        assertEq(potBnb.ticketCount(), 0, "dust must earn NO ticket");
        assertEq(potBnbull.ticketCount(), 0, "on either pool");
        assertTrue(bulls.isAlive(aliceBull), "but the fight itself still settled");
        assertEq(duelC.fightSeq(alice), 1, "and still consumed its sequence");

        // A real $2-sized stake is far above the floor and still earns one.
        Duel.DuelResult memory real = _newResult(aliceBull, bobBull, uint32(bobBull));
        real.assetA = address(wbnb);
        real.assetB = address(wbnb);
        real.stakeA = 0.00331 ether;
        real.stakeB = 0.00331 ether;
        _submitValue(alice, real, 1 ether);

        assertEq(potBnb.ticketCount(), 1, "an ordinary fight still earns its ticket");
    }

    /// @dev The floor must never be settable above what anyone can afford —
    ///      that would fill the pot and silently never issue a ticket again.
    function test_theFloorCannotBeSetAboveTheAssetCeiling() public {
        uint256 ceiling = duelC.maxFightCostOf(address(wbnb));
        assertGt(ceiling, 0, "WBNB is a registered stake asset");
        vm.expectRevert();
        duelC.setMinTicketStake(address(wbnb), ceiling + 1);
    }
}
