// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockV2Factory, MockV2Pair} from "./MockRouter.sol";

/**
 * @title SplitterMocks
 * @notice Hostile fixtures for `lib/PotSplitter.sol` and its two concrete
 *         splitters.
 *
 * @dev ⚠ NO MAINNET FORK. Every one of these is a mock, driven into a failure
 *      mode a fork could not reproduce on demand.
 *
 *      ⚠ THIS FILE USED TO HOLD A **v3** ROUTER, AND THAT WAS THE BUG.
 *      `DECISIONS.md §28`: four.meme graduates into PancakeSwap **v2** against
 *      WBNB and creates no v3 pool at any tier, so a v3-only leg could only
 *      ever have found somebody else's decoy — measured at 95x worse. The
 *      splitters are v2 now and so is this router. It stays separate from the
 *      shared `MockRouter` because it carries hostile modes (overreport, gas
 *      burn, enforce-minOut, the `Pancake: K` trap) that the other suites do
 *      not want, and it borrows `MockV2Factory` / `MockV2Pair` from there so
 *      there is ONE mock pair shape in the repo, not two.
 */

// ══════════════════════════════════════════════════════════════════════════
//  The v2 router
// ══════════════════════════════════════════════════════════════════════════

/**
 * @title SplitterV2Router
 * @notice A PancakeSwap-v2 router with every hostile mode the buyback legs must
 *         survive, and one that matters more than all of them:
 *
 *         ⚠ **IT DOES NOT ENFORCE `amountOutMin`, AND IT LIES.**
 *
 * @dev That is the whole point. `BNBULLS-BOOTSTRAP.md §6.4` requires swap
 *      output to be booked as a MEASURED BALANCE DELTA and re-checked against
 *      `minOut` by the CALLER, because a lying router or a fee-on-transfer
 *      token would otherwise wedge a pot forever. If `PotSplitter` trusted
 *      anything the router said, every test here would pass while the pot
 *      received dust.
 *
 *      The transfer is whatever `lyingBps` says (10_000 = honest).
 *      `enforceMinOut` is OFF by default so the contract's own check is the
 *      only thing standing between the pot and a lie.
 *
 *      ⚠ `overreportBps` SURVIVES ONLY ON THE LEGACY SELECTORS, and that is a
 *      statement in itself: the fee-supporting call the splitter now uses
 *      RETURNS NOTHING, so there is no longer any figure for a router to
 *      overstate. The only way to be lied to is by under-delivering, which the
 *      measured delta catches.
 *
 *      `factory()` names a `MockV2Factory` whose one pair is seeded HEALTHY, so
 *      a test only has to think about liquidity when it is testing liquidity.
 */
