// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Duel} from "../contracts/Duel.sol";
import {DuelNative} from "../contracts/DuelNative.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";
import {Graveyard} from "../contracts/Graveyard.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Yards} from "../contracts/Yards.sol";
import {PermissiveYards} from "./mocks/DuelMocks.sol";

/**
 * @title NativeSeamsTest
 * @notice THE SEAMS BETWEEN CONTRACTS, not the contracts.
 *
 * @dev Every other suite audits one contract in isolation. This one only ever
 *      asks what happens WHERE TWO MEET — and specifically where the two new
 *      contracts (`DuelNative`, `JackpotNative`) meet the eight that are
 *      staying (`Bulls`, `Yards`, `Graveyard`, `MintDrop`, `Marketplace`, the
 *      three splitters) plus the SECOND, unchanged, ERC-20 pot (`Jackpot`).
 *
 *      ⚠ THE GAP THIS FILE EXISTS TO CLOSE. Before it, NOTHING in the suite
 *      instantiated `DuelNative` and `JackpotNative` together. `DuelNativeCredit`
 *      wires `DuelNative` to the OLD ERC-20 `Jackpot`; `JackpotNativePot` drives
 *      `JackpotNative` from a `MockDuel`. The exact pairing that will custody
 *      real money on chain 56 had zero integration coverage.
 */
