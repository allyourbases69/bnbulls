// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FourMemeMock} from "../../contracts/testnet/FourMemeMock.sol";
import {MockBnbull} from "../../contracts/testnet/MockBnbull.sol";

/*
 ╔══════════════════════════════════════════════════════════════════════════╗
 ║  ⚠  TESTNET REHEARSAL RIG — chain 97. Nothing here is deployable to      ║
 ║     mainnet: both artefacts under test REVERT in their constructors on    ║
 ║     chain 56, and `test_mainnetDeploymentIsRefused` proves it.            ║
 ╚══════════════════════════════════════════════════════════════════════════╝
*/

interface IPancakeFactoryV2 {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
    function INIT_CODE_PAIR_HASH() external view returns (bytes32);
    function feeTo() external view returns (address);
}

interface IPancakeRouterV2 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakePairV2 {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function mint(address) external returns (uint256);
}

interface IWBNB9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/**
 * @title TestnetDexBase
 * @notice Stands up the **REAL** PancakeSwap v2 of BSC testnet (chain 97) —
 *         factory, router02 and WBNB — at their real addresses, and the two
 *         rehearsal artefacts on top of it.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      THE THREE ADDRESSES, AND HOW THEY WERE ESTABLISHED
 *      ══════════════════════════════════════════════════════════════════════
 *      Read live off `https://bsc-testnet-rpc.publicnode.com` (`eth_chainId`
 *      answered `97`) rather than copied out of a doc:
 *
 *        router.factory()  -> 0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc
 *        router.WETH()     -> 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd
 *        WBNB.symbol()     -> "WBNB",  WBNB.decimals() -> 18
 *        factory.INIT_CODE_PAIR_HASH() ->
 *            0xecba335299a6693cb2ebc4782e74669b84290b6378ea3a3873c7231a8d7d1074
 *
 *      That is the same discipline `FOUR-MEME-LAUNCH-ROUTE.md §1` used for
 *      mainnet: the factory is read OFF THE ROUTER, never looked up, so a
 *      router/factory mismatch cannot survive.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY THE BYTECODE IS COMMITTED, AND WHY THAT IS STILL "REAL"
 *      ══════════════════════════════════════════════════════════════════════
 *      `test/testnet/dexcode/*.runtime.hex` are the **verbatim runtime
 *      bytecodes** of those three live contracts, fetched with
 *      `cast code <addr> --rpc-url <chain-97 rpc>`. They are `vm.etch`ed back at
 *      their own addresses, so:
 *
 *        - the factory's `createPair` deploys the REAL PancakePair through the
 *          REAL CREATE2 + init-code-hash it carries in its own code. Nothing
 *          about the pair is written by us;
 *        - the router's `factory()` and `WETH()` are immutables baked into that
 *          bytecode and still answer with the real addresses — asserted in
 *          `test_realDexIsWiredToItself`, so a bad etch cannot pass silently;
 *        - `mint`, `getReserves`, `getAmountsOut`, `swapExactETHForTokens`,
 *          the `Pancake: K` invariant and the 1000-wei `MINIMUM_LIQUIDITY`
 *          burn are all the deployed implementations, not a re-implementation.
 *
 *      **This is not a simulated AMM.** It is the deployed one, executed
 *      locally, which means the whole lifecycle runs in a plain `forge test`
 *      with no RPC, no key and no faucet — and the numbers it produces are
 *      constant-product numbers, not numbers we chose.
 *
 *      Set `TESTNET_FORK=1` (with `RPC_URL_TESTNET`) to run the identical tests
 *      against a live chain-97 fork instead. The addresses are the same either
 *      way, so no test knows which mode it is in.
 *
 *      ⚠ ONE DIFFERENCE, STATED PLAINLY: `vm.etch` copies code, not storage.
 *      WBNB's `name`/`symbol`/`decimals` and the factory's `feeTo`/`feeToSetter`
 *      live in storage, so they are restored explicitly below from the values
 *      read on chain 97. Everything else — balances, pair registry — starts
 *      empty, which is what a rehearsal wants.
 */
