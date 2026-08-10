// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {IERC20Fork} from "./ForkInterfaces.sol";

/**
 * @title DuelNativeWrapForkTest
 * @notice The one place `DuelNative` touches real WBNB, proved against the
 *         deployed bytecode rather than a mock.
 *
 * @dev WHY THIS FILE EXISTS. `DuelNative` moves the whole game to native BNB
 *      and leaves exactly one WBNB boundary: `routePotSliceInline` wraps the
 *      dev-cut pot slice, because `Jackpot.prizeToken` is `immutable` WBNB. A
 *      mock WBNB is written to be agreeable. The deployed one is not:
 *
 *        - `withdraw()` pays out with `.transfer()`, a 2300-gas stipend. Any
 *          `receive()` that does real work is UNFUNDABLE by it while passing
 *          every mock test in the suite.
 *        - `deposit()` credits `msg.sender`, so who calls it matters.
 *
 *      `DuelNative` is safe from the stipend trap by construction — it never
 *      unwraps, so real WBNB never sends native back into its `receive()`. That
 *      is an argument, and arguments rot. This measures it instead, and the
 *      last test FAILS THE BUILD if an unwrap path is ever introduced without
 *      someone re-reading the stipend problem.
 */
contract DuelNativeWrapForkTest is ForkBase {
    /// @dev The credit ledger's `receive()` does a storage write, which is an
    ///      order of magnitude past the 2300-gas stipend. Stand-in for it.
    StorageWritingReceiver internal receiver;

    function setUp() public override {
        super.setUp();
        receiver = new StorageWritingReceiver();
    }

    /// @notice The wrap itself: 1:1, no router, no liquidity, against the real
    ///         token. This is the operation `routePotSliceInline` performs.
    function test_realWbnb_depositIsOneToOneAndCreditsTheCaller() public {
        uint256 amount = 3 ether;
        vm.deal(address(this), amount);

        uint256 before = IERC20Fork(A.WBNB).balanceOf(address(this));
        wbnb.deposit{value: amount}();
        uint256 got = IERC20Fork(A.WBNB).balanceOf(address(this)) - before;

        assertEq(got, amount, "real WBNB did not mint 1:1 on deposit");
        emit log_named_uint("real WBNB minted for 3 BNB (wei)", got);
    }

    /// @notice The measured wrap gas, so the pot-slice leg's try/catch budget
    ///         is sized off a real number rather than a guess.
    function test_realWbnb_depositGasIsModest() public {
        vm.deal(address(this), 1 ether);
        uint256 g0 = gasleft();
        wbnb.deposit{value: 1 ether}();
        uint256 used = g0 - gasleft();
        emit log_named_uint("real WBNB deposit gas", used);
        assertLt(used, 60_000, "wrap unexpectedly expensive: re-check the pot-leg gas budget");
    }

    /// @notice ⚠ THE TRAP, MEASURED. Real WBNB's `withdraw` pays with
    ///         `.transfer()` and its 2300-gas stipend. A recipient whose
    ///         `receive()` writes storage CANNOT be paid by it — and a mock
    ///         that uses `.call{value:}` forwards all gas and hides this
    ///         completely.
    ///
    ///         `DuelNative.receive()` writes storage (`_addCredit`). So if an
    ///         unwrap path is ever added, the contract becomes unfundable by
    ///         its own unwrap. This proves the hazard is real on mainnet.
    function test_realWbnb_withdrawCannotPayAStorageWritingReceiver() public {
        vm.deal(address(receiver), 2 ether);
        receiver.wrap(A.WBNB, 2 ether);
        assertEq(IERC20Fork(A.WBNB).balanceOf(address(receiver)), 2 ether, "wrapped");

        // The stipend is not enough for a storage write: the unwrap reverts.
        vm.expectRevert();
        receiver.unwrap(A.WBNB, 2 ether);

        emit log_string(
            "CONFIRMED on mainnet bytecode: real WBNB.withdraw cannot pay a receive() that writes storage"
        );
    }

    /// @notice THE GUARD. `DuelNative` is safe only because it never unwraps.
    ///         If someone adds an unwrap later, this fails and sends them to
    ///         the test above before they ship an unfundable contract.
    function test_duelNativeMustNeverUnwrap() public view {
        string memory src = vm.readFile("contracts/DuelNative.sol");
        assertFalse(
            vm.contains(src, "wbnb.withdraw("),
            "DuelNative now UNWRAPS. Real WBNB pays with a 2300-gas stipend and this contract's receive() writes storage, so the unwrap will revert on mainnet. See test_realWbnb_withdrawCannotPayAStorageWritingReceiver."
        );
    }
}

/// @dev Mirrors the shape of `DuelNative.receive()`: it writes storage, which
///      is what the 2300-gas stipend cannot afford.
contract StorageWritingReceiver {
    mapping(address => uint256) public credit;
    uint256 public total;

    function wrap(address w, uint256 amount) external {
        (bool ok,) = w.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(ok, "wrap failed");
    }

    function unwrap(address w, uint256 amount) external {
        (bool ok,) = w.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        require(ok, "unwrap failed");
    }

    receive() external payable {
        // Exactly the shape of the credit ledger: a cold SSTORE, ~20k gas.
        credit[msg.sender] += msg.value;
        total += msg.value;
    }
}
