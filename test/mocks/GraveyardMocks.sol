// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev `Graveyard`'s revive entrypoints, re-declared under a mock-specific
///      name. File-level declarations are hoisted into importers, so nothing
///      here may reuse `IMintDropDonate` or `IDuelStreak`.
interface IGraveyardUnderTest {
    function resurrectWithBNB(uint256 tokenId) external payable;
    function resurrectWithBNBULL(uint256 tokenId) external;
    function resurrectAndClaimWithBNB(uint256 tokenId) external payable;
    function resurrectsUsed(uint256 tokenId) external view returns (uint256);
}

/**
 * @notice A MintDrop whose donation entrypoints are down.
 *
 * @dev THE regression mock for the fefers bug in `Graveyard.sol`'s header: on
 *      fefers `MintDrop.donateJackpotBuy` was called with NO try/catch, so a
 *      reverting entrypoint bricked **every revive in the game** and the
 *      Graveyard was frozen so there was no fixing it from that side. Here the
 *      leg must defer and the revive must complete.
 */
contract GraveyardRevertingMintDrop {
    bool public nativeReverts = true;
    bool public tokenReverts = true;

    uint256 public nativeTaken;
    uint256 public tokenTaken;

    function setNativeReverts(bool b) external {
        nativeReverts = b;
    }

    function setTokenReverts(bool b) external {
        tokenReverts = b;
    }

    function donatePotNative() external payable {
        if (nativeReverts) revert("GraveyardRevertingMintDrop: native down");
        nativeTaken += msg.value;
    }

    function donatePotToken(address asset, uint256 amount) external {
        if (tokenReverts) revert("GraveyardRevertingMintDrop: token down");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        tokenTaken += amount;
    }
}

/**
 * @notice A MintDrop that accepts BNB and then hands it straight back.
 *
 * @dev The subtle failure `DECISIONS.md §19` describes from the other side: a
 *      donation target that re-enters its caller. `Graveyard._revive` holds
 *      `nonReentrant`, so any callback into a guarded Graveyard entrypoint
 *      must revert — and that revert must be swallowed into an accrual, never
 *      surface as a failed revive.
 */
contract GraveyardReentrantMintDrop {
    address public graveyard;
    uint256 public tokenIdToPoke;

    function configure(address g, uint256 tokenId) external {
        graveyard = g;
        tokenIdToPoke = tokenId;
    }

    function donatePotNative() external payable {
        IGraveyardUnderTest(graveyard).resurrectWithBNB{value: msg.value}(tokenIdToPoke);
    }

    function donatePotToken(address, uint256) external {
        IGraveyardUnderTest(graveyard).resurrectWithBNBULL(tokenIdToPoke);
    }
}

/**
 * @notice A player contract that tries to re-enter the Graveyard from inside
 *         the oracle-cushion refund.
 *
 * @dev The refund is the one call in `_revive` that hands control to an
 *      address of the caller's choosing, and it is deliberately dead last. A
 *      re-entrant frame must find `nonReentrant` closed and every piece of
 *      state already settled.
 */
contract GraveyardReentrantReviver {
    address public graveyard;
    uint256 public tokenId;
    bool public armed = true;

    bool public sawRefund;
    bool public reentryReverted;
    uint256 public usedAtRefund;

    function configure(address g, uint256 t) external {
        graveyard = g;
        tokenId = t;
    }

    function disarm() external {
        armed = false;
    }

    function revive(uint256 t) external payable {
        IGraveyardUnderTest(graveyard).resurrectWithBNB{value: msg.value}(t);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        sawRefund = true;
        usedAtRefund = IGraveyardUnderTest(graveyard).resurrectsUsed(tokenId);
        if (armed) {
            armed = false;
            (bool ok,) = graveyard.call{value: 0}(
                abi.encodeWithSignature("resurrectWithBNB(uint256)", tokenId)
            );
            reentryReverted = !ok;
        }
    }
}

/// @dev Counts BNB in and lets a test read it back. Stands in for a healthy LP
///      splitter.
contract GraveyardLpSink {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}
