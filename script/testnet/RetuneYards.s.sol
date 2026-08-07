// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Yards} from "../../contracts/Yards.sol";
import {Duel} from "../../contracts/Duel.sol";

interface IBullsRead {
    function nextTokenId() external view returns (uint32);
    function ownerOf(uint256 tokenId) external view returns (address);
    function isAlive(uint256 tokenId) external view returns (bool);
}

/**
 * @title RetuneYards
 * @notice Swap the live `Yards` for one whose `MIN_EJECT_DELAY` is 5 minutes
 *         instead of 15, WITHOUT interrupting testing while the wiring
 *         timelock walks.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS SCRIPT EXISTS AT ALL — `MIN_EJECT_DELAY` IS A `constant`
 *      ══════════════════════════════════════════════════════════════════════
 *      The eject floor is not a setter. `setEjectDelay` is bounded BELOW by
 *      `MIN_EJECT_DELAY`, and that is `constant`, i.e. baked into the bytecode.
 *      So "make the eject 5 minutes" is not a configuration change: it is a
 *      REDEPLOY of `Yards` plus a rewire of `Duel.Wire.Yards`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE TRAP THIS SCRIPT IS SHAPED AROUND: THE REWIRE IS TIMELOCKED
 *      ══════════════════════════════════════════════════════════════════════
 *      `Duel.Wire.Yards` is a `TimelockedAddress.Slot`. `bootstrap` is
 *      immediate but ONLY while the slot is zero, and on any live deployment it
 *      is not zero. So a replacement must be `proposeWire` -> wait
 *      `Duel.wiringDelay` -> `commitWire`. That default is 24 HOURS, with a
 *      6 hour floor (`MIN_WIRING_DELAY`).
 *
 *      A NEW `Duel` WOULD NOT DODGE THIS, IT WOULD MULTIPLY IT. Deploying a
 *      fresh `Duel` does give a free `bootstrap` of its own Yards slot — but
 *      `Bulls.Wire.Duel` and `Graveyard.Wire.Duel` are timelocked too, and are
 *      already set, so the fresh `Duel` would then need TWO more 24h timelocks
 *      before it could kill or revive anything. Strictly worse, and it would
 *      also reset `fightSeq` under a signer that is mid-session.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      SO WHAT ACTUALLY BREAKS DURING THE WINDOW, AND WHAT DOES NOT
 *      ══════════════════════════════════════════════════════════════════════
 *      Two different readers resolve the roster from two different places, and
 *      that asymmetry is the whole reason this script does what it does:
 *
 *        - `Duel._requireInYards` AND the off-chain signer both resolve it from
 *          `Duel.yardsContract()`. `api/run-duel` reads that slot on purpose
 *          ("THE ROSTER ADDRESS IS READ OFF `Duel`, NOT OFF AN ENV VAR") so the
 *          pre-check is incapable of disagreeing with the contract. Until the
 *          timelock commits, BOTH still see the OLD yards.
 *
 *        - The UI resolves it from `NEXT_PUBLIC_YARDS`. Point that at the new
 *          contract and the pit page, the enter/eject buttons and the countdown
 *          all exercise the 5 minute delay TONIGHT.
 *
 *      The hazard that leaves is one-directional and specific: a bull entered
 *      ONLY in the new yards looks in-pit in the UI while the signer, reading
 *      the old yards, refuses to quote it a fight. That reads as "the new
 *      deploy is broken" and it is not.
 *
 *      **Step 3 of `_execute` is the fix.** Every living bull the broadcaster
 *      owns is (re-)entered into the OLD yards as a permissive backstop, so the
 *      signer says yes to anything the UI lets you put in the pit. It costs one
 *      transaction, it is invisible in the UI (which is reading the new
 *      contract), and it becomes inert the moment the rewire commits.
 *
 *      ⚠ WHAT THIS CANNOT PAPER OVER: while the window is open the ENFORCED
 *      eject is still the old contract's 15 minutes, because enforcement lives
 *      on whichever contract `Duel` points at. Tonight proves the 5 minute
 *      countdown and the UX around it; end-to-end enforcement of the 5 minute
 *      eject starts when `commitWire` lands.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ BULLS THIS SCRIPT CANNOT TOUCH
 *      ══════════════════════════════════════════════════════════════════════
 *      `Yards.enter` requires `bulls.ownerOf(id) == msg.sender`, so this only
 *      ever speaks for the broadcaster's own bulls. Any bull held by another
 *      test wallet must be re-entered by THAT wallet once `NEXT_PUBLIC_YARDS`
 *      moves, or it drops out of the pit in the UI. The script prints the exact
 *      list rather than failing, because it is a fact about the chain, not a
 *      fault in the deploy.
 */
