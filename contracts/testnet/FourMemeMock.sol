// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockBnbull} from "./MockBnbull.sol";

/*
 ╔══════════════════════════════════════════════════════════════════════════╗
 ║  ⚠⚠⚠  TESTNET / TEST-ONLY ARTEFACT — NEVER DEPLOY THIS TO MAINNET  ⚠⚠⚠   ║
 ║                                                                          ║
 ║  This is NOT four.meme. It is not a fork, a port, or a clone of           ║
 ║  TokenManager2 `0x5c952063c7fc8610FFDB798152D69F0B9550762b`. A literal    ║
 ║  clone is IMPOSSIBLE and that is a finding, not an excuse:                ║
 ║                                                                          ║
 ║    * the implementation `0x12570c76…70e8` is UNVERIFIED on bscscan, so    ║
 ║      there is no source to copy (`FOUR-MEME-LAUNCH-ROUTE.md §7`);         ║
 ║    * it is an ERC-1967 UUPS proxy, so even byte-copying the runtime code  ║
 ║      would land on storage we cannot correctly initialise;                ║
 ║    * `createToken(bytes,bytes)` demands a SIGNED, SINGLE-USE, TIME-LIMITED║
 ║      backend request. Replaying a real one reverts `RequestTracing:       ║
 ║      executed request`; mutating the id reverts `Expired`. The signer key ║
 ║      is theirs (§3).                                                      ║
 ║                                                                          ║
 ║  So this reproduces the OBSERVABLE BEHAVIOURS OUR CONTRACTS INTERACT      ║
 ║  WITH, against a REAL PancakeSwap v2 on BSC testnet (chain 97).           ║
 ║                                                                          ║
 ║  The constructor REVERTS on chain 56.                                    ║
 ╚══════════════════════════════════════════════════════════════════════════╝
*/

