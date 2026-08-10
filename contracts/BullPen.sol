// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

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
 *      WHAT THIS DELIBERATELY DOES NOT DO
 *      ══════════════════════════════════════════════════════════════════════
 *      It does not hold money and it has no refund path. The seller
 *      (`MintDrop`) routes the payment at `reserve` time exactly as it always
 *      has — untouched code. The cost of that choice is that delivery liveness
 *      matters: see `armFallback`.
 */
contract BullPen is VRFConsumerBaseV2Plus, ReentrancyGuard, IERC721Receiver {
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── Immutables ───────────────────────────────────────────────────────

    /// @notice The collection this pen stocks.
    IERC721 public immutable bulls;

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

    struct Reservation {
        address to;
        uint16 count;
        bool settled;
        /// @notice True once `seed` is final. Checked instead of `seed != 0`
        ///         because zero is a legitimate VRF word.
        bool seeded;
        uint64 reservedAtBlock;
        /// @notice Block whose hash seeds the fallback. Zero when unarmed.
        uint64 fallbackBlock;
        uint256 seed;
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
    error ValueOutOfRange(uint256 requested, uint256 cap);

    // ─── Constructor ──────────────────────────────────────────────────────

    /**
     * @param _bulls       The Bulls ERC-721.
     * @param _owner       Intended owner. `ConfirmedOwner` is two-step, so this
     *                     address must call `acceptOwnership()` after deploy.
     * @param _coordinator Chainlink VRF v2.5 coordinator. BSC mainnet:
     *                     0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9.
     */
    constructor(address _bulls, address _owner, address _coordinator)
        VRFConsumerBaseV2Plus(_coordinator)
    {
        if (_bulls == address(0)) revert BadAddress();
        bulls = IERC721(_bulls);
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
    function reserve(address to, uint16 count)
        external
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
        if (r.seeded || r.settled) return;
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

    function reservationOf(uint256 reservationId) external view returns (Reservation memory) {
        return _reservations[reservationId];
    }

    function drawnIds(uint256 reservationId) external view returns (uint32[] memory) {
        return _drawn[reservationId];
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

    function setVrfTimeoutBlocks(uint256 blocks_) external onlyOwner {
        if (blocks_ == 0 || blocks_ > MAX_VRF_TIMEOUT_BLOCKS) {
            revert ValueOutOfRange(blocks_, MAX_VRF_TIMEOUT_BLOCKS);
        }
        vrfTimeoutBlocks = blocks_;
        emit VrfTimeoutChanged(blocks_);
    }
}
