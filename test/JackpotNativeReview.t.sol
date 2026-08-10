// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ══════════════════════════════════════════════════════════════════════════
//  EXTERNAL SECURITY REVIEW — scratch harness, not part of the product suite.
//  Everything here assumes the authors were wrong.
// ══════════════════════════════════════════════════════════════════════════

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {JackpotNative} from "../contracts/JackpotNative.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {MockDuel} from "./mocks/Hostile.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @dev A FAITHFUL replica of the deployed BSC WBNB (WETH9 fork): `withdraw`
 *      pays with `.transfer()`, i.e. a HARD 2300-GAS STIPEND. The repo's
 *      MockWBNB uses `.call{value:}` and forwards all gas, so it cannot detect
 *      a `receive()` that is too expensive for mainnet.
 */
contract StipendWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount); // 2300 gas, exactly like WETH9
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev A WBNB that hands back LESS than asked. `_unwrap` must revert, not
///      silently book a short pot.
contract ShortWBNB is ERC20 {
    constructor() ERC20("Short", "SHORT") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount / 2}("");
        require(ok, "short");
    }

    receive() external payable {}
}

/// @dev A Duel whose exclusivity lock re-enters `resolve`. The shared guard
///      makes that call revert; `_claimDuel` reads a revert as DENIED.
contract ReentrantLockDuel {
    JackpotNative public pot;
    uint256 public calls;

    function setPot(address p) external {
        pot = JackpotNative(payable(p));
    }

    function open(address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        external
        returns (uint256)
    {
        return pot.recordWin(winner, tokenId, entropy, duelKey);
    }

    function claimJackpotForDuel(uint256) external returns (bool) {
        calls++;
        pot.resolve(1); // re-entrant: reverts on the shared guard
        return true;
    }
}

/// @dev A winner that re-enters `fundNative` from `receive()` during withdraw.
contract RefundingWinner {
    JackpotNative public pot;

    function setPot(address p) external {
        pot = JackpotNative(payable(p));
    }

    function pullAll() external {
        pot.withdrawAll();
    }

    receive() external payable {
        // Push the money straight back in as a donation while the outer
        // withdraw frame is still live.
        if (msg.sender == address(pot)) {
            (bool ok,) = address(pot).call{value: msg.value}("");
            ok;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════

contract JackpotNativeReviewTest is Test {
    JackpotNative internal pot;
    MockWBNB internal wbnb;
    MockVRFCoordinator internal coord;
    MockDuel internal mockDuel;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal funder = address(0xF00D);

    uint256 internal constant ODDS = 75;

    function setUp() public {
        wbnb = new MockWBNB();
        coord = new MockVRFCoordinator();
        mockDuel = new MockDuel();
        pot = new JackpotNative(address(wbnb), owner, address(coord), ODDS);
        pot.bootstrapDuel(address(mockDuel));
        pot.bootstrapPayoutParams(ODDS, 10_000, 0);
        pot.setVrfConfig(bytes32(uint256(0xBEEF)), 1, 3, 200_000, true);
        pot.setFunder(funder, true);
        pot.setRequester(owner, true);
        vm.deal(funder, 1000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _roll(uint256 w, uint256 e, uint256 tid, address win, uint256 id, address p, uint256 o)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(w, e, tid, win, id, p))) % o;
    }

    function _winWord(uint256 e, uint256 tid, address win, uint256 id, address p, uint256 o)
        internal
        pure
        returns (uint256)
    {
        for (uint256 w = 1; w < 500_000; w++) {
            if (_roll(w, e, tid, win, id, p, o) == 0) return w;
        }
        revert("no winning word");
    }

    function _fund(uint256 a) internal {
        vm.prank(funder);
        pot.fundNative{value: a}("t");
    }

    function _openAndFulfil(address winner, uint256 e, uint256 tid, uint256 key)
        internal
        returns (uint256 id)
    {
        id = pot.ticketCount();
        mockDuel.open(address(pot), winner, tid, e, key);
        uint256 word = _winWord(e, tid, winner, id, address(pot), ODDS);
        uint256 req = pot.requestResolve(20);
        coord.fulfillTo(address(pot), req, word);
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. THE GAS-STIPEND TRAP, offline (the fork test never runs in CI)
    // ══════════════════════════════════════════════════════════════════

    function test_REVIEW_fund_survivesRealWbnbTransferStipend() public {
        StipendWBNB real = new StipendWBNB();
        JackpotNative p = new JackpotNative(address(real), owner, address(coord), ODDS);
        p.bootstrapDuel(address(mockDuel));
        p.bootstrapPayoutParams(ODDS, 10_000, 0);
        p.setVrfConfig(bytes32(uint256(0xBEEF)), 1, 3, 200_000, true);
        p.setFunder(funder, true);

        vm.startPrank(funder);
        real.deposit{value: 5 ether}();
        real.approve(address(p), 5 ether);
        p.fund(5 ether, "stipend");
        vm.stopPrank();

        assertEq(address(p).balance, 5 ether, "unwrap must survive a 2300-gas stipend");
        assertEq(p.pool(), 5 ether);
    }

    function test_REVIEW_absorbStray_survivesStipend() public {
        StipendWBNB real = new StipendWBNB();
        JackpotNative p = new JackpotNative(address(real), owner, address(coord), ODDS);

        vm.startPrank(alice);
        real.deposit{value: 2 ether}();
        real.transfer(address(p), 2 ether);
        vm.stopPrank();

        p.absorbStrayWbnb();
        assertEq(address(p).balance, 2 ether);
    }

    function test_REVIEW_shortWrapperReverts() public {
        ShortWBNB shortW = new ShortWBNB();
        JackpotNative p = new JackpotNative(address(shortW), owner, address(coord), ODDS);
        p.setFunder(funder, true);

        vm.startPrank(funder);
        shortW.deposit{value: 4 ether}();
        shortW.approve(address(p), 4 ether);
        vm.expectRevert();
        p.fund(4 ether, "short");
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. VRF: replay, double-consume, cancel race
    // ══════════════════════════════════════════════════════════════════

    function test_REVIEW_wordCannotBeDeliveredTwice() public {
        _fund(10 ether);
        uint256 id = pot.ticketCount();
        mockDuel.open(address(pot), alice, 1, 42, 0);
        uint256 word = _winWord(42, 1, alice, id, address(pot), ODDS);

        uint256 req = pot.requestResolve(1);
        coord.fulfillTo(address(pot), req, word);
        // Second delivery of the SAME id must be a no-op.
        coord.fulfillTo(address(pot), req, word);

        pot.resolve(5);
        assertEq(pot.owed(alice), 10 ether, "paid exactly once");
        assertEq(pot.totalOwed(), 10 ether);
        assertEq(address(pot).balance, pot.pool() + pot.totalOwed());
    }

    function test_REVIEW_cancelledRequestLateWordIsDropped() public {
        _fund(10 ether);
        uint256 id = pot.ticketCount();
        mockDuel.open(address(pot), alice, 1, 42, 0);
        uint256 word = _winWord(42, 1, alice, id, address(pot), ODDS);

        uint256 req = pot.requestResolve(1);
        vm.roll(block.number + pot.requestTimeoutBlocks() + 1);
        pot.cancelStalledRequest();

        coord.fulfillTo(address(pot), req, word);
        assertFalse(pot.wordReady(), "a cancelled request's word must be dropped");
    }

    /// @dev Can a ticket be resolved twice across two batches? The cursor is
    ///      global, so no — prove it.
    function test_REVIEW_ticketCannotResolveTwice() public {
        _fund(10 ether);
        uint256 id = _openAndFulfil(alice, 42, 1, 0);
        pot.resolve(5);
        uint256 owedAfter = pot.owed(alice);
        assertEq(owedAfter, 10 ether);

        // A brand new batch cannot reach ticket `id` again.
        mockDuel.open(address(pot), bob, 2, 43, 0);
        uint256 req = pot.requestResolve(20);
        coord.fulfillTo(address(pot), req, _winWord(42, 1, alice, id, address(pot), ODDS));
        pot.resolve(20);
        assertEq(pot.owed(alice), owedAfter, "ticket 0 must not pay a second time");
        assertEq(address(pot).balance, pot.pool() + pot.totalOwed());
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. THEFT SURFACE
    // ══════════════════════════════════════════════════════════════════

    /// @dev Nobody may touch another wallet's credited prize.
    function test_REVIEW_cannotStealAnotherWalletsOwed() public {
        _fund(6 ether);
        _openAndFulfil(alice, 0x11, 5, 0);
        pot.resolve(5);
        assertEq(pot.owed(alice), 6 ether);

        vm.prank(bob);
        vm.expectRevert();
        pot.withdrawAll();

        vm.prank(bob);
        vm.expectRevert();
        pot.withdraw(1);

        assertEq(pot.owed(alice), 6 ether, "alice's prize untouched");
    }

    /// @dev Every owner-reachable selector, hammered against a funded pot.
    function test_REVIEW_ownerCannotReachNative() public {
        _fund(25 ether);
        uint256 before = owner.balance;

        pot.setFunder(owner, true);
        pot.setRequester(owner, true);
        pot.setWiringDelay(6 hours);
        pot.setTimeouts(1, 1);
        pot.setSocials("x", "y", "z");
        pot.proposeDuel(address(0xD1));
        pot.cancelDuel();
        pot.proposeCoordinator(address(coord));
        pot.cancelCoordinator();
        pot.proposePayoutParams(10, 10_000, 0);
        pot.cancelPayoutParams();
        pot.setVrfConfig(bytes32(uint256(1)), 2, 3, 100_000, false);

        // sweep of a foreign token cannot reach native
        MockERC20 junk = new MockERC20("J", "J", 18);
        junk.mint(address(pot), 5e18);
        pot.sweepForeignToken(address(junk), owner, 5e18);

        // sweeping the pot itself as if it were a token must not work
        vm.expectRevert();
        pot.sweepForeignToken(address(pot), owner, 1 ether);

        assertEq(address(pot).balance, 25 ether, "native untouched");
        assertEq(owner.balance, before, "owner gained no native");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. WEDGING / GUARD NESTING
    // ══════════════════════════════════════════════════════════════════

    /**
     * @dev ⚠ The lock contract re-enters `resolve`. Under the shared guard the
     *      re-entrant call REVERTS, the low-level `_claimDuel` sees `ok=false`
     *      and treats it as DENIED. The batch survives (good) but the winner is
     *      silently paid nothing. Quantify it.
     */
    function test_REVIEW_lockThatReentersResolveDeniesEveryWin() public {
        ReentrantLockDuel lock = new ReentrantLockDuel();
        JackpotNative p = new JackpotNative(address(wbnb), owner, address(coord), ODDS);
        lock.setPot(address(p));
        p.bootstrapDuel(address(lock));
        p.bootstrapPayoutParams(ODDS, 10_000, 0);
        p.setVrfConfig(bytes32(uint256(0xBEEF)), 1, 3, 200_000, true);
        p.setFunder(funder, true);
        p.setRequester(owner, true);

        vm.prank(funder);
        p.fundNative{value: 9 ether}("t");

        uint256 id = lock.open(alice, 1, 42, 777);
        uint256 word = _winWord(42, 1, alice, id, address(p), ODDS);
        uint256 req = p.requestResolve(5);
        coord.fulfillTo(address(p), req, word);

        uint256 resolved = p.resolve(5);
        assertEq(resolved, 1, "batch still completes");
        console2.log("owed after a reverting lock:", p.owed(alice));
        console2.log("lock calls:", lock.calls());
    }

    /// @dev A winner that pushes the prize straight back in from `receive()`.
    ///      The ledger must not drift.
    function test_REVIEW_winnerDonatesBackInsideWithdraw() public {
        RefundingWinner w = new RefundingWinner();
        w.setPot(address(pot));
        _fund(7 ether);
        _openAndFulfil(address(w), 0x22, 6, 0);
        pot.resolve(5);
        assertEq(pot.owed(address(w)), 7 ether);

        w.pullAll();

        assertEq(pot.owed(address(w)), 0, "ledger cleared");
        assertEq(pot.totalOwed(), 0, "totalOwed cleared");
        assertEq(address(pot).balance, 7 ether, "money came straight back as a donation");
        assertEq(pot.pool(), 7 ether, "and it is pot money now");
        assertEq(address(pot).balance, pot.pool() + pot.totalOwed());
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. THE minPoolToFire GATE vs A PERMISSIONLESS receive()
    // ══════════════════════════════════════════════════════════════════

    /**
     * @dev The deploy script sets `minPoolToFire = 0.0168 ether`. The word is
     *      PUBLIC once fulfilled and `resolve` is permissionless, so a player
     *      who can see their own ticket rolled a 0 can top the pot over the
     *      floor themselves and collect. Measure the size of that.
     */
    function test_REVIEW_floorCanBeCrossedAfterTheWordIsPublic() public {
        pot.proposePayoutParams(ODDS, 10_000, 5 ether);
        vm.warp(block.timestamp + 25 hours);
        pot.commitPayoutParams();

        _fund(4 ether); // under the floor
        uint256 id = pot.ticketCount();
        mockDuel.open(address(pot), alice, 1, 42, 0);
        uint256 word = _winWord(42, 1, alice, id, address(pot), ODDS);
        uint256 req = pot.requestResolve(1);
        coord.fulfillTo(address(pot), req, word);

        // The word is now public storage. Anyone can compute the roll.
        assertEq(pot.resolveWord(), word);

        // Alice tops the pot over the floor with her own money, then resolves.
        uint256 aliceStart = alice.balance;
        vm.prank(alice);
        (bool ok,) = address(pot).call{value: 1 ether}("");
        assertTrue(ok);

        vm.prank(alice);
        pot.resolve(1);
        vm.prank(alice);
        pot.withdrawAll();

        // She spent 1, took 5 -> +4 of other players' money, from a pot the
        // floor said was not allowed to fire.
        assertEq(alice.balance, aliceStart + 4 ether, "floor bypassed for a net +4");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. THE PREIMAGE SEPARATION TEST THE SUITE ONLY PRETENDS TO MAKE
    // ══════════════════════════════════════════════════════════════════

    /// @dev The shipped `test_addressThisInRollPreimage` asserts `a != b || true`
    ///      which is a tautology. This is the real assertion.
    function test_REVIEW_twoPotsRollDifferently() public {
        JackpotNative p2 = new JackpotNative(address(wbnb), owner, address(coord), ODDS);
        uint256 differing;
        for (uint256 w = 1; w <= 300; w++) {
            uint256 a = _roll(w, 1, 2, alice, 0, address(pot), ODDS);
            uint256 b = _roll(w, 1, 2, alice, 0, address(p2), ODDS);
            if (a != b) differing++;
        }
        assertGt(differing, 250, "two pots must not share a preimage");
    }
}

// ══════════════════════════════════════════════════════════════════════════
//  7. GHOST-ACCOUNTED SOLVENCY INVARIANT
//     The shipped invariant asserts `balance == pool() + totalOwed`, which is
//     the DEFINITION of pool() and therefore near-tautological. This one
//     tracks money in and out independently, and sums `owed` over every actor.
// ══════════════════════════════════════════════════════════════════════════

contract GhostHandler is Test {
    JackpotNative public pot;
    MockWBNB public wbnb;
    MockVRFCoordinator public coord;
    MockDuel public mockDuel;

    address[] public actors;
    uint256 public ghostIn;
    uint256 public ghostOut;

    constructor(
        JackpotNative _pot,
        MockWBNB _wbnb,
        MockVRFCoordinator _coord,
        MockDuel _duel,
        address[] memory _actors
    ) {
        pot = _pot;
        wbnb = _wbnb;
        coord = _coord;
        mockDuel = _duel;
        actors = _actors;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function fundNative(uint256 amt) external {
        amt = bound(amt, 1, 5 ether);
        vm.deal(address(this), address(this).balance + amt);
        pot.fundNative{value: amt}("g");
        ghostIn += amt;
    }

    function fundWrapped(uint256 amt) external {
        amt = bound(amt, 1, 5 ether);
        vm.deal(address(this), address(this).balance + amt);
        wbnb.deposit{value: amt}();
        wbnb.approve(address(pot), amt);
        pot.fund(amt, "g");
        ghostIn += amt;
    }

    function donate(uint256 amt) external {
        amt = bound(amt, 1, 2 ether);
        vm.deal(address(this), address(this).balance + amt);
        (bool ok,) = address(pot).call{value: amt}("");
        require(ok);
        ghostIn += amt;
    }

    function absorbStray(uint256 amt) external {
        amt = bound(amt, 1, 1 ether);
        vm.deal(address(this), address(this).balance + amt);
        wbnb.deposit{value: amt}();
        wbnb.transfer(address(pot), amt);
        pot.absorbStrayWbnb();
        ghostIn += amt;
    }

    function openTicket(uint256 seed, uint256 entropy) external {
        mockDuel.open(address(pot), _actor(seed), seed % 300, entropy, 0);
    }

    function requestAndFulfil(uint256 maxT, uint256 word) external {
        maxT = bound(maxT, 1, 20);
        if (!pot.requestable()) return;
        uint256 next = pot.nextToResolve();
        uint256 id = pot.requestResolve(maxT);
        if (word % 2 == 0) {
            uint256 forced = _winningWordFor(next);
            if (forced != 0) word = forced;
        }
        coord.fulfillTo(address(pot), id, word);
    }

    function _winningWordFor(uint256 ticketId) internal view returns (uint256) {
        if (ticketId >= pot.ticketCount()) return 0;
        (address w,, uint256 tokenId, uint256 entropy,) = pot.tickets(ticketId);
        uint256 odds = pot.oddsOneIn();
        for (uint256 c = 1; c < 5_000; c++) {
            uint256 r = uint256(
                keccak256(abi.encodePacked(c, entropy, tokenId, w, ticketId, address(pot)))
            ) % odds;
            if (r == 0) return c;
        }
        return 0;
    }

    function doResolve(uint256 maxR) external {
        maxR = bound(maxR, 1, 20);
        try pot.resolve(maxR) {} catch {}
    }

    function withdrawPart(uint256 seed, uint256 frac) external {
        address a = _actor(seed);
        uint256 held = pot.owed(a);
        if (held == 0) return;
        uint256 amt = bound(frac, 1, held);
        vm.prank(a);
        pot.withdraw(amt);
        ghostOut += amt;
    }

    function withdrawAll(uint256 seed) external {
        address a = _actor(seed);
        uint256 held = pot.owed(a);
        if (held == 0) return;
        vm.prank(a);
        pot.withdrawAll();
        ghostOut += held;
    }

    function cancelStalled(uint256 jump) external {
        if (pot.pendingRequestId() == 0) return;
        vm.roll(block.number + bound(jump, 1, 50_000));
        try pot.cancelStalledRequest() {} catch {}
    }

    function sumOwed() external view returns (uint256 s) {
        for (uint256 i; i < actors.length; i++) {
            s += pot.owed(actors[i]);
        }
    }

    receive() external payable {}
}

contract JackpotNativeGhostInvariantTest is StdInvariant, Test {
    JackpotNative internal pot;
    MockWBNB internal wbnb;
    MockVRFCoordinator internal coord;
    MockDuel internal mockDuel;
    GhostHandler internal h;

    uint256 internal constant ODDS = 75;

    function setUp() public {
        wbnb = new MockWBNB();
        coord = new MockVRFCoordinator();
        mockDuel = new MockDuel();
        pot = new JackpotNative(address(wbnb), address(this), address(coord), ODDS);
        pot.bootstrapDuel(address(mockDuel));
        pot.bootstrapPayoutParams(ODDS, 10_000, 0);
        pot.setVrfConfig(bytes32(uint256(0xBEEF)), 1, 3, 200_000, true);

        address[] memory actors = new address[](4);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCAFE);
        actors[3] = address(0xD00D);

        h = new GhostHandler(pot, wbnb, coord, mockDuel, actors);
        pot.setFunder(address(h), true);
        pot.setRequester(address(h), true);
        vm.deal(address(h), 5000 ether);

        bytes4[] memory sel = new bytes4[](10);
        sel[0] = GhostHandler.fundNative.selector;
        sel[1] = GhostHandler.fundWrapped.selector;
        sel[2] = GhostHandler.donate.selector;
        sel[3] = GhostHandler.absorbStray.selector;
        sel[4] = GhostHandler.openTicket.selector;
        sel[5] = GhostHandler.requestAndFulfil.selector;
        sel[6] = GhostHandler.doResolve.selector;
        sel[7] = GhostHandler.withdrawPart.selector;
        sel[8] = GhostHandler.withdrawAll.selector;
        sel[9] = GhostHandler.cancelStalled.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 200
    /// forge-config: default.invariant.depth = 100
    function invariant_ghostBalanceIsExact() public view {
        assertEq(address(pot).balance, h.ghostIn() - h.ghostOut(), "balance != in - out");
    }

    function invariant_totalOwedEqualsSumOfOwed() public view {
        assertEq(pot.totalOwed(), h.sumOwed(), "totalOwed != sum(owed)");
    }

    function invariant_balanceCoversOwed() public view {
        assertGe(address(pot).balance, pot.totalOwed(), "INSOLVENT: balance < totalOwed");
    }

    function invariant_awardedCoversOwedPlusPaid() public view {
        assertLe(pot.totalOwed(), pot.totalAwarded(), "credit conjured from nothing");
    }

    function afterInvariant() public view {
        console2.log("== REVIEW ghost campaign ==");
        console2.log("tickets opened :", pot.ticketCount());
        console2.log("resolved       :", pot.nextToResolve());
        console2.log("awards         :", pot.awardCount());
        console2.log("ghostIn        :", h.ghostIn());
        console2.log("ghostOut       :", h.ghostOut());
        console2.log("balance        :", address(pot).balance);
        console2.log("totalOwed      :", pot.totalOwed());
    }
}
