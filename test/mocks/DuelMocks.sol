// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The slice of `Duel` these mocks need. Deliberately re-declared with a
///      `Duel`-mock-specific name: Solidity hoists file-level declarations into
///      any importer, and `Duel.sol` already publishes `IDuelJackpot` /
///      `IPotDonation` / `IMarketplaceListing` / `IWrappedBNB`.
interface IDuelUnderTest {
    struct DuelResult {
        uint256 tokenA;
        uint256 tokenB;
        uint32 winnerId;
        uint16 rounds;
        uint256 seed;
        uint32 newEloA;
        uint32 newEloB;
        address assetA;
        address assetB;
        uint256 stakeA;
        uint256 stakeB;
        uint64 seqA;
        uint64 seqB;
        uint256 nonce;
        uint256 expiry;
    }

    function submitDuel(DuelResult calldata result, bytes calldata signature) external payable;
    function fightSeq(address wallet) external view returns (uint64);
}

interface IBullsRead {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isDead(uint256 tokenId) external view returns (bool);
}

// ══════════════════════════════════════════════════════════════════════════
//  Jackpots
// ══════════════════════════════════════════════════════════════════════════

/**
 * @notice A pot that records every ticket it is handed, so a test can prove
 *         BOTH pools got the SAME `duelKey` for one fight.
 */
