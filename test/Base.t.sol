// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {MockDuel} from "./mocks/Hostile.sol";

/**
 * @title BnbullsBase
 * @notice Shared harness for the bnbulls contract suite.
 *
 * @dev ⚠ NO MAINNET FORK ANYWHERE IN THIS SUITE, DELIBERATELY.
 *      `BNB-CHAIN-FACTS.md` tags most BSC addresses `⚠ VERIFY`, and nothing is
 *      deployed on chain 56 yet. A fork E2E — both pots funding from both
 *      payment currencies against the real PancakeSwap router, the real
 *      Chainlink BNB/USD feed and the real VRF coordinator — is a LATER SLICE,
 *      and it is the only thing that can prove the live wiring. Everything here
 *      is mocks, and the mocks are driven into failure modes a fork could not
 *      reproduce on demand.
 *
 *      ⚠ `DECISIONS.md §26` dropped the stablecoin. There are TWO payment
 *      currencies now, BNB and BNBULL, and the decimals discipline that used to
 *      be rehearsed against a 6dp payment token now rides on BNBULL — which is
 *      the one that genuinely cannot be checked in advance, because four.meme
 *      issues it. `_deployAll(bnbullDecimals_)` takes that as its parameter for
 *      exactly that reason; see `MarketplaceDecimals.t.sol`.
 *
 *      Economic frame used throughout, so the arithmetic in each test reads:
 *        BNB/USD  = $600            (feed, 8 decimals)
 *        BNBULL   = $0.01           (so the $10 rung pegs at 1,000 BNBULL)
 */
