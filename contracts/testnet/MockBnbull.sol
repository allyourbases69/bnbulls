// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
 ╔══════════════════════════════════════════════════════════════════════════╗
 ║  ⚠⚠⚠  TESTNET / TEST-ONLY ARTEFACT — NEVER DEPLOY THIS TO MAINNET  ⚠⚠⚠   ║
 ║                                                                          ║
 ║  This is NOT the BNBULL token. The real BNBULL is minted by four.meme's  ║
 ║  TokenManager2 on chain 56 through a SIGNED, SINGLE-USE backend request  ║
 ║  we cannot forge (`FOUR-MEME-LAUNCH-ROUTE.md §3`), and its implementation ║
 ║  source is unverified. This file reproduces only the BEHAVIOURS OUR       ║
 ║  CONTRACTS TOUCH, so the whole lifecycle can be rehearsed on BSC testnet  ║
 ║  (chain 97) before a single announcement is made.                        ║
 ║                                                                          ║
 ║  The constructor REVERTS on chain 56. That guard is the structural        ║
 ║  answer to "must never be deployable to mainnet by accident" — it is not  ║
 ║  a comment, it is a hard stop.                                           ║
 ╚══════════════════════════════════════════════════════════════════════════╝
*/

/**
 * @title MockBnbull
 * @notice A behavioural stand-in for a four.meme template-B token, gated by a
 *         `FourMemeMock` pad exactly the way the live pad gates a live token.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT IS REPRODUCED, AND WHERE THE EVIDENCE IS
 *      ══════════════════════════════════════════════════════════════════════
 *
 *      1. **THE TRANSFER GATE — the single most important behaviour.**
 *         Pre-graduation `transfer` / `transferFrom` revert with EXACTLY
 *         `"Token: Transfer is restricted"`. `FOUR-MEME-LAUNCH-ROUTE.md §2`
 *         verified this three ways: bytecode strings, a live `eth_call` from a
 *         real holder of Gort `0xe7069592CfbC6F0c95F36e81865107ce2ddbFffF`,
 *         and a real transaction on a mainnet fork. Reproduced across three
 *         token templates (Gort, 构石, 道).
 *
 *         ⚠ It reverts for EVERY holder, including the pad itself — §2 records
 *         that a direct `transfer()` called from TokenManager2's own address
 *         reverts with the same string. So the gate here is unconditional in
 *         restricted mode; the pad delivers through `sendToken` instead.
 *
 *         `DECISIONS.md §28.1`: this is not a buyback inconvenience. The 10%
 *         BNBULL discount, BNBULL fight stakes and BNBULL marketplace payments
 *         are ALL dead for the whole curve phase, because every one of them
 *         moves BNBULL with `transferFrom`.
 *
 *      2. **`approve` works during the restricted phase** and returns `true`,
 *         so allowances can be pre-staged. VERIFIED, §2.
 *
 *      3. **`transferFrom` with NO allowance reverts on the allowance check
 *         FIRST**, which is why an allowance-less probe is misleading and must
 *         not be used as evidence the gate is open. §2 calls this out
 *         explicitly. The ordering here matches. ⚠ The allowance revert STRING
 *         is an inference: `Token: Invalid transfer` is one of the strings §2
 *         disassembled out of the live token, but it was never proven to be the
 *         one the allowance branch uses.
 *
 *      4. **After graduation the gate is gone permanently.** `_mode()` flips
 *         `1 -> 0`, `owner()` becomes `address(0)` (ownership renounced), so
 *         `setMode` can never be called again and `sendToken` reverts
 *         `Not allowed`. Plain `transfer` and third-party `transferFrom` then
 *         move the EXACT amount, with no max-tx and no max-wallet. All
 *         VERIFIED on fork, §2.
 *
 *      5. **The template-B tax (`DECISIONS.md §30`, route §4).** A creator-set
 *         buy AND sell tax, `amount * rate / 100`, hooking ONLY on transfers
 *         where `from == pair` or `to == pair`. Wallet-to-wallet moves are
 *         clean either way — measured on BEAU (`feeRateBuy = feeRateSell = 10`)
 *         where a 1e24 wallet transfer moved 1e24 exactly while a router buy
 *         came out 10% short and a non-fee-supporting `swapExactTokensForETH`
 *         reverted `Pancake: K`.
 *
 *         **It is a FLAG AND IT DEFAULTS OFF**, so the taxed path is only ever
 *         exercised deliberately. `feeRateBuy = feeRateSell = 0` (template B
 *         with zero rates) is the outcome `§9.4` wants from the launch form,
 *         and it is this contract's default for that reason.
 *
 *      6. **`decimals()` IS A CONSTRUCTOR PARAMETER.** four.meme issues the
 *         real token, so "BEP-20s are usually 18" is not evidence
 *         (`DECISIONS.md §4`, `PotSplitter`'s decimals note). Every consumer
 *         must READ it. A non-18dp run is one constructor argument away.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      DELIBERATELY NOT REPRODUCED — see the report, these still need a
 *      mainnet-fork test
 *      ══════════════════════════════════════════════════════════════════════
 *        - `MODE_TRANSFER_CONTROLLED (2)` semantics. The constant exists on the
 *          live token but no specimen was ever observed in it, so its exact
 *          rules are UNKNOWN. Here it behaves as restricted; do not read that
 *          as evidence.
 *        - `isBlacklisted(address)` (`0xfe575a87`). Present in the live
 *          bytecode, reverts when called, cause unresolved (§2). Absent here.
 *        - `TOKEN_HELPER_5()` / `SHARE_HOLDER_MANAGER()` constants, `claimFee`,
 *          `swapForToken`, `rateBurn`, `feeToLiquidity`. Present on template B,
 *          none of them on any path our contracts touch.
 *        - The fee DESTINATION. Live template B wraps the founder leg to WBNB
 *          and parks it in the token contract until graduation; here the tax
 *          simply lands on `founder`. The observable our code cares about — the
 *          recipient receives `amount - fee` — is identical.
 *        - Whether `feeRateBuy = 0` is actually accepted by the live creation
 *          path. §10 lists that as the single most important thing to check on
 *          our own token; it cannot be settled here.
 */
