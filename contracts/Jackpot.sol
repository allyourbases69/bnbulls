// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

/**
 * @title Jackpot
 * @notice A no-withdraw prize pool that fires at random to duel winners.
 *         Token-agnostic: the prize token is a constructor argument and the
 *         game deploys this contract TWICE.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      THE TWO DEPLOYMENTS (`DECISIONS.md §10`, §13)
 *      ══════════════════════════════════════════════════════════════════════
 *        1. prize token = **BNBULL**, odds **1 in 50**.
 *        2. prize token = **WBNB**,   odds **1 in 100**.
 *
 *      ⚠ THE SECOND POT HOLDS **WBNB**, NOT RAW BNB, AND THAT IS DELIBERATE.
 *      `DECISIONS.md §10` puts BNB in the slot $FEFER held on fefers. Keeping
 *      this contract purely ERC-20 buys two things that matter more than the
 *      cosmetics of holding native:
 *        - a payout is `safeTransfer`, which cannot be refused. A raw-BNB
 *          payout is a `.call{value:}` to an arbitrary winner, and a winner
 *          that is a contract with a reverting `receive()` would revert the
 *          resolve loop and WEDGE THE QUEUE — permanently, in a contract with
 *          no withdraw path.
 *        - one code path, one invariant, one test. A dual native/ERC-20 mode
 *          would branch every funding, payout and sweep in the one contract
 *          whose whole product IS the no-withdraw guarantee.
 *      Wrapping is not a swap: `WBNB.deposit()` is 1:1, has no slippage, no
 *      router and no liquidity dependency, so `DECISIONS.md §13`'s "a BNB
 *      payment routes straight into the pot with no DEX interaction at all"
 *      still holds exactly. MintDrop does the wrapping.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY THIS IS STILL TWO PHASES, EVEN WITH VRF
 *      ══════════════════════════════════════════════════════════════════════
 *      Winning a duel opens a TICKET. The ticket's outcome is decided by data
 *      that does not exist yet when the ticket is opened.
 *
 *      That indirection is load-bearing. Anything decided inside the duel
 *      transaction is grindable, because the player controls whether that
 *      transaction is ever sent:
 *        1. player asks the server for a duel, gets a signed result
 *        2. player computes what the jackpot roll WOULD be if they submitted
 *        3. if it loses, they simply do not submit and try another matchup
 *      Stakes are only pulled on submit, so step 3 is free.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHERE THE RANDOMNESS COMES FROM — CHAINLINK VRF v2.5
 *      ══════════════════════════════════════════════════════════════════════
 *      On Stable (chain 988) there was no VRF at all — no Chainlink, no Pyth,
 *      no API3, and `block.prevrandao` was a hardcoded `2**256 - 1` in every
 *      block forever, contributing exactly zero bits. Worse, Stable was an
 *      11-validator round-robin with blocks 5-12% full, so a validator knew
 *      which blocks were theirs and could grind their own block hash for free.
 *      Fefers therefore had to build `blockhash(open+1)` mixed with a
 *      pre-committed hash chain, and document it honestly as "not VRF-grade".
 *
 *      **BNB Chain has VRF, so all of that is deleted.** The commitment chain,
 *      the reveal ordering, the 250-block `BLOCKHASH_WINDOW`, the reveal grace
 *      period and ticket expiry are gone with it. One request, one verifiable
 *      word, no operator discretion at all.
 *
 *      ⚠ COST. VRF is charged per request, and `BNB-CHAIN-FACTS.md §4` flags
 *      a per-fight request as a real running cost the free Stable hack did not
 *      have. So requests are **batched**: `requestResolve(n)` covers the next
 *      `n` pending tickets with ONE word, and each ticket's roll is
 *      `keccak(word, ticket fields, address(this))`. A hundred fights can cost
 *      one request. The batch range is fixed at REQUEST time, before the word
 *      exists, so batching gives nobody anything to grind.
 *
 *      The callback deliberately does nothing but store the word. Paying out
 *      inside `fulfillRandomWords` would put the transfers under the VRF
 *      callback gas limit, and a callback that runs out of gas loses the
 *      randomness for good.
 *
 *      If VRF goes dark: `cancelStalledRequest` frees the queue so a new
 *      request can be made, and `setCoordinator` (inherited) can repoint at a
 *      replacement coordinator. If it stayed dark forever, payouts stall and
 *      the money sits in the pool — which is the correct failure mode for a
 *      pot with no withdraw path. Nobody can take it, including us.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ONE POT PER DUEL, DECIDED AT RESOLUTION
 *      ══════════════════════════════════════════════════════════════════════
 *      A winner is eligible for BOTH pots but must never take both in the same
 *      fight. Every decisive duel opens a ticket on BOTH pools carrying the
 *      same `duelKey`. Each pool rolls its own true odds independently, and
 *      the FIRST ticket to roll a WIN claims the duel through
 *      `IDuelJackpotLock(duel).claimJackpotForDuel(duelKey)`. The other is
 *      denied and pays nothing; the money stays in the pool for the next
 *      winner. A `duelKey` of zero disables the check (standalone pool/tests).
 *
 *      SAFETY: nothing here may ever revert a duel. `recordWin` only appends,
 *      the lock call is a low-level `call` that cannot bubble a revert, and
 *      Duel wraps its calls in try/catch regardless.
 */
