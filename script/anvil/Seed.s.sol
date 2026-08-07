// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BnbullsConfig} from "../lib/BnbullsConfig.sol";
import {Bulls} from "../../contracts/Bulls.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";
import {Duel} from "../../contracts/Duel.sol";
import {Graveyard} from "../../contracts/Graveyard.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";
import {Marketplace} from "../../contracts/Marketplace.sol";
import {Yards} from "../../contracts/Yards.sol";
import {LocalWBNB, LocalVRFCoordinator} from "./mocks/LocalMocks.sol";

/**
 * @title Seed
 * @notice Give the local chain real state to render: mint in all three
 *         currencies, fight, kill a bull, revive it, resolve a jackpot ticket,
 *         and leave a listing standing.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY IT SEEDS THIS EXACT SEQUENCE
 *      ══════════════════════════════════════════════════════════════════════
 *      Every step is a leg of the money layer whose failure mode is SILENT:
 *
 *        - mint with BNB     -> the single-hop WBNB->BNBULL swap leg and the
 *                               WBNB wrap leg
 *        - mint with BNBULL  -> `DECISIONS.md §14`: 30/0/70 and NO DEX call
 *        - three fights      -> the dev-cut direct pot legs, and death on the
 *                               third consecutive loss
 *        - revive            -> Graveyard -> ReviveBuySplitter -> both pots
 *        - VRF fulfil        -> a ticket actually resolving
 *
 *      Watch the run for `PotDeferred` / `PotSliceFailed`. Those events are
 *      what a missing funder role or a stale floor looks like in production,
 *      and `Verify.s.sol` should already have caught the cause.
 *
 *      ⚠ ANVIL ONLY. It signs duel results with a well-known test key and
 *      refuses to run on any chain but 31337.
 */
