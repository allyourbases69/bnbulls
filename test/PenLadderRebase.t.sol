// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LadderRebase} from "../script/lib/LadderRebase.sol";
import {MintDrop} from "../contracts/MintDrop.sol";

/**
 * @title PenLadderRebaseTest
 * @notice The one arithmetic in the BullPen migration that costs real money
 *         when it is wrong, and costs it silently.
 *
 * @dev A replacement `MintDrop` starts `totalSold = 0`, so a ladder copied
 *      across verbatim restarts at rung one. With 31 bulls already gone that
 *      sells about thirty extra bulls at $10 which should have been $20, and
 *      nothing reverts, nothing logs, and the buyers keep their bulls.
 *
 *      These tests exist so that failure has to get past an assertion rather
 *      than past somebody remembering.
 */
/// @dev `LadderRebase.rebase` is `internal`, so it is inlined into the caller
///      and `vm.expectRevert` cannot see it at a lower call depth. This gives
///      the two refusal cases a real external frame to revert in.
contract RebaseHarness {
    function rebase(MintDrop.PriceTier[] memory live, uint256 minted, uint16 lastMustCover)
        external
        pure
        returns (MintDrop.PriceTier[] memory)
    {
        return LadderRebase.rebase(live, minted, lastMustCover);
    }
}