contract MockBnbull {
    // ─── The mainnet guard ────────────────────────────────────────────────

    /// @notice Chain id of BNB Smart Chain mainnet. Deployment here is refused.
    uint256 public constant BNB_MAINNET_CHAIN_ID = 56;

    /// @notice Loud, on-chain, readable by any explorer or preflight script.
    string public constant TESTNET_ONLY_WARNING =
        "TESTNET/TEST ONLY. Not the real BNBULL. Refuses to deploy on chain 56.";

    error MainnetDeploymentForbidden(uint256 chainId);

    // ─── ERC-20 ───────────────────────────────────────────────────────────

    string public name;
    string public symbol;

    /**
     * @notice ⚠ READ THIS, NEVER ASSUME IT. A constructor parameter on purpose:
     *         four.meme issues the real token and 18 is an EXPECTATION, not a
     *         fact (`DECISIONS.md §4`). Every divisor in the money layer is
     *         supposed to come off this getter.
     */
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ─── The four.meme surface ────────────────────────────────────────────

    /// @notice Mode constants, read off a live token (§2).
    uint256 public constant MODE_NORMAL = 0;
    uint256 public constant MODE_TRANSFER_RESTRICTED = 1;
    uint256 public constant MODE_TRANSFER_CONTROLLED = 2;

    uint256 private _modeValue;

    /// @notice The pad during the curve phase; `address(0)` after graduation.
    ///         VERIFIED: `owner()` on a live pre-graduation token returns
    ///         TokenManager2, and on a graduated one returns the zero address.
    address public owner;

    /// @notice The three DEX addresses. Compile-time constants inside the live
    ///         token; constructor arguments here so the SAME contract can be
    ///         pointed at chain 97's PancakeSwap instead of chain 56's.
    address public immutable PANCAKE_FACTORY;
    address public immutable PANCAKE_ROUTER;
    address public immutable WETH;

    /// @notice The creator's payout address (`founder()` on template B).
    address public founder;

    /// @notice The v2 pair, set at graduation. The tax hooks ONLY on transfers
    ///         where this address is one of the two sides.
    address public pair;

    // ─── The template-B tax (DEFAULT OFF) ─────────────────────────────────

    /// @notice Master switch for `DECISIONS.md §30` template B. **False by
    ///         default** — the taxed path is opt-in, never a surprise.
    bool public taxEnabled;
    /// @notice Percent (not bps) taken when `from == pair`. Observed live
    ///         values: 1, 3 and 10 across one sample window (§4).
    uint256 public feeRateBuy;
    /// @notice Percent taken when `to == pair`.
    uint256 public feeRateSell;
    /// @notice Kept because it is part of the live getter set; unused here.
    uint256 public rateFounder;

    /**
     * @notice `require(feeRateBuy <= 10)` / `require(feeRateSell <= 10)`.
     * @dev ⚠ WEAKER EVIDENCE. §4 read these bounds off the bscscan source page
     *      through a summariser, NOT off a contract call, and no live token with
     *      a rate of 0 was found to prove the lower end. Treat as a lead.
     */
    uint256 public constant MAX_FEE_RATE = 10;

    event ModeChanged(uint256 previous, uint256 next);
    event PairSet(address indexed pair);
    event FeesSet(bool enabled, uint256 feeRateBuy, uint256 feeRateSell, uint256 rateFounder);
    event OwnershipRenounced(address indexed previous);
    event TaxTaken(address indexed from, address indexed to, uint256 fee, bool isBuy);

    // ─── Construction ─────────────────────────────────────────────────────

    struct InitParams {
        string name;
        string symbol;
        /// ⚠ NOT assumed to be 18.
        uint8 decimals;
        /// Whole supply, in the token's own units.
        uint256 totalSupply;
        /// The pad. Becomes `owner()` AND receives the entire float, exactly as
        /// the live pad holds 999,999,720.6 of a 1e27 supply at creation (§3).
        address manager;
        address founder;
        bool taxEnabled;
        uint256 feeRateBuy;
        uint256 feeRateSell;
        uint256 rateFounder;
        address pancakeFactory;
        address pancakeRouter;
        address weth;
    }

    constructor(InitParams memory p) {
        if (block.chainid == BNB_MAINNET_CHAIN_ID) {
            revert MainnetDeploymentForbidden(block.chainid);
        }
        require(p.manager != address(0), "MockBnbull: manager is zero");
        require(p.feeRateBuy <= MAX_FEE_RATE, "Token: invalid feeRateBuy");
        require(p.feeRateSell <= MAX_FEE_RATE, "Token: invalid feeRateSell");
        require(!p.taxEnabled || p.founder != address(0), "MockBnbull: taxed with no founder");

        name = p.name;
        symbol = p.symbol;
        decimals = p.decimals;
        founder = p.founder;
        taxEnabled = p.taxEnabled;
        feeRateBuy = p.feeRateBuy;
        feeRateSell = p.feeRateSell;
        rateFounder = p.rateFounder;
        PANCAKE_FACTORY = p.pancakeFactory;
        PANCAKE_ROUTER = p.pancakeRouter;
        WETH = p.weth;

        owner = p.manager;
        // ⚠ The curve phase is CUSTODIAL. The whole float lives in the pad and
        //   moves only through `sendToken` (§2).
        _modeValue = MODE_TRANSFER_RESTRICTED;
        totalSupply = p.totalSupply;
        balanceOf[p.manager] = p.totalSupply;
        emit Transfer(address(0), p.manager, p.totalSupply);
    }

    // ─── Ownership, with the live revert STRING ───────────────────────────

    /**
     * @dev ⚠ The string is deliberate. §2 records an impersonated `setMode`
     *      call on a graduated token reverting `Ownable: caller is not the
     *      owner` — the OpenZeppelin **v4** message. This repo is on OZ v5,
     *      whose `Ownable` reverts with the custom error
     *      `OwnableUnauthorizedAccount` instead, so inheriting it would have
     *      produced a revert shape the real token does not have. Hand-rolled
     *      for fidelity.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        _;
    }

    /// @notice The live getter name. `_mode() == 1` on every pre-graduation
    ///         specimen sampled; `0` after graduation. VERIFIED.
    function _mode() external view returns (uint256) {
        return _modeValue;
    }

    function setMode(uint256 newMode) external onlyOwner {
        require(newMode <= MODE_TRANSFER_CONTROLLED, "Token: invalid mode");
        emit ModeChanged(_modeValue, newMode);
        _modeValue = newMode;
    }

    function setPair(address newPair) external onlyOwner {
        pair = newPair;
        emit PairSet(newPair);
    }

    function setFees(bool enabled, uint256 buy, uint256 sell, uint256 rateFounder_)
        external
        onlyOwner
    {
        require(buy <= MAX_FEE_RATE, "Token: invalid feeRateBuy");
        require(sell <= MAX_FEE_RATE, "Token: invalid feeRateSell");
        require(!enabled || founder != address(0), "MockBnbull: taxed with no founder");
        taxEnabled = enabled;
        feeRateBuy = buy;
        feeRateSell = sell;
        rateFounder = rateFounder_;
        emit FeesSet(enabled, buy, sell, rateFounder_);
    }

    /**
     * @notice Renounce to `address(0)`, one way, forever.
     * @dev This is what makes the post-graduation guarantees REAL rather than
     *      promised: with no owner there is no reachable admin function left on
     *      the token, so the gate cannot come back and the supply cannot be
     *      touched. VERIFIED on the live graduated specimens (§2, §7).
     */
    function renounceOwnership() external onlyOwner {
        emit OwnershipRenounced(owner);
        owner = address(0);
    }

    // ─── The privileged delivery path ─────────────────────────────────────

    /**
     * @notice Move `amount` from `from` to `to` with no allowance and no gate —
     *         the ONLY way tokens move during the curve phase.
     * @dev Selector `0x2fdcfbd2`, present in the live token's bytecode (§2).
     *      Owner-gated, so during the curve phase the pad can move ANY holder's
     *      balance: **treat the curve phase as custodial.**
     *
     *      Reverts `Not allowed` once the token is in `MODE_NORMAL`, which is
     *      exactly what §2 measured against a graduated token — the pad has zero
     *      custody power afterwards.
     *
     *      ⚠ It also bypasses the tax. That is not a shortcut: §5 measured the
     *      opening reserves of a graduated template-B token (BEAU, 10% tax) at
     *      exactly 200,000,000 tokens, so the pad's own seeding of the pair was
     *      demonstrably untaxed.
     */
    function sendToken(address from, address to, uint256 amount) external onlyOwner {
        require(_modeValue != MODE_NORMAL, "Not allowed");
        _move(from, to, amount);
    }

    // ─── ERC-20, gated ────────────────────────────────────────────────────

    /// @notice Works even during the restricted phase, returning `true`, so
    ///         allowances can be pre-staged. VERIFIED (§2).
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @dev ⚠ THE ALLOWANCE CHECK COMES FIRST, ON PURPOSE. §2: "with no
     *      allowance it reverts on the allowance check first, which is why an
     *      allowance-less probe is misleading — do not use one." A test that
     *      wants to prove the GATE must stage an allowance first, and this
     *      ordering is what forces it to.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "Token: Invalid transfer");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev The gate, then the tax. Both live here so there is exactly one place
     *      either can be reasoned about.
     */
    function _transfer(address from, address to, uint256 amount) private {
        // ═══════════════════════════════════════════════════════════════════
        // THE GATE. The exact string, byte for byte, from three independent
        // verifications in `FOUR-MEME-LAUNCH-ROUTE.md §2`. Unconditional:
        // even the pad gets this on a plain `transfer`.
        // ═══════════════════════════════════════════════════════════════════
        if (_modeValue != MODE_NORMAL) {
            revert("Token: Transfer is restricted");
        }
        require(to != address(0), "Token: invalid recipient");

        uint256 fee = 0;
        if (taxEnabled && pair != address(0)) {
            if (from == pair) {
                fee = (amount * feeRateBuy) / 100;
                if (fee != 0) emit TaxTaken(from, to, fee, true);
            } else if (to == pair) {
                fee = (amount * feeRateSell) / 100;
                if (fee != 0) emit TaxTaken(from, to, fee, false);
            }
        }

        if (fee == 0) {
            _move(from, to, amount);
        } else {
            _move(from, to, amount - fee);
            _move(from, founder, fee);
        }
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "Token: Invalid transfer");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
