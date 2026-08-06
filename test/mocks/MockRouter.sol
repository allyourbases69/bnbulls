// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockV2Pair
 * @notice A PancakeSwap v2 pair, reduced to the only two things the
 *         minimum-liquidity floor asks it: `getReserves()` and `token0()`.
 *
 * @dev The reserves are SETTABLE and deliberately independent of the router's
 *      rate table. That is not laziness — it is what lets a test say "the pair
 *      exists, holds 0.01 WBNB, and would quote you a terrible price" without
 *      building a whole constant-product AMM. `DECISIONS.md §28` measured that
 *      exact shape at 95x worse than the real book.
 */
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 private _reserve0;
    uint112 private _reserve1;

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function setReserves(uint112 r0, uint112 r1) external {
        _reserve0 = r0;
        _reserve1 = r1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }
}

/**
 * @title MockV2Factory
 * @notice Answers `getPair` with ONE pair for every token pair, which is enough
 *         because v2 has one canonical pair per token pair anyway.
 * @dev `missing` makes it answer `address(0)` — the PRE-GRADUATION state, and
 *      the one the never-fail rule cares about most: no pair must defer, never
 *      revert.
 */
contract MockV2Factory {
    address public pair;
    bool public missing;

    constructor(address _pair) {
        pair = _pair;
    }

    function setMissing(bool b) external {
        missing = b;
    }

    function getPair(address, address) external view returns (address) {
        return missing ? address(0) : pair;
    }
}

/**
 * @title MockRouter
 * @notice A PancakeSwap-v2-shaped router with every hostile mode the buyback
 *         legs have to survive, and one that matters more than the rest:
 *
 *         ⚠ **IT NEVER ENFORCES `amountOutMin`.**
 *
 * @dev That is deliberate and it is the entire point of the swap-safety suite.
 *      `LEARNINGS-AND-MISTAKES §B` requires the contract to book swap output as
 *      a MEASURED BALANCE DELTA and re-check it against `minOut` itself,
 *      because a lying router or a fee-on-transfer token would otherwise wedge
 *      the pot forever. If MintDrop trusted either the router's enforcement or
 *      its returned `amounts[]`, every test against this mock would pass while
 *      the pot silently received dust. So the mock reports the full quote in
 *      `amounts[]`, transfers whatever `lying`/`quoteZero` say it feels like,
 *      and leaves `minOut` entirely to the caller.
 *
 *      Rates are per (path[0], path[last]) so a stable->WBNB leg and a
 *      BNB->BNBULL leg can carry economically sane, different prices in the
 *      same test. Unset pairs are 1:1.
 */