contract PenLadderRebaseTest is Test {
    uint16 internal constant MAX_MINT = 500;

    RebaseHarness internal harness = new RebaseHarness();

    /// @dev `DECISIONS.md §12`, and the table live on chain today. The BNBULL
    ///      column is zero pre-graduation, which is the correct live value.
    function _launchLadder() internal pure returns (MintDrop.PriceTier[] memory t) {
        t = new MintDrop.PriceTier[](5);
        t[0] = MintDrop.PriceTier({upToSold: 100, usdPrice: 10e18, bnbullPrice: 0});
        t[1] = MintDrop.PriceTier({upToSold: 200, usdPrice: 20e18, bnbullPrice: 0});
        t[2] = MintDrop.PriceTier({upToSold: 300, usdPrice: 35e18, bnbullPrice: 0});
        t[3] = MintDrop.PriceTier({upToSold: 400, usdPrice: 50e18, bnbullPrice: 0});
        t[4] = MintDrop.PriceTier({upToSold: 500, usdPrice: 75e18, bnbullPrice: 0});
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE BUG, DEMONSTRATED FIRST
    // ══════════════════════════════════════════════════════════════════════

    /// @notice With the live state (31 minted), an UN-rebased ladder sells 69
    ///         more bulls at $10 than it should. This is the number the whole
    ///         exercise is about.
    function test_anUnrebasedLadderReRunsTheTenDollarRung() public pure {
        MintDrop.PriceTier[] memory live = _launchLadder();
        uint256 minted = 31;

        // What a verbatim copy would do: rung one covers sales 1..100 on the
        // NEW contract, i.e. 100 more $10 bulls.
        uint256 tenDollarBullsIfCopied = live[0].upToSold;
        // What is actually left of that rung.
        uint256 tenDollarBullsRemaining = live[0].upToSold - minted;

        assertEq(tenDollarBullsIfCopied, 100, "a verbatim copy re-runs the whole rung");
        assertEq(tenDollarBullsRemaining, 69, "only 69 of the $10 rung are left");
        assertEq(
            tenDollarBullsIfCopied - tenDollarBullsRemaining,
            31,
            "31 bulls would sell at $10 that should sell at $20"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE REBASE
    // ══════════════════════════════════════════════════════════════════════

    function test_boundariesMoveDownByWhatIsAlreadyMinted() public pure {
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(_launchLadder(), 31, MAX_MINT);

        assertEq(out.length, 5, "no rung is spent yet at 31 minted");
        assertEq(out[0].upToSold, 69, "$10 rung: 100 - 31");
        assertEq(out[1].upToSold, 169, "$20 rung: 200 - 31");
        assertEq(out[2].upToSold, 269, "$35 rung: 300 - 31");
        assertEq(out[3].upToSold, 369, "$50 rung: 400 - 31");
    }

    /// @notice ⚠ The dollar column is the thing that must NOT move. A rebase
    ///         that shifts a price is a re-pricing nobody approved.
    function test_theDollarStickersAreUntouched() public pure {
        MintDrop.PriceTier[] memory live = _launchLadder();
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(live, 31, MAX_MINT);
        for (uint256 i = 0; i < out.length; i++) {
            assertEq(out[i].usdPrice, live[i].usdPrice, "a dollar sticker moved");
        }
    }

    /**
     * @notice `setPriceTiers` REVERTS unless the last rung reaches `MAX_MINT`,
     *         so the final boundary is raised rather than clamped to what is
     *         actually left.
     * @dev The obvious rebase gives 469 as the last boundary, and 469 is
     *      refused: `InvalidTiers`. Worse, a table that stopped there and was
     *      somehow accepted would leave mints 470..500 UNPRICED — there is no
     *      flat-price fallback, so `priceForMint` reverts `NotPriced` and the
     *      tail of the drop becomes unsellable.
     */
    function test_theLastRungIsRaisedToMaxMintNotToWhatRemains() public pure {
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(_launchLadder(), 31, MAX_MINT);
        assertEq(out[4].upToSold, MAX_MINT, "the last rung must cover MAX_MINT");
        assertTrue(out[4].upToSold != 469, "469 would revert InvalidTiers");
    }

    /// @notice The rebased table has to be one `setPriceTiers` would accept:
    ///         strictly ascending, and reaching MAX_MINT.
    function test_theRebasedTableSatisfiesSetPriceTiers() public pure {
        for (uint256 minted = 0; minted < 500; minted += 7) {
            MintDrop.PriceTier[] memory out = LadderRebase.rebase(_launchLadder(), minted, MAX_MINT);
            for (uint256 i = 1; i < out.length; i++) {
                assertGt(
                    out[i].upToSold, out[i - 1].upToSold, "boundaries must be strictly ascending"
                );
            }
            assertGe(out[out.length - 1].upToSold, MAX_MINT, "last rung must reach MAX_MINT");
        }
    }

    /// @notice A rung already fully spent is DROPPED, not emitted as a zero.
    function test_aFullySpentRungIsDropped() public pure {
        // 150 minted: the $10 rung (boundary 100) is gone entirely.
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(_launchLadder(), 150, MAX_MINT);
        assertEq(out.length, 4, "the $10 rung is gone");
        assertEq(out[0].usdPrice, 20e18, "the cheapest rung left is $20");
        assertEq(out[0].upToSold, 50, "200 - 150");
    }

    /// @notice The exact boundary case: minted lands ON a rung boundary, so
    ///         that rung is spent to the last bull and must not survive as a
    ///         zero-width rung (which `setPriceTiers` would reject anyway).
    function test_mintedExactlyOnABoundaryDropsThatRung() public pure {
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(_launchLadder(), 100, MAX_MINT);
        assertEq(out.length, 4, "the $10 rung is exactly spent");
        assertEq(out[0].usdPrice, 20e18);
        assertEq(out[0].upToSold, 100, "200 - 100");
    }

    /// @notice Nothing minted is the identity. A migration on a fresh
    ///         collection must not quietly change the ladder.
    function test_zeroMintedIsTheIdentity() public pure {
        MintDrop.PriceTier[] memory live = _launchLadder();
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(live, 0, MAX_MINT);
        assertEq(out.length, live.length);
        for (uint256 i = 0; i < out.length; i++) {
            assertEq(out[i].upToSold, live[i].upToSold, "an untouched ladder moved");
            assertEq(out[i].usdPrice, live[i].usdPrice);
        }
    }

    /// @notice A sold-out collection has nothing to rebase, and says so rather
    ///         than emitting a table that prices nothing.
    function test_aFullySoldLadderRefusesRatherThanEmittingNonsense() public {
        vm.expectRevert(abi.encodeWithSelector(LadderRebase.EveryRungSpent.selector, uint256(500)));
        harness.rebase(_launchLadder(), 500, MAX_MINT);
    }

    function test_anEmptyLadderRefuses() public {
        MintDrop.PriceTier[] memory none = new MintDrop.PriceTier[](0);
        vm.expectRevert(LadderRebase.NoTiers.selector);
        harness.rebase(none, 0, MAX_MINT);
    }

    /// @notice The BNBULL column is carried across untouched. Pre-graduation it
    ///         is zero on chain, and zero is what "this leg is not priced yet"
    ///         means — the rebase must not invent a peg. This is the column
    ///         `Wire.s.sol` derives from env, which is the 1,250x leak.
    function test_theBnbullColumnIsCarriedNotDerived() public pure {
        MintDrop.PriceTier[] memory live = _launchLadder();
        live[0].bnbullPrice = 1234;
        MintDrop.PriceTier[] memory out = LadderRebase.rebase(live, 31, MAX_MINT);
        assertEq(out[0].bnbullPrice, 1234, "the BNBULL peg must be carried verbatim");
        assertEq(out[1].bnbullPrice, 0, "and a zero peg must stay zero");
    }
}