contract RetuneYards is Script {
    uint256 internal constant CHAIN_BSC_TESTNET = 97;

    /// @notice What the retune is FOR. Asserted against the freshly deployed
    ///         bytecode so a stale `out/` artifact cannot ship the old floor.
    uint64 internal constant EXPECTED_EJECT_DELAY = 5 minutes;

    /**
     * @notice Testnet only: shorten the wiring timelock to its floor so the
     *         rewire can commit in 6 hours instead of 24.
     * @dev ⚠ MAINNET KEEPS 24 HOURS. The delay is the window in which holders
     *      can see a proposed rewire and react to it; 6h is a rehearsal
     *      convenience, not a setting to carry across. `MIN_WIRING_DELAY`
     *      bounds this, so the value is inside the contract's own envelope
     *      either way.
     */
    uint256 internal constant TESTNET_WIRING_DELAY = 6 hours;

    error NotBscTestnet(uint256 chainid);
    error NotTheDuelOwner(address caller, address duelOwner);
    error StaleBytecode(uint64 minEjectDelay, uint64 ejectDelay);
    error YardsAlreadyRetuned(address current);

    /// @dev Addresses resolved once and threaded through, so no single stack
    ///      frame has to hold them all. Written flat first and it was genuinely
    ///      `Stack too deep` — `via_ir` is off in `foundry.toml` and stays off.
    struct Ctx {
        address bulls;
        address duel;
        address oldYards;
        address sender;
    }

    function run() external {
        if (block.chainid != CHAIN_BSC_TESTNET) revert NotBscTestnet(block.chainid);

        Ctx memory ctx = _load();
        (uint256[] memory inPit, uint256[] memory mine) = _scanPit(ctx);
        _execute(ctx, inPit, mine);
    }

    /// @dev Resolve the deployment and refuse, BEFORE spending anything, on the
    ///      two conditions that make the run pointless or impossible.
    function _load() private view returns (Ctx memory ctx) {
        string memory json = vm.readFile("deployments/97.json");
        ctx.bulls = vm.parseJsonAddress(json, ".contracts.bulls");
        ctx.duel = vm.parseJsonAddress(json, ".contracts.duel");
        ctx.oldYards = vm.parseJsonAddress(json, ".contracts.yards");
        ctx.sender = msg.sender;

        // Only the owner may propose a wire or move the delay. Fail here rather
        // than after a `Yards` has already been deployed and paid for.
        address duelOwner = Duel(ctx.duel).owner();
        if (ctx.sender != duelOwner) revert NotTheDuelOwner(ctx.sender, duelOwner);

        // Refuse to run twice: a second run would strand a Yards on chain and
        // re-open a timelock for nothing.
        if (Yards(ctx.oldYards).MIN_EJECT_DELAY() == EXPECTED_EJECT_DELAY) {
            revert YardsAlreadyRetuned(ctx.oldYards);
        }

        console2.log("== retune Yards: 15 minute eject -> 5 minute eject ==");
        console2.log("  broadcaster        ", ctx.sender);
        console2.log("  bulls              ", ctx.bulls);
        console2.log("  duel               ", ctx.duel);
        console2.log("  yards (old)        ", ctx.oldYards);
        console2.log("  old MIN_EJECT_DELAY", Yards(ctx.oldYards).MIN_EJECT_DELAY());
        console2.log("  old ejectDelay     ", Yards(ctx.oldYards).ejectDelay());
        console2.log("  duel.wiringDelay   ", Duel(ctx.duel).wiringDelay());
        console2.log("");
    }

    /**
     * @dev Photograph the pit BEFORE anything changes. Two lists, deliberately
     *      different:
     *        inPit -> what the UI must still show afterwards. Re-entered into
     *                 the NEW yards so the visible state is preserved EXACTLY,
     *                 including which bulls are deliberately out.
     *        mine  -> every living bull the broadcaster owns. Entered into the
     *                 OLD yards as the signer-side backstop (see the header).
     */
    function _scanPit(Ctx memory ctx)
        private
        view
        returns (uint256[] memory inPit, uint256[] memory mine)
    {
        uint256 n = IBullsRead(ctx.bulls).nextTokenId();
        uint256[] memory inPitBuf = new uint256[](n);
        uint256[] memory mineBuf = new uint256[](n);
        uint256 inPitCount;
        uint256 mineCount;
        uint256 foreign;

        for (uint256 id = 1; id < n; ++id) {
            address holder = IBullsRead(ctx.bulls).ownerOf(id);
            bool live = Yards(ctx.oldYards).inYards(id);
            if (holder != ctx.sender) {
                if (live) {
                    foreign++;
                    console2.log("  [!] in the pit, NOT ours - that wallet re-enters itself");
                    console2.log("      token", id);
                    console2.log("      held by", holder);
                }
                continue;
            }
            if (live) inPitBuf[inPitCount++] = id;
            if (IBullsRead(ctx.bulls).isAlive(id)) mineBuf[mineCount++] = id;
        }

        inPit = _trim(inPitBuf, inPitCount);
        mine = _trim(mineBuf, mineCount);

        console2.log("  ours, in the pit right now :", inPitCount);
        console2.log("  ours, alive (backstop set) :", mineCount);
        console2.log("  someone elses, in the pit  :", foreign);
        console2.log("");
    }

    function _execute(Ctx memory ctx, uint256[] memory inPit, uint256[] memory mine) private {
        vm.startBroadcast();

        // ── 1. The new roster ────────────────────────────────────────────
        Yards newYards = new Yards(ctx.sender, ctx.bulls);

        // The deploy is worthless if `out/` was stale. Prove the bytecode that
        // actually landed carries the retuned floor before anything is wired to
        // it or any bull is entered into it.
        if (
            newYards.MIN_EJECT_DELAY() != EXPECTED_EJECT_DELAY
                || newYards.ejectDelay() != EXPECTED_EJECT_DELAY
        ) {
            revert StaleBytecode(newYards.MIN_EJECT_DELAY(), newYards.ejectDelay());
        }

        // ── 2. Restore the pit, exactly as it was ────────────────────────
        if (inPit.length != 0) newYards.enter(inPit);

        // ── 3. The signer-side backstop on the OLD yards ─────────────────
        //
        // See the header. This is what stops "the UI says it is in the pit but
        // the fight is refused" during the window. Entering also CANCELS any
        // pending eject on the old contract, which is exactly what is wanted:
        // the old contract's only job for the next few hours is to say yes.
        if (mine.length != 0) Yards(ctx.oldYards).enter(mine);

        // ── 4. Open the timelock ─────────────────────────────────────────
        //
        // ⚠ ORDER MATTERS. `propose` stamps `eta = block.timestamp +
        // wiringDelay` AT PROPOSE TIME, so the delay must be lowered FIRST or
        // the proposal carries the old 24 hours and lowering it afterwards
        // changes nothing.
        Duel(ctx.duel).setWiringDelay(TESTNET_WIRING_DELAY);
        uint64 eta = Duel(ctx.duel).proposeWire(Duel.Wire.Yards, address(newYards));

        vm.stopBroadcast();

        _report(ctx, address(newYards), eta);
    }

    function _report(Ctx memory ctx, address newYards, uint64 eta) private view {
        console2.log("== done ==");
        console2.log("  yards (new)        ", newYards);
        console2.log("  MIN_EJECT_DELAY    ", Yards(newYards).MIN_EJECT_DELAY());
        console2.log("  ejectDelay         ", Yards(newYards).ejectDelay());
        console2.log("  rewire committable ", eta);
        console2.log("  now                ", block.timestamp);
        console2.log("");
        console2.log("== NOT FINISHED. TWO THINGS LEFT ==");
        console2.log("  1. Point the site at the new roster, then rebuild/redeploy:");
        console2.log("       frontend/.env.local  NEXT_PUBLIC_YARDS=", newYards);
        console2.log("     Until then the UI still drives the 15 minute contract.");
        console2.log("  2. AFTER the eta above, commit the rewire (Wire.Yards == 4):");
        console2.log("       cast send <duel> commitWire(uint8) 4   <- duel is:", ctx.duel);
        console2.log("     THAT is what makes 5 minutes enforceable. Until it lands,");
        console2.log("     Duel AND the signer both still gate on the OLD yards.");
    }

    /// @dev Solidity cannot shrink a memory array in place, so the scan
    ///      oversizes and copies. `n` is the collection size, not user input.
    function _trim(uint256[] memory buf, uint256 count)
        private
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buf[i];
        }
    }
}

