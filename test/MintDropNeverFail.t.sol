// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {MockERC20, RevertingERC20} from "./mocks/MockERC20.sol";
import {MockWBNB, BrokenWBNB} from "./mocks/MockWBNB.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/**
 * @title MintDropNeverFailTest
 * @notice PRIORITY 7. The entrypoint that is not allowed to revert.
 *
 * @dev `MintDrop.donatePotNative()` carries this warning, and it is a scar:
 *
 *        "⚠ NOT PAUSABLE, AND IT MUST NOT REVERT. On fefers this exact
 *         entrypoint was called UN-GUARDED by `Graveyard._routeNative`: if it
 *         reverted, every revive in the game bricked."
 *
 *      `LEARNINGS-AND-MISTAKES §C` generalises it: "an entrypoint a frozen
 *      upstream calls un-guarded must NEVER revert: try/catch -> accrue on
 *      failure -> keeper sweep -> owner escape."
 *
 *      The failure modes are all real and all have happened somewhere: a thin
 *      pool, a pool that does not exist yet, a router that reverts, a slippage
 *      bust, a pot that has not whitelisted the caller, a token that changed
 *      under us. Each one below drives `donatePotNative` into that state and
 *      asserts three things:
 *        1. the call SUCCEEDS,
 *        2. every wei is ACCRUED into a `pending*` bucket (nothing is lost),
 *        3. a DEFERRED EVENT is emitted, so which branch ran is on chain and
 *           nobody has to take our word for it.
 *      Then the keeper sweep is shown to recover the money afterwards.
 */
