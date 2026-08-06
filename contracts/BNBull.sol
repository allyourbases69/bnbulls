// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BNBull
 * @notice The $BNBULL utility token — stake to duel, earn by winning, and the
 *         asset the game market-buys and locks in the no-withdraw BNBULL pot.
 *         Fixed supply, minted once at construction. There is no mint path.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ⚠ THIS MAY NOT BE THE TOKEN THAT SHIPS. `DECISIONS.md §4` picks
 *      **four.meme** as the launch venue, and a four.meme launch means the
 *      token contract is THEIRS, not this one. This contract is the fallback
 *      path: a plain fixed-supply BEP-20 for a self-seeded, LP-locked
 *      pancakeswap launch. It is built anyway so the choice stays open right
 *      up to launch week.
 *
 *      If four.meme issues the token instead, run the `BNB-CHAIN-FACTS.md §5`
 *      verify-at-launch checklist on whatever it deploys — above all that the
 *      token has **no transfer tax, no blacklist, no pause and no transfer
 *      hook**, because MintDrop, Duel, Graveyard and the Marketplace all call
 *      `transferFrom` and a transfer gate bricks every one of those flows.
 *
 *      ══════════════════════════════════════════════════════════════════
 *      THE ORDER-OF-OPERATIONS THAT CANNOT BE UNDONE
 *      ══════════════════════════════════════════════════════════════════
 *
 *        `liftLimits()`  MUST be called BEFORE `renounceOwnership()`.
 *        `lockBlacklist()` likewise, if you intend to lock it at all.
 *
 *      Renouncing first leaves `maxTx` / `maxWallet` clamped forever and the
 *      blacklist frozen in whatever state it happens to be in, with nobody
 *      able to lift either. Both switches are ONE-WAY on purpose, so the
 *      sequence is: enable trading → let the launch settle → lift limits →
 *      lock the blacklist → renounce. See `DEPLOY-SAFETY-PREFLIGHT.md`.
 *
 *      Anti-sniping arsenal (all of it optional, all of it one-way-disarmable):
 *        1. `tradingEnabled` defaults false; nothing but whitelisted setup
 *           transfers move until the owner calls `enableTrading()`.
 *        2. Anti-bot: for `antiBotBlocks` after trading opens, a transfer to a
 *           non-whitelisted CONTRACT reverts. Catches atomic block-0 snipers.
 *           It BLOCKS but does not auto-blacklist — a revert would discard the
 *           write and the log alike. See `_update` for why that is unfixable
 *           in-contract, and watch failed txs for `SniperBlocked` instead.
 *        3. `maxTx` / `maxWallet` caps during the launch window, bounded below
 *           so a compromised key cannot set them to dust and freeze trading.
 *        4. Manual blacklist, permanently seal-able via `lockBlacklist()`.
 */
