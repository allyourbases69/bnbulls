// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVRFCoordinatorV2Plus} from
    "@chainlink/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @dev ⚠⚠ REHEARSAL CHAINS ONLY — anvil (31337) and BSC testnet (97).
 *      NOTHING IN THIS FILE MAY EVER REACH CHAIN 56.
 *
 *      This is the file the `DEPLOY-SAFETY-PREFLIGHT.md §2` warning is about:
 *      stable warriors auto-deployed a `MockUSDT` from a deploy script with a
 *      silent fallback and baked it into `MintDrop`'s IMMUTABLE storage
 *      forever. So the containment is structural, not a comment:
 *
 *        - the only importers are `script/anvil/DeployLocal.s.sol` (31337) and
 *          `script/testnet/DeployTestnet.s.sol` (97), and BOTH refuse to run on
 *          any other chain id;
 *        - `script/Deploy.s.sol` imports nothing from here, so a mainnet run
 *          does not even have this bytecode in scope.
 *
 *      `LocalStable` is GONE with `DECISIONS.md §26`. It existed to rehearse
 *      the decimals path against a SIX-decimal payment token, because 18dp
 *      everywhere would hide precisely the bug the read-never-assume discipline
 *      exists to guard against. That discipline did not go with it: BNBULL's
 *      `decimals()` is still read at wiring time by `MintDrop`, `Marketplace`
 *      and both splitters, and `test/MarketplaceDecimals.t.sol` drives a
 *      non-18dp BNBULL through the whole listing/quote/buy path.
 */

// ─── Wrapped BNB ────────────────────────────────────────────────────────────

/// @notice `deposit()` is 1:1 — a WRAP, not a swap. This is why "a BNB payment
///         routes straight into the pot with no DEX interaction" survives the
///         fact that the BNB pot actually holds WBNB.
contract LocalWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "LocalWBNB: withdraw failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

// ─── Chainlink BNB/USD ──────────────────────────────────────────────────────

/**
 * @notice A BNB/USD aggregator you drive by hand.
 *
 * @dev `autoFresh` defaults ON and stamps `updatedAt = block.timestamp` on
 *      every read. That is wrong for a fork test and exactly right for a local
 *      chain: `maxOracleAge` is 1 hour, and a laptop that sits idle over lunch
 *      would otherwise come back to a dead mint path with no explanation.
 *      Switch it off to rehearse the stale-feed revert, which MintDrop must
 *      REVERT on rather than clamp — a clamp charges a price nobody chose.
 */
contract LocalAggregator {
    uint8 public decimals = 8;
    string public description = "BNB / USD";
    uint256 public version = 4;

    uint80 private _roundId = 1;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _answeredInRound = 1;

    bool public autoFresh = true;
    bool public readReverts;

    constructor(int256 initialAnswer) {
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
    }

    /// @notice Move the price. `setAnswer(700e8)` = BNB is $700.
    function setAnswer(int256 a) external {
        _roundId += 1;
        _answer = a;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }

    function setAutoFresh(bool b) external {
        autoFresh = b;
    }

    function setUpdatedAt(uint256 t) external {
        autoFresh = false;
        _updatedAt = t;
    }

    function setAnsweredInRound(uint80 r) external {
        _answeredInRound = r;
    }

    function setReadReverts(bool b) external {
        readReverts = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (readReverts) revert("LocalAggregator: feed down");
        uint256 ts = autoFresh ? block.timestamp : _updatedAt;
        return (_roundId, _answer, ts, ts, _answeredInRound);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (readReverts) revert("LocalAggregator: feed down");
        uint256 ts = autoFresh ? block.timestamp : _updatedAt;
        return (_roundId, _answer, ts, ts, _answeredInRound);
    }
}

// ─── The DEX ────────────────────────────────────────────────────────────────

/**
 * @title LocalRouter
 * @notice One router speaking BOTH dialects the money layer uses, over REAL
 *         constant-product reserves.
 *
 * @dev Two dialects because the contracts genuinely use two books:
 *        - `MintDrop` swaps on the PancakeSwap **v2** router
 *          (`getAmountsOut` / `swapExactETHForTokens` /
 *          `swapExactTokensForTokens`);
 *        - the splitters swap on the **v3 SmartRouter**
 *          (`exactInputSingle` / `exactInput` over an encoded path).
 *      That split is deliberate — on Stable a v2 `getPair` answered with a
 *      decoy pair holding ~6.6k while the real book was a v3 1% pool, and a $50
 *      buy priced through the decoy published as $13.26. Locally, both dialects
 *      hit the same reserves, so a price move is visible from either side.
 *
 *      ⚠ It is `x*y=k` with a 0.25% fee and it MOVES. That matters: a flat
 *      fixed-rate mock would let a `minOut` bug through, because slippage would
 *      always be zero. Here a fat buy really does get a worse price, and a
 *      `setFloors` value that is too optimistic really does make the swap miss
 *      `amountOutMinimum` — which is the behaviour the never-fail pattern is
 *      supposed to absorb by deferring.
 *
 *      Unlike the unit-test `MockRouter`, this one DOES enforce `minOut`. The
 *      test mock deliberately lies about its output to prove the measured
 *      balance delta catches it; this one is here so the local chain behaves
 *      like a real DEX end to end.
 */
