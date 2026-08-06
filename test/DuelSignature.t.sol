// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DuelGraveyardBase} from "./DuelGraveyardBase.t.sol";
import {Duel} from "../contracts/Duel.sol";

/**
 * @title DuelSignatureTest
 * @notice PRIORITY 3. The contract VERIFIES a duel, it does not fight one.
 *
 * @dev ⚠ MOCKS ONLY, NO FORK. See `DuelGraveyardBase`.
 *
 *      `BNBULLS-BOOTSTRAP.md §5`: "`submitDuel` does `ECDSA.recover(
 *      hashDuelResult(result), sig) == trustedSigner` and checks `winnerId ∈
 *      {0, tokenA, tokenB}`. It NEVER re-runs the combat sim on-chain."
 *
 *      So the signature IS the game. Four things have to hold:
 *        1. only `trustedSigner` can produce a settleable result;
 *        2. `winnerId` cannot name a bull that is not in the fight;
 *        3. a nonce burns, and an expiry expires;
 *        4. **rotating the signer kills every outstanding signature in ONE
 *           transaction** — the slot is a plain setter on purpose, because a
 *           24-hour timelock on a leaked signing key is 24 hours of an
 *           attacker signing whatever they like.
 *
 *      Plus the typehash. `DUEL_RESULT_TYPEHASH` is duplicated field-for-field
 *      in `frontend/src/app/api/run-duel/route.ts`, and `Duel.sol` warns the
 *      two must stay byte-identical or every fight reverts `InvalidSignature`.
 *      `test_theTypehashMatchesTheDocumentedTypesArray` rebuilds the digest
 *      from the documented field list, with no help from the contract, so a
 *      one-character drift fails here rather than on launch day.
 */