abstract contract TestnetDexBase is Test {
    // ─── chain 97, verified live ──────────────────────────────────────────

    address internal constant V2_ROUTER = 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3;
    address internal constant V2_FACTORY = 0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc;
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    bytes32 internal constant INIT_CODE_PAIR_HASH =
        0xecba335299a6693cb2ebc4782e74669b84290b6378ea3a3873c7231a8d7d1074;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    /// @dev Read on chain 97 alongside the code, so the etched WBNB is not a
    ///      nameless 0-decimals husk.
    bytes32 private constant WBNB_SLOT0_NAME =
        0x5772617070656420424e42000000000000000000000000000000000000000016;
    bytes32 private constant WBNB_SLOT1_SYMBOL =
        0x57424e4200000000000000000000000000000000000000000000000000000008;
    address private constant FACTORY_FEE_TO = 0xE42C439D836708f43F77a65C198A2d7f55b3f3f4;
    address private constant FACTORY_FEE_TO_SETTER = 0x352a7a5277eC7619500b06fA051974621C1acd12;

    IPancakeFactoryV2 internal factory = IPancakeFactoryV2(V2_FACTORY);
    IPancakeRouterV2 internal router = IPancakeRouterV2(V2_ROUTER);
    IWBNB9 internal wbnb = IWBNB9(WBNB);

    // ─── Actors ───────────────────────────────────────────────────────────

    address internal padOwner = address(0xF00D);
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal griefer = address(0x6816F);
    address internal fourMemeOperator = address(0x0BE8A7);
    address internal padFeeRecipient = address(0xFEE5);
    address internal referralKeeper = address(0x8EF8);

    FourMemeMock internal pad;

    // ─── Launch shape ─────────────────────────────────────────────────────

    /// @notice 1e27 = 1,000,000,000 tokens at 18dp — the live shape §3 read off
    ///         Gort's `_tokenInfos`.
    uint256 internal constant SUPPLY_18DP = 1e27;
    /// @notice 80% on the curve, 20% to LP. §5 measured exactly that split.
    uint256 internal constant CURVE_SHARE_BPS = 8_000;

    // ══════════════════════════════════════════════════════════════════════
    //  Setup
    // ══════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        _standUpRealDex();
        pad = new FourMemeMock(
            padOwner, V2_FACTORY, V2_ROUTER, WBNB, padFeeRecipient, referralKeeper
        );
        vm.prank(padOwner);
        pad.grantDeployer(creator);
        vm.prank(padOwner);
        pad.grantOperator(fourMemeOperator);
    }

    /// @dev Either a live chain-97 fork or the etched real bytecode. Identical
    ///      addresses either way.
    function _standUpRealDex() internal {
        if (_forkRequested()) {
            vm.createSelectFork(vm.envString("RPC_URL_TESTNET"));
            require(block.chainid == 97, "TestnetDexBase: fork is not chain 97");
        } else {
            vm.etch(V2_FACTORY, vm.parseBytes(vm.readFile(_codePath("PancakeV2Factory"))));
            vm.etch(V2_ROUTER, vm.parseBytes(vm.readFile(_codePath("PancakeV2Router02"))));
            vm.etch(WBNB, vm.parseBytes(vm.readFile(_codePath("WBNB"))));

            // Storage `vm.etch` cannot carry, restored from the live reads.
            vm.store(WBNB, bytes32(uint256(0)), WBNB_SLOT0_NAME);
            vm.store(WBNB, bytes32(uint256(1)), WBNB_SLOT1_SYMBOL);
            vm.store(WBNB, bytes32(uint256(2)), bytes32(uint256(18)));
            vm.store(V2_FACTORY, bytes32(uint256(0)), bytes32(uint256(uint160(FACTORY_FEE_TO))));
            vm.store(
                V2_FACTORY, bytes32(uint256(1)), bytes32(uint256(uint160(FACTORY_FEE_TO_SETTER)))
            );

            // The rehearsal is a chain-97 rehearsal. Say so on chain.
            vm.chainId(97);
            // The router's `ensure(deadline)` compares against `block.timestamp`
            // and the pair packs it into a uint32; a realistic clock keeps both
            // honest and keeps `block.timestamp` deadlines meaningful.
            vm.warp(1_780_000_000);
        }
    }

    function _forkRequested() private view returns (bool) {
        if (!vm.envOr("TESTNET_FORK", false)) return false;
        return bytes(vm.envOr("RPC_URL_TESTNET", string(""))).length != 0;
    }

    function _codePath(string memory n) private pure returns (string memory) {
        return string.concat("test/testnet/dexcode/", n, ".runtime.hex");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Launch helpers
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The default rehearsal token: template B, atomic graduation, **tax
    ///      OFF and `feeRateBuy = 0`** — the `§9.4` "best of both" target.
    ///      `maxRaising` is a parameter so a whole lifecycle fits in one buy.
    function _launchDefault(uint256 maxRaising) internal returns (MockBnbull) {
        return _launch(
            FourMemeMock.LaunchParams({
                name: "BNBull",
                symbol: "BNBULL",
                decimals: 18,
                totalSupply: SUPPLY_18DP,
                maxOffers: (SUPPLY_18DP * CURVE_SHARE_BPS) / 10_000,
                maxRaising: maxRaising,
                quote: address(0),
                founder: creator,
                feeRateBuy: 0,
                feeRateSell: 0,
                rateFounder: 100,
                taxEnabled: false,
                atomicGraduation: true
            })
        );
    }

    function _launch(FourMemeMock.LaunchParams memory p) internal returns (MockBnbull) {
        vm.prank(creator);
        return MockBnbull(pad.launch(p));
    }

    /// @dev Buy on the curve as `who`, measuring the amount out as a
    ///      `balanceOf` DELTA — the only honest way, because `buyTokenAMAP`
    ///      returns nothing (§3).
    function _curveBuy(MockBnbull token, address who, uint256 gross, uint256 minOut)
        internal
        returns (uint256 delivered)
    {
        vm.deal(who, who.balance + gross);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        pad.buyTokenAMAP{value: gross}(address(token), gross, minOut);
        delivered = token.balanceOf(who) - before;
    }

    /// @dev Fill the curve and graduate. Overpays deliberately: the pad caps the
    ///      curve amount at the threshold and refunds the rest.
    function _graduate(MockBnbull token) internal {
        uint256 need = pad.maxRaisingOf(address(token));
        _curveBuy(token, alice, need * 3, 0);
        assertEq(pad.statusOf(address(token)), pad.STATUS_COMPLETED(), "did not graduate");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Pool reads
    // ══════════════════════════════════════════════════════════════════════

    function _pair(address token) internal view returns (address) {
        return factory.getPair(token, WBNB);
    }

    /// @notice Reserves of a pair, always returned as (token side, WBNB side).
    function _reserves(address token) internal view returns (uint256 tokenSide, uint256 wbnbSide) {
        address p = _pair(token);
        if (p == address(0)) return (0, 0);
        (uint112 r0, uint112 r1,) = IPancakePairV2(p).getReserves();
        return IPancakePairV2(p).token0() == token ? (r0, r1) : (r1, r0);
    }

    /**
     * @notice The minimum-liquidity floor, **denominated in WBNB**, as
     *         `DECISIONS.md §28` / route `§9.2` specify it.
     *
     * @dev ⚠⚠ THIS IS THE INTENDED BEHAVIOUR, IMPLEMENTED HERE BECAUSE THE
     *      CONTRACT-SIDE FLOOR DOES NOT EXIST YET. A grep of `contracts/` for
     *      `minPoolLiquidity` returns nothing as of this writing; another agent
     *      is adding it. When it lands, the tests in `DecoyPoolFloor.t.sol`
     *      should be retargeted at the real getter and this helper deleted.
     *
     *      Two rules it encodes, both from `§9.2`:
     *        - the floor is denominated in **WBNB**, never in BNBULL, because a
     *          decoy can print BNBULL freely and cannot print WBNB;
     *        - "under the floor" means **defer and accrue**, never "trade anyway
     *          with a bigger slippage tolerance".
     */
    function _passesLiquidityFloor(address token, uint256 minWbnbReserve)
        internal
        view
        returns (bool)
    {
        address p = _pair(token);
        if (p == address(0)) return false;
        (uint256 tokenSide, uint256 wbnbSide) = _reserves(token);
        if (tokenSide == 0) return false;
        return wbnbSide >= minWbnbReserve;
    }

    /// @notice A v2 quote for `bnbIn` through the real router. Reverts if the
    ///         pool cannot quote — which is itself a finding.
    function _quoteBnbIn(address token, uint256 bnbIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        return router.getAmountsOut(bnbIn, path)[1];
    }

    /// @dev Wrap and hand `to` some real WBNB.
    function _giveWbnb(address to, uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        wbnb.deposit{value: amount}();
        wbnb.transfer(to, amount);
    }

    receive() external payable {}
}
