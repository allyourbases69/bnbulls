// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {ForkAddresses as A} from "./ForkAddresses.sol";
import {
    IERC20Fork,
    IWBNBFork,
    IPancakeFactoryFork,
    IPancakePairFork,
    IPancakeRouterFork,
    IPancakeV3FactoryFork,
    IAggregatorV3Fork,
    ITokenManager2Fork,
    IFourMemeTokenFork
} from "./ForkInterfaces.sol";

/**
 * @title ForkBase
 * @notice Shared harness for the BSC mainnet-fork E2E package.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHY THIS DIRECTORY EXISTS
 * ══════════════════════════════════════════════════════════════════════════
 *
 * All 540 tests in `test/*.t.sol` are mock-based, and `test/Base.t.sol` says
 * so in its own header: *"⚠ NO MAINNET FORK ANYWHERE IN THIS SUITE,
 * DELIBERATELY … A fork E2E … is a LATER SLICE, and it is the only thing that
 * can prove the live wiring."* This is that slice.
 *
 * A mock router quotes whatever it is told, so it is **structurally incapable**
 * of catching the bug that actually bit Fighting Fefers: a $50 dev buy
 * published as $13.26 because the factory's `getPair` answered with a decoy
 * pool holding ~6.6k while the real book was elsewhere
 * (`BNB-CHAIN-FACTS.md §3`). No amount of mock coverage finds that. Only real
 * contracts, holding real liquidity, at a real block, can.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  HOW TO RUN — this package is EXCLUDED from `forge test` on purpose
 * ══════════════════════════════════════════════════════════════════════════
 *
 *   FOUNDRY_PROFILE=fork forge test -j 1     <-- FIRST RUN (cold cache)
 *   FOUNDRY_PROFILE=fork forge test          <-- every run after that
 *
 * `foundry.toml`'s default profile carries `no_match_path = "test/fork/**"`, so
 * `forge test` runs the mock suite and nothing from here; `[profile.fork]`
 * points `test` at this directory and nothing else. Running a single file:
 *
 *   FOUNDRY_PROFILE=fork forge test --match-contract DecoyPoolForkTest -vv
 *
 * `-vv` is worth it: several tests exist to PRINT a measured number, and the
 * number is the finding.
 *
 * ⚠ `-j 1` ON THE FIRST RUN, AND IT IS NOT SUPERSTITION. Measured: with the
 * default thread count and an empty cache, six suites fetch state in parallel
 * and the free endpoint answers **HTTP 429 "Rate limit reached"** — 25 of 61
 * tests failed with `database error: failed to get account for …`, which looks
 * like a contract bug and is not one. Single-threaded, the same cold run is
 * 61/61 in ~2m15s. Once `~/.foundry/cache/rpc/bsc/<block>` is populated the
 * whole package replays offline in under half a second, which is the other
 * half of why the block is PINNED.
 *
 * ⚠ THE RPC MUST BE AN ARCHIVE ENDPOINT. `RPC_URL` in `.env.example` is
 * `https://bsc-rpc.publicnode.com`, which answers a pinned-block state read
 * with **HTTP 403 "Archive requests require a personal token"** — verified,
 * not assumed. A pinned fork therefore CANNOT use it. This harness reads
 * `BSC_FORK_RPC_URL` and otherwise falls back to the endpoint that the
 * four.meme drill in `FOUR-MEME-LAUNCH-ROUTE.md` used for its three
 * graduations and that answers archive reads today. A keyed endpoint removes
 * the `-j 1` requirement.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHAT THIS HARNESS DELIBERATELY DOES NOT DO
 * ══════════════════════════════════════════════════════════════════════════
 *
 *  - It never broadcasts. Every transaction here is a fork transaction. There
 *    is nothing of ours on chain 56 and this package does not put anything
 *    there.
 *  - It never redeclares the swap ABI of `PotSplitter`, the splitters or
 *    `MintDrop`. Those are mid-rewrite (`DECISIONS.md §28` v3→v2), so the
 *    assertions here are on **behaviour that survives the change**: measured
 *    balance deltas, `minOut == 0` refused, a thin or missing book deferring
 *    rather than trading, and accrual that never reverts the user's mint.
 *  - It never assumes a graduated BNBULL exists. `DECISIONS.md §29` is
 *    explicit that it does not, and that it could not be transferred even if
 *    it did. Every test needing that state MANUFACTURES it on the fork by
 *    graduating a real four.meme token.
 */
