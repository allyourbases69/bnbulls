// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Duel} from "../contracts/Duel.sol";
import {DuelRouterMock, IDuelUnderTest} from "./mocks/DuelMocks.sol";

/**
 * @title DuelSelfDuelTest
 * @notice PRIORITY 2. `allowSelfDuel`, default FALSE — `DECISIONS.md §16`.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      Two reasons the flag exists, and the second is the one that bites:
 *        - ECONOMIC. An owner alternating wins between two of their own bulls
 *          keeps both alive forever, pays only the dev cut, and buys a
 *          full-odds ticket on a pot everybody else funded.
 *        - COLLECTION SAFETY. `KEEPER-FLEET-AND-OPS.md` records the fefers
 *          autoplay bot killing **34 of 60 bulls** before its
 *          opponent-protection bug was found. This flag is the structural
 *          version of that protection, enforced by the bytecode rather than
 *          trusted to every bot anyone ever writes.
 *
 *      The load-bearing detail is WHERE the check runs: at SETTLEMENT, against
 *      live `ownerOf` reads. An off-chain check in `api/run-duel` is
 *      bypassable by transferring a bull after the quote, so both directions
 *      are tested here — a transfer IN turns a legal fight into a self-duel,
 *      and a transfer OUT rescues an illegal one, on the very same signature.
 */
