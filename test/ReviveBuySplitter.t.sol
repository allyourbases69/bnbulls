// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SplitterBase} from "./SplitterBase.t.sol";
import {PotSplitter} from "../contracts/lib/PotSplitter.sol";
import {ReviveBuySplitter} from "../contracts/ReviveBuySplitter.sol";
import {SplitterFrozenCaller} from "./mocks/SplitterMocks.sol";

/**
 * @title ReviveBuySplitterTest
 * @notice The revive-path splitter: **100% of what arrives goes to the pots**,
 *         divided in the live `bnbullShareBps : bnbShareBps` ratio (2:1 at
 *         launch), because the caller has ALREADY taken its dev cut. That is
 *         what makes a revive land at `DECISIONS.md §13`'s 20/10/70 end to end
 *         rather than 20/10 of 30%.
 *
 * @dev ⚠ MOCKS ONLY, NO MAINNET FORK. See `SplitterBase.t.sol`.
 *
 *      The end-to-end composition is asserted here arithmetically rather than
 *      by driving the real `Graveyard`, so this suite stays independent of the
 *      Graveyard suite: the Graveyard's contribution to the invariant is
 *      exactly "keep 70%, donate 30%", and that is modelled directly.
 */
contract ReviveBuySplitterTest is SplitterBase {
    // ══════════════════════════════════════════════════════════════════════
    //  100% to the pots, in the live 2:1 ratio
    // ══════════════════════════════════════════════════════════════════════

    function test_aNativeDonationGoesEntirelyToThePotsInTheLiveRatio() public {
        _donate(6 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(4 ether), "2/3 of the donation");
        assertEq(potBnb.pool(), 2 ether, "1/3 of the donation");
        assertEq(address(reviveSplit).balance, 0, "this splitter keeps NOTHING");
        assertEq(reviveSplit.freeOf(PotSplitter.PotSource.Native), 0);
    }

    /**
     * @notice The end-to-end invariant: Graveyard keeps 70% and donates 30%;
     *         this splitter divides that 30% two-to-one; the result is exactly
     *         `DECISIONS.md §13`'s 20% BNBULL / 10% BNB / 70% dev.
     */
    function test_aReviveLands20_10_70EndToEnd() public {
        uint256 revivePrice = 10 ether;
        uint256 devCut = (revivePrice * 7_000) / 10_000; // what the Graveyard keeps
        uint256 donation = revivePrice - devCut;

        _donate(donation);

        assertEq(devCut, 7 ether, "70% dev");
        assertEq(potBnbull.pool(), _bnbullFromBnb(2 ether), "20% of the ORIGINAL price");
        assertEq(potBnb.pool(), 1 ether, "10% of the ORIGINAL price");
    }

    /// @dev `DECISIONS.md §14`: a BNBULL donation is never sold, so all of it
    ///      goes to the BNBULL pot and no DEX is touched.
    function test_aBnbullDonationIsNeverSold() public {
        _giveSplitterBnbull(alice, address(reviveSplit), 1_000e18);
        vm.prank(alice);
        reviveSplit.donatePotToken(address(bnbull), 30e18);

        assertEq(potBnbull.pool(), 30e18, "ALL of it");
        assertEq(potBnb.pool(), 0);
        assertEq(dex.swapCalls(), 0, "NOT ONE SWAP");
    }

    function test_aBnbullDonationSplitsOnceTheOwnerTurnsSellingOn() public {
        drop.setBnbullPaymentSellPolicy(true);

        _giveSplitterBnbull(alice, address(reviveSplit), 1_000e18);
        vm.prank(alice);
        reviveSplit.donatePotToken(address(bnbull), 30e18);

        assertEq(potBnbull.pool(), 20e18);
        assertEq(potBnb.pool(), uint256(10e18) / 60_000);
    }

    /// @dev The ratio is read LIVE off MintDrop, so retuning the house split is
    ///      one transaction on one contract.
    function test_theRatioFollowsMintDropWithNoTransactionHere() public {
        drop.setPotShares(3_000, 1_000); // 3:1
        _donate(8 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(6 ether));
        assertEq(potBnb.pool(), 2 ether);
    }

    /// @dev Pots disabled entirely: it all goes to the BNBULL leg rather than
    ///      dividing by zero or silently vanishing. Matches
    ///      `MintDrop._potSplit`.
    function test_withBothSharesZeroEverythingGoesToTheBnbullLeg() public {
        drop.setPotShares(0, 0);
        _donate(6 ether);

        assertEq(potBnbull.pool(), _bnbullFromBnb(6 ether));
        assertEq(potBnb.pool(), 0);
    }

    /// @dev `toBnb = amount - toBnbull`, so the division can never strand a wei.
    function testFuzz_everyWeiOfADonationIsAccountedFor(uint96 amount) public {
        vm.assume(amount > 0);
        dex.setRevertOnSwap(true);
        potBnb.setFunder(address(reviveSplit), false);

        vm.deal(alice, uint256(amount));
        vm.prank(alice);
        reviveSplit.donatePotNative{value: amount}();

        assertEq(
            reviveSplit.pendingBnbullBuyNative() + reviveSplit.pendingBnbPotNative(),
            uint256(amount),
            "a donation must be 100% pot money, to the wei"
        );
        assertEq(reviveSplit.freeOf(PotSplitter.PotSource.Native), 0, "nothing is ever retained");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The entrypoints the Graveyard calls
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice On fefers the Graveyard called `donateJackpotBuy{value}()` on its
     *         `mintDrop` slot with NO try/catch. If that reverted, every revive
     *         in the game — owner ladder and takeover alike — was bricked for
     *         every token, forever, on a contract nobody could patch. These are
     *         the same two selectors, so the slot just repoints.
     */
    function test_bothGraveyardSelectorsExistAndAreNeverFail() public {
        SplitterFrozenCaller frozen = new SplitterFrozenCaller();
        dex.setRevertOnSwap(true);
        potBnbull.setFunder(address(reviveSplit), false);
        potBnb.setFunder(address(reviveSplit), false);

        vm.deal(address(frozen), 6 ether);
        frozen.pushWithSelector(
            payable(address(reviveSplit)), abi.encodeWithSignature("donatePotNative()"), 6 ether
        );
        assertEq(reviveSplit.pendingBnbullBuyNative(), 4 ether);

        // The token selector, with a missing allowance — the failure a revive
        // must not die on.
        bnbull.mint(address(frozen), 100e18);
        frozen.pushWithSelector(
            payable(address(reviveSplit)),
            abi.encodeWithSignature("donatePotToken(address,uint256)", address(bnbull), 30e18),
            0
        );
        assertEq(bnbull.balanceOf(address(frozen)), 100e18, "the caller kept its money");
    }

    /// @dev A bare value transfer with no calldata is treated as a donation
    ///      rather than sitting as untracked residue.
    function test_bareValueTransfersAreTreatedAsADonation() public {
        vm.deal(alice, 6 ether);
        vm.prank(alice);
        (bool ok,) = address(reviveSplit).call{value: 6 ether}("");
        assertTrue(ok);
        assertEq(potBnbull.pool(), _bnbullFromBnb(4 ether));
        assertEq(potBnb.pool(), 2 ether);
    }

    function test_donatePotTokenMeasuresThePull() public {
        _giveSplitterBnbull(alice, address(reviveSplit), 1_000e18);
        uint256 before = bnbull.balanceOf(alice);
        vm.prank(alice);
        reviveSplit.donatePotToken(address(bnbull), 30e18);
        assertEq(before - bnbull.balanceOf(alice), 30e18, "exactly what was asked for");
    }

    function test_aDeferredDonationIsStillOneHundredPercentPotMoney() public {
        dex.setQuoteZero(true); // launch day: no BNBULL pair
        _donate(6 ether);

        assertEq(reviveSplit.pendingBnbullBuyNative(), 4 ether);
        assertEq(potBnb.pool(), 2 ether, "the wrap leg never needed a pool");
        assertEq(
            reviveSplit.freeOf(PotSplitter.PotSource.Native),
            0,
            "a deferral must not quietly become a dev share"
        );

        // ...and the keeper turns it into BNBULL once the pair exists.
        dex.setQuoteZero(false);
        vm.prank(keeper);
        uint256 funded = reviveSplit.sweepBnbullPot(
            PotSplitter.PotSource.Native, 0, (_bnbullFromBnb(4 ether) * 99) / 100
        );
        assertEq(funded, _bnbullFromBnb(4 ether));
        assertEq(address(reviveSplit).balance, 0, "and the splitter is empty again");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _donate(uint256 amount) internal {
        vm.deal(alice, alice.balance + amount);
        vm.prank(alice);
        reviveSplit.donatePotNative{value: amount}();
    }
}
