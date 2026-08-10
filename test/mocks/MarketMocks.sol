// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title MarketMocks
 * @notice Fixtures for `Marketplace.sol`.
 *
 * @dev ⚠ NO MAINNET FORK. Mocks only — the marketplace's dangerous
 *      counterparties are a seller with an awkward receiver, a jackpot sink
 *      with no BNBULL pool behind it, and a re-entrant buyer, and none of those
 *      can be summoned on demand against a live chain.
 */

/// @dev The generic driver every contract fixture here implements, so a test
///      can list / cancel / approve / withdraw from inside a contract without
///      the mock re-declaring the marketplace's ABI.
interface IMarketExec {
    function exec(address target, bytes calldata data) external returns (bytes memory);
}

/**
 * @notice A contract seller. Holds a bull, drives the marketplace through
 *         `exec`, and can be made to refuse native or to BURN GAS on receipt.
 *
 * @dev Both are real griefs. A seller who cannot receive would otherwise make
 *      their own listing unbuyable; a seller who burns gas would charge the
 *      BUYER for the privilege. `Marketplace._payNative` forwards a bounded
 *      stipend and falls back to `nativeCredit`, so neither works.
 */
contract MarketAwkwardSeller is IERC721Receiver {
    bool public accepts;
    bool public burnGas;
    uint256 public received;

    function setAccepts(bool b) external {
        accepts = b;
    }

    function setBurnGas(bool b) external {
        burnGas = b;
    }

    /// @dev Bubbles the callee's own revert data, so a test can still assert on
    ///      the marketplace's custom errors through this hop.
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (burnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        if (!accepts) revert("MarketAwkwardSeller: no thanks");
        received += msg.value;
    }
}

/**
 * @notice A jackpot sink that can fail in every way the real one will.
 *
 * @dev The important mode is `takeTokens = false`: it implements
 *      `donatePotToken` and RETURNS NORMALLY having moved nothing — which is
 *      exactly what `PotSplitter.donatePotToken` does when its own pull fails
 *      (it emits `PullFailed` rather than reverting). A successful call is
 *      therefore not evidence that anything moved, which is why the marketplace
 *      books the MEASURED BALANCE DELTA.
 */
contract MarketHostileSink {
    bool public takeTokens;
    bool public revertOnNative;
    bool public revertOnToken;
    uint256 public nativeTaken;

    function setTakeTokens(bool b) external {
        takeTokens = b;
    }

    function setRevertOnNative(bool b) external {
        revertOnNative = b;
    }

    function setRevertOnToken(bool b) external {
        revertOnToken = b;
    }

    function donatePotToken(address asset, uint256 amount) external {
        if (revertOnToken) revert("MarketHostileSink: closed");
        if (takeTokens) IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    receive() external payable {
        if (revertOnNative) revert("MarketHostileSink: closed");
        nativeTaken += msg.value;
    }
}

/**
 * @notice A buyer that re-enters `buyWithBNB` from `onERC721Received` and
 *         records whether the inner attempt got anywhere.
 *
 * @dev Two independent defences should stop it: `nonReentrant`, and CEI — the
 *      listing is deleted before any external call, so a re-entrant frame finds
 *      nothing to double-spend. The inner failure is SWALLOWED here so the test
 *      can assert the outer sale still completes.
 */
contract MarketReentrantBuyer is IERC721Receiver {
    address public market;
    bool public armed = true;
    bool public innerSucceeded;
    uint256 public innerAttempts;

    function setMarket(address m) external {
        market = m;
    }

    function disarm() external {
        armed = false;
    }

    function buy(uint256 tokenId, uint256 value) external {
        (bool ok,) = market.call{value: value}(
            abi.encodeWithSignature(
                "buyWithBNB(uint256,uint256,uint256)",
                tokenId,
                type(uint256).max,
                type(uint256).max
            )
        );
        require(ok, "MarketReentrantBuyer: outer buy failed");
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (armed) {
            armed = false;
            innerAttempts += 1;
            (bool ok,) = market.call{value: address(this).balance}(
                abi.encodeWithSignature(
                "buyWithBNB(uint256,uint256,uint256)",
                tokenId,
                type(uint256).max,
                type(uint256).max
            )
            );
            innerSucceeded = ok;
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A plain contract with no `receive()` at all — the commonest awkward
///      seller in the wild (a multisig mid-upgrade, a proxy without a fallback).
contract MarketBlindReceiver is IERC721Receiver {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