contract DuelSelfDuelTest is DuelGraveyardBase {
    uint256 internal bullOne;
    uint256 internal bullTwo;
    uint256 internal bobBull;

    DuelRouterMock internal routerMock;

    function setUp() public override {
        super.setUp();
        bullOne = _mintBull(alice);
        bullTwo = _mintBull(alice);
        bobBull = _mintBull(bob);
        routerMock = new DuelRouterMock(address(duelC));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Off by default
    // ══════════════════════════════════════════════════════════════════════

    function test_theFlagDefaultsToFalse() public view {
        assertFalse(duelC.allowSelfDuel(), "the safe default is the one that happens");
    }

    function test_aSameOwnerFightIsBlocked() public {
        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.SelfDuelBlocked.selector, alice)
        );
    }

    /// @dev Blocked before ANY of the expensive work — no sequence consumed,
    ///      no stake pulled, no ticket opened.
    function test_theBlockCostsNothing() public {
        _fundForFight(alice, 100e18, 0);
        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = 10e18;
        r.stakeB = 10e18;

        uint256 before = bnbull.balanceOf(alice);
        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.SelfDuelBlocked.selector, alice)
        );

        assertEq(bnbull.balanceOf(alice), before);
        assertEq(duelC.fightSeq(alice), 0);
        assertEq(potBnbull.ticketCount(), 0);
    }

    /// @dev One bull cannot fight itself under any configuration. This is a
    ///      different guard from `SelfDuelBlocked` and is unconditional.
    function test_oneBullCannotFightItself() public {
        duelC.setAllowSelfDuel(true);
        Duel.DuelResult memory r = _newResult(bullOne, bobBull, uint32(bullOne));
        r.tokenB = bullOne;
        _expectSubmitRevert(alice, r, abi.encodeWithSelector(Duel.SelfFight.selector));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Checked at SETTLEMENT, against live `ownerOf`
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A bull that changes hands between the quote and the submit is
     *         judged where it is NOW.
     *
     * @dev The signature was issued for a perfectly legal alice-vs-bob fight.
     *      Bob then hands his bull to alice. The same signature is now a
     *      self-duel and is refused — which is exactly what an off-chain check
     *      in `api/run-duel` could not have caught.
     */
    function test_aTransferInTurnsALegalFightIntoASelfDuel() public {
        Duel.DuelResult memory r = _newResult(bullOne, bobBull, uint32(bullOne));

        vm.prank(bob);
        bulls.transferFrom(bob, alice, bobBull);

        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.SelfDuelBlocked.selector, alice)
        );
    }

    /**
     * @notice ...and the mirror image. A signature that WAS a self-duel
     *         settles once the bull has moved out, on the same numbers.
     *
     * @dev Both sequence numbers still read zero afterwards because the
     *      signature named `seqA = 0` for alice and `seqB = 0` for whoever
     *      holds side B — and bob's sequence is also zero. Nothing about the
     *      signature had to change; only the world did.
     */
    function test_aTransferOutRescuesABlockedFight() public {
        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        assertEq(r.seqA, 0);
        assertEq(r.seqB, 1, "a same-wallet quote names seq and seq + 1");

        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.SelfDuelBlocked.selector, alice)
        );

        // Re-quote for the new world: side B now belongs to bob, whose
        // sequence is zero.
        vm.prank(alice);
        bulls.transferFrom(alice, bob, bullTwo);

        Duel.DuelResult memory fresh = _newResult(bullOne, bullTwo, uint32(bullOne));
        assertEq(fresh.seqB, 0, "the new holder's sequence is the one that counts");
        _submitAs(alice, fresh);

        assertEq(duelC.fightSeq(alice), 1);
        assertEq(duelC.fightSeq(bob), 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Flipping it on, and how it composes with the per-wallet sequence
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice "Flipping it on composes with the per-wallet sequence above
     *          without a special case: the two sequence numbers are then both
     *          that wallet's, consumed in order, so the signer names `seq` and
     *          `seq + 1`."
     */
    function test_flippingItOnLetsTheFightThroughAndTheSequencesCompose() public {
        vm.expectEmit(false, false, false, true, address(duelC));
        emit Duel.AllowSelfDuelChanged(true);
        duelC.setAllowSelfDuel(true);

        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        assertEq(r.seqA, 0);
        assertEq(r.seqB, 1);
        _submitAs(alice, r);

        assertEq(duelC.fightSeq(alice), 2, "one self-duel consumes two sequences");
    }

    /// @dev The sequence is consumed SEQUENTIALLY, so naming the same number
    ///      twice is refused even with the flag on. That is what stops a
    ///      self-duel spending one wallet's affordability twice.
    function test_withTheFlagOnTwoIdenticalSequencesAreStillRefused() public {
        duelC.setAllowSelfDuel(true);

        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        r.seqB = r.seqA; // both name zero

        _expectSubmitRevert(
            alice, r, abi.encodeWithSelector(Duel.StaleFightSeq.selector, alice, 1, 0)
        );
    }

    /// @dev A self-duel with real stakes is a wash for the wallet, less the
    ///      dev cut — which is precisely the "pays only the dev cut, buys a
    ///      full-odds ticket" economics the default-off flag exists to stop.
    function test_aSelfDuelWithStakesIsAWashLessTheDevCut() public {
        duelC.setAllowSelfDuel(true);
        _fundForFight(alice, 100e18, 0);

        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        r.assetA = address(bnbull);
        r.assetB = address(bnbull);
        r.stakeA = 10e18;
        r.stakeB = 10e18;

        uint256 before = bnbull.balanceOf(alice);
        _submitAs(alice, r);

        // 10% dev cut on each side: 20 in, 18 back.
        assertEq(before - bnbull.balanceOf(alice), 2e18, "the self-duel cost only the dev cut");
        assertEq(potBnbull.ticketCount(), 1, "...and it still bought a full-odds ticket");
        assertEq(potBnb.ticketCount(), 1);
    }

    function test_theFlagIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        duelC.setAllowSelfDuel(true);

        duelC.setAllowSelfDuel(true);
        assertTrue(duelC.allowSelfDuel());
        duelC.setAllowSelfDuel(false);
        assertFalse(duelC.allowSelfDuel());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The router path — equal owners that ARE the router is escrow
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A router escrows both bulls, so `ownerOf` reads the router on
     *         BOTH sides. Equality there is an artefact of custody, not a
     *         self-duel, and the fight settles.
     */
    function test_theRouterEscrowCaseIsNotASelfDuel() public {
        duelC.setAuthorizedRouter(address(routerMock));
        _escrowToRouter(bullOne);
        _escrowToRouter(bobBull);

        Duel.DuelResult memory r = _newResult(bullOne, bobBull, uint32(bullOne));
        assertEq(r.seqA, 0);
        assertEq(r.seqB, 1, "both sides are the router's, consumed in order");

        routerMock.submit(_asRouterResult(r), _sign(r));

        assertEq(duelC.fightSeq(address(routerMock)), 2);
        assertFalse(duelC.allowSelfDuel(), "and the flag never had to be flipped");
    }

    /// @dev With a router wired it is the SOLE entrypoint. The owner of a bull
    ///      can no longer submit directly.
    function test_onlyTheRouterMaySubmitWhenOneIsWired() public {
        duelC.setAuthorizedRouter(address(routerMock));

        Duel.DuelResult memory r = _newResult(bullOne, bobBull, uint32(bullOne));
        _expectSubmitRevert(alice, r, abi.encodeWithSelector(Duel.OnlyAuthorizedRouter.selector));
    }

    /**
     * @notice "Any OTHER pair of equal owners on this path is a genuine
     *          self-duel and is blocked here just the same."
     */
    function test_onTheRouterPathEqualOwnersThatAreNotTheRouterAreStillBlocked() public {
        duelC.setAuthorizedRouter(address(routerMock));

        // Both still alice's — the router is submitting, not escrowing.
        Duel.DuelResult memory r = _newResult(bullOne, bullTwo, uint32(bullOne));
        bytes memory sig = _sign(r);

        vm.expectRevert(abi.encodeWithSelector(Duel.SelfDuelBlocked.selector, alice));
        routerMock.submit(_asRouterResult(r), sig);
    }

    /// @dev The liveness valve: a broken router is removable in one
    ///      transaction, and the direct owner-submits path comes back.
    function test_unwiringTheRouterRestoresTheDirectPath() public {
        duelC.setAuthorizedRouter(address(routerMock));
        duelC.setAuthorizedRouter(address(0));

        _submit(_newResult(bullOne, bobBull, uint32(bullOne)));
        assertEq(duelC.fightSeq(alice), 1);
    }

    /**
     * @notice A DOCUMENTED CONSEQUENCE, pinned here so it cannot drift
     *         silently: on the router path the PLAYERS' sequences are never
     *         touched. Both `ownerOf` reads return the router, so the router's
     *         own counter is the one consumed — twice per fight.
     *
     * @dev That means the per-wallet affordability guarantee protects the
     *      ROUTER's balance on that path, not the players'. It follows
     *      directly from "every ownership-derived rule keys off these two
     *      reads", and a phase-2 router therefore has to run its own
     *      per-player accounting before it escrows. Not a defect — a property
     *      of the design that a future router author must know.
     */
    function test_onTheRouterPathThePlayersOwnSequencesAreUntouched() public {
        duelC.setAuthorizedRouter(address(routerMock));
        _escrowToRouter(bullOne);
        _escrowToRouter(bobBull);

        Duel.DuelResult memory r = _newResult(bullOne, bobBull, uint32(bullOne));
        routerMock.submit(_asRouterResult(r), _sign(r));

        assertEq(duelC.fightSeq(alice), 0, "the player's sequence moved on the router path");
        assertEq(duelC.fightSeq(bob), 0);
        assertEq(duelC.fightSeq(address(routerMock)), 2);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The direct path still needs skin in the game
    // ══════════════════════════════════════════════════════════════════════

    function test_aStrangerCannotSubmitOnTheDirectPath() public {
        Duel.DuelResult memory r = _newResult(bullOne, bobBull, uint32(bullOne));
        _expectSubmitRevert(carol, r, abi.encodeWithSelector(Duel.NotOwnerOfEither.selector));
    }

    function test_eitherSidesOwnerMaySubmit() public {
        _submitAs(bob, _newResult(bullOne, bobBull, uint32(bullOne)));
        assertEq(duelC.fightSeq(alice), 1);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _escrowToRouter(uint256 tokenId) internal {
        address holder = bulls.ownerOf(tokenId);
        vm.prank(holder);
        bulls.transferFrom(holder, address(routerMock), tokenId);
    }

    /// @dev The router mock speaks its own copy of the struct (file-level
    ///      declarations are hoisted, so it cannot reuse `Duel.DuelResult`).
    function _asRouterResult(Duel.DuelResult memory r)
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
