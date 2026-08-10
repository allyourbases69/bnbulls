// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

/// @dev The seller's route-back entrypoint. The pen holds the payment until the
///      bulls are delivered, then hands it back for the ordinary 20/10/70
///      split. Pen-gated on the seller's side.
interface IMintDropRoute {
    function routeReservedPayment(uint256 tokenAmount) external payable;
}

/**
 * @title BullPen
 * @notice Holds the unsold bulls and hands them out at random, so that WHEN
 *         you buy no longer decides WHICH bull you get.
 *
 * @custom:website   https://bnbulls.xyz
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      THE PROBLEM THIS EXISTS FOR
 *      ══════════════════════════════════════════════════════════════════════
 *      `Bulls._initializeRarity()` shuffles the 500 tiers ONCE, in the
 *      constructor, from `masterSeed` — which is a public getter, with the
 *      algorithm in verified source and a line-for-line JS port shipped in the
 *      site's own bundle (`frontend/src/lib/art/bull.ts`). The table is
 *      therefore public, permanently, BY DESIGN: it is what `initialRarityHash`
 *      proves and what the art and the names hang off.
 *
 *      That is fine. What is NOT fine is that `Bulls.mint()` hands out the next
 *      SEQUENTIAL id and `nextTokenId()` is public. Together those two facts
 *      mean anybody can compute which ids are legendary, watch the counter, and
 *      mint at exactly the right moment. It is not a subtle edge — it is a
 *      one-line script.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY THE FIX IS "RANDOMISE THE ID", NOT "HIDE THE TABLE"
 *      ══════════════════════════════════════════════════════════════════════
 *      Rarity, stats, weapon, NAME and ARTWORK are all pure functions of
 *      (masterSeed, tokenId), fixed at deploy. So an id carries its whole
 *      bundle with it. Randomising WHICH id a buyer receives therefore needs:
 *
 *        - no change to `_rarity`            → `initialRarityHash` is untouched
 *        - no regeneration of art or names   → the id still means what it meant
 *        - no change to already-minted bulls → they keep their ids, so they
 *                                              keep their exact rarity
 *
 *      Every other lever (a global offset, a reshuffle, a new seed) moves what
 *      an id MEANS, which breaks all three.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY DELIVERY IS ASYNCHRONOUS, AND WHY IT HAS TO BE
 *      ══════════════════════════════════════════════════════════════════════
 *      ⛔ THIS IS THE WHOLE SECURITY ARGUMENT. READ IT BEFORE "SIMPLIFYING"
 *         ANYTHING BELOW INTO A SINGLE TRANSACTION.
 *
 *      If the id were drawn and revealed inside the buyer's own transaction,
 *      the draw would be worthless no matter how good the randomness is,
 *      because a contract caller can simply look at the result and REVERT if
 *      it is not a legendary. A revert costs gas and nothing else — no
 *      payment, no supply consumed. The attacker retries until it lands. At
 *      BSC gas prices that is a few dollars per legendary, i.e. barely more
 *      expensive than the snipe it was supposed to fix.
 *
 *      You cannot have all three of (1) same-transaction delivery,
 *      (2) unpredictability, (3) no free abort. Anything observable inside the
 *      transaction is abortable. So payment and draw are SEPARATED:
 *
 *        tx 1  `reserve()`  — the seller has already taken the money. Nothing
 *                             about the outcome exists yet, so there is
 *                             nothing to abort on.
 *        tx 2  `settle()`   — the seed is now fixed and public. Reverting is
 *                             pointless: the ids are a pure function of state
 *                             that is already written, so the NEXT caller
 *                             draws exactly the same ids.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE THREE GRIND VECTORS THAT ARE CLOSED HERE, EXPLICITLY
 *      ══════════════════════════════════════════════════════════════════════
 *      1. **Abort-on-reveal.** Closed by the split above: at `reserve` time no
 *         seed exists, and `settle` is idempotent in outcome.
 *
 *      2. **Re-ordering.** If a caller could choose whether reservation A or
 *         reservation B settles first, they could permute the pool and so
 *         change their own draw — trying orderings and reverting until one
 *         suits. Closed by `nextToSettle`: settlement is strict FIFO in
 *         reservation order, which no caller can influence.
 *
 *      3. **Stall-for-a-reroll.** A buyer who dislikes their seed must not be
 *         able to refuse to settle and wait for a different one. Closed
 *         because a VRF word, once delivered, is stored forever, and because
 *         nothing can settle past a pending reservation (see 2) — so stalling
 *         changes nothing at all.
 *
 *      The draw depends ONLY on (seed, index) and the pool state that FIFO
 *      pins. It never touches `msg.sender`, `block.*`, `gasleft()` or `tx.*` —
 *      grep for them below, there are none in `_drawOne`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      IT HOLDS THE MONEY, AND THAT IS A DELIBERATE REVERSAL
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ THIS CONTRACT USED TO SAY "it does not hold money and it has no
 *      refund path". That was true, and it was wrong, and the reason is worth
 *      keeping rather than quietly editing out.
 *
 *      Under that design `MintDrop` routed the payment at `reserve` time: 70%
 *      to a treasury EOA and 30% into the two `Jackpot` contracts. A jackpot is
 *      NO-WITHDRAW BY DESIGN — nothing gets money out except a won ticket — so
 *      by the time a reservation existed, the money was already somewhere
 *      nobody could ever retrieve it from. If VRF then never delivered, the
 *      buyer had paid, had no bull, and there was nothing left to refund them
 *      out of. The permissionless blockhash fallback made that recoverable in
 *      the normal case, but "recoverable if a third party presses two buttons"
 *      is not the same promise as "you can have your money back".
 *
 *      So payment is now ESCROWED here and routed on SETTLE:
 *
 *        reserve  — the pen takes custody. Nothing is decided, nothing has
 *                   moved anywhere irreversible.
 *        settle   — the bulls are delivered AND the escrow is pushed back to
 *                   `MintDrop.routeReservedPayment`, which runs the identical
 *                   20/10/70 split it always ran.
 *        refund   — after `refundAfterBlocks`, and ONLY while no seed exists,
 *                   the payer may take their money back.
 *
 *      The cost is that the pots and the treasury are paid one transaction
 *      later than they used to be. That is the whole cost, and it buys the
 *      thing a player actually cares about.
 *
 *      ⛔ THE RULE THAT MAKES IT SAFE: **a seed is the point of no return.**
 *      `refund` requires `!seeded`, not merely `!settled`. Once a word exists
 *      the outcome is computable off chain, so a refund available after that
 *      point would BE the free-abort attack this whole two-transaction design
 *      exists to close — buy, look, and unwind if it is not a legendary. The
 *      two paths are mutually exclusive forever, by one flag each, both written
 *      before any external call.
 */