contract BNBull is ERC20, Ownable {
    // ─── True security ceilings (the only things that may be `constant`) ──

    /// @notice Hard ceiling on the supply this contract can ever be deployed
    ///         with. Supply itself is a constructor argument and is fixed at
    ///         construction: a *settable* supply is a mint function, which is
    ///         the one thing a fixed-supply token must not have.
    uint256 public constant MAX_FIXED_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Floor on the launch caps, in basis points of total supply.
    ///         `maxTx` and `maxWallet` can never be set below 0.10% of supply,
    ///         so "tune the caps" can never become "freeze all trading".
    uint256 public constant MIN_LIMIT_BPS = 10;

    /// @notice Ceiling on the anti-bot window. Five blocks is already generous;
    ///         beyond it the auto-blacklist starts catching real aggregators.
    uint256 public constant MAX_ANTI_BOT_BLOCKS = 5;

    // ─── Supply ───────────────────────────────────────────────────────────

    /// @notice Total supply, minted in full at construction. Immutable.
    uint256 public immutable fixedSupply;

    // ─── Launch state ─────────────────────────────────────────────────────

    /// @notice Trading-enabled flag. Defaults false. ONE-WAY once flipped.
    bool public tradingEnabled;

    /// @notice Block trading was enabled at. Drives the anti-bot window.
    uint256 public launchBlock;

    /// @notice Blocks after `launchBlock` during which a non-whitelisted
    ///         contract receiving tokens is auto-blacklisted. Owner-settable
    ///         (bounded by MAX_ANTI_BOT_BLOCKS) but ONLY before trading opens —
    ///         after that the window is running and moving it is a trap.
    uint256 public antiBotBlocks = 1;

    /// @notice Per-tx cap while `limitsActive`. Defaults to 0.5% of supply.
    uint256 public maxTx;

    /// @notice Per-wallet cap while `limitsActive`. Defaults to 1% of supply.
    uint256 public maxWallet;

    /// @notice True while the caps are enforced. `liftLimits()` sets it false
    ///         permanently — there is no path back.
    bool public limitsActive = true;

    /// @notice Once true, no address can ever be ADDED to the blacklist again.
    ///         `unblacklist` keeps working, so the switch can only ever loosen
    ///         the token. ONE-WAY.
    bool public blacklistLocked;

    /// @notice Addresses exempt from every transfer restriction. Seeded with
    ///         the initial holder and the owner; the owner adds the LP router,
    ///         the pair, MintDrop, Duel, Graveyard and the Marketplace.
    mapping(address => bool) public whitelisted;

    /// @notice Blocked addresses (auto-added snipers plus manual entries).
    mapping(address => bool) public blacklisted;

    // ─── Socials (DECISIONS §5 — settable, handles and domains move) ──────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ───────────────────────────────────────────────────────────

    event TradingEnabled(uint256 atBlock);
    event LimitsLifted();
    event LimitsChanged(uint256 newMaxTx, uint256 newMaxWallet);
    event AntiBotBlocksChanged(uint256 newBlocks);
    event WhitelistedSet(address indexed addr, bool status);
    event Blacklisted(address indexed addr, string reason);
    event Unblacklisted(address indexed addr);
    event BlacklistLocked();
    event SocialsChanged(string website, string twitter, string telegram);

    // ─── Errors ───────────────────────────────────────────────────────────

    error ZeroInitialHolder();
    error ZeroSupply();
    error SupplyTooHigh(uint256 requested, uint256 cap);
    error TradingNotEnabled();
    error AlreadyEnabled();
    error LimitsAlreadyLifted();
    error LimitTooLow(uint256 requested, uint256 floorAmount);
    error AntiBotWindowTooLong(uint256 requested, uint256 cap);
    error TradingAlreadyOpen();
    error MaxTxExceeded(uint256 amount, uint256 cap);
    error MaxWalletExceeded(uint256 newBalance, uint256 cap);
    error AddrBlacklisted(address addr);
    error SniperBlocked(address addr);
    error BlacklistIsLocked();

    /**
     * @param initialHolder Receives the entire fixed supply.
     * @param initialOwner  Holds the limit-management keys. Cannot mint,
     *                      cannot pause transfers globally.
     * @param supply        Total supply in wei. Fixed forever at this value.
     */
    constructor(address initialHolder, address initialOwner, uint256 supply)
        ERC20("BNBull", "BNBULL") // ticker LOCKED, DECISIONS §13
        Ownable(initialOwner)
    {
        if (initialHolder == address(0)) revert ZeroInitialHolder();
        if (supply == 0) revert ZeroSupply();
        if (supply > MAX_FIXED_SUPPLY) revert SupplyTooHigh(supply, MAX_FIXED_SUPPLY);
        // initialOwner == 0 is rejected by OZ Ownable's constructor.

        fixedSupply = supply;
        _mint(initialHolder, supply);

        // Standard fair-launch openers: 1% wallet cap, 0.5% tx cap. Both
        // tunable (within MIN_LIMIT_BPS) until they are lifted for good.
        maxWallet = supply / 100;
        maxTx = supply / 200;

        whitelisted[initialOwner] = true;
        whitelisted[initialHolder] = true;
        emit WhitelistedSet(initialOwner, true);
        if (initialHolder != initialOwner) {
            emit WhitelistedSet(initialHolder, true);
        }
    }

    // ─── Owner: launch + limit management ─────────────────────────────────

    /// @notice ONE-WAY switch to open trading. Starts the anti-bot window.
    function enableTrading() external onlyOwner {
        if (tradingEnabled) revert AlreadyEnabled();
        tradingEnabled = true;
        launchBlock = block.number;
        emit TradingEnabled(block.number);
    }

    /// @notice Tune the anti-bot window. Only before trading opens: once the
    ///         window is running, moving it changes the rules mid-flight.
    function setAntiBotBlocks(uint256 blocks_) external onlyOwner {
        if (tradingEnabled) revert TradingAlreadyOpen();
        if (blocks_ > MAX_ANTI_BOT_BLOCKS) {
            revert AntiBotWindowTooLong(blocks_, MAX_ANTI_BOT_BLOCKS);
        }
        antiBotBlocks = blocks_;
        emit AntiBotBlocksChanged(blocks_);
    }

    /// @notice Add or remove an address from the transfer-restriction whitelist.
    function setWhitelist(address addr, bool status) external onlyOwner {
        whitelisted[addr] = status;
        emit WhitelistedSet(addr, status);
    }

    /// @notice Bulk whitelist for game-contract setup (router, pair, MintDrop,
    ///         Duel, Graveyard, Marketplace, both Jackpot pools).
    function setWhitelistBulk(address[] calldata addrs, bool status) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            whitelisted[addrs[i]] = status;
            emit WhitelistedSet(addrs[i], status);
        }
    }

    /**
     * @notice Tune the per-tx / per-wallet caps, both in BNBULL wei.
     * @dev Bounded BELOW at MIN_LIMIT_BPS of supply. Fighting Fefers let the
     *      owner set these to anything, which meant a compromised key could
     *      set `maxTx = 1` and halt the market without touching a pause flag.
     */
    function setLimits(uint256 newMaxTx, uint256 newMaxWallet) external onlyOwner {
        if (!limitsActive) revert LimitsAlreadyLifted();
        uint256 floorAmount = (fixedSupply * MIN_LIMIT_BPS) / 10_000;
        if (newMaxTx < floorAmount) revert LimitTooLow(newMaxTx, floorAmount);
        if (newMaxWallet < floorAmount) revert LimitTooLow(newMaxWallet, floorAmount);
        maxTx = newMaxTx;
        maxWallet = newMaxWallet;
        emit LimitsChanged(newMaxTx, newMaxWallet);
    }

    /**
     * @notice Lift the launch caps permanently. ONE-WAY.
     * @dev ⚠ CALL THIS BEFORE `renounceOwnership()`. Renounce first and the
     *      caps are enforced forever with nobody able to lift them.
     */
    function liftLimits() external onlyOwner {
        if (!limitsActive) revert LimitsAlreadyLifted();
        limitsActive = false;
        emit LimitsLifted();
    }

    /// @notice Manually blacklist a confirmed bot/scammer address.
    function blacklist(address addr, string calldata reason) external onlyOwner {
        if (blacklistLocked) revert BlacklistIsLocked();
        blacklisted[addr] = true;
        emit Blacklisted(addr, reason);
    }

    /// @notice Reverse a blacklist entry. Still available after
    ///         `lockBlacklist()`, because loosening is always safe.
    function unblacklist(address addr) external onlyOwner {
        blacklisted[addr] = false;
        emit Unblacklisted(addr);
    }

    /**
     * @notice Permanently disable ADDING blacklist entries. ONE-WAY.
     * @dev The blacklist is the one piece of this token that looks like a
     *      transfer gate to a scanner, and a transfer gate is exactly what
     *      bricks `transferFrom` in the game's flows. Sealing it is the
     *      strongest trust signal this contract can emit short of renouncing.
     *      ⚠ Call it BEFORE `renounceOwnership()` if you want it sealed.
     */
    function lockBlacklist() external onlyOwner {
        blacklistLocked = true;
        emit BlacklistLocked();
    }

    /// @notice Update the published socials. Handles and domains move.
    function setSocials(string calldata w, string calldata t, string calldata g)
        external
        onlyOwner
    {
        website = w;
        twitter = t;
        telegram = g;
        emit SocialsChanged(w, t, g);
    }

    // ─── Internal: transfer hook ──────────────────────────────────────────

    /// @dev OZ ERC-20 routes every transfer/mint/burn through `_update`.
    function _update(address from, address to, uint256 value) internal override {
        // Mint or burn: skip every restriction.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        if (blacklisted[from]) revert AddrBlacklisted(from);
        if (blacklisted[to]) revert AddrBlacklisted(to);

        bool fromWl = whitelisted[from];
        bool toWl = whitelisted[to];

        // Trading closed: only whitelisted setup transfers move.
        if (!tradingEnabled && !fromWl && !toWl) revert TradingNotEnabled();

        // Anti-bot window. EOAs always pass; only contract receivers are
        // caught, and whitelisted contracts bypass it entirely.
        //
        // ⚠ THIS BLOCKS, IT DOES NOT RECORD — AND IT CANNOT.
        //   An earlier version wrote `blacklisted[to] = true` and emitted
        //   `Blacklisted(to, "anti-bot")` immediately before reverting. A
        //   revert discards the whole state change AND every log in the frame,
        //   so neither ever happened: the flag never persisted, and a
        //   launch-day keeper subscribed to `Blacklisted` would have received
        //   nothing, ever, while believing it was watching. The docs described
        //   behaviour the contract did not have.
        //
        //   You cannot both reject a transfer and durably record its sender in
        //   the same call — the rejection is what erases the record. Blocking
        //   is the half that matters, so blocking is what this does; the revert
        //   carries the address so an off-chain watcher can pick sniper
        //   addresses off failed transactions and feed them to `setBlacklist`.
        if (
            tradingEnabled && antiBotBlocks > 0 && block.number <= launchBlock + antiBotBlocks
                && !fromWl && !toWl && to.code.length > 0
        ) {
            revert SniperBlocked(to);
        }

        // Launch-window caps.
        if (limitsActive && !fromWl && !toWl) {
            if (value > maxTx) revert MaxTxExceeded(value, maxTx);
            uint256 newBalance = balanceOf(to) + value;
            if (newBalance > maxWallet) revert MaxWalletExceeded(newBalance, maxWallet);
        }

        super._update(from, to, value);
    }
}