contract LocalRouter {
    address public immutable weth;

    /// @notice The v2 factory this router names. `MintDrop` and both splitters
    ///         derive the pair — and therefore the minimum-liquidity floor —
    ///         from `factory()`, never from a second wire, so the local chain
    ///         has to answer that call too (`DECISIONS.md §28`).
    LocalFactory public immutable factoryAddr;

    /// @dev `reserve[a][b]` is the amount of `a` in the a/b pool.
    mapping(address => mapping(address => uint256)) public reserve;

    uint256 public constant FEE_NUM = 9_975; // 0.25%
    uint256 public constant FEE_DEN = 10_000;

    event Seeded(address indexed a, address indexed b, uint256 amountA, uint256 amountB);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 out);

    constructor(address _weth) {
        weth = _weth;
        factoryAddr = new LocalFactory();
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function factory() external view returns (address) {
        return address(factoryAddr);
    }

    /// @notice Add liquidity to the a/b pool. Pulls both sides from the caller.
    /// @dev Also registers the pair with the factory, so the liquidity floor
    ///      sees a pool the instant one genuinely exists — and, before that,
    ///      sees `address(0)` and defers, which is the real pre-graduation
    ///      behaviour (`DECISIONS.md §29`).
    function seed(address a, address b, uint256 amountA, uint256 amountB) external {
        IERC20(a).transferFrom(msg.sender, address(this), amountA);
        IERC20(b).transferFrom(msg.sender, address(this), amountB);
        reserve[a][b] += amountA;
        reserve[b][a] += amountB;
        factoryAddr.ensurePair(address(this), a, b);
        emit Seeded(a, b, amountA, amountB);
    }

    function quote(uint256 amountIn, address tokenIn, address tokenOut)
        public
        view
        returns (uint256)
    {
        uint256 rIn = reserve[tokenIn][tokenOut];
        uint256 rOut = reserve[tokenOut][tokenIn];
        if (rIn == 0 || rOut == 0 || amountIn == 0) return 0;
        uint256 inWithFee = amountIn * FEE_NUM;
        return (inWithFee * rOut) / (rIn * FEE_DEN + inWithFee);
    }

    // ─── v2 dialect (MintDrop AND both splitters) ───────────────────────
    //
    // ⚠ THE FEE-SUPPORTING VARIANTS ARE THE ONES THE CONTRACTS CALL —
    // `DECISIONS.md §30`. They return nothing, so the caller has to measure a
    // balance delta, which it already did. The legacy selectors below are kept
    // only so a local run of an older keeper script does not 404.

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "LocalRouter: bad path");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i + 1 < path.length; i++) {
            amounts[i + 1] = quote(amounts[i], path[i], path[i + 1]);
        }
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable returns (uint256[] memory amounts) {
        require(path.length >= 2 && path[0] == weth, "LocalRouter: path must start at WETH");
        LocalWBNB(payable(weth)).deposit{value: msg.value}();
        amounts = _walk(msg.value, path);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "LocalRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).transfer(to, out);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length >= 2, "LocalRouter: bad path");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        amounts = _walk(amountIn, path);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "LocalRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).transfer(to, out);
    }

    /// @notice The fee-supporting native swap. Returns nothing, like the real
    ///         router.
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable {
        require(path.length >= 2 && path[0] == weth, "LocalRouter: path must start at WETH");
        LocalWBNB(payable(weth)).deposit{value: msg.value}();
        uint256[] memory amounts = _walk(msg.value, path);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "LocalRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).transfer(to, out);
    }

    /// @notice The fee-supporting token swap. Returns nothing.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        require(path.length >= 2, "LocalRouter: bad path");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256[] memory amounts = _walk(amountIn, path);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "LocalRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).transfer(to, out);
    }

    // ─── v3 dialect — ⚠ DEAD, kept only so an old local script still runs ──
    //
    // `DECISIONS.md §28`: nothing in `contracts/` speaks v3 any more. four.meme
    // graduates into PancakeSwap v2 and creates no v3 pool at any tier.

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = _swapOne(p.tokenIn, p.tokenOut, p.amountIn);
        require(amountOut >= p.amountOutMinimum, "LocalRouter: Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        address[] memory tokens = _decodePath(p.path);
        IERC20(tokens[0]).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = p.amountIn;
        for (uint256 i = 0; i + 1 < tokens.length; i++) {
            amountOut = _swapOne(tokens[i], tokens[i + 1], amountOut);
        }
        require(amountOut >= p.amountOutMinimum, "LocalRouter: Too little received");
        IERC20(tokens[tokens.length - 1]).transfer(p.recipient, amountOut);
    }

    /// @dev v3 path encoding: token (20) [fee (3) token (20)]+
    function _decodePath(bytes memory path) internal pure returns (address[] memory tokens) {
        require(path.length >= 43 && (path.length - 20) % 23 == 0, "LocalRouter: bad v3 path");
        uint256 n = (path.length - 20) / 23 + 1;
        tokens = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = _addrAt(path, i * 23);
        }
    }

    function _addrAt(bytes memory b, uint256 offset) private pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(b, 0x20), offset)))
        }
    }

    // ─── Reserves ───────────────────────────────────────────────────────

    function _walk(uint256 amountIn, address[] calldata path)
        private
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i + 1 < path.length; i++) {
            amounts[i + 1] = _swapOne(path[i], path[i + 1], amounts[i]);
        }
    }

    function _swapOne(address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint256 out)
    {
        out = quote(amountIn, tokenIn, tokenOut);
        require(out > 0, "LocalRouter: no liquidity");
        reserve[tokenIn][tokenOut] += amountIn;
        reserve[tokenOut][tokenIn] -= out;
        emit Swapped(tokenIn, tokenOut, amountIn, out);
    }

    receive() external payable {}
}

