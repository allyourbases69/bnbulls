// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {
    IERC20Fork,
    IPancakePairFork,
    INonfungiblePositionManagerFork,
    IQuoterV2Fork,
    IPancakeV3PoolFork
} from "./ForkInterfaces.sol";

import {Bulls} from "../../contracts/Bulls.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";

/**
 * @notice A plain, boring, 18-decimal ERC-20. It exists for ONE reason: to be
 *         the token in a pool whose DEPTH we control. Every other contract in
 *         these tests is live mainnet code; this one has to be ours because
 *         mainnet will not hand us a dust pool on request.
 *
 * @dev Deliberately featureless — no tax, no hooks, no owner. If the decoy
 *      tests fail, it must be impossible to blame the token.
 */
contract PlainToken {
    string public name = "Decoy Bull";
    string public symbol = "DBULL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 supply) {
        totalSupply = supply;
        balanceOf[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        emit Transfer(msg.sender, to, v);
        return true;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        emit Transfer(f, t, v);
        return true;
    }
}

/**
 * @title DecoyPoolForkTest
 * @notice ⚠⚠ THE HEADLINE FILE. `BNB-CHAIN-FACTS.md §3`, reproduced against
 *         live contracts, and then defended against.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  THE BUG THIS FILE EXISTS TO CATCH
 * ══════════════════════════════════════════════════════════════════════════
 *
 * On Stable a $50 dev buy was published as **$13.26** — a 4x understatement —
 * because the v2 factory's `getPair` answered with a decoy pair holding ~6.6k
 * while the real book was a v3 1% pool. The number went out publicly before
 * anyone caught it.
 *
 * **No mock can catch that class of bug.** A mock router quotes whatever it
 * was told; the failure is precisely that a REAL registry answers truthfully
 * about the WRONG pool. `test/Base.t.sol`'s `MockRouter` has one rate per
 * pair and no notion of a second venue, so the mock suite is structurally
 * blind here no matter how many tests it has.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHY IT IS WORSE ON BNB THAN IT WAS ON STABLE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * `DECISIONS.md §28.3`: four.meme graduates into PancakeSwap **v2** and
 * creates **no v3 pool at any tier**. So for a v3-routed leg the decoy is not
 * an unlucky outcome — it is the ONLY thing that can ever be there. Broccoli,
 * a real four.meme graduate, already carries three third-party v3 pools today
 * (asserted in `FourMeme.fork.t.sol`).
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  WHAT IS ASSERTED HERE
 * ══════════════════════════════════════════════════════════════════════════
 *
 *  1. The decoy is CHEAP and PERMISSIONLESS - a stranger builds it with
 *     0.01 BNB and no contract of their own.
 *  2. The loss is measured, not asserted from a doc: a real quote through the
 *     decoy against a real quote through the real book.
 *  3. `minOut` alone CANNOT save us, because the inline floor is quoted off
 *     the same book it is about to trade against. Demonstrated, not argued.
 *  4. `MintDrop.minPoolLiquidity` DOES save us: every dust and empty-pool
 *     shape defers and accrues instead of trading, and the mint still
 *     succeeds.
 */