/// @dev The real PancakeSwap v2 factory. On chain 97 that is
///      `0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc` — read off the router's own
///      `factory()`, not looked up in a doc.
interface IPancakeFactoryV2 {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @dev The real pair. `mint` is genuine constant-product LP issuance, including
///      the 1000-wei `MINIMUM_LIQUIDITY` locked at `address(0)` — which is
///      exactly the residue `FOUR-MEME-LAUNCH-ROUTE.md §5` measured on three
///      fork graduations and on two live mainnet graduates.
interface IPancakePairV2 {
    function mint(address to) external returns (uint256 liquidity);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function token0() external view returns (address);
}

interface IWBNB9 {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title FourMemeMock
 * @notice A behavioural stand-in for four.meme's TokenManager2: the bonding
 *         curve, the custodial transfer gate, `buyTokenAMAP`, and a graduation
 *         that creates a GENUINE PancakeSwap v2 pair through the REAL factory
 *         and burns the LP.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      REPRODUCED FAITHFULLY — with the evidence, not an assertion
 *      ══════════════════════════════════════════════════════════════════════
 *
 *      **1. `buyTokenAMAP(address,uint256,uint256)`, selector `0x87f27655`,
 *      payable in NATIVE BNB** (`FOUR-MEME-LAUNCH-ROUTE.md §3`, verified by
 *      sending real transactions on mainnet forks against Gort, BEAU, PUPP and
 *      构石). Every property our integration depends on is reproduced:
 *
 *        - **no EOA gate, no signature.** §3 proved a contract can call it
 *          twice over: a real mainnet tx `0xc7f889ee…` whose `to` is a 2206-byte
 *          contract, and a fork run impersonating the WBNB contract as caller.
 *        - **a real `minAmount` floor** that reverts **`Slippage`**. There is
 *          never an excuse for a blind buy.
 *        - **it returns NOTHING.** The only honest way to learn the amount out
 *          is a `balanceOf` delta — the discipline `BNB-CHAIN-FACTS §3` demands
 *          anyway. This mock returns nothing for exactly that reason: a test
 *          that reads a return value would not compile.
 *        - **overpayment is refunded**, so a contract caller needs a payable
 *          fallback or the refund reverts the buy. §9.1 calls this "a live
 *          footgun"; it is reproduced so our code can be made to trip on it
 *          here rather than on chain 56.
 *        - **tokens land with `msg.sender`** (or the explicit recipient on the
 *          4-argument overload `0x7f79f6df`).
 *        - **it reverts `Disabled` after graduation.** The call does not merely
 *          stop being useful, it FAILS — so a venue switch must be
 *          state-driven, never date-driven.
 *
 *      **2. The cost shape: you pay 111 to move the curve by 100.** §3 measured
 *      a 0.1 BNB buy on Gort splitting 0.090090090090 onto the curve /
 *      0.009009009009 to the founder / 0.000855855856 pad fee / 0.000045045045
 *      referral. That is `_tradingFeeRate = 100` (1.00% of the curve amount, of
 *      which `_referralRewardRate = 5` is peeled off) plus a creator-set
 *      `feeRateBuy` PERCENT of the curve amount. Both are settable here, so
 *      `feeRateBuy = 0` — the §9.4 launch-form target — can be rehearsed.
 *
 *      **3. Delivery is CUSTODIAL.** Bought tokens are handed over with the
 *      token's privileged `sendToken`, never `transfer`, because `transfer`
 *      reverts `"Token: Transfer is restricted"` even when the pad itself is the
 *      caller (§2).
 *
 *      **4. Graduation lands in PancakeSwap V2 against WBNB and the LP is
 *      BURNED** (§5, verified by executing three complete graduations on
 *      mainnet forks and reading two live mainnet graduates). Opening reserves
 *      were 17.64 WBNB / 200,000,000 tokens from an 18 BNB raise — 98% of the
 *      raise (2% retained by the pad) and 20% of supply. `lpRaiseBps` defaults
 *      to 9800 for that reason. LP goes straight to `0x…dEaD`, leaving only
 *      uniswap's 1000-wei MINIMUM_LIQUIDITY at `address(0)`.
 *
 *      Afterwards the gate is gone PERMANENTLY: `_mode` flips `1 -> 0` and the
 *      token's ownership renounces to `address(0)`, so `setMode` and
 *      `sendToken` can never be called again.
 *
 *      **5. Both production templates (`DECISIONS.md §30`).** `atomicGraduation`
 *      picks between them:
 *        - `true`  = template B: graduation happens INSIDE the filling buyer's
 *          own transaction. No keeper, no window. Carries the tax.
 *        - `false` = template A: the curve fills, status parks at
 *          `STATUS_ADDING_LIQUIDITY`, **and the token stays fully
 *          transfer-locked with the curve closed** until a `ROLE_OPERATOR`
 *          calls `addLiquidity(address)`. §4 reproduced that stall on PUPP and
 *          on a clean control fork, so it is the template's behaviour, not an
 *          artefact.
 *
 *      **6. The operator halt.** `suspendTrading(address,bool)` and a global
 *      `_tradingHalt()` exist on the live pad, gated to `ROLE_OPERATOR`
 *      (§2). **four.meme can freeze our curve**, and our never-fail paths have
 *      to survive that, so it is reproducible here.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      DELIBERATELY SIMPLIFIED — and why
 *      ══════════════════════════════════════════════════════════════════════
 *
 *      **The curve SHAPE is not the real one, and it cannot be.** §3 decoded
 *      `_tokenInfos` field-by-field from observed state transitions, but the
 *      pad's source is unverified and the `K` / `T` parameters were never
 *      resolved into a formula (§10). What IS known, and what this curve
 *      reproduces, is the contract our code integrates against: monotone
 *      increasing price, deterministic and quotable off chain, and it sells
 *      EXACTLY `maxOffers` tokens by the time `funds` reaches `maxRaising`
 *      (§5's 800M-on-the-curve / 200M-to-LP split). The shape used is
 *      `sold(f) = maxOffers * sqrt(f / maxRaising)` — a linear price ramp.
 *      **A test may not assert real four.meme prices off this.** The real curve
 *      is much steeper at the open: Gort's first 1.6036e-6 BNB bought 279.4
 *      tokens where this one would sell far more.
 *
 *      **`createToken(bytes,bytes)` reverts `Expired`, always.** Reproducing the
 *      signature scheme would be theatre — the point of §3's finding is that
 *      **the launch must go through four.meme's own front end and cannot be
 *      driven from a foundry script.** `launch()` is the deliberately
 *      differently-named, owner-gated door, so no script can ever mistake this
 *      for a self-serve create path.
 *
 *      **Quote asset is forced to native BNB (template 0).** §5 found 19 of the
 *      20 live templates graduate into a NON-BNB pool, and `DECISIONS.md §30`
 *      calls that a launch-form checkbox that silently kills the money layer.
 *      This mock REFUSES a non-zero quote rather than pretending to model
 *      CAKE/USDT/NVDAB pools. The refusal is the warning.
 *
 *      **Fee destinations are simplified.** The pad fee and referral reward are
 *      sent as native BNB immediately (and re-accrued if the recipient rejects
 *      them, so a hostile fee recipient can never brick a buy); the founder fee
 *      accrues and is paid at graduation. Live template B wraps the founder leg
 *      to WBNB and parks it in the TOKEN contract until graduation — a
 *      different route to the same measured outcome (§3 confirmed Gort's
 *      founder received exactly 1.8 BNB = 10% of an 18 BNB raise).
 *
 *      **`sellToken`, `buyToken` (exact-out), `lockLP`, `calcSellCost`,
 *      referral plumbing, the 20-template registry and the UUPS upgrade
 *      surface are absent.** None of them is on a path our contracts touch. The
 *      upgrade surface in particular is a RISK to re-verify at launch week
 *      (§7), not a behaviour to emulate.
 */
contract FourMemeMock {
    // ─── The mainnet guard ────────────────────────────────────────────────

    uint256 public constant BNB_MAINNET_CHAIN_ID = 56;

    string public constant TESTNET_ONLY_WARNING =
        "TESTNET/TEST ONLY. Not four.meme. Refuses to deploy on chain 56.";

    error MainnetDeploymentForbidden(uint256 chainId);

    // ─── Status constants, read off the live pad (§3) ─────────────────────

    uint8 public constant STATUS_TRADING = 0;
    uint8 public constant STATUS_HALT = 1;
    uint8 public constant STATUS_ADDING_LIQUIDITY = 2;
    uint8 public constant STATUS_COMPLETED = 3;

    /// @notice The real role hash, read off the live pad (§7). Kept so a
    ///         keeper's role-sweep tooling can be rehearsed against the same
    ///         constant it will use on chain 56.
    bytes32 public constant ROLE_OPERATOR =
        0xaa3edb77f7c8cc9e38e8afe78954f703aeeda7fffe014eeb6e56ea84e62f6da7;

    /// @notice Where the LP goes. §5: LP total 59,396.969616568150296050, LP at
    ///         DEAD 59,396.969616568150295050 — the 1000-wei difference is
    ///         uniswap's MINIMUM_LIQUIDITY at `address(0)`. Nobody can pull it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 private constant BPS = 10_000;

    // ─── The DEX this pad graduates into ──────────────────────────────────

    /// @notice The REAL PancakeSwap v2 factory. Chain 97:
    ///         `0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc`.
    IPancakeFactoryV2 public immutable pancakeFactory;
    /// @notice The REAL v2 router. Chain 97:
    ///         `0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3`. Recorded and handed
    ///         to the token as `PANCAKE_ROUTER()`; graduation seeds the pair
    ///         directly, the way the live pad's receipts show.
    address public immutable pancakeRouter;
    /// @notice The REAL WBNB. Chain 97:
    ///         `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`, which is what the
    ///         router's own `WETH()` answers. **BNB needs no mock** — it is
    ///         native, and WBNB is live.
    IWBNB9 public immutable wbnb;

    // ─── Roles ────────────────────────────────────────────────────────────

    /// @notice Stands in for the 3-of-6 Gnosis Safe that owns the live pad.
    address public owner;
    /// @notice `ROLE_OPERATOR` holders. On chain 56 these are four.meme's, not
    ///         ours, and §10 flags enumerating them as launch-week work.
    mapping(address => bool) public operators;
    /// @notice May call `launch`. The live analogue is `ROLE_DEPLOYER`.
    mapping(address => bool) public deployers;

    // ─── Pad-wide config (live getter names) ──────────────────────────────

    /// @notice Pad trading fee, bps of the CURVE amount. Live value: 100 (1.00%).
    uint256 public _tradingFeeRate = 100;
    /// @notice Referral slice, bps of the curve amount, PEELED OUT of the pad
    ///         fee rather than added on top. Live value: 5 (0.05%).
    uint256 public _referralRewardRate = 5;
    /// @notice Live value: 0. The "0.01 BNB launch fee" people quote is the
    ///         creator's own dev-buy at the UI layer, not an on-chain fee (§3).
    uint256 public _launchFee = 0;
    address public _feeRecipient;
    address public _referralRewardKeeper;
    /// @notice The global freeze. Live value: false — but it exists, and it is
    ///         four.meme's to flip.
    bool public _tradingHalt;
    /// @notice Per-token freeze, set by `suspendTrading`.
    mapping(address => bool) public suspended;
    uint256 public _tokenCount;

    /// @notice Share of the raise that becomes liquidity. §5 measured 17.64 of
    ///         18 BNB = 98%, identical on all three fork graduations.
    uint256 public lpRaiseBps = 9_800;

    // ─── Curve state ──────────────────────────────────────────────────────

    /**
     * @notice The `_tokenInfos` struct, in the field order §3 decoded off the
     *         live pad and confirmed against observed state transitions.
     * @dev ⚠ `config` is the one field whose MEANING is a guess (§10): it
     *      decodes byte-for-byte as `founder(20) ‖ 0×5 ‖ rateFounder ‖
     *      feeRateBuy ‖ feeRateSell ‖ …` but the pad's struct definition is not
     *      public. Packed the same way here so tooling can be rehearsed, and
     *      exposed through plain getters as well so no test has to depend on the
     *      guess.
     */
    struct TokenInfo {
        address base;
        /// ⚠ `address(0)` = NATIVE BNB = template 0. The ONLY template whose
        ///   graduated pool our WBNB pivot can reach (`DECISIONS.md §30`).
        address quote;
        bytes32 config;
        uint256 totalSupply;
        /// Tokens sellable on the curve. §3: 8e26 of a 1e27 supply (80%).
        uint256 maxOffers;
        /// The graduation threshold, in BNB wei. §3 read 18e18 on Gort.
        uint256 maxRaising;
        uint256 launchTime;
        /// Tokens still on the curve.
        uint256 offers;
        /// BNB raised onto the curve so far — NET of every fee.
        uint256 funds;
        uint256 lastPrice;
        uint256 K;
        uint256 T;
        uint8 status;
    }

    mapping(address => TokenInfo) private _infos;
    /// @notice Founder fee accrued per token, paid out at graduation (§3).
    mapping(address => uint256) public founderAccrued;
    /// @notice Percent of the curve amount the creator takes. Live observed
    ///         values: 1, 3, 10 — chosen by the creator, not fixed by the pad.
    mapping(address => uint256) public feeRateBuyOf;
    /// @notice Template B (atomic) vs template A (stalls for a keeper).
    mapping(address => bool) public atomicGraduationOf;
    /// @notice The v2 pair, once it exists.
    mapping(address => address) public pairOf;

    address[] public tokens;

    // ─── Events ───────────────────────────────────────────────────────────

    event TokenCreate(address indexed token, address indexed creator, uint256 totalSupply);
    event TokenPurchase(
        address indexed token,
        address indexed buyer,
        uint256 grossBnb,
        uint256 toCurve,
        uint256 amountOut
    );
    event FeeSplit(
        address indexed token, uint256 toCurve, uint256 founderFee, uint256 padFee, uint256 referral
    );
    event Graduated(
        address indexed token,
        address indexed pair,
        uint256 wbnbIn,
        uint256 tokensIn,
        uint256 lpBurned
    );
    event AwaitingOperator(address indexed token, uint256 raised);
    event TradingSuspended(address indexed token, bool suspended);
    event TradingHaltSet(bool halted);

    // ─── Errors ───────────────────────────────────────────────────────────

    /// @notice The live revert when `buyTokenAMAP` misses its floor.
    error Slippage();
    /// @notice The live revert when `buyTokenAMAP` is called after graduation.
    error Disabled();
    /// @notice The live revert when a `createToken` request is not a fresh,
    ///         signed, in-date one from four.meme's backend.
    error Expired();
    error TradingHalted();
    error MissingOperatorRole(address account);
    error NotOwner(address account);
    error NotDeployer(address account);
    error InsufficientValue(uint256 required, uint256 sent);
    error RefundFailed();
    error WrongStatus(uint8 status);
    /// @notice `DECISIONS.md §30`: 19 of 20 live templates graduate into a pool
    ///         our contracts cannot reach. This mock only models template 0.
    error NonNativeQuoteUnsupported(address quote);
    error BadConfig();

    // ─── Construction ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address factory_,
        address router_,
        address wbnb_,
        address feeRecipient_,
        address referralRewardKeeper_
    ) {
        if (block.chainid == BNB_MAINNET_CHAIN_ID) {
            revert MainnetDeploymentForbidden(block.chainid);
        }
        if (
            initialOwner == address(0) || factory_ == address(0) || router_ == address(0)
                || wbnb_ == address(0)
        ) revert BadConfig();
        owner = initialOwner;
        pancakeFactory = IPancakeFactoryV2(factory_);
        pancakeRouter = router_;
        wbnb = IWBNB9(wbnb_);
        _feeRecipient = feeRecipient_;
        _referralRewardKeeper = referralRewardKeeper_;
        operators[initialOwner] = true;
        deployers[initialOwner] = true;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @dev The live pad answers a random caller with
    ///      `BasicAccessControl: account … is missing role ROLE_OPERATOR` (§2).
    ///      A custom error is used here — no contract of ours ever calls an
    ///      operator function, so the exact string is not load-bearing.
    modifier onlyOperator() {
        if (!operators[msg.sender]) revert MissingOperatorRole(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Creation
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The real create entrypoint, selector `0x519ebb10`. **It always
     *         reverts, on purpose.**
     * @dev §3: `createToken` takes a SIGNED, SINGLE-USE, TIME-LIMITED request
     *      from four.meme's backend. Replaying a real mainnet create calldata
     *      from a different sender reverts `RequestTracing: executed request`;
     *      mutating the id so it is unused reverts `Expired`. **The launch must
     *      go through four.meme's front end — we cannot mint the token from a
     *      foundry script.** Keeping the door here and nailing it shut is the
     *      point: nobody reading this file can come away thinking otherwise.
     */
    function createToken(bytes calldata, bytes calldata) external payable {
        revert Expired();
    }

    struct LaunchParams {
        string name;
        string symbol;
        /// ⚠ NOT assumed to be 18.
        uint8 decimals;
        uint256 totalSupply;
        /// Tokens sellable on the curve. The remainder becomes the LP side.
        uint256 maxOffers;
        /// Graduation threshold in BNB wei. A TEST PARAMETER: set it to
        /// 0.01 ether and the whole lifecycle runs in one small buy instead of
        /// the 18 BNB a live curve needs.
        uint256 maxRaising;
        /// MUST be `address(0)`. See `NonNativeQuoteUnsupported`.
        address quote;
        address founder;
        /// Creator's founder fee, PERCENT of the curve amount. 0 is the §9.4
        /// target and is the value a clean rehearsal should use.
        uint256 feeRateBuy;
        uint256 feeRateSell;
        uint256 rateFounder;
        /// Template B tax master switch. Default it OFF.
        bool taxEnabled;
        /// true = template B (atomic graduation). false = template A (stalls at
        /// STATUS_ADDING_LIQUIDITY until an operator calls `addLiquidity`).
        bool atomicGraduation;
    }

    /**
     * @notice Create a curve-phase token. Deliberately NOT called `createToken`.
     * @dev The pad becomes the token's `owner()` and holds the whole float,
     *      which is what makes the curve phase custodial (§2, §3).
     */
    function launch(LaunchParams calldata p) external returns (address token) {
        if (!deployers[msg.sender]) revert NotDeployer(msg.sender);
        if (p.quote != address(0)) revert NonNativeQuoteUnsupported(p.quote);
        if (
            p.totalSupply == 0 || p.maxOffers == 0 || p.maxOffers > p.totalSupply
                || p.maxRaising == 0
        ) revert BadConfig();

        MockBnbull t = new MockBnbull(
            MockBnbull.InitParams({
                name: p.name,
                symbol: p.symbol,
                decimals: p.decimals,
                totalSupply: p.totalSupply,
                manager: address(this),
                founder: p.founder,
                taxEnabled: p.taxEnabled,
                feeRateBuy: p.feeRateBuy,
                feeRateSell: p.feeRateSell,
                rateFounder: p.rateFounder,
                pancakeFactory: address(pancakeFactory),
                pancakeRouter: pancakeRouter,
                weth: address(wbnb)
            })
        );
        token = address(t);

        _infos[token] = TokenInfo({
            base: token,
            quote: address(0),
            config: _packConfig(p.founder, p.rateFounder, p.feeRateBuy, p.feeRateSell),
            totalSupply: p.totalSupply,
            maxOffers: p.maxOffers,
            maxRaising: p.maxRaising,
            launchTime: block.timestamp,
            offers: p.maxOffers,
            funds: 0,
            lastPrice: 0,
            // ⚠ SHAPE PLACEHOLDERS. The live pad's K/T are real curve
            //   parameters whose formula was never resolved (§10). Populated
            //   with the two numbers that DO define this curve so the struct is
            //   never misleadingly zero.
            K: p.maxRaising,
            T: p.maxOffers,
            status: STATUS_TRADING
        });
        feeRateBuyOf[token] = p.feeRateBuy;
        atomicGraduationOf[token] = p.atomicGraduation;

        tokens.push(token);
        _tokenCount += 1;
        emit TokenCreate(token, msg.sender, p.totalSupply);
    }

    function _packConfig(address founder_, uint256 rateFounder, uint256 buy, uint256 sell)
        private
        pure
        returns (bytes32)
    {
        return bytes32(
            (uint256(uint160(founder_)) << 96) | (rateFounder << 16) | (buy << 8) | sell
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The curve buy
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Buy on the curve. Selector `0x87f27655`. Payable in NATIVE BNB.
     *
     * @param token     The curve-phase token.
     * @param funds     GROSS BNB to spend, fees included. §3 measured a 0.1 BNB
     *                  `funds` splitting 90.09% onto the curve, 9.01% to the
     *                  founder, 0.86% pad fee and 0.045% referral — **you pay
     *                  111 to move the curve by 100**.
     * @param minAmount Hard slippage floor. Missing it reverts `Slippage`.
     *
     * @dev ⚠ RETURNS NOTHING, exactly like the live call. The caller MUST
     *      measure a `balanceOf` delta. Anything else is a router-reported
     *      number, and the whole `BNB-CHAIN-FACTS §3` lesson is not to trust
     *      one.
     *
     *      ⚠ `msg.value` above `funds` is REFUNDED, so a contract caller
     *      without a payable fallback reverts on the refund. That is the live
     *      footgun §9.1 names, kept sharp.
     */
    function buyTokenAMAP(address token, uint256 funds, uint256 minAmount) external payable {
        _buy(token, msg.sender, funds, minAmount);
    }

    /// @notice The 4-argument overload, selector `0x7f79f6df`, with an explicit
    ///         recipient. Present on the live pad (§3).
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external
        payable
    {
        _buy(token, to, funds, minAmount);
    }

    /// @dev The four legs of a buy, measured the way §3 measured them off a real
    ///      receipt. Held in a struct rather than as locals purely so `_buy`
    ///      stays inside the EVM's stack depth.
    struct BuySplit {
        uint256 toCurve;
        uint256 padFee;
        uint256 referral;
        uint256 founderFee;
        uint256 spend;
    }

    function _buy(address token, address to, uint256 funds, uint256 minAmount) private {
        TokenInfo storage info = _infos[token];

        // ⚠ `Disabled`, not "no-op". §3: after graduation the call FAILS. A
        //   venue switch has to be state-driven, not date-driven.
        if (info.status != STATUS_TRADING) revert Disabled();
        if (_tradingHalt || suspended[token]) revert TradingHalted();
        if (msg.value < funds) revert InsufficientValue(funds, msg.value);
        if (funds == 0) revert BadConfig();

        BuySplit memory s = _splitBuy(token, funds, info.maxRaising - info.funds);
        if (s.toCurve == 0) revert Disabled();
        if (s.spend > msg.value) revert InsufficientValue(s.spend, msg.value);

        uint256 amountOut = _advanceCurve(info, s.toCurve, minAmount);
        founderAccrued[token] += s.founderFee;

        // ── Delivery is CUSTODIAL: `sendToken`, never `transfer` ──────────
        MockBnbull(token).sendToken(address(this), to, amountOut);

        emit FeeSplit(token, s.toCurve, s.founderFee, s.padFee, s.referral);
        emit TokenPurchase(token, to, s.spend, s.toCurve, amountOut);

        // ── Fees out. A rejecting recipient must never brick a buy. ───────
        _payOrKeep(_feeRecipient, s.padFee);
        _payOrKeep(_referralRewardKeeper, s.referral);

        // ── Refund. A contract caller needs a payable fallback. ───────────
        if (msg.value > s.spend) {
            (bool ok,) = msg.sender.call{value: msg.value - s.spend}("");
            if (!ok) revert RefundFailed();
        }

        if (info.funds >= info.maxRaising) _fill(token);
    }

    /// @dev **You pay 111 to move the curve by 100.** `funds` is the GROSS
    ///      spend; the curve amount is what is left after the pad's 1% and the
    ///      creator's `feeRateBuy` percent, and the referral slice is peeled OUT
    ///      of the pad fee rather than added on top (§3).
    ///
    ///      Capped at `room` so an overpaying buyer fills the curve exactly and
    ///      gets the rest back instead of overshooting the threshold.
    function _splitBuy(address token, uint256 funds, uint256 room)
        private
        view
        returns (BuySplit memory s)
    {
        s.toCurve = (funds * BPS) / _grossMultiplier(token);
        if (s.toCurve > room) s.toCurve = room;

        uint256 padFeeTotal = (s.toCurve * _tradingFeeRate) / BPS;
        s.referral = (s.toCurve * _referralRewardRate) / BPS;
        if (s.referral > padFeeTotal) s.referral = padFeeTotal;
        s.padFee = padFeeTotal - s.referral;
        s.founderFee = (s.toCurve * feeRateBuyOf[token]) / 100;
        s.spend = s.toCurve + padFeeTotal + s.founderFee;
    }

    /// @dev Move the curve and book the tokens out. `minAmount` is a HARD floor
    ///      — missing it reverts `Slippage`, exactly like the live call.
    function _advanceCurve(TokenInfo storage info, uint256 toCurve, uint256 minAmount)
        private
        returns (uint256 amountOut)
    {
        uint256 fundsAfter = info.funds + toCurve;
        amountOut = _soldAt(info, fundsAfter) - _soldAt(info, info.funds);
        if (amountOut > info.offers) amountOut = info.offers;
        if (amountOut == 0 || amountOut < minAmount) revert Slippage();

        info.funds = fundsAfter;
        info.offers -= amountOut;
        info.lastPrice = (toCurve * 1e18) / amountOut;
    }

    /// @dev `10_000 + tradingFeeRate + feeRateBuy * 100`. With the live values
    ///      (100 and 10) that is 11_100 — 111 paid to move the curve by 100.
    function _grossMultiplier(address token) private view returns (uint256) {
        return BPS + _tradingFeeRate + feeRateBuyOf[token] * 100;
    }

    function _payOrKeep(address to, uint256 amount) private {
        if (amount == 0 || to == address(0)) return;
        (bool ok,) = to.call{value: amount}("");
        // Failure is not fatal: the pad simply keeps it. A hostile fee
        // recipient cannot be allowed to freeze the curve.
        ok;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The curve
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev `sold(f) = maxOffers * sqrt(f / maxRaising)`.
     *
     *      ⚠ NOT the real four.meme curve — see the header. It is monotone, has
     *      an increasing marginal price, is exactly quotable off chain, and
     *      lands on EXACTLY `maxOffers` at `f == maxRaising`, which is the only
     *      property §5's 800M/200M graduation split actually pins down.
     */
    function _soldAt(TokenInfo storage info, uint256 f) private view returns (uint256) {
        if (f == 0) return 0;
        if (f >= info.maxRaising) return info.maxOffers;
        uint256 ratio = Math.sqrt((f * 1e36) / info.maxRaising);
        return (info.maxOffers * ratio) / 1e18;
    }

    /// @notice Tokens a GROSS spend of `funds` would buy right now. The live pad
    ///         exposes `calcBuyAmount` for exactly this — off-chain quoting, so
    ///         `minAmount` can be keeper-pegged without an oracle (§9.1).
    function calcBuyAmount(address token, uint256 funds) public view returns (uint256) {
        TokenInfo storage info = _infos[token];
        if (info.base == address(0) || info.status != STATUS_TRADING) return 0;
        uint256 toCurve = (funds * BPS) / _grossMultiplier(token);
        uint256 room = info.maxRaising - info.funds;
        if (toCurve > room) toCurve = room;
        uint256 out = _soldAt(info, info.funds + toCurve) - _soldAt(info, info.funds);
        return out > info.offers ? info.offers : out;
    }

    /// @notice GROSS BNB needed to buy `amount` tokens right now.
    function calcBuyCost(address token, uint256 amount) external view returns (uint256) {
        TokenInfo storage info = _infos[token];
        if (info.base == address(0) || amount == 0) return 0;
        uint256 target = _soldAt(info, info.funds) + amount;
        if (target > info.maxOffers) target = info.maxOffers;
        uint256 r = (target * 1e18) / info.maxOffers;
        uint256 fTarget = (info.maxRaising * r * r) / 1e36;
        if (fTarget <= info.funds) return 0;
        uint256 toCurve = fTarget - info.funds;
        return (toCurve * _grossMultiplier(token) + BPS - 1) / BPS;
    }

    /// @notice The pad's own cut of a curve amount. Live name kept.
    function calcTradingFee(uint256 toCurve) external view returns (uint256) {
        return (toCurve * _tradingFeeRate) / BPS;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Graduation
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The curve has filled. Template B graduates here, inside the buyer's
    ///      own transaction. Template A parks and waits for a keeper.
    function _fill(address token) private {
        TokenInfo storage info = _infos[token];
        info.status = STATUS_ADDING_LIQUIDITY;
        if (atomicGraduationOf[token]) {
            _graduate(token);
        } else {
            // ⚠ TEMPLATE A'S TRAP (§4). The curve is closed, the token is still
            //   `_mode() == 1`, still owned by the pad, still fully
            //   transfer-locked — and it stays that way until four.meme's
            //   keeper shows up. The whole game stays frozen for however long
            //   they take.
            emit AwaitingOperator(token, info.funds);
        }
    }

    /**
     * @notice Finish a template-A graduation. `ROLE_OPERATOR` only, exactly like
     *         the live `addLiquidity(address)` / `0xe3412e3d`, where a random
     *         EOA gets `BasicAccessControl: … missing role ROLE_OPERATOR` (§4).
     */
    function addLiquidity(address token) external onlyOperator {
        if (_infos[token].status != STATUS_ADDING_LIQUIDITY) {
            revert WrongStatus(_infos[token].status);
        }
        _graduate(token);
    }

    function _graduate(address token) private {
        TokenInfo storage info = _infos[token];
        MockBnbull t = MockBnbull(token);

        // ── A GENUINE pair, through the REAL factory ──────────────────────
        // ⚠ If a griefer pre-created it, we REUSE it. §6: the pair address is
        //   deterministic per token pair, so there is no "which v2 pair is
        //   real" ambiguity to exploit — and a pre-created one can never hold a
        //   token balance, because seeding it reverts on the transfer gate.
        address pair = pancakeFactory.getPair(token, address(wbnb));
        if (pair == address(0)) pair = pancakeFactory.createPair(token, address(wbnb));
        pairOf[token] = pair;
        t.setPair(pair);

        uint256 lpTokens = info.totalSupply - info.maxOffers;
        uint256 lpBnb = (info.funds * lpRaiseBps) / BPS;

        // The custodial move — untaxed, and the reason §5 measured EXACTLY
        // 200,000,000 tokens in a 10%-tax token's opening reserves.
        t.sendToken(address(this), pair, lpTokens);

        wbnb.deposit{value: lpBnb}();
        require(wbnb.transfer(pair, lpBnb), "FourMemeMock: wbnb transfer failed");

        // Real constant-product LP issuance, straight to the burn address.
        uint256 lp = IPancakePairV2(pair).mint(BURN_ADDRESS);

        // ── The gate lifts, permanently ───────────────────────────────────
        t.setMode(t.MODE_NORMAL());
        // ⚠ ORDER MATTERS: every owner-gated call must happen BEFORE this.
        //   Afterwards the token has no reachable admin function at all.
        t.renounceOwnership();

        info.status = STATUS_COMPLETED;

        uint256 owed = founderAccrued[token];
        founderAccrued[token] = 0;
        _payOrKeep(t.founder(), owed);

        emit Graduated(token, pair, lpBnb, lpTokens, lp);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Operator / owner surface
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Freeze one token's curve. `ROLE_OPERATOR` on the live pad — i.e.
    ///         **four.meme can freeze our curve** (§2).
    function suspendTrading(address token, bool on) external onlyOperator {
        suspended[token] = on;
        emit TradingSuspended(token, on);
    }

    /// @notice The global freeze. Live value reads `false` today.
    function setTradingHalt(bool on) external onlyOperator {
        _tradingHalt = on;
        emit TradingHaltSet(on);
    }

    function grantOperator(address a) external onlyOwner {
        operators[a] = true;
    }

    function revokeOperator(address a) external onlyOwner {
        operators[a] = false;
    }

    function grantDeployer(address a) external onlyOwner {
        deployers[a] = true;
    }

    /// @notice ⚠ TEST DIAL. Move the graduation threshold so a rehearsal can
    ///         fill the curve in one small buy instead of 18 BNB.
    function setMaxRaising(address token, uint256 maxRaising) external onlyOwner {
        TokenInfo storage info = _infos[token];
        if (info.status != STATUS_TRADING) revert WrongStatus(info.status);
        if (maxRaising == 0) revert BadConfig();
        info.maxRaising = maxRaising;
        info.K = maxRaising;
    }

    /// @notice ⚠ TEST DIAL. `100` reproduces the live 1.00% pad fee.
    function setTradingFeeRate(uint256 bps) external onlyOwner {
        if (bps > BPS) revert BadConfig();
        _tradingFeeRate = bps;
    }

    /// @notice ⚠ TEST DIAL. `5` reproduces the live 0.05% referral slice.
    function setReferralRewardRate(uint256 bps) external onlyOwner {
        if (bps > BPS) revert BadConfig();
        _referralRewardRate = bps;
    }

    /// @notice ⚠ TEST DIAL. `9_800` reproduces the measured 98% of the raise.
    function setLpRaiseBps(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > BPS) revert BadConfig();
        lpRaiseBps = bps;
    }

    /// @notice Set the creator's founder fee while the pad still owns the token.
    ///         `0` is the `§9.4` target.
    function setFeeRateBuy(address token, uint256 percent) external onlyOwner {
        if (_infos[token].status != STATUS_TRADING) revert WrongStatus(_infos[token].status);
        if (percent > MockBnbull(token).MAX_FEE_RATE()) revert BadConfig();
        feeRateBuyOf[token] = percent;
    }

    /// @notice Turn the template-B tax on or off before graduation.
    ///         **Off is the default and the safe answer** (`§9.4`).
    function setTokenTax(address token, bool enabled, uint256 buy, uint256 sell, uint256 rateFounder)
        external
        onlyOwner
    {
        MockBnbull(token).setFees(enabled, buy, sell, rateFounder);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The live getter name and field order (§3).
    function _tokenInfos(address token) external view returns (TokenInfo memory) {
        return _infos[token];
    }

    function statusOf(address token) external view returns (uint8) {
        return _infos[token].status;
    }

    function fundsOf(address token) external view returns (uint256) {
        return _infos[token].funds;
    }

    function offersOf(address token) external view returns (uint256) {
        return _infos[token].offers;
    }

    function maxRaisingOf(address token) external view returns (uint256) {
        return _infos[token].maxRaising;
    }

    /// @notice True while `buyTokenAMAP` can still be called. The state-driven
    ///         switch §9.1 requires, rather than a date.
    function curveOpen(address token) external view returns (bool) {
        return _infos[token].status == STATUS_TRADING && !_tradingHalt && !suspended[token];
    }
}