abstract contract ForkBase is Test {
    // ─── Live contracts, typed ────────────────────────────────────────────

    IWBNBFork internal constant wbnb = IWBNBFork(A.WBNB);
    IPancakeRouterFork internal constant v2Router = IPancakeRouterFork(A.PANCAKE_V2_ROUTER);
    IPancakeFactoryFork internal constant v2Factory = IPancakeFactoryFork(A.PANCAKE_V2_FACTORY);
    IPancakeV3FactoryFork internal constant v3Factory = IPancakeV3FactoryFork(A.PANCAKE_V3_FACTORY);
    IAggregatorV3Fork internal constant bnbUsdFeed = IAggregatorV3Fork(A.CHAINLINK_BNB_USD);
    ITokenManager2Fork internal constant fourMeme = ITokenManager2Fork(A.FOUR_MEME_TOKEN_MANAGER);

    // ─── Actors ───────────────────────────────────────────────────────────

    address internal owner;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0x7EA5);
    address internal lpTreasury = address(0x1B7EA5);
    address internal keeper = address(0xCEE9E2);
    /// @dev Stands in for whoever creates the decoy. Not us, on purpose.
    address internal stranger = address(0x57A9E);

    uint256 internal forkId;

    // ─── Setup ────────────────────────────────────────────────────────────

    function setUp() public virtual {
        owner = address(this);
        forkId = vm.createSelectFork(_rpcUrl(), A.FORK_BLOCK);

        // The pin is load-bearing. Assert it in setUp so a moved pin fails
        // here, once, with a clear message — rather than as a confusing
        // arithmetic mismatch three tests later.
        assertEq(block.chainid, A.BSC_CHAIN_ID, "not BSC mainnet");
        assertEq(block.number, A.FORK_BLOCK, "fork did not land on the pinned block");
        assertEq(
            block.timestamp,
            A.FORK_TIMESTAMP,
            "pinned block timestamp moved: re-verify every specimen in ForkAddresses"
        );

        vm.label(A.WBNB, "WBNB");
        vm.label(A.PANCAKE_V2_ROUTER, "PancakeV2Router");
        vm.label(A.PANCAKE_V2_FACTORY, "PancakeV2Factory");
        vm.label(A.PANCAKE_V3_FACTORY, "PancakeV3Factory");
        vm.label(A.CHAINLINK_BNB_USD, "ChainlinkBNBUSD");
        vm.label(A.VRF_COORDINATOR_V2_5, "VRFCoordinatorV2_5");
        vm.label(A.FOUR_MEME_TOKEN_MANAGER, "four.meme:TokenManager2");
        vm.label(A.GORT, "four.meme:Gort");
        vm.label(A.BABYDOGE, "BabyDoge");
        vm.label(stranger, "stranger(decoy-creator)");
    }

    /// @dev `BSC_FORK_RPC_URL` first, because `RPC_URL` points at publicnode
    ///      in `.env.example` and publicnode refuses archive reads — a pinned
    ///      fork against it dies with HTTP 403 rather than a useful error.
    function _rpcUrl() internal view returns (string memory) {
        return vm.envOr("BSC_FORK_RPC_URL", string("https://bsc-mainnet.public.blastapi.io"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  four.meme helpers
    // ═══════════════════════════════════════════════════════════════════════

    struct CurveState {
        address quote;
        uint256 totalSupply;
        uint256 maxOffers;
        uint256 maxRaising;
        uint256 offers;
        uint256 funds;
        uint256 status;
    }

    /**
     * @dev Read `_tokenInfos` WORD BY WORD rather than as a 13-value tuple.
     *
     *      Two reasons, both real. The pad's struct definition is not public
     *      (`FOUR-MEME-LAUNCH-ROUTE §10`): the field layout below is a decode
     *      confirmed by observed state transitions, and field 2 in particular
     *      is an explicit guess this package never asserts on. Decoding by
     *      offset keeps that honest — and it sidesteps the stack-too-deep a
     *      13-way destructuring causes without `via_ir`, which this repo does
     *      not use.
     */
    function _curve(address token) internal view returns (CurveState memory c) {
        (bool ok, bytes memory data) = A.FOUR_MEME_TOKEN_MANAGER
            .staticcall(abi.encodeWithSelector(ITokenManager2Fork._tokenInfos.selector, token));
        require(ok && data.length >= 13 * 32, "four.meme: _tokenInfos shape changed");

        c.quote = address(uint160(_word(data, 1)));
        c.totalSupply = _word(data, 3);
        c.maxOffers = _word(data, 4);
        c.maxRaising = _word(data, 5);
        c.offers = _word(data, 7);
        c.funds = _word(data, 8);
        c.status = _word(data, 12);
    }

    function _word(bytes memory data, uint256 index) private pure returns (uint256 v) {
        assembly {
            v := mload(add(data, add(32, mul(index, 32))))
        }
    }

    /**
     * @notice Buy `grossBnb` worth of `token` on the four.meme curve as
     *         `buyer`, and return the **measured** balance delta.
     *
     * @dev `buyTokenAMAP` returns nothing (`FOUR-MEME-LAUNCH-ROUTE §3`), so a
     *      balance delta is the only honest answer. That is not a convenience
     *      here — it is the same discipline `BNB-CHAIN-FACTS §3` demands of
     *      every swap leg we own, exercised against a contract that gives us
     *      no choice.
     */
    function _curveBuy(address token, address buyer, uint256 grossBnb, uint256 minAmount)
        internal
        returns (uint256 received)
    {
        vm.deal(buyer, buyer.balance + grossBnb + 1 ether);
        uint256 before = IERC20Fork(token).balanceOf(buyer);
        vm.prank(buyer);
        fourMeme.buyTokenAMAP{ value: grossBnb }(token, grossBnb, minAmount);
        received = IERC20Fork(token).balanceOf(buyer) - before;
    }

    /**
     * @notice Fill a template-B four.meme curve to completion so the token
     *         graduates into a real PancakeSwap v2 pool.
     *
     * @dev This is how the package obtains a graduated, freely-transferable
     *      four.meme token — the closest thing to BNBULL that can exist
     *      today, given `DECISIONS.md §29` says BNBULL does not exist on
     *      mainnet and could not be moved if it did.
     *
     *      The gross-up is `FOUR-MEME-LAUNCH-ROUTE §3`'s measured split: you
     *      pay 111 to move the curve by 100 (90.0901% reaches the curve, the
     *      rest is founder fee + pad fee + referral). A generous cushion is
     *      sent because overpayment is refunded to the caller.
     */
    function _graduate(address token, address buyer) internal {
        CurveState memory c = _curve(token);
        require(c.status == 0, "specimen is not on a live curve at the pin");

        uint256 remaining = c.maxRaising - c.funds;
        // /0.900901 plus a wide cushion; the pad refunds the excess.
        uint256 gross = (remaining * 10_000) / 9_009 + 2 ether;

        _curveBuy(token, buyer, gross, 1);

        CurveState memory after_ = _curve(token);
        require(after_.status == 3, "curve did not complete (template A stalls at status 2)");
        require(IFourMemeTokenFork(token)._mode() == 0, "transfer gate did not lift");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PancakeSwap helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _pathWbnbTo(address token) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = A.WBNB;
        p[1] = token;
    }

    function _pathToWbnb(address token) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = token;
        p[1] = A.WBNB;
    }

    /// @notice The WBNB side of a v2 pair, in wei. THE number a
    ///         minimum-liquidity floor has to be denominated in — never the
    ///         token side, which a decoy can print for free
    ///         (`DECISIONS.md §22`).
    function _pairWbnbReserve(address pair) internal view returns (uint256) {
        if (pair == address(0)) return 0;
        (uint112 r0, uint112 r1,) = IPancakePairFork(pair).getReserves();
        return IPancakePairFork(pair).token0() == A.WBNB ? uint256(r0) : uint256(r1);
    }

    /// @notice Spot price implied by a v2 pair's reserves: token wei per 1e18
    ///         WBNB wei, with NO price impact. The honest reference a swap's
    ///         effective rate is compared against.
    function _spotTokenPerBnb(address pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPancakePairFork(pair).getReserves();
        (uint256 rWbnb, uint256 rTok) = IPancakePairFork(pair).token0() == A.WBNB
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        if (rWbnb == 0) return 0;
        return (rTok * 1e18) / rWbnb;
    }

    /// @dev Give `who` real WBNB by wrapping real BNB. Never `deal()` into
    ///      WBNB's storage — a forged balance is not a balance the pair's
    ///      `sync()` would ever agree with.
    function _giveWbnb(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        wbnb.deposit{ value: amount }();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Reporting
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Fork tests are evidence, not just assertions. When a number is the
    ///      point of the test, print it — the reader of the run log is the
    ///      person deciding whether to ship.
    function _log(string memory label, uint256 v) internal pure {
        console2.log(label, v);
    }

    receive() external payable { }
}