/**
 * @title EnterMyBulls
 * @notice Put every living bull the CALLER owns into whichever `Yards` the
 *         deployment record currently names. Idempotent.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHY THIS IS A SEPARATE ENTRY POINT AND NOT PART OF THE RETUNE
 *      ══════════════════════════════════════════════════════════════════════
 *      `Yards.enter` reverts `NotTokenOwner` unless `bulls.ownerOf(id) ==
 *      msg.sender`. There is no operator path, no `enterFor`, and that is the
 *      point of the contract — nobody can volunteer somebody else's bull for a
 *      fight. So a roster swap CANNOT be completed by the deployer alone: every
 *      wallet holding bulls has to speak for its own.
 *
 *      On chain 97 that is not academic. At the time of the retune the majority
 *      of the bulls in the pit were held by a second test wallet, so after
 *      `NEXT_PUBLIC_YARDS` moves they vanish from the pit page until that
 *      wallet runs this. Nothing is lost and nothing is broken — the default is
 *      OUT and a new roster starts empty, exactly as on deploy day.
 *
 *      Run it once per wallet:
 *
 *        forge script script/testnet/RetuneYards.s.sol:EnterMyBulls \
 *          --rpc-url $RPC_URL_TESTNET --broadcast --slow \
 *          --account bnbulls-testnet-player --password-file <path>
 *
 *      ⚠ It reads the roster address from `deployments/97.json`, so update that
 *      record BEFORE running it or it will helpfully re-enter everything into
 *      the contract you are trying to leave behind.
 *
 *      ⚠ It skips bulls that are already in, so it never disturbs a pending
 *      eject you meant to keep — `enter` would silently CANCEL one.
 */