contract DuelRecordingJackpot {
    struct Opened {
        address winner;
        uint256 tokenId;
        uint256 entropy;
        uint256 duelKey;
    }

    Opened[] public opened;
    uint256 public resolveCalls;
    uint256 public funded;

    function recordWin(address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        external
        returns (uint256)
    {
        opened.push(Opened(winner, tokenId, entropy, duelKey));
        return opened.length - 1;
    }

    function resolve(uint256) external returns (uint256) {
        resolveCalls += 1;
        return 0;
    }

    function fund(uint256 amount, string calldata) external {
        funded += amount;
    }

    function count() external view returns (uint256) {
        return opened.length;
    }

    function keyAt(uint256 i) external view returns (uint256) {
        return opened[i].duelKey;
    }
}

/// @dev A pot that is simply broken. `recordWin` AND `resolve` revert.
///      `DECISIONS.md` / `Duel.sol`: "A failed roll costs a ticket, never the
///      duel." This is the thing that must not stop a fight.
contract DuelRevertingJackpot {
    function recordWin(address, uint256, uint256, uint256) external pure returns (uint256) {
        revert("DuelRevertingJackpot: down");
    }

    function resolve(uint256) external pure returns (uint256) {
        revert("DuelRevertingJackpot: down");
    }

    function fund(uint256, string calldata) external pure {
        revert("DuelRevertingJackpot: down");
    }
}

/**
 * @notice A pot whose `recordWin` burns an enormous amount of gas before
 *         giving up.
 *
 * @dev The nastiest shape a try/catch has to survive, and the one people
 *      forget: EIP-150 forwards 63/64 of the remaining gas to a sub-call, so a
 *      guzzler that runs itself out of gas still leaves the caller 1/64 to
 *      finish the duel with — but only if the duel is not doing anything
 *      expensive afterwards. Proving the fight still settles is proving the
 *      ordering is right, not just the try/catch.
 */
contract DuelGuzzlerJackpot {
    /// @dev Arithmetic, not hashing: `keccak256(abi.encodePacked(...))` in a
    ///      loop grows memory quadratically and the gas bill stops being a
    ///      knob and starts being a wall. This burns ~10 gas an iteration with
    ///      a flat memory profile.
    uint256 public loops = 500_000;
    uint256 public sink;

    function setLoops(uint256 n) external {
        loops = n;
    }

    function recordWin(address, uint256, uint256, uint256) external returns (uint256) {
        unchecked {
            uint256 x = 1;
            for (uint256 i = 0; i < loops; i++) {
                x = x * 3 + i;
            }
            sink = x;
        }
        revert("DuelGuzzlerJackpot: out of patience");
    }

    function resolve(uint256) external pure returns (uint256) {
        return 0;
    }

    function fund(uint256, string calldata) external pure {}
}

// ══════════════════════════════════════════════════════════════════════════
//  Marketplace
// ══════════════════════════════════════════════════════════════════════════

/// @dev A marketplace whose listing read can be driven, including into a
///      revert — the fail-CLOSED case `Duel._validate` documents.
contract DuelListingMarketplace {
    mapping(uint256 => bool) public listed;
    bool public readReverts;

    function setListed(uint256 tokenId, bool v) external {
        listed[tokenId] = v;
    }

    function setReadReverts(bool b) external {
        readReverts = b;
    }

    function isListed(uint256 tokenId) external view returns (bool) {
        if (readReverts) revert("DuelListingMarketplace: down");
        return listed[tokenId];
    }
}

// ══════════════════════════════════════════════════════════════════════════
//  Callers
// ══════════════════════════════════════════════════════════════════════════

/**
 * @notice A phase-2 style router that escrows both bulls and submits on the
 *         players' behalf. `DECISIONS.md §16`: equal owners that ARE the
 *         router is escrow, not a self-duel.
 */
contract DuelRouterMock {
    address public immutable duel;

    constructor(address _duel) {
        duel = _duel;
    }

    function submit(IDuelUnderTest.DuelResult calldata r, bytes calldata sig) external payable {
        IDuelUnderTest(duel).submitDuel{value: msg.value}(r, sig);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/**
 * @notice A contract player that snapshots the world INSIDE its refund
 *         callback.
 *
 * @dev This is how "refund dead last" is proved rather than asserted. The
 *      refund is the one call in `submitDuel` that hands control to an address
 *      of the caller's choosing, so by the time this `receive()` runs, every
 *      piece of state must already be settled: the sequence bumped, the bull's
 *      record written, the winner paid. If the refund moved earlier, one of
 *      these snapshots would come back half-done.
 */
contract DuelRefundProbe {
    address public duel;
    address public bulls;
    address public wbnbToken;

    bool public sawRefund;
    uint256 public refundAmount;
    uint64 public seqAtRefund;
    uint256 public wbnbAtRefund;
    bool public deadAtRefund;
    uint256 public watchToken;

    function configure(address _duel, address _bulls, address _wbnb, uint256 _watchToken)
        external
    {
        duel = _duel;
        bulls = _bulls;
        wbnbToken = _wbnb;
        watchToken = _watchToken;
    }

    function submit(IDuelUnderTest.DuelResult calldata r, bytes calldata sig) external payable {
        IDuelUnderTest(duel).submitDuel{value: msg.value}(r, sig);
    }

    function approveWbnb(address spender, uint256 amount) external {
        IERC20(wbnbToken).approve(spender, amount);
    }

    receive() external payable {
        sawRefund = true;
        refundAmount = msg.value;
        seqAtRefund = IDuelUnderTest(duel).fightSeq(address(this));
        wbnbAtRefund = IERC20(wbnbToken).balanceOf(address(this));
        deadAtRefund = IBullsRead(bulls).isDead(watchToken);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}

/// @dev A player whose `receive()` refuses the oracle cushion. `RefundFailed`
///      is the correct answer — the payer chose to be a contract that cannot
///      take its own money back.
contract DuelRefundRejector {
    address public immutable duel;

    constructor(address _duel) {
        duel = _duel;
    }

    function submit(IDuelUnderTest.DuelResult calldata r, bytes calldata sig) external payable {
        IDuelUnderTest(duel).submitDuel{value: msg.value}(r, sig);
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("DuelRefundRejector: keep it");
    }
}

// ══════════════════════════════════════════════════════════════════════════
//  Wrapped BNB, misbehaving
// ══════════════════════════════════════════════════════════════════════════

/**
 * @notice A WBNB that credits LESS than it was sent.
 *
 * @dev `Duel._collectStakes` measures the wrap even though a wrap is 1:1 and
 *      "measuring is free". This is the token that makes that paranoia pay:
 *      without the measurement the duel would settle a pot it does not hold.
 */
contract DuelShortWBNB is ERC20 {
    uint256 public creditBps = 9_000;

    constructor() ERC20("Short WBNB", "sWBNB") {}

    function setCreditBps(uint256 b) external {
        creditBps = b;
    }

    function deposit() external payable {
        _mint(msg.sender, (msg.value * creditBps) / 10_000);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev A Yards stand-in that blocks nothing.
 *
 * ⚠ IT EXISTS BECAUSE `DuelNative._requireInYards` FAILS CLOSED. The WBNB-era
 *    contract skipped the check on an unwired slot, so every native fixture in
 *    this repo was written without wiring one — and passed. So was the shipped
 *    migration script, which bootstraps four of the five wires. An external
 *    review turned that into 0.8 BNB lifted from a wallet whose only action had
 *    ever been `deposit()`: push a junk bull at a depositor, fight it, and the
 *    custodied float pays, because credit needs no allowance and ERC-721 needs
 *    no consent to receive.
 *
 *    Wiring this keeps a money-path fixture about money paths. It deliberately
 *    does NOT make the gate permissive in production — the real `Yards` is what
 *    ships, and the gate's own behaviour is covered in `DuelYards.t.sol` and by
 *    the review PoC that pushes an unentered bull.
 */
contract PermissiveYards {
    function fightBlocked(uint256, address, uint256, address) external pure returns (uint256) {
        return 0;
    }
}
