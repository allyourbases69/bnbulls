// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
 ╔══════════════════════════════════════════════════════════════════════════╗
 ║  ⚠⚠⚠  TESTNET / TEST-ONLY ARTEFACT — NEVER DEPLOY THIS TO MAINNET  ⚠⚠⚠   ║
 ║  The constructor REVERTS on chain 56, same guard as its two siblings.     ║
 ╚══════════════════════════════════════════════════════════════════════════╝
*/

interface IFourMemePad {
    function buyTokenAMAP(address token, uint256 funds, uint256 minAmount) external payable;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title CurveBuyerProbe
 * @notice A CONTRACT that buys on the bonding curve, so
 *         `FOUR-MEME-LAUNCH-ROUTE.md §3` / `DECISIONS.md §28.2` can be
 *         rehearsed **from the shape our own pot buy-leg would have**, not from
 *         an EOA.
 *
 * @dev Three findings this exists to make executable on chain 97:
 *
 *      1. **`buyTokenAMAP` has no EOA gate.** §3 proved it twice on mainnet (a
 *         real tx whose `to` was a 2206-byte contract, and a fork run
 *         impersonating WBNB as caller). A rehearsal driven only from an EOA
 *         cannot re-prove it; this can.
 *
 *      2. **The call RETURNS NOTHING**, so the amount out is only ever a
 *         measured `balanceOf` delta. `buy` is written that way and there is no
 *         router-reported number anywhere to be tempted by.
 *
 *      3. ⚠ **THE REFUND FOOTGUN.** `msg.value` above `funds` is refunded with
 *         a plain `call`, so a contract caller without a payable fallback
 *         reverts the whole buy. §9.1 calls this "a live footgun". `rejectRefunds`
 *         makes this contract into exactly that broken caller on demand, so the
 *         failure can be observed here instead of on chain 56.
 *
 *      ⚠ `withdrawToken` is what a curve-phase buyer CANNOT use: it calls
 *      `transfer`, which reverts `"Token: Transfer is restricted"` until the
 *      curve graduates. That is the point of having it — the stranding is
 *      demonstrated, not asserted.
 */
contract CurveBuyerProbe {
    uint256 public constant BNB_MAINNET_CHAIN_ID = 56;

    string public constant TESTNET_ONLY_WARNING =
        "TESTNET/TEST ONLY. Refuses to deploy on chain 56.";

    error MainnetDeploymentForbidden(uint256 chainId);
    error NotOwner();
    error RefundRefused();

    address public immutable pad;
    address public immutable owner;

    /// @notice Turn this contract into the broken caller §9.1 warns about: the
    ///         pad's refund `call` fails and takes the entire buy down with it.
    bool public rejectRefunds;

    event Bought(address indexed token, uint256 sent, uint256 delivered, uint256 refunded);
    event RefundRejectionSet(bool on);

    constructor(address pad_) {
        if (block.chainid == BNB_MAINNET_CHAIN_ID) {
            revert MainnetDeploymentForbidden(block.chainid);
        }
        pad = pad_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @notice Buy on the curve as a CONTRACT and book the output as a measured
     *         balance delta.
     * @param token  The curve-phase token.
     * @param funds  GROSS BNB to put through the pad. Everything above it in
     *               `msg.value` comes back as a refund.
     * @param minOut Hard slippage floor. The pad reverts `Slippage` if missed —
     *               there is never an excuse for a blind buy.
     */
    function buy(address token, uint256 funds, uint256 minOut)
        external
        payable
        onlyOwner
        returns (uint256 delivered, uint256 refunded)
    {
        uint256 tokensBefore = IERC20Min(token).balanceOf(address(this));
        uint256 bnbBefore = address(this).balance;

        // ⚠ RETURNS NOTHING. The delta below is the only honest measurement.
        IFourMemePad(pad).buyTokenAMAP{value: msg.value}(token, funds, minOut);

        delivered = IERC20Min(token).balanceOf(address(this)) - tokensBefore;
        uint256 bnbAfter = address(this).balance;
        // `bnbBefore` already includes `msg.value`; anything still here is the
        // refund the pad handed back.
        refunded = bnbAfter > bnbBefore - msg.value ? bnbAfter - (bnbBefore - msg.value) : 0;
        emit Bought(token, msg.value, delivered, refunded);
    }

    /// @notice Move tokens out. ⚠ Reverts `"Token: Transfer is restricted"`
    ///         while the curve is running — the stranding, demonstrated.
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20Min(token).transfer(to, amount);
    }

    function withdrawNative(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "CurveBuyerProbe: native withdraw failed");
    }

    function setRejectRefunds(bool on) external onlyOwner {
        rejectRefunds = on;
        emit RefundRejectionSet(on);
    }

    receive() external payable {
        if (rejectRefunds) revert RefundRefused();
    }
}
