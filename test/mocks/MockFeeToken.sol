// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeToken
 * @notice A fee-on-transfer token: the recipient always gets less than the
 *         sender sent.
 *
 * @dev This is the token class that breaks every "trust the number you asked
 *      for" assumption. `LEARNINGS-AND-MISTAKES §B` requires every swap and
 *      every pull to be booked as a MEASURED BALANCE DELTA precisely so a token
 *      like this cannot wedge a pot forever.
 */
contract MockFeeToken is ERC20 {
    address public constant SINK = address(0xFEE);

    uint256 public feeBps;

    constructor(uint256 _feeBps) ERC20("FeeOnTransfer", "FOT") {
        feeBps = _feeBps;
    }

    function setFeeBps(uint256 b) external {
        feeBps = b;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, SINK, fee);
    }
}
