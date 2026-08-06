// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {MintBnbullSplitter} from "../contracts/MintBnbullSplitter.sol";
import {ReviveBuySplitter} from "../contracts/ReviveBuySplitter.sol";
import {SplitterV2Router} from "./mocks/SplitterMocks.sol";

/**
 * @title SplitterBase
 * @notice Shared harness for `lib/PotSplitter.sol`, `MintBnbullSplitter` and
 *         `ReviveBuySplitter` — and, because it already owns the router and the
 *         two pots, for the marketplace's jackpot-fee sink too.
 *
 * @dev ⚠ NO MAINNET FORK ANYWHERE IN THIS SUITE, DELIBERATELY. Same reasoning
 *      as `Base.t.sol`: nothing is deployed on chain 56, and the failure modes
 *      being proved here (a lying router, a dead pool, a dust pair, a pot that
 *      has not granted the funder role, a keeper that stopped publishing
 *      floors) cannot be summoned on demand against a live PancakeSwap. This
 *      EXTENDS `Base.t.sol` rather than standing up a parallel world: the same
 *      Bulls, MintDrop, Jackpots, MockWBNB, MockERC20s and the same $600 /
 *      $0.01 economic frame.
 *
 *      ⚠ THIS HARNESS USED TO STAND UP A **v3** ROUTER. `DECISIONS.md §28`
 *      killed that: four.meme graduates into PancakeSwap **v2** and creates no
 *      v3 pool at any tier, so the only thing a v3 leg could ever have found is
 *      somebody else's decoy — measured at 95x worse. `dex` is a v2 router now.
 *      It is still separate from `MockRouter` because it carries hostile modes
 *      the other suites do not want.
 */
abstract contract SplitterBase is BnbullsBase {
    // ─── The v2 route the splitters trade on ──────────────────────────────

    SplitterV2Router internal dex;

    // ─── Contracts under test ─────────────────────────────────────────────

    MintBnbullSplitter internal mintSplit;
    ReviveBuySplitter internal reviveSplit;

    // ─── Market rates, at the harness's $600 BNB / $0.01 BNBULL / $1 stable ─

    /// @notice BNBULL wei out per 1e18 BNB in.
    uint256 internal constant RATE_BNBULL_PER_BNB = 60_000e18;
    /// @notice WBNB wei out per ONE WHOLE BNBULL unit in — `1e18 / 60_000`,
    ///         spelled out because a `constant` expression in Solidity is exact
    ///         rational arithmetic.
    uint256 internal constant RATE_WBNB_PER_BNBULL = 16_666_666_666_666;

    /// @dev The keeper publishes floors 1% under the market, the way a real
    ///      price-keeper leaves room for ordinary drift between two blocks.
    uint256 internal constant FLOOR_BNBULL_PER_BNB = (RATE_BNBULL_PER_BNB * 99) / 100;
    uint256 internal constant FLOOR_WBNB_PER_BNBULL = (RATE_WBNB_PER_BNBULL * 99) / 100;

    // ─── Setup ────────────────────────────────────────────────────────────

    function setUp() public virtual override {
        super.setUp();

        dex = new SplitterV2Router(address(wbnb));
        _setDexRates();
        _fundDex();

        mintSplit = new MintBnbullSplitter(owner, address(wbnb), keeper);
        reviveSplit = new ReviveBuySplitter(owner, address(wbnb), keeper);

        _wireSplitter(mintSplit, address(drop));
        _wireSplitter(reviveSplit, address(drop));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _setDexRates() internal {
        dex.setRate(address(wbnb), address(bnbull), 60_000, 1);
        dex.setRate(address(bnbull), address(wbnb), 1, 60_000);
    }

    function _fundDex() internal {
        bnbull.mint(address(dex), 1e30);
        vm.deal(address(this), address(this).balance + 1e24);
        wbnb.deposit{value: 1e24}();
        wbnb.transfer(address(dex), 1e24);
    }

    /**
     * @dev Wire a splitter the way deploy day does: `bootstrapWire` is
     *      immediate while a slot is still zero, and timelocked forever after.
     * @param policy What to put in the live-policy slot. ZERO leaves it
     *        unwired, so the splitter runs on its own `fallback*` shares —
     *        which is exactly how the marketplace's 100%-BNBULL sink is set up.
     */
    function _wireSplitter(PotSplitter s, address policy) internal {
        s.bootstrapWire(PotSplitter.Wire.Bnbull, address(bnbull));
        s.bootstrapWire(PotSplitter.Wire.Router, address(dex));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnbull, address(potBnbull));
        s.bootstrapWire(PotSplitter.Wire.JackpotBnb, address(potBnb));
        if (policy != address(0)) s.bootstrapWire(PotSplitter.Wire.MintDrop, policy);

        potBnbull.setFunder(address(s), true);
        potBnb.setFunder(address(s), true);

        _publishFloors(s);
    }

    /// @dev The keeper's two rates, written together under one timestamp — a
    ///      partial refresh would leave one leg authorised by the other leg's
    ///      freshness.
    function _publishFloors(PotSplitter s) internal {
        vm.prank(keeper);
        s.setFloors(FLOOR_BNBULL_PER_BNB, FLOOR_WBNB_PER_BNBULL);
    }

    /// @dev A splitter with nothing wired at all — the pre-launch state, where
    ///      the pots, the token and the router may not exist yet.
    function _bareMintSplitter() internal returns (MintBnbullSplitter s) {
        s = new MintBnbullSplitter(owner, address(wbnb), keeper);
    }

    function _bareReviveSplitter() internal returns (ReviveBuySplitter s) {
        s = new ReviveBuySplitter(owner, address(wbnb), keeper);
    }

    // ─── Expected swap outputs at the harness rates ───────────────────────

    function _bnbullFromBnb(uint256 bnb) internal pure returns (uint256) {
        return (bnb * 60_000);
    }

    function _giveSplitterBnbull(address to, address splitter_, uint256 amount) internal {
        bnbull.mint(to, amount);
        vm.prank(to);
        bnbull.approve(splitter_, type(uint256).max);
    }
}
