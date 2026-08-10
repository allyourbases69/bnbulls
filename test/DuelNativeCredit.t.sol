// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {DuelRevertingJackpot, PermissiveYards} from "./mocks/DuelMocks.sol";

/**
 * @title DuelNativeCreditTest
 * @notice The native-BNB credit ledger that replaces the WBNB allowance.
 *
 * @dev WHAT IS ON TRIAL. `DuelNative` exists so a player never holds, approves
 *      or receives a wrapped token. That required moving two things off WBNB:
 *
 *        1. THE PASSIVE STAKE. Only `msg.sender` can post value and native BNB
 *           has no allowance, so a wallet that is not signing can only be
 *           charged if the contract already custodies its money.
 *        2. THE PAYOUT. The old contract had to pay in WBNB because a raw
 *           `.call{value:}` to a winner with a reverting `receive()` would have
 *           reverted the whole duel. Crediting cannot revert.
 *
 *      Both are asserted here, and so is the invariant that makes custody safe:
 *      `address(this).balance >= totalBnbCredit`, checked after every test that
 *      moves money. If that ever inverts, one player's withdrawal is another
 *      player's stake.
 *
 *      ⚠ MOCKS ONLY, NO FORK — same rule as the rest of the Duel suites.
 */
contract DuelNativeCreditTest is BnbullsBase {
    DuelNative internal duelN;
    Graveyard internal graveN;

    uint256 internal constant SIGNER_PK = 0xB011_51_6E;
    address internal signerN;
    address internal duelTreasuryN = address(0xDE7);

    uint256 internal constant MAX_COST_WBNB = 100 ether;
    uint256 internal constant MAX_COST_BNBULL = 1_000_000e18;
    uint16 internal constant DEV_BPS = 1_000;
    uint256 internal constant USD_FIGHT_PRICE = 10e18;
    /// @dev $10 at the harness's $600 BNB.
    uint256 internal constant STAKE_BNB = (USD_FIGHT_PRICE * 1e18) / BNB_USD_1E18;

    uint256 internal _nonceSeq;

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
        // ⚠ THE CONSENT GATE. `_requireInYards` now FAILS CLOSED, so an unwired
        // slot refuses every duel — which is the point: this fixture used to
        // pass with the gate switched off, and so did the migration script.
        // A permissive stand-in keeps these tests about the money paths; the
        // gate's own behaviour is proven in DuelNativeReview and DuelYards.
        duelN.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));

        potBnbull.bootstrapDuel(address(duelN));
        potBnb.bootstrapDuel(address(duelN));
        potBnbull.setFunder(address(duelN), true);
        potBnb.setFunder(address(duelN), true);

        graveN.bootstrapWire(Graveyard.Wire.Duel, address(duelN));
        graveN.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        graveN.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        // Passive stakes now draw on an allowance the wallet sets, the way the
        // WBNB era drew on an ERC-20 approval. Bounded on purpose: a fixture that
        // grants type(uint256).max would re-open exactly the drain being fixed.
        vm.prank(alice);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(bob);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(carol);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE INVARIANT
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Solvency. Every test that moves money ends here. The contract may
    ///      hold MORE than it owes (a stray donation, a dev cut mid-flight) but
    ///      never less, or somebody's withdrawal is somebody else's money.
    function _assertSolvent() internal view {
        assertGe(
            address(duelN).balance,
            duelN.totalBnbCredit(),
            "INSOLVENT: contract balance below the credit it owes"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Deposit / withdraw
    // ══════════════════════════════════════════════════════════════════════

    function test_deposit_creditsSenderAndTotal() public {
        vm.prank(alice);
        duelN.deposit{value: 3 ether}();

        assertEq(duelN.bnbCredit(alice), 3 ether, "credit");
        assertEq(duelN.totalBnbCredit(), 3 ether, "total");
        assertEq(address(duelN).balance, 3 ether, "held");
        _assertSolvent();
    }

    function test_plainSend_isTreatedAsDeposit() public {
        vm.prank(alice);
        (bool ok,) = address(duelN).call{value: 1 ether}("");
        assertTrue(ok, "plain send");
        assertEq(duelN.bnbCredit(alice), 1 ether, "credited, not donated");
        _assertSolvent();
    }

    function test_depositFor_creditsTheNamedWallet() public {
        vm.prank(alice);
        duelN.depositFor{value: 2 ether}(bob);

        assertEq(duelN.bnbCredit(bob), 2 ether, "bob credited");
        assertEq(duelN.bnbCredit(alice), 0, "payer keeps no claim");
        _assertSolvent();
    }

    function test_withdraw_returnsBnbAndClearsCredit() public {
        vm.prank(alice);
        duelN.deposit{value: 5 ether}();

        uint256 before = alice.balance;
        vm.prank(alice);
        duelN.withdraw(2 ether);

        assertEq(alice.balance - before, 2 ether, "native returned");
        assertEq(duelN.bnbCredit(alice), 3 ether, "remainder");
        assertEq(duelN.totalBnbCredit(), 3 ether, "total tracks");
        _assertSolvent();
    }

    function test_withdrawAll_emptiesTheBalance() public {
        vm.prank(alice);
        duelN.deposit{value: 4 ether}();

        uint256 before = alice.balance;
        vm.prank(alice);
        duelN.withdrawAll();

        assertEq(alice.balance - before, 4 ether, "all of it");
        assertEq(duelN.bnbCredit(alice), 0, "empty");
        assertEq(duelN.totalBnbCredit(), 0, "total empty");
        _assertSolvent();
    }

    function test_withdraw_moreThanHeld_reverts() public {
        vm.prank(alice);
        duelN.deposit{value: 1 ether}();

        vm.expectRevert(
            abi.encodeWithSelector(DuelNative.InsufficientCredit.selector, alice, 2 ether, 1 ether)
        );
        vm.prank(alice);
        duelN.withdraw(2 ether);
    }

    /// @dev Nobody can withdraw against somebody else's balance.
    function test_withdraw_cannotTouchAnotherWallet() public {
        vm.prank(alice);
        duelN.deposit{value: 5 ether}();

        vm.expectRevert(
            abi.encodeWithSelector(DuelNative.InsufficientCredit.selector, bob, 1, 0)
        );
        vm.prank(bob);
        duelN.withdraw(1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The fight: passive side pays from credit
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE HEADLINE. Alice challenges Bob's bull. Alice pays with
     *         `msg.value`; Bob is not signing and pays from the balance he
     *         topped up earlier. No WBNB, no allowance, anywhere.
     */
    function test_passiveSide_paysFromCredit_noWbnbAnywhere() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        uint256 bobBefore = duelN.bnbCredit(bob);
        _submitValue(alice, r, STAKE_BNB);

        assertEq(bobBefore - duelN.bnbCredit(bob), STAKE_BNB, "bob's stake came from credit");
        // Alice won: she takes both post-dev-cut shares as credit.
        uint256 share = STAKE_BNB - (STAKE_BNB * DEV_BPS) / 10_000;
        assertEq(duelN.bnbCredit(alice), share * 2, "winner credited both shares");
        // Nobody holds WBNB. Not the players, not the contract at rest.
        assertEq(wbnb.balanceOf(alice), 0, "alice holds no wbnb");
        assertEq(wbnb.balanceOf(bob), 0, "bob holds no wbnb");
        _assertSolvent();
    }

    function test_passiveSide_withoutCredit_revertsByName() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        bytes memory sig = _sign(r);
        vm.expectRevert(
            abi.encodeWithSelector(DuelNative.InsufficientCredit.selector, bob, STAKE_BNB, 0)
        );
        vm.prank(alice);
        duelN.submitDuel{value: STAKE_BNB}(r, sig);
    }

    /// @dev PRECEDENCE: `msg.value` is spent before the balance. Alice has both;
    ///      only the sent BNB should be consumed.
    function test_precedence_msgValueBeforeCredit() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 1 ether}();
        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        uint256 aliceCreditBefore = duelN.bnbCredit(alice);

        DuelNative.DuelResult memory r = _result(a, b, uint32(b)); // bob wins
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        _submitValue(alice, r, STAKE_BNB);

        // Alice lost, so she earned nothing back; her deposit must be untouched
        // because her stake came out of msg.value.
        assertEq(duelN.bnbCredit(alice), aliceCreditBefore, "deposit untouched");
        _assertSolvent();
    }

    /// @dev An active player with a balance and no `msg.value` falls through to
    ///      the balance — so you can fight without sending BNB every time.
    function test_activeSide_fallsBackToCreditWhenNoValueSent() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 1 ether}();
        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        uint256 aliceBefore = duelN.bnbCredit(alice);

        DuelNative.DuelResult memory r = _result(a, b, uint32(b)); // bob wins
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        _submitValue(alice, r, 0);

        assertEq(aliceBefore - duelN.bnbCredit(alice), STAKE_BNB, "paid from balance");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Accounting, to the wei
    // ══════════════════════════════════════════════════════════════════════

    function test_winnerTakesBothSharesAndDevGetsItsCut() public {
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

        uint256 cut = (STAKE_BNB * DEV_BPS) / 10_000;
        uint256 share = STAKE_BNB - cut;

        assertEq(duelN.bnbCredit(alice), share * 2, "winner");
        // The dev cut is split: pot slice out, remainder credited to dev.
        uint256 potShare = duelN.potShareBps();
        uint256 slicePer = (cut * potShare) / 10_000;
        assertEq(
            duelN.bnbCredit(duelTreasuryN),
            (cut - slicePer) * 2,
            "dev keeps the cut less the pot slice"
        );
        _assertSolvent();
    }

    function test_tie_refundsEachSideItsOwnStakeLessTheCut() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();
        uint256 bobBefore = duelN.bnbCredit(bob);

        DuelNative.DuelResult memory r = _result(a, b, 0); // tie
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        _submitValue(alice, r, STAKE_BNB);

        uint256 share = STAKE_BNB - (STAKE_BNB * DEV_BPS) / 10_000;
        assertEq(duelN.bnbCredit(alice), share, "alice refunded her own");
        assertEq(duelN.bnbCredit(bob) - (bobBefore - STAKE_BNB), share, "bob refunded his own");
        _assertSolvent();
    }

    /// @dev Excess `msg.value` still comes back, exactly as before.
    function test_overpay_isRefunded() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        uint256 before = alice.balance;
        _submitValue(alice, r, STAKE_BNB + 1 ether);
        assertEq(before - alice.balance, STAKE_BNB, "only the stake was kept");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The griefing vector the old contract could only dodge
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A winner whose `receive()` reverts CANNOT break the fight.
     *
     * @dev This is the reason the old Duel paid in WBNB at all. Here the payout
     *      is a storage write, so the duel settles; the broken contract simply
     *      cannot `withdraw` afterwards, which is its own problem.
     */
    function test_winnerWithRevertingReceive_cannotBreakTheDuel() public {
        RejectingPlayer hostile = new RejectingPlayer();
        vm.deal(address(hostile), 10 ether);

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(address(hostile));

        hostile.deposit(duelN, 1 ether);

        // Passive side, so it must opt in like any wallet. `vm.prank` rather
        // than a helper: setPassiveAllowance is a plain external call and the
        // hostile fixture has no wrapper for it.
        vm.prank(address(hostile));
        duelN.setPassiveAllowance(MAX_COST_WBNB);

        DuelNative.DuelResult memory r = _result(a, b, uint32(b)); // hostile wins
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        // Settles cleanly despite the winner being unpayable by push.
        _submitValue(alice, r, STAKE_BNB);

        uint256 share = STAKE_BNB - (STAKE_BNB * DEV_BPS) / 10_000;
        assertGt(duelN.bnbCredit(address(hostile)), 0, "winnings credited regardless");
        assertEq(
            duelN.bnbCredit(address(hostile)),
            1 ether - STAKE_BNB + share * 2,
            "to the wei"
        );

        // And the hostile contract's own withdrawal is the only thing that fails.
        vm.expectRevert(DuelNative.WithdrawFailed.selector);
        hostile.pull(duelN, 1);
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Reentrancy
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A `receive()` that calls back into `withdraw` must not double-spend.
    ///      CEI debits first, so the re-entrant frame sees a settled ledger; the
    ///      guard stops it before that even matters.
    function test_reentrantWithdraw_cannotDoubleSpend() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer();
        vm.deal(address(attacker), 10 ether);
        attacker.deposit(duelN, 2 ether);

        // The re-entrant call reverts, taking the whole withdrawal with it.
        vm.expectRevert();
        attacker.pull(duelN, 1 ether);

        // Nothing was drained.
        assertEq(duelN.bnbCredit(address(attacker)), 2 ether, "ledger intact");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The pot leg — the only surviving wrap
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A failing pot must not strand wrapped BNB or break solvency.
     *
     * @dev THE RISKIEST NEW INTERACTION. The pot slice is wrapped native->WBNB
     *      inside `routePotSliceInline`, which runs as a try/catch'd EXTERNAL
     *      self-call. If `fund()` reverts after the wrap has happened, the whole
     *      sub-call frame rolls back — including the wrap — so the slice goes to
     *      dev as credit and no WBNB is left sitting here. If that rollback did
     *      not hold, the contract would leak native into WBNB on every failed
     *      pot leg and quietly go insolvent against its own ledger.
     */
    function test_failingPotLeg_rollsBackTheWrapAndPaysDev() public {
        DuelRevertingJackpot deadPot = new DuelRevertingJackpot();
        // `bootstrapWire` is one-shot and setUp already used it, so swap the
        // pot the way production would: propose, age past the delay, commit.
        duelN.proposeWire(DuelNative.Wire.JackpotBnb, address(deadPot));
        vm.warp(block.timestamp + duelN.wiringDelay() + 1);
        duelN.commitWire(DuelNative.Wire.JackpotBnb);

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

        uint256 cut = (STAKE_BNB * DEV_BPS) / 10_000;
        // The pot failed, so dev keeps the WHOLE cut — no slice was deducted.
        assertEq(duelN.bnbCredit(duelTreasuryN), cut * 2, "dev keeps the full cut");
        // And no wrapped BNB was left behind by the rolled-back wrap.
        assertEq(wbnb.balanceOf(address(duelN)), 0, "no stranded wbnb");
        _assertSolvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Solvency across a run of fights
    // ══════════════════════════════════════════════════════════════════════

    function test_solvency_holdsAcrossManyFights() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        vm.prank(alice);
        duelN.deposit{value: 10 ether}();
        vm.prank(bob);
        duelN.deposit{value: 10 ether}();

        for (uint256 i = 0; i < 12; i++) {
            DuelNative.DuelResult memory r =
                _result(a, b, uint32(i % 2 == 0 ? a : b));
            r.assetA = address(wbnb);
            r.assetB = address(wbnb);
            r.stakeA = STAKE_BNB;
            r.stakeB = STAKE_BNB;
            _submitValue(alice, r, 0); // both sides from credit
            _assertSolvent();
        }

        // Everyone can still get their money out.
        vm.prank(alice);
        duelN.withdrawAll();
        vm.prank(bob);
        duelN.withdrawAll();
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
            seed: uint256(keccak256(abi.encodePacked("native-seed", _nonceSeq))),
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

/// @dev A player contract that refuses native sends. Deposits fine, cannot be
///      paid by push — the exact shape the old contract had to design around.
///      Holds bulls, so it must accept the ERC-721.
contract RejectingPlayer {
    function deposit(DuelNative d, uint256 amount) external {
        d.deposit{value: amount}();
    }

    function pull(DuelNative d, uint256 amount) external {
        d.withdraw(amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("no thanks");
    }
}

/// @dev Attempts to re-enter `withdraw` from its own `receive()`.
contract ReentrantWithdrawer {
    bool private _in;

    function deposit(DuelNative d, uint256 amount) external {
        d.deposit{value: amount}();
    }

    function pull(DuelNative d, uint256 amount) external {
        _target = d;
        d.withdraw(amount);
    }

    DuelNative private _target;

    receive() external payable {
        if (!_in) {
            _in = true;
            _target.withdraw(1 ether);
        }
    }
}
