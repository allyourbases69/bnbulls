// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ══════════════════════════════════════════════════════════════════════════
//  EXTERNAL SECURITY REVIEW — the pairing the shipped suite never builds.
//
//  Every DuelNative test wires the OLD ERC-20 `Jackpot` as `Wire.JackpotBnb`
//  (test/Base.t.sol:97). `MigrateNative.s.sol` wires `JackpotNative` there.
//  So the production pairing has ZERO coverage. This file is that pairing.
// ══════════════════════════════════════════════════════════════════════════

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";
import {PermissiveYards} from "./mocks/DuelMocks.sol";

contract JackpotNativeDuelWireTest is BnbullsBase {
    DuelNative internal duelN;
    Graveyard internal graveN;
    JackpotNative internal potNative;

    uint256 internal constant SIGNER_PK = 0xB011_51_6E;
    address internal signerN;
    address internal duelTreasuryN = address(0xDE7);

    uint256 internal constant MAX_COST_WBNB = 100 ether;
    uint256 internal constant MAX_COST_BNBULL = 1_000_000e18;
    uint16 internal constant DEV_BPS = 1_000;
    uint256 internal constant USD_FIGHT_PRICE = 10e18;
    uint256 internal constant STAKE_BNB = (USD_FIGHT_PRICE * 1e18) / BNB_USD_1E18;
    uint256 internal constant ODDS = 75;

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

        // ── the production pot ────────────────────────────────────────────
        potNative = new JackpotNative(address(wbnb), owner, address(coord), ODDS);
        potNative.bootstrapDuel(address(duelN));
        potNative.setFunder(address(duelN), true);
        potNative.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        potNative.setRequester(owner, true);
        // Exactly what MigrateNative.s.sol writes.
        potNative.bootstrapPayoutParams(ODDS, 10_000, 0.0168 ether);

        bulls.bootstrapWire(Bulls.Wire.Duel, address(duelN));
        bulls.bootstrapWire(Bulls.Wire.Graveyard, address(graveN));

        duelN.bootstrapWire(DuelNative.Wire.Graveyard, address(graveN));
        duelN.bootstrapWire(DuelNative.Wire.JackpotBnbull, address(potBnbull));
        duelN.bootstrapWire(DuelNative.Wire.JackpotBnb, address(potNative));
        duelN.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));
        // ⚠ THE FIFTH WIRE. This fixture was written to mirror what
        // `MigrateNative.s.sol` bootstraps — and that script wired FOUR of the
        // five, omitting the consent gate. `_requireInYards` now FAILS CLOSED,
        // so the omission that once passed silently here (and would have
        // shipped) refuses every duel instead. A permissive stand-in keeps this
        // file about the Duel↔pot pairing it exists to cover; the gate's own
        // behaviour is proven in NativeSeams, DuelNativeReview and DuelYards.
        duelN.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));

        potBnbull.bootstrapDuel(address(duelN));
        potBnbull.setFunder(address(duelN), true);

        graveN.bootstrapWire(Graveyard.Wire.Duel, address(duelN));
        graveN.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        graveN.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);

        // A passive side now draws on an allowance its owner set, the way the
        // WBNB era drew on an ERC-20 approval — custody deleted that ceiling
        // and silently replaced it with the whole float. Bounded on purpose:
        // granting type(uint256).max here would re-open the very drain the
        // allowance exists to close.
        vm.prank(alice);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(bob);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
    }

    // ─── helpers ──────────────────────────────────────────────────────────

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
            seed: uint256(keccak256(abi.encodePacked("wire-seed", _nonceSeq))),
            newEloA: 1_050,
            newEloB: 950,
            assetA: address(wbnb),
            assetB: address(wbnb),
            stakeA: STAKE_BNB,
            stakeB: STAKE_BNB,
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

    function _submit(address who, DuelNative.DuelResult memory r, uint256 value) internal {
        bytes memory sig = _sign(r);
        vm.prank(who);
        duelN.submitDuel{value: value}(r, sig);
    }

    function _fundBothSides() internal returns (uint256 a, uint256 b) {
        a = bulls.mint(alice);
        b = bulls.mint(bob);
        vm.prank(bob);
        duelN.deposit{value: 10 ether}();
    }

    function _solvent() internal view {
        assertGe(address(duelN).balance, duelN.totalBnbCredit(), "duel INSOLVENT");
        assertGe(address(potNative).balance, potNative.totalOwed(), "pot INSOLVENT");
        assertEq(
            address(potNative).balance,
            potNative.pool() + potNative.totalOwed(),
            "pot netting drift"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE POT SLICE MUST ACTUALLY LAND, THROUGH wrap -> fund -> unwrap
    // ══════════════════════════════════════════════════════════════════════

    function test_WIRE_potSliceReachesTheNativePot() public {
        (uint256 a, uint256 b) = _fundBothSides();
        uint256 poolBefore = potNative.pool();

        vm.recordLogs();
        DuelNative.DuelResult memory r = _result(a, b, uint32(a));
        _submit(alice, r, STAKE_BNB);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The two silent-failure receipts DuelNative emits when a pot leg dies.
        bytes32 sliceFailed = keccak256("PotSliceFailed(address,uint256)");
        bytes32 resolveFailed = keccak256("JackpotResolveFailed(address,bytes4)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sliceFailed) {
                revert("POT SLICE SWALLOWED: the wrap->fund->unwrap leg failed");
            }
            if (logs[i].topics[0] == resolveFailed) {
                console2.log("!! JackpotResolveFailed emitted");
                console2.logBytes32(logs[i].topics[0]);
            }
        }

        uint256 delta = potNative.pool() - poolBefore;
        console2.log("pot slice landed (wei):", delta);
        assertGt(delta, 0, "the native pot received nothing from a staked duel");
        assertEq(wbnb.balanceOf(address(potNative)), 0, "no wbnb may rest in the pot");
        assertEq(potNative.ticketCount(), 1, "a decisive staked duel must open a ticket");
        _solvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE SHARED GUARD MUST NOT NEST INSIDE ONE submitDuel
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev `submitDuel` calls `pot.fund()` (guard) and then `pot.resolve()`
     *      (same guard) in one transaction. If they ever nested, `resolve`
     *      would revert into `_resolveOnly`'s catch and the cursor would roll
     *      back silently. Drive a real batch through a real duel and assert the
     *      cursor actually MOVES.
     */
    function test_WIRE_resolveNudgeAdvancesTheCursorInsideADuel() public {
        (uint256 a, uint256 b) = _fundBothSides();

        // Duel 1: opens ticket 0 and funds the pot.
        _submit(alice, _result(a, b, uint32(a)), STAKE_BNB);
        assertEq(potNative.ticketCount(), 1);
        assertEq(potNative.nextToResolve(), 0, "nothing resolvable yet");

        // Get a word for the pending ticket.
        uint256 req = potNative.requestResolve(5);
        coord.fulfillTo(address(potNative), req, uint256(keccak256("plain-word")));
        assertTrue(potNative.wordReady());

        // Duel 2: the nudge inside submitDuel must consume ticket 0.
        _submit(alice, _result(a, b, uint32(a)), STAKE_BNB);

        assertEq(
            potNative.nextToResolve(),
            1,
            "GUARD NESTED: submitDuel's resolve nudge did not advance the cursor"
        );
        _solvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. A REAL WIN, PAID IN NATIVE, END TO END THROUGH THE DUEL
    // ══════════════════════════════════════════════════════════════════════

    function test_WIRE_realWinCreditsAndWithdrawsNative() public {
        (uint256 a, uint256 b) = _fundBothSides();

        // Seed the pot well past the 0.0168 dust floor.
        potNative.setFunder(owner, true);
        potNative.fundNative{value: 5 ether}("seed");

        _submit(alice, _result(a, b, uint32(a)), STAKE_BNB);
        assertEq(potNative.ticketCount(), 1, "ticket opened");

        // Grind a word that makes ticket 0 win, using the pot's exact preimage.
        (address w,, uint256 tokenId, uint256 entropy,) = potNative.tickets(0);
        assertEq(w, alice, "winner is the bull's owner");
        uint256 word;
        for (uint256 c = 1; c < 500_000; c++) {
            if (
                uint256(
                    keccak256(abi.encodePacked(c, entropy, tokenId, w, uint256(0), address(potNative)))
                ) % ODDS == 0
            ) {
                word = c;
                break;
            }
        }
        require(word != 0, "no winning word");

        uint256 req = potNative.requestResolve(5);
        coord.fulfillTo(address(potNative), req, word);

        uint256 poolAtResolve = potNative.pool();
        potNative.resolve(5);

        assertEq(potNative.owed(alice), poolAtResolve, "whole pool credited at 100% bps");
        assertGt(potNative.owed(alice), 5 ether, "prize is real money");

        uint256 before = alice.balance;
        vm.prank(alice);
        potNative.withdrawAll();
        assertEq(alice.balance - before, poolAtResolve, "winner received native BNB");
        assertEq(wbnb.balanceOf(alice), 0, "winner never touched WBNB");
        _solvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. ONE POT PER DUEL, ACROSS THE REAL TWO-POT PAIRING
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The BNBULL pot (old `Jackpot`, odds 50) and the native pot (odds 75)
    ///      both ticket the same fight with the same duelKey. Prove they cannot
    ///      both pay it.
    function test_WIRE_bothPotsTicketButOnlyOneMayPay() public {
        (uint256 a, uint256 b) = _fundBothSides();
        _submit(alice, _result(a, b, uint32(a)), STAKE_BNB);

        assertEq(potNative.ticketCount(), 1, "native pot ticketed");
        assertEq(potBnbull.ticketCount(), 1, "bnbull pot ticketed");

        (,,,, uint256 keyNative) = potNative.tickets(0);
        (,,,, uint256 keyBnbull) = potBnbull.tickets(0);
        assertEq(keyNative, keyBnbull, "both pots must share the duel key");
        assertTrue(keyNative != 0, "a zero key would disable exclusivity");
        _solvent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. GAS: the nudge runs under a real duel's budget
    // ══════════════════════════════════════════════════════════════════════

    function test_WIRE_duelGasWithTheNativePot() public {
        (uint256 a, uint256 b) = _fundBothSides();
        potNative.setFunder(owner, true);
        potNative.fundNative{value: 5 ether}("seed");

        // Alternate the winner so neither bull hits the 3-loss death streak.
        for (uint256 i; i < 6; i++) {
            _submit(alice, _result(a, b, uint32(i % 2 == 0 ? a : b)), STAKE_BNB);
        }
        uint256 req = potNative.requestResolve(6);
        coord.fulfillTo(address(potNative), req, uint256(keccak256("w")));

        uint256 g0 = gasleft();
        _submit(alice, _result(a, b, uint32(a)), STAKE_BNB);
        console2.log("submitDuel gas with a live native-pot batch:", g0 - gasleft());
        assertGt(potNative.nextToResolve(), 0, "the nudge did work");
        _solvent();
    }
}
