// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Duel} from "../contracts/Duel.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {
    DuelRefundProbe,
    DuelRefundRejector,
    DuelShortWBNB,
    IDuelUnderTest
} from "./mocks/DuelMocks.sol";

/**
 * @title DuelStakesTest
 * @notice PRIORITY 4. Stakes, `maxFightCostOf`, and the native convenience
 *         path.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      Three rules are on trial here.
 *
 *      **The one-shot ceiling.** `maxFightCostOf` is fixed when an asset is
 *      registered and immutable after, so "a compromised owner key can
 *      re-price within it but can never set a stake nobody can afford, and no
 *      signature can charge above it."
 *
 *      **Legible failures.** `_takeSide` checks balance AND allowance
 *      explicitly, and reverts `StakeUnaffordable` / `StakeNotApproved` with
 *      the numbers in the error. That is the visible half of the affordability
 *      fix: the residual "the player moved their own money" case has to read
 *      as a named error in a wallet simulation, not as an opaque
 *      `ERC20: transfer amount exceeds balance`.
 *
 *      **BNB is staked as WBNB.** `submitDuel` is payable and wraps exactly
 *      what the caller's own side owes, refunding the rest — and the refund is
 *      DEAD LAST, after every piece of state is settled. A passive opponent
 *      can only ever be debited by allowance, because raw BNB cannot grant
 *      one. That is physics, not policy, and
 *      `test_aPassiveOpponentCanOnlyEverBeDebitedByAllowance` is the proof.
 */
