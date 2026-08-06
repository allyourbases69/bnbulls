// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ForkInterfaces
 * @notice Minimal ABIs for the LIVE mainnet contracts this package calls.
 *
 * @dev These are deliberately hand-written and deliberately small. Every
 *      selector below was resolved against a live contract before it was
 *      written down (`FOUR-MEME-LAUNCH-ROUTE §1/§3`); nothing is copied from
 *      a package that could be a different deployment's ABI.
 *
 *      ⚠ NONE of these are our contracts' interfaces. `PotSplitter`, the
 *      splitters and `MintDrop` are mid-rewrite (`DECISIONS.md §28`), so this
 *      package never redeclares their swap ABI — it drives them through their
 *      public entry points and asserts on measured balances.
 */

// ─── ERC-20 ───────────────────────────────────────────────────────────────

interface IERC20Fork {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWBNBFork is IERC20Fork {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// ─── PancakeSwap v2 ───────────────────────────────────────────────────────

interface IPancakeFactoryFork {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IPancakePairFork {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

interface IPancakeRouterFork {
    function WETH() external view returns (address);
    function factory() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

// ─── PancakeSwap v3 — the venue four.meme never creates ───────────────────

interface IPancakeV3FactoryFork {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IPancakeV3PoolFork {
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface INonfungiblePositionManagerFork {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function factory() external view returns (address);

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IQuoterV2Fork {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

// ─── Chainlink ────────────────────────────────────────────────────────────

interface IAggregatorV3Fork {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function aggregator() external view returns (address);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 ans);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 ans);
}

interface IVRFCoordinatorV2_5Fork {
    function createSubscription() external returns (uint256 subId);
    function addConsumer(uint256 subId, address consumer) external;
    function fundSubscriptionWithNative(uint256 subId) external payable;
    function getSubscription(uint256 subId)
        external
        view
        returns (
            uint96 balance,
            uint96 nativeBalance,
            uint64 reqCount,
            address subOwner,
            address[] memory consumers
        );
    /// @dev The registry `requestRandomWords` does NOT consult. Returns
    ///      `(exists, maxGas)` for a gas lane. This is the read that turns a
    ///      keyHash typo from a silent stall into a deploy-time assertion.
    function s_provingKeys(bytes32 keyHash) external view returns (bool exists, uint64 maxGas);

    function s_provingKeyHashes(uint256 index) external view returns (bytes32);

    function s_config()
        external
        view
        returns (
            uint16 minimumRequestConfirmations,
            uint32 maxGasLimit,
            bool reentrancyLock,
            uint32 stalenessSeconds,
            uint32 gasAfterPaymentCalculation,
            uint32 fulfillmentFlatFeeNativePPM,
            uint32 fulfillmentFlatFeeLinkDiscountPPM,
            uint8 nativePremiumPercentage,
            uint8 linkPremiumPercentage
        );
}

// ─── four.meme ────────────────────────────────────────────────────────────

/**
 * @dev TokenManager2. The implementation is UNVERIFIED on bscscan
 *      (`FOUR-MEME-LAUNCH-ROUTE §7`), so every selector here was resolved
 *      from bytecode and then proven by execution, not read off a source
 *      page. `_tokenInfos` is returned as a raw tuple because the pad's
 *      struct definition is not public; field 2 in particular is a decoded
 *      guess (§10) and this package never asserts on it.
 */
interface ITokenManager2Fork {
    /// @dev selector 0x87f27655. Payable in native BNB. `minAmount` is a hard
    ///      floor that reverts `Slippage`. Returns NOTHING — the only honest
    ///      amount-out is a `balanceOf` delta.
    function buyTokenAMAP(address token, uint256 funds, uint256 minAmount) external payable;

    function _tokenInfos(address token)
        external
        view
        returns (
            address base,
            address quote,
            bytes32 config,
            uint256 totalSupply,
            uint256 maxOffers,
            uint256 maxRaising,
            uint256 launchTime,
            uint256 offers,
            uint256 funds,
            uint256 lastPrice,
            uint256 K,
            uint256 T,
            uint256 status
        );

    function _tradingHalt() external view returns (bool);
    function _tradingFeeRate() external view returns (uint256);
    function _referralRewardRate() external view returns (uint256);
    function _launchFee() external view returns (uint256);
    function owner() external view returns (address);

    function STATUS_TRADING() external view returns (uint256);
    function STATUS_HALT() external view returns (uint256);
    function STATUS_ADDING_LIQUIDITY() external view returns (uint256);
    function STATUS_COMPLETED() external view returns (uint256);
}

/// @dev The four.meme token template. `_mode` is the transfer gate:
///      1 = MODE_TRANSFER_RESTRICTED, 0 = MODE_NORMAL after graduation.
interface IFourMemeTokenFork is IERC20Fork {
    function _mode() external view returns (uint256);
    function owner() external view returns (address);
    function founder() external view returns (address);
    function feeRateBuy() external view returns (uint256);
    function feeRateSell() external view returns (uint256);
    function pair() external view returns (address);
    function PANCAKE_FACTORY() external view returns (address);
    function PANCAKE_ROUTER() external view returns (address);
    function WETH() external view returns (address);
}
