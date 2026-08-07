// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Jackpot} from "../contracts/Jackpot.sol";
import {Bulls} from "../contracts/Bulls.sol";

/**
 * @title MoneyLayerE2ETest
 * @notice The whole drop sold out across all three payment currencies, both
 *         pots funded from each of them, and both pots paying out.
 *
 * @dev ⚠ THIS IS THE MOCKED E2E, NOT THE FORK E2E. `BUILD-PLAN.md §B` asks for
 *      "a **bsc-fork E2E** proving both pots fund from every payment currency,
 *      both pots fire, and a mint/revive survives a broken or absent buyback
 *      pool". Two of those three are proved here against mocks; the third —
 *      that the LIVE PancakeSwap router, the LIVE Chainlink BNB/USD feed and
 *      the LIVE VRF coordinator behave as assumed — cannot be, because:
 *
 *        - nothing is deployed on chain 56 yet (`MintDrop.Wire`
 *          documents the slot as blank in `.env.example` on purpose),
 *        - nothing is deployed on chain 56 yet, and
 *        - `BNB-CHAIN-FACTS.md` still tags the verify flow, the block time, the
 *          getLogs cap and the v3 quoter `⚠ VERIFY`.
 *
 *      SO THE FORK E2E IS A LATER SLICE and it is not optional: it is the only
 *      thing that can catch the decoy-pool class of error (`§B`: "$FEFER's real
 *      liquidity was a v3 1% pool; the v2 factory's `getPair` returned a DECOY
 *      holding ~6.6k, and pricing a $50 buy through it reported $13.26"). A
 *      mock router quotes whatever it is told to.
 */
