// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {IERC20Fork, IVRFCoordinatorV2_5Fork} from "./ForkInterfaces.sol";

import {Jackpot} from "../../contracts/Jackpot.sol";

/**
 * @notice Stands in for `Duel` so tickets can be opened and the one-pot-per-
 *         duel lock can answer, without deploying the whole game.
 *
 * @dev It must be a CONTRACT and not an EOA. `Jackpot._claimDuel` treats an
 *      unreachable lock as DENIED — a low-level call to an EOA returns success
 *      with empty returndata, which reads as "the other pot already paid", so
 *      an EOA stub silently makes every ticket lose. That is the right
 *      failure direction for production and a very confusing one in a test.
 */
contract DuelStub {
    mapping(uint256 => bool) public paid;

    function claimJackpotForDuel(uint256 duelKey) external returns (bool) {
        if (duelKey == 0) return false;
        if (paid[duelKey]) return false;
        paid[duelKey] = true;
        return true;
    }
}

/**
 * @title VrfV25ForkTest
 * @notice Chainlink VRF v2.5 against the LIVE BSC coordinator, as far as a
 *         fork can honestly go.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  ⚠ WHAT A FORK CANNOT DO, STATED UP FRONT
 * ══════════════════════════════════════════════════════════════════════════
 *
 * VRF is a two-party protocol and only one party is on chain. A fork can
 * drive the coordinator; it cannot make Chainlink's off-chain node observe a
 * fork and answer it. So these are **out of reach here and belong on the
 * testnet / mainnet rehearsal checklist**:
 *
 *   1. **Real fulfilment.** No node watches this fork, so
 *      `fulfillRandomWords` is never delivered by the real oracle. The tests
 *      below reach the callback by impersonating the coordinator, which
 *      proves OUR side of the handshake and nothing about THEIRS.
 *   2. **Real latency.** "A couple of blocks later" cannot be measured; the
 *      keeper's `requestTimeoutBlocks` and `publicRequestDelayBlocks` can
 *      only be validated against real fulfilment times on testnet.
 *   3. **The real price of a request.** v2.5 charges at fulfilment, against
 *      the LINK/native premium and the gas lane. A fork request never
 *      fulfils, so it never bills, so the per-fight cost `BNB-CHAIN-FACTS §4`
 *      asks us to "put a number on" cannot be measured here.
 *   4. **Whether the keyHash's lane is actually being served** on BSC today.
 *      The coordinator accepting a keyHash proves the proving key is
 *      REGISTERED, not that an operator is answering it.
 *   5. **Subscription funding through the real LINK ERC-677
 *      `transferAndCall`** — reachable, but the balance it credits is only
 *      spent at fulfilment, so it proves plumbing, not economics.
 *
 * What the fork CAN prove is the half that a mock coordinator cannot: that
 * the request our contract builds is one the REAL coordinator accepts, and
 * that its own bounds are the real ones.
 */
