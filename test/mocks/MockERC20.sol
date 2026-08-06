// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain mintable ERC-20 with configurable decimals.
///      ⚠ `decimals` is a constructor argument on purpose. `BNB-CHAIN-FACTS §1`
///      warns that BSC-USDT is 18dp while ethereum/tron USDT is 6dp, and the
///      fefers "everything is 6dp" rule is wrong here in the expensive
///      direction. Nothing in these tests may assume a decimals value.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev A token whose `transfer` always reverts. Stands in for a paused or
///      blacklisting prize token on the never-fail paths.
contract RevertingERC20 is ERC20 {
    bool public transfersBroken = true;

    constructor() ERC20("Broken", "BRK") {}

    function setBroken(bool b) external {
        transfersBroken = b;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (transfersBroken && from != address(0)) revert("RevertingERC20: nope");
        super._update(from, to, value);
    }
}

/// @dev No `decimals()` at all. Wiring this as the stablecoin or the price feed
///      must fail the WIRING transaction, not the first mint.
contract NoDecimalsToken {
    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}