contract MoneyLayerE2ETest is BnbullsBase {
    function setUp() public override {
        super.setUp();
        potBnbull.bootstrapDuel(address(duel));
        potBnb.bootstrapDuel(address(duel));
    }

    /**
     * @dev Search for a VRF word that makes ticket `id` a WINNER on `pot`.
     *      Mirrors `Jackpot.resolve`'s preimage exactly, `address(this)` term
     *      and all.
     *
     *      ⚠ REPLACES `setOdds(1)`, which was the old "make every ticket win"
     *      shortcut and is now correctly refused by `MIN_ODDS_ONE_IN` — odds of
     *      one is a certain win for every possible word. Searching the word
     *      leaves the pots on the shipped 1-in-50 / 1-in-100 of `DECISIONS §13`,
     *      which this file asserts elsewhere.
     */
    function _wordThatWins(
        address pot,
        uint256 entropy,
        uint256 tokenId,
        address winner,
        uint256 id,
        uint256 odds
    ) internal pure returns (uint256) {
        for (uint256 word = 1; word < 100_000; word++) {
            uint256 roll =
                uint256(keccak256(abi.encodePacked(word, entropy, tokenId, winner, id, pot))) % odds;
            if (roll == 0) return word;
        }
        revert("no winning word found");
    }

    /**
     * @notice Sell all 500 bulls — 300 for BNB, 100 for BNBULL, 100 for BNB
     *         again — and check both pots grew from every currency that is
     *         supposed to feed them.
     *
     * @dev `DECISIONS.md §26` left TWO currencies, so the middle 100 that used
     *      to be a stablecoin run are BNB now. What that block is really
     *      testing is unchanged: a full sell-out with nothing stranded and
     *      nothing deferred.
     */
    function test_theWholeDropSellsOutAndBothPotsFundFromEveryCurrency() public {
        // ── 1. 200 bulls for BNB (the $10 and $20 rungs) ──────────────────
        for (uint256 i = 0; i < 10; i++) {
            _mintBnb(alice, 20);
        }
        assertEq(drop.totalSold(), 200);
        uint256 bnbullAfterNative = potBnbull.pool();
        uint256 bnbAfterNative = potBnb.pool();
        assertGt(bnbullAfterNative, 0, "BNB payments did not feed the BNBULL pot");
        assertGt(bnbAfterNative, 0, "BNB payments did not feed the WBNB pot");

        // ── 2. 100 more for BNB (the $35 rung) ────────────────────────────
        for (uint256 i = 0; i < 5; i++) {
            _mintBnb(bob, 20);
        }
        assertEq(drop.totalSold(), 300);
        assertGt(potBnbull.pool(), bnbullAfterNative, "the dearer rung did not feed BNBULL");
        assertGt(potBnb.pool(), bnbAfterNative, "the dearer rung did not feed the WBNB pot");
        uint256 bnbullBeforeBull = potBnbull.pool();
        uint256 bnbBeforeBull = potBnb.pool();

        // ── 3. 100 bulls for BNBULL (the $50 rung) ────────────────────────
        // 100 x 5,000 BNBULL sticker, less the 10% discount.
        _giveBnbull(carol, 1_000_000e18);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(carol);
            drop.mintWithBNBULL(carol, 20);
        }
        assertEq(drop.totalSold(), 400);
        assertGt(potBnbull.pool(), bnbullBeforeBull, "BNBULL payments did not feed BNBULL");
        assertEq(
            potBnb.pool(),
            bnbBeforeBull,
            "a BNBULL payment fed the WBNB pot - the game sold BNBULL"
        );

        // ── 4. the last 100, back in BNB (the $75 rung) ───────────────────
        for (uint256 i = 0; i < 5; i++) {
            _mintBnb(alice, 20);
        }
        assertEq(drop.totalSold(), 500);
        assertEq(bulls.nextTokenId(), 501);

        // ── 5. Nothing is stranded and nothing was deferred ───────────────
        assertEq(drop.pendingBnbullBuyNative(), 0);
        assertEq(drop.pendingBnbullDirect(), 0);
        assertEq(drop.pendingBnbPotNative(), 0);
        assertEq(drop.pendingBnbPotBnbull(), 0);
        assertEq(address(drop).balance, 0);
        assertEq(bnbull.balanceOf(address(drop)), 0);

        // ── 6. The drop is closed ─────────────────────────────────────────
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(MintDrop.SupplyExhausted.selector);
        drop.mintWithBNB{value: 50 ether}(alice, 1);
    }

    /// @notice The dollar side of the same run: $19,000 of stickers, 30% of it
    ///         into the two pots and 70% to dev, in whatever currency it
    ///         arrived in.
    function test_theDevTakeIsSeventyPercentOfEveryCurrency() public {
        // BNB: 70% of what the oracle charged for 20 x $10.
        (, uint256 bnbDue,,) = drop.quote(20);
        uint256 treasuryBefore = treasury.balance;
        _mintBnb(bob, 20);
        // ⚠ `_routeNative` takes the two pot slices and gives dev the REMAINDER,
        // so this is `amount - 20% - 10%` and not `amount - 30%`: the two differ
        // by a wei of rounding, and the remainder is what guarantees no wei is
        // ever lost.
        uint256 potA = (bnbDue * 2_000) / 10_000;
        uint256 potB = (bnbDue * 1_000) / 10_000;
        assertEq(treasury.balance - treasuryBefore, bnbDue - potA - potB);

        // BNBULL: 70% of the DISCOUNTED payment.
        _giveBnbull(carol, 1_000_000e18);
        vm.prank(carol);
        drop.mintWithBNBULL(carol, 20); // 20 x $10 sticker, -10%
        uint256 paid = (20 * 1_000e18 * 9_000) / 10_000;
        assertEq(bnbull.balanceOf(treasury), (paid * 7_000) / 10_000);
    }

    /**
     * @notice Both pots, funded by real mints, then actually paying out to duel
     *         winners — the full loop the product describes.
     */
    function test_bothPotsFundFromMintsAndThenPayOut() public {
        for (uint256 i = 0; i < 5; i++) {
            _mintBnb(alice, 20);
        }
        uint256 bnbullPot = potBnbull.pool();
        uint256 bnbPot = potBnb.pool();
        assertGt(bnbullPot, 0);
        assertGt(bnbPot, 0);

        // Force both to fire, on DIFFERENT duels, so neither is denied — at the
        // pots' real 1-in-50 and 1-in-100, with the word searched for.
        duel.open(address(potBnbull), alice, 1, 0xA1, 1);
        duel.open(address(potBnb), bob, 2, 0xB2, 2);

        uint256 wA = _wordThatWins(address(potBnbull), 0xA1, 1, alice, 0, 50);
        uint256 wB = _wordThatWins(address(potBnb), 0xB2, 2, bob, 0, 100);

        uint256 rA = potBnbull.requestResolve(1);
        uint256 rB = potBnb.requestResolve(1);
        coord.fulfill(rA, wA);
        coord.fulfill(rB, wB);
        potBnbull.resolve(1);
        potBnb.resolve(1);

        assertEq(bnbull.balanceOf(alice), bnbullPot, "the BNBULL pot paid its winner");
        assertEq(wbnb.balanceOf(bob), bnbPot, "the WBNB pot paid its winner");
        assertEq(potBnbull.pool(), 0);
        assertEq(potBnb.pool(), 0);
        assertEq(potBnbull.awardCount(), 1);
        assertEq(potBnb.awardCount(), 1);
    }

    /// @dev A revive donation with the buyback route down must still leave the
    ///      money recoverable and the caller unharmed — the Graveyard leg of
    ///      the same guarantee, standing in for the contract another agent is
    ///      writing.
    function test_aReviveDonationSurvivesADeadPoolAndIsRecoveredLater() public {
        router.setRevertOnSwap(true);
        router.setRevertOnQuote(true);

        address graveyard = address(0x64A5E);
        vm.deal(graveyard, 5 ether);
        vm.prank(graveyard);
        drop.donatePotNative{value: 5 ether}(); // un-guarded, must not revert

        uint256 deferred = drop.pendingBnbullBuyNative();
        assertGt(deferred, 0);

        router.setRevertOnSwap(false);
        router.setRevertOnQuote(false);
        // ⛔ OWNER, not keeper: a priced sweep on `MintDrop` is owner-only.
        vm.prank(owner);
        drop.sweepBnbullPot(MintDrop.PotSource.Native, 0, 1);
        assertEq(drop.pendingBnbullBuyNative(), 0);
        assertEq(potBnbull.pool(), deferred * BNBULL_PER_BNB);
    }

    /// @dev `DECISIONS.md §5`: socials embedded in every contract we deploy, as
    ///      owner-settable strings, so a scanner can find the project from any
    ///      contract address.
    function test_everyContractCarriesTheSocials() public view {
        assertEq(bulls.website(), "https://bnbulls.xyz");
        assertEq(bulls.twitter(), "https://x.com/WeAreBNBulls");
        assertEq(bulls.telegram(), "https://t.me/WeAreBNBulls");

        assertEq(drop.website(), "https://bnbulls.xyz");
        assertEq(drop.twitter(), "https://x.com/WeAreBNBulls");
        assertEq(drop.telegram(), "https://t.me/WeAreBNBulls");

        assertEq(potBnbull.website(), "https://bnbulls.xyz");
        assertEq(potBnbull.twitter(), "https://x.com/WeAreBNBulls");
        assertEq(potBnbull.telegram(), "https://t.me/WeAreBNBulls");
    }

    /// @dev `DECISIONS.md §13/§15`: the ERC-721 collection symbol is `BNBULLS`,
    ///      distinct from the token ticker `BNBULL`.
    function test_theCollectionSymbolIsBnbulls() public view {
        assertEq(bulls.name(), "BNBulls");
        assertEq(bulls.symbol(), "BNBULLS");
    }

    /// @dev The odds each pot was deployed with (§13): BNBULL 1-in-50,
    ///      BNB 1-in-100.
    function test_theDeployedOddsAreFiftyAndOneHundred() public view {
        assertEq(potBnbull.oddsOneIn(), 50);
        assertEq(potBnb.oddsOneIn(), 100);
        assertEq(address(potBnbull.prizeToken()), address(bnbull));
        assertEq(address(potBnb.prizeToken()), address(wbnb), "the BNB pot holds WBNB");
    }

    /// @dev The BNBULL airdrop rides along with a mint but is paid strictly out
    ///      of the FREE balance — never out of money a pot is owed — and a
    ///      shortfall airdrops less rather than failing the mint.
    function test_theAirdropNeverSpendsPotMoneyAndNeverBlocksAMint() public {
        drop.setAirdropPerMint(100e18);
        bnbull.mint(address(drop), 250e18); // only enough for two and a half

        _mintBnb(alice, 3);
        assertEq(bnbull.balanceOf(alice), 250e18, "the third mint got the remainder");
        assertEq(bulls.balanceOf(alice), 3, "a dry promo budget must not fail a mint");
        assertEq(drop.freeBnbull(), 0);

        uint256 cap = drop.MAX_AIRDROP_PER_MINT();
        vm.expectRevert(abi.encodeWithSelector(MintDrop.AirdropTooHigh.selector, cap + 1, cap));
        drop.setAirdropPerMint(cap + 1);
    }

    /// @dev With the BNBULL leg deferring, the accrued BNBULL is reserved and
    ///      the airdrop must not reach into it.
    function test_theAirdropCannotSpendAccruedPotBnbull() public {
        potBnbull.setFunder(address(drop), false);
        drop.setAirdropPerMint(10e18);

        _giveBnbull(alice, 100_000e18);
        vm.prank(alice);
        drop.mintWithBNBULL(alice, 1);

        // 270 BNBULL accrued for the pot; the free balance is zero, so the
        // airdrop paid nothing rather than raiding the bucket.
        assertEq(drop.pendingBnbullDirect(), 270e18);
        assertEq(drop.freeBnbull(), 0);
        assertEq(bnbull.balanceOf(address(drop)), 270e18);
    }
}