contract SplitterV2Router {
    mapping(bytes32 => uint256) private _num;
    mapping(bytes32 => uint256) private _den;

    /// @notice The factory the splitter derives the pair from. Never a second
    ///         wire — `PotSplitter` reads `router.factory()`.
    MockV2Factory public immutable v2Factory;
    MockV2Pair public immutable v2Pair;

    /// @notice Default reserve on both sides: 1e24 wei, five orders of
    ///         magnitude above the 1 BNB launch floor.
    uint112 public constant HEALTHY_RESERVE = 1e24;

    /// @notice Every swap reverts. A router that is down, or an address with no
    ///         router at it.
    bool public revertOnSwap;
    /// @notice Every swap produces zero. **The launch state**: BNBULL is on
    ///         four.meme's bonding curve and there is no PancakeSwap pair.
    bool public quoteZero;
    /// @notice Transfer only `lyingBps` of the honest figure. The
    ///         measured-delta test.
    uint256 public lyingBps = 10_000;
    /// @notice What the LEGACY (non-fee-supporting) selectors claim in their
    ///         `amounts[]`. Unreachable through the fee-supporting call, by
    ///         construction — see the header.
    uint256 public overreportBps = 10_000;
    /// @notice Behave like a real router and enforce the floor. Off by default.
    bool public enforceMinOut;
    /// @notice Burn the caller's gas instead of reverting.
    bool public burnGas;
    /// @notice Behave like a four.meme template B token's pair: the legacy,
    ///         non-fee-supporting selectors revert `Pancake: K`
    ///         (`DECISIONS.md §30`). ON by default — that is the token we must
    ///         assume we are getting.
    bool public taxedPair = true;

    /// @notice How many times a swap function was entered. `DECISIONS.md §14`
    ///         ("never sell BNBULL") is proved by asserting this stays 0.
    uint256 public swapCalls;
    /// @notice How many times a LEGACY selector was entered. Must stay 0
    ///         forever: reaching one means we went back to a call that a taxed
    ///         token reverts.
    uint256 public legacyCalls;
    /// @notice The last floor the caller asked for, so a test can prove the
    ///         floor actually derives from the keeper's published rate.
    uint256 public lastMinOut;
    /// @notice The last deadline the caller passed. A v2 router reverts on a
    ///         stale one, so it has to be a real value.
    uint256 public lastDeadline;

    constructor(address weth) {
        v2Pair = new MockV2Pair();
        v2Pair.setTokens(weth, address(0));
        v2Pair.setReserves(HEALTHY_RESERVE, HEALTHY_RESERVE);
        v2Factory = new MockV2Factory(address(v2Pair));
    }

    // ─── Config ───────────────────────────────────────────────────────────

    function setRate(address tokenIn, address tokenOut, uint256 n, uint256 d) external {
        bytes32 k = keccak256(abi.encodePacked(tokenIn, tokenOut));
        _num[k] = n;
        _den[k] = d;
    }

    function setRevertOnSwap(bool b) external {
        revertOnSwap = b;
    }

    function setQuoteZero(bool b) external {
        quoteZero = b;
    }

    function setLying(uint256 bps) external {
        lyingBps = bps;
    }

    function setOverreport(uint256 bps) external {
        overreportBps = bps;
    }

    function setEnforceMinOut(bool b) external {
        enforceMinOut = b;
    }

    function setBurnGas(bool b) external {
        burnGas = b;
    }

    function setTaxedPair(bool b) external {
        taxedPair = b;
    }

    function resetSwapCalls() external {
        swapCalls = 0;
        legacyCalls = 0;
    }

    /// @notice Drive the pair under the floor — the dust-pair case.
    function setPairReserves(uint112 wbnbSide, uint112 tokenSide) external {
        v2Pair.setReserves(wbnbSide, tokenSide);
    }

    /// @notice No pair at all — pre-graduation. Must DEFER, never revert.
    function setPairMissing(bool b) external {
        v2Factory.setMissing(b);
    }

    // ─── IPancakeRouter02 ─────────────────────────────────────────────────

    function factory() external view returns (address) {
        return address(v2Factory);
    }

    /// @notice THE call `PotSplitter` makes. Returns nothing, like the real one.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        lastDeadline = deadline;
        _swap(path, to, amountIn, amountOutMin);
    }

    // ─── The legacy, NON-fee-supporting selectors ─────────────────────────
    //
    // ⚠ THEY EXIST TO CATCH A REGRESSION. On a four.meme template B token
    // (creator-set buy AND sell tax) these revert `Pancake: K` on the real
    // router, and v3 has no fee-supporting variant at all — which is why the
    // venue moved. `legacyCalls` is asserted to be 0.

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        legacyCalls += 1;
        if (taxedPair) revert("Pancake: K");
        uint256 honest = _swap(path, to, amountIn, amountOutMin);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; i++) {
            amounts[i] = (honest * overreportBps) / 10_000; // what we CLAIM
        }
    }

    // ─── Internals ────────────────────────────────────────────────────────

    function _swap(address[] calldata path, address recipient, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 honest)
    {
        if (revertOnSwap) revert("SplitterV2Router: swap down");
        if (burnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        require(path.length >= 2, "SplitterV2Router: bad path");
        swapCalls += 1;
        lastMinOut = minOut;

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // Real routers pull with transferFrom against the allowance the caller
        // set. A fee-on-transfer input token therefore delivers us less than
        // `amountIn`, exactly as on chain.
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        honest = _out(amountIn, tokenIn, tokenOut);
        uint256 sent = (honest * lyingBps) / 10_000;

        if (enforceMinOut && sent < minOut) {
            revert("SplitterV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        }
        if (sent > 0) IERC20(tokenOut).transfer(recipient, sent);
    }

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

// ══════════════════════════════════════════════════════════════════════════
//  The live policy source (stands in for MintDrop)
// ══════════════════════════════════════════════════════════════════════════

/**
 * @notice A `MintDrop`-shaped pot-routing policy that can be driven into every
 *         way the read can go wrong.
 *
 * @dev `PotSplitter.potPolicy()` reads the split LIVE off MintDrop so
 *      `DECISIONS.md §13`/`§14` has one source of truth on chain, and falls back
 *      to its local shares when the read is unavailable. "Unavailable" has to
 *      cover more than "unwired": a reverting getter, a getter that BURNS the
 *      caller's gas (which try/catch alone does not protect against — hence
 *      `POLICY_READ_GAS`), and an answer that is simply out of bounds.
 */
contract SplitterPolicySource {
    enum Mode {
        Healthy,
        Revert,
        BurnGas,
        Huge
    }

    Mode public mode;
    uint256 private _bnbullBps = 2_000;
    uint256 private _bnbBps = 1_000;
    bool private _sells;

    function setMode(Mode m) external {
        mode = m;
    }

    function setPolicy(uint256 a, uint256 b, bool s) external {
        _bnbullBps = a;
        _bnbBps = b;
        _sells = s;
    }

    function bnbullShareBps() external view returns (uint256) {
        return _read(_bnbullBps);
    }

    function bnbShareBps() external view returns (uint256) {
        return _read(_bnbBps);
    }

    function bnbullPaymentSellsForBnbLeg() external view returns (bool) {
        _read(0);
        return _sells;
    }

    function _read(uint256 v) private view returns (uint256) {
        if (mode == Mode.Revert) revert("SplitterPolicySource: down");
        if (mode == Mode.BurnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        // `Huge` returns two values whose SUM overflows uint256. A real
        // `MintDrop` cannot (`setPotShares` bounds it), but the splitter's own
        // NatSpec promises that a "wrong ABI" at this slot degrades to the
        // local fallback rather than failing the player — so it is fair game.
        if (mode == Mode.Huge) return type(uint256).max / 2 + 1;
        return v;
    }
}

/// @dev A policy source with no matching functions at all — the "wrong ABI"
///      case. Every getter hits the fallback, which returns nothing, and
///      `abi.decode` of empty returndata reverts inside the try.
contract SplitterWrongAbiPolicy {
    fallback() external {}
}

// ══════════════════════════════════════════════════════════════════════════
//  Pots
// ══════════════════════════════════════════════════════════════════════════

/// @notice A `Jackpot`-shaped sink whose `fund` can be made to fail. Cheaper
///         than deploying the real pot when all a test needs is "the funding
///         leg broke".
contract SplitterHostilePot {
    IERC20 public immutable prize;
    bool public fundReverts;
    uint256 public funded;

    constructor(address _prize) {
        prize = IERC20(_prize);
    }

    function setFundReverts(bool b) external {
        fundReverts = b;
    }

    function fund(uint256 amount, string calldata) external {
        if (fundReverts) revert("SplitterHostilePot: closed");
        prize.transferFrom(msg.sender, address(this), amount);
        funded += amount;
    }

    function pool() external view returns (uint256) {
        return prize.balanceOf(address(this));
    }
}

/**
 * @notice A pot that re-enters the splitter's never-fail entrypoint while it is
 *         being funded.
 *
 * @dev `PotSplitter` deliberately carries NO `nonReentrant` on its entrypoints
 *      — `ReentrancyGuard` REVERTS, and a reverting modifier on a never-fail
 *      entrypoint is precisely the brick the pattern exists to prevent. This
 *      proves the claim that the entrypoints are safe without it: each handles
 *      only the value delivered to that call and accrues with `+=`, so a
 *      re-entrant delivery can neither double-count nor double-spend.
 */
contract SplitterReentrantPot {
    IERC20 public immutable prize;
    address payable public splitter;
    uint256 public funded;
    uint256 public reentries;
    uint256 public maxReentries = 1;
    uint256 public reentryValue;

    constructor(address _prize) {
        prize = IERC20(_prize);
    }

    function arm(address payable _splitter, uint256 value, uint256 max) external {
        splitter = _splitter;
        reentryValue = value;
        maxReentries = max;
    }

    function fund(uint256 amount, string calldata) external {
        if (splitter != address(0) && reentries < maxReentries) {
            reentries += 1;
            (bool ok,) = splitter.call{value: reentryValue}("");
            require(ok, "SplitterReentrantPot: inner entrypoint reverted");
        }
        prize.transferFrom(msg.sender, address(this), amount);
        funded += amount;
    }

    function pool() external view returns (uint256) {
        return prize.balanceOf(address(this));
    }

    receive() external payable {}
}

// ══════════════════════════════════════════════════════════════════════════
//  Tokens
// ══════════════════════════════════════════════════════════════════════════

/// @dev A fee-on-transfer token with CONFIGURABLE DECIMALS, so the same fixture
///      can play a 6-dp stablecoin and an 18-dp BNBULL. `MockFeeToken` is
///      18-dp-only and shared with other suites, so this is a new one rather
///      than an edit to it.
contract SplitterFeeToken is ERC20 {
    address public constant SINK = address(0xFEE5);

    uint8 private immutable _decimals;
    uint256 public feeBps;

    constructor(string memory n, string memory s, uint8 d, uint256 _feeBps) ERC20(n, s) {
        _decimals = d;
        feeBps = _feeBps;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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

/**
 * @title FourMemeTaxedToken
 * @notice A four.meme **template B** token: a creator-set buy AND sell tax that
 *         bites only on transfers touching the pair, exactly as measured on
 *         chain (`DECISIONS.md §30`, -10% on the specimen).
 *
 * @dev This is the shape that makes the venue decision load-bearing. On a token
 *      like this:
 *        - a plain `swapExactTokensForTokens` reverts `Pancake: K`, because the
 *          pair receives less than the router told it to expect;
 *        - **v3 has no fee-supporting variant at all**, so a taxed token cannot
 *          be routed on v3 under any circumstances;
 *        - `…SupportingFeeOnTransferTokens` works, and returns nothing, so the
 *          caller MUST measure — which this codebase already did.
 *
 *      Distinct from `SplitterFeeToken`, which taxes every transfer: taxing
 *      only pair-touching transfers is both more faithful AND a sharper test,
 *      because it means the pot funding is untaxed and any shortfall the pot
 *      sees came from the SWAP, not from the plumbing.
 */
contract FourMemeTaxedToken is ERC20 {
    address public constant SINK = address(0x7A4E5);

    uint8 private immutable _decimals;
    /// @notice The "pair" — in these tests the router mock, which is what holds
    ///         the other side of the book.
    address public pair;
    uint256 public buyTaxBps;
    uint256 public sellTaxBps;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setPair(address p) external {
        pair = p;
    }

    /// @param buyBps  Taken when tokens leave the pair (a buy).
    /// @param sellBps Taken when tokens enter the pair (a sell).
    function setTax(uint256 buyBps, uint256 sellBps) external {
        buyTaxBps = buyBps;
        sellTaxBps = sellBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 bps;
        if (pair != address(0) && from != address(0) && to != address(0)) {
            if (from == pair) bps = buyTaxBps;
            else if (to == pair) bps = sellTaxBps;
        }
        if (bps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 tax = (value * bps) / 10_000;
        super._update(from, to, value - tax);
        if (tax > 0) super._update(from, SINK, tax);
    }
}

/// @dev Reports a decimals value above `MAX_TOKEN_DECIMALS`. Wiring it must
///      fail the WIRING transaction, not the first payment.
contract SplitterFatDecimalsToken is ERC20 {
    constructor() ERC20("Fat", "FAT") {}

    function decimals() public pure override returns (uint8) {
        return 37;
    }
}

// ══════════════════════════════════════════════════════════════════════════
//  Callers
// ══════════════════════════════════════════════════════════════════════════

/**
 * @notice Stands in for a FROZEN upstream: it forwards value with a bare call
 *         and treats failure as fatal, exactly as `MintDrop._routeNative` did
 *         on fefers (`if (!ok) revert LpTransferFailed()`).
 *
 * @dev This is the shape the never-fail rule exists for. If the splitter's
 *      `receive()` reverts, this caller reverts, and on the real thing that
 *      meant every native mint bricked.
 */
contract SplitterFrozenCaller {
    error DownstreamFailed();

    function push(address payable to, uint256 amount) external payable {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert DownstreamFailed();
    }

    function pushWithSelector(address payable to, bytes calldata data, uint256 amount)
        external
        payable
    {
        (bool ok,) = to.call{value: amount}(data);
        if (!ok) revert DownstreamFailed();
    }

    receive() external payable {}
}

/// @dev A receiver that refuses native. Used to prove the OWNER escape hatches
///      (which are allowed to revert) behave, without touching a never-fail path.
contract SplitterRefusingReceiver {
    receive() external payable {
        revert("SplitterRefusingReceiver: no");
    }
}