contract MockRouter {
    address public immutable weth;

    /// @notice The v2 factory this router names. `MintDrop` derives the pair —
    ///         and therefore the liquidity floor — from `factory()`, never from
    ///         a second wire, so the mock has to name one too.
    MockV2Factory public immutable v2Factory;
    /// @notice The one pair `v2Factory` answers with. Seeded HEALTHY so every
    ///         existing test keeps passing without knowing this exists.
    MockV2Pair public immutable v2Pair;

    /// @notice The default reserve on both sides: 1e24 wei, five orders of
    ///         magnitude above the 1 BNB launch floor.
    uint112 public constant HEALTHY_RESERVE = 1e24;

    mapping(bytes32 => uint256) private _num;
    mapping(bytes32 => uint256) private _den;

    /// @notice Quote calls revert. A router that is down, or an address with no
    ///         router at it.
    bool public revertOnQuote;
    /// @notice Swap calls revert.
    bool public revertOnSwap;
    /// @notice Quote and swap both produce zero. A drained or non-existent pair.
    bool public quoteZero;
    /// @notice Report the full output in `amounts[]` but only transfer
    ///         `lyingBps` of it. THE test case for measured balance deltas.
    bool public lying;
    uint256 public lyingBps = 100; // 1% of what it claims

    /// @notice How many times a swap function was actually entered. The
    ///         "never sell BNBULL" rule is proved by asserting this stays 0.
    uint256 public swapCalls;

    constructor(address _weth) {
        weth = _weth;
        v2Pair = new MockV2Pair();
        // WBNB is token0 here; the contracts READ `token0()` rather than
        // deriving it from address ordering, so the mock is free to say so.
        v2Pair.setTokens(_weth, address(0));
        v2Pair.setReserves(HEALTHY_RESERVE, HEALTHY_RESERVE);
        v2Factory = new MockV2Factory(address(v2Pair));
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function factory() external view returns (address) {
        return address(v2Factory);
    }

    // ─── Config ───────────────────────────────────────────────────────────

    /// @notice Drive the pair under the floor — the dust-pair case.
    function setPairReserves(uint112 wbnbSide, uint112 tokenSide) external {
        v2Pair.setReserves(wbnbSide, tokenSide);
    }

    /// @notice No pair at all — pre-graduation. Must DEFER, never revert.
    function setPairMissing(bool b) external {
        v2Factory.setMissing(b);
    }

    function setRate(address tokenIn, address tokenOut, uint256 n, uint256 d) external {
        bytes32 k = keccak256(abi.encodePacked(tokenIn, tokenOut));
        _num[k] = n;
        _den[k] = d;
    }

    function setRevertOnQuote(bool b) external {
        revertOnQuote = b;
    }

    function setRevertOnSwap(bool b) external {
        revertOnSwap = b;
    }

    function setQuoteZero(bool b) external {
        quoteZero = b;
    }

    function setLying(bool b, uint256 bps) external {
        lying = b;
        lyingBps = bps;
    }

    function resetSwapCalls() external {
        swapCalls = 0;
    }

    // ─── Quote ────────────────────────────────────────────────────────────

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        if (revertOnQuote) revert("MockRouter: quote down");
        require(path.length >= 2, "MockRouter: bad path");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        uint256 out = _out(amountIn, path[0], path[path.length - 1]);
        for (uint256 i = 1; i < path.length; i++) {
            amounts[i] = out;
        }
    }

    // ─── Swaps ────────────────────────────────────────────────────────────

    /**
     * @notice The FEE-SUPPORTING native swap — the one `MintDrop` calls.
     * @dev Returns NOTHING, exactly like the real router. There is therefore no
     *      `amounts[]` left for a caller to trust, which is the point of
     *      `DECISIONS.md §30`: the caller has to measure.
     */
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, /* amountOutMin — deliberately ignored, see the header */
        address[] calldata path,
        address to,
        uint256
    ) external payable {
        if (revertOnSwap) revert("MockRouter: swap down");
        require(path.length >= 2, "MockRouter: bad path");
        swapCalls += 1;

        uint256 out = _out(msg.value, path[0], path[path.length - 1]);
        uint256 sent = lying ? (out * lyingBps) / 10_000 : out;
        if (sent > 0) IERC20(path[path.length - 1]).transfer(to, sent);
    }

    /// @notice The FEE-SUPPORTING token swap. Same discipline.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256, /* amountOutMin — deliberately ignored */
        address[] calldata path,
        address to,
        uint256
    ) external {
        if (revertOnSwap) revert("MockRouter: swap down");
        require(path.length >= 2, "MockRouter: bad path");
        swapCalls += 1;

        // A real router pulls against the allowance, so a taxed INPUT token
        // delivers the pair less than `amountIn` — exactly as on chain.
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        uint256 out = _out(amountIn, path[0], path[path.length - 1]);
        uint256 sent = lying ? (out * lyingBps) / 10_000 : out;
        if (sent > 0) IERC20(path[path.length - 1]).transfer(to, sent);
    }

    // ─── The legacy, NON-fee-supporting variants ──────────────────────────
    //
    // ⚠ THEY EXIST ONLY TO FAIL. `DECISIONS.md §30`: a four.meme template B
    // token carries a creator-set buy and sell tax, and a non-fee-supporting
    // router call on such a token reverts `Pancake: K`. Keeping them here, with
    // that exact revert reason, means any regression back to them is a loud red
    // test — the pot silently stops being funded — rather than a mainnet-only
    // failure discovered by a holder.

    function swapExactETHForTokens(uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory)
    {
        revert("Pancake: K");
    }

    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        pure
        returns (uint256[] memory)
    {
        revert("Pancake: K");
    }

    // ─── Internals ────────────────────────────────────────────────────────

    function _out(uint256 amountIn, address tokenIn, address tokenOut)
        private
        view
        returns (uint256)
    {
        if (quoteZero) return 0;
        bytes32 k = keccak256(abi.encodePacked(tokenIn, tokenOut));
        uint256 n = _num[k];
        uint256 d = _den[k];
        if (n == 0 || d == 0) return amountIn; // unset pairs are 1:1
        return (amountIn * n) / d;
    }

    receive() external payable {}
}
