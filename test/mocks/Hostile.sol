// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IJackpotLike {
    function recordWin(address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        external
        returns (uint256);
    function resolve(uint256 max) external returns (uint256);
    function sweepForeignToken(address token, address to, uint256 amount) external;
    function pool() external view returns (uint256);
}

/**
 * @notice Stands in for the real `Duel`, which another agent is writing.
 * @dev Two jobs: open tickets (only the wired duel may), and arbitrate the
 *      one-pot-per-duel lock. First caller to claim a key wins it.
 */
contract MockDuel {
    mapping(uint256 => address) public claimedBy;
    bool public alwaysDeny;
    bool public claimReverts;

    function setAlwaysDeny(bool b) external {
        alwaysDeny = b;
    }

    function setClaimReverts(bool b) external {
        claimReverts = b;
    }

    function claimJackpotForDuel(uint256 duelKey) external returns (bool) {
        if (claimReverts) revert("MockDuel: lock down");
        if (alwaysDeny) return false;
        if (claimedBy[duelKey] != address(0)) return false;
        claimedBy[duelKey] = msg.sender;
        return true;
    }

    function open(address pot, address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        external
        returns (uint256)
    {
        return IJackpotLike(pot).recordWin(winner, tokenId, entropy, duelKey);
    }
}

/// @dev A "duel" whose lock call returns garbage instead of a bool. `_claimDuel`
///      must treat that as DENIED and must not revert the resolve loop.
contract GarbageDuel {
    function claimJackpotForDuel(uint256) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

/// @dev Reverting `receive()`. The treasury/LP slot that has gone bad.
contract RevertingReceiver {
    receive() external payable {
        revert("RevertingReceiver: no");
    }
}

/// @dev Accepts BNB and counts it.
contract PayableSink {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/**
 * @notice A fake "foreign token" whose `transfer` re-enters the Jackpot and
 *         tries to sweep the PRIZE token out on the way past.
 *
 * @dev The owner sweeping this token is a legitimate call. The re-entrancy is
 *      the attack: the inner `sweepForeignToken(prizeToken, ...)` must fail —
 *      both because the prize token is not sweepable and because the inner
 *      caller is this contract, not the owner.
 */
contract ReentrantSweepToken {
    address public jackpot;
    address public prizeToken;
    address public thief;
    bool public armed = true;
    bool public innerSucceeded;
    bytes public innerReturn;

    constructor(address _jackpot, address _prizeToken, address _thief) {
        jackpot = _jackpot;
        prizeToken = _prizeToken;
        thief = _thief;
    }

    function disarm() external {
        armed = false;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transfer(address, uint256 amount) external returns (bool) {
        if (armed) {
            (bool ok, bytes memory ret) = jackpot.call(
                abi.encodeWithSelector(
                    IJackpotLike.sweepForeignToken.selector, prizeToken, thief, amount
                )
            );
            innerSucceeded = ok;
            innerReturn = ret;
        }
        return true;
    }
}

/**
 * @notice A PRIZE token whose `transfer` re-enters `resolve` mid-payout.
 *
 * @dev The nastiest shape available to this contract: `resolve` is
 *      permissionless by design (Duel nudges it on the way past and must never
 *      be reverted by it), and the payout is an external call to a token the
 *      pot does not necessarily control. If the resolve cursor were advanced
 *      AFTER the transfer instead of before it, the inner frame would replay
 *      the same ticket. CEI is what makes this safe, and this is the test.
 */
contract ReentrantResolveToken {
    address public jackpot;
    uint256 public bal;
    uint256 public reentries;
    uint256 public maxReentries = 2;
    mapping(address => uint256) public paidTo;

    function setJackpot(address j) external {
        jackpot = j;
    }

    function setBalance(uint256 b) external {
        bal = b;
    }

    function balanceOf(address who) external view returns (uint256) {
        return who == jackpot ? bal : paidTo[who];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(msg.sender == jackpot, "only the pot pays");
        bal -= amount;
        paidTo[to] += amount;
        reentries += 1;
        if (reentries <= maxReentries) {
            IJackpotLike(jackpot).resolve(50);
        }
        return true;
    }
}