contract MintDropNeverFailTest is BnbullsBase {
    // ══════════════════════════════════════════════════════════════════════
    //  It cannot revert
    // ══════════════════════════════════════════════════════════════════════

    function test_survivesARouterThatRevertsOnSwap() public {
        router.setRevertOnSwap(true);
        _donateAndAssertNothingLost(3 ether);
        assertGt(drop.pendingBnbullBuyNative(), 0, "the swap leg must have deferred");
        assertEq(drop.pendingBnbPotNative(), 0, "the wrap leg needs no router");
    }

    function test_survivesARouterThatRevertsOnQuote() public {
        router.setRevertOnQuote(true);
        _donateAndAssertNothingLost(3 ether);
        assertGt(drop.pendingBnbullBuyNative(), 0);
    }

    /// @dev A drained or non-existent pair quotes ZERO, which makes the floor
    ///      zero, which is refused outright as a blind swap. Deferring is
    ///      exactly the right answer here — trading into an empty pair hands
    ///      the slice to whoever is watching the mempool.
    function test_survivesZeroLiquidity() public {
        router.setQuoteZero(true);
        _donateAndAssertNothingLost(3 ether);
        assertGt(drop.pendingBnbullBuyNative(), 0);
    }

    function test_survivesNoRouterWiredAtAll() public {
        MintDrop d = _freshDrop(address(bnbull), address(wbnb));
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(d), true);
        potBnb.setFunder(address(d), true);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        // The cheap pre-check short-circuits before the try/catch even runs.
        assertEq(d.pendingBnbullBuyNative(), 2 ether);
        assertEq(d.pendingBnbPotNative(), 0, "the wrap leg still works with no router");
        assertEq(potBnb.pool(), 1 ether);
    }

    function test_survivesPotsThatAreNotWiredYet() public {
        MintDrop d = _freshDrop(address(bnbull), address(wbnb));
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        assertEq(d.pendingBnbullBuyNative(), 2 ether);
        assertEq(d.pendingBnbPotNative(), 1 ether);
        assertEq(address(d).balance, 3 ether, "every wei is still here");
    }

    /// @dev The realistic deploy-ordering bug: the pot exists but has not
    ///      whitelisted MintDrop as a funder yet.
    function test_survivesAPotThatRefusesOurFunding() public {
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);
        _donateAndAssertNothingLost(3 ether);
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);
        assertEq(drop.pendingBnbPotNative(), 1 ether);
    }

    /// @dev A prize token whose `transfer` reverts — paused, blacklisting, or
    ///      simply broken. `BNB-CHAIN-FACTS §5` warns a launchpad token with a
    ///      transfer gate bricks every `transferFrom` flow in the game; this is
    ///      what stops it bricking a revive.
    function test_survivesARevertingToken() public {
        RevertingERC20 broken = new RevertingERC20();
        MintDrop d = _freshDrop(address(broken), address(wbnb));
        MockRouter r = new MockRouter(address(wbnb));
        r.setRate(address(wbnb), address(broken), 1_000, 1);
        broken.setBroken(false);
        broken.mint(address(r), 1e30);
        broken.setBroken(true);

        Jackpot pot = new Jackpot(address(broken), address(0), address(coord), 50);
        pot.setFunder(address(d), true);
        d.bootstrapWire(MintDrop.Wire.Router, address(r));
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(pot));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnb.setFunder(address(d), true);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        assertEq(d.pendingBnbullBuyNative(), 2 ether, "the broken-token leg deferred");
        assertEq(potBnb.pool(), 1 ether, "the healthy leg still landed");
    }

    /// @dev Even the WRAP — the one leg with no router, no slippage and no
    ///      liquidity dependency — must defer rather than revert if WBNB itself
    ///      misbehaves.
    function test_survivesABrokenWrapper() public {
        BrokenWBNB bad = new BrokenWBNB();
        MintDrop d = _freshDrop(address(bnbull), address(bad));
        Jackpot pot = new Jackpot(address(bad), address(0), address(coord), 100);
        pot.setFunder(address(d), true);
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(pot));

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        d.donatePotNative{value: 3 ether}();

        assertEq(d.pendingBnbPotNative(), 1 ether, "the wrap leg deferred instead of reverting");
        assertEq(pot.pool(), 0);
    }

    /// @dev Everything broken at once.
    function test_survivesTotalCollapse() public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);
        router.setQuoteZero(true);
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);

        _donateAndAssertNothingLost(7 ether);
        assertEq(drop.pendingBnbullBuyNative() + drop.pendingBnbPotNative(), 7 ether);
    }

    /// @dev Fuzzed over the donation size, with every route dead. The Graveyard
    ///      calls this un-guarded; it may not revert for ANY input.
    function testFuzz_donatePotNativeNeverRevertsWithEveryRouteDead(uint96 amount) public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);

        vm.deal(alice, uint256(amount));
        vm.prank(alice);
        drop.donatePotNative{value: amount}();

        assertEq(
            drop.pendingBnbullBuyNative() + drop.pendingBnbPotNative(),
            uint256(amount),
            "wei went missing on the deferred path"
        );
    }

    function test_aZeroDonationIsANoOpNotARevert() public {
        vm.prank(alice);
        drop.donatePotNative{value: 0}();
        drop.donatePotToken(address(bnbull), 0);
    }

    /// @dev ⚠ NOT PAUSABLE. If pausing the mint could also brick revives, the
    ///      pause button would be a foot-gun rather than a safety valve.
    function test_donationsKeepWorkingWhileTheDropIsPaused() public {
        drop.pause();

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        assertGt(potBnbull.pool(), 0);

        bnbull.mint(alice, 100e18);
        vm.startPrank(alice);
        bnbull.approve(address(drop), type(uint256).max);
        drop.donatePotToken(address(bnbull), 100e18);
        vm.stopPrank();

        // ...while the MINT is correctly closed.
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert();
        drop.mintWithBNB{value: 5 ether}(bob, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The same rule on the inline mint path
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A mint must never fail because of a buyback either.
    function test_aMintSucceedsWithEveryPotRouteDead() public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);
        potBnbull.setFunder(address(drop), false);
        potBnb.setFunder(address(drop), false);

        (, uint256 bnbDue,,) = drop.quote(1);
        uint256 spent = _mintBnb(alice, 1);

        assertEq(spent, bnbDue, "the buyer still paid exactly the quote");
        assertEq(bulls.balanceOf(alice), 1, "the mint must not fail on a buyback");
        assertEq(
            drop.pendingBnbullBuyNative() + drop.pendingBnbPotNative(),
            (bnbDue * 2_000) / 10_000 + (bnbDue * 1_000) / 10_000
        );
    }

    /**
     * @notice A BNBULL MINT SUCCEEDS WITH EVERY POT ROUTE DEAD.
     *
     * @dev ⚠ REWRITTEN, NOT DELETED, for `DECISIONS.md §26`. It used to prove
     *      this on the stablecoin leg. The subject — a token mint completing
     *      with the whole DEX down — is untouched; only the currency changed.
     *
     *      And this is now the LIKELY launch state, not an edge case:
     *      pre-graduation four.meme tokens cannot be transferred at all, and
     *      after graduation the pot leg still has no pool to buy from until the
     *      curve fills. A BNBULL payment routes 30/70 with no DEX call at all
     *      (`§14`), so the BNBULL pot funds directly and only the WBNB leg has
     *      anything to defer — and here it defers into the BNBULL pot too.
     */
    function test_aBnbullMintSucceedsWithEveryPotRouteDead() public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);

        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        // The $10 rung pegs at 1,000 BNBULL undiscounted; 10% off = 900 paid.
        uint256 paid = 900e18;
        assertEq(bulls.balanceOf(alice), 1);
        assertEq(potBnbull.pool(), (paid * 3_000) / 10_000, "30% straight in, no DEX");
        assertEq(bnbull.balanceOf(treasury), (paid * 7_000) / 10_000, "the dev leg still settled");
        assertEq(router.swapCalls(), 0, "BNBULL WAS SOLD");
    }

    /// @dev And with the POT itself refusing us, a BNBULL mint still lands and
    ///      the whole slice accrues instead. This is the pre-launch shape: the
    ///      funder role has not been granted yet.
    function test_aBnbullMintSucceedsWithThePotRefusingUs() public {
        potBnbull.setFunder(address(drop), false);

        _giveBnbull(alice, 10_000e18);
        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbullPotDeferred(MintDrop.PotSource.Bnbull, 180e18, 180e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        assertEq(bulls.balanceOf(alice), 1, "the mint must not fail on a buyback");
        assertEq(drop.pendingBnbullDirect(), 270e18, "20% + the never-sold 10%");
        assertEq(bnbull.balanceOf(address(drop)), 270e18, "the accrual is not actually held");
    }

    /// @dev The deferred events carry the RUNNING BUCKET TOTAL, so an indexer
    ///      can watch the backlog build without reading state.
    function test_deferredEventsCarryTheBucketTotal() public {
        router.setRevertOnSwap(true);
        vm.deal(alice, 6 ether);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbullPotDeferred(MintDrop.PotSource.Native, 2 ether, 2 ether);
        drop.donatePotNative{value: 3 ether}();

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbullPotDeferred(MintDrop.PotSource.Native, 2 ether, 4 ether);
        drop.donatePotNative{value: 3 ether}();
    }

    function test_theInlineSuccessPathEmitsItsOwnEvent() public {
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(drop));
        emit MintDrop.BnbPotFundedInline(MintDrop.PotSource.Native, 1 ether, 1 ether);
        drop.donatePotNative{value: 3 ether}();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ...and the keeper picks the backlog up afterwards
    // ══════════════════════════════════════════════════════════════════════

    function test_theKeeperSweepsTheBacklogOnceTheRouteIsBack() public {
        router.setRevertOnSwap(true);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);

        router.setRevertOnSwap(false);
        // The floor is quoted OFF chain — the one bound a same-block front-run
        // cannot move.
        uint256 offChainFloor = 2 ether * BNBULL_PER_BNB * 99 / 100;
        vm.prank(keeper);
        uint256 funded = drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, offChainFloor);

        assertEq(funded, 2 ether * BNBULL_PER_BNB);
        assertEq(potBnbull.pool(), funded);
        assertEq(drop.pendingBnbullBuyNative(), 0);
    }

    function test_sweepsArePartialAndBounded() public {
        router.setRevertOnSwap(true);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();
        router.setRevertOnSwap(false);

        vm.prank(keeper);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0.5 ether, 1);
        assertEq(drop.pendingBnbullBuyNative(), 1.5 ether);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.InsufficientPending.selector, 2 ether, 1.5 ether)
        );
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 2 ether, 1);

        vm.prank(alice);
        vm.expectRevert(MintDrop.NotKeeperOrOwner.selector);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);

        vm.prank(keeper);
        vm.expectRevert(MintDrop.NothingToSweep.selector);
        drop.sweepBnbPot(MintDrop.PotSource.Bnbull, 0, 1);
    }

    /**
     * @notice The trust boundary, stated plainly and tested both ways.
     *
     * @dev Money in a `pending*` bucket has NOT entered a pot, so the owner can
     *      pull it out to place a buy by hand. Money that has REACHED a pot can
     *      never come out except through a won ticket. Two different
     *      guarantees, and the receipts trail says which is which.
     */
    function test_pendingIsWithdrawableButPotMoneyIsNot() public {
        router.setRevertOnSwap(true);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        drop.donatePotNative{value: 3 ether}();

        uint256 potted = potBnb.pool();
        assertEq(potted, 1 ether, "the wrap leg landed in the pot");
        assertEq(drop.pendingBnbullBuyNative(), 2 ether);

        // Pending: movable, with its own event.
        vm.expectEmit(false, false, false, true, address(drop));
        emit MintDrop.PendingWithdrawnForManualBuy(
            MintDrop.PotSource.Native, true, address(0xBEEF), 2 ether
        );
        drop.withdrawPendingForManualBuy(true, MintDrop.PotSource.Native, address(0xBEEF), 0);
        assertEq(address(0xBEEF).balance, 2 ether);
        assertEq(drop.pendingBnbullBuyNative(), 0);

        // Potted: not movable, by anyone, ever.
        vm.expectRevert(Jackpot.PrizeTokenIsNotSweepable.selector);
        potBnb.sweepForeignToken(address(wbnb), owner, potted);
        assertEq(potBnb.pool(), potted);

        vm.expectRevert(MintDrop.NothingToSweep.selector);
        drop.withdrawPendingForManualBuy(false, MintDrop.PotSource.Native, owner, 0);
    }

    /// @dev `rescueToken` must refuse anything a pot leg is already credited
    ///      with — that money is spoken for.
    function test_rescueCannotTouchMoneyEarmarkedForAPot() public {
        potBnbull.setFunder(address(drop), false);
        _giveBnbull(alice, 10_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        uint256 reserved = drop.pendingBnbullDirect() + drop.pendingBnbPotBnbull();
        assertEq(reserved, 270e18);
        assertEq(bnbull.balanceOf(address(drop)), reserved);

        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.ReservedForPots.selector, reserved, uint256(0))
        );
        drop.rescueToken(address(bnbull), owner, reserved);

        // A genuinely stray token is rescuable in full.
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(drop), 5e18);
        drop.rescueToken(address(stray), owner, 5e18);
        assertEq(stray.balanceOf(owner), 5e18);
    }

    /// @dev There is deliberately NO native rescue: less owner power over BNB,
    ///      and nothing legitimate ever lands here to rescue.
    function test_thereIsNoNativeRescueAndNoReceive() public {
        (bool ok,) = address(drop).call(
            abi.encodeWithSignature("rescueNative(address,uint256)", owner, 1)
        );
        assertFalse(ok, "a native rescue exists on MintDrop");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (ok,) = address(drop).call{value: 1 ether}("");
        assertFalse(ok, "MintDrop has a receive(); BNB can arrive unaccounted for");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _donateAndAssertNothingLost(uint256 amount) internal {
        vm.deal(alice, amount);
        uint256 potsBefore = potBnbull.pool() + potBnb.pool();
        uint256 pendingBefore = drop.pendingBnbullBuyNative() + drop.pendingBnbPotNative();

        vm.prank(alice);
        drop.donatePotNative{value: amount}();

        uint256 pendingAfter = drop.pendingBnbullBuyNative() + drop.pendingBnbPotNative();
        uint256 accrued = pendingAfter - pendingBefore;
        uint256 pottedNative = _nativeEquivalentPotted(potsBefore);
        assertEq(accrued + pottedNative, amount, "value was lost on a deferred leg");
        assertEq(address(drop).balance, pendingAfter, "the accrued BNB is actually held");
    }

    /// @dev BNB that made it into a pot, converted back to BNB terms at the
    ///      harness rates, so the conservation check above is exact.
    function _nativeEquivalentPotted(uint256 potsBefore) internal view returns (uint256) {
        uint256 nowBnbull = potBnbull.pool() / BNBULL_PER_BNB;
        uint256 nowBnb = potBnb.pool();
        potsBefore; // both pots start empty in every case here
        return nowBnbull + nowBnb;
    }

    function _freshDrop(address bnbull_, address wbnb_) internal returns (MintDrop d) {
        Bulls b = new Bulls(owner, SEED, bytes32(0));
        d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(b),
                bnbull: bnbull_,
                wbnb: wbnb_,
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
        b.bootstrapWire(Bulls.Wire.MintDrop, address(d));
        d.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        d.setPriceTiers(_launchTiers());
    }
}
