// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {PermissiveYards} from "./mocks/DuelMocks.sol";
import {Graveyard} from "../contracts/Graveyard.sol";

/**
 * @title DuelNativeAdversarialTest
 * @notice The safety gate before `DuelNative` custodies real money.
 *
 * @dev The build agent shipped 18 happy-and-unhappy-path tests and said what it
 *      had NOT done: no fuzz, no invariant campaign, no fork. This file is that
 *      campaign. It assumes the contract is hostile-adjacent and tries to break
 *      the one property everything else rests on:
 *
 *          address(this).balance >= totalBnbCredit
 *
 *      If that ever inverts, the last player to withdraw is paid with somebody
 *      else's stake. Every test here ends on it.
 *
 *      ⚠ The invariant campaign drives the ledger through a handler rather than
 *      the duel path. `submitDuel` needs a trusted-signer signature, which a
 *      fuzzer cannot forge and which `vm.sign` cannot reach from inside an
 *      invariant run — so the ledger primitives are fuzzed exhaustively here and
 *      the duel-driven solvency is covered by the bounded loop in
 *      `DuelNativeCredit.t.sol` plus the wei-exact fuzz cases below.
 */
contract DuelNativeAdversarialTest is BnbullsBase {
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

    CreditHandler internal handler;

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

        // Passive stakes now draw on an allowance the wallet sets, the way the
        // WBNB era drew on an ERC-20 approval. Bounded on purpose: a fixture that
        // grants type(uint256).max would re-open exactly the drain being fixed.
        vm.prank(alice);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(bob);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(carol);
        duelN.setPassiveAllowance(MAX_COST_WBNB);

        handler = new CreditHandler(duelN);
        vm.deal(address(handler), 100_000 ether);

        // Arm the handler with real fighters so the invariant campaign drives
        // `submitDuel` itself, not just the ledger primitives.
        uint256 fa = bulls.mint(address(handler)); // handler is the ACTIVE side
        uint256 fb = bulls.mint(bob);               // bob pays passively, from credit
        handler.armFights(bulls, SIGNER_PK, fa, fb, address(handler), bob);
        handler.addActor(duelTreasuryN); // the dev cut lands here as credit

        targetContract(address(handler));

        // ⚠⚠ WITHOUT THIS THE CAMPAIGN IS VACUOUS AND STILL REPORTS GREEN.
        // The fuzzer picks uniformly from every external selector on the target,
        // which includes this handler's own setup functions and everything
        // forge-std bolts on. The first run of this file spent its ONE call on
        // `armFights(...)` with fuzzed garbage — overwriting the fighter config
        // with token id 9.48e31 — after which no duel could ever settle. Pin the
        // fuzzer to the money-moving actions so the run exercises the ledger.
        bytes4[] memory sels = new bytes4[](6);
        sels[0] = CreditHandler.depositFor.selector;
        sels[1] = CreditHandler.depositSelf.selector;
        sels[2] = CreditHandler.plainSend.selector;
        sels[3] = CreditHandler.withdrawSome.selector;
        sels[4] = CreditHandler.withdrawEverything.selector;
        sels[5] = CreditHandler.fight.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function _assertSolvent() internal view {
        assertGe(
            address(duelN).balance,
            duelN.totalBnbCredit(),
            "INSOLVENT: contract balance below the credit it owes"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE SOLVENCY INVARIANT CAMPAIGN
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The whole ballgame. Under ANY sequence of deposits, depositFors,
    ///      withdraws, withdrawAlls, plain sends and force-feeds, the contract
    ///      must never owe more than it holds.
    function invariant_neverOwesMoreThanItHolds() public view {
        assertGe(
            address(duelN).balance,
            duelN.totalBnbCredit(),
            "INSOLVENT under fuzzed sequence"
        );
    }

    /// @dev `totalBnbCredit` must equal the sum of the individual balances. If
    ///      these drift, one of them is lying and both are used for money.
    function invariant_totalMatchesSumOfActors() public view {
        uint256 sum;
        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; i++) {
            sum += duelN.bnbCredit(actors[i]);
        }
        assertEq(duelN.totalBnbCredit(), sum, "total drifted from the sum of balances");
    }

    /// @dev No credit is ever conjured. The ledger can owe LESS than net money
    ///      in — the dev-cut pot slice legitimately leaves as WBNB — but it must
    ///      never owe MORE, which would mean credit created from nothing.
    function invariant_creditIsNeverConjured() public view {
        assertLe(
            duelN.totalBnbCredit(),
            handler.totalIn() - handler.totalOut(),
            "credit created from nothing"
        );
    }

    /// @dev Guards the campaign itself: a run where no fight ever settled would
    ///      pass every invariant above while proving nothing about the money
    ///      paths. Checked AFTER the run — as an invariant it would fire during
    ///      setup, before a single call had been made.
    function afterInvariant() public {
        // PERMANENT COVERAGE PRINT. A solvency invariant over a run where
        // nothing happened is trivially true; these numbers are the only thing
        // that distinguishes a real pass from a vacuous one. Never delete them.
        emit log_named_uint("deposits made      ", handler.deposits());
        emit log_named_uint("withdrawals made   ", handler.withdrawals());
        emit log_named_uint("duels settled      ", handler.fightsSettled());
        emit log_named_uint("duels rejected     ", handler.fightsRejected());
        emit log_named_uint("credit created wei ", handler.totalIn());
        emit log_named_uint("credit removed wei ", handler.totalOut());
        emit log_named_uint("final total credit ", duelN.totalBnbCredit());

        assertGt(handler.deposits(), 0, "no deposit ever happened: campaign vacuous");
        assertGt(handler.withdrawals(), 0, "no withdrawal ever happened: campaign vacuous");
        assertGt(handler.fightsSettled(), 0, "no duel ever settled: the campaign proved nothing");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. FUZZED MONEY PATHS — wei-exact
    // ══════════════════════════════════════════════════════════════════════

    /// @dev msg.value above / below / exactly the stake, with and without a
    ///      standing balance. Asserts every party to the wei.
    function testFuzz_valueVsCreditPrecedence(uint96 sentRaw, uint96 preRaw) public {
        uint256 sent = bound(uint256(sentRaw), 0, 5 ether);
        uint256 pre = bound(uint256(preRaw), 0, 5 ether);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        // Bob (passive) must always be able to cover his side.
        vm.prank(bob);
        duelN.deposit{value: 2 ether}();

        if (pre > 0) {
            vm.prank(alice);
            duelN.deposit{value: pre}();
        }

        uint256 aliceCreditBefore = duelN.bnbCredit(alice);
        uint256 aliceWalletBefore = alice.balance;

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        bool payable_ = sent >= STAKE_BNB || aliceCreditBefore >= STAKE_BNB;
        if (!payable_) {
            // Cannot cover her side from either source: must revert, not
            // half-charge.
            bytes memory sig = _sign(r);
            vm.prank(alice);
            vm.expectRevert();
            duelN.submitDuel{value: sent}(r, sig);
            _assertSolvent();
            return;
        }

        _submitValue(alice, r, sent);

        uint256 cut = (STAKE_BNB * DEV_BPS) / 10_000;
        uint256 share = STAKE_BNB - cut;

        if (sent >= STAKE_BNB) {
            // Paid from msg.value; the standing balance is untouched and only
            // the excess comes back.
            assertEq(
                duelN.bnbCredit(alice),
                aliceCreditBefore + share * 2,
                "value path: balance must be untouched but for winnings"
            );
            assertEq(
                alice.balance,
                aliceWalletBefore - sent + (sent - STAKE_BNB),
                "value path: refund is exactly the excess"
            );
        } else {
            // Fell through to the balance; the whole msg.value is refunded.
            assertEq(
                duelN.bnbCredit(alice),
                aliceCreditBefore - STAKE_BNB + share * 2,
                "credit path: stake off the balance"
            );
            assertEq(
                alice.balance, aliceWalletBefore - sent + sent, "credit path: full refund"
            );
        }
        _assertSolvent();
    }

    /// @dev The stake itself, across the whole legal range up to the ceiling.
    ///      In + out must balance to the wei for winner, dev and pot.
    function testFuzz_stakeAcrossTheRange(uint96 stakeRaw) public {
        uint256 stake = bound(uint256(stakeRaw), 1, MAX_COST_WBNB);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.deal(bob, 1_000 ether);
        vm.prank(bob);
        duelN.deposit{value: stake}();

        uint256 heldBefore = address(duelN).balance;

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = stake;
        r.stakeB = stake;
        _submitValue(alice, r, stake);

        uint256 cut = (stake * DEV_BPS) / 10_000;
        uint256 share = stake - cut;

        assertEq(duelN.bnbCredit(alice), share * 2, "winner takes both post-cut shares");
        assertEq(duelN.bnbCredit(bob), 0, "loser's balance is spent");

        // Everything that came in is either owed to somebody or left as WBNB in
        // the pot. Nothing vanished and nothing was minted.
        uint256 potSlice = heldBefore + stake - address(duelN).balance;
        assertEq(
            duelN.totalBnbCredit() + potSlice,
            heldBefore + stake,
            "conservation: credit + pot slice must equal everything held"
        );
        _assertSolvent();
    }

    /// @dev Dev bps at both extremes. 0 means the winner takes everything; the
    ///      maximum must still leave the arithmetic exact.
    function testFuzz_devBpsExtremes(bool zeroBps) public {
        uint16 bps = zeroBps ? 0 : duelN.MAX_DEV_BPS();
        vm.prank(owner);
        duelN.setDevShareBps(address(wbnb), bps);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        _submitValue(alice, r, STAKE_BNB);

        uint256 cut = (STAKE_BNB * bps) / 10_000;
        uint256 share = STAKE_BNB - cut;
        assertEq(duelN.bnbCredit(alice), share * 2, "winner share at bps extreme");
        _assertSolvent();
    }

    /// @dev A tie at a fuzzed stake: each side gets its own back less the cut,
    ///      never the other side's.
    function testFuzz_tieRefundsSymmetrically(uint96 stakeRaw) public {
        uint256 stake = bound(uint256(stakeRaw), 1, 10 ether);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: stake}();

        DuelNative.DuelResult memory r = _result(a, b, 0);
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = stake;
        r.stakeB = stake;
        _submitValue(alice, r, stake);

        uint256 share = stake - (stake * DEV_BPS) / 10_000;
        assertEq(duelN.bnbCredit(alice), share, "alice gets her own back");
        assertEq(duelN.bnbCredit(bob), share, "bob gets his own back");
        _assertSolvent();
    }

    /// @dev Deposit/withdraw round trip at any amount loses nothing.
    function testFuzz_depositWithdrawRoundTrip(uint96 amountRaw) public {
        uint256 amount = bound(uint256(amountRaw), 1, 500 ether);
        uint256 before = alice.balance;

        vm.prank(alice);
        duelN.deposit{value: amount}();
        assertEq(duelN.bnbCredit(alice), amount, "credited in full");

        vm.prank(alice);
        duelN.withdrawAll();

        assertEq(alice.balance, before, "round trip is lossless");
        assertEq(duelN.bnbCredit(alice), 0, "balance cleared");
        _assertSolvent();
    }

    /// @dev A stake over the per-asset ceiling must be refused outright.
    function testFuzz_ceilingIsEnforced(uint96 overRaw) public {
        uint256 over = bound(uint256(overRaw), MAX_COST_WBNB + 1, type(uint96).max);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = over;
        r.stakeB = 0;

        bytes memory sig = _sign(r);
        vm.deal(alice, over + 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DuelNative.FightCostTooHigh.selector, over));
        duelN.submitDuel{value: over}(r, sig);
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. ADVERSARIAL COUNTERPARTIES
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A winner whose `receive()` burns all the gas it is given. Crediting
    ///      is a storage write, so the duel must not care.
    function test_gasBurningWinner_cannotWedgeTheDuel() public {
        GasBurner burner = new GasBurner();
        vm.deal(address(burner), 10 ether);

        uint256 a = bulls.mint(address(burner));
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();
        burner.deposit(duelN, 1 ether);
        // The burner is the PASSIVE side here, so it opts in like any wallet.
        vm.prank(address(burner));
        duelN.setPassiveAllowance(MAX_COST_WBNB);

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        // Submitted by bob, so the burner is the PASSIVE side and the winner.
        _submitValue(bob, r, STAKE_BNB);

        uint256 share = STAKE_BNB - (STAKE_BNB * DEV_BPS) / 10_000;
        assertEq(duelN.bnbCredit(address(burner)), 1 ether - STAKE_BNB + share * 2, "credited");
        _assertSolvent();
    }

    /// @dev The cross-entry claim: `withdraw` and `submitDuel` share one
    ///      `nonReentrant` guard, so a hostile `receive()` fired from a refund
    ///      cannot re-enter `withdraw` to double-spend.
    function test_refundReentrancy_cannotReenterWithdraw() public {
        CrossReenterer bad = new CrossReenterer(duelN);
        vm.deal(address(bad), 100 ether);

        uint256 a = bulls.mint(address(bad));
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();
        bad.topUp(5 ether);

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        bytes memory sig = _sign(r);

        // Overpay so a refund fires, which is where the hostile receive() runs.
        bad.arm();
        bad.fight(r, sig, STAKE_BNB + 1 ether);

        // The re-entrant withdraw must have been rejected, leaving the ledger
        // consistent rather than drained.
        assertTrue(bad.reenterFailed(), "re-entrant withdraw was NOT blocked");
        _assertSolvent();
    }

    /// @dev Force-feeding native via selfdestruct inflates the balance. That is
    ///      harmless — it can only ever make the contract MORE solvent — and it
    ///      must not become anybody's credit.
    function test_forceFedNative_isHarmlessAndUnclaimable() public {
        vm.prank(alice);
        duelN.deposit{value: 1 ether}();

        uint256 totalBefore = duelN.totalBnbCredit();

        ForceFeeder feeder = new ForceFeeder{value: 7 ether}();
        feeder.boom(payable(address(duelN)));

        assertEq(duelN.totalBnbCredit(), totalBefore, "force-fed BNB must not become credit");
        assertGe(address(duelN).balance, 8 ether, "balance took the donation");
        _assertSolvent();

        // Nobody can withdraw it: alice is still limited to her own 1 ether.
        vm.prank(alice);
        vm.expectRevert();
        duelN.withdraw(2 ether);

        vm.prank(alice);
        duelN.withdrawAll();
        assertEq(duelN.bnbCredit(alice), 0, "alice took only her own");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE OWNER IS NOT TRUSTED WITH PLAYER MONEY
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `rescueToken` moves ERC-20s only. The player float is native, so
    ///      there must be no owner path to it. This is the safety argument the
    ///      build agent rewrote, asserted rather than trusted.
    function test_owner_cannotReachCreditedNativeByAnyPath() public {
        vm.prank(alice);
        duelN.deposit{value: 40 ether}();
        uint256 held = address(duelN).balance;

        // There is deliberately no native rescue. Prove the surface is absent.
        vm.prank(owner);
        (bool hit,) = address(duelN).call(
            abi.encodeWithSignature("rescueNative(address,uint256)", owner, 1 ether)
        );
        assertFalse(hit, "a native rescue exists: the float is reachable by the owner");

        vm.prank(owner);
        (bool hit2,) = address(duelN).call(
            abi.encodeWithSignature("sweep(address,uint256)", owner, 1 ether)
        );
        assertFalse(hit2, "a native sweep exists");

        // Rescuing WBNB cannot touch native either: there is no resting WBNB.
        vm.prank(owner);
        vm.expectRevert();
        duelN.rescueToken(address(wbnb), owner, 1 ether);

        assertEq(address(duelN).balance, held, "the float did not move");
        assertEq(duelN.bnbCredit(alice), 40 ether, "alice's balance is intact");
        _assertSolvent();
    }

    /// @dev A pause stops fights. It must never trap money already deposited.
    function test_pause_stopsFightsButNeverWithdrawals() public {
        vm.prank(alice);
        duelN.deposit{value: 5 ether}();

        vm.prank(owner);
        duelN.pause();

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);
        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        bytes memory sig = _sign(r);
        vm.prank(alice);
        vm.expectRevert();
        duelN.submitDuel(r, sig);

        // ...but the money comes out regardless.
        uint256 before = alice.balance;
        vm.prank(alice);
        duelN.withdrawAll();
        assertEq(alice.balance, before + 5 ether, "pause trapped player money");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. PRESERVED INVARIANTS — did the rewrite keep them?
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The contract checks its own typehash at construction. If the struct
    ///      drifted from the string, this would already have reverted — assert
    ///      the domain is the new deployment's, which is what separates
    ///      signatures between old and new Duel.
    function test_eip712_domainSeparatesFromTheOldDeployment() public view {
        (, string memory name, string memory version,, address verifying,,) =
            duelN.eip712Domain();
        assertEq(name, "BNBullsDuel", "domain name changed");
        assertEq(version, "1", "domain version changed");
        assertEq(verifying, address(duelN), "verifyingContract must be this deployment");
    }

    /// @dev A signature is bound to the deployment. One minted for the old Duel
    ///      must not settle here.
    function test_signatureFromAnotherContract_isRejected() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);
        DuelNative.DuelResult memory r = _result(a, b, uint32(a));

        // Sign the same struct under a different verifyingContract by signing a
        // deliberately wrong digest.
        (uint8 v, bytes32 rs, bytes32 ss) =
            vm.sign(SIGNER_PK, keccak256(abi.encodePacked("not-this-contract")));
        bytes memory badSig = abi.encodePacked(rs, ss, v);

        vm.prank(alice);
        vm.expectRevert();
        duelN.submitDuel(r, badSig);
        _assertSolvent();
    }

    /// @dev The per-wallet sequence still consumes exactly once, so a replayed
    ///      result cannot charge a balance twice.
    function test_fightSeq_blocksReplay() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        bytes memory sig = _sign(r);

        vm.prank(alice);
        duelN.submitDuel{value: STAKE_BNB}(r, sig);

        uint256 bobAfterOne = duelN.bnbCredit(bob);

        vm.prank(alice);
        vm.expectRevert();
        duelN.submitDuel{value: STAKE_BNB}(r, sig);

        assertEq(duelN.bnbCredit(bob), bobAfterOne, "replay charged the passive side twice");
        _assertSolvent();
    }


    /// @dev Diagnostic: run one handler fight directly so a rejection surfaces
    ///      its reason instead of being swallowed by the campaign's try/catch.
    function test_diag_handlerFightSettles() public {
        handler.fight(uint96(1 ether), uint96(0.01 ether), true);
        if (handler.fightsSettled() == 0) {
            emit log_named_bytes("fight rejected with", handler.lastFightError());
        }
        assertGt(handler.fightsSettled(), 0, "handler fight did not settle");
    }


    /// @dev ⚠ THE SILENT-WEDGE CHECK. `DuelNative` added `nonReentrant` to
    ///      `withdraw`/`withdrawAll` on top of `submitDuel`'s existing guard.
    ///      `submitDuel` reaches the pot TWICE in one transaction, through a
    ///      try/catch'd external SELF-call — so if a widened guard ever caught
    ///      that self-call, the pot leg would revert, be swallowed, and the
    ///      slice would silently stop reaching the jackpot while every test
    ///      still went green.
    ///
    ///      Asserting the slice is NON-ZERO is what makes that visible. A
    ///      conservation check alone cannot see it: zero is conserved too.
    function test_potSliceActuallyReachesTheJackpot_notSwallowed() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        uint256 potBefore = wbnb.balanceOf(address(potBnb));

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        _submitValue(alice, r, STAKE_BNB);

        uint256 delta = wbnb.balanceOf(address(potBnb)) - potBefore;

        uint256 cut = (STAKE_BNB * DEV_BPS) / 10_000;
        uint256 expected = ((cut * duelN.potShareBps()) / 10_000) * 2;

        assertGt(delta, 0, "POT LEG SWALLOWED: the slice never reached the jackpot");
        assertEq(delta, expected, "pot slice is not the expected share of the dev cut");
        _assertSolvent();
    }

    /// @dev The other half: the guard must still BLOCK a genuine re-entry. If
    ///      the two tests above and this one all pass, the guard is neither too
    ///      loose nor wedging the legitimate self-call.
    function test_guardStillBlocksGenuineReentry() public {
        CrossReenterer bad = new CrossReenterer(duelN);
        vm.deal(address(bad), 50 ether);
        bad.topUp(5 ether);

        bad.arm();
        // A plain withdraw whose receive() re-enters withdraw must be stopped.
        try bad.pullReentrant(1 ether) {
            assertTrue(bad.reenterFailed(), "re-entry was NOT blocked");
        } catch {
            // Outer revert is also an acceptable rejection.
        }
        _assertSolvent();
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
            seed: uint256(keccak256(abi.encodePacked("adv-seed", _nonceSeq))),
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

// ══════════════════════════════════════════════════════════════════════════
//  Handler + hostile counterparties
// ══════════════════════════════════════════════════════════════════════════

/// @dev Drives the ledger primitives for the invariant campaign and keeps its
///      own independent tally of money in and out. The contract's accounting is
///      checked against this rather than against itself.
contract CreditHandler {
    DuelNative public immutable duel;

    address[] private _actors;
    uint256 public totalIn;
    uint256 public totalOut;

    // Fight driving. Set by the test after it has minted the fighters.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Bulls private _bulls;
    uint256 private _pk;
    uint256 private _tokenA;
    uint256 private _tokenB;
    address private _ownerA;
    address private _ownerB;
    uint256 private _nonce;
    bool private _fightsArmed;

    /// @dev Count of fights that actually settled, so a run that silently never
    ///      fought cannot masquerade as coverage.
    uint256 public fightsSettled;
    uint256 public deposits;
    uint256 public withdrawals;

    function armFights(
        Bulls b,
        uint256 pk,
        uint256 tokenA,
        uint256 tokenB,
        address ownerA,
        address ownerB
    ) external {
        _bulls = b;
        _pk = pk;
        _tokenA = tokenA;
        _tokenB = tokenB;
        _ownerA = ownerA;
        _ownerB = ownerB;
        _fightsArmed = true;
        // The fighters earn credit too, so they must be inside the accounting
        // check or the sum will legitimately disagree with the total.
        addActor(ownerA);
        addActor(ownerB);
    }

    constructor(DuelNative d) {
        duel = d;
        _actors.push(address(uint160(0xA11CE)));
        _actors.push(address(uint160(0xB0B)));
        _actors.push(address(uint160(0xCAA01)));
        _actors.push(address(this));
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    /// @dev Any address that can end up holding credit must be tracked, or the
    ///      sum-vs-total check reports a drift that is really just a blind spot.
    function addActor(address a) public {
        for (uint256 i; i < _actors.length; i++) {
            if (_actors[i] == a) return; // deduped: double counting fakes a drift
        }
        _actors.push(a);
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @dev The workhorse: credits a tracked actor from the handler's own money.
    function depositFor(uint256 actorSeed, uint96 amountRaw) external {
        uint256 amount = uint256(amountRaw) % 100 ether;
        if (amount == 0) return;
        if (address(this).balance < amount) return;
        address a = _actor(actorSeed);
        duel.depositFor{value: amount}(a);
        totalIn += amount;
        deposits += 1;
    }

    function depositSelf(uint96 amountRaw) external {
        uint256 amount = uint256(amountRaw) % 100 ether;
        if (amount == 0) return;
        if (address(this).balance < amount) return;
        duel.deposit{value: amount}();
        totalIn += amount;
        deposits += 1;
    }

    /// @dev A plain send, which `receive()` treats as a deposit.
    function plainSend(uint96 amountRaw) external {
        uint256 amount = uint256(amountRaw) % 50 ether;
        if (amount == 0) return;
        if (address(this).balance < amount) return;
        (bool ok,) = address(duel).call{value: amount}("");
        if (ok) { totalIn += amount; deposits += 1; }
    }

    function withdrawSome(uint96 amountRaw) external {
        uint256 held = duel.bnbCredit(address(this));
        if (held == 0) return;
        uint256 amount = (uint256(amountRaw) % held) + 1;
        duel.withdraw(amount);
        totalOut += amount;
        withdrawals += 1;
    }

    function withdrawEverything() external {
        uint256 held = duel.bnbCredit(address(this));
        if (held == 0) return;
        duel.withdrawAll();
        totalOut += held;
        withdrawals += 1;
    }

    /// @dev THE POINT OF THE CAMPAIGN. Drives a real signed duel so the money
    ///      paths — stake collection off msg.value AND off the custodied
    ///      balance, the winner credit, the dev cut and the pot slice — are all
    ///      inside the invariant's blast radius, not just deposit/withdraw.
    ///
    ///      Both fighters are funded first so the fight is affordable; a fight
    ///      that reverts teaches the fuzzer nothing about solvency.
    function fight(uint96 valueRaw, uint96 stakeRaw, bool aWins) external {
        if (!_fightsArmed) return;

        uint256 stake = (uint256(stakeRaw) % 1 ether) + 1;
        uint256 value = uint256(valueRaw) % (2 ether);
        if (address(this).balance < value + 4 ether) return;

        // Make both sides solvent for this fight.
        duel.depositFor{value: stake}(_ownerA);
        duel.depositFor{value: stake}(_ownerB);
        totalIn += stake * 2;

        _nonce += 1;

        // ⚠ ALTERNATE THE WINNER, do not let the fuzzer pick freely. `lossesToDie`
        // is 5: a fuzzed run happily hands one bull five straight losses, it dies,
        // and EVERY subsequent fight reverts. Measured: fuzzed winners gave 5
        // settled / 66 rejected, i.e. the campaign stopped exercising the money
        // paths a twentieth of the way in. Alternating keeps both bulls alive so
        // the ledger is driven for the whole run. The win/lose/tie branches
        // themselves are covered wei-exactly by the fuzz tests above.
        bool aTakesIt = (_nonce % 2 == 0);
        aWins; // fuzzer input deliberately unused; see above

        DuelNative.DuelResult memory r = DuelNative.DuelResult({
            tokenA: _tokenA,
            tokenB: _tokenB,
            winnerId: aTakesIt ? uint32(_tokenA) : uint32(_tokenB),
            rounds: 5,
            seed: uint256(keccak256(abi.encodePacked("inv", _nonce))),
            newEloA: 1_010,
            newEloB: 990,
            assetA: address(duel.wbnb()),
            assetB: address(duel.wbnb()),
            stakeA: stake,
            stakeB: stake,
            seqA: duel.nextFightSeq(_ownerA),
            seqB: duel.nextFightSeq(_ownerB),
            nonce: uint256(keccak256(abi.encodePacked("inv-nonce", _nonce))),
            expiry: type(uint64).max
        });

        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(_pk, duel.hashDuelResult(r));
        bytes memory sig = abi.encodePacked(rs, ss, v);

        // ⚠ NO vm.prank HERE. The invariant fuzzer already pranks the sender for
        // this call, and a nested prank reverts the whole handler frame before
        // the try/catch — which is exactly how an earlier version of this file
        // reported "no duel ever settled" while a direct call worked fine. The
        // handler OWNS tokenA instead, so it is the active side by construction
        // and ownerB pays passively from the custodied balance.
        // ⚠ COUNT THE VALUE ONLY IF THE CALL ACTUALLY TOOK IT. Incrementing
        // before the `try` counted `msg.value` on reverted fights too, where
        // the EVM hands every wei straight back — so `totalIn` drifted upward
        // on every rejection and `invariant_creditIsNeverConjured` got looser
        // the more often the fuzzer failed. An invariant that relaxes when the
        // system misbehaves is worse than no invariant.
        try duel.submitDuel{value: value}(r, sig) {
            totalIn += value;
            fightsSettled += 1;
            // Whatever the fight refunded went back to ownerA's wallet, out of
            // the contract. Measure it rather than predicting it.
            totalOut += _refundOf(value, stake);
        } catch (bytes memory err) {
            // Unaffordable or otherwise rejected: the deposits stay as credit,
            // and the value never left the caller.
            lastFightError = err;
            fightsRejected += 1;
        }
    }

    bytes public lastFightError;
    uint256 public fightsRejected;

    /// @dev The refund is msg.value less whatever the active side's stake
    ///      actually consumed from it.
    function _refundOf(uint256 value, uint256 stake) private pure returns (uint256) {
        return value >= stake ? value - stake : value;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev Burns every drop of gas forwarded to it.
contract GasBurner {
    function deposit(DuelNative d, uint256 amount) external {
        d.deposit{value: amount}();
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        while (true) {
            // consume everything forwarded
        }
    }
}

/// @dev Tries to re-enter `withdraw` from the refund fired inside `submitDuel`.
contract CrossReenterer {
    DuelNative public immutable duel;
    bool public armed;
    bool public reenterFailed;

    constructor(DuelNative d) {
        duel = d;
    }

    function topUp(uint256 amount) external {
        duel.deposit{value: amount}();
    }

    function arm() external {
        armed = true;
    }

    function pullReentrant(uint256 amount) external {
        duel.withdraw(amount);
    }

    function fight(DuelNative.DuelResult calldata r, bytes calldata sig, uint256 value)
        external
    {
        duel.submitDuel{value: value}(r, sig);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            try duel.withdraw(1) {
                reenterFailed = false;
            } catch {
                reenterFailed = true;
            }
        }
    }
}

/// @dev Force-feeds native past `receive()` via selfdestruct.
contract ForceFeeder {
    constructor() payable {}

    function boom(address payable victim) external {
        selfdestruct(victim);
    }
}