// ─── The v2 factory + pair, for the minimum-liquidity floor ─────────────────

/**
 * @title LocalPair
 * @notice A PancakeSwap v2 pair reduced to the two calls the minimum-liquidity
 *         floor makes: `getReserves()` and `token0()`.
 * @dev It holds no balances of its own — it reads them LIVE off `LocalRouter`,
 *      so a local seed or a local swap moves the floor's view of the pool
 *      exactly as it moves the price. A pair that lied about its reserves would
 *      make the local rehearsal worthless.
 */
contract LocalPair {
    LocalRouter public immutable router;
    address public immutable token0;
    address public immutable token1;

    constructor(address _router, address t0, address t1) {
        router = LocalRouter(payable(_router));
        token0 = t0;
        token1 = t1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (
            uint112(router.reserve(token0, token1)),
            uint112(router.reserve(token1, token0)),
            uint32(block.timestamp)
        );
    }
}

/**
 * @title LocalFactory
 * @notice `getPair` for the local chain. Answers `address(0)` until a pool has
 *         actually been seeded — which is the honest pre-graduation answer, and
 *         the one the floor must turn into a deferral rather than a revert
 *         (`DECISIONS.md §29`).
 */
contract LocalFactory {
    mapping(bytes32 => address) private _pairs;

    event PairCreated(address indexed token0, address indexed token1, address pair);

    function getPair(address a, address b) external view returns (address) {
        return _pairs[_key(a, b)];
    }

    function ensurePair(address router, address a, address b) external returns (address pair) {
        bytes32 k = _key(a, b);
        pair = _pairs[k];
        if (pair != address(0)) return pair;
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pair = address(new LocalPair(router, t0, t1));
        _pairs[k] = pair;
        emit PairCreated(t0, t1, pair);
    }

    function _key(address a, address b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

// ─── VRF ────────────────────────────────────────────────────────────────────

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/**
 * @title LocalVRFCoordinator
 * @notice A VRF v2.5 coordinator you fulfil on demand.
 *
 * @dev Two modes, and both are worth exercising locally:
 *        - `fulfill(requestId, word)` delivers a word you choose;
 *        - `fulfillPending(word)` delivers to whatever asked last, which is all
 *          the seed script needs.
 *      And the third mode is doing NOTHING: `Jackpot` documents that if VRF
 *      stays dark forever the money simply sits in the pool, which is the
 *      correct failure for a pot with no withdraw path. Nobody can take it,
 *      including us.
 *
 *      ⚠ `Jackpot.fulfillRandomWords` refuses a word from any address that is
 *      not the TIMELOCKED `_coordinatorWire` (`DECISIONS.md §18`), so this
 *      contract only works because `DeployLocal` wires it as the constructor's
 *      coordinator. Pointing a second coordinator at a live pot and expecting
 *      it to work is precisely the attack that timelock exists to stop.
 */
contract LocalVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 public nextRequestId = 1;
    uint256 public requestCount;

    mapping(uint256 => address) public consumerOf;
    uint256 public lastRequestId;
    address public lastConsumer;

    event Requested(uint256 indexed requestId, address indexed consumer);
    event Fulfilled(uint256 indexed requestId, address indexed consumer, uint256 word);

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata)
        external
        returns (uint256 requestId)
    {
        requestId = nextRequestId++;
        requestCount += 1;
        consumerOf[requestId] = msg.sender;
        lastRequestId = requestId;
        lastConsumer = msg.sender;
        emit Requested(requestId, msg.sender);
    }

    function fulfill(uint256 requestId, uint256 word) public {
        address consumer = consumerOf[requestId];
        require(consumer != address(0), "LocalVRF: unknown request");
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
        emit Fulfilled(requestId, consumer, word);
    }

    /// @notice Fulfil whatever asked last. What the seed script uses.
    function fulfillPending(uint256 word) external {
        require(lastRequestId != 0, "LocalVRF: nothing pending");
        fulfill(lastRequestId, word);
    }

    // ─── IVRFSubscriptionV2Plus: unused by the consumer, stubbed ────────

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

    function getActiveSubscriptionIds(uint256, uint256) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function fundSubscriptionWithNative(uint256) external payable {}
}