contract NativeSeamsTest is BnbullsBase {
    DuelNative internal duelN;
    JackpotNative internal newPot;
    Graveyard internal graveN;

    uint256 internal constant SIGNER_PK = 0x5EA_11;
    address internal signerN;
    address internal duelTreasuryN = address(0xDE7);

    uint256 internal constant MAX_COST_WBNB = 100 ether;
    uint256 internal constant MAX_COST_BNBULL = 1_000_000e18;
    uint16 internal constant DEV_BPS = 1_000;
    uint256 internal constant USD_FIGHT_PRICE = 10e18;
    uint256 internal constant STAKE_BNB = (USD_FIGHT_PRICE * 1e18) / BNB_USD_1E18;
    uint256 internal constant NEW_ODDS = 75;

    uint256 internal _nonceSeq;

    function setUp() public virtual override {
        super.setUp();
        signerN = vm.addr(SIGNER_PK);

        duelN = new DuelNative(_params(signerN));
        duelN.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        duelN.addFightAsset(address(bnbull), MAX_COST_BNBULL, DEV_BPS);
        duelN.setFightCost(address(bnbull), 1_000e18);
        duelN.setUsdFightPrice(USD_FIGHT_PRICE);

        // The production pairing: the BNBULL pot stays ERC-20, the BNB pot is
        // native. `potBnbull` is the untouched `Jackpot.sol`.
        newPot = new JackpotNative(address(wbnb), owner, address(coord), NEW_ODDS);
        newPot.bootstrapDuel(address(duelN));
        newPot.bootstrapPayoutParams(NEW_ODDS, 10_000, 0);
        newPot.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        newPot.setFunder(address(duelN), true);
        newPot.setFunder(address(drop), true);
        newPot.setRequester(owner, true);

        graveN = new Graveyard(owner, address(bulls), address(bnbull), treasury);

        bulls.bootstrapWire(Bulls.Wire.Duel, address(duelN));
        bulls.bootstrapWire(Bulls.Wire.Graveyard, address(graveN));

        duelN.bootstrapWire(DuelNative.Wire.Graveyard, address(graveN));
        duelN.bootstrapWire(DuelNative.Wire.JackpotBnbull, address(potBnbull));
        duelN.bootstrapWire(DuelNative.Wire.JackpotBnb, address(newPot));
        duelN.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));
        // ⚠ THE FIFTH WIRE — the one `MigrateNative.s.sol` omitted. This fixture
        // was built to mirror that script, so it inherited the omission and the
        // seam tests passed with the consent gate switched off. `_requireInYards`
        // now FAILS CLOSED, so the SEAM tests get a permissive stand-in to stay
        // about seams; the gate itself is proven below in
        // `test_SEAM_anUnwiredYardsGateNowFailsClosed`.
        duelN.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));

        potBnbull.bootstrapDuel(address(duelN));
        potBnbull.bootstrapPayoutParams(50, 10_000, 0);
        potBnbull.setFunder(address(duelN), true);

        graveN.bootstrapWire(Graveyard.Wire.Duel, address(duelN));
        graveN.bootstrapWire(Graveyard.Wire.MintDrop, address(drop));
        graveN.bootstrapWire(Graveyard.Wire.PriceFeed, address(feed));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // A passive side draws on an allowance its owner set — the ceiling the
        // WBNB-era ERC-20 approval used to provide and custody silently removed.
        // Bounded, not type(uint256).max, for the reason the allowance exists.
        vm.prank(alice);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(bob);
        duelN.setPassiveAllowance(MAX_COST_WBNB);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SEAM 1 — MintDrop / splitters -> the pot. THE WIRE NOBODY MOVES.
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⛔ CRITICAL. `MintDrop.Wire.JackpotBnb` is a TIMELOCKED slot on a
     *         contract that is NOT being redeployed, and `MigrateNative.s.sol`
     *         never proposes it. It keeps pointing at the OLD WBNB pot after
     *         cutover, so every mint / revive / marketplace pot slice keeps
     *         funding a contract that can no longer pay anybody.
     *
     * @dev THE FAILURE IS SILENT BY CONSTRUCTION. MintDrop is still a funder on
     *      the old pot, so `fund` SUCCEEDS — no revert, no `catch`, no
     *      `BnbPotDeferred`, nothing for an alert bot to see. The money is gone:
     *      the old pot's `sweepForeignToken` reverts on its prize token and its
     *      `_duelWire` still names the OLD Duel, which receives no more fights,
     *      so no new ticket can ever be opened against it.
     *
     *      This is the modern shape of the 77-wedged-tickets incident: every
     *      health read stays green while the money stops arriving.
     */
    function test_SEAM_mintDropStillFundsTheDeadPotAfterCutover() public {
        // Cutover has happened: the new Duel is wired to the new pot.
        (,, address duelPotBnb,) = duelN.wires();
        assertEq(duelPotBnb, address(newPot), "duel points at the new pot");
        // But MintDrop was never repointed, exactly as the migration leaves it.
        (,,, address dropPotBnb) = drop.wires();
        assertEq(dropPotBnb, address(potBnb), "MintDrop STILL points at the old WBNB pot");

        drop.setPotShares(0, 5_000); // send the whole donation to the BNB leg
        uint256 oldPoolBefore = potBnb.pool();

        drop.donatePotNative{value: 4 ether}();

        assertGt(potBnb.pool() - oldPoolBefore, 0, "the DEAD pot got the money");
        assertEq(newPot.pool(), 0, "the LIVE pot got nothing");
        assertEq(newPot.totalFunded(), 0, "and nothing was even attempted");

        // And it is unrecoverable: the old pot refuses to give its prize token
        // back to the owner, which is the whole no-withdraw product.
        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnb.sweepForeignToken(address(wbnb), owner, 1);
    }

    /**
     * @notice The fix is one timelocked repoint per funder — proven here so the
     *         runbook step can be written against a passing test.
     */
    function test_SEAM_repointingMintDropIsWhatMakesTheNewPotFundable() public {
        drop.proposeWire(MintDrop.Wire.JackpotBnb, address(newPot));
        vm.warp(block.timestamp + 24 hours + 1);
        drop.commitWire(MintDrop.Wire.JackpotBnb);

        drop.setPotShares(0, 5_000);
        drop.donatePotNative{value: 4 ether}();

        assertGt(newPot.pool(), 0, "now the live pot is funded");
        assertEq(wbnb.balanceOf(address(newPot)), 0, "and it rests NATIVE, not WBNB");
        assertEq(address(newPot).balance, newPot.pool(), "balance is the pool");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SEAM 2 — `fund(uint256,string)` ABI compatibility, byte for byte
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The load-bearing claim of the whole migration: four deployed,
     *         immutable contracts keep calling what they called yesterday.
     */
    function test_SEAM_fundAbiIsIdenticalAcrossBothPots() public pure {
        assertEq(
            Jackpot.fund.selector, JackpotNative.fund.selector, "fund selector must not move"
        );
        // The encodings a deployed funder emits must be byte-identical.
        assertEq(
            keccak256(abi.encodeCall(Jackpot.fund, (1 ether, "mint-inline"))),
            keccak256(abi.encodeCall(JackpotNative.fund, (1 ether, "mint-inline"))),
            "calldata must be byte-identical"
        );
        // The gate a non-funder hits must still be the same error.
        assertEq(Jackpot.NotFunder.selector, JackpotNative.NotFunder.selector, "NotFunder moved");
    }

    /// @notice The REAL, unmodified `MintDrop` funding the native pot through
    ///         its hard-coded `forceApprove` + `fund` leg.
    function test_SEAM_theDeployedMintDropLegDrivesTheNativePot() public {
        drop.proposeWire(MintDrop.Wire.JackpotBnb, address(newPot));
        vm.warp(block.timestamp + 24 hours + 1);
        drop.commitWire(MintDrop.Wire.JackpotBnb);
        drop.setPotShares(0, 5_000);

        drop.donatePotNative{value: 6 ether}();

        // `donatePotNative` gives 100% to the pots in the bnbull:bnb RATIO, and
        // the bnbull share is zero here, so the whole donation lands native.
        assertEq(newPot.pool(), 6 ether, "the whole donate leg, unwrapped");
        assertEq(newPot.totalFunded(), 6 ether, "booked as a measured delta");
        assertEq(wbnb.allowance(address(drop), address(newPot)), 0, "approval cleared");
    }

    /**
     * @notice ⚠ THE ONE REAL COMPATIBILITY COST: `fund` now costs more gas,
     *         because it unwraps inside the same call. Every deployed funder
     *         calls it from inside a `try` block, so a gas-starved call is
     *         CAUGHT and becomes an accrual rather than a revert — the pot
     *         quietly stops being funded inline instead of failing loudly.
     */
    function test_SEAM_theNativeFundCostsMoreGasThanTheOldOne() public {
        potBnb.setFunder(address(this), true);
        newPot.setFunder(address(this), true);
        vm.deal(address(this), 10 ether);
        wbnb.deposit{value: 4 ether}();

        wbnb.approve(address(potBnb), 1 ether);
        uint256 g0 = gasleft();
        potBnb.fund(1 ether, "x");
        uint256 oldGas = g0 - gasleft();

        wbnb.approve(address(newPot), 1 ether);
        g0 = gasleft();
        newPot.fund(1 ether, "x");
        uint256 newGas = g0 - gasleft();

        emit log_named_uint("old Jackpot.fund gas", oldGas);
        emit log_named_uint("JackpotNative.fund gas", newGas);
        assertGt(newGas, oldGas, "the unwrap is not free");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SEAM 3 — one pot per duel, across a Duel REPLACEMENT
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⛔ HIGH. `duelJackpotPaid` — the entire one-pot-per-duel ledger —
     *         is storage ON THE DUEL. Replacing the Duel wipes it.
     *
     * @dev The BNBULL pot is NOT redeployed and its ticket backlog is NOT
     *      drained by the runbook (step 3 drains only the BNB pot). Those
     *      tickets carry duel keys minted by the OLD Duel. After stage 2 repoints
     *      `Jackpot.duelWire` at `DuelNative`, resolving one of them asks the NEW
     *      Duel about a key only the OLD Duel ever saw — and the new Duel, having
     *      an empty ledger, grants it.
     *
     *      Result: a duel whose jackpot was already paid out of the WBNB pot can
     *      be paid a SECOND time out of the BNBULL pot. "Never both pots" is the
     *      one invariant this machinery exists to enforce.
     */
    function test_SEAM_replacingTheDuelWipesTheOnePotPerDuelLedger() public {
        Duel oldDuel = new Duel(_oldParams(signerN));
        oldDuel.bootstrapWire(Duel.Wire.JackpotBnbull, address(potBnbull));
        oldDuel.bootstrapWire(Duel.Wire.JackpotBnb, address(potBnb));

        // A key minted by the OLD Duel, on a fight it settled before cutover.
        uint256 key = oldDuel.duelJackpotKey(4242);

        // Pre-cutover: the WBNB pot wins the race and claims it.
        vm.prank(address(potBnb));
        assertTrue(oldDuel.claimJackpotForDuel(key), "first claim granted");
        // The lock works — WITHIN one Duel.
        vm.prank(address(potBnbull));
        assertFalse(oldDuel.claimJackpotForDuel(key), "second claim denied, same Duel");

        // ── stage 2 commits: the BNBULL pot is repointed at the new Duel ──
        // Its backlog still holds tickets carrying `key`.
        vm.prank(address(potBnbull));
        bool grantedAgain = duelN.claimJackpotForDuel(key);

        assertTrue(
            grantedAgain,
            "SEAM BREAK: the new Duel has never seen this key and pays the same duel twice"
        );
    }

    /// @dev The mitigation, stated as a test: a key the new Duel HAS seen is
    ///      locked normally, so the exposure is bounded to the pre-cutover
    ///      backlog rather than being a permanent hole.
    function test_SEAM_theNewDuelsOwnLedgerStillHoldsOnce() public {
        uint256 key = duelN.duelJackpotKey(7);
        vm.prank(address(newPot));
        assertTrue(duelN.claimJackpotForDuel(key), "first");
        vm.prank(address(potBnbull));
        assertFalse(duelN.claimJackpotForDuel(key), "the other pot is denied");
        vm.prank(address(newPot));
        assertFalse(duelN.claimJackpotForDuel(key), "and it cannot claim twice");
    }

    /// @dev The retired pot cannot reach across into the new Duel's ledger and
    ///      pre-claim keys, because it is not one of the new Duel's two wires.
    function test_SEAM_theRetiredPotCannotStarveTheNewOne() public {
        uint256 key = duelN.duelJackpotKey(9);
        vm.prank(address(potBnb)); // the OLD, now-orphaned WBNB pot
        assertFalse(duelN.claimJackpotForDuel(key), "a stranger gets false, not a claim");
        vm.prank(address(newPot));
        assertTrue(duelN.claimJackpotForDuel(key), "and the key was left untouched");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SEAM 4 — a denied claim: no stranding, but no payout, and NO SIGNAL
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The native pot's version of "wedged, while the game reads
     *         healthy". `resolve` can no longer revert — crediting a winner is a
     *         storage write — so the old cursor-wedge is genuinely gone. The
     *         failure moved: a pot whose Duel does not recognise it resolves
     *         every ticket CLEANLY and pays nobody, forever.
     *
     * @dev Every health read a keeper or the UI looks at stays green:
     *      `pendingTickets() == 0`, `resolvable() == false`, the pool grows.
     *      Only `ExclusivityDenied` says otherwise — and nothing off-chain
     *      subscribes to it (`duel-bot.mjs` names it in a comment only).
     */
    function test_SEAM_aPotTheDuelDoesNotKnowResolvesCleanlyAndPaysNobody() public {
        // A pot wired to the Duel, but NOT in the Duel's two pot slots — the
        // exact state produced by ever repointing `Duel.Wire.JackpotBnb`.
        JackpotNative orphan = new JackpotNative(address(wbnb), owner, address(coord), NEW_ODDS);
        orphan.bootstrapDuel(address(duelN));
        orphan.bootstrapPayoutParams(NEW_ODDS, 10_000, 0);
        orphan.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        orphan.setFunder(owner, true);
        orphan.setRequester(owner, true);
        vm.deal(owner, 100 ether);
        orphan.fundNative{value: 10 ether}("seed");

        uint256 key = duelN.duelJackpotKey(1234);
        vm.prank(address(duelN));
        orphan.recordWin(alice, 1, 999, key);

        uint256 word = _winningWord(address(orphan), 999, 1, alice, 0);
        uint256 reqId = orphan.requestResolve(5);
        coord.fulfillTo(address(orphan), reqId, word);
        orphan.resolve(5);

        // The ticket rolled a WIN and was still paid nothing.
        assertEq(orphan.totalAwarded(), 0, "nothing awarded");
        assertEq(orphan.awardCount(), 0, "no award recorded");
        assertEq(orphan.owed(alice), 0, "the winner is owed nothing");

        // ...and not one health read shows it.
        assertEq(orphan.pendingTickets(), 0, "queue reads DRAINED");
        assertFalse(orphan.resolvable(), "reads nothing to do");
        assertEq(orphan.pool(), 10 ether, "the money is safe, and stuck");
        assertEq(address(orphan).balance, orphan.pool() + orphan.totalOwed(), "solvent");
    }

    /// @dev The same denial on the LIVE pot leaves the pool intact rather than
    ///      stranding the slice anywhere — the money rolls over to the next
    ///      winner, which is the correct outcome of a denied claim.
    function test_SEAM_aDeniedClaimStrandsNothingInEitherPot() public {
        vm.deal(owner, 100 ether);
        newPot.setFunder(owner, true);
        newPot.fundNative{value: 8 ether}("seed");

        uint256 key = duelN.duelJackpotKey(555);
        // The BNBULL pot got there first.
        vm.prank(address(potBnbull));
        assertTrue(duelN.claimJackpotForDuel(key), "bnbull pot claimed it");

        vm.prank(address(duelN));
        newPot.recordWin(alice, 1, 42, key);
        uint256 word = _winningWord(address(newPot), 42, 1, alice, 0);
        uint256 reqId = newPot.requestResolve(5);
        coord.fulfillTo(address(newPot), reqId, word);
        newPot.resolve(5);

        assertEq(newPot.pool(), 8 ether, "the pool is whole, nothing stranded");
        assertEq(newPot.totalOwed(), 0, "and nothing half-credited");
        assertEq(address(newPot).balance, 8 ether, "no wei went missing");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SEAM 5 — Duel <-> Bulls / Graveyard across the timelock window
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice `Bulls.Wire.Duel` is ONE slot, so two Duels can never both write
     *         elo — a bull cannot get stats from two sources or die twice.
     *         The cost is the mirror image: during the 24h window the new Duel
     *         is completely dead, and `applyDuelResult` is NOT inside a
     *         try/catch, so every fight reverts.
     *
     * @dev Operationally this means there is NO WAY to smoke-test the new Duel
     *      end to end on mainnet before the irreversible commit. The first real
     *      fight it ever serves is a player's.
     */
    function test_SEAM_theNewDuelIsBrickedUntilBullsCommits() public {
        DuelNative pending = new DuelNative(_params(signerN));
        pending.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        pending.setUsdFightPrice(USD_FIGHT_PRICE);
        // Wire the consent gate so THIS test still proves what it was written
        // to prove. Without it `_requireInYards` reverts first and the assertion
        // below would pass for the wrong reason — a green test measuring a
        // different failure.
        pending.bootstrapWire(DuelNative.Wire.Yards, address(new PermissiveYards()));

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        DuelNative.DuelResult memory r = _result(pending, a, b, uint32(a));
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, pending.hashDuelResult(r));

        vm.prank(alice);
        vm.expectRevert(Bulls.NotAuthorized.selector);
        pending.submitDuel(r, abi.encodePacked(rs, ss, v));
    }

    /**
     * @notice ⛔ THE REGRESSION TEST FOR A FIXED CRITICAL. `MigrateNative.s.sol`
     *         bootstrapped FOUR of the new Duel's five wires — `Graveyard`,
     *         `JackpotBnbull`, `JackpotBnb`, `MintDrop` — and never touched
     *         `Wire.Yards`. Its `Migration` struct had no `yards` field at all,
     *         even though `Yards` is deployed on chain 56 and `Wire.s.sol:328`
     *         calls that slot "THE consent gate".
     *
     * @dev `_requireInYards` USED TO treat a zero slot as "no yards" and RETURN,
     *      so a mis-wire degraded the check instead of bricking the game. That
     *      reasoning was written for a contract that custodied nothing, where a
     *      passive wallet's exposure was the ERC-20 allowance it chose to grant.
     *      The native credit ledger broke it: credit needs no allowance and
     *      ERC-721 needs no consent to RECEIVE, so an unwired gate let anyone
     *      push a junk bull at a depositor, fight it, and spend their float —
     *      measured at 0.8 BNB lifted from a wallet whose only ever action was
     *      `deposit()`.
     *
     *      It now FAILS CLOSED. This test pins both halves of that: an unwired
     *      slot refuses every duel, and a WIRED slot still enforces membership
     *      rather than waving everything through. The original version of this
     *      test asserted the opposite — that two unrostered bulls could fight —
     *      and is kept here inverted, because the behaviour it documented is
     *      exactly what must never come back.
     */
    function test_SEAM_anUnwiredYardsGateNowFailsClosed() public {
        // ── half one: the migration's four-wire duel refuses to fight ──────
        // Exactly the four wires `MigrateNative` stage 1 used to set, and no
        // more. This is the shipped-script shape, reproduced.
        DuelNative fourWired = new DuelNative(_params(signerN));
        fourWired.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        fourWired.setUsdFightPrice(USD_FIGHT_PRICE);
        fourWired.bootstrapWire(DuelNative.Wire.Graveyard, address(graveN));
        fourWired.bootstrapWire(DuelNative.Wire.JackpotBnbull, address(potBnbull));
        fourWired.bootstrapWire(DuelNative.Wire.JackpotBnb, address(newPot));
        fourWired.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));

        (address g, address pA, address pB, address md) = fourWired.wires();
        assertEq(g, address(graveN), "Graveyard wired");
        assertEq(pA, address(potBnbull), "JackpotBnbull wired");
        assertEq(pB, address(newPot), "JackpotBnb wired");
        assertEq(md, address(drop), "MintDrop wired");
        assertEq(fourWired.yardsContract(), address(0), "and the gate is not");

        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);
        vm.prank(bob);
        fourWired.setPassiveAllowance(MAX_COST_WBNB);
        vm.prank(bob);
        fourWired.deposit{value: 1 ether}();

        DuelNative.DuelResult memory r = _result(fourWired, a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, fourWired.hashDuelResult(r));

        // It no longer settles. It refuses, by name.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DuelNative.YardsNotWired.selector, address(0)));
        fourWired.submitDuel{value: STAKE_BNB}(r, abi.encodePacked(rs, ss, v));
        assertFalse(fourWired.usedNonces(r.nonce), "the unrostered fight did NOT settle");

        // ── half two: wired, the gate still ENFORCES rather than waves ─────
        // Failing closed would be worthless if the wired path were permissive.
        Yards realYards = new Yards(owner, address(bulls));
        DuelNative fiveWired = new DuelNative(_params(signerN));
        fiveWired.addFightAsset(address(wbnb), MAX_COST_WBNB, DEV_BPS);
        fiveWired.setUsdFightPrice(USD_FIGHT_PRICE);
        fiveWired.bootstrapWire(DuelNative.Wire.Graveyard, address(graveN));
        fiveWired.bootstrapWire(DuelNative.Wire.JackpotBnbull, address(potBnbull));
        fiveWired.bootstrapWire(DuelNative.Wire.JackpotBnb, address(newPot));
        fiveWired.bootstrapWire(DuelNative.Wire.MintDrop, address(drop));
        fiveWired.bootstrapWire(DuelNative.Wire.Yards, address(realYards));

        DuelNative.DuelResult memory r2 = _result(fiveWired, a, b, uint32(a));
        r2.assetA = address(wbnb);
        r2.assetB = address(wbnb);
        r2.stakeA = STAKE_BNB;
        r2.stakeB = STAKE_BNB;
        (uint8 v2, bytes32 rs2, bytes32 ss2) = vm.sign(SIGNER_PK, fiveWired.hashDuelResult(r2));

        // Neither bull has entered. Now that is the answer the gate gives.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DuelNative.BullNotInYards.selector, a));
        fiveWired.submitDuel{value: STAKE_BNB}(r2, abi.encodePacked(rs2, ss2, v2));
    }

    /**
     * @notice ⚠ `consecutiveLosses` lives on the DUEL, not on `Bulls`. Every
     *         bull's loss streak silently resets to zero at cutover — a bull one
     *         loss from death walks away from it.
     *
     * @dev The runbook's "what is permanently lost" table lists `fightSeq` and
     *      omits this. It is the same class of state and it is the one players
     *      would notice: deaths are the scarcity mechanic the Graveyard sells
     *      against.
     */
    function test_SEAM_lossStreaksResetWhenTheDuelIsReplaced() public {
        Duel oldDuel = new Duel(_oldParams(signerN));
        uint256 tokenId = bulls.mint(alice);

        // Whatever streak a bull carried on the old contract...
        assertEq(oldDuel.consecutiveLosses(tokenId), 0, "streaks live on the Duel");
        // ...the new contract starts it at zero, unconditionally. There is no
        // migration path: the mapping is not readable by, or writable from, the
        // new deployment.
        assertEq(duelN.consecutiveLosses(tokenId), 0, "and the new Duel starts blank");
        assertEq(
            duelN.lossesToDie(), 5, "so a bull at 4/5 on the old Duel is back to 0/5 on the new"
        );
    }

    /// @dev `Graveyard.resetStreak` is NOT try/catch'd on the Graveyard side, so
    ///      the two halves of that wire must agree or every revive reverts.
    ///      Stage 1 bootstraps `DuelNative.Wire.Graveyard`; stage 2 commits
    ///      `Graveyard.Wire.Duel`. Between them the OLD Duel serves it, which is
    ///      consistent — but only because BOTH slots are single-valued.
    function test_SEAM_theGraveyardStreakWireRefusesTheWrongDuel() public {
        uint256 tokenId = bulls.mint(alice);
        vm.prank(address(graveN));
        duelN.resetStreak(tokenId); // the wired Graveyard: fine

        vm.prank(alice);
        vm.expectRevert(DuelNative.NotGraveyard.selector);
        duelN.resetStreak(tokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SEAM 6 — Duel -> both pots in ONE transaction, one native one ERC-20
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE MIGRATION SCRIPT'S COMMENT IS WRONG. `MigrateNative.s.sol`
     *         says "the new Duel funds the pot leg natively via `fundNative`".
     *         It does not: `DuelNative.routePotSliceInline` still wraps to WBNB
     *         and calls `fund(uint256,string)`, and `IDuelJackpot` has no
     *         `fundNative` member at all.
     *
     * @dev Not a break — the pot unwraps it straight back — but it is a pointless
     *      BNB -> WBNB -> BNB round trip plus two approvals on EVERY decisive
     *      BNB fight, paid for by the player, and it keeps the "last wrap in the
     *      system" alive in the one place the migration existed to remove it.
     */
    function test_SEAM_theDuelFundsTheNativePotByWrapping_notFundNative() public {
        uint256 a = bulls.mint(alice);
        uint256 b = bulls.mint(bob);

        // The passive side settles from its own credit, the way a native fight
        // works now — `msg.value` only ever covers the submitter's own stake.
        vm.prank(bob);
        duelN.deposit{value: 1 ether}();

        DuelNative.DuelResult memory r = _result(duelN, a, b, uint32(a));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_BNB;
        r.stakeB = STAKE_BNB;

        vm.recordLogs();
        _submit(alice, r, STAKE_BNB);

        // The slice arrived, and it arrived NATIVE.
        assertGt(newPot.pool(), 0, "the native pot was funded");
        assertEq(address(newPot).balance, newPot.pool(), "and it rests native");
        assertEq(wbnb.balanceOf(address(newPot)), 0, "no WBNB rests in the pot");

        // But it got there through a wrap. `PotSliceWrapped` is the receipt.
        bool wrapped;
        bytes32 topic = keccak256("PotSliceWrapped(uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) wrapped = true;
        }
        assertTrue(wrapped, "DuelNative still wraps; it does NOT call fundNative");
    }

    /**
     * @notice A fault in the ERC-20 pot must not touch the native one, in either
     *         order. `submitDuel` opens a ticket on BOTH and nudges BOTH resolve
     *         queues inside one transaction, and the BNBULL pot goes first.
     *
     * @dev The BNBULL pot is driven into the exact failure the incident log
     *      describes — a prize token that refuses the winner's transfer — while
     *      the native pot is asked to pay the same fight.
     */
    function test_SEAM_anErc20PotFaultCannotStopTheNativePot() public {
        vm.deal(owner, 100 ether);
        newPot.setFunder(owner, true);
        newPot.fundNative{value: 5 ether}("seed");

        // The BNBULL pot holds a prize it cannot deliver: fund it, then make the
        // token refuse outbound transfers to the winner.
        bnbull.mint(address(this), 1_000e18);
        potBnbull.setFunder(address(this), true);
        bnbull.approve(address(potBnbull), 1_000e18);
        potBnbull.fund(1_000e18, "seed");

        uint256 key = duelN.duelJackpotKey(31337);
        vm.startPrank(address(duelN));
        potBnbull.recordWin(alice, 1, 77, key);
        newPot.recordWin(alice, 1, 77, key);
        vm.stopPrank();

        // Resolve the native pot on a winning word. Nothing about the ERC-20
        // pot's state — wedged, unfunded or reverting — reaches this call.
        uint256 word = _winningWord(address(newPot), 77, 1, alice, 0);
        uint256 reqId = newPot.requestResolve(5);
        coord.fulfillTo(address(newPot), reqId, word);
        newPot.resolve(5);

        assertEq(newPot.owed(alice), 5 ether, "the native pot paid, in full");
        assertEq(newPot.totalOwed(), 5 ether, "and booked it");
        // The winner PULLS it. Nothing was pushed, so no receive() could revert.
        uint256 before = alice.balance;
        vm.prank(alice);
        newPot.withdrawAll();
        assertEq(alice.balance - before, 5 ether, "collected natively");
        assertEq(address(newPot).balance, 0, "and the pot is empty, not short");
    }

    /**
     * @notice The winner of a native jackpot is NOT paid — they are CREDITED,
     *         and must call `withdraw`. Nothing off-chain says so.
     *
     * @dev A behavioural break at the seam between the contracts and the product:
     *      `duel-bot.mjs` still announces "JUST TOOK THE ENTIRE POT" off the
     *      `Awarded` event, which now fires for a storage write. `Awarded` is
     *      byte-identical to the old one, so the bot cannot tell the difference.
     */
    function test_SEAM_awardedNoLongerMeansPaid() public {
        vm.deal(owner, 100 ether);
        newPot.setFunder(owner, true);
        newPot.fundNative{value: 3 ether}("seed");

        uint256 key = duelN.duelJackpotKey(8888);
        vm.prank(address(duelN));
        newPot.recordWin(bob, 2, 5, key);

        uint256 word = _winningWord(address(newPot), 5, 2, bob, 0);
        uint256 reqId = newPot.requestResolve(5);
        coord.fulfillTo(address(newPot), reqId, word);

        uint256 balBefore = bob.balance;
        newPot.resolve(5);

        assertEq(newPot.awardCount(), 1, "Awarded fired, exactly as before");
        assertEq(newPot.totalAwarded(), 3 ether, "for the full pot");
        assertEq(bob.balance, balBefore, "and the winner's wallet did not move");
        assertEq(newPot.owed(bob), 3 ether, "it is sitting in `owed`, unannounced");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════════════

    function _params(address signer) internal view returns (DuelNative.DeployParams memory) {
        return DuelNative.DeployParams({
            initialOwner: owner,
            bulls: address(bulls),
            bnbull: address(bnbull),
            wbnb: address(wbnb),
            trustedSigner: signer,
            devTreasury: duelTreasuryN,
            defaultDevShareBps: DEV_BPS
        });
    }

    function _oldParams(address signer) internal view returns (Duel.DeployParams memory) {
        return Duel.DeployParams({
            initialOwner: owner,
            bulls: address(bulls),
            bnbull: address(bnbull),
            wbnb: address(wbnb),
            trustedSigner: signer,
            devTreasury: duelTreasuryN,
            defaultDevShareBps: DEV_BPS
        });
    }

    function _result(DuelNative d, uint256 tokenA, uint256 tokenB, uint32 winnerId)
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
            seed: uint256(keccak256(abi.encodePacked("seam-seed", _nonceSeq))),
            newEloA: 1_050,
            newEloB: 950,
            assetA: address(0),
            assetB: address(0),
            stakeA: 0,
            stakeB: 0,
            seqA: d.nextFightSeq(oa),
            seqB: d.nextFightSeq(ob),
            nonce: _nonceSeq,
            expiry: block.timestamp + 1 hours
        });
    }

    function _submit(address who, DuelNative.DuelResult memory r, uint256 value) internal {
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, duelN.hashDuelResult(r));
        vm.prank(who);
        duelN.submitDuel{value: value}(r, abi.encodePacked(rs, ss, v));
    }

    /// @dev Mirrors `JackpotNative.resolve`'s preimage, `address(pot)` term and
    ///      all, so a change to it breaks these tests loudly.
    function _winningWord(
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id
    ) internal pure returns (uint256) {
        for (uint256 w = 1; w < 500_000; w++) {
            uint256 roll = uint256(
                keccak256(abi.encodePacked(w, entropy, tokenId, winner, id, pot))
            ) % NEW_ODDS;
            if (roll == 0) return w;
        }
        revert("no winning word");
    }
}