contract DuelSignatureTest is DuelGraveyardBase {
    uint256 internal aliceBull;
    uint256 internal bobBull;

    /// @dev Rebuilt from the `types.DuelResult` array in the contract's own
    ///      off-chain workflow comment. NOT copied from the constant.
    bytes32 internal constant DOC_TYPEHASH = keccak256(
        "DuelResult(uint256 tokenA,uint256 tokenB,uint32 winnerId,uint16 rounds,uint256 seed,uint32 newEloA,uint32 newEloB,address assetA,address assetB,uint256 stakeA,uint256 stakeB,uint64 seqA,uint64 seqB,uint256 nonce,uint256 expiry)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function setUp() public override {
        super.setUp();
        aliceBull = _mintBull(alice);
        bobBull = _mintBull(bob);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Only the trusted signer
    // ══════════════════════════════════════════════════════════════════════

    function test_aResultSignedByAnyoneElseIsRefused() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory rogue = _signWith(duelC, ROGUE_PK, r);

        vm.prank(alice);
        vm.expectRevert(Duel.InvalidSignature.selector);
        duelC.submitDuel(r, rogue);
    }

    function test_aMalformedSignatureIsRefused() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));

        vm.prank(alice);
        vm.expectRevert();
        duelC.submitDuel(r, hex"deadbeef");
    }

    /// @dev Every signed field is covered by the digest, so touching any of
    ///      them after signing invalidates it. The seed and the ELOs matter
    ///      most: they are what the replay re-simulator checks against.
    function test_tamperingWithAnySignedFieldBreaksTheSignature() public {
        for (uint256 i = 0; i < 6; i++) {
            Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
            bytes memory sig = _sign(r);

            if (i == 0) r.seed += 1;
            else if (i == 1) r.rounds += 1;
            else if (i == 2) r.newEloA += 1;
            else if (i == 3) r.newEloB += 1;
            else if (i == 4) r.nonce += 1_000;
            else r.seqA = r.seqA; // control: unchanged, must SETTLE

            if (i == 5) {
                vm.prank(alice);
                duelC.submitDuel(r, sig);
                assertEq(duelC.fightSeq(alice), 1, "the control case must settle");
            } else {
                vm.prank(alice);
                vm.expectRevert(Duel.InvalidSignature.selector);
                duelC.submitDuel(r, sig);
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The typehash and the domain
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice The digest, rebuilt from the documented field list with no help
     *         from the contract.
     *
     * @dev If `DUEL_RESULT_TYPEHASH` or the EIP-712 domain ever drifts from
     *      what the signer in `api/run-duel` hands viem, this is the test that
     *      catches it — and it catches it before deploy, which matters because
     *      Fighting Fefers still carries "Stable WarriorsDuel" scars from
     *      renaming a domain after launch.
     */
    function test_theTypehashMatchesTheDocumentedTypesArray() public view {
        Duel.DuelResult memory r = _newResultView();

        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    DOC_TYPEHASH, r.tokenA, r.tokenB, r.winnerId, r.rounds, r.seed, r.newEloA,
                    r.newEloB
                ),
                abi.encode(
                    r.assetA, r.assetB, r.stakeA, r.stakeB, r.seqA, r.seqB, r.nonce, r.expiry
                )
            )
        );

        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("BNBullsDuel")),
                keccak256(bytes("1")),
                block.chainid,
                address(duelC)
            )
        );
        assertEq(domain, duelC.domainSeparator(), "the EIP-712 domain drifted");

        bytes32 expected = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        assertEq(duelC.hashDuelResult(r), expected, "the DuelResult typehash drifted");
    }

    /**
     * @notice A signature is bound to ONE deployment. A testnet signature
     *         cannot be replayed on mainnet and a v2 Duel cannot honour v1
     *         signatures.
     */
    function test_aSignatureDoesNotTransferToAnotherDeployment() public {
        Duel other = _newDuel(address(bulls));

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r); // signed against `duelC`'s domain

        assertTrue(
            duelC.domainSeparator() != other.domainSeparator(),
            "two deployments share a domain separator"
        );

        vm.prank(alice);
        vm.expectRevert(Duel.InvalidSignature.selector);
        other.submitDuel(r, sig);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  `winnerId ∈ {0, tokenA, tokenB}`
    // ══════════════════════════════════════════════════════════════════════

    function test_aWinnerOutsideTheFightIsRefused() public {
        uint256 stranger = _mintBull(carol);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(stranger));
        _expectSubmitRevert(alice, r, abi.encodeWithSelector(Duel.InvalidWinnerId.selector));

        r = _newResult(aliceBull, bobBull, type(uint32).max);
        _expectSubmitRevert(alice, r, abi.encodeWithSelector(Duel.InvalidWinnerId.selector));
    }

    function test_zeroIsATieAndIsAccepted() public {
        _submit(_newResult(aliceBull, bobBull, 0));
        assertEq(duelC.consecutiveLosses(aliceBull), 0);
        assertEq(duelC.consecutiveLosses(bobBull), 0);
        assertEq(potBnbull.ticketCount(), 0, "a tie opens no ticket");
        assertEq(potBnb.ticketCount(), 0);
    }

    function test_eitherFighterMayWin() public {
        _submit(_newResult(aliceBull, bobBull, uint32(aliceBull)));
        assertEq(duelC.consecutiveLosses(bobBull), 1);
        _submit(_newResult(aliceBull, bobBull, uint32(bobBull)));
        assertEq(duelC.consecutiveLosses(aliceBull), 1);
        assertEq(duelC.consecutiveLosses(bobBull), 0, "a win clears the loser's streak");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Nonces and expiry
    // ══════════════════════════════════════════════════════════════════════

    function test_aNonceBurnsOnUse() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        assertFalse(duelC.usedNonces(r.nonce));
        _submit(r);
        assertTrue(duelC.usedNonces(r.nonce));

        // Replaying the identical result hits the NONCE first, which is the
        // right order: the sequence error would be misleading here.
        bytes memory sig = _sign(r);
        vm.prank(alice);
        vm.expectRevert(Duel.NonceAlreadyUsed.selector);
        duelC.submitDuel(r, sig);
    }

    /// @dev A DIFFERENT result reusing a spent nonce is refused too, so a
    ///      nonce is a one-shot no matter what it is attached to.
    function test_aSpentNonceCannotBeRecycledOntoANewResult() public {
        Duel.DuelResult memory first = _newResult(aliceBull, bobBull, uint32(aliceBull));
        _submit(first);

        Duel.DuelResult memory second = _newResult(aliceBull, bobBull, uint32(bobBull));
        second.nonce = first.nonce;
        _expectSubmitRevert(alice, second, abi.encodeWithSelector(Duel.NonceAlreadyUsed.selector));
    }

    function test_expiryIsEnforced() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        vm.warp(r.expiry + 1);
        _expectSubmitRevert(alice, r, abi.encodeWithSelector(Duel.Expired.selector));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Rotating the signer — one transaction, no timelock, on purpose
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice A leaked signing key has to be rotatable in one transaction.
     *
     * @dev "A 24-hour timelock on this slot is 24 hours of an attacker signing
     *      whatever they like." So this is deliberately NOT one of the
     *      `TimelockedAddress` wires, and the proof that the rotation actually
     *      bites is that a signature issued a moment earlier is dead the
     *      instant the setter lands — same block, no waiting.
     */
    function test_rotatingTheSignerKillsOutstandingSignaturesImmediately() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r);

        vm.expectEmit(true, true, false, false, address(duelC));
        emit Duel.TrustedSignerChanged(signer, rogueSigner);
        duelC.setTrustedSigner(rogueSigner);

        vm.prank(alice);
        vm.expectRevert(Duel.InvalidSignature.selector);
        duelC.submitDuel(r, sig);

        // ...and the new key works from that same moment.
        bytes memory fresh = _signWith(duelC, ROGUE_PK, r);
        vm.prank(alice);
        duelC.submitDuel(r, fresh);
        assertEq(duelC.fightSeq(alice), 1);
    }

    /// @dev Recovery is stateless: rotating back revives the old key's
    ///      signatures. Nothing is stored per-signature, only per-signer.
    function test_rotatingBackRevivesTheOldKeysSignatures() public {
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r);

        duelC.setTrustedSigner(rogueSigner);
        duelC.setTrustedSigner(signer);

        vm.prank(alice);
        duelC.submitDuel(r, sig);
        assertEq(duelC.fightSeq(alice), 1);
    }

    function test_theSignerCanNeverBeZeroAndIsOwnerOnly() public {
        vm.expectRevert(Duel.SignerMustBeNonZero.selector);
        duelC.setTrustedSigner(address(0));

        vm.prank(alice);
        vm.expectRevert();
        duelC.setTrustedSigner(alice);

        assertEq(duelC.trustedSigner(), signer);
    }

    /**
     * @notice The blast radius of a compromised signer, bounded.
     *
     * @dev "a bad signer can only produce results that are publicly
     *      re-simulatable from the seed, and it can never exceed
     *      `maxFightCostOf` or move a bull it does not have an allowance for."
     *      Both halves are checked here.
     */
    function test_aCompromisedSignerStillCannotExceedTheAssetCeiling() public {
        duelC.setTrustedSigner(rogueSigner);
        _fundForFight(alice, MAX_COST_BNBULL * 10, 0);
        _fundForFight(bob, MAX_COST_BNBULL * 10, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(bobBull));
        r.assetA = address(bnbull);
        r.assetB = address(0);
        r.stakeA = MAX_COST_BNBULL + 1;
        bytes memory sig = _signWith(duelC, ROGUE_PK, r);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Duel.FightCostTooHigh.selector, MAX_COST_BNBULL + 1)
        );
        duelC.submitDuel(r, sig);
    }

    function test_aCompromisedSignerCannotReachPastAnAllowance() public {
        duelC.setTrustedSigner(rogueSigner);

        // Bob holds plenty but has approved nothing.
        bnbull.mint(bob, 1_000e18);
        _fundForFight(alice, 100e18, 0);

        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        r.assetB = address(bnbull);
        r.stakeB = 50e18;
        bytes memory sig = _signWith(duelC, ROGUE_PK, r);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Duel.StakeNotApproved.selector, bob, address(bnbull), uint256(50e18), uint256(0)
            )
        );
        duelC.submitDuel(r, sig);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Liveness gates that sit alongside the signature
    // ══════════════════════════════════════════════════════════════════════

    function test_aDeadBullCannotFight() public {
        uint256 victim = _mintBull(carol);
        _killBull(victim, bobBull);

        Duel.DuelResult memory r = _newResult(victim, aliceBull, uint32(aliceBull));
        _expectSubmitRevert(
            carol, r, abi.encodeWithSelector(Duel.BullNotAlive.selector, victim)
        );
    }

    function test_pausingStopsNewFightsButNotThePotLock() public {
        duelC.pause();
        Duel.DuelResult memory r = _newResult(aliceBull, bobBull, uint32(aliceBull));
        bytes memory sig = _sign(r);
        vm.prank(alice);
        vm.expectRevert();
        duelC.submitDuel(r, sig);

        // `claimJackpotForDuel` is deliberately NOT `whenNotPaused`: pausing
        // new duels must not freeze payouts on tickets already in flight.
        uint256 key = duelC.duelJackpotKey(999);
        vm.prank(address(potBnbull));
        assertTrue(duelC.claimJackpotForDuel(key));

        duelC.unpause();
        _submit(_newResult(aliceBull, bobBull, uint32(aliceBull)));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev A fixed result for the pure-hash test. Deliberately does NOT read
    ///      live sequences, so the test is `view` and the digest is stable.
    function _newResultView() internal view returns (Duel.DuelResult memory r) {
        r = Duel.DuelResult({
            tokenA: 1,
            tokenB: 2,
            winnerId: 1,
            rounds: 9,
            seed: 0xC0FFEE,
            newEloA: 1_234,
            newEloB: 987,
            assetA: address(bnbull),
            assetB: address(wbnb),
            stakeA: 10e18,
            stakeB: 900e18,
            seqA: 3,
            seqB: 7,
            nonce: 42,
            expiry: 1_800_000_000
        });
    }
}
