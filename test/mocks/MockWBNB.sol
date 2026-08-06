// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockWBNB
 * @notice Wrapped BNB. `deposit()` is 1:1 — a WRAP, not a swap.
 *
 * @dev This is why `DECISIONS.md §13`'s "a BNB payment routes straight into the
 *      pot with no DEX interaction at all" survives the fact that the BNB pot
 *      actually holds WBNB: no router, no slippage, no liquidity dependency.
 */
contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWBNB: withdraw failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev A WBNB whose `deposit()` reverts. The BNB pot leg is the one leg that
///      is supposed to be un-failable, so prove even THAT defers rather than
///      bricking a revive.
contract BrokenWBNB is ERC20 {
    constructor() ERC20("Broken WBNB", "bWBNB") {}

    function deposit() external payable {
        revert("BrokenWBNB: deposit down");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
