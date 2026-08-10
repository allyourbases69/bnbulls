// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

/**
 * @dev The one-pot-per-duel lock, implemented by the Duel contract. Two
 *      Jackpot deployments both open a ticket for the same fight; whichever
 *      one's ticket resolves into a WIN first claims the duel and the other
 *      is denied. See `Duel.claimJackpotForDuel`.
 */
interface IDuelJackpotLock {
    function claimJackpotForDuel(uint256 duelKey) external returns (bool claimed);
}

/// @dev Wrapped BNB. `deposit()` and `withdraw()` are both 1:1 — no router, no
///      liquidity, no slippage. Both selectors verified present in the deployed
///      BSC WBNB bytecode (`0xbb4C…095c`): `d0e30db0` and `2e1a7d4d`.
interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title JackpotNative
 * @notice A no-withdraw prize pool, held and paid in **native BNB**, that fires
 *         at random to duel winners.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS EXISTS — THE LAST PLAYER-FACING WBNB
 *      ══════════════════════════════════════════════════════════════════════
 *      `Jackpot.sol` holds an ERC-20 and pays with `prizeToken.safeTransfer`,
 *      so a jackpot winner receives **WBNB tokens into their wallet**. That is
 *      the last place a player touches WBNB, and it cannot be fixed by UI or by
 *      replacing Duel — `prizeToken` is `immutable`.
 *
 *      ⚠ THE ORIGINAL'S OBJECTION WAS CORRECT, AND IS ANSWERED — NOT IGNORED.
 *      `Jackpot.sol` argued for ERC-20 on one specific ground: a native payout
 *      is a `.call{value:}` to an arbitrary winner, and a winner that is a
 *      contract with a reverting `receive()` would revert the resolve loop and
 *      **WEDGE THE QUEUE PERMANENTLY** in a contract with no withdraw path.
 *      That reasoning is sound and this contract does not hand-wave it away.
 *      It removes the premise instead: **resolution never sends anything.** A
 *      win is a storage write to `owed[winner]`, which cannot revert for any
 *      winner, and the winner pulls it later with `withdraw`. A broken
 *      `receive()` now only ever hurts its own owner, and the queue cannot be
 *      wedged by anybody. Same pattern as `DuelNative.bnbCredit`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      TWO FUNDING DOORS, AND WHY THE OLD ONE SURVIVES
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop` and the three splitters are DEPLOYED and immutable. Their pot
 *      leg is hard-coded as `forceApprove(pot, amount); pot.fund(amount, src)`
 *      — an ERC-20 pull of WBNB. A pot that only accepted `msg.value` could not
 *      be funded by any of them, which would drag MintDrop, MintBnbullSplitter,
 *      ReviveBuySplitter and MarketPotSplitter into the migration.
 *
 *      So `fund(uint256,string)` KEEPS ITS EXACT SIGNATURE AND SEMANTICS: it
 *      pulls WBNB by `transferFrom` exactly as before, then **unwraps it in the
 *      same call**. WBNB is a transient accounting hop that lives for a few
 *      opcodes inside one transaction and is never the resting form of the pot.
 *      The player never sees it, the pot is native, and four deployed contracts
 *      keep working untouched.
 *
 *      `fundNative()` is the door for anything deployed after this — including
 *      `DuelNative`, whose "last wrap in the system" comment points squarely at
 *      this contract as the reason those four lines still exist.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT `pool()` MEANS NOW
 *      ══════════════════════════════════════════════════════════════════════
 *      The old pool was `prizeToken.balanceOf(this)`. The native pool is
 *      `address(this).balance - totalOwed`, because this contract's balance now
 *      holds two different kinds of money: the pot, and prizes already won but
 *      not yet withdrawn. Netting `totalOwed` out is what stops an unclaimed
 *      prize being re-awarded to the next winner.
 *
 *      A plain BNB transfer in is still a donation, exactly as before — it
 *      raises the balance without raising `totalOwed`.
 *
 *      Everything else — the two-phase ticket, the VRF trust wire, the
 *      snapshotted terms, `MIN_ODDS_ONE_IN`, the `address(this)` roll term, the
 *      one-pot-per-duel lock, CEI around ticket retirement — is carried over
 *      unchanged. Each of those encodes an incident; read `Jackpot.sol` for the
 *      stories.
 */
contract JackpotNative is VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── The prize ────────────────────────────────────────────────────────

    /**
     * @notice The wrapper this pot unwraps through on the compatibility path.
     *
     * @dev NOT the prize. The prize is native BNB. This is here only so the
     *      deployed MintDrop/splitter pot legs — which can only speak
     *      `transferFrom` — still work; see the header.
     */
    IWBNB public immutable wbnb;

    // ─── Prizes won but not yet collected ─────────────────────────────────

    /**
     * @notice Prize won and not yet withdrawn, per winner.
     *
     * @dev ⛔ THE REASON A NATIVE POT IS SAFE AT ALL. Paying inside `resolve`
     *      would be a `.call{value:}` to an arbitrary winner inside a loop; one
     *      winner with a reverting `receive()` would revert the batch and strand
     *      every later ticket forever, in a contract with no withdraw path.
     *      Crediting is a storage write. It cannot revert, for anyone.
     */
    mapping(address => uint256) public owed;

    /**
     * @notice Sum of every entry in `owed`.
     *
     * @dev THE SOLVENCY INVARIANT, and the reason `pool()` subtracts it:
     *
     *          address(this).balance >= totalOwed
     *          pool()               == address(this).balance - totalOwed
     *
     *      Without the subtraction an unclaimed prize would still read as pot
     *      money and could be awarded a second time.
     */
    uint256 public totalOwed;

    // ─── Odds + payout (owner-settable, hard-bounded) ─────────────────────

    /// @notice A ticket wins with probability 1 / oddsOneIn.
    uint256 public oddsOneIn;
    /// @notice Share of the pool paid on a win, in basis points.
    uint256 public payoutBps = 10_000;
    /// @notice The pool must hold at least this much before a ticket can win.
    uint256 public minPoolToFire;

    uint256 public constant MAX_ODDS_ONE_IN = 1_000_000;

    /**
     * @notice ⛔ TRUE SECURITY FLOOR ON THE ODDS DENOMINATOR. `oddsOneIn = 1`
     *         means `H % 1 == 0` for every possible word — a CERTAIN win.
     * @dev Carried over verbatim from `Jackpot.sol`, where it was found by
     *      reproducing a four-transaction pool drain end to end. The pool left
     *      through a *chosen win*, so no function named "withdraw" was involved
     *      and the surface sweep still passed.
     */
    uint256 public constant MIN_ODDS_ONE_IN = 10;

    // ─── The payout terms of the batch in flight (snapshotted) ────────────

    /**
     * @dev ⛔ `resolve` MUST NOT READ THE LIVE ODDS/PAYOUT/FLOOR. IT READS THESE.
     *      The batch RANGE is fixed at request time so batching gives nobody
     *      anything to grind; leaving the three numbers that decide WHETHER a
     *      ticket wins reading live storage handed all of that back — the owner
     *      could watch the word land and only then choose the terms it would be
     *      judged under. Snapshotted with the range, promoted with the word.
     */
    uint256 public pendingOdds;
    uint256 public pendingPayoutBps;
    uint256 public pendingMinPool;

    uint256 public resolveOdds;
    uint256 public resolvePayoutBps;
    uint256 public resolveMinPool;

    // ─── Payout-parameter timelock ────────────────────────────────────────

    uint256 public proposedOdds;
    uint256 public proposedPayoutBps;
    uint256 public proposedMinPool;
    uint64 public payoutParamsEta;

    /// @notice One free instant write, for deploy day. See `Jackpot.sol`.
    bool public payoutParamsBootstrapped;

    // ─── Wiring ───────────────────────────────────────────────────────────

    /// @dev Timelocked: a malicious Duel could open tickets naming itself.
    TimelockedAddress.Slot private _duelWire;

    /**
     * @dev ⛔ THE RANDOMNESS SOURCE IS A MONEY SLOT. `setCoordinator` is
     *      owner-callable with no timelock and is not `virtual`, so whoever
     *      delivers the word must be tracked here instead and
     *      `fulfillRandomWords` must refuse anyone else. Without this the owner
     *      swaps in a coordinator they control, grinds a word satisfying the
     *      roll offline (~`odds` keccaks, free) and takes the pool.
     */
    TimelockedAddress.Slot private _coordinatorWire;

    uint256 public wiringDelay = 24 hours;
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;

    mapping(address => bool) public isFunder;
    mapping(address => bool) public isRequester;

    uint256 public publicRequestDelayBlocks = 1_200;
    uint256 public constant MAX_PUBLIC_REQUEST_DELAY_BLOCKS = 200_000;

    // ─── Tickets ──────────────────────────────────────────────────────────

    struct Ticket {
        address winner;
        uint64 openedAtBlock;
        uint256 tokenId;
        uint256 entropy;
        uint256 duelKey;
    }

    Ticket[] public tickets;
    uint256 public nextToResolve;

    // ─── VRF request state (one request in flight at a time) ──────────────

    uint256 public pendingRequestId;
    uint64 public pendingRequestedAtBlock;
    uint64 public pendingUntil;

    uint256 public resolveWord;
    uint64 public resolveUntil;
    bool public wordReady;

    /// @notice Blocks after which a stalled request may be cancelled by anyone.
    /// @dev MEASURED, not guessed. The first live fulfilment on chain 97 took
    ///      3,169 blocks; a keeper obeying the old 1_200 would have cancelled a
    ///      request that was about to be answered. The unit is the trap — this
    ///      bounds ORACLE LATENCY, which is time, but counts BLOCKS, so every
    ///      BSC block-time reduction silently shortens it.
    uint256 public requestTimeoutBlocks = 24_000;
    uint256 public constant MAX_REQUEST_TIMEOUT_BLOCKS = 200_000;

    // ─── VRF configuration (owner-settable, bounded) ──────────────────────

    bytes32 public keyHash;
    uint256 public subscriptionId;
    uint16 public requestConfirmations = 3;
    uint32 public callbackGasLimit = 200_000;
    bool public payWithNative = true;

    uint16 public constant MIN_REQUEST_CONFIRMATIONS = 3;
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;

    // ─── Stats ────────────────────────────────────────────────────────────

    uint256 public totalFunded;
    uint256 public totalAwarded;
    uint256 public awardCount;

    // ─── Socials (DECISIONS §5) ───────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ───────────────────────────────────────────────────────────

    event Funded(address indexed from, uint256 amount, string source);
    /// @notice WBNB arrived on the compatibility path and was unwrapped to
    ///         native in the same call. The receipt that the pot is native.
    event FundUnwrapped(address indexed from, uint256 amount);
    event TicketOpened(
        uint256 indexed ticketId,
        address indexed winner,
        uint256 indexed tokenId,
        uint64 openedAtBlock
    );
    event RandomnessRequested(
        uint256 indexed requestId, uint64 fromTicket, uint64 untilTicket, address indexed by
    );
    event RandomnessFulfilled(uint256 indexed requestId, uint64 untilTicket);
    event RequestCancelled(uint256 indexed requestId, address indexed by);
    event TicketResolved(
        uint256 indexed ticketId,
        address indexed winner,
        uint256 indexed tokenId,
        uint256 roll,
        uint256 oddsOneIn,
        bool won
    );
    event Awarded(address indexed winner, uint256 indexed tokenId, uint256 amount, uint256 ticketId);
    /// @notice The prize is now claimable by the winner. Paired with `Awarded`.
    event PrizeCredited(address indexed winner, uint256 amount, uint256 owedAfter);
    event PrizeWithdrawn(address indexed winner, uint256 amount, uint256 owedAfter);
    event ExclusivityDenied(uint256 indexed ticketId, address indexed winner, uint256 duelKey);
    event StrayWbnbAbsorbed(uint256 amount);
    event DuelWireBootstrapped(address indexed target);
    event DuelWireProposed(address indexed target, uint64 eta);
    event DuelWireCommitted(address indexed previous, address indexed next);
    event DuelWireCancelled(address indexed dropped);
    event CoordinatorWireProposed(address indexed target, uint64 eta);
    event CoordinatorWireCommitted(address indexed previous, address indexed next);
    event CoordinatorWireCancelled(address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event FunderChanged(address indexed funder, bool allowed);
    event RequesterChanged(address indexed requester, bool allowed);
    event OddsChanged(uint256 oddsOneIn);
    event PayoutParamsProposed(
        uint256 oddsOneIn, uint256 payoutBps, uint256 minPoolToFire, uint64 eta
    );
    event PayoutParamsCancelled(uint256 oddsOneIn, uint256 payoutBps, uint256 minPoolToFire);
    event PayoutBpsChanged(uint256 payoutBps);
    event MinPoolToFireChanged(uint256 minPool);
    event VrfConfigChanged(
        bytes32 keyHash,
        uint256 subscriptionId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        bool payWithNative
    );
    event TimeoutsChanged(uint256 requestTimeoutBlocks, uint256 publicRequestDelayBlocks);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event SocialsChanged(string website, string twitter, string telegram);

    // ─── Errors ───────────────────────────────────────────────────────────
    // ⚠ `ZeroAddress`, `OnlyCoordinatorCanFulfill` and `OnlyOwnerOrCoordinator`
    // are declared by VRFConsumerBaseV2Plus. Do not redeclare them here.

    error BadAddress();
    error NotDuel();
    error NotFunder();
    error NotRequester();
    error InvalidOdds(uint256 oddsOneIn);
    error PayoutParamsAlreadyBootstrapped();
    error NothingProposed();
    error PayoutParamsNotElapsed(uint64 eta, uint64 nowTs);
    error InvalidShare(uint256 bps);
    error DelayOutOfRange(uint256 requested);
    error RequestInFlight(uint256 requestId);
    error BatchStillOpen();
    error NothingToResolve();
    error NoRequestInFlight();
    error TimeoutNotElapsed(uint64 requestedAt, uint256 timeoutBlocks);
    /// @dev The pot is native and WBNB is only ever a transient hop, so neither
    ///      can be swept out. See `sweepForeignToken`.
    error PrizeIsNotSweepable();
    error VrfNotConfigured();
    error UntrustedCoordinator(address caller);
    error BadVrfConfig();
    error ValueOutOfRange(uint256 requested, uint256 cap);
    error ZeroAmount();
    error NothingOwed(address who);
    error InsufficientOwed(address who, uint256 wanted, uint256 held);
    error WithdrawFailed();
    error UnwrapShortfall(uint256 wanted, uint256 got);

    /**
     * @param _wbnb        WBNB, for the compatibility funding path only. BSC
     *                     mainnet: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c.
     * @param _owner       Intended owner. ConfirmedOwner is two-step, so this
     *                     address must call `acceptOwnership()` after deploy.
     * @param _coordinator Chainlink VRF v2.5 coordinator. BSC mainnet:
     *                     0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9.
     * @param _oddsOneIn   Odds denominator, e.g. 75.
     */
    constructor(address _wbnb, address _owner, address _coordinator, uint256 _oddsOneIn)
        VRFConsumerBaseV2Plus(_coordinator)
    {
        if (_wbnb == address(0)) revert BadAddress();
        // Same floor the setters enforce — a pot deployed at odds of 1 would be
        // drainable from block one, before any timelock could matter.
        if (_oddsOneIn < MIN_ODDS_ONE_IN || _oddsOneIn > MAX_ODDS_ONE_IN) {
            revert InvalidOdds(_oddsOneIn);
        }
        wbnb = IWBNB(_wbnb);
        oddsOneIn = _oddsOneIn;
        _coordinatorWire.bootstrap(_coordinator);
        if (_owner != address(0) && _owner != msg.sender) {
            transferOwnership(_owner);
        }
    }

    // ─── Views ────────────────────────────────────────────────────────────

    /**
     * @notice Current prize pool, in native BNB.
     * @dev Balance MINUS prizes already won but not yet collected. Without the
     *      subtraction an unwithdrawn prize would read as pot money and could
     *      be handed to a second winner.
     */
    function pool() public view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 reserved = totalOwed;
        // Cannot underflow while the solvency invariant holds; clamped anyway
        // so a view can never revert and wedge a keeper or the UI.
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice What a winning ticket would take home right now.
    function pendingPayout() external view returns (uint256) {
        return (pool() * payoutBps) / 10_000;
    }

    function ticketCount() external view returns (uint256) {
        return tickets.length;
    }

    function pendingTickets() external view returns (uint256) {
        return tickets.length - nextToResolve;
    }

    function duel() public view returns (address) {
        return _duelWire.current;
    }

    function duelWire() external view returns (address current, address pending, uint64 eta) {
        return (_duelWire.current, _duelWire.pending, _duelWire.eta);
    }

    function resolvable() external view returns (bool) {
        return wordReady && nextToResolve < resolveUntil;
    }

    function requestable() external view returns (bool) {
        return pendingRequestId == 0 && !wordReady && nextToResolve < tickets.length;
    }

    // ─── Funding ──────────────────────────────────────────────────────────

    /**
     * @notice Pull `amount` of WBNB from the caller and unwrap it into the
     *         native pool. THE COMPATIBILITY DOOR.
     *
     * @dev ⚠ THE SIGNATURE AND THE PULL SEMANTICS ARE LOAD-BEARING, NOT LEGACY.
     *      `MintDrop` and the three splitters are deployed and immutable, and
     *      their pot leg is hard-coded `forceApprove(pot, amount);
     *      pot.fund(amount, source)`. Change this shape and all four have to be
     *      redeployed with this contract. Keeping it means the WBNB they hold
     *      is unwrapped here, in the same transaction, and the pot rests native.
     *
     *      Booked as a MEASURED DELTA on both legs — the pull is measured in
     *      WBNB (a lying token cannot inflate `totalFunded`) and the unwrap is
     *      measured in native (a lying wrapper cannot short the pot silently).
     */
    function fund(uint256 amount, string calldata source) external nonReentrant {
        if (!isFunder[msg.sender]) revert NotFunder();
        if (amount == 0) return;

        uint256 beforeWbnb = wbnb.balanceOf(address(this));
        IERC20(address(wbnb)).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = wbnb.balanceOf(address(this)) - beforeWbnb;
        if (received == 0) return;

        uint256 credited = _unwrap(received);
        totalFunded += credited;
        emit Funded(msg.sender, credited, source);
    }

    /**
     * @notice Fund the pool with native BNB. The door for anything deployed
     *         after this contract — `DuelNative`'s pot leg above all, whose
     *         "last wrap in the system" exists only because the old pot could
     *         not accept native.
     */
    function fundNative(string calldata source) external payable {
        if (!isFunder[msg.sender]) revert NotFunder();
        if (msg.value == 0) return;
        totalFunded += msg.value;
        emit Funded(msg.sender, msg.value, source);
    }

    /// @notice Dev top-up in native BNB. Owner-only, always allowed.
    function topUp() external payable onlyOwner {
        if (msg.value == 0) return;
        totalFunded += msg.value;
        emit Funded(msg.sender, msg.value, "dev-topup");
    }

    /**
     * @notice Unwrap any WBNB sitting here into the pool. Permissionless.
     *
     * @dev The canonical path unwraps atomically, so WBNB only ever rests here
     *      if somebody transferred it in directly by mistake. This gives that
     *      money to the players rather than leaving it as a foreign token an
     *      owner could sweep — which is why `sweepForeignToken` refuses WBNB.
     */
    function absorbStrayWbnb() external nonReentrant {
        uint256 held = wbnb.balanceOf(address(this));
        if (held == 0) return;
        uint256 credited = _unwrap(held);
        totalFunded += credited;
        emit StrayWbnbAbsorbed(credited);
    }

    /// @dev WBNB -> native, measured. A wrapper that shorts us must revert here
    ///      rather than quietly leave the pot smaller than `totalFunded` says.
    function _unwrap(uint256 amount) private returns (uint256 got) {
        uint256 beforeNative = address(this).balance;
        wbnb.withdraw(amount);
        got = address(this).balance - beforeNative;
        if (got < amount) revert UnwrapShortfall(amount, got);
        emit FundUnwrapped(msg.sender, got);
    }

    /**
     * @dev Native in. Two legitimate senders: WBNB paying out an unwrap, and
     *      anybody donating to the pot. Both simply raise the balance, which
     *      raises `pool()`, which is exactly right — a donation belongs to the
     *      players and there is no path that takes it back out.
     */
    receive() external payable {}

    // ─── Collecting a prize ───────────────────────────────────────────────

    /**
     * @notice Withdraw a prize you have won.
     *
     * @dev ⚠ CHECKS-EFFECTS-INTERACTIONS, and the only place this contract
     *      sends native on purpose. `owed` is debited BEFORE the call, so a
     *      re-entrant `receive()` finds the ledger already settled and its
     *      second withdrawal reverts on its own arithmetic even if the guard
     *      were somehow absent. `nonReentrant` is the belt; CEI is the braces.
     *
     *      Shares the guard with `resolve` and `fund`, so a hostile `receive()`
     *      cannot re-enter the resolve loop mid-batch either.
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 held = owed[msg.sender];
        if (held < amount) revert InsufficientOwed(msg.sender, amount, held);

        unchecked {
            owed[msg.sender] = held - amount;
            totalOwed -= amount;
        }
        emit PrizeWithdrawn(msg.sender, amount, held - amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Collect the lot.
    function withdrawAll() external nonReentrant {
        uint256 held = owed[msg.sender];
        if (held == 0) revert NothingOwed(msg.sender);

        unchecked {
            owed[msg.sender] = 0;
            totalOwed -= held;
        }
        emit PrizeWithdrawn(msg.sender, held, 0);

        (bool ok,) = msg.sender.call{value: held}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @dev THE ONE PLACE A PRIZE IS EVER CREATED. Cannot revert — that is the
    ///      entire reason a native pot is safe. See the `owed` header.
    function _creditPrize(address winner, uint256 amount) private {
        uint256 next = owed[winner] + amount;
        owed[winner] = next;
        totalOwed += amount;
        emit PrizeCredited(winner, amount, next);
    }

    // ─── Phase 1: open a ticket ───────────────────────────────────────────

    /**
     * @notice Open a jackpot ticket for a duel winner. Duel-only. Cannot revert
     *         on any normal input, and never pays out here: the outcome is not
     *         knowable yet, which is the whole point.
     */
    function recordWin(address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        external
        returns (uint256 ticketId)
    {
        if (msg.sender != _duelWire.current) revert NotDuel();
        if (winner == address(0)) return type(uint256).max;

        ticketId = tickets.length;
        tickets.push(
            Ticket({
                winner: winner,
                openedAtBlock: uint64(block.number),
                tokenId: tokenId,
                entropy: entropy,
                duelKey: duelKey
            })
        );
        emit TicketOpened(ticketId, winner, tokenId, uint64(block.number));
    }

    // ─── Phase 2a: ask VRF for the deciding word ──────────────────────────

    function requestResolve(uint256 maxTickets) external returns (uint256 requestId) {
        if (keyHash == bytes32(0) || subscriptionId == 0) revert VrfNotConfigured();
        if (pendingRequestId != 0) revert RequestInFlight(pendingRequestId);
        if (wordReady) revert BatchStillOpen();

        uint256 from = nextToResolve;
        uint256 total = tickets.length;
        if (from >= total) revert NothingToResolve();
        if (maxTickets == 0) revert NothingToResolve();

        if (!isRequester[msg.sender] && msg.sender != owner()) {
            uint64 oldest = tickets[from].openedAtBlock;
            if (block.number < uint256(oldest) + publicRequestDelayBlocks) revert NotRequester();
        }

        uint256 until_ = from + maxTickets;
        if (until_ > total) until_ = total;

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: payWithNative})
                )
            })
        );

        pendingRequestId = requestId;
        pendingRequestedAtBlock = uint64(block.number);
        pendingUntil = uint64(until_);

        // ⛔ THE TERMS ARE FIXED HERE, WITH THE RANGE, BEFORE THE WORD EXISTS.
        pendingOdds = oddsOneIn;
        pendingPayoutBps = payoutBps;
        pendingMinPool = minPoolToFire;

        emit RandomnessRequested(requestId, uint64(from), uint64(until_), msg.sender);
    }

    /// @dev The VRF callback. It stores the word and nothing else — paying out
    ///      here would put the work under the coordinator's callback gas limit,
    ///      and a callback that runs out of gas loses the randomness for good.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        // ⛔ The word must come from the TIMELOCKED coordinator, not merely from
        //    whatever `s_vrfCoordinator` currently points at.
        if (msg.sender != _coordinatorWire.current) revert UntrustedCoordinator(msg.sender);
        if (requestId != pendingRequestId) return;
        resolveWord = randomWords[0];
        resolveUntil = pendingUntil;
        resolveOdds = pendingOdds;
        resolvePayoutBps = pendingPayoutBps;
        resolveMinPool = pendingMinPool;
        wordReady = true;
        pendingRequestId = 0;
        pendingUntil = 0;
        emit RandomnessFulfilled(requestId, resolveUntil);
    }

    function cancelStalledRequest() external {
        uint256 id = pendingRequestId;
        if (id == 0) revert NoRequestInFlight();
        if (block.number <= uint256(pendingRequestedAtBlock) + requestTimeoutBlocks) {
            revert TimeoutNotElapsed(pendingRequestedAtBlock, requestTimeoutBlocks);
        }
        pendingRequestId = 0;
        pendingUntil = 0;
        emit RequestCancelled(id, msg.sender);
    }

    // ─── Phase 2b: resolve the batch ──────────────────────────────────────

    /**
     * @notice Resolve up to `max` tickets from the fulfilled batch.
     *         Permissionless, and stops rather than reverting when there is
     *         nothing to do — Duel nudges this on its way past and must never
     *         be reverted by it.
     *
     * @dev `nonReentrant` because a win now touches `owed`/`totalOwed`. It
     *      makes no external call that could re-enter (crediting is a storage
     *      write and `_claimDuel` is a low-level call to the timelocked Duel),
     *      but the guard is shared with `withdraw`, which closes the door on a
     *      winner's `receive()` re-entering a batch mid-loop.
     */
    function resolve(uint256 max) external nonReentrant returns (uint256 resolved) {
        if (!wordReady) return 0;

        uint256 word = resolveWord;
        // The NATIVE pool, net of prizes already owed. Read once and decremented
        // locally, exactly as the ERC-20 version did with its balance.
        uint256 balance = pool();
        uint256 stop = resolveUntil;

        // ⛔ THE SNAPSHOT, NOT LIVE STORAGE. Repointing any of these three at
        //    `oddsOneIn` / `minPoolToFire` / `payoutBps` reopens the
        //    four-transaction pool drain — see `MIN_ODDS_ONE_IN`.
        uint256 odds = resolveOdds;
        uint256 minPool = resolveMinPool;
        uint256 bps = resolvePayoutBps;

        while (resolved < max && nextToResolve < stop) {
            uint256 id = nextToResolve;
            Ticket memory t = tickets[id];

            // ⚠ `address(this)` IS LOAD-BEARING. DO NOT REMOVE IT.
            //
            // Both pools are ticketed on every decisive duel and those two
            // tickets share every other input: same entropy, tokenId, winner
            // and ticket index. Without a per-pool term the two pools hash an
            // IDENTICAL preimage whenever they are decided by the same word,
            // and if one odds denominator divides the other, every win on the
            // longer pot comes with a win on the shorter one — which claims the
            // duel key first, so the second pot pays out NEVER. Measured on
            // Stable before this term existed: 600 duels, 7 payouts on one pot,
            // 0 on the other.
            uint256 roll = uint256(
                keccak256(
                    abi.encodePacked(word, t.entropy, t.tokenId, t.winner, id, address(this))
                )
            ) % odds;

            bool won = roll == 0 && balance >= minPool && balance > 0;
            uint256 paid;
            if (won) {
                paid = (balance * bps) / 10_000;
                won = paid > 0;
            }

            // Retire the ticket BEFORE the first external call of the loop.
            // `_claimDuel` reaches into another contract; if that contract ever
            // re-entered `resolve` while the cursor still pointed here, the
            // outer frame would write the cursor back and hand the inner
            // frame's tickets out a second time. CEI removes the question.
            nextToResolve = id + 1;
            resolved += 1;

            // ⚠ ONE POT PER DUEL. The only place the two pools are arbitrated,
            // and it sits here rather than in the duel transaction because by
            // now the deciding word exists.
            if (won && t.duelKey != 0) {
                if (!_claimDuel(t.duelKey)) {
                    won = false;
                    paid = 0;
                    emit ExclusivityDenied(id, t.winner, t.duelKey);
                }
            }

            emit TicketResolved(id, t.winner, t.tokenId, roll, odds, won);

            if (won) {
                balance -= paid;
                totalAwarded += paid;
                awardCount += 1;
                emit Awarded(t.winner, t.tokenId, paid, id);
                // ⛔ A STORAGE WRITE, NOT A TRANSFER. See the `owed` header:
                //    sending here would let one winner with a reverting
                //    `receive()` revert the batch and strand every later ticket.
                _creditPrize(t.winner, paid);
            }
        }

        if (nextToResolve >= stop) {
            wordReady = false;
            resolveWord = 0;
            resolveUntil = 0;
        }
    }

    /**
     * @dev Ask the Duel contract for the exclusive right to pay `duelKey`.
     *
     *      Low-level `call` rather than try/catch on purpose: a `duel` that is
     *      an EOA returns success with EMPTY returndata, and try/catch does NOT
     *      catch a return-data decode failure — it would revert the whole
     *      resolve loop.
     *
     *      ⚠ THE DECODE IS `uint256`, NOT `bool`, AND THAT IS LOAD-BEARING.
     *      `abi.decode(ret, (bool))` reverts on any 32-byte word that is not
     *      exactly 0 or 1, which the length guard does not catch. If it fired,
     *      `resolve` would revert on that ticket forever and every later ticket
     *      would be stranded.
     *
     *      FAILURE IS TREATED AS DENIED. If the lock is unreachable we cannot
     *      prove the other pot did not already pay, and "never both pots" is the
     *      invariant that matters.
     */
    function _claimDuel(uint256 duelKey) private returns (bool) {
        address d = _duelWire.current;
        if (d == address(0) || d.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            d.call(abi.encodeCall(IDuelJackpotLock.claimJackpotForDuel, (duelKey)));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == 1;
    }

    // ─── Admin: wiring ────────────────────────────────────────────────────

    function bootstrapDuel(address _duel) external onlyOwner {
        _duelWire.bootstrap(_duel);
        emit DuelWireBootstrapped(_duel);
    }

    function proposeDuel(address _duel) external onlyOwner returns (uint64 eta) {
        eta = _duelWire.propose(_duel, wiringDelay);
        emit DuelWireProposed(_duel, eta);
    }

    function commitDuel() external onlyOwner {
        (address previous, address next) = _duelWire.commit();
        emit DuelWireCommitted(previous, next);
    }

    function cancelDuel() external onlyOwner {
        address dropped = _duelWire.cancel();
        emit DuelWireCancelled(dropped);
    }

    // ─── Admin: the trusted randomness source ─────────────────────────────

    function trustedCoordinator() external view returns (address) {
        return _coordinatorWire.current;
    }

    function coordinatorWire()
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        return (_coordinatorWire.current, _coordinatorWire.pending, _coordinatorWire.eta);
    }

    function proposeCoordinator(address _coordinator) external onlyOwner returns (uint64 eta) {
        eta = _coordinatorWire.propose(_coordinator, wiringDelay);
        emit CoordinatorWireProposed(_coordinator, eta);
    }

    function commitCoordinator() external onlyOwner {
        (address previous, address next) = _coordinatorWire.commit();
        emit CoordinatorWireCommitted(previous, next);
    }

    function cancelCoordinator() external onlyOwner {
        address dropped = _coordinatorWire.cancel();
        emit CoordinatorWireCancelled(dropped);
    }

    function setWiringDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_WIRING_DELAY || newDelay > MAX_WIRING_DELAY) {
            revert DelayOutOfRange(newDelay);
        }
        wiringDelay = newDelay;
        emit WiringDelayChanged(newDelay);
    }

    function setFunder(address funder, bool allowed) external onlyOwner {
        if (funder == address(0)) revert BadAddress();
        isFunder[funder] = allowed;
        emit FunderChanged(funder, allowed);
    }

    function setRequester(address requester, bool allowed) external onlyOwner {
        if (requester == address(0)) revert BadAddress();
        isRequester[requester] = allowed;
        emit RequesterChanged(requester, allowed);
    }

    // ─── Admin: odds + payout ─────────────────────────────────────────────

    function bootstrapPayoutParams(uint256 _oddsOneIn, uint256 _payoutBps, uint256 _minPool)
        external
        onlyOwner
    {
        if (payoutParamsBootstrapped) revert PayoutParamsAlreadyBootstrapped();
        _validatePayoutParams(_oddsOneIn, _payoutBps);
        payoutParamsBootstrapped = true;
        oddsOneIn = _oddsOneIn;
        payoutBps = _payoutBps;
        minPoolToFire = _minPool;
        emit OddsChanged(_oddsOneIn);
        emit PayoutBpsChanged(_payoutBps);
        emit MinPoolToFireChanged(_minPool);
    }

    /**
     * @notice Propose a change to the three payout numbers.
     * @dev ⛔ ALL THREE MOVE TOGETHER, ON ONE CLOCK. The drain this timelock
     *      exists to stop used two of them in concert — `minPoolToFire` to burn
     *      other players' tickets without paying, then `oddsOneIn` to guarantee
     *      the attacker's own. Three independent timelocks would let the pieces
     *      be staged separately and land in one block.
     */
    function proposePayoutParams(uint256 _oddsOneIn, uint256 _payoutBps, uint256 _minPool)
        external
        onlyOwner
        returns (uint64 eta)
    {
        _validatePayoutParams(_oddsOneIn, _payoutBps);
        eta = uint64(block.timestamp + wiringDelay);
        proposedOdds = _oddsOneIn;
        proposedPayoutBps = _payoutBps;
        proposedMinPool = _minPool;
        payoutParamsEta = eta;
        emit PayoutParamsProposed(_oddsOneIn, _payoutBps, _minPool, eta);
    }

    function commitPayoutParams() external onlyOwner {
        uint64 eta = payoutParamsEta;
        if (eta == 0) revert NothingProposed();
        if (block.timestamp < eta) revert PayoutParamsNotElapsed(eta, uint64(block.timestamp));

        oddsOneIn = proposedOdds;
        payoutBps = proposedPayoutBps;
        minPoolToFire = proposedMinPool;
        payoutParamsEta = 0;

        emit OddsChanged(oddsOneIn);
        emit PayoutBpsChanged(payoutBps);
        emit MinPoolToFireChanged(minPoolToFire);
    }

    function cancelPayoutParams() external onlyOwner {
        if (payoutParamsEta == 0) revert NothingProposed();
        payoutParamsEta = 0;
        emit PayoutParamsCancelled(proposedOdds, proposedPayoutBps, proposedMinPool);
    }

    function _validatePayoutParams(uint256 _oddsOneIn, uint256 _payoutBps) private pure {
        if (_oddsOneIn < MIN_ODDS_ONE_IN || _oddsOneIn > MAX_ODDS_ONE_IN) {
            revert InvalidOdds(_oddsOneIn);
        }
        if (_payoutBps == 0 || _payoutBps > 10_000) revert InvalidShare(_payoutBps);
    }

    // ─── Admin: VRF ───────────────────────────────────────────────────────

    function setVrfConfig(
        bytes32 _keyHash,
        uint256 _subscriptionId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _payWithNative
    ) external onlyOwner {
        if (pendingRequestId != 0) revert RequestInFlight(pendingRequestId);
        if (_keyHash == bytes32(0) || _subscriptionId == 0) revert BadVrfConfig();
        if (
            _requestConfirmations < MIN_REQUEST_CONFIRMATIONS
                || _requestConfirmations > MAX_REQUEST_CONFIRMATIONS
        ) revert BadVrfConfig();
        if (_callbackGasLimit == 0 || _callbackGasLimit > MAX_CALLBACK_GAS_LIMIT) {
            revert BadVrfConfig();
        }
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        payWithNative = _payWithNative;
        emit VrfConfigChanged(
            _keyHash, _subscriptionId, _requestConfirmations, _callbackGasLimit, _payWithNative
        );
    }

    function setTimeouts(uint256 _requestTimeoutBlocks, uint256 _publicRequestDelayBlocks)
        external
        onlyOwner
    {
        if (_requestTimeoutBlocks == 0 || _requestTimeoutBlocks > MAX_REQUEST_TIMEOUT_BLOCKS) {
            revert ValueOutOfRange(_requestTimeoutBlocks, MAX_REQUEST_TIMEOUT_BLOCKS);
        }
        if (
            _publicRequestDelayBlocks == 0
                || _publicRequestDelayBlocks > MAX_PUBLIC_REQUEST_DELAY_BLOCKS
        ) {
            revert ValueOutOfRange(_publicRequestDelayBlocks, MAX_PUBLIC_REQUEST_DELAY_BLOCKS);
        }
        requestTimeoutBlocks = _requestTimeoutBlocks;
        publicRequestDelayBlocks = _publicRequestDelayBlocks;
        emit TimeoutsChanged(_requestTimeoutBlocks, _publicRequestDelayBlocks);
    }

    function setSocials(string calldata w, string calldata t, string calldata g)
        external
        onlyOwner
    {
        website = w;
        twitter = t;
        telegram = g;
        emit SocialsChanged(w, t, g);
    }

    // ─── The no-withdraw invariant ────────────────────────────────────────

    /**
     * @notice Recover ERC-20s sent here by mistake.
     *
     * @dev ⚠ THIS IS THE PRODUCT, AND THE NATIVE POT MAKES IT STRONGER, NOT
     *      WEAKER. The pool is native and this function moves ERC-20s only, so
     *      there is no owner path to the pot at all — not a sweep, not a
     *      "temporary" hatch, not a pause-and-withdraw. **There is deliberately
     *      NO native rescue.** Adding one would hand the owner the pool, and
     *      there is nothing for it to recover anyway: every wei of this
     *      contract's balance is either pot or an unclaimed prize
     *      (`pool() == balance - totalOwed`), so a "spare native" bounded by
     *      `balance - (pool + totalOwed)` would always be exactly zero.
     *
     *      ⚠ WBNB IS REFUSED even though it is not the prize. The canonical
     *      funding path unwraps atomically so WBNB never rests here, but a
     *      mistaken direct transfer would otherwise be sweepable by the owner —
     *      and that money was plainly meant for the pot. `absorbStrayWbnb` is
     *      the permissionless alternative: it pushes it into the pool where
     *      nobody, including us, can take it back out.
     */
    function sweepForeignToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(wbnb)) revert PrizeIsNotSweepable();
        if (to == address(0) || token == address(0)) revert BadAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