abstract contract BnbullsBase is Test {
    // ─── Actors ───────────────────────────────────────────────────────────

    address internal owner;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal treasury = address(0x7EA5);
    address internal lpTreasury = address(0x1B7EA5);
    address internal keeper = address(0xCEE9E2);

    // ─── Deployment ───────────────────────────────────────────────────────

    uint256 internal constant SEED = 0xB011;

    MockERC20 internal bnbull;
    MockWBNB internal wbnb;
    MockAggregator internal feed;
    MockRouter internal router;
    MockVRFCoordinator internal coord;

    Bulls internal bulls;
    Jackpot internal potBnbull;
    Jackpot internal potBnb;
    MintDrop internal drop;
    MockDuel internal duel;

    // ─── Economic constants used by the expectations ──────────────────────

    /// @notice $600 with the feed's 8 decimals.
    int256 internal constant BNB_USD_8 = 600e8;
    /// @notice $600, 1e18-scaled — what `bnbUsdPrice()` must return.
    uint256 internal constant BNB_USD_1E18 = 600e18;
    /// @notice BNBULL per BNB at $600 / $0.01.
    uint256 internal constant BNBULL_PER_BNB = 60_000;

    bytes32 internal constant KEY_HASH =
        0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;

    // ─── Setup ────────────────────────────────────────────────────────────

    /// @param bnbullDecimals_ BNBULL's `decimals()`. A PARAMETER, never an
    ///        assumption — four.meme issues the token (`DECISIONS.md §4`), so
    ///        "BEP-20s are usually 18" is not evidence, and every contract
    ///        reads it off the wire rather than hardcoding a divisor.
    function _deployAll(uint8 bnbullDecimals_) internal {
        owner = address(this);

        bnbull = new MockERC20("BNBull", "BNBULL", bnbullDecimals_);
        wbnb = new MockWBNB();
        feed = new MockAggregator(8, BNB_USD_8);
        router = new MockRouter(address(wbnb));
        coord = new MockVRFCoordinator();
        duel = new MockDuel();

        bulls = new Bulls(owner, SEED, bytes32(0));

        potBnbull = new Jackpot(address(bnbull), address(0), address(coord), 50);
        potBnb = new Jackpot(address(wbnb), address(0), address(coord), 100);

        drop = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );

        bulls.bootstrapWire(Bulls.Wire.MintDrop, address(drop));

        potBnbull.setFunder(address(drop), true);
        potBnb.setFunder(address(drop), true);
        potBnbull.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);
        potBnb.setVrfConfig(KEY_HASH, 1, 3, 200_000, true);

        _setRouterRates();
        _fundRouter();
    }

    function setUp() public virtual {
        _deployAll(18);
        _wireDrop();
        _setLaunchTiers();
    }

    /// @dev Every money-moving slot on MintDrop, wired via `bootstrapWire`
    ///      (immediate while the slot is zero — deploy day is not a two-day job).
    function _wireDrop() internal {
        drop.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        drop.bootstrapWire(MintDrop.Wire.Router, address(router));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        drop.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        drop.setKeeper(keeper);
    }

    function _setRouterRates() internal {
        // 1 BNB ($600) buys 60,000 BNBULL ($0.01 each).
        router.setRate(address(wbnb), address(bnbull), BNBULL_PER_BNB, 1);
        // 1 BNBULL ($0.01) buys 1/60,000 WBNB.
        router.setRate(address(bnbull), address(wbnb), 1, BNBULL_PER_BNB);
    }

    function _fundRouter() internal {
        bnbull.mint(address(router), 1e30);
        vm.deal(address(this), address(this).balance + 1e24);
        wbnb.deposit{value: 1e24}();
        wbnb.transfer(address(router), 1e24);
    }

    /// @notice `DECISIONS.md §12`: 100 -> $10, 200 -> $20, 300 -> $35,
    ///         400 -> $50, 500 -> $75.
    /// @dev The BNBULL column is the keeper's peg of the **FULL, UNDISCOUNTED**
    ///      sticker (`$0.01` a token). MintDrop takes the 10% off — see the
    ///      double-discount trap in its header.
    function _setLaunchTiers() internal {
        MintDrop.PriceTier[] memory t = _launchTiers();
        drop.setPriceTiers(t);
    }

    /// @dev The BNBULL column is DERIVED from `bnbull.decimals()`, never
    ///      written as an `e18` literal. That is the whole decimals discipline
    ///      in one line: at 18dp the $10 rung is 1_000e18 exactly as before, at
    ///      6dp it is 1_000e6, and no test has to know which world it is in.
    function _launchTiers() internal view returns (MintDrop.PriceTier[] memory t) {
        uint256 unit = 10 ** bnbull.decimals();
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({
            upToSold: 100,
            usdPrice: 10e18,
            bnbullPrice: uint128(1_000 * unit)
        });
        t[1] = MintDrop.PriceTier({
            upToSold: 200,
            usdPrice: 20e18,
            bnbullPrice: uint128(2_000 * unit)
        });
        t[2] = MintDrop.PriceTier({
            upToSold: 300,
            usdPrice: 35e18,
            bnbullPrice: uint128(3_500 * unit)
        });
        t[3] = MintDrop.PriceTier({
            upToSold: 400,
            usdPrice: 50e18,
            bnbullPrice: uint128(5_000 * unit)
        });
        t[4] = MintDrop.PriceTier({
            upToSold: 500,
            usdPrice: 75e18,
            bnbullPrice: uint128(7_500 * unit)
        });
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev BNB owed for a given (already-discounted) dollar amount.
    function _bnbFor(uint256 usd1e18, uint256 price1e18) internal pure returns (uint256) {
        return _ceilDiv(usd1e18 * 1e18, price1e18);
    }

    function _giveBnbull(address to, uint256 amount) internal {
        bnbull.mint(to, amount);
        vm.prank(to);
        bnbull.approve(address(drop), type(uint256).max);
    }

    /// @dev Sell `count` bulls for BNB to `who`, generously overpaying so the
    ///      refund path is exercised on every call.
    function _mintBnb(address who, uint256 count) internal returns (uint256 spent) {
        (, uint256 bnbDue,,) = drop.quote(count);
        vm.deal(who, who.balance + bnbDue * 2 + 1 ether);
        uint256 before = who.balance;
        vm.prank(who);
        drop.mintWithBNB{value: bnbDue * 2}(who, count);
        spent = before - who.balance;
    }

    receive() external payable {}
}
