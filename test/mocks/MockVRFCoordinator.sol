// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVRFCoordinatorV2Plus} from
    "@chainlink/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/**
 * @title MockVRFCoordinator
 * @notice A VRF v2.5 coordinator you drive by hand: request now, `fulfill`
 *         whenever the test wants, or never.
 *
 * @dev The "never" case matters as much as the happy one — `Jackpot` documents
 *      that if VRF stays dark forever the money sits in the pool, which is the
 *      correct failure mode for a pot with no withdraw path. Nobody can take
 *      it, including us.
 */
contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 public nextRequestId = 1;
    uint256 public requestCount;
    bool public revertOnRequest;

    mapping(uint256 => address) public consumerOf;
    /// @notice The keyHash / subId / confirmations the live request was made
    ///         with, so a test can prove config cannot move mid-flight.
    mapping(uint256 => bytes32) public keyHashOf;
    mapping(uint256 => uint256) public subIdOf;
    mapping(uint256 => bool) public nativePaymentOf;

    function setRevertOnRequest(bool b) external {
        revertOnRequest = b;
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req)
        external
        returns (uint256 requestId)
    {
        if (revertOnRequest) revert("MockVRF: coordinator down");
        requestId = nextRequestId++;
        requestCount += 1;
        consumerOf[requestId] = msg.sender;
        keyHashOf[requestId] = req.keyHash;
        subIdOf[requestId] = req.subId;
        nativePaymentOf[requestId] = _decodeNative(req.extraArgs);
    }

    /// @notice Deliver the word. Anyone may call it on the mock; the consumer
    ///         only accepts it because it comes from this address.
    function fulfill(uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumer(consumerOf[requestId]).rawFulfillRandomWords(requestId, words);
    }

    function fulfillTo(address consumer, uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }

    function _decodeNative(bytes memory extraArgs) private pure returns (bool) {
        if (extraArgs.length < 36) return false;
        // 4-byte tag then an abi-encoded ExtraArgsV1{bool}
        bytes memory tail = new bytes(extraArgs.length - 4);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = extraArgs[i + 4];
        }
        VRFV2PlusClient.ExtraArgsV1 memory a =
            abi.decode(tail, (VRFV2PlusClient.ExtraArgsV1));
        return a.nativePayment;
    }

    // ─── IVRFSubscriptionV2Plus: unused by the consumer, stubbed ──────────

    function addConsumer(uint256, address) external {}
    function removeConsumer(uint256, address) external {}
    function cancelSubscription(uint256, address) external {}
    function acceptSubscriptionOwnerTransfer(uint256) external {}
    function requestSubscriptionOwnerTransfer(uint256, address) external {}

    function createSubscription() external pure returns (uint256) {
        return 1;
    }

    function getSubscription(uint256)
        external
        pure
        returns (uint96, uint96, uint64, address, address[] memory)
    {
        address[] memory c = new address[](0);
        return (0, 0, 0, address(0), c);
    }

    function pendingRequestExists(uint256) external pure returns (bool) {
        return false;
    }

    function getActiveSubscriptionIds(uint256, uint256)
        external
        pure
        returns (uint256[] memory)
    {
        return new uint256[](0);
    }

    function fundSubscriptionWithNative(uint256) external payable {}
}

/**
 * @notice A coordinator the caller fully controls the output of.
 *
 * @dev ⚠ THIS IS NOT A CONVENIENCE MOCK — it is the exploit harness for the
 *      finding in `JackpotNoWithdraw.t.sol`. `VRFConsumerBaseV2Plus.
 *      setCoordinator` is owner-callable with NO timelock, so the owner can
 *      repoint the randomness source at this contract and hand-pick the word
 *      that decides a batch.
 */
contract EvilVRFCoordinator is MockVRFCoordinator {}
