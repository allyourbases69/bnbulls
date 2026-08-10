// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {JackpotNative} from "../../contracts/JackpotNative.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";
import {MockDuel} from "../mocks/Hostile.sol";

interface IRealWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/**
 * @title JackpotNativeWbnbForkTest
 * @notice The atomic unwrap inside `fund()`, against the REAL deployed BSC WBNB.
 *
 * @dev ⚠ THE MOCK CANNOT CATCH THIS CLASS OF BUG. `MockWBNB.withdraw` pays out
 *      with `.call{value:}`, which forwards all remaining gas. The canonical
 *      WETH9 that BSC's WBNB is forked from pays with `.transfer()`, which
 *      forwards a 2300 GAS STIPEND and nothing more. A `receive()` that does any
 *      real work — a storage write, an event with a dynamic argument — fits
 *      comfortably under `.call` and reverts under `.transfer`, so a pot that
 *      passes every mock test can still be unfundable on mainnet.
 *
 *      `JackpotNative.receive()` is deliberately empty for exactly this reason.
 *      This test is the proof, against the actual bytecode rather than a stand-in.
 */
contract JackpotNativeWbnbForkTest is Test {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    JackpotNative internal pot;
    MockVRFCoordinator internal coord;
    MockDuel internal mockDuel;
    address internal funder = address(0xF00D);

    function setUp() public {
        // Skip cleanly when no fork endpoint is configured, rather than failing
        // the suite for someone without an archive RPC.
        try vm.envString("BSC_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
        }

        coord = new MockVRFCoordinator();
        mockDuel = new MockDuel();
        pot = new JackpotNative(WBNB, address(this), address(coord), 75);
        pot.bootstrapDuel(address(mockDuel));
        pot.bootstrapPayoutParams(75, 10_000, 0);
        pot.setVrfConfig(bytes32(uint256(0xBEEF)), 1, 3, 200_000, true);
        pot.setFunder(funder, true);
        vm.deal(funder, 100 ether);
    }

    /// @dev THE CRUX. Real WBNB in, native out, in one call, measured.
    function test_fund_unwrapsAgainstRealWbnb() public {
        vm.startPrank(funder);
        IRealWBNB(WBNB).deposit{value: 5 ether}();
        assertEq(IRealWBNB(WBNB).balanceOf(funder), 5 ether, "wrapped");
        IRealWBNB(WBNB).approve(address(pot), 5 ether);

        uint256 potNativeBefore = address(pot).balance;
        pot.fund(5 ether, "fork-test");
        vm.stopPrank();

        assertEq(address(pot).balance - potNativeBefore, 5 ether, "native landed 1:1");
        assertEq(IRealWBNB(WBNB).balanceOf(address(pot)), 0, "nothing left wrapped");
        assertEq(pot.pool(), 5 ether, "pool is native");
        assertEq(pot.totalFunded(), 5 ether, "booked");
        assertEq(address(pot).balance, pot.pool() + pot.totalOwed(), "solvent");
    }

    /// @dev The gas stipend question, isolated: does the real token's payout
    ///      reach `receive()` at all under whatever it uses to send?
    function test_receive_survivesRealWbnbWithdrawStipend() public {
        vm.deal(address(pot), 0);
        vm.startPrank(funder);
        IRealWBNB(WBNB).deposit{value: 1 ether}();
        IRealWBNB(WBNB).transfer(address(pot), 1 ether);
        vm.stopPrank();

        // Permissionless: unwrap the stray directly, which is the same
        // `wbnb.withdraw` -> `receive()` path `fund` takes.
        pot.absorbStrayWbnb();

        assertEq(address(pot).balance, 1 ether, "receive() accepted the real payout");
        assertEq(IRealWBNB(WBNB).balanceOf(address(pot)), 0, "unwrapped");
        assertEq(address(pot).balance, pot.pool() + pot.totalOwed(), "solvent");
    }

    /// @dev A winner pulling a prize paid out of real unwrapped WBNB.
    function test_endToEnd_realWbnbFundedPrizeWithdrawsAsNative() public {
        vm.startPrank(funder);
        IRealWBNB(WBNB).deposit{value: 3 ether}();
        IRealWBNB(WBNB).approve(address(pot), 3 ether);
        pot.fund(3 ether, "fork-e2e");
        vm.stopPrank();

        address winner = address(0xBEEF01);
        uint256 id = pot.ticketCount();
        mockDuel.open(address(pot), winner, 1, 0xABC, 0);

        uint256 word;
        for (uint256 w = 1; w < 200_000; w++) {
            if (
                uint256(keccak256(abi.encodePacked(w, uint256(0xABC), uint256(1), winner, id, address(pot))))
                    % 75 == 0
            ) {
                word = w;
                break;
            }
        }
        require(word != 0, "no winning word");

        pot.setRequester(address(this), true);
        uint256 reqId = pot.requestResolve(5);
        coord.fulfillTo(address(pot), reqId, word);
        pot.resolve(5);

        assertEq(pot.owed(winner), 3 ether, "credited in native");

        uint256 before = winner.balance;
        vm.prank(winner);
        pot.withdrawAll();
        assertEq(winner.balance - before, 3 ether, "winner received BNB, never WBNB");
        assertEq(IRealWBNB(WBNB).balanceOf(winner), 0, "no wbnb ever touched the winner");
    }
}