contract EnterMyBulls is Script {
    error NothingToEnter(address wallet);

    function run() external {
        string memory json = vm.readFile("deployments/97.json");
        address bullsAddr = vm.parseJsonAddress(json, ".contracts.bulls");
        address yardsAddr = vm.parseJsonAddress(json, ".contracts.yards");
        address sender = msg.sender;

        console2.log("== enter my bulls ==");
        console2.log("  wallet", sender);
        console2.log("  yards ", yardsAddr);
        console2.log("  MIN_EJECT_DELAY", Yards(yardsAddr).MIN_EJECT_DELAY());

        uint256 n = IBullsRead(bullsAddr).nextTokenId();
        uint256[] memory buf = new uint256[](n);
        uint256 count;

        for (uint256 id = 1; id < n; ++id) {
            if (IBullsRead(bullsAddr).ownerOf(id) != sender) continue;
            if (!IBullsRead(bullsAddr).isAlive(id)) continue;
            // Already in and staying? Leave it alone — see the header.
            if (Yards(yardsAddr).inYards(id)) continue;
            buf[count++] = id;
        }

        if (count == 0) revert NothingToEnter(sender);

        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = buf[i];
            console2.log("  entering", ids[i]);
        }

        vm.startBroadcast();
        Yards(yardsAddr).enter(ids);
        vm.stopBroadcast();

        console2.log("  entered", count);
    }
}