contract Seed is BnbullsConfig {
    error NotAnvil(uint256 chainid);

    /// @dev anvil account 0. A published test key, worthless anywhere real.
    uint256 internal constant ANVIL_PK_0 =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    /// @dev anvil account 1 — the opponent, so no fight is a self-duel
    ///      (`DECISIONS.md §16` blocks those by default).
    uint256 internal constant ANVIL_PK_1 =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    Deployment internal d;
    address internal wbnbAddr;
    address internal vrfAddr;

    address internal alice; // account 0 — also the deployer/owner
    address internal bob; // account 1

    function run() external {
        if (block.chainid != CHAIN_ANVIL) revert NotAnvil(block.chainid);

        d = readDeployment();
        string memory json = vm.readFile(deploymentPath());
        wbnbAddr = vm.parseJsonAddress(json, ".ext.wbnb");
        vrfAddr = vm.parseJsonAddress(json, ".ext.vrfCoordinator");

        alice = vm.addr(ANVIL_PK_0);
        bob = vm.addr(ANVIL_PK_1);

        console2.log("== seeding the local chain ==");
        console2.log("  alice (owner/deployer)", alice);
        console2.log("  bob   (opponent)      ", bob);

        _mint();
        _prepareStakes();
        _fightUntilDead();
        _revive();
        _resolveJackpot();
        _list();
        _report();
    }

    // ─── 1. Mint, in both currencies ────────────────────────────────────

    function _mint() private {
        MintDrop m = MintDrop(d.mintDrop);
        (uint256 usd, uint256 bnbDue, uint256 bnbullDue, uint256 px) = m.quote(1);
        console2.log("");
        console2.log("-- mint --");
        console2.log("  BNB/USD 1e18", px);
        console2.log("  1 bull  usd ", usd);
        console2.log("          bnb ", bnbDue);
        console2.log("          bull", bnbullDue);

        // Alice: two bulls with BNB. Overpay so the refund path runs too.
        vm.startBroadcast(ANVIL_PK_0);
        m.mintWithBNB{value: bnbDue * 3}(alice, 1);
        (, uint256 bnb2,,) = m.quote(1);
        m.mintWithBNB{value: bnb2 * 3}(alice, 1);

        // Alice: one with BNBULL. `§14` — this one must touch NO DEX at all.
        (,, uint256 bull3,) = m.quote(1);
        IERC20(d.bnbull).approve(d.mintDrop, type(uint256).max);
        m.mintWithBNBULL(alice, 1);
        vm.stopBroadcast();

        // Bob: one with BNB.
        (, uint256 bnb4,,) = m.quote(2);
        vm.startBroadcast(ANVIL_PK_0);
        (bool ok,) = bob.call{value: 10 ether}("");
        require(ok, "fund bob");
        IERC20(d.bnbull).transfer(bob, 2_000_000e18);
        vm.stopBroadcast();

        vm.startBroadcast(ANVIL_PK_1);
        m.mintWithBNB{value: bnb4 * 3}(bob, 1);
        vm.stopBroadcast();

        console2.log("  bnbull leg cost", bull3);
        console2.log("  minted:", Bulls(d.bulls).nextTokenId() - 1);
    }

    // ─── 2. Stakes, and consent ─────────────────────────────────────────

    /**
     * @dev ⚠ THE APPROVAL IS NO LONGER ENOUGH, AND THAT IS THE POINT OF
     *      `Yards.sol`. Arena membership USED to be the ERC-20 allowance —
     *      wallet-wide, and skipped entirely by a zero-stake duel. It is now a
     *      per-bull standing instruction that only the LIVE owner can give,
     *      defaulting to OUT, so a seed that only approves would have every
     *      `submitDuel` below revert `BullNotInYards`.
     *
     *      This is the local rehearsal of the readiness step the UI does in one
     *      transaction: `approve` the stake asset AND `enter` the bulls.
     */
    function _prepareStakes() private {
        Duel du = Duel(d.duel);
        uint256 wbnbCost = du.fighterCost(wbnbAddr);

        // Both sides need WBNB and an allowance. Alice could pay natively (the
        // convenience path only works for `msg.sender`'s own side), but wrapping
        // both keeps the two duels symmetrical.
        vm.startBroadcast(ANVIL_PK_0);
        LocalWBNB(payable(wbnbAddr)).deposit{value: wbnbCost * 20}();
        IERC20(wbnbAddr).approve(d.duel, type(uint256).max);
        IERC20(d.bnbull).approve(d.duel, type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(ANVIL_PK_1);
        LocalWBNB(payable(wbnbAddr)).deposit{value: wbnbCost * 20}();
        IERC20(wbnbAddr).approve(d.duel, type(uint256).max);
        IERC20(d.bnbull).approve(d.duel, type(uint256).max);
        vm.stopBroadcast();

        // Into the yards. Alice's #1 and bob's #4 are the two that fight; each
        // is entered by its OWN owner, because `enter` checks `ownerOf` live
        // and an operator approval does not let one wallet volunteer another's
        // bull for combat.
        uint256[] memory hers = new uint256[](1);
        hers[0] = 1;
        uint256[] memory his = new uint256[](1);
        his[0] = 4;

        vm.startBroadcast(ANVIL_PK_0);
        Yards(d.yards).enter(hers);
        vm.stopBroadcast();

        vm.startBroadcast(ANVIL_PK_1);
        Yards(d.yards).enter(his);
        vm.stopBroadcast();

        console2.log("");
        console2.log("-- yards --");
        console2.log("  #1 in", Yards(d.yards).inYards(1));
        console2.log("  #4 in", Yards(d.yards).inYards(4));
        console2.log("  #2 in (never entered, stays OUT)", Yards(d.yards).inYards(2));
    }

    // ─── 3. Three fights, and bull #1 dies on the third ─────────────────

    function _fightUntilDead() private {
        Duel du = Duel(d.duel);
        uint8 threshold = du.lossesToDie();
        console2.log("");
        console2.log("-- duels --");
        console2.log("  lossesToDie", threshold);

        // Fight 1 in BNBULL: the dev cut is ALREADY the BNBULL pot's prize
        // token, so it is routed straight in and nothing is sold (`§14`).
        _fight(1, 4, d.bnbull, du.fighterCost(d.bnbull), 1);

        // The rest in WBNB: the dev cut is already the OTHER pot's prize token.
        for (uint256 i = 2; i <= threshold; i++) {
            _fight(1, 4, wbnbAddr, du.fighterCost(wbnbAddr), i);
        }

        bool dead = Bulls(d.bulls).isDead(1);
        console2.log("  bull #1 dead:", dead);
        require(dead, "seed: bull #1 should be dead");
    }

    /// @dev Bull `a` (alice) LOSES to bull `b` (bob). Signed by the trusted
    ///      signer exactly as `frontend/api/run-duel` would.
    function _fight(uint256 a, uint256 b, address asset, uint256 stake, uint256 nonce) private {
        Duel du = Duel(d.duel);

        Duel.DuelResult memory r = Duel.DuelResult({
            tokenA: a,
            tokenB: b,
            winnerId: uint32(b),
            rounds: 5,
            seed: uint256(keccak256(abi.encode("bnbulls-local-seed", nonce))),
            newEloA: 1_000 - uint32(nonce) * 12,
            newEloB: 1_000 + uint32(nonce) * 12,
            assetA: asset,
            assetB: asset,
            stakeA: stake,
            stakeB: stake,
            seqA: du.nextFightSeq(alice),
            seqB: du.nextFightSeq(bob),
            nonce: nonce,
            expiry: block.timestamp + 1 hours
        });

        bytes32 digest = du.hashDuelResult(r);
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(ANVIL_PK_0, digest);
        bytes memory sig = abi.encodePacked(rs, ss, v);

        // Alice owns bull A, so alice may submit.
        vm.startBroadcast(ANVIL_PK_0);
        du.submitDuel(r, sig);
        vm.stopBroadcast();

        console2.log("  fight", nonce, "settled; stake asset", asset);
    }

    // ─── 4. Revive ──────────────────────────────────────────────────────

    function _revive() private {
        Graveyard g = Graveyard(d.graveyard);
        (bool allowed, uint256 used, uint256 ownerUsd,,) = g.quoteResurrect(1);
        require(allowed, "seed: bull #1 out of lives");
        (uint256 bnbDue,,) = g.quotePayment(ownerUsd);

        console2.log("");
        console2.log("-- revive --");
        console2.log("  lives used", used);
        console2.log("  rung usd  ", ownerUsd);
        console2.log("  bnb due   ", bnbDue);

        // Overpay; the oracle cushion comes back last, after the bull stands.
        vm.startBroadcast(ANVIL_PK_0);
        g.resurrectWithBNB{value: bnbDue * 2}(1);
        vm.stopBroadcast();

        require(!Bulls(d.bulls).isDead(1), "seed: revive failed");
        console2.log("  bull #1 is alive again");
    }

    // ─── 5. Resolve a jackpot ticket ────────────────────────────────────

    /**
     * @dev The full VRF round trip: request -> fulfil -> resolve. Locally the
     *      coordinator is ours, so the word is whatever we hand it.
     *
     *      ⚠ The pot only accepts a word from its TIMELOCKED
     *      `_coordinatorWire` (`DECISIONS.md §18`). That is why this works with
     *      the coordinator the constructor was given and would NOT work with a
     *      second coordinator bolted on afterwards — which is exactly the
     *      hand-pick-a-winner attack the timelock closed.
     */
    function _resolveJackpot() private {
        console2.log("");
        console2.log("-- jackpot --");
        _resolveOne(Jackpot(d.jackpotBnbull), "BNBULL pot");
        _resolveOne(Jackpot(d.jackpotBnb), "BNB pot");
    }

    function _resolveOne(Jackpot p, string memory tag) private {
        console2.log(string.concat("  ", tag));
        console2.log("    pool         ", p.pool());
        console2.log("    tickets      ", p.ticketCount());
        console2.log("    pending      ", p.pendingTickets());

        if (!p.requestable()) {
            console2.log("    nothing to request");
            return;
        }

        vm.startBroadcast(ANVIL_PK_0);
        p.requestResolve(10);
        vm.stopBroadcast();

        LocalVRFCoordinator vrf = LocalVRFCoordinator(vrfAddr);
        vm.startBroadcast(ANVIL_PK_0);
        vrf.fulfillPending(uint256(keccak256(abi.encode("bnbulls-local-word", tag))));
        p.resolve(10);
        vm.stopBroadcast();

        console2.log("    resolved; awards so far", p.awardCount());
        console2.log("    pool now              ", p.pool());
    }

    // ─── 6. Leave a listing standing ────────────────────────────────────

    function _list() private {
        Marketplace mk = Marketplace(payable(d.marketplace));
        Bulls b = Bulls(d.bulls);

        // Bull #2 is alice's and has never fought, so it is not listed-locked
        // and not dead. `Duel.setMarketplace` means a LISTED bull cannot fight,
        // which is the point of the lockout.
        vm.startBroadcast(ANVIL_PK_0);
        b.approve(d.marketplace, 2);
        mk.list(2, 250e18, Marketplace.BnbullMode.Pegged, 0);
        vm.stopBroadcast();

        console2.log("");
        console2.log("-- marketplace --");
        console2.log("  bull #2 listed at $250, BNBULL leg pegged");
        // ⚠ The first return is the USD sticker, not a token amount. Getting
        // that destructuring wrong is how a UI renders "250 BNB" for a $250
        // listing — the exact shape of the fefers decimals bug, one slot over.
        (uint256 usd, uint256 bnbDue, uint256 bnbullDue,) = mk.quote(2);
        console2.log("  sticker usd   ", usd);
        console2.log("  buy-now in BNB", bnbDue);
        console2.log("  buy-now BNBULL", bnbullDue);
    }

    // ─── Report ─────────────────────────────────────────────────────────

    function _report() private view {
        Bulls b = Bulls(d.bulls);
        MintDrop m = MintDrop(d.mintDrop);

        console2.log("");
        console2.log("== local chain state ==");
        console2.log("  bulls minted    ", b.nextTokenId() - 1);
        console2.log("  mintDrop sold   ", m.totalSold());
        console2.log("  #1", b.nameOf(1), b.isDead(1) ? "(dead)" : "(alive)");
        console2.log("  #2", b.nameOf(2));
        console2.log("  #4", b.nameOf(4));
        console2.log("  BNBULL pot pool ", Jackpot(d.jackpotBnbull).pool());
        console2.log("  BNB pot pool    ", Jackpot(d.jackpotBnb).pool());
        console2.log("");
        console2.log("  A pool of 0 with tickets open means a buyback DEFERRED.");
        console2.log("  Check the run for PotDeferred / PotSliceFailed and re-read");
        console2.log("  script/Verify.s.sol - that is the silent failure this whole");
        console2.log("  package exists to catch.");
    }
}
