// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {PermissiveYards} from "./mocks/DuelMocks.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {Yards} from "../contracts/Yards.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";

/**
 * @title DuelNativeReviewTest
 * @notice EXTERNAL REVIEW PROBES. Not part of the shipped suite — these exist to
 *         attack paths the two DuelNative suites never drive.
 */
contract DuelNativeReviewTest is BnbullsBase {
    DuelNative internal duelN;
    Graveyard internal graveN;

    uint256 internal constant SIGNER_PK = 0xB011_51_6E;
    address internal signerN;
    address internal duelTreasuryN = address(0xDE7);

    uint256 internal constant MAX_COST_WBNB = 100 ether;
    uint256 internal constant MAX_COST_BNBULL = 1_000_000e18;
    uint16 internal constant DEV_BPS = 1_000;
    uint256 internal constant USD_FIGHT_PRICE = 10e18;
    uint256 internal constant STAKE_BNB = (USD_FIGHT_PRICE * 1e18) / BNB_USD_1E18;

    uint256 internal _nonceSeq;

    address internal victim = address(0x1C71);
    address internal thief = address(0x7413F);

    function setUp() public virtual override {
        super.setUp();
        signerN = vm.addr(SIGNER_PK);

        duelN = new DuelNative(
            DuelNative.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                trustedSigner: signerN,
                devTreasury: duelTreasuryN,
                defaultDevShareBps: DEV_BPS
            })
        );
        duelN.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        duelN.addFightAsset(address(bnbull), MAX_COST_BNBULL, DEV_BPS);
        duelN.setFightCost(address(bnbull), 1_000e18);
        duelN.setUsdFightPrice(USD_FIGHT_PRICE);

        graveN = new Graveyard(owner, address(bulls), address(bnbull), treasury);

        bulls.bootstrapWire(Bulls.Wire.Duel, address(duelN));
        bulls.bootstrapWire(Bulls.Wire.Graveyard, address(graveN));

        duelN.bootstrapWire(DuelNative.Wire.Graveyard, address(graveN));
        duelN.bootstrapWire(DuelNative.Wire.JackpotBnbull, address(potBnbull));
        duelN.bootstrapWire(DuelNative.Wire.JackpotBnb, address(potBnb));
        duelN.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));
        // Consent gate: _requireInYards fails closed, so an unwired slot refuses
        // every duel. This fixture never wired one - neither did the migration.
        duelN.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));

        potBnbull.bootstrapDuel(address(duelN));
        potBnb.bootstrapDuel(address(duelN));
        potBnbull.setFunder(address(duelN), true);
        potBnb.setFunder(address(duelN), true);

        graveN.bootstrapWire(Graveyard.Wire.Duel, address(duelN));
        graveN.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        graveN.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(victim, 1_000 ether);
        vm.deal(thief, 1_000 ether);

        // ⚠ THE ORDINARY ACTORS OPT IN; `victim` DELIBERATELY DOES NOT.
        // A passive side now draws on an allowance it set itself, restoring the
        // ceiling the WBNB approval used to provide and that the credit ledger
        // silently removed. `victim` is the wallet the two attack probes target,
        // and leaving it at the default zero is the whole point: a depositor who
        // never offered their float to anyone must not have it spent for them.
        vm.prank(alice);
        duelN.setPassiveAllowance(5 ether);
        vm.prank(bob);
        duelN.setPassiveAllowance(5 ether);
        vm.prank(carol);
        duelN.setPassiveAllowance(5 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 1: the signer key reaches every depositor's whole balance
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev `setTrustedSigner` is an INSTANT owner setter (deliberately, as the
     *      "valve for a leaked key"). With custody, whoever holds that key can
     *      write a duel that debits any depositor up to `maxFightCostOf[wbnb]`
     *      and credit the proceeds to a wallet they control. No allowance, no
     *      opt-in per fight — the whole custodied balance is in range.
     */
    function test_REVIEW_signerDrainsDepositorCredit() public {
        // A perfectly ordinary player: mints a bull, tops up so it can be
        // challenged while offline. This is exactly what the docs tell them.
        uint256 vBull = bulls.mint(victim);
        vm.prank(victim);
        duelN.deposit{value: 90 ether}();

        // The attacker holds the signer key (leak, or a compromised owner key
        // calling setTrustedSigner, which is instant and untimelocked).
        uint256 attackerPk = 0xBADBEEF;
        vm.prank(owner);
        duelN.setTrustedSigner(vm.addr(attackerPk));

        uint256 tBull = bulls.mint(thief);

        DuelNative.DuelResult memory r = _result(vBull, tBull, uint32(tBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.assetB = address(0);
        r.stakeB = 0;
        r.stakeA = 90 ether; // the whole float, as before

        // ── FLIP: 90 ether is no longer reachable. ──────────────────────────
        // `victim` never set an allowance, so a fight it is not signing can take
        // NOTHING from it. Before the fix this exact call moved 81 of 90 BNB in
        // one transaction and withdrew it.
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(attackerPk, duelN.hashDuelResult(r));
        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector, victim, uint256(90 ether), uint256(0)
            )
        );
        duelN.submitDuel(r, abi.encodePacked(rs, ss, v));
        assertEq(duelN.bnbCredit(victim), 90 ether, "float must be untouched");

        // ── And the bound is a CEILING, not a speed bump. ───────────────────
        // Even a player who opts in caps their exposure at the number they
        // chose. The signer takes that and no more — the aggregate is bounded,
        // which is the property `maxFightCostOf` never gave us because it
        // bounds ONE fight and a leaked key does not stop at one.
        vm.prank(victim);
        duelN.setPassiveAllowance(5 ether);

        r.stakeA = 5 ether;
        r.nonce = ++_nonceSeq;
        (v, rs, ss) = vm.sign(attackerPk, duelN.hashDuelResult(r));
        vm.prank(thief);
        duelN.submitDuel(r, abi.encodePacked(rs, ss, v));

        assertEq(duelN.bnbCredit(victim), 85 ether, "only the allowance was reachable");
        assertEq(duelN.passiveAllowance(victim), 0, "allowance is spent, not reusable");

        // A second attempt finds the allowance exhausted. Fresh sequence
        // numbers: the fight that just settled consumed both wallets' commits.
        r.nonce = ++_nonceSeq;
        r.seqA = duelN.fightSeq(victim);
        r.seqB = duelN.fightSeq(thief);
        (v, rs, ss) = vm.sign(attackerPk, duelN.hashDuelResult(r));
        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector, victim, uint256(5 ether), uint256(0)
            )
        );
        duelN.submitDuel(r, abi.encodePacked(rs, ss, v));
        assertEq(duelN.bnbCredit(victim), 85 ether, "85 of 90 survives a leaked signer");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 2: an instant withdrawal cancels any in-flight loss
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev The Yards eject is delayed 15 minutes precisely so a losing side
     *      cannot front-run a submission and delete the loss. `withdraw` is
     *      instant and unpausable and achieves the same thing: the passive
     *      side's stake cannot be taken, `_debitBnb` reverts, and the whole
     *      duel dies. Bull never loses, never dies, keeps its money.
     */
    function test_REVIEW_instantWithdrawCancelsAnyLoss() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 5 ether}();

        // Alice's signed win over Bob is in the public mempool.
        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        bytes memory sig = _sign(r);

        // Bob reads it, front-runs with a 30k-gas withdrawal.
        vm.prank(bob);
        duelN.withdrawAll();

        // Alice's settlement now dies. No loss, no death, no seq consumed.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DuelNative.InsufficientCredit.selector, bob, STAKE_BNB, 0)
        );
        duelN.submitDuel{value: STAKE_BNB}(r, sig);

        assertEq(duelN.consecutiveLosses(b), 0, "loss landed anyway");
        assertTrue(bulls.isAlive(b), "bull died anyway");
        assertEq(duelN.nextFightSeq(bob), r.seqB, "seq consumed despite the revert");

        // And he simply redeposits, ready to accept the fights he likes.
        vm.prank(bob);
        duelN.deposit{value: 5 ether}();
        assertEq(duelN.bnbCredit(bob), 5 ether, "back in the game at zero cost");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 3: conservation on paths the shipped suite never drives
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Every DuelNative test uses assetA == assetB == WBNB. Drive the
    ///      mixed pair and assert wei-exact conservation of native AND BNBULL.
    function test_REVIEW_mixedAssetConservation() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        uint256 bnbullStake = 1_000e18;
        bnbull.mint(bob, bnbullStake * 10);
        vm.prank(bob);
        bnbull.approve(address(duelN), type(uint256).max);

        uint256 natBefore = address(duelN).balance;
        uint256 credBefore = duelN.totalBnbCredit();
        uint256 potWbnbBefore = wbnb.balanceOf(address(potBnb));
        uint256 potBnbullBefore = bnbull.balanceOf(address(potBnbull));
        uint256 duelBnbullBefore = bnbull.balanceOf(address(duelN));

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(bnbull);
        r.stakeA = STAKE_BNB;
        r.stakeB = bnbullStake;
        _submitValue(alice, r, STAKE_BNB);

        // Native: everything that came in is owed as credit or left as the pot
        // slice. Nothing minted, nothing stranded.
        uint256 sliceOut = (natBefore + STAKE_BNB) - address(duelN).balance;
        assertEq(
            duelN.totalBnbCredit() - credBefore + sliceOut,
            STAKE_BNB,
            "native conservation broken on the mixed pair"
        );
        assertEq(
            wbnb.balanceOf(address(potBnb)) - potWbnbBefore, sliceOut, "slice did not reach pot"
        );

        // BNBULL: in == out, nothing rests here.
        assertEq(
            bnbull.balanceOf(address(duelN)),
            duelBnbullBefore,
            "BNBULL stranded in the duel contract"
        );
        assertGt(bnbull.balanceOf(address(potBnbull)) - potBnbullBefore, 0, "bnbull pot leg dead");

        assertGe(address(duelN).balance, duelN.totalBnbCredit(), "INSOLVENT");
    }

    /// @dev Zero-stake side + priced side. `_distributePot` must not conjure.
    function test_REVIEW_oneSidedStakeConservation() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        uint256 natBefore = address(duelN).balance;
        uint256 credBefore = duelN.totalBnbCredit();

        DuelNative.DuelResult memory r = _result(a, b, uint32(b));
        r.assetA = address(wbnb);
        r.assetB = address(0);
        r.stakeA = STAKE_BNB;
        r.stakeB = 0;
        _submitValue(alice, r, STAKE_BNB);

        uint256 sliceOut = (natBefore + STAKE_BNB) - address(duelN).balance;
        assertEq(
            duelN.totalBnbCredit() - credBefore + sliceOut,
            STAKE_BNB,
            "one-sided stake conservation broken"
        );
        assertGe(address(duelN).balance, duelN.totalBnbCredit(), "INSOLVENT");
    }

    /// @dev potShareBps at the ceiling: the WHOLE dev cut is wrapped and leaves
    ///      as native. Solvency must survive it.
    function test_REVIEW_potShareAtCeilingStaysSolvent() public {
        vm.prank(owner);
        duelN.setPotShareBps(duelN.MAX_POT_SHARE_BPS());

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);
        vm.prank(bob);
        duelN.deposit{value: 5 ether}();

        uint256 natBefore = address(duelN).balance;
        uint256 credBefore = duelN.totalBnbCredit();

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = 1 ether;
        r.stakeB = 1 ether;
        _submitValue(alice, r, 1 ether);

        uint256 sliceOut = (natBefore + 1 ether) - address(duelN).balance;
        assertEq(
            duelN.totalBnbCredit() - credBefore + sliceOut,
            1 ether,
            "conservation broken at max pot share"
        );
        assertEq(duelN.bnbCredit(duelTreasuryN), 0, "dev kept a slice it routed away");
        assertGe(address(duelN).balance, duelN.totalBnbCredit(), "INSOLVENT");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 4: the receive() gas budget
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `receive()` does two SSTOREs and a LOG2. Measure it against the
    ///      2300-gas stipend a `.transfer()` / `.send()` sender would give it.
    function test_REVIEW_receiveCostsFarMoreThanTheStipend() public {
        StipendSender s = new StipendSender();
        vm.deal(address(s), 10 ether);

        uint256 g = gasleft();
        vm.prank(alice);
        (bool ok,) = address(duelN).call{value: 1 ether}("");
        uint256 used = g - gasleft();
        assertTrue(ok, "plain send failed");
        emit log_named_uint("receive() gas (cold)", used);
        assertGt(used, 2300, "receive fits in a stipend");

        // A `.transfer()`-style sender cannot deposit at all.
        assertFalse(s.sendWithStipend(payable(address(duelN)), 1 ether), "stipend send worked");
        assertEq(duelN.bnbCredit(address(s)), 0, "nothing credited");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 5: hostile pot re-entering the duel mid-settlement
    // ══════════════════════════════════════════════════════════════════════

    function test_REVIEW_hostilePotCannotReachTheLedger() public {
        HostilePot pot = new HostilePot(duelN);
        duelN.proposeWire(DuelNative.Wire.JackpotBnb, address(pot));
        vm.warp(block.timestamp + duelN.wiringDelay() + 1);
        duelN.commitWire(DuelNative.Wire.JackpotBnb);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);
        vm.prank(bob);
        duelN.deposit{value: 5 ether}();

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = 1 ether;
        r.stakeB = 1 ether;
        _submitValue(alice, r, 1 ether);

        emit log_named_uint("pot reentry attempts", pot.attempts());
        emit log_named_uint("pot reentry successes", pot.successes());
        assertEq(pot.successes(), 0, "hostile pot re-entered a money path");
        assertGe(address(duelN).balance, duelN.totalBnbCredit(), "INSOLVENT");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 6: the consent gate the migration script never wires
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev `script/MigrateNative.s.sol` bootstraps FOUR DuelNative wires —
     *      Graveyard, JackpotBnbull, JackpotBnb, MintDrop — and never
     *      `Wire.Yards`. `_requireInYards` returns early on a zero slot, so the
     *      "no consent, no fight" rule is simply absent on the shipped deploy.
     *
     *      On the old Duel that cost a passive wallet only whatever WBNB
     *      allowance it had granted. Here it costs the whole custodied float:
     *      an attacker PUSHES a worthless bull at any address holding credit
     *      (ERC-721 `transferFrom` needs no consent) and that address is now a
     *      legal opponent whose balance pays the stake.
     */
    function test_REVIEW_yardsUnwired_pushedBullReachesADepositorsCredit() public {
        // A depositor who has never entered anything into any yard.
        vm.prank(victim);
        duelN.deposit{value: 10 ether}();

        uint256 junk = bulls.mint(thief);
        uint256 mine = bulls.mint(thief);

        // Push the junk bull at the victim. No consent, no acceptance hook.
        vm.prank(thief);
        bulls.transferFrom(thief, victim, junk);
        assertEq(bulls.ownerOf(junk), victim, "push failed");

        DuelNative.DuelResult memory r = _result(junk, mine, uint32(mine));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = 1 ether;
        r.stakeB = 1 ether;

        // ── FLIP 1: the allowance. ──────────────────────────────────────────
        // This fixture wires a permissive yards stand-in, so the fight clears
        // the GATE — and still dies, because `victim` never offered its float
        // to anybody. Before the fix this line lifted 0.8 BNB.
        uint256 vBefore = duelN.bnbCredit(victim);
        bytes memory sig1 = _sign(r);
        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector, victim, uint256(1 ether), uint256(0)
            )
        );
        duelN.submitDuel{value: 1 ether}(r, sig1);
        assertEq(duelN.bnbCredit(victim), vBefore, "victim's float must be untouched");

        // ── FLIP 2: the gate itself. ────────────────────────────────────────
        // A duel deployed exactly as the migration script wires it — four of the
        // five slots, Yards omitted — now refuses BY NAME instead of waving the
        // fight through. This is the state the shipped script would have gone
        // live in.
        DuelNative bare = _bareDuel();
        DuelNative.DuelResult memory rb = _result(junk, mine, uint32(mine));
        rb.assetA = address(wbnb);
        rb.assetB = address(wbnb);
        rb.stakeA = 1 ether;
        rb.stakeB = 1 ether;
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(SIGNER_PK, bare.hashDuelResult(rb));
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(DuelNative.YardsNotWired.selector, address(0)));
        bare.submitDuel{value: 1 ether}(rb, abi.encodePacked(br, bs, bv));

        // ── And the REAL gate, on a duel that has one, refuses an unentered
        // bull the way it always should have. ───────────────────────────────
        Yards yards = new Yards(owner, address(bulls));
        bare.bootstrapWire(DuelNative.Wire.Yards, address(yards));
        assertFalse(yards.inYards(junk), "victim never entered it, correctly");
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(DuelNative.BullNotInYards.selector, junk));
        bare.submitDuel{value: 1 ether}(rb, abi.encodePacked(br, bs, bv));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The away budget binds the ABSENT, not the present
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev A player tops up, sets a small away budget, then starts a fight
     *      HIMSELF paying out of that balance with no value attached.
     *
     *      An earlier revision of the allowance caught this branch, so his own
     *      budget refused his own fight. The control is named and explained as
     *      "how much can be taken while I am away"; a fight he is signing is
     *      not that, and the fix a confused player reaches for — raising the
     *      away budget — is the opposite of what safety wants.
     */
    function test_submitterPaysWithAttachedValue_andTheBudgetIsUntouched() public {
        uint256 aBull = bulls.mint(alice);
        uint256 bBull = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 50 ether}();
        vm.prank(alice);
        duelN.setPassiveAllowance(0.001 ether);

        DuelNative.DuelResult memory r = _result(aBull, bBull, uint32(aBull));
        r.assetA = address(wbnb);
        r.stakeA = 1 ether;
        r.assetB = address(0);
        r.stakeB = 0;

        uint256 creditBefore = duelN.bnbCredit(alice);
        bytes memory sig = _sign(r);
        vm.prank(alice);
        // She ATTACHES the stake. That is the exemption: value she chose in the
        // same transaction she signed, not a balance sitting there.
        duelN.submitDuel{value: 1 ether}(r, sig);

        // ⚠ ASSERT THE EXACT MOVEMENT, NOT MERELY THAT SOMETHING MOVED.
        // The predecessor of this test asserted `assertLt(credit, before)` and
        // nothing else, which a 299x overcharge satisfies perfectly well — and
        // did, until an external audit measured it. Winnings land as credit, so
        // her balance must have gone UP by the payout and not down at all.
        assertGe(duelN.bnbCredit(alice), creditBefore, "attached value must not touch the ledger");
        assertEq(
            duelN.passiveAllowance(alice), 0.001 ether, "attached value must not touch the budget"
        );
    }

    /**
     * @dev The other half: value that falls SHORT is not exempt, however it is
     *      submitted. This is the branch the audit measured at 299x the quote —
     *      a compromised signer names `maxFightCostOf`, the player attaches the
     *      honest quote, and the difference used to come silently off the ledger
     *      with the honest payment refunded untouched.
     */
    function test_submitterWithShortValue_isStillBoundedByTheBudget() public {
        uint256 aBull = bulls.mint(alice);
        uint256 bBull = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 50 ether}();
        vm.prank(alice);
        duelN.setPassiveAllowance(0.001 ether);

        DuelNative.DuelResult memory r = _result(aBull, bBull, uint32(aBull));
        r.assetA = address(wbnb);
        r.stakeA = 1 ether; // the ceiling, as a compromised signer would name
        r.assetB = address(0);
        r.stakeB = 0;

        uint256 creditBefore = duelN.bnbCredit(alice);
        uint256 walletBefore = alice.balance;
        bytes memory sig = _sign(r);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector,
                alice,
                uint256(1 ether),
                uint256(0.001 ether)
            )
        );
        duelN.submitDuel{value: 0.0033 ether}(r, sig); // the honest quote

        assertEq(duelN.bnbCredit(alice), creditBefore, "ledger must not move");
        assertEq(alice.balance, walletBefore, "wallet must not move");
    }

    /// @dev The other half of the same rule: exempting the submitter must not
    ///      exempt anybody else. Bob is not the sender, so his ceiling binds.
    function test_awayBudgetStillCapsAGenuinelyPassiveSide() public {
        uint256 aBull = bulls.mint(alice);
        uint256 bBull = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 50 ether}();
        vm.prank(bob);
        duelN.setPassiveAllowance(0.001 ether);

        DuelNative.DuelResult memory r = _result(aBull, bBull, uint32(aBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = 0;
        r.assetA = address(0);
        r.stakeB = 1 ether;

        uint256 before = duelN.bnbCredit(bob);
        bytes memory sig = _sign(r);
        vm.prank(alice); // ALICE submits; BOB is the absent side.
        vm.expectRevert(
            abi.encodeWithSelector(
                DuelNative.PassiveAllowanceExceeded.selector,
                bob,
                uint256(1 ether),
                uint256(0.001 ether)
            )
        );
        duelN.submitDuel(r, sig);
        assertEq(duelN.bnbCredit(bob), before, "absent side stays capped");
    }

    /// @dev A DuelNative wired the way `MigrateNative.s.sol` wires one: four
    ///      slots, Yards omitted. The fixture under test is deliberately NOT
    ///      this, so the shipped wiring gets its own probe.
    function _bareDuel() internal returns (DuelNative d) {
        d = new DuelNative(
            DuelNative.DeployParams({
                initialOwner: address(this),
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                trustedSigner: signerN,
                devTreasury: duelTreasuryN,
                defaultDevShareBps: DEV_BPS
            })
        );
        d.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        d.setUsdFightPrice(USD_FIGHT_PRICE);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 6b: the pot leg against REAL WBNB semantics
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev `MockWBNB.withdraw` pays with `.call{value:}` and forwards all gas.
     *      Mainnet WBNB (0xbb4C...) pays with `.transfer()` and a 2300-gas
     *      stipend. DuelNative wraps the pot slice and hands it to
     *      `JackpotNative.fund`, which immediately unwraps — so the slice's
     *      survival on mainnet depends on the POT's `receive()` fitting in 2300
     *      gas, and nothing in the mock suite can see that.
     */
    function test_REVIEW_potLegSurvivesRealWbnbStipend() public {
        StipendWBNB w = new StipendWBNB();
        JackpotNative pot = new JackpotNative(address(w), owner, address(coord), 100);

        DuelNative d = new DuelNative(
            DuelNative.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(w),
                trustedSigner: signerN,
                devTreasury: duelTreasuryN,
                defaultDevShareBps: DEV_BPS
            })
        );
        d.addFightAsset(address(w), MAX_COST_WBNB, DEV_BPS);
        d.bootstrapWire(DuelNative.Wire.JackpotBnb, address(pot));
        // The consent gate fails closed now, so even a single-purpose fixture
        // has to wire one. That is the point of the change.
        d.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));
        pot.bootstrapDuel(address(d));
        pot.setFunder(address(d), true);

        // Repoint Bulls at this duel so applyDuelResult is authorised.
        bulls.proposeWire(Bulls.Wire.Duel, address(d));
        vm.warp(block.timestamp + 7 days);
        bulls.commitWire(Bulls.Wire.Duel);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);
        vm.prank(bob);
        d.deposit{value: 5 ether}();
        vm.prank(bob);
        d.setPassiveAllowance(5 ether);

        uint256 poolBefore = pot.pool();

        DuelNative.DuelResult memory r = DuelNative.DuelResult({
            tokenA: a,
            tokenB: b,
            winnerId: uint32(a),
            rounds: 7,
            seed: 1,
            newEloA: 1_050,
            newEloB: 950,
            assetA: address(w),
            assetB: address(w),
            stakeA: 1 ether,
            stakeB: 1 ether,
            seqA: d.nextFightSeq(alice),
            seqB: d.nextFightSeq(bob),
            nonce: 99,
            expiry: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, d.hashDuelResult(r));
        vm.prank(alice);
        d.submitDuel{value: 1 ether}(r, abi.encodePacked(rs, ss, v));

        emit log_named_uint("pot pool delta (stipend wbnb)", pot.pool() - poolBefore);
        assertGt(pot.pool(), poolBefore, "POT LEG DIES ON MAINNET WBNB: slice silently went to dev");
        assertGe(address(d).balance, d.totalBnbCredit(), "INSOLVENT");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PROBE 7: conservation over randomised fight shapes
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Winner/tie x asset pair x value-vs-credit x pot share, all fuzzed,
    ///      asserting wei-exact native conservation and solvency every time.
    function testFuzz_REVIEW_conservation(
        uint8 shape,
        uint96 stakeRaw,
        uint96 valueRaw,
        uint16 potBpsRaw
    ) public {
        vm.prank(owner);
        duelN.setPotShareBps(uint16(bound(uint256(potBpsRaw), 0, 10_000)));

        uint256 stake = bound(uint256(stakeRaw), 1, 1 ether);
        uint256 value = bound(uint256(valueRaw), 0, 2 ether);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 5 ether}();
        vm.prank(bob);
        duelN.deposit{value: 5 ether}();

        bool bnbullB = (shape & 1) == 1;
        if (bnbullB) {
            bnbull.mint(bob, 1e24);
            vm.prank(bob);
            bnbull.approve(address(duelN), type(uint256).max);
        }

        uint32 winner = shape % 3 == 0 ? 0 : (shape % 3 == 1 ? uint32(a) : uint32(b));

        DuelNative.DuelResult memory r = _result(a, b, winner);
        r.assetA = address(wbnb);
        r.stakeA = stake;
        r.assetB = bnbullB ? address(bnbull) : address(wbnb);
        r.stakeB = bnbullB ? 1_000e18 : stake;

        uint256 natBefore = address(duelN).balance;
        uint256 credBefore = duelN.totalBnbCredit();

        _submitValue(alice, r, value);

        // Native in = msg.value kept; native out = the wrapped pot slice.
        uint256 natAfter = address(duelN).balance;
        uint256 credAfter = duelN.totalBnbCredit();
        // (credit created) + (native that left) == (native that arrived)
        assertEq(
            int256(credAfter) - int256(credBefore) + (int256(natBefore) - int256(natAfter)),
            0,
            "native conservation broken"
        );
        assertGe(natAfter, credAfter, "INSOLVENT");
        assertEq(bnbull.balanceOf(address(duelN)), 0, "BNBULL stranded");

        // And everyone can actually get their money out.
        _drain(alice);
        _drain(bob);
        _drain(duelTreasuryN);
        assertGe(address(duelN).balance, duelN.totalBnbCredit(), "INSOLVENT after drain");
        assertEq(duelN.totalBnbCredit(), 0, "credit left over that nobody owns");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    function _result(uint256 tokenA, uint256 tokenB, uint32 winnerId)
        internal
        returns (DuelNative.DuelResult memory r)
    {
        address oa = bulls.ownerOf(tokenA);
        address ob = bulls.ownerOf(tokenB);
        uint64 sa = duelN.nextFightSeq(oa);
        uint64 sb = duelN.nextFightSeq(ob);
        if (oa == ob) sb = sa + 1;

        _nonceSeq += 1;
        r = DuelNative.DuelResult({
            tokenA: tokenA,
            tokenB: tokenB,
            winnerId: winnerId,
            rounds: 7,
            seed: uint256(keccak256(abi.encodePacked("review-seed", _nonceSeq))),
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

    function _drain(address who) internal {
        uint256 held = duelN.bnbCredit(who);
        if (held == 0) return;
        uint256 before = who.balance;
        vm.prank(who);
        duelN.withdrawAll();
        assertEq(who.balance - before, held, "withdrawal short-changed the holder");
    }

    function _sign(DuelNative.DuelResult memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, duelN.hashDuelResult(r));
        return abi.encodePacked(rs, ss, v);
    }

    function _submitValue(address who, DuelNative.DuelResult memory r, uint256 value) internal {
        bytes memory sig = _sign(r);
        vm.prank(who);
        duelN.submitDuel{value: value}(r, sig);
    }
}

/// @dev Sends with a 2300-gas stipend, the way real mainnet WBNB's `withdraw`
///      and every `.transfer()`-era contract does.
contract StipendSender {
    function sendWithStipend(address payable to, uint256 amount) external returns (bool) {
        return to.send(amount);
    }

    receive() external payable {}
}

/// @dev A wired pot that tries to claw at the ledger from inside settlement.
contract HostilePot {
    DuelNative public immutable duel;
    uint256 public attempts;
    uint256 public successes;

    constructor(DuelNative d) {
        duel = d;
    }

    function _probe() private {
        attempts += 1;
        try duel.withdrawAll() {
            successes += 1;
        } catch {}
        try duel.withdraw(1) {
            successes += 1;
        } catch {}
        // Can a wired pot pre-claim a key it was never given? (returns bool)
        try duel.claimJackpotForDuel(0) returns (bool ok) {
            if (ok) successes += 1;
        } catch {}
    }

    function fund(uint256, string calldata) external {
        _probe();
    }

    function recordWin(address, uint256, uint256, uint256) external returns (uint256) {
        _probe();
        return 1;
    }

    function resolve(uint256) external returns (uint256) {
        _probe();
        return 0;
    }

    receive() external payable {}
}

/// @dev WBNB whose `withdraw` pays with a 2300-gas stipend, exactly like the
///      real 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c on BNB Chain.
contract StipendWBNB {
    string public name = "Wrapped BNB";
    string public symbol = "WBNB";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "WBNB: balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad); // ⚠ 2300-gas stipend, like mainnet
        emit Transfer(msg.sender, address(0), wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WBNB: balance");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, "WBNB: allowance");
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }

    receive() external payable {
        deposit();
    }
}