contract BullPen is VRFConsumerBaseV2Plus, ReentrancyGuard, IERC721Receiver {
    using TimelockedAddress for TimelockedAddress.Slot;
    using SafeERC20 for IERC20;

    // ─── Immutables ───────────────────────────────────────────────────────

    /// @notice The collection this pen stocks.
    IERC721 public immutable bulls;

    /// @notice The one ERC-20 a payment can arrive in. Immutable, because a
    ///         settable escrow asset is a way to hand somebody else's refund to
    ///         a token the owner controls.
    IERC20 public immutable bnbull;

    // ─── True ceilings ────────────────────────────────────────────────────

    /// @notice Largest reservation. Matches `MintDrop.MAX_BATCH`.
    uint16 public constant MAX_BATCH = 20;

    /// @notice Blocks a VRF request may hang before the blockhash fallback may
    ///         be armed.
    /// @dev    ⚠ THE UNIT IS THE TRAP, exactly as in `JackpotNative`. This
    ///         bounds ORACLE LATENCY, which is time, but it counts BLOCKS —
    ///         so every BSC block-time reduction silently shortens it. The
    ///         measured first live fulfilment on chain 97 took 3,169 blocks.
    uint256 public vrfTimeoutBlocks = 24_000;
    uint256 public constant MAX_VRF_TIMEOUT_BLOCKS = 200_000;

    /**
     * @notice Blocks a buyer must wait before they may take their money back.
     *
     * @dev ⚠ THIS IS NOT `vrfTimeoutBlocks` AND IT MUST STAY SHORTER THAN IT.
     *      The two numbers answer different questions and the ORDER they fire
     *      in is the design:
     *
     *        0 .. refundAfterBlocks    VRF is working on it. Wait.
     *        refundAfterBlocks ..      the buyer MAY leave with their money.
     *        vrfTimeoutBlocks ..       anyone MAY force the draw through the
     *                                  blockhash fallback.
     *
     *      That order is deliberate. If the fallback opened first, a stranger
     *      could force an outcome onto a buyer who wanted out, and the refund
     *      would be a promise that anybody could cancel.
     *
     *      ⚠ WHY 7,200 AND NOT THE HOUSE 24,000. `VRF_REQUEST_TIMEOUT_BLOCKS`
     *      is 24,000 on the jackpots, and it is right there: a jackpot roll is
     *      a background job nobody is standing over. A mint is not. A buyer who
     *      has paid and has nothing is a person waiting, and 24,000 blocks is
     *      hours of that.
     *
     *      It cannot be short either. The worst measured live fulfilment on
     *      chain 97 took **3,169 blocks**, and Chainlink has stalled on this
     *      project before — the node gates fulfilment on theoretical max gas at
     *      the lane cap, which is how the jackpot silently stopped resolving on
     *      launch day. Refunding while a word could still plausibly land is not
     *      unsafe (the flags below make the race harmless) but it is wasteful:
     *      the subscription has already paid for a word that then gets dropped.
     *
     *      7,200 is 2.3x the worst measured fulfilment. At BSC's current ~0.75s
     *      blocks that is about 90 minutes; at the older 3s it was six hours.
     *      ⚠ THE UNIT IS THE TRAP, AS EVERYWHERE ELSE HERE: this bounds a human
     *      wait, which is time, but it counts BLOCKS, so every BSC block-time
     *      reduction silently shortens it. Re-check it when the block time
     *      moves, which is why it is a bounded setter and not a `constant`.
     */
    uint256 public refundAfterBlocks = 7_200;

    /// @notice ⛔ THE FLOOR EXISTS TO STOP THE OWNER, not the buyer. Below the
    ///         worst observed fulfilment a refund window becomes a griefing
    ///         tool — reserve, refund immediately, repeat, and the queue churns
    ///         while the subscription pays for words nobody uses. 4,000 clears
    ///         the measured 3,169 with margin.
    uint256 public constant MIN_REFUND_AFTER_BLOCKS = 4_000;

    /// @notice Blocks between arming the fallback and the block whose hash
    ///         seeds it. Must be >= 1 so the hash does not exist at arm time —
    ///         that is the entire point of the two-step.
    uint8 public constant FALLBACK_DELAY_BLOCKS = 5;

    // ─── VRF configuration (owner-settable, bounded) ──────────────────────

    bytes32 public keyHash;
    uint256 public subscriptionId;
    uint16 public requestConfirmations = 3;
    uint32 public callbackGasLimit = 200_000;
    bool public payWithNative = true;

    uint16 public constant MIN_REQUEST_CONFIRMATIONS = 3;
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;

    /// @dev ⛔ `VRFConsumerBaseV2Plus.setCoordinator` is owner-callable with NO
    ///      timelock — the finding `JackpotNoWithdraw.t.sol` records. A word is
    ///      therefore only accepted from the TIMELOCKED slot, never from
    ///      whatever `s_vrfCoordinator` currently points at.
    TimelockedAddress.Slot private _coordinatorWire;

    /// @notice The only address allowed to `reserve`. Timelocked, never
    ///         one-time-set (`BUILD-PLAN.md` rule 2).
    TimelockedAddress.Slot private _sellerWire;

    uint256 public wiringDelay = 24 hours;
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;

    // ─── The pool ─────────────────────────────────────────────────────────

    /**
     * @notice Unsold token ids, in no meaningful order.
     * @dev An explicit array rather than the usual sparse "swap with last"
     *      mapping. The sparse trick needs a `0 means identity` sentinel and
     *      an assumption that the pool is one contiguous id range; this pen is
     *      stocked by transfer and must hold ANY set of ids, so the array is
     *      both more general and impossible to get subtly wrong. The cost is
     *      one SSTORE per token at stocking time, which is already dwarfed by
     *      the ERC-721 transfer it rides along with.
     */
    uint32[] private _pool;

    /// @notice Tokens promised to open reservations but not yet drawn. The
    ///         sellable pool is `_pool.length - reservedCount`.
    uint256 public reservedCount;

    // ─── Reservations ─────────────────────────────────────────────────────

    /**
     * @notice What a reservation is waiting on. Returned by `rescueState`.
     * @dev The order is "further from delivery" -> "delivered", so a UI can
     *      treat it as progress. Everything except `QueuedBehind` names an
     *      action ANYONE may take, including the buyer themselves.
     */
    enum Rescue {
        /// No such reservation.
        Unknown,
        /// Delivered. Nothing to do.
        Settled,
        /// The buyer took their money back. Terminal, and it means the mint
        /// FAILED for a real person - worth alerting on, not just indexing.
        Refunded,
        /// The refund window is open and this reservation's payer may take
        /// their money back. Only they can; anyone may still push it through
        /// to delivery instead.
        Refundable,
        /// VRF still has its window. `actionAtBlock` is when `armFallback`
        /// becomes callable.
        WaitingForVrf,
        /// VRF gave up. Call `armFallback(id)` now.
        ArmFallback,
        /// Armed. `actionAtBlock` is when `pinFallbackSeed` becomes callable.
        WaitFallback,
        /// Call `pinFallbackSeed(id)` now, before the blockhash ages out.
        PinFallback,
        /// Seeded and at the head of the queue. Call `settle(id)` now.
        Settle,
        /// Seeded, but an EARLIER reservation has to settle first. Unstick
        /// `blockedBy` — settlement is strict FIFO on purpose.
        QueuedBehind
    }

    struct Reservation {
        address to;
        uint16 count;
        bool settled;
        /// @notice ⛔ THE MUTUAL EXCLUSION. Set before any transfer, checked by
        ///         `settle`, `fulfillRandomWords`, `armFallback` and
        ///         `pinFallbackSeed`. A refunded reservation can never acquire
        ///         a seed and can never be settled, so a word that arrives
        ///         afterwards is inert rather than a second payout.
        bool refunded;
        /// @notice True once `seed` is final. Checked instead of `seed != 0`
        ///         because zero is a legitimate VRF word.
        bool seeded;
        uint64 reservedAtBlock;
        /// @notice Block whose hash seeds the fallback. Zero when unarmed.
        uint64 fallbackBlock;
        uint256 seed;
        /// @notice Who gets the money back. The PAYER, not `to` — a gifted
        ///         mint refunds the gifter, who is the one out of pocket.
        address payer;
        /// @notice BNB held for this reservation.
        uint256 nativeEscrow;
        /// @notice BNBULL held for this reservation.
        uint256 tokenEscrow;
    }

    /// @notice Reservations by id. Ids start at 1.
    mapping(uint256 => Reservation) private _reservations;
    /// @notice Ids drawn for a settled reservation, in draw order.
    mapping(uint256 => uint32[]) private _drawn;

    /// @notice Next reservation id to be issued.
    uint256 public nextReservationId = 1;

    /**
     * @notice The next reservation that may settle.
     * @dev ⛔ THIS IS A SECURITY CONTROL, NOT BOOKKEEPING. Settlement is strict
     *      FIFO precisely so that no caller can choose an ordering that suits
     *      their own draw. Do not add an "out of order" escape hatch.
     */
    uint256 public nextToSettle = 1;

    /// @notice VRF request id -> reservation id.
    mapping(uint256 => uint256) public reservationOfRequest;

    /// @notice A drawn token whose delivery transfer failed, and who it is
    ///         owed to. Pull-retry via `claim`.
    mapping(uint256 => address) public unclaimedOwner;

    /**
     * @notice Every reservation ever made FOR an address, oldest first.
     *
     * @dev ⚠ THIS IS NOT BOOKKEEPING EITHER — IT IS THE ONLY THING THAT MAKES
     *      A PENDING RESERVATION SURVIVE A PAGE RELOAD.
     *
     *      Delivery is asynchronous, so between paying and receiving there is a
     *      window in which the buyer owns nothing an ERC-721 wallet can show
     *      them. If the only handle on that window is a `reservationId` the
     *      site happened to keep in memory, then a refresh, a closed tab or a
     *      second device loses it, and the buyer is left with "I paid and
     *      nothing happened" — which is indistinguishable, from where they are
     *      standing, from being robbed.
     *
     *      Keyed on `to` (the RECIPIENT), not on the payer: `to` is who the
     *      bull is for, and a gifted mint must show up in the recipient's
     *      wallet view. `MintDrop.BullsReserved` carries both if an indexer
     *      needs the other side.
     */
    mapping(address => uint256[]) private _byOwner;

    /**
     * @notice The same index, keyed on the PAYER, for gifts only.
     *
     * @dev ⚠ THIS EXISTS BECAUSE THE REFUND GUARANTEE HAD A HOLE IN IT.
     *      `refund` is payer-only — deliberately, because the payer is who is
     *      out of pocket and because a permissionless refund hands the holder
     *      of a seeded reservation a free choice over their own draw. But the
     *      only index was keyed on the RECIPIENT. So on a gifted mint the one
     *      person entitled to the refund was the one person who could not find
     *      the reservation to refund it: the recipient could see it and be
     *      correctly told the money was not theirs, and the gifter had nothing
     *      at all. "You can always get your money back" was false for exactly
     *      the case where somebody else has your bull.
     *
     *      ⚠ ONLY WRITTEN WHEN `payer != to`, WHICH IS WHY IT COSTS THE NORMAL
     *      MINT NOTHING. Buying for yourself touches one array, as before. It
     *      also makes the two indexes DISJOINT by construction, so the union
     *      below is a concatenation and needs no de-duplication.
     */
    mapping(address => uint256[]) private _byPayer;

    /// @notice Refund money a payer could not receive (a contract that reverts
    ///         on `receive`). Pull-retry via `claimRefund`. A refund must never
    ///         revert: the queue has to advance whatever the payer's wallet
    ///         does, or one hostile buyer wedges the drop for everybody.
    mapping(address => uint256) public unclaimedRefundNative;
    mapping(address => uint256) public unclaimedRefundToken;

    /// @notice Escrow the seller refused on settle. Held, never lost, and
    ///         sweepable by the owner back into the seller.
    uint256 public unroutedNative;
    uint256 public unroutedToken;

    // ─── Events ───────────────────────────────────────────────────────────

    event Stocked(uint256 indexed tokenId, address indexed from, uint256 poolSize);
    event Reserved(
        uint256 indexed reservationId,
        address indexed to,
        uint16 count,
        uint256 indexed vrfRequestId
    );
    event Seeded(uint256 indexed reservationId, uint8 source);
    event FallbackArmed(uint256 indexed reservationId, uint64 fallbackBlock, address indexed by);
    event Settled(uint256 indexed reservationId, address indexed to, uint32[] tokenIds);
    event Delivered(uint256 indexed reservationId, address indexed to, uint256 indexed tokenId);
    event DeliveryDeferred(uint256 indexed reservationId, address indexed to, uint256 indexed tokenId);
    event Claimed(uint256 indexed tokenId, address indexed to);
    /// @notice A buyer took their money back. This means the mint FAILED for a
    ///         real person, so it is worth alerting on, not just indexing.
    event Refunded(
        uint256 indexed reservationId,
        address indexed payer,
        uint256 nativeAmount,
        uint256 tokenAmount
    );
    event RefundDeferred(uint256 indexed reservationId, address indexed payer, uint256 amount);
    event RefundClaimed(address indexed payer, uint256 amount);
    event EscrowRouted(uint256 indexed reservationId, uint256 nativeAmount, uint256 tokenAmount);
    /// @notice The seller refused its own money back. Held here, never lost.
    event EscrowRouteDeferred(uint256 indexed reservationId, uint256 nativeAmount, uint256 tokenAmount);
    event RefundAfterBlocksChanged(uint256 blocks_);
    event SellerWireBootstrapped(address indexed target);
    event SellerWireProposed(address indexed target, uint64 eta);
    event SellerWireCommitted(address indexed previous, address indexed next);
    event SellerWireCancelled(address indexed dropped);
    event CoordinatorWireProposed(address indexed target, uint64 eta);
    event CoordinatorWireCommitted(address indexed previous, address indexed next);
    event CoordinatorWireCancelled(address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event VrfConfigChanged(
        bytes32 keyHash,
        uint256 subscriptionId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        bool payWithNative
    );
    event VrfTimeoutChanged(uint256 vrfTimeoutBlocks);

    // ─── Errors ───────────────────────────────────────────────────────────
    // ⚠ `ZeroAddress` and `OnlyCoordinatorCanFulfill` are declared by
    // `VRFConsumerBaseV2Plus`. Do not redeclare them here.

    error BadAddress();
    error NotSeller();
    error InvalidCount(uint256 count);
    error PoolTooSmall(uint256 wanted, uint256 sellable);
    error UnknownReservation(uint256 reservationId);
    error NotNextToSettle(uint256 reservationId, uint256 expected);
    error NotSeededYet(uint256 reservationId);
    error AlreadySettled(uint256 reservationId);
    error AlreadySeeded(uint256 reservationId);
    error VrfTimeoutNotElapsed(uint64 reservedAt, uint256 timeoutBlocks);
    error FallbackNotArmed(uint256 reservationId);
    error FallbackNotReady(uint64 fallbackBlock);
    error FallbackExpired(uint64 fallbackBlock);
    error VrfNotConfigured();
    error UntrustedCoordinator(address caller);
    error BadVrfConfig();
    error NotStockable(address from);
    error TokenIdTooLarge(uint256 tokenId);
    error NothingUnclaimed(uint256 tokenId);
    error DelayOutOfRange(uint256 requested);
    error AlreadyRefunded(uint256 reservationId);
    error RefundWindowNotOpen(uint64 reservedAt, uint256 refundAfter);
    error NotThePayer(address caller, address payer);
    error NothingToClaim(address who);
    error RefundBlocksOutOfRange(uint256 requested);
    error ValueOutOfRange(uint256 requested, uint256 cap);

    // ─── Constructor ──────────────────────────────────────────────────────

    /**
     * @param _bulls       The Bulls ERC-721.
     * @param _owner       Intended owner. `ConfirmedOwner` is two-step, so this
     *                     address must call `acceptOwnership()` after deploy.
     * @param _coordinator Chainlink VRF v2.5 coordinator. BSC mainnet:
     *                     0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9.
     */
    constructor(address _bulls, address _bnbull, address _owner, address _coordinator)
        VRFConsumerBaseV2Plus(_coordinator)
    {
        if (_bulls == address(0) || _bnbull == address(0)) revert BadAddress();
        bulls = IERC721(_bulls);
        bnbull = IERC20(_bnbull);
        _coordinatorWire.bootstrap(_coordinator);
        if (_owner != address(0) && _owner != msg.sender) {
            transferOwnership(_owner);
        }
    }

    // ─── Stocking ─────────────────────────────────────────────────────────

    /**
     * @notice Take delivery of a bull and add it to the sellable pool.
     * @dev Stocked by TRANSFER, which is what keeps `Bulls` out of this change
     *      entirely — the owner mints the remaining supply straight to this
     *      address and `_safeMint` lands here. No new Bulls, no reissue, and
     *      every already-minted bull keeps the id it has today and therefore
     *      the exact rarity it has today.
     *
     *      Only a fresh mint (`from == 0`) or the owner may stock the pen. A
     *      bull that wandered in from a third party is REFUSED rather than
     *      silently absorbed into the drop.
     */
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(bulls)) revert NotStockable(msg.sender);
        if (from != address(0) && from != owner()) revert NotStockable(from);
        // The pool is `uint32` to keep a draw inside one slot. Bulls tops out
        // at #501 so this can never bind — but a silent truncation here would
        // deal a token that does not exist, so it is checked rather than
        // assumed.
        if (tokenId > type(uint32).max) revert TokenIdTooLarge(tokenId);
        _pool.push(uint32(tokenId));
        emit Stocked(tokenId, from, _pool.length);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ─── Reserve (tx 1: the seller has the money, nothing is decided yet) ──

    /**
     * @notice Reserve `count` bulls for `to`. Draws nothing and reveals
     *         nothing — that is the point.
     * @dev Seller-only. The seller has already taken payment; this contract
     *      never holds money.
     * @return reservationId The handle `settle` is called with.
     */
    function reserve(address to, uint16 count, address payer, uint256 tokenEscrow)
        external
        payable
        nonReentrant
        returns (uint256 reservationId)
    {
        if (msg.sender != _sellerWire.current) revert NotSeller();
        if (to == address(0) || to == address(this)) revert BadAddress();
        if (count == 0 || count > MAX_BATCH) revert InvalidCount(count);
        if (keyHash == bytes32(0) || subscriptionId == 0) revert VrfNotConfigured();

        uint256 free = _pool.length - reservedCount;
        if (count > free) revert PoolTooSmall(count, free);
        reservedCount += count;

        reservationId = nextReservationId++;
        Reservation storage r = _reservations[reservationId];
        r.to = to;
        r.count = count;
        r.reservedAtBlock = uint64(block.number);
        // The PAYER, not `to`. A gifted mint refunds the person who is out of
        // pocket. Zero is refused rather than quietly defaulted to `to`: a
        // refund with nowhere to go is money this contract could never release.
        if (payer == address(0)) revert BadAddress();
        r.payer = payer;
        r.nativeEscrow = msg.value;
        r.tokenEscrow = tokenEscrow;
        // One SSTORE, so the buyer can find their own pending reservation from
        // any device with nothing but their address. See `_byOwner`.
        _byOwner[to].push(reservationId);
        // Gifts only. See `_byPayer`: a self-mint is already findable, and
        // skipping the write keeps the ordinary path exactly as cheap as it was
        // while keeping the two indexes disjoint.
        if (payer != to) _byPayer[payer].push(reservationId);

        uint256 vrfRequestId = s_vrfCoordinator.requestRandomWords(
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
        reservationOfRequest[vrfRequestId] = reservationId;

        emit Reserved(reservationId, to, count, vrfRequestId);
    }

    // ─── Seeding ──────────────────────────────────────────────────────────

    /// @dev Stores the word and nothing else. Drawing here would put the work
    ///      under the coordinator's callback gas limit, and a callback that
    ///      runs out of gas loses the randomness for good.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        // ⛔ The word must come from the TIMELOCKED coordinator.
        if (msg.sender != _coordinatorWire.current) revert UntrustedCoordinator(msg.sender);
        uint256 reservationId = reservationOfRequest[requestId];
        if (reservationId == 0) return;
        Reservation storage r = _reservations[reservationId];
        // A second word for the same reservation is dropped, never applied —
        // re-seeding a live reservation would be a reroll.
        // A refunded reservation is INERT. This is the other half of the mutual
        // exclusion: the buyer already has their money, so accepting a word
        // here would let it settle and hand them the bull as well.
        if (r.seeded || r.settled || r.refunded) return;
        r.seed = randomWords[0];
        r.seeded = true;
        emit Seeded(reservationId, 0);
    }

    /**
     * @notice Arm the blockhash fallback for a reservation VRF has abandoned.
     * @dev Permissionless, and deliberately TWO steps. Arming only names a
     *      FUTURE block; the hash that becomes the seed does not exist yet, so
     *      whoever arms it cannot see what they are arming.
     *
     *      ⚠ RESIDUAL RISK, STATED PLAINLY: this path is weaker than VRF. A
     *      blockhash is only readable for 256 blocks, so if nobody pins in
     *      that window the fallback must be re-armed — and a buyer who is
     *      willing to sit on their own reservation, with VRF already down, and
     *      who can outlast every honest party including the keeper for 256
     *      consecutive blocks, gets one reroll per window. It is the degraded
     *      path behind a working VRF, not the normal one.
     */
    function armFallback(uint256 reservationId) external {
        Reservation storage r = _reservations[reservationId];
        if (r.count == 0) revert UnknownReservation(reservationId);
        if (r.settled) revert AlreadySettled(reservationId);
        if (r.refunded) revert AlreadyRefunded(reservationId);
        if (r.seeded) revert AlreadySeeded(reservationId);
        if (block.number < uint256(r.reservedAtBlock) + vrfTimeoutBlocks) {
            revert VrfTimeoutNotElapsed(r.reservedAtBlock, vrfTimeoutBlocks);
        }
        // Re-arming is only allowed once the previous window has genuinely
        // expired, so this cannot be used to shop for a block.
        if (r.fallbackBlock != 0) {
            uint256 expiry = uint256(r.fallbackBlock) + 256;
            if (block.number <= expiry) revert FallbackNotReady(r.fallbackBlock);
        }
        uint64 target = uint64(block.number + FALLBACK_DELAY_BLOCKS);
        r.fallbackBlock = target;
        emit FallbackArmed(reservationId, target, msg.sender);
    }

    /// @notice Pin the armed fallback's blockhash as the seed. Permissionless,
    ///         and the value is fixed by the armed block, not by the caller.
    function pinFallbackSeed(uint256 reservationId) external {
        Reservation storage r = _reservations[reservationId];
        if (r.count == 0) revert UnknownReservation(reservationId);
        if (r.settled) revert AlreadySettled(reservationId);
        if (r.refunded) revert AlreadyRefunded(reservationId);
        if (r.seeded) revert AlreadySeeded(reservationId);
        uint64 target = r.fallbackBlock;
        if (target == 0) revert FallbackNotArmed(reservationId);
        if (block.number <= target) revert FallbackNotReady(target);
        bytes32 bh = blockhash(target);
        if (bh == bytes32(0)) revert FallbackExpired(target);
        r.seed = uint256(keccak256(abi.encode(bh, reservationId, address(this))));
        r.seeded = true;
        emit Seeded(reservationId, 1);
    }

    // ─── Settle (tx 2: the seed is fixed, so reverting achieves nothing) ───

    /**
     * @notice Draw and deliver a seeded reservation. Anyone may call it.
     * @dev ⛔ STRICT FIFO. See `nextToSettle` — permitting out-of-order
     *      settlement would hand the caller a permutation of the pool to shop
     *      through.
     *
     *      All state is written BEFORE any transfer, so the outcome is already
     *      final when the first receiver hook runs. A hostile receiver can
     *      make its own delivery fail; it cannot change what was drawn, and it
     *      cannot stop the queue — the token is parked for `claim`.
     */
    function settle(uint256 reservationId) external nonReentrant {
        Reservation storage r = _reservations[reservationId];
        if (r.count == 0) revert UnknownReservation(reservationId);
        if (r.settled) revert AlreadySettled(reservationId);
        if (r.refunded) revert AlreadyRefunded(reservationId);
        if (reservationId != nextToSettle) revert NotNextToSettle(reservationId, nextToSettle);
        if (!r.seeded) revert NotSeededYet(reservationId);

        uint256 count = r.count;
        uint256 seed = r.seed;
        address to = r.to;

        uint32[] memory ids = new uint32[](count);
        for (uint256 j = 0; j < count; j++) {
            // ⛔ (seed, j) ONLY. No msg.sender, no block data, no gasleft.
            ids[j] = _drawOne(uint256(keccak256(abi.encode(seed, j))));
        }

        r.settled = true;
        _drawn[reservationId] = ids;
        reservedCount -= count;
        nextToSettle = reservationId + 1;

        emit Settled(reservationId, to, ids);

        for (uint256 j = 0; j < count; j++) {
            _deliver(reservationId, to, ids[j]);
        }

        // The bulls are in the buyer's hands, so the sale is real and the money
        // may now go where a direct mint would have sent it.
        _routeEscrow(reservationId, r);
        // A refunded slot in front of the next one would wedge the queue.
        _advanceQueue();
    }

    /**
     * @dev Hand the escrow back to the seller for the ordinary 20/10/70 split.
     *
     *      TRY/CATCH, NOT A BARE CALL, AND FOR THE SAME REASON EVERY POT LEG IN
     *      `MintDrop` IS ONE. `_routeNative` can revert - a treasury that stops
     *      accepting BNB is enough - and a revert here would take `settle` down
     *      with it. That does not merely fail one sale: settlement is strict
     *      FIFO, so it would wedge the queue for everybody behind it,
     *      permanently. The money is held here instead and the owner sweeps it
     *      back into the seller.
     */
    function _routeEscrow(uint256 reservationId, Reservation storage r) private {
        uint256 nat = r.nativeEscrow;
        uint256 tok = r.tokenEscrow;
        if (nat == 0 && tok == 0) return;
        r.nativeEscrow = 0;
        r.tokenEscrow = 0;

        address seller_ = _sellerWire.current;
        if (tok > 0) bnbull.safeTransfer(seller_, tok);
        try IMintDropRoute(seller_).routeReservedPayment{value: nat}(tok) {
            emit EscrowRouted(reservationId, nat, tok);
        } catch {
            unroutedNative += nat;
            unroutedToken += tok;
            emit EscrowRouteDeferred(reservationId, nat, tok);
        }
    }

    /**
     * @notice Take your money back for a reservation the draw never reached.
     *
     * @dev THREE CONDITIONS, AND EVERY ONE OF THEM IS LOAD-BEARING.
     *
     *      **`!seeded`, not merely `!settled`.** A seed makes the outcome
     *      computable off chain. A refund available after that point IS the
     *      free-abort attack the whole two-transaction design exists to close:
     *      buy, compute, and unwind unless it is a legendary. This is the single
     *      most important line in the contract after `_drawOne`.
     *
     *      **The PAYER only, not anybody.** Liveness does not need it to be
     *      permissionless: `armFallback`, `pinFallbackSeed` and `settle` are all
     *      permissionless, so ANYONE can always push a stuck reservation through
     *      to delivery and the queue can never be wedged by a lost key.
     *      Restricting the refund closes a real edge instead.
     *
     *        A refund draws nothing, so it does not touch `_pool` - but WHETHER
     *        a stuck reservation refunds or settles changes what the NEXT one
     *        draws. If refunding were permissionless, the holder of a seeded
     *        reservation B could refund a stranger's stuck reservation A and so
     *        pick between two outcomes for B, both computable off chain. One
     *        bit, free. Payer-only makes that bit cost the attacker a whole mint
     *        of their own, which is a trade nobody wants.
     *
     *        It is a NARROWING, NOT A PROOF: a buyer holding two reservations,
     *        one of them stuck, can still make that choice. Written down rather
     *        than papered over.
     *
     *      **After `refundAfterBlocks`.** See that variable for the number and
     *      why it is not the house 24,000.
     *
     *      Never reverts on the transfer. A payer that refuses delivery has it
     *      parked for `claimRefund`, because a refund that can revert is a
     *      refund a hostile contract can use to wedge the FIFO queue.
     */
    function refund(uint256 reservationId) external nonReentrant {
        Reservation storage r = _reservations[reservationId];
        if (r.count == 0) revert UnknownReservation(reservationId);
        if (r.settled) revert AlreadySettled(reservationId);
        if (r.refunded) revert AlreadyRefunded(reservationId);
        // THE POINT OF NO RETURN.
        if (r.seeded) revert AlreadySeeded(reservationId);
        if (msg.sender != r.payer) revert NotThePayer(msg.sender, r.payer);
        if (block.number < uint256(r.reservedAtBlock) + refundAfterBlocks) {
            revert RefundWindowNotOpen(r.reservedAtBlock, refundAfterBlocks);
        }

        // EVERY BIT OF STATE BEFORE ANY EXTERNAL CALL. `refunded` is what makes
        // a word arriving later inert, so it must already be true before
        // anything can re-enter.
        r.refunded = true;
        uint256 nat = r.nativeEscrow;
        uint256 tok = r.tokenEscrow;
        r.nativeEscrow = 0;
        r.tokenEscrow = 0;
        // The bulls promised to this reservation go back on sale. Nothing was
        // ever drawn, so `_pool` itself is untouched.
        reservedCount -= r.count;
        address payer = r.payer;

        _advanceQueue();
        emit Refunded(reservationId, payer, nat, tok);

        if (tok > 0) unclaimedRefundToken[payer] += tok;
        if (nat > 0) {
            (bool ok,) = payer.call{value: nat}("");
            if (!ok) {
                unclaimedRefundNative[payer] += nat;
                emit RefundDeferred(reservationId, payer, nat);
            }
        }
        if (tok > 0) _payoutToken(payer);
    }

    /// @notice Collect a refund whose push failed. Anyone may call it FOR a
    ///         payer; the money can only ever go to the payer.
    function claimRefund(address payer) external nonReentrant {
        uint256 nat = unclaimedRefundNative[payer];
        uint256 tok = unclaimedRefundToken[payer];
        if (nat == 0 && tok == 0) revert NothingToClaim(payer);
        unclaimedRefundNative[payer] = 0;
        if (nat > 0) {
            (bool ok,) = payer.call{value: nat}("");
            if (!ok) {
                unclaimedRefundNative[payer] = nat;
                nat = 0;
            }
        }
        if (tok > 0) _payoutToken(payer);
        emit RefundClaimed(payer, nat);
    }

    function _payoutToken(address payer) private {
        uint256 tok = unclaimedRefundToken[payer];
        if (tok == 0) return;
        unclaimedRefundToken[payer] = 0;
        bnbull.safeTransfer(payer, tok);
    }

    /**
     * @dev Move the queue head past refunded slots.
     *
     *      A REFUND LEAVES A HOLE, AND A HOLE IN A STRICT-FIFO QUEUE IS A WEDGE.
     *      `settle` refuses anything that is not `nextToSettle`, and a refunded
     *      reservation can never be settled, so without this every reservation
     *      behind a refunded one would be stuck forever.
     *
     *      Skipping is safe precisely BECAUSE a refund draws nothing: `_pool` is
     *      identical either side of it, so no ordering has been handed to a
     *      caller that they did not already have. See `refund` for the one
     *      residual edge this does not close.
     */
    function _advanceQueue() private {
        uint256 n = nextToSettle;
        uint256 end = nextReservationId;
        while (n < end && _reservations[n].refunded) {
            unchecked {
                n++;
            }
        }
        nextToSettle = n;
    }

    /// @notice Push escrow the seller refused back at it. Owner-only, and it
    ///         can only ever go to the seller, never to the owner.
    function sweepUnrouted() external onlyOwner nonReentrant {
        uint256 nat = unroutedNative;
        uint256 tok = unroutedToken;
        if (nat == 0 && tok == 0) revert NothingToClaim(address(this));
        unroutedNative = 0;
        unroutedToken = 0;
        address seller_ = _sellerWire.current;
        if (tok > 0) bnbull.safeTransfer(seller_, tok);
        IMintDropRoute(seller_).routeReservedPayment{value: nat}(tok);
        emit EscrowRouted(0, nat, tok);
    }

    /// @dev Uniform draw from the remaining pool: pick an index, swap the tail
    ///      in, pop. This is one step of a lazy Fisher-Yates and it is exactly
    ///      uniform over what is left.
    function _drawOne(uint256 word) private returns (uint32 tokenId) {
        uint256 n = _pool.length;
        uint256 i = word % n;
        tokenId = _pool[i];
        uint256 last = n - 1;
        if (i != last) _pool[i] = _pool[last];
        _pool.pop();
    }

    /// @dev Push delivery with a pull fallback. `safeTransferFrom` is kept so a
    ///      contract that cannot hold ERC-721s is not silently handed one, but
    ///      a reverting receiver must not be able to wedge the FIFO queue.
    function _deliver(uint256 reservationId, address to, uint32 tokenId) private {
        try bulls.safeTransferFrom(address(this), to, tokenId) {
            emit Delivered(reservationId, to, tokenId);
        } catch {
            unclaimedOwner[tokenId] = to;
            emit DeliveryDeferred(reservationId, to, tokenId);
        }
    }

    /// @notice Retry a deferred delivery. The token is already spoken for; this
    ///         only moves it.
    function claim(uint256 tokenId) external nonReentrant {
        address to = unclaimedOwner[tokenId];
        if (to == address(0)) revert NothingUnclaimed(tokenId);
        delete unclaimedOwner[tokenId];
        bulls.safeTransferFrom(address(this), to, tokenId);
        emit Claimed(tokenId, to);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    /// @notice Bulls physically held, including those promised to open
    ///         reservations.
    function poolSize() external view returns (uint256) {
        return _pool.length;
    }

    /// @notice Bulls that may still be reserved.
    function sellable() external view returns (uint256) {
        return _pool.length - reservedCount;
    }

    /**
     * @notice The unsold pool, for the site's "what is left" panel.
     * @dev ⚠ THIS IS PUBLIC AND IT IS SUPPOSED TO BE. Knowing the SET that is
     *      left tells you the odds, which is the honest thing to publish. It
     *      does not tell you which one you will get, because that is decided
     *      by a seed that does not exist when you pay.
     */
    function poolAt(uint256 index) external view returns (uint32) {
        return _pool[index];
    }

    /**
     * @notice The whole unsold pool in one call.
     *
     * @dev ⚠ THIS EXISTS FOR THE COUNTING BUG, NOT FOR CONVENIENCE. Once the
     *      pen is stocked, `Bulls.nextTokenId()` is 501 while several hundred
     *      bulls have never been sold — so every surface that reads
     *      "`nextTokenId - 1` bulls are minted" is wrong by exactly this array's
     *      length. The honest circulating set is `1..nextTokenId-1` MINUS this,
     *      and getting it needed 469 separate `poolAt` calls until this
     *      existed.
     *
     *      Publishing the set is already the documented position (`poolAt`):
     *      knowing WHAT is left tells you the odds, which is the honest thing
     *      to publish, and it still does not tell you WHICH one you will get.
     *      Bounded by `Bulls.MAX_SUPPLY`, so it cannot grow without bound.
     */
    function poolIds() external view returns (uint32[] memory) {
        return _pool;
    }

    function reservationOf(uint256 reservationId) external view returns (Reservation memory) {
        return _reservations[reservationId];
    }

    function drawnIds(uint256 reservationId) external view returns (uint32[] memory) {
        return _drawn[reservationId];
    }

    /**
     * @notice Every reservation `who` has an interest in, oldest first —
     *         whether they are receiving the bull or paid for it.
     *
     * @dev ⚠ BOTH ROLES, NOT JUST THE RECIPIENT. A gifted mint concerns two
     *      people and they need different things from it: the recipient is
     *      waiting for a bull, and the PAYER holds the refund right. Indexing
     *      only the recipient left the gifter unable to find the one
     *      reservation they were entitled to refund. See `_byPayer`.
     *
     *      The two indexes are disjoint by construction (`_byPayer` is only
     *      written when `payer != to`), so this concatenates and never needs to
     *      de-duplicate. Order is recipient-side first, then payer-side; within
     *      each, oldest first.
     */
    function reservationIdsOf(address who) public view returns (uint256[] memory all) {
        uint256[] storage mine = _byOwner[who];
        uint256[] storage paid = _byPayer[who];
        all = new uint256[](mine.length + paid.length);
        uint256 j;
        for (uint256 i = 0; i < mine.length; i++) {
            all[j++] = mine[i];
        }
        for (uint256 i = 0; i < paid.length; i++) {
            all[j++] = paid[i];
        }
    }

    /// @notice Only the reservations `who` still has an interest in, i.e. "you
    ///         paid for these and they have not been delivered". The read the
    ///         site's "a bull is on its way" banner is built on.
    ///
    /// @dev ⚠ A REFUNDED RESERVATION IS STILL LISTED, ON PURPOSE. The filter is
    ///      `!settled`, not `!settled && !refunded`, so the "your money came
    ///      back, here is what happened, mint again" dialogue survives a page
    ///      reload instead of vanishing the moment it becomes true. Callers
    ///      distinguish the two through `rescueState`, which reports `Refunded`
    ///      as its own terminal state.
    function openReservationsOf(address who) external view returns (uint256[] memory open) {
        uint256[] memory all = reservationIdsOf(who);
        uint256 n = all.length;
        uint256 hits;
        for (uint256 i = 0; i < n; i++) {
            if (!_reservations[all[i]].settled) hits++;
        }
        open = new uint256[](hits);
        uint256 j;
        for (uint256 i = 0; i < n; i++) {
            if (!_reservations[all[i]].settled) open[j++] = all[i];
        }
    }

    // ─── Liveness: what is stuck, and what unsticks it ────────────────────

    /**
     * @notice What a reservation is waiting on, and the block at which the
     *         next action becomes possible.
     *
     * @dev ⚠ THIS IS THE ANSWER TO "I PAID AND I HAVE NO BULL", AND IT IS A
     *      VIEW RATHER THAN A NEW MECHANISM ON PURPOSE.
     *
     *      Money routes at `reserve` time, so a reservation that never settles
     *      is the one failure in this design that costs a real player real
     *      money. The escape already exists and is permissionless —
     *      `armFallback` -> `pinFallbackSeed` -> `settle`, none of which
     *      needs VRF to be alive, an owner key, or a keeper. What did NOT exist
     *      was any way for the buyer or a keeper to find out that they are the
     *      one who has to press it, or when.
     *
     *      A refund path was considered and rejected: it would make this
     *      contract custody money (it deliberately does not), and a refund
     *      offered AFTER a seed exists is a free abort, which is the exact
     *      attack the whole two-transaction design is built to close. A
     *      keeper-callable VRF re-request was considered and rejected too: it
     *      is useless in the case that actually matters, because the case that
     *      matters is VRF not answering.
     *
     * @return state       What to do — see `Rescue`.
     * @return actionAtBlock Block at which `state`'s action becomes callable.
     *                     Equal to `block.number` when it is callable now.
     * @return blockedBy   For `QueuedBehind`, the reservation that must settle
     *                     first. Zero otherwise.
     */
    function rescueState(uint256 reservationId)
        external
        view
        returns (Rescue state, uint256 actionAtBlock, uint256 blockedBy)
    {
        Reservation storage r = _reservations[reservationId];
        if (r.count == 0) return (Rescue.Unknown, 0, 0);
        if (r.settled) return (Rescue.Settled, 0, 0);
        if (r.refunded) return (Rescue.Refunded, 0, 0);

        if (r.seeded) {
            if (reservationId != nextToSettle) {
                return (Rescue.QueuedBehind, 0, nextToSettle);
            }
            return (Rescue.Settle, block.number, 0);
        }

        // Not seeded. VRF still has its window.
        uint256 refundable = uint256(r.reservedAtBlock) + refundAfterBlocks;
        uint256 armable = uint256(r.reservedAtBlock) + vrfTimeoutBlocks;
        // The refund window opens FIRST and stays open. A buyer gets the choice
        // to leave before the system starts forcing an outcome onto them.
        if (block.number < refundable) return (Rescue.WaitingForVrf, refundable, 0);
        if (block.number < armable) return (Rescue.Refundable, armable, 0);

        uint64 target = r.fallbackBlock;
        if (target == 0) return (Rescue.ArmFallback, block.number, 0);
        if (block.number <= target) return (Rescue.WaitFallback, uint256(target) + 1, 0);
        // `blockhash` reaches back exactly 256 blocks, and `armFallback` only
        // permits a re-arm once that window has closed — so the two are
        // adjacent and there is no block at which neither action is available.
        if (block.number <= uint256(target) + 256) return (Rescue.PinFallback, block.number, 0);
        return (Rescue.ArmFallback, block.number, 0);
    }

    /// @notice `rescueState` for the reservation at the head of the FIFO queue —
    ///         the only one whose being stuck can hold up anybody else. The
    ///         single bounded read a liveness keeper needs.
    function queueHead()
        external
        view
        returns (uint256 reservationId, Rescue state, uint256 actionAtBlock)
    {
        reservationId = nextToSettle;
        if (reservationId >= nextReservationId) return (reservationId, Rescue.Unknown, 0);
        (state, actionAtBlock,) = this.rescueState(reservationId);
    }

    function seller() external view returns (address) {
        return _sellerWire.current;
    }

    function sellerWire() external view returns (address current, address pending, uint64 eta) {
        TimelockedAddress.Slot storage s = _sellerWire;
        return (s.current, s.pending, s.eta);
    }

    function coordinatorWire()
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        TimelockedAddress.Slot storage s = _coordinatorWire;
        return (s.current, s.pending, s.eta);
    }

    // ─── Admin: wiring ────────────────────────────────────────────────────

    function bootstrapSeller(address target) external onlyOwner {
        _sellerWire.bootstrap(target);
        emit SellerWireBootstrapped(target);
    }

    function proposeSeller(address target) external onlyOwner returns (uint64 eta) {
        eta = _sellerWire.propose(target, wiringDelay);
        emit SellerWireProposed(target, eta);
    }

    function commitSeller() external onlyOwner {
        (address previous, address next) = _sellerWire.commit();
        emit SellerWireCommitted(previous, next);
    }

    function cancelSeller() external onlyOwner {
        address dropped = _sellerWire.cancel();
        emit SellerWireCancelled(dropped);
    }

    function proposeCoordinator(address target) external onlyOwner returns (uint64 eta) {
        eta = _coordinatorWire.propose(target, wiringDelay);
        emit CoordinatorWireProposed(target, eta);
    }

    /**
     * @notice Commit a matured coordinator change.
     * @dev ⚠ THIS DOES NOT MOVE `s_vrfCoordinator`, and that is deliberate —
     *      it is `external` on the base contract, so it cannot be called from
     *      in here, and the same split is what `JackpotNative` ships. A word is
     *      only accepted when BOTH pointers agree, so the owner must also call
     *      `setCoordinator(next)`. Until they do, requests still go to the old
     *      coordinator and its words are refused: dark, never wrong.
     */
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

    // ─── Admin: VRF ───────────────────────────────────────────────────────

    function setVrfConfig(
        bytes32 _keyHash,
        uint256 _subscriptionId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _payWithNative
    ) external onlyOwner {
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

    /// @notice Retune the refund clock. Bounded below by
    ///         `MIN_REFUND_AFTER_BLOCKS` and above by `vrfTimeoutBlocks`, so the
    ///         refund window can never open after the forced-draw window nor
    ///         close the gap the buyer's choice lives in.
    function setRefundAfterBlocks(uint256 blocks_) external onlyOwner {
        if (blocks_ < MIN_REFUND_AFTER_BLOCKS || blocks_ >= vrfTimeoutBlocks) {
            revert RefundBlocksOutOfRange(blocks_);
        }
        refundAfterBlocks = blocks_;
        emit RefundAfterBlocksChanged(blocks_);
    }

    function setVrfTimeoutBlocks(uint256 blocks_) external onlyOwner {
        if (blocks_ == 0 || blocks_ > MAX_VRF_TIMEOUT_BLOCKS) {
            revert ValueOutOfRange(blocks_, MAX_VRF_TIMEOUT_BLOCKS);
        }
        // The forced-draw window must stay BEHIND the refund window. Lowering
        // it under the refund clock would let a stranger settle a reservation
        // its buyer was still entitled to walk away from.
        if (blocks_ <= refundAfterBlocks) revert ValueOutOfRange(blocks_, refundAfterBlocks);
        vrfTimeoutBlocks = blocks_;
        emit VrfTimeoutChanged(blocks_);
    }
}