contract DecoyPoolForkTest is ForkBase {
    INonfungiblePositionManagerFork internal constant npm =
        INonfungiblePositionManagerFork(A.PANCAKE_V3_NPM);
    IQuoterV2Fork internal constant quoter = IQuoterV2Fork(A.PANCAKE_V3_QUOTER_V2);

    Bulls internal bulls;
    Jackpot internal potBnbull;
    Jackpot internal potBnb;

    /// @dev The 10000-tier's tick spacing on BSC is 200 (verified by
    ///      `feeAmountTickSpacing`), so full range is +/-887200, not the raw
    ///      +/-887272 bound.
    int24 internal constant FULL_RANGE_LOWER = -887_200;
    int24 internal constant FULL_RANGE_UPPER = 887_200;

    function setUp() public override {
        super.setUp();
        bulls = new Bulls(owner, 0xB011, bytes32(0));
        potBnb = new Jackpot(A.WBNB, address(0), A.VRF_COORDINATOR_V2_5, 100);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE MEASUREMENT — a real decoy beside a real book
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠⚠ THE ONE. Graduate a real four.meme token so a real v2 book
     *         exists, let a STRANGER build a v3 decoy for 0.01 BNB, then quote
     *         1 BNB through both and measure the damage.
     *
     * @dev Every actor here is real: PancakeSwap's v3 factory, its
     *      NonfungiblePositionManager, its QuoterV2, its v2 router, and a
     *      four.meme token that graduated inside this transaction. The only
     *      thing the test supplies is the intent to grief, which costs one
     *      hundredth of a BNB and needs no contract.
     *
     *      The assertion is a RATIO, not a number: the absolute quote depends
     *      on the pin, but "the decoy is an order of magnitude worse" is the
     *      property, and it is what makes a naive `getPool` lookup a money
     *      bug rather than a rounding one.
     */
    function test_THE_DECOY_aStrangerBuildsA95xWorsePoolForOneHundredthOfABnb() public {
        // ── the honest book, created by four.meme's own graduation ────────
        _graduate(A.GORT, alice);
        address realPair = v2Factory.getPair(A.GORT, A.WBNB);
        uint256 realReserve = _pairWbnbReserve(realPair);
        assertGt(realReserve, 10 ether, "the real book is not where we thought");

        // ── before the stranger acts, a v3 leg finds NOTHING ──────────────
        uint24[4] memory tiers = [A.V3_FEE_100, A.V3_FEE_500, A.V3_FEE_2500, A.V3_FEE_10000];
        for (uint256 i = 0; i < tiers.length; i++) {
            assertEq(
                v3Factory.getPool(A.GORT, A.WBNB, tiers[i]),
                address(0),
                "four.meme created a v3 pool after all - re-read DECISIONS 28.3"
            );
        }

        // ── the decoy, built by someone who is not us, for 0.01 BNB ───────
        address decoy = _buildV3Decoy(realPair, 0.01 ether);
        assertEq(
            v3Factory.getPool(A.GORT, A.WBNB, A.V3_FEE_10000),
            decoy,
            "the v3 factory does not answer with the decoy"
        );

        // ── the measurement ───────────────────────────────────────────────
        uint256 realOut = v2Router.getAmountsOut(1 ether, _pathWbnbTo(A.GORT))[1];
        (uint256 decoyOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2Fork.QuoteExactInputSingleParams({
                tokenIn: A.WBNB,
                tokenOut: A.GORT,
                amountIn: 1 ether,
                fee: A.V3_FEE_10000,
                sqrtPriceLimitX96: 0
           })
        );

        console2.log("1 BNB through the REAL v2 book :", realOut);
        console2.log("1 BNB through the v3 DECOY     :", decoyOut);
        console2.log("decoy is worse by a factor of  :", realOut / (decoyOut == 0 ? 1 : decoyOut));
        console2.log("decoy cost the griefer (wei)   :", uint256(0.01 ether));

        assertGt(decoyOut, 0, "the decoy quotes nothing - it would fail loudly, not silently");
        assertLt(
            decoyOut * 20,
            realOut,
            "the decoy is not materially worse - re-check the seeding, not the finding"
        );
    }

    /**
     * @notice The decoy is not merely worse, it is UNDETECTABLE from inside
     *         the pool it lives in. Both venues answer confidently.
     *
     * @dev This is the reason a `minOut` floor cannot be the defence. A floor
     *      quoted off the pool being traded is a bound on slippage WITHIN that
     *      book — it says nothing about whether the book is the right one. A
     *      keeper pegging `minOut` at launch reads the decoy and pegs to the
     *      decoy, which is exactly what `DECISIONS.md §22` warns about.
     */
    function test_bothVenuesQuoteConfidentlyWhichIsWhyMinOutCannotBeTheDefence() public {
        _graduate(A.GORT, alice);
        address realPair = v2Factory.getPair(A.GORT, A.WBNB);
        _buildV3Decoy(realPair, 0.01 ether);

        (uint256 decoyOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2Fork.QuoteExactInputSingleParams({
                tokenIn: A.WBNB,
                tokenOut: A.GORT,
                amountIn: 1 ether,
                fee: A.V3_FEE_10000,
                sqrtPriceLimitX96: 0
           })
        );

        // A 5% slippage band around the decoy's OWN quote is satisfied by the
        // decoy's own execution. Nothing in that arithmetic can notice that
        // the answer is 95x wrong.
        uint256 naiveFloor = (decoyOut * 9_500) / 10_000;
        assertGt(naiveFloor, 0, "even a blind-swap guard would pass here");
        console2.log("a keeper pegging minOut here would peg it to:", naiveFloor);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE DEFENCE — MintDrop refuses every thin-book shape
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE `DECISIONS.md §22` GAP-3 SCENARIO, EXACTLY. A stranger
     *         pre-creates the WBNB/BNBULL v2 pair before graduation; the
     *         factory answers with it; our buy leg must NOT trade.
     *
     * @dev §22: *"anyone can create a dust WBNB/BNBULL pair before
     *      graduation, and a factory lookup answers with it."* Verified here
     *      with the real factory and a real four.meme token: `createPair` from
     *      a random EOA succeeds, the pair holds nothing (it CANNOT hold
     *      anything — seeding it reverts on the transfer gate), and the mint
     *      defers instead of trading.
     *
     *      This is the whole `DECISIONS.md §29` phase-1 posture, proven rather
     *      than assumed: BNBULL legs are present, they defer, and the money is
     *      visible in `pendingBnbullBuyNative` instead of quietly gone.
     */
    function test_aStrangerPreCreatedPairMakesTheBuyLegDeferNotTrade() public {
        // The stranger's whole attack, from an EOA, before graduation.
        vm.prank(stranger);
        address pair = v2Factory.createPair(A.GORT, A.WBNB);
        assertTrue(pair != address(0), "createPair is not permissionless after all");
        assertEq(_pairWbnbReserve(pair), 0, "the decoy pair somehow holds WBNB");

        // And it cannot be seeded, because the token is gated.
        uint256 held = IERC20Fork(A.GORT).balanceOf(A.GORT_HOLDER);
        vm.prank(A.GORT_HOLDER);
        vm.expectRevert(bytes("Token: Transfer is restricted"));
        IERC20Fork(A.GORT).transfer(pair, held);

        // Our code, pointed at exactly this state.
        MintDrop drop = _dropFor(A.GORT);
        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        assertEq(bulls.ownerOf(1), alice, "the mint failed - never-fail was violated");
        assertEq(
            drop.pendingBnbullBuyNative(),
            (bnbDue * 2_000) / 10_000,
            "the BNBULL slice did not accrue"
        );
        assertEq(IERC20Fork(A.GORT).balanceOf(address(potBnbull)), 0, "we traded against the decoy");
    }

    /**
     * @notice ⚠ THE SEEDED DUST POOL. A pair that DOES hold liquidity, just
     *         not enough — the shape that quotes a plausible number and takes
     *         your money anyway.
     *
     * @dev The empty-pair case above would fail loudly on `getAmountsOut`
     *      alone (a zero-reserve pair reverts `INSUFFICIENT_LIQUIDITY`). This
     *      one would NOT: the router quotes happily, the slippage band is
     *      satisfied, and the trade books as a success. Only
     *      `minPoolLiquidity` stops it.
     *
     *      The test measures what would have been lost, so the floor's value
     *      is a number rather than an opinion.
     */
    function test_THE_DECOY_aSeededDustPairQuotesHappilyAndIsStillRefused() public {
        (PlainToken tok, address pair) = _seedDustPair(0.01 ether, 1_000_000e18);

        // 1. The router is perfectly happy. `minOut` would be satisfied.
        uint256 quoted = v2Router.getAmountsOut(1 ether, _pathWbnbTo(address(tok)))[1];
        assertGt(quoted, 0, "the dust pair refuses to quote - wrong shape for this test");

        // 2. And the price it quotes is catastrophic against its OWN spot.
        uint256 spot = _spotTokenPerBnb(pair);
        console2.log("dust pool WBNB reserve (wei):", _pairWbnbReserve(pair));
        console2.log("spot rate (tok per BNB):", spot);
        console2.log("effective rate for 1 BNB:", quoted);
        assertLt(quoted * 50, spot, "the dust pool is not thin enough to be a decoy");

        // 3. Our code refuses it outright.
        MintDrop drop = _dropFor(address(tok));
        (address seenPair, uint256 seenReserve) = drop.wbnbPoolLiquidity();
        assertEq(seenPair, pair, "the floor is looking at a different pair");
        assertLt(seenReserve, drop.minPoolLiquidity(), "the dust pair is above our own floor");

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        assertEq(bulls.ownerOf(1), alice, "the mint failed - never-fail was violated");
        assertEq(
            drop.pendingBnbullBuyNative(), (bnbDue * 2_000) / 10_000, "the slice did not accrue"
        );
        assertEq(tok.balanceOf(address(potBnbull)), 0, "WE TRADED AGAINST THE DECOY");
        assertEq(tok.balanceOf(address(drop)), 0, "tokens arrived from somewhere");
    }

    /**
     * @notice The floor is DENOMINATED IN WBNB, and that is load-bearing: a
     *         decoy can print an unlimited token side for free.
     *
     * @dev `DECISIONS.md §22`: *"it must be denominated in WBNB (never in
     *      BNBULL, which a decoy can print)."* Here the decoy's token side is
     *      a trillion units against 0.01 WBNB. A floor written against the
     *      token reserve would wave it through; the WBNB floor does not.
     */
    function test_theFloorCannotBeFooledByPrintingTheTokenSide() public {
        (PlainToken tok, address pair) = _seedDustPair(0.01 ether, 1_000_000_000_000e18);

        assertGe(tok.balanceOf(pair), 1e30, "token side is not absurd enough to make the point");
        assertLt(_pairWbnbReserve(pair), 1 ether, "WBNB side is not dust");

        MintDrop drop = _dropFor(address(tok));
        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        assertEq(tok.balanceOf(address(potBnbull)), 0, "a printed token side defeated the floor");
        assertGt(drop.pendingBnbullBuyNative(), 0, "the slice did not accrue");
    }

    /**
     * @notice The floor is really consulted, in both directions: raise it
     *         above a genuinely deep real book and even that book is refused.
     *
     * @dev Without this, "the dust pool deferred" could just be the pool being
     *      unquotable for some unrelated reason. Here the SAME pool trades at
     *      one setting and defers at another, with nothing else changed.
     */
    function test_theFloorIsTheThingDoingTheWorkNotSomeIncidentalRevert() public {
        (PlainToken tok, address pair) = _seedDustPair(5 ether, 5_000_000e18);
        uint256 reserve = _pairWbnbReserve(pair);
        assertGt(reserve, 4 ether, "seeding did not land");

        MintDrop drop = _dropFor(address(tok));

        // Below the reserve: it trades.
        drop.setMinPoolLiquidity(reserve - 1);
        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);
        uint256 traded = tok.balanceOf(address(potBnbull));
        assertGt(traded, 0, "a pool above the floor did not trade");
        assertEq(drop.pendingBnbullBuyNative(), 0, "it deferred anyway");

        // Above the reserve: the same pool, the same block, refused.
        // (Re-read it: the trade above just added WBNB to the book, which is
        // itself a small reminder that a floor is measured, not remembered.)
        drop.setMinPoolLiquidity(_pairWbnbReserve(pair) + 1);
        (, uint256 bnbDue2,,) = drop.quote(1);
        vm.deal(bob, bnbDue2);
        vm.prank(bob);
        drop.mintWithBNB{ value: bnbDue2 }(bob, 1);
        assertEq(tok.balanceOf(address(potBnbull)), traded, "it traded above the floor");
        assertEq(drop.pendingBnbullBuyNative(), (bnbDue2 * 2_000) / 10_000, "it did not accrue");
    }

    /// @notice Zero is refused as a floor. "Turn the guard off" must not be a
    ///         one-transaction option for a compromised owner key.
    function test_theFloorCannotBeSetToZero() public {
        MintDrop drop = _dropFor(A.GORT);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.InvalidMinLiquidity.selector, uint256(0)));
        drop.setMinPoolLiquidity(0);
    }

    /**
     * @notice What is deferred is not lost: after the real book exists, the
     *         keeper sweeps the accrual into the pot at an honest floor.
     *
     * @dev This closes `DECISIONS.md §22`'s "the money silently accrues …
     *      and nobody notices, because nothing reverts". The accrual is a
     *      public number, it survives, and it converts.
     */
    function test_theDeferredCurvePhaseAccrualSweepsIntoTheRealBookLater() public {
        // Phase 1: no pool. Everything defers.
        MintDrop drop = _dropFor(A.GORT);
        drop.setKeeper(keeper);

        (, uint256 bnbDue,,) = drop.quote(1);
        vm.deal(alice, bnbDue);
        vm.prank(alice);
        drop.mintWithBNB{ value: bnbDue }(alice, 1);

        uint256 accrued = drop.pendingBnbullBuyNative();
        assertGt(accrued, 0, "nothing accrued during the curve phase");

        // Phase 2: the curve completes and a real book appears.
        _graduate(A.GORT, bob);
        assertGt(_pairWbnbReserve(v2Factory.getPair(A.GORT, A.WBNB)), 10 ether);

        // A taxed graduate needs a slippage band wider than its tax; see
        // `FeeOnTransfer.fork.t.sol` for why that is a launch decision.
        uint256 honest = v2Router.getAmountsOut(accrued, _pathWbnbTo(A.GORT))[1];
        vm.prank(keeper);
        uint256 funded =
            drop.sweepBnbullPot(MintDrop.PotSource.Native, accrued, (honest * 80) / 100);

        assertGt(funded, 0, "the sweep bought nothing");
        assertEq(drop.pendingBnbullBuyNative(), 0, "the accrual was not cleared");
        assertEq(
            IERC20Fork(A.GORT).balanceOf(address(potBnbull)),
            funded,
            "the pot was credited something other than the measured delta"
        );
        console2.log("curve-phase accrual (BNB wei):", accrued);
        console2.log("swept into the pot (token wei):", funded);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Fixtures
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A `MintDrop` wired to the REAL router and the REAL feed, with
    ///      `token` standing in for BNBULL.
    /// @dev A FRESH collection per drop: `Bulls.Wire.MintDrop` is a one-shot
    ///      bootstrap slot (correctly — the minter is not something to swap
    ///      out casually), so re-pointing an already-wired one is not allowed.
    function _dropFor(address token) internal returns (MintDrop drop) {
        bulls = new Bulls(owner, 0xB011, bytes32(0));
        potBnbull = new Jackpot(token, address(0), A.VRF_COORDINATOR_V2_5, 50);
        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: token,
                wbnb: A.WBNB,
                treasury: treasury,
                lpTreasury: lpTreasury
           })
        );
        // The drop now ships PAUSED; tests open it deliberately.
        drop.unpause();
        bulls.bootstrapWire(Bulls.Wire.MintDrop, address(drop));
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, A.CHAINLINK_BNB_USD);
        drop.bootstrapWire(MintDrop.Wire.Router, A.PANCAKE_V2_ROUTER);
        drop.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);
        drop.setPriceTiers(_launchTiers());
    }

    /// @dev Create a REAL v2 pair through the REAL router and seed it with
    ///      `wbnbAmount` of real WBNB. The stranger does it, not us.
    function _seedDustPair(uint256 wbnbAmount, uint256 tokenAmount)
        internal
        returns (PlainToken tok, address pair)
    {
        tok = new PlainToken(tokenAmount * 10);
        tok.transfer(stranger, tokenAmount);

        vm.deal(stranger, wbnbAmount + 1 ether);
        vm.startPrank(stranger);
        tok.approve(A.PANCAKE_V2_ROUTER, type(uint256).max);
        v2Router.addLiquidityETH{ value: wbnbAmount }(
            address(tok), tokenAmount, 0, 0, stranger, block.timestamp
        );
        vm.stopPrank();

        pair = v2Factory.getPair(address(tok), A.WBNB);
        require(pair != address(0), "seeding did not create a pair");
    }

    /**
     * @dev Build the v3 decoy at the 10000 tier, initialised at the REAL v2
     *      pool's own spot price, and seeded with `wbnbAmount`.
     *
     *      Initialising at the honest price is the point: the decoy is not
     *      mispriced, it is merely EMPTY. That is what makes it invisible to
     *      any check that looks at price rather than depth.
     */
    function _buildV3Decoy(address realPair, uint256 wbnbAmount) internal returns (address pool) {
        (uint112 r0, uint112 r1,) = IPancakePairFork(realPair).getReserves();
        (uint256 rWbnb, uint256 rTok) = IPancakePairFork(realPair).token0() == A.WBNB
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));

        // WBNB (0xbb4C..) sorts below Gort (0xe706..), so token0 = WBNB and
        // the pool price is "Gort wei per WBNB wei".
        require(A.WBNB < A.GORT, "token ordering assumption broke");
        uint160 sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(rTok, 1 << 192, rWbnb)));

        // Fund the stranger honestly: real WBNB, and Gort bought on the curve
        // and moved post-graduation.
        _giveWbnb(stranger, wbnbAmount);
        uint256 seedTok = Math.mulDiv(wbnbAmount, rTok, rWbnb) * 2;
        vm.prank(alice);
        IERC20Fork(A.GORT).transfer(stranger, seedTok);

        vm.startPrank(stranger);
        pool = npm.createAndInitializePoolIfNecessary(A.WBNB, A.GORT, A.V3_FEE_10000, sqrtPriceX96);
        IERC20Fork(A.WBNB).approve(A.PANCAKE_V3_NPM, type(uint256).max);
        IERC20Fork(A.GORT).approve(A.PANCAKE_V3_NPM, type(uint256).max);
        npm.mint(
            INonfungiblePositionManagerFork.MintParams({
                token0: A.WBNB,
                token1: A.GORT,
                fee: A.V3_FEE_10000,
                tickLower: FULL_RANGE_LOWER,
                tickUpper: FULL_RANGE_UPPER,
                amount0Desired: wbnbAmount,
                amount1Desired: seedTok,
                amount0Min: 0,
                amount1Min: 0,
                recipient: stranger,
                deadline: block.timestamp
           })
        );
        vm.stopPrank();

        require(IPancakeV3PoolFork(pool).liquidity() > 0, "decoy has no liquidity");
    }

    function _launchTiers() internal pure returns (MintDrop.PriceTier[] memory t) {
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({upToSold: 100, usdPrice: 10e18, bnbullPrice: 1_000e18});
        t[1] = MintDrop.PriceTier({upToSold: 200, usdPrice: 20e18, bnbullPrice: 2_000e18});
        t[2] = MintDrop.PriceTier({upToSold: 300, usdPrice: 35e18, bnbullPrice: 3_500e18});
        t[3] = MintDrop.PriceTier({upToSold: 400, usdPrice: 50e18, bnbullPrice: 5_000e18});
        t[4] = MintDrop.PriceTier({upToSold: 500, usdPrice: 75e18, bnbullPrice: 7_500e18});
    }
}