contract Jackpot is VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── The prize ────────────────────────────────────────────────────────

    /// @notice The prize token. BNBULL on one deployment, WBNB on the other.
    IERC20 public immutable prizeToken;

    // ─── Odds + payout (owner-settable, hard-bounded) ─────────────────────

    /// @notice A ticket wins with probability 1 / oddsOneIn.
    uint256 public oddsOneIn;
    /// @notice Share of the pool paid on a win, in basis points.
    uint256 public payoutBps = 10_000;
    /// @notice The pool must hold at least this much before a ticket can win.
    uint256 public minPoolToFire;

    /// @notice True security ceiling on the odds denominator.
    uint256 public constant MAX_ODDS_ONE_IN = 1_000_000;

    /**
     * @notice ⛔ TRUE SECURITY FLOOR ON THE ODDS DENOMINATOR. `oddsOneIn = 1`
     *         means `H % 1 == 0` for every possible word — a CERTAIN win, with
     *         no VRF grinding required at all.
     *
     * @dev This is the same defect class as the `setCoordinator` finding
     *      documented on `_coordinatorWire` below, and it was reachable the
     *      same way: no function named "withdraw" is involved, so the literal
     *      "no owner path removes the prize asset" invariant still held and the
     *      surface sweep still passed. **The pool left through a chosen win.**
     *
     *      Reproduced end to end before this bound existed: open one ticket to
     *      an address you control (the trusted signer is a plain setter, and a
     *      self-duel only needs two wallets) → `setMinPoolToFire(max)` so
     *      `resolve(n)` walks the cursor past every other player's ticket
     *      paying nothing → `setMinPoolToFire(0); setOdds(1); resolve(1)` →
     *      the entire pool, to an address of your choosing, in four owner
     *      transactions with no front-running risk.
     */
    uint256 public constant MIN_ODDS_ONE_IN = 10;

    // ─── The payout terms of the batch in flight (snapshotted) ────────────

    /**
     * @dev ⛔ `resolve` MUST NOT READ THE LIVE ODDS/PAYOUT/FLOOR. IT READS THESE.
     *
     *      The batch RANGE is already fixed at request time, and this file
     *      states why verbatim: *"fixed at REQUEST time, before the word
     *      exists, so batching gives nobody anything to grind."* The three
     *      numbers that decide **whether a ticket wins and how much it takes**
     *      were left reading live storage, which handed back everything that
     *      principle was protecting: the owner could see the word land and only
     *      then choose the terms it would be judged under.
     *
     *      So they are snapshotted into the request alongside `pendingUntil`
     *      and promoted on fulfilment alongside `resolveUntil`. Same lifecycle,
     *      same guarantee: **the terms of a batch are set before its randomness
     *      exists, and cannot move afterwards.**
     */
    uint256 public pendingOdds;
    uint256 public pendingPayoutBps;
    uint256 public pendingMinPool;

    /// @notice The terms `resolveWord` is being judged under. See above.
    uint256 public resolveOdds;
    uint256 public resolvePayoutBps;
    uint256 public resolveMinPool;

    // ─── Payout-parameter timelock ────────────────────────────────────────

    /// @notice A proposed change to the three payout numbers, and its ETA.
    ///         Zero `eta` means nothing is pending.
    uint256 public proposedOdds;
    uint256 public proposedPayoutBps;
    uint256 public proposedMinPool;
    uint64 public payoutParamsEta;

    /**
     * @notice One free instant write, for deploy day. After it, every change to
     *         the payout numbers is propose → wait `wiringDelay` → commit.
     * @dev Exactly `TimelockedAddress.bootstrap`'s bargain, for the same
     *      reason: wiring a fresh deployment must not be a two-day job, but a
     *      live pot's payout terms must never move without public notice.
     *
     *      ⚠ It is a ONE-TIME FLAG and deliberately not "while no tickets
     *      exist". The latter looks equivalent and is not: the owner could fund
     *      the pot, set odds to the floor while the queue was empty, and only
     *      then open the ticket that collects. `Verify` asserts this has been
     *      used before launch.
     */
    bool public payoutParamsBootstrapped;

    // ─── Wiring ───────────────────────────────────────────────────────────

    /// @dev The Duel contract is the only address allowed to open tickets, and
    ///      it is the address that arbitrates exclusivity — so a malicious one
    ///      could open tickets naming itself as the winner and statistically
    ///      drain the pool. It is therefore TIMELOCKED, not a bare setter.
    TimelockedAddress.Slot private _duelWire;

    /**
     * @dev ⛔ THE RANDOMNESS SOURCE IS A MONEY SLOT. TREAT IT LIKE ONE.
     *
     *      `VRFConsumerBaseV2Plus.setCoordinator` is owner-callable with NO
     *      timelock, and it is not `virtual`, so it cannot be overridden. Left
     *      alone, that is a complete break of the guarantee this contract
     *      exists to make. The attack, reproduced end to end in
     *      `test_FINDING_ownerCanHandPickTheWinningWordViaSetCoordinator`:
     *
     *        win one duel so a ticket exists → `setCoordinator(evil)`, instant
     *        → `requestResolve(1)` → grind offline for a word satisfying
     *        `keccak(word, entropy, tokenId, winner, id, address(this)) % odds
     *        == 0` (~`odds` keccaks, i.e. free) → `evil.fulfill(id, word)` →
     *        `resolve(1)` → the whole pool, to an address of your choosing.
     *
     *      No function named "withdraw" is involved, so the literal invariant
     *      ("no owner path removes the prize asset") still held and the
     *      surface sweep still passed. The pool left through a *chosen* win.
     *
     *      Note what does NOT fix this: adding more terms to the roll
     *      preimage. Every other term is fixed before the word is known, so a
     *      chosen word can be ground against any of them. Only controlling
     *      WHO may deliver the word helps.
     *
     *      So the trusted coordinator is tracked HERE, timelocked like every
     *      other money slot, and `fulfillRandomWords` refuses a word from
     *      anyone else. `setCoordinator` may still be called — Chainlink's own
     *      migration path needs it — but on its own it now buys nothing:
     *      repointing randomness at a contract we control takes `wiringDelay`
     *      and is publicly visible as a pending proposal with an ETA, exactly
     *      like re-wiring the Duel.
     */
    TimelockedAddress.Slot private _coordinatorWire;

    /// @notice Delay a Duel re-wire must age before it can be committed.
    uint256 public wiringDelay = 24 hours;
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;

    /// @notice Addresses allowed to fund the pool via `fund` (MintDrop, the
    ///         splitters, Duel's dev-cut leg). Funders can only ADD money, so
    ///         this is a plain setter.
    mapping(address => bool) public isFunder;

    /// @notice Addresses allowed to spend the VRF subscription by calling
    ///         `requestResolve` (the keeper). Gated because each request costs
    ///         real LINK/BNB and an ungated one is a subscription-drain vector.
    mapping(address => bool) public isRequester;

    /// @notice Once the oldest pending ticket is this many blocks old, ANYONE
    ///         may call `requestResolve`. The failsafe for a dead keeper.
    uint256 public publicRequestDelayBlocks = 1_200;
    uint256 public constant MAX_PUBLIC_REQUEST_DELAY_BLOCKS = 200_000;

    // ─── Tickets ──────────────────────────────────────────────────────────

    /// @dev `winner` and `openedAtBlock` are adjacent so they share one slot.
    struct Ticket {
        address winner;
        uint64 openedAtBlock;
        uint256 tokenId;
        uint256 entropy;
        /// @notice Identifies the DUEL this ticket belongs to. Both pools get
        ///         the same value for the same fight, which is what lets the
        ///         first winning ticket lock the other pot out. Zero disables
        ///         the exclusivity check for this ticket.
        uint256 duelKey;
    }

    /// @notice Every ticket ever opened, in order.
    Ticket[] public tickets;
    /// @notice Index of the next ticket awaiting resolution.
    uint256 public nextToResolve;

    // ─── VRF request state (one request in flight at a time) ──────────────

    /// @notice Live VRF request id, or 0 when nothing is in flight.
    uint256 public pendingRequestId;
    /// @notice Block the live request was made at, for the stall timeout.
    uint64 public pendingRequestedAtBlock;
    /// @notice Exclusive ticket bound the live request will cover.
    uint64 public pendingUntil;

    /// @notice The fulfilled random word currently being consumed.
    uint256 public resolveWord;
    /// @notice Exclusive ticket bound `resolveWord` covers.
    uint64 public resolveUntil;
    /// @notice True while `resolveWord` still has tickets left to decide.
    bool public wordReady;

    /**
     * @notice Blocks after which a stalled request may be cancelled by anyone.
     *
     * @dev ⚠ MEASURED, NOT GUESSED, AND THE OLD NUMBER WAS TOO SMALL. This was
     *      1_200 — about nine minutes at BSC's ~0.45s blocks. The FIRST live
     *      fulfilment on chain 97 took **3,169 blocks (~24 minutes)**; later
     *      ones landed in one to three. So a keeper obeying 1_200 would have
     *      cancelled a request that was about to be answered, wasting the
     *      subscription payment AND discarding the word, because
     *      `fulfillRandomWords` drops a word whose id no longer matches.
     *
     *      ⚠ AND THE UNIT IS THE TRAP. What this bounds is ORACLE LATENCY,
     *      which is denominated in TIME — but the counter is denominated in
     *      BLOCKS, so every BSC block-time reduction silently SHORTENS it.
     *      BSC has gone 3s → 1.5s → 0.75s → ~0.45s inside a year; a number
     *      chosen tightly against today's block time is a number that expires
     *      on somebody else's hard fork.
     *
     *      24_000 is ~3 hours at 0.45s, still ~1.7 hours if blocks halve
     *      again, and 7.6x the worst fulfilment actually observed. The
     *      asymmetry says to err long: cancelling early burns a paid request
     *      and confuses the operator, while cancelling late only delays a
     *      retry that mostly cannot help anyway — a request that is not being
     *      served is usually not being served for a reason a re-request does
     *      not fix (an unfunded subscription, a lane nobody runs). Meanwhile
     *      fights are completely unaffected either way.
     *
     *      Owner-settable and bounded (`BNBULLS-BOOTSTRAP.md §0`), and `Wire`
     *      now writes it explicitly so this default cannot ship by accident —
     *      `DECISIONS.md §40`.
     */
    uint256 public requestTimeoutBlocks = 24_000;
    uint256 public constant MAX_REQUEST_TIMEOUT_BLOCKS = 200_000;

    // ─── VRF configuration (owner-settable, bounded) ──────────────────────

    /// @notice Gas-lane key hash. BSC lanes are listed in BNB-CHAIN-FACTS §4.
    bytes32 public keyHash;
    /// @notice VRF v2.5 subscription id (uint256 in v2.5, not uint64).
    uint256 public subscriptionId;
    /// @notice Block confirmations the coordinator waits before fulfilling.
    uint16 public requestConfirmations = 3;
    /// @notice Gas the coordinator forwards to `fulfillRandomWords`. The
    ///         callback only writes three slots, so this is generous.
    uint32 public callbackGasLimit = 200_000;
    /// @notice Pay the VRF fee in native BNB rather than LINK. v2.5 supports
    ///         both; native avoids having to keep LINK topped up.
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
    /// @notice A ticket rolled a WIN and was paid nothing, because the other
    ///         pot had already paid this same duel. One pot per fight, and
    ///         this is the receipt that it was enforced.
    event ExclusivityDenied(uint256 indexed ticketId, address indexed winner, uint256 duelKey);
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
    /// @dev `bootstrapPayoutParams` called twice. It is a one-time write.
    error PayoutParamsAlreadyBootstrapped();
    /// @dev `commitPayoutParams`/`cancelPayoutParams` with nothing proposed.
    error NothingProposed();
    /// @dev `commitPayoutParams` before the timelock elapsed.
    error PayoutParamsNotElapsed(uint64 eta, uint64 nowTs);
    error InvalidShare(uint256 bps);
    error DelayOutOfRange(uint256 requested);
    error RequestInFlight(uint256 requestId);
    error BatchStillOpen();
    error NothingToResolve();
    error NoRequestInFlight();
    error TimeoutNotElapsed(uint64 requestedAt, uint256 timeoutBlocks);
    error PrizeTokenIsNotSweepable();
    error VrfNotConfigured();
    /// @notice A word arrived from an address that is not the timelocked
    ///         coordinator. See `_coordinatorWire`.
    error UntrustedCoordinator(address caller);
    error BadVrfConfig();
    error ValueOutOfRange(uint256 requested, uint256 cap);

    /**
     * @param _prizeToken  BNBULL on one deployment, WBNB on the other.
     * @param _owner       Intended owner. ConfirmedOwner is two-step, so this
     *                     address must call `acceptOwnership()` after deploy.
     *                     Pass the deployer (or zero) to keep ownership put.
     * @param _coordinator Chainlink VRF v2.5 coordinator. BSC mainnet:
     *                     0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9.
     * @param _oddsOneIn   50 for the BNBULL pot, 100 for the WBNB pot.
     */
    constructor(address _prizeToken, address _owner, address _coordinator, uint256 _oddsOneIn)
        VRFConsumerBaseV2Plus(_coordinator)
    {
        if (_prizeToken == address(0)) revert BadAddress();
        // Same floor the setters enforce — a pot deployed at odds of 1 would
        // be drainable from block one, before any timelock could matter.
        if (_oddsOneIn < MIN_ODDS_ONE_IN || _oddsOneIn > MAX_ODDS_ONE_IN) {
            revert InvalidOdds(_oddsOneIn);
        }
        prizeToken = IERC20(_prizeToken);
        oddsOneIn = _oddsOneIn;
        // The coordinator VRFConsumerBaseV2Plus was constructed with is the
        // one we trust. Bootstrapped, so deploy day is one tx; every later
        // change goes through propose → wait → commit.
        _coordinatorWire.bootstrap(_coordinator);
        // ConfirmedOwner set the owner to msg.sender. Hand it on two-step.
        if (_owner != address(0) && _owner != msg.sender) {
            transferOwnership(_owner);
        }
    }

    // ─── Views ────────────────────────────────────────────────────────────

    /// @notice Current prize pool. Just the balance, so a plain transfer in
    ///         counts as a donation.
    function pool() external view returns (uint256) {
        return prizeToken.balanceOf(address(this));
    }

    /// @notice What a winning ticket would take home right now. The figure the
    ///         fight HUD shows.
    function pendingPayout() external view returns (uint256) {
        return (prizeToken.balanceOf(address(this)) * payoutBps) / 10_000;
    }

    function ticketCount() external view returns (uint256) {
        return tickets.length;
    }

    /// @notice Tickets still waiting on resolution.
    function pendingTickets() external view returns (uint256) {
        return tickets.length - nextToResolve;
    }

    /// @notice The wired Duel contract.
    function duel() public view returns (address) {
        return _duelWire.current;
    }

    /// @notice Duel wiring slot: live address, pending target, ETA.
    function duelWire() external view returns (address current, address pending, uint64 eta) {
        return (_duelWire.current, _duelWire.pending, _duelWire.eta);
    }

    /// @notice Whether `resolve` has work it can do right now.
    function resolvable() external view returns (bool) {
        return wordReady && nextToResolve < resolveUntil;
    }

    /// @notice Whether a fresh `requestResolve` would be accepted (ignoring
    ///         caller permissions).
    function requestable() external view returns (bool) {
        return pendingRequestId == 0 && !wordReady && nextToResolve < tickets.length;
    }

    // ─── Funding ──────────────────────────────────────────────────────────

    /**
     * @notice Pull `amount` of the prize token from the caller into the pool.
     * @dev Booked as a MEASURED BALANCE DELTA. The prize token is not always
     *      one we control (WBNB is not, and a launchpad-issued BNBULL might
     *      not be either), so `totalFunded` counts what actually landed rather
     *      than what the caller said it sent.
     */
    function fund(uint256 amount, string calldata source) external {
        if (!isFunder[msg.sender]) revert NotFunder();
        if (amount == 0) return;
        uint256 before = prizeToken.balanceOf(address(this));
        prizeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = prizeToken.balanceOf(address(this)) - before;
        totalFunded += received;
        emit Funded(msg.sender, received, source);
    }

    /// @notice Dev top-up. Owner-only, always allowed.
    function topUp(uint256 amount) external onlyOwner {
        if (amount == 0) return;
        uint256 before = prizeToken.balanceOf(address(this));
        prizeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = prizeToken.balanceOf(address(this)) - before;
        totalFunded += received;
        emit Funded(msg.sender, received, "dev-topup");
    }

    // ─── Phase 1: open a ticket ───────────────────────────────────────────

    /**
     * @notice Open a jackpot ticket for a duel winner. Duel-only. Cannot
     *         revert on any normal input, and never pays out here: the outcome
     *         is not knowable yet, which is the whole point.
     * @param duelKey Identifies the fight. Pass the SAME value to both pools
     *                for the same duel and only one of them can ever pay it.
     *                Pass 0 to skip the exclusivity check.
     * @return ticketId Index of the ticket, or type(uint256).max if none was
     *                  opened.
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

    /**
     * @notice Request one VRF word covering the next `maxTickets` pending
     *         tickets. One request decides the whole batch, which is what
     *         keeps the per-fight VRF cost sane.
     * @dev Normally called by the keeper. Once the oldest pending ticket is
     *      `publicRequestDelayBlocks` old, anyone may call it, so a dead
     *      keeper cannot freeze the queue.
     */
    function requestResolve(uint256 maxTickets) external returns (uint256 requestId) {
        if (keyHash == bytes32(0) || subscriptionId == 0) revert VrfNotConfigured();
        if (pendingRequestId != 0) revert RequestInFlight(pendingRequestId);
        // A fulfilled batch must be fully consumed first, so one word never
        // silently replaces another that still had tickets to decide.
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
        //    Reading these live in `resolve` let the owner watch the word land
        //    and only then choose the odds it would be judged under. Same
        //    principle the range already relies on, applied to the three
        //    numbers that actually decide who gets paid and how much.
        pendingOdds = oddsOneIn;
        pendingPayoutBps = payoutBps;
        pendingMinPool = minPoolToFire;

        emit RandomnessRequested(requestId, uint64(from), uint64(until_), msg.sender);
    }

    /**
     * @dev The VRF callback. It stores the word and nothing else.
     *
     *      Paying out here would put N token transfers plus N external
     *      exclusivity calls under the coordinator's `callbackGasLimit`, and a
     *      callback that runs out of gas does not retry — the word is gone and
     *      the batch is stranded. Storing three slots always fits.
     *
     *      A word for a request that is no longer the live one (a cancelled,
     *      stalled request that fulfilled late) is discarded on purpose.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        // ⛔ The word must come from the TIMELOCKED coordinator, not merely
        //    from whatever `s_vrfCoordinator` currently points at. See the
        //    `_coordinatorWire` docs: without this line the owner can swap the
        //    coordinator instantly and hand-pick a winning word.
        //
        //    `rawFulfillRandomWords` is an external function on this same
        //    contract, so inside here `msg.sender` is still the caller that
        //    delivered the word.
        if (msg.sender != _coordinatorWire.current) revert UntrustedCoordinator(msg.sender);
        if (requestId != pendingRequestId) return;
        resolveWord = randomWords[0];
        resolveUntil = pendingUntil;
        // Promoted with the range, so the word and the terms it is judged
        // under always travel together.
        resolveOdds = pendingOdds;
        resolvePayoutBps = pendingPayoutBps;
        resolveMinPool = pendingMinPool;
        wordReady = true;
        pendingRequestId = 0;
        pendingUntil = 0;
        emit RandomnessFulfilled(requestId, resolveUntil);
    }

    /**
     * @notice Free the queue when a VRF request has not been fulfilled inside
     *         `requestTimeoutBlocks`. Permissionless: a stuck subscription must
     *         not need our key to unstick.
     * @dev Only clears the in-flight marker. Tickets are untouched, and the
     *         next request covers the same range again. If the abandoned
     *         request fulfils later its word is discarded, because the id no
     *         longer matches.
     */
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
     */
    function resolve(uint256 max) external returns (uint256 resolved) {
        if (!wordReady) return 0;

        uint256 word = resolveWord;
        uint256 balance = prizeToken.balanceOf(address(this));
        uint256 stop = resolveUntil;

        // ⛔ THE SNAPSHOT, NOT LIVE STORAGE. These were captured in
        //    `requestResolve` before the word existed. Repointing any of these
        //    three at `oddsOneIn` / `minPoolToFire` / `payoutBps` reopens the
        //    four-transaction pool drain — see `MIN_ODDS_ONE_IN`.
        uint256 odds = resolveOdds;
        uint256 minPool = resolveMinPool;
        uint256 bps = resolvePayoutBps;

        while (resolved < max && nextToResolve < stop) {
            uint256 id = nextToResolve;
            Ticket memory t = tickets[id];

            // ⚠ `address(this)` IS LOAD-BEARING. DO NOT REMOVE IT.
            //
            // Both pools are ticketed on every decisive duel, and those two
            // tickets share every other input: same duel entropy, same
            // tokenId, same winner, and the same ticket index (each pool gets
            // exactly one ticket per duel, so the cursors stay in lockstep).
            // Without a per-pool term the two pools hash an IDENTICAL
            // preimage whenever they are decided by the same word.
            //
            // That is fatal, not cosmetic. With odds of 50 and 100, 50 divides
            // 100, so `H % 100 == 0` implies `H % 50 == 0` — every win on the
            // 1-in-100 pot came with a win on the 1-in-50 pot, the 1-in-50
            // claimed the duel key first, and the second pot paid out NEVER.
            // Measured on Stable before this line existed: 600 duels, 7
            // payouts on one pot, 0 on the other.
            //
            // Two separate VRF requests give the two pools different words
            // today, which would also break the tie — but that is a property
            // of the KEEPER's call pattern, not of the code, and these
            // contracts are not upgradeable. The separation stays here.
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
            // `_claimDuel` reaches into another contract; if that contract
            // ever re-entered `resolve` while the cursor still pointed here,
            // the outer frame would write the cursor back and hand the inner
            // frame's tickets out a second time. CEI removes the question.
            nextToResolve = id + 1;
            resolved += 1;

            // ⚠ ONE POT PER DUEL. The only place the two pools are arbitrated,
            // and it sits here rather than in the duel transaction because by
            // now the deciding word exists — nothing about which pot pays was
            // knowable when the player submitted.
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
                prizeToken.safeTransfer(t.winner, paid);
            }
        }

        // Batch exhausted: release the word so a fresh request can be made.
        if (nextToResolve >= stop) {
            wordReady = false;
            resolveWord = 0;
            resolveUntil = 0;
        }
    }

    /**
     * @dev Ask the Duel contract to hand this pool the exclusive right to pay
     *      `duelKey`. True means "you may pay", false means the other pot
     *      already did (or the lock is unreachable).
     *
     *      Low-level `call` rather than try/catch on purpose. A `duel` that is
     *      an EOA would return success with EMPTY returndata, and Solidity's
     *      try/catch does NOT catch a return-data decode failure — it would
     *      revert the whole resolve loop. This cannot revert for any callee.
     *
     *      ⚠ THE DECODE IS `uint256`, NOT `bool`, AND THAT IS LOad-BEARING.
     *      `abi.decode(ret, (bool))` reverts on any 32-byte word that is not
     *      exactly 0 or 1. The length guard above does not catch it — the data
     *      is a full word, just not a canonical bool. If it ever fired, this
     *      function WOULD revert, `resolve` would revert on that ticket
     *      forever, the cursor could never advance past it, and every later
     *      ticket would be stranded in a contract with no withdraw path.
     *      Solidity always returns canonical bools, so this needs a proxy, a
     *      Vyper/assembly Duel, or a fallback answering in its own format —
     *      all reachable through the (timelocked) Duel wire. Decoding the raw
     *      word and comparing makes the claim in the line above actually true.
     *
     *      FAILURE IS TREATED AS DENIED, deliberately. If the lock is
     *      unreachable we cannot prove the other pot did not already pay, and
     *      "never both pots" is the invariant that matters. The cost of being
     *      wrong that way is a payout that rolls over into the pool (visible
     *      on chain as `ExclusivityDenied`); the cost of the other way is the
     *      double payout this whole design exists to stop.
     */
    function _claimDuel(uint256 duelKey) private returns (bool) {
        address d = _duelWire.current;
        if (d == address(0) || d.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            d.call(abi.encodeCall(IDuelJackpotLock.claimJackpotForDuel, (duelKey)));
        if (!ok || ret.length < 32) return false;
        // Non-canonical words decode to `false` (denied) rather than reverting.
        return abi.decode(ret, (uint256)) == 1;
    }

    // ─── Admin: wiring ────────────────────────────────────────────────────

    /// @notice First-time wiring of the Duel contract. Immediate, once.
    function bootstrapDuel(address _duel) external onlyOwner {
        _duelWire.bootstrap(_duel);
        emit DuelWireBootstrapped(_duel);
    }

    /// @notice Propose a replacement Duel contract. Timelocked and public.
    function proposeDuel(address _duel) external onlyOwner returns (uint64 eta) {
        eta = _duelWire.propose(_duel, wiringDelay);
        emit DuelWireProposed(_duel, eta);
    }

    /// @notice Commit a matured Duel proposal.
    function commitDuel() external onlyOwner {
        (address previous, address next) = _duelWire.commit();
        emit DuelWireCommitted(previous, next);
    }

    /// @notice Drop a pending Duel proposal.
    function cancelDuel() external onlyOwner {
        address dropped = _duelWire.cancel();
        emit DuelWireCancelled(dropped);
    }

    // ─── Admin: the trusted randomness source ─────────────────────────────
    //
    // Same propose → wait → commit shape as the Duel wire, for the same
    // reason: whoever delivers the word decides who gets paid.

    /// @notice The coordinator whose words this pot will accept.
    function trustedCoordinator() external view returns (address) {
        return _coordinatorWire.current;
    }

    /// @notice Coordinator wiring slot: live address, pending target, ETA.
    function coordinatorWire()
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        return (_coordinatorWire.current, _coordinatorWire.pending, _coordinatorWire.eta);
    }

    /// @notice Propose a replacement coordinator. Timelocked and public.
    /// @dev Chainlink's own migration also needs `setCoordinator` called, so a
    ///      real migration is BOTH: propose here, wait, commit, and point
    ///      `s_vrfCoordinator` at the same address. Until both agree, words
    ///      from the new coordinator are refused.
    function proposeCoordinator(address _coordinator) external onlyOwner returns (uint64 eta) {
        eta = _coordinatorWire.propose(_coordinator, wiringDelay);
        emit CoordinatorWireProposed(_coordinator, eta);
    }

    /// @notice Commit a matured coordinator proposal.
    function commitCoordinator() external onlyOwner {
        (address previous, address next) = _coordinatorWire.commit();
        emit CoordinatorWireCommitted(previous, next);
    }

    /// @notice Drop a pending coordinator proposal.
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

    /**
     * @notice Deploy-day write of the three payout numbers. Instant, and
     *         available exactly ONCE.
     * @dev After this, every change goes through `proposePayoutParams` →
     *      wait `wiringDelay` → `commitPayoutParams`. See
     *      `payoutParamsBootstrapped`.
     */
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
     * @notice Propose a change to the three payout numbers. Public, with an
     *         ETA, for `wiringDelay` before it can take effect.
     *
     * @dev ⛔ ALL THREE MOVE TOGETHER, ON ONE CLOCK, AND THAT IS DELIBERATE.
     *      The drain this timelock exists to stop used two of them in concert
     *      — `minPoolToFire` to burn other players' tickets without paying,
     *      then `oddsOneIn` to guarantee the attacker's own. Three independent
     *      timelocks would let the pieces be staged separately and land in one
     *      block; one proposal means the whole intended end state is on public
     *      display, together, for the full delay.
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

    /// @notice Apply a matured proposal.
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

    /// @notice Drop a pending proposal.
    function cancelPayoutParams() external onlyOwner {
        if (payoutParamsEta == 0) revert NothingProposed();
        payoutParamsEta = 0;
        emit PayoutParamsCancelled(proposedOdds, proposedPayoutBps, proposedMinPool);
    }

    function _validatePayoutParams(uint256 _oddsOneIn, uint256 _payoutBps) private pure {
        // ⛔ THE FLOOR IS THE POINT. `oddsOneIn = 1` is a certain win for every
        //    word; anything below MIN_ODDS_ONE_IN makes a self-dealt ticket
        //    cheap enough to farm. See MIN_ODDS_ONE_IN.
        if (_oddsOneIn < MIN_ODDS_ONE_IN || _oddsOneIn > MAX_ODDS_ONE_IN) {
            revert InvalidOdds(_oddsOneIn);
        }
        if (_payoutBps == 0 || _payoutBps > 10_000) revert InvalidShare(_payoutBps);
    }

    // ─── Admin: VRF ───────────────────────────────────────────────────────

    /**
     * @notice Configure the VRF request. Cannot be changed while a request is
     *         in flight, so a live request always settles under the terms it
     *         was made with.
     */
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

    /// @notice Update the published socials.
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
     * @notice Recover tokens sent here by mistake.
     *
     * @dev ⚠ THIS IS THE PRODUCT. It deliberately CANNOT touch the prize
     *      token: the pool belongs to the players, and a dev-drainable jackpot
     *      is exactly the rug this game's trust story is built against. The
     *      prize token only ever leaves by winning a ticket. There is no
     *      owner path, no "temporary" hatch, no pause-and-withdraw.
     *
     *      There is deliberately no `receive()` and no native sweep either, so
     *      this contract has no code that moves BNB at all.
     */
    function sweepForeignToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(prizeToken)) revert PrizeTokenIsNotSweepable();
        if (to == address(0) || token == address(0)) revert BadAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