contract DuelStakesTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    MockFeeToken internal feeToken;

    uint256 internal constant STAKE_BULL = 10e18;
    uint256 internal constant STAKE_WBNB = 0.01 ether;

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);

        feeToken = new MockFeeToken(100); // 1% on transfer
        duelC.addFightAsset(address(feeToken), 1_000e18, DEV_BPS);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The one-shot per-asset ceiling
    // ══════════════════════════════════════════════════════════════════════

    function test_aStakeAboveTheAssetCeilingIsRefused() public {
        _fundForFight(alice, MAX_COST_BNBULL * 4, 0);
        _fundForFight(bob, MAX_COST_BNBULL * 4, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = MAX_COST_BNBULL + 1;

        _expectSubmitRevert(
            alice,
            r,
            abi.encodeWithSelector(Duel.FightCostTooHigh.selector, MAX_COST_BNBULL + 1)
        );

        // Exactly at the ceiling is fine — it is a ceiling, not a barrier.
        r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = MAX_COST_BNBULL;
        _submitAs(alice, r);
    }

    /**
     * @notice THE PAY-TIME BOUND ON THE ORACLE-DERIVED LEG.
     *
     * @dev `DECISIONS.md §26` made the BNB stake a stored DOLLAR figure
     *      converted through Chainlink, so the sticker moves whenever the feed
     *      does. `maxFightCostOf[wbnb]` is the only bound that survives to
     *      settlement, and it is one-shot and immutable — which is exactly why
     *      the ceiling had to stay when the peg went.
     *
     *      A BNB price collapse makes the same $10 sticker cost far more BNB.
     *      Past the ceiling the signature simply cannot settle, and it says so
     *      by name before a single wei moves.
     */
    function test_theOracleDerivedStakeIsStillBoundedByTheOneShotCeiling() public {
        // $10 at $0.05/BNB is 200 BNB — well past the 100 ether ceiling.
        feed.setAnswer(0.05e8);
        assertGt(duelC.stickerCost(address(wbnb)), MAX_COST_WBNB, "harness: not past the ceiling");

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.stakeA = MAX_COST_WBNB + 1;

        vm.deal(alice, 1_000 ether);
        _expectSubmitRevertValue(
            alice,
            r,
            500 ether,
            abi.encodeWithSelector(Duel.FightCostTooHigh.selector, MAX_COST_WBNB + 1)
        );
    }

    function test_theCeilingIsOneShotAndTheAssetCannotBeReRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(Duel.AssetAlreadyAdded.selector, address(bnbull))
        );
        duelC.addFightAsset(address(bnbull), MAX_COST_BNBULL * 100, DEV_BPS);

        assertEq(duelC.maxFightCostOf(address(bnbull)), MAX_COST_BNBULL, "the ceiling moved");
    }

    function test_registrationGuards() public {
        vm.expectRevert(Duel.ZeroAddress.selector);
        duelC.addFightAsset(address(0), 1e18, 0);

        MockERC20 fresh = new MockERC20("Fresh", "FRSH", 18);
        vm.expectRevert(Duel.ZeroMaxCost.selector);
        duelC.addFightAsset(address(fresh), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Duel.DevShareTooHigh.selector, uint16(2_001)));
        duelC.addFightAsset(address(fresh), 1e18, 2_001);

        // The sentinel takes `defaultDevShareBps`.
        duelC.setDefaultDevShareBps(1_500);
        duelC.addFightAsset(address(fresh), 1e18, type(uint16).max);
        assertEq(duelC.devShareBpsOf(address(fresh)), 1_500);

        vm.prank(alice);
        vm.expectRevert();
        duelC.addFightAsset(address(0xBEEF), 1e18, 0);
    }

    function test_anUnregisteredAssetCannotBeStaked() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        rogue.mint(alice, 1_000e18);
        vm.prank(alice);
        rogue.approve(address(duelC), type(uint256).max);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(rogue);
        r.stakeA = 1e18;

        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.UnsupportedAsset.selector, address(rogue))
        );
    }

    /// @dev `(address(0), 0)` is the only legal "this side stakes nothing".
    function test_anAmountWithoutAnAssetIsRefused() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(0);
        r.stakeA = 1e18;

        _expectSubmitRevert(alice, r, abi.encodeWithSelector(Duel.StakeWithoutAsset.selector));
    }

    function test_theKeepersPegIsBoundedByTheCeiling() public {
        vm.expectRevert(
            abi.encodeWithSelector(Duel.FightCostTooHigh.selector, MAX_COST_BNBULL + 1)
        );
        duelC.setFightCost(address(bnbull), MAX_COST_BNBULL + 1);

        // Zero is legal: that asset temporarily fights free.
        duelC.setFightCost(address(bnbull), 0);
        assertEq(duelC.fighterCost(address(bnbull)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(Duel.UnsupportedAsset.selector, address(0xBEEF))
        );
        duelC.setFightCost(address(0xBEEF), 1e18);
    }

    // ═══════════════════════════
    //  THE DOLLAR ANCHOR (`DECISIONS.md §26` + `§1` option A)
    // ═══════════════════════════

    /**
     * @notice WBNB HAS NO STORED PEG, AND THE CONTRACT REFUSES TO LET ONE
     *         EXIST.
     *
     * @dev Before `§26` the BNB stake price was derived off chain from "the
     *      registered fight asset that is neither BNBULL nor WBNB" — the
     *      stablecoin. Deleting that asset deleted the anchor, and the naive
     *      landing spot was `fightCostOf[wbnb]`: a flat keeper number with no
     *      freshness guarantee anywhere in the bytecode, which is precisely the
     *      failure `§1` option A exists to prevent.
     *
     *      So there is no second source of truth to disagree with the first.
     *      The mapping reads zero forever and the setter refuses by name.
     */
    function test_theWbnbLegHasNoStoredPegAndRefusesOne() public {
        assertEq(duelC.fightCostOf(address(wbnb)), 0, "a stale WBNB peg exists");

        vm.expectRevert(
            abi.encodeWithSelector(Duel.OraclePricedAsset.selector, address(wbnb))
        );
        duelC.setFightCost(address(wbnb), 1 ether);

        assertEq(duelC.fightCostOf(address(wbnb)), 0);
    }

    /// @notice The stored dollar figure is converted through the Chainlink
    ///         feed, rounding UP, so a rounding artefact never quotes under.
    function test_theBnbStickerIsTheDollarFigureConvertedThroughTheFeed() public view {
        assertEq(duelC.usdFightPrice1e18(), USD_FIGHT_PRICE);
        assertEq(duelC.bnbUsdPrice(), BNB_USD_1E18);
        assertEq(
            duelC.stickerCost(address(wbnb)),
            _ceilDiv(USD_FIGHT_PRICE * 1e18, BNB_USD_1E18),
            "the BNB sticker is not the oracle conversion"
        );
    }

    /// @notice And it MOVES with the feed. A keeper peg would not have.
    function test_theBnbStickerTracksTheOracleWithNoKeeperTick() public {
        uint256 at600 = duelC.stickerCost(address(wbnb));

        // ⚠ Ceil-then-halve is not halve-then-ceil, so these are asserted
        // against the conversion rather than against `at600` arithmetic — one
        // wei of rounding is the sticker rounding UP, which it must always do.
        feed.setAnswer(300e8); // BNB halves
        assertEq(
            duelC.stickerCost(address(wbnb)),
            _ceilDiv(USD_FIGHT_PRICE * 1e18, 300e18),
            "the same $10 costs twice the BNB"
        );
        assertApproxEqAbs(duelC.stickerCost(address(wbnb)), at600 * 2, 2);

        feed.setAnswer(1_200e8); // BNB doubles
        assertEq(duelC.stickerCost(address(wbnb)), _ceilDiv(USD_FIGHT_PRICE * 1e18, 1_200e18));
        assertApproxEqAbs(duelC.stickerCost(address(wbnb)), at600 / 2, 2);

        // Nothing was re-pegged in between. That is the whole point.
        assertEq(duelC.usdFightPrice1e18(), USD_FIGHT_PRICE);
    }

    /**
     * @notice STICKER FIRST, DISCOUNT SECOND — the double-discount trap on a
     *         two-step conversion.
     *
     * @dev Taking the discount off the dollar anchor AND again off the BNB
     *      result gives 19% on a 10% setting. `fighterCost` converts, then
     *      discounts, exactly once.
     */
    function test_theDiscountOnTheOracleLegIsAppliedExactlyOnce() public {
        duelC.setDiscountBps(address(wbnb), 1_000);

        uint256 sticker = duelC.stickerCost(address(wbnb));
        assertEq(duelC.fighterCost(address(wbnb)), (sticker * 9_000) / 10_000, "not 10% off");

        // The 19% number a double application would produce.
        uint256 doubled = (((sticker * 9_000) / 10_000) * 9_000) / 10_000;
        assertTrue(duelC.fighterCost(address(wbnb)) != doubled, "the discount applied twice");
    }

    /**
     * @notice A BAD ORACLE REFUSES TO QUOTE. IT NEVER CLAMPS.
     *
     * @dev `§1`: stale, non-positive and out-of-band all REVERT. A clamped
     *      price is a wrong price presented as a right one, and here it would
     *      quote fights at a stake nobody chose. The revert propagates out of
     *      `MintDrop.bnbUsdPrice` unchanged — one staleness policy, not two.
     */
    function test_aStaleOrBadOracleRefusesToPriceABnbFight() public {
        vm.warp(block.timestamp + drop.maxOracleAge() + 1);
        vm.expectRevert();
        duelC.stickerCost(address(wbnb));

        feed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(MintDrop.OracleBadAnswer.selector, int256(-1)));
        duelC.stickerCost(address(wbnb));

        feed.setAnswer(BNB_USD_8);
        drop.setOraclePolicy(1 hours, 500e18, 700e18);
        feed.setAnswer(100e8); // $100, under the band
        vm.expectRevert(
            abi.encodeWithSelector(MintDrop.OracleOutOfBand.selector, uint256(100e18))
        );
        duelC.stickerCost(address(wbnb));
    }

    /// @notice An unwired oracle fails CLOSED — no fallback to a stored peg,
    ///         because a wrong price is worse than no fight.
    function test_anUnwiredOracleRefusesToPriceABnbFightRatherThanGuessing() public {
        Duel fresh = new Duel(
            Duel.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                trustedSigner: signer,
                devTreasury: duelTreasury,
                defaultDevShareBps: DEV_BPS
            })
        );
        fresh.setUsdFightPrice(USD_FIGHT_PRICE);

        vm.expectRevert(Duel.OracleNotWired.selector);
        fresh.stickerCost(address(wbnb));

        // ...but an UNPRICED leg reads zero without touching the feed at all,
        // so a pre-wiring UI can still render "BNB fights are free right now"
        // instead of blowing up.
        fresh.setUsdFightPrice(0);
        assertEq(fresh.stickerCost(address(wbnb)), 0);
        assertEq(fresh.fighterCost(address(wbnb)), 0);
    }

    /// @notice The anchor is bounded, so a compromised owner key cannot
    ///         re-price fights absurdly.
    function test_theDollarAnchorIsBoundedAndOwnerOnly() public {
        uint256 cap = duelC.MAX_USD_FIGHT_PRICE();
        vm.expectRevert(abi.encodeWithSelector(Duel.FightCostTooHigh.selector, cap + 1));
        duelC.setUsdFightPrice(cap + 1);

        vm.prank(alice);
        vm.expectRevert();
        duelC.setUsdFightPrice(1e18);

        duelC.setUsdFightPrice(cap);
        assertEq(duelC.usdFightPrice1e18(), cap);
    }

    /// @notice SETTLEMENT STILL CHARGES THE SIGNED AMOUNT. An oracle tick
    ///         between quote and submit changes the NEXT fight, not this one —
    ///         the same guarantee a keeper repeg has, now against a feed that
    ///         moves every block.
    function test_anOracleTickBetweenQuoteAndSubmitDoesNotChangeThePrice() public {
        _fundForFight(bob, 0, 1 ether);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_WBNB;
        r.stakeB = STAKE_WBNB;

        // BNB collapses AFTER the quote was signed.
        feed.setAnswer(60e8);
        assertGt(duelC.stickerCost(address(wbnb)), STAKE_WBNB * 5, "harness: price did not move");

        vm.deal(alice, 5 ether);
        uint256 before = alice.balance;
        _submitValue(alice, r, 1 ether);
        assertEq(before - alice.balance, STAKE_WBNB, "the signed price is the price");
    }

    /**
     * @notice FIGHTS ARE UNDISCOUNTED AT LAUNCH, IN EVERY CURRENCY.
     *
     * @dev `DECISIONS.md §39`, owner call: "a $2 duel costs $2, whether it is
     *      paid in BNB or in BNBULL." A duel is a bet between two players, and
     *      discounting one side's entry means the two fighters put different
     *      money into the same purse — `_distributePot` settles each side in
     *      its OWN asset, so that asymmetry lands straight in the winner's
     *      payout. §2's "the discount is ALWAYS BNBULL" still stands; it just
     *      belongs to MINTING.
     */
    function test_fightsCarryNoLaunchDiscountInAnyCurrency() public {
        assertEq(duelC.discountBpsOf(address(bnbull)), 0, "DECISIONS 39: no discount on fights");
        assertEq(duelC.discountBpsOf(address(wbnb)), 0, "DECISIONS 39: none on the BNB leg either");

        duelC.setFightCost(address(bnbull), 1_000e18);
        assertEq(
            duelC.fighterCost(address(bnbull)),
            duelC.stickerCost(address(bnbull)),
            "a BNBULL fight costs the sticker, full stop"
        );
        assertEq(
            duelC.fighterCost(address(wbnb)),
            duelC.stickerCost(address(wbnb)),
            "no discount off the BNB leg"
        );
        assertEq(duelC.fighterCost(address(0)), 0);

        vm.expectRevert(abi.encodeWithSelector(Duel.InvalidShare.selector, uint256(5_001)));
        duelC.setDiscountBps(address(bnbull), 5_001);
    }

    /**
     * @notice THE DOUBLE-DISCOUNT TRAP, still covered even though §39 turns the
     *         fight discount OFF at launch.
     *
     * @dev The setter is deliberately still live so the owner can switch it on
     *      without a redeploy. The moment they do, the trap is back: the keeper
     *      pegs the FULL sticker and the contract owns the discount, so a
     *      discounted fight must be 10% off and never 19%. Deleting this with
     *      the launch value would have left that machinery untested the day it
     *      is turned on, which is the worst possible day to find out.
     */
    function test_ifTheFightDiscountIsEverTurnedOnItAppliesExactlyOnce() public {
        duelC.setDiscountBps(address(bnbull), 1_000);
        duelC.setFightCost(address(bnbull), 1_000e18);

        assertEq(duelC.stickerCost(address(bnbull)), 1_000e18, "the peg is the FULL sticker");
        assertEq(duelC.fighterCost(address(bnbull)), 900e18, "10% off, not 19%");
        assertEq(duelC.discountBpsOf(address(wbnb)), 0, "and only on the asset it was set on");
    }

    /**
     * @notice THE QUOTING VIEW IS NEVER USED AT SETTLEMENT.
     *
     * @dev "a keeper repeg between quote and submit changes the NEXT fight's
     *      price, never the one already on the player's screen." A compromised
     *      owner key repegging to the ceiling cannot reach into standing
     *      allowances, because no signature authorises the new number.
     */
    function test_aRepegBetweenQuoteAndSubmitDoesNotChangeThePrice() public {
        _fundForFight(alice, 1_000e18, 0);
        _fundForFight(bob, 1_000e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(bobBull));
        r.assetA = address(bnbull);
        r.stakeA = STAKE_BULL;

        // The keeper repegs to the ceiling AFTER the quote was signed.
        // Undiscounted since `DECISIONS.md §39`, so the quote IS the peg — the
        // point of this test is that neither number reaches the signed stake.
        duelC.setFightCost(address(bnbull), MAX_COST_BNBULL);
        assertEq(duelC.fighterCost(address(bnbull)), MAX_COST_BNBULL);

        uint256 before = bnbull.balanceOf(alice);
        _submitAs(alice, r);
        assertEq(before - bnbull.balanceOf(alice), STAKE_BULL, "the signed price is the price");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Legible failures, with the numbers in the error
    // ══════════════════════════════════════════════════════════════════════

    function test_anUnaffordableStakeSaysSoByNameAndByNumber() public {
        bnbull.mint(alice, 3e18);
        vm.prank(alice);
        bnbull.approve(address(duelC), type(uint256).max);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = STAKE_BULL;

        _expectSubmitRevert(
            alice,
            r,
            abi.encodeWithSelector(
                Duel.StakeUnaffordable.selector, alice, address(bnbull), STAKE_BULL, 3e18
            )
        );
    }

    function test_anUnapprovedStakeSaysSoByNameAndByNumber() public {
        bnbull.mint(alice, 1_000e18);
        vm.prank(alice);
        bnbull.approve(address(duelC), 4e18);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = STAKE_BULL;

        _expectSubmitRevert(
            alice,
            r,
            abi.encodeWithSelector(
                Duel.StakeNotApproved.selector, alice, address(bnbull), STAKE_BULL, 4e18
            )
        );
    }

    /**
     * @notice A fee-on-transfer stake asset is refused LOUDLY.
     *
     * @dev The pull is booked as a measured balance delta, so a token with a
     *      transfer tax cannot make the duel settle numbers it does not hold.
     *      `BNB-CHAIN-FACTS §5` says a launchpad token's transfer gate is a
     *      thing to VERIFY at deploy, not assume — this is what happens if the
     *      answer is bad.
     */
    function test_aFeeOnTransferStakeIsRefusedRatherThanShortSettled() public {
        feeToken.mint(alice, 1_000e18);
        vm.prank(alice);
        feeToken.approve(address(duelC), type(uint256).max);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(feeToken);
        r.stakeA = 100e18;

        _expectSubmitRevert(
            alice,
            r,
            abi.encodeWithSelector(
                Duel.StakeShortfall.selector, address(feeToken), uint256(100e18), uint256(99e18)
            )
        );

        // With the tax switched off the very same fight settles.
        feeToken.setFeeBps(0);
        _submitAs(alice, r);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Settlement — each side in its own asset
    // ══════════════════════════════════════════════════════════════════════

    function test_theWinnerTakesBothStakesLessTheDevCut() public {
        _fundForFight(alice, 1_000e18, 0);
        _fundForFight(bob, 1_000e18, 0);

        uint256 aBefore = bnbull.balanceOf(alice);
        uint256 bBefore = bnbull.balanceOf(bob);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = STAKE_BULL;
        r.stakeB = STAKE_BULL;
        _submitAs(alice, r);

        uint256 cut = (STAKE_BULL * DEV_BPS) / 10_000; // 1e18 each side
        assertEq(bnbull.balanceOf(alice), aBefore + STAKE_BULL - 2 * cut, "winner's take");
        assertEq(bnbull.balanceOf(bob), bBefore - STAKE_BULL, "loser paid its stake");
        assertEq(bnbull.balanceOf(address(duelC)), 0, "nothing stranded in the duel");
    }

    /// @dev A tie refunds each fighter their OWN stake less the cut, with no
    ///      cross-asset splitting — nobody ends a draw holding a token they
    ///      never opted into.
    function test_aTieRefundsEachSideItsOwnAssetOnly() public {
        _fundForFight(alice, 0, 1 ether);
        _fundForFight(bob, 100_000e18, 0);

        duelC.setFightCost(address(bnbull), 1_000e18);

        uint256 aliceBnbullBefore = bnbull.balanceOf(alice);
        uint256 bobWbnbBefore = wbnb.balanceOf(bob);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, 0);
        r.assetA = address(wbnb);
        r.assetB = address(bnbull);
        r.stakeA = STAKE_WBNB;
        r.stakeB = 1_000e18;
        _submitAs(alice, r);

        assertEq(
            bnbull.balanceOf(alice), aliceBnbullBefore, "alice was handed a token she never chose"
        );
        assertEq(wbnb.balanceOf(bob), bobWbnbBefore, "bob was handed a token he never chose");
        // Each side is down exactly its own dev cut.
        assertEq(wbnb.balanceOf(address(duelC)), 0);
        assertEq(bnbull.balanceOf(address(duelC)), 0);
    }

    function test_aMixedAssetPotSettlesInBothAssets() public {
        _fundForFight(alice, 0, 1 ether);
        _fundForFight(bob, 100_000e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.assetB = address(bnbull);
        r.stakeA = STAKE_WBNB;
        r.stakeB = 1_000e18;

        uint256 aliceBnbullBefore = bnbull.balanceOf(alice);
        _submitAs(alice, r);

        assertEq(
            bnbull.balanceOf(alice) - aliceBnbullBefore,
            1_000e18 - 100e18,
            "the winner takes the opponent's asset too"
        );
    }

    function test_theDevCutReachesTheDevTreasury() public {
        _fundForFight(alice, 1_000e18, 0);
        _fundForFight(bob, 1_000e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = STAKE_BULL;
        r.stakeB = STAKE_BULL;
        _submitAs(alice, r);

        // 10% cut on 20 staked = 2. `potShareBps` (30%) of that feeds the
        // pots; the remaining 70% is dev's.
        uint256 cut = 2e18;
        uint256 slice = (cut * 3_000) / 10_000;
        assertEq(bnbull.balanceOf(duelTreasury), cut - slice, "dev's share of the cut");
    }

    function test_zeroStakeSidesAreLegal() public {
        _fundForFight(alice, 1_000e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(bnbull);
        r.stakeA = STAKE_BULL;
        r.assetB = address(0);
        r.stakeB = 0;

        uint256 before = bnbull.balanceOf(alice);
        _submitAs(alice, r);
        // Alice staked and won it straight back, less her own dev cut.
        assertEq(before - bnbull.balanceOf(alice), (STAKE_BULL * DEV_BPS) / 10_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  BNB is staked as WBNB
    // ══════════════════════════════════════════════════════════════════════

    function test_bnbIsWrappedExactlyAndTheSurplusComesBack() public {
        _fundForFight(bob, 0, 1 ether);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_WBNB;
        r.stakeB = STAKE_WBNB;

        vm.deal(alice, 5 ether);
        uint256 nativeBefore = alice.balance;

        vm.expectEmit(true, false, false, true, address(duelC));
        emit Duel.NativeStakeWrapped(alice, STAKE_WBNB);
        _submitValue(alice, r, 3 ether);

        assertEq(
            nativeBefore - alice.balance,
            STAKE_WBNB,
            "the wrap took more (or less) than the side owed"
        );
        uint256 cut = (STAKE_WBNB * DEV_BPS) / 10_000;
        assertEq(wbnb.balanceOf(alice), 2 * (STAKE_WBNB - cut), "winner's WBNB");
        assertEq(address(duelC).balance, 0, "BNB stranded in the duel");
    }

    /// @dev Sending value with no WBNB side owed by the caller refunds all of
    ///      it and wraps nothing.
    function test_valueWithNothingToWrapIsFullyRefunded() public {
        vm.deal(alice, 5 ether);
        uint256 before = alice.balance;

        _submitValue(alice, _newResult(aliceBull, bobBull, uint32(aliceBull)), 2 ether);

        assertEq(alice.balance, before, "value was consumed with no WBNB side");
        assertEq(wbnb.balanceOf(address(duelC)), 0);
    }

    /**
     * @notice A PASSIVE OPPONENT CAN ONLY EVER BE DEBITED BY ALLOWANCE.
     *
     * @dev "raw BNB cannot grant one — so a side that is not `msg.sender`
     *      stakes WBNB or BNBULL, never a native send. That is
     *      physics, not policy."
     *
     *      Alice sends far more BNB than BOTH stakes together. It still cannot
     *      pay bob's side: the native credit path requires `owner_ ==
     *      msg.sender`, so bob is refused on his own empty balance and alice's
     *      money stays hers.
     */
    function test_aPassiveOpponentCanOnlyEverBeDebitedByAllowance() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_WBNB;
        r.stakeB = STAKE_WBNB;

        vm.deal(alice, 5 ether);
        _expectSubmitRevertValue(
            alice,
            r,
            3 ether,
            abi.encodeWithSelector(
                Duel.StakeUnaffordable.selector, bob, address(wbnb), STAKE_WBNB, uint256(0)
            )
        );

        // Bob holds WBNB but has approved nothing: still refused, by name.
        vm.deal(address(this), address(this).balance + 1 ether);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(bob, 1 ether);

        _expectSubmitRevertValue(
            alice,
            r,
            3 ether,
            abi.encodeWithSelector(
                Duel.StakeNotApproved.selector, bob, address(wbnb), STAKE_WBNB, uint256(0)
            )
        );
    }

    /**
     * @notice THE REFUND IS DEAD LAST.
     *
     * @dev Proved rather than asserted. The probe is the payer, so the refund
     *      hands control to it — and its `receive()` snapshots the world. By
     *      then the sequence must be bumped, the winner must already hold its
     *      WBNB, and the loser must already be flagged dead. If the refund
     *      moved earlier, one of these three would come back half-done.
     */
    function test_theRefundIsDeadLastAfterEveryPieceOfStateIsSettled() public {
        duelC.setLossesToDie(1); // so one loss kills, and death is observable

        DuelRefundProbe probe = new DuelRefundProbe();
        uint256 probeBull = _mintBull(address(probe));
        probe.configure(address(duelC), address(bulls), address(wbnb), bobBull);

        _fundForFight(bob, 0, 1 ether);

        Duel.DuelResult memory r = _newResult(probeBull, bobBull, uint32(probeBull));
        r.assetA = address(wbnb);
        r.assetB = address(wbnb);
        r.stakeA = STAKE_WBNB;
        r.stakeB = STAKE_WBNB;
        bytes memory sig = _sign(r);

        vm.deal(address(this), address(this).balance + 2 ether);
        probe.submit{value: 1 ether}(_asProbeResult(r), sig);

        assertTrue(probe.sawRefund(), "no refund reached the payer");
        assertEq(probe.refundAmount(), 1 ether - STAKE_WBNB);
        assertEq(probe.seqAtRefund(), 1, "the sequence was not bumped before the refund");
        uint256 cut = (STAKE_WBNB * DEV_BPS) / 10_000;
        assertEq(
            probe.wbnbAtRefund(), 2 * (STAKE_WBNB - cut), "the winner was not paid before the refund"
        );
        assertTrue(probe.deadAtRefund(), "the death was not applied before the refund");
    }

    /// @dev A payer that refuses its own money back reverts the duel. The
    ///      refund is the caller's own contract's problem, and failing loudly
    ///      beats stranding BNB in the Duel.
    function test_aRefundThatCannotBeDeliveredRevertsTheDuel() public {
        DuelRefundRejector rejector = new DuelRefundRejector(address(duelC));
        uint256 rejectorBull = _mintBull(address(rejector));

        Duel.DuelResult memory r = _newResult(rejectorBull, bobBull, uint32(rejectorBull));
        bytes memory sig = _sign(r);

        vm.deal(address(this), address(this).balance + 1 ether);
        vm.expectRevert(Duel.RefundFailed.selector);
        rejector.submit{value: 1 ether}(_asProbeResult(r), sig);
    }

    /**
     * @notice The wrap is MEASURED, even though a wrap is 1:1.
     *
     * @dev "Measured anyway, because measuring is free and assumptions are how
     *      the fefers decimals trap happened." A wrapper that credits less
     *      than it was sent would otherwise have the duel settle a pot it does
     *      not hold.
     */
    function test_aShortChangingWrapperIsCaught() public {
        DuelShortWBNB shortWbnb = new DuelShortWBNB();
        Duel d = new Duel(
            Duel.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(shortWbnb),
                trustedSigner: signer,
                devTreasury: duelTreasury,
                defaultDevShareBps: DEV_BPS
            })
        );
        d.addFightAsset(address(shortWbnb), 100 ether, DEV_BPS);

        Duel.DuelResult memory r = _newResultOn(d, bulls, aliceBull, bobBull, uint32(aliceBull));
        r.assetA = address(shortWbnb);
        r.stakeA = STAKE_WBNB;
        bytes memory sig = _signOn(d, r);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Duel.WrapShortfall.selector, STAKE_WBNB, (STAKE_WBNB * 9_000) / 10_000
            )
        );
        d.submitDuel{value: STAKE_WBNB}(r, sig);
    }

    /// @dev There is deliberately no native rescue and no `receive()`: the
    ///      only BNB that ever touches this contract is a stake being wrapped
    ///      or a refund going straight back out in the same call.
    function test_thereIsNoWayForLooseBnbToLandInTheDuel() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(duelC).call{value: 1 ether}("");
        assertFalse(ok, "Duel has a receive(); BNB can arrive unaccounted for");

        (ok,) = address(duelC).call(
            abi.encodeWithSignature("rescueNative(address,uint256)", owner, 1)
        );
        assertFalse(ok, "a native rescue exists on Duel");
    }

    /// @dev A stray token IS rescuable — the duel holds no player money
    ///      between calls, so there is nothing here for this to steal.
    function test_aStrayTokenIsRescuable() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(duelC), 7e18);
        duelC.rescueToken(address(stray), owner, 7e18);
        assertEq(stray.balanceOf(owner), 7e18);

        vm.prank(alice);
        vm.expectRevert();
        duelC.rescueToken(address(stray), alice, 0);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _asProbeResult(Duel.DuelResult memory r)
        internal
        pure
        returns (IDuelUnderTest.DuelResult memory o)
    {
        o = IDuelUnderTest.DuelResult({
            tokenA: r.tokenA,
            tokenB: r.tokenB,
            winnerId: r.winnerId,
            rounds: r.rounds,
            seed: r.seed,
            newEloA: r.newEloA,
            newEloB: r.newEloB,
            assetA: r.assetA,
            assetB: r.assetB,
            stakeA: r.stakeA,
            stakeB: r.stakeB,
            seqA: r.seqA,
            seqB: r.seqB,
            nonce: r.nonce,
            expiry: r.expiry
        });
    }
}