contract VrfV25ForkTest is ForkBase {
    IVRFCoordinatorV2_5Fork internal constant coord =
        IVRFCoordinatorV2_5Fork(A.VRF_COORDINATOR_V2_5);

    Jackpot internal pot;
    uint256 internal subId;

    address internal duelStub;

    function setUp() public override {
        super.setUp();
        duelStub = address(new DuelStub());
        pot = new Jackpot(A.WBNB, address(0), A.VRF_COORDINATOR_V2_5, 50);
        pot.bootstrapDuel(duelStub);
        pot.setRequester(keeper, true);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. Our ceilings vs the coordinator's — read, never assumed
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE CONFIG BOUNDS OUR SETTER ENFORCES ARE THE COORDINATOR'S
     *         OWN. Read off the live contract.
     *
     * @dev `Jackpot.setVrfConfig` bounds `callbackGasLimit` at 2,500,000 and
     *      `requestConfirmations` at [3, 200]. If those did not match the
     *      coordinator, a config could pass our validation and be rejected at
     *      request time — and the request happens on the duel path, where a
     *      revert is the one thing that must never happen.
     *
     *      `MockVRFCoordinator` has whatever limits we gave it, so the mock
     *      suite cannot check this. Only the deployed coordinator can.
     */
    function test_ourVrfBoundsAreTheLiveCoordinatorsOwnBounds() public view {
        (uint16 minConfs, uint32 maxGas,,,,,,,) = coord.s_config();

        console2.log("coordinator minimumRequestConfirmations:", minConfs);
        console2.log("coordinator maxGasLimit:", maxGas);

        assertEq(
            uint256(pot.MAX_CALLBACK_GAS_LIMIT()),
            uint256(maxGas),
            "our callback-gas ceiling is not the coordinator's"
        );
        assertEq(
            uint256(pot.MIN_REQUEST_CONFIRMATIONS()),
            uint256(minConfs),
            "our confirmations floor is not the coordinator's"
        );
    }

    /// @notice The coordinator our contract will actually talk to is the
    ///         timelocked one, and it is the address in `BNB-CHAIN-FACTS §4`.
    function test_theWiredCoordinatorIsTheLiveOne() public view {
        (address current, address pending,) = pot.coordinatorWire();
        assertEq(current, A.VRF_COORDINATOR_V2_5, "coordinator wire is not the live one");
        assertEq(pending, address(0), "a coordinator change is already pending at deploy");
        assertGt(A.VRF_COORDINATOR_V2_5.code.length, 0, "the coordinator has no code");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. A REAL request, on a REAL subscription
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE FURTHEST A FORK GOES: create a real subscription on the
     *         real coordinator, fund it with real BNB, add our Jackpot as a
     *         real consumer, and have the Jackpot make a real request.
     *
     * @dev This is the half of the handshake that is genuinely testable, and
     *      it catches the deploy bugs that actually happen: a keyHash that is
     *      not a registered proving key on THIS chain, a consumer that was
     *      never added, a `numWords`/`extraArgs` encoding the coordinator
     *      rejects. Every one of those would be invisible against a mock and
     *      would surface for the first time on a live duel.
     */
    function test_theLiveCoordinatorAcceptsTheRequestOurContractBuilds() public {
        _openSubscriptionAndTicket();

        vm.prank(keeper);
        uint256 requestId = pot.requestResolve(10);

        assertGt(requestId, 0, "the live coordinator returned no request id");
        assertEq(pot.pendingRequestId(), requestId, "the request was not recorded");
        console2.log("live VRF requestId:", requestId);

        (, uint96 nativeBal, uint64 reqCount,,) = coord.getSubscription(subId);
        console2.log("subscription native balance (wei):", nativeBal);
        console2.log("subscription reqCount:", reqCount);
    }

    /**
     * @notice A consumer that was never added to the subscription is refused
     *         BY THE COORDINATOR.
     *
     * @dev The single most common VRF deploy mistake: the contract ships, the
     *      subscription is funded, and nobody clicks "Add consumer". A mock
     *      coordinator has no consumer registry, so the mock suite cannot
     *      model it at all.
     *
     *      ⚠ AND THE THING THAT MATTERS MORE THAN THE REVERT: the duel path
     *      does NOT call `requestResolve`. Opening a ticket is a storage push
     *      with no external call, so an unregistered consumer cannot revert a
     *      fight — it only stalls the queue, which a keeper (or, after
     *      `publicRequestDelayBlocks`, anyone) can clear later.
     */
    function test_anUnregisteredConsumerIsRefusedByTheCoordinatorAndTheDuelPathSurvives() public {
        vm.prank(owner);
        subId = coord.createSubscription();
        coord.fundSubscriptionWithNative{ value: 1 ether }(subId);
        // Deliberately NOT: coord.addConsumer(subId, address(pot));
        vm.deal(address(this), 10 ether);

        pot.setVrfConfig(A.VRF_KEY_HASH_200_GWEI, subId, 3, 200_000, true);

        // A fight still settles: opening a ticket touches nothing external.
        vm.prank(duelStub);
        uint256 ticketId = pot.recordWin(alice, 1, uint256(keccak256("entropy")), 1);
        assertEq(ticketId, 0, "the ticket was not opened");

        // Only the keeper's request fails, and it fails loudly.
        vm.prank(keeper);
        vm.expectRevert();
        pot.requestResolve(10);
    }

    /**
     * @notice ⚠ FINDING: the live coordinator ACCEPTS A KEYHASH IT HAS NEVER
     *         HEARD OF. A typo'd gas lane does not revert — it produces a
     *         request that will simply never be answered.
     *
     * @dev This is the opposite of what the test was written to expect, and
     *      it is worse. A rejected keyHash would be a loud, five-minute deploy
     *      bug. An ACCEPTED one that no operator serves is a silent one: the
     *      request id is real, `pendingRequestId` is set, `RequestInFlight`
     *      then blocks every subsequent request, and the whole jackpot queue
     *      wedges until `requestTimeoutBlocks` lets someone cancel it.
     *
     *      Mitigation already in the tree: `requestTimeoutBlocks` plus the
     *      permissionless retry after `publicRequestDelayBlocks`, so the wedge
     *      is recoverable. The deploy-time defence is to check the keyHash
     *      against `BNB-CHAIN-FACTS §4` by hand — nothing on chain will do it
     *      for you.
     *
     *      Added to the testnet rehearsal checklist: a request on the real
     *      keyHash must be OBSERVED to fulfil. Acceptance is not fulfilment.
     */
    function test_FINDING_anUnknownKeyHashIsAcceptedAndWouldNeverBeFulfilled() public {
        _openSubscriptionAndTicket();
        pot.setVrfConfig(keccak256("not a real proving key"), subId, 3, 200_000, true);

        vm.prank(keeper);
        uint256 id = pot.requestResolve(10);

        assertGt(id, 0, "the coordinator rejected an unknown keyHash after all");
        assertEq(pot.pendingRequestId(), id, "the bad request was not recorded as in-flight");
        console2.log("a keyHash nobody serves still produced request id:", id);

        // And the wedge it causes, which is the actual operational risk.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.RequestInFlight.selector, id));
        pot.requestResolve(10);
    }

    /**
     * @notice ⚠ THE REMEDY FOR THE FINDING ABOVE, and it is one `eth_call`.
     *
     * @dev `requestRandomWords` never consults the proving-key registry, but
     *      the registry is public. `s_provingKeys(keyHash)` answers
     *      `(exists, maxGas)`, so a keyHash typo IS catchable at deploy time —
     *      just not by the request. This test asserts the check that the
     *      deploy pre-flight should be making, and asserts it against all
     *      three lanes `BNB-CHAIN-FACTS §4` names, in order.
     *
     *      It upgrades those three addresses from `✔ found` (read off a docs
     *      page) to `✔ registered on the live coordinator, with the gas lane
     *      the name claims`.
     */
    function test_theThreeDocumentedKeyHashesAreRegisteredWithTheGasLanesTheyName() public view {
        (bool exists200, uint64 gas200) = coord.s_provingKeys(A.VRF_KEY_HASH_200_GWEI);
        assertTrue(exists200, "the 200 gwei keyHash is not a registered proving key");
        assertEq(gas200, 200 gwei, "the 200 gwei lane does not price at 200 gwei");

        assertEq(
            coord.s_provingKeyHashes(0),
            A.VRF_KEY_HASH_200_GWEI,
            "the coordinator's lane list no longer starts with the 200 gwei lane"
        );
        assertEq(
            coord.s_provingKeyHashes(1),
            0xeb0f72532fed5c94b4caf7b49caf454b35a729608a441101b9269efb7efe2c6c,
            "the 500 gwei lane moved"
        );
        assertEq(
            coord.s_provingKeyHashes(2),
            0xb94a4fdb12830e15846df59b27d7c5d92c9c24c10cf6ae49655681ba560848dd,
            "the 1000 gwei lane moved"
        );

        // And the check that would have caught the typo.
        (bool bogus,) = coord.s_provingKeys(keccak256("not a real proving key"));
        assertFalse(bogus, "an invented keyHash reads as registered");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. Our side of the callback
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice ⚠ THE WORD MUST COME FROM THE TIMELOCKED COORDINATOR — and
     *         "timelocked" is doing work the base class does not.
     *
     * @dev Two guards, one behind the other, and the second is ours:
     *
     *        1. `VRFConsumerBaseV2Plus.rawFulfillRandomWords` refuses anyone
     *           who is not `s_vrfCoordinator` (`OnlyCoordinatorCanFulfill`).
     *        2. `Jackpot.fulfillRandomWords` then refuses anyone who is not
     *           `_coordinatorWire.current` (`UntrustedCoordinator`).
     *
     *      Guard 1 alone is NOT enough, and this test is the proof:
     *      `setCoordinator` on the base class is `onlyOwnerOrCoordinator` and
     *      **instant**. An owner with a stolen key can point `s_vrfCoordinator`
     *      at an address they control in one transaction and hand-deliver a
     *      chosen word — which is exactly the attack `DECISIONS.md §18`
     *      closed. Guard 2 is timelocked, so the swap has to be announced days
     *      in advance.
     */
    function test_aSwappedCoordinatorCannotHandPickTheWord() public {
        _openSubscriptionAndTicket();
        vm.prank(keeper);
        uint256 requestId = pot.requestResolve(10);

        uint256[] memory words = new uint256[](1);
        words[0] = 12345;

        // A stranger is stopped by the base class.
        vm.prank(stranger);
        vm.expectRevert();
        pot.rawFulfillRandomWords(requestId, words);

        // The owner swaps the base coordinator in ONE transaction - allowed,
        // instant, and useless, because the timelocked wire still disagrees.
        pot.setCoordinator(stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.UntrustedCoordinator.selector, stranger));
        pot.rawFulfillRandomWords(requestId, words);

        assertFalse(pot.wordReady(), "a hand-picked word was accepted");
        (address wired,,) = pot.coordinatorWire();
        assertEq(wired, A.VRF_COORDINATOR_V2_5, "the timelocked wire moved without a timelock");
    }

    /**
     * @notice The full request → fulfil → resolve → PAY cycle, with the real
     *         coordinator's address delivering the word.
     *
     * @dev ⚠ HONESTY NOTE, AND IT MATTERS: the word here is delivered by
     *      `vm.prank(coordinator)`, not by Chainlink. What this proves is
     *      that OUR contract, holding a REAL prize token (WBNB), wired to the
     *      REAL coordinator address, resolves and pays correctly once a word
     *      arrives. It proves nothing about whether a word ever will. See the
     *      file header, item 1.
     *
     *      The word is chosen by search so the ticket wins — the payout math
     *      is what is under test, not the odds.
     */
    function test_aDeliveredWordResolvesTheBatchAndPaysARealPrizeToken() public {
        _openSubscriptionAndTicket();

        // Fund the pot with REAL WBNB, wrapped from real BNB.
        _giveWbnb(address(this), 5 ether);
        IERC20Fork(A.WBNB).approve(address(pot), type(uint256).max);
        pot.topUp(5 ether);
        assertEq(pot.pool(), 5 ether, "the pot is not holding real WBNB");

        vm.prank(keeper);
        uint256 requestId = pot.requestResolve(10);

        uint256 winningWord = _findWinningWord(0, alice, 1, uint256(keccak256("entropy")));
        uint256[] memory words = new uint256[](1);
        words[0] = winningWord;

        vm.prank(A.VRF_COORDINATOR_V2_5);
        pot.rawFulfillRandomWords(requestId, words);
        assertTrue(pot.wordReady(), "the word was not stored");

        uint256 before = IERC20Fork(A.WBNB).balanceOf(alice);
        pot.resolve(10);

        uint256 paid = IERC20Fork(A.WBNB).balanceOf(alice) - before;
        assertGt(paid, 0, "a winning ticket paid nothing");
        assertEq(paid, pot.totalAwarded(), "accounting != the real transfer");
        assertEq(pot.pool(), IERC20Fork(A.WBNB).balanceOf(address(pot)), "pot != real balance");
        console2.log("real WBNB paid to the winner (wei):", paid);
    }

    /// @notice A word for a stale request is discarded, not applied. The
    ///         late-fulfilment case a real network produces and a mock does
    ///         not.
    function test_aWordForAStaleRequestIsDiscarded() public {
        _openSubscriptionAndTicket();
        vm.prank(keeper);
        uint256 requestId = pot.requestResolve(10);

        uint256[] memory words = new uint256[](1);
        words[0] = 999;

        vm.prank(A.VRF_COORDINATOR_V2_5);
        pot.rawFulfillRandomWords(requestId + 1, words);

        assertFalse(pot.wordReady(), "a stale word was accepted");
        assertEq(pot.pendingRequestId(), requestId, "the live request was dropped");
    }

    // ─── Fixtures ─────────────────────────────────────────────────────────

    function _openSubscriptionAndTicket() internal {
        vm.deal(address(this), 100 ether);
        subId = coord.createSubscription();
        coord.addConsumer(subId, address(pot));
        coord.fundSubscriptionWithNative{ value: 5 ether }(subId);

        pot.setVrfConfig(A.VRF_KEY_HASH_200_GWEI, subId, 3, 200_000, true);

        vm.prank(duelStub);
        pot.recordWin(alice, 1, uint256(keccak256("entropy")), 1);
    }

    /// @dev Search for a word that makes ticket `id` a winner. The roll
    ///      preimage includes `address(this)` on the POT (see `Jackpot.resolve`),
    ///      so the search has to be done against the deployed pot's address.
    function _findWinningWord(uint256 id, address winner, uint256 tokenId, uint256 entropy)
        internal
        view
        returns (uint256)
    {
        for (uint256 w = 1; w < 5_000; w++) {
            uint256 roll = uint256(
                keccak256(abi.encodePacked(w, entropy, tokenId, winner, id, address(pot)))
            ) % pot.oddsOneIn();
            if (roll == 0) return w;
        }
        revert("no winning word found in the search window");
    }
}
