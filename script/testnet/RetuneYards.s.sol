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
 *      **Step 4 below is the fix.** Every living bull the broadcaster owns is
 *      (re-)entered into the OLD yards as a permissive backstop, so the signer
 *      says yes to anything the UI lets you put in the pit. It costs one
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

    function run() external {
        if (block.chainid != CHAIN_BSC_TESTNET) revert NotBscTestnet(block.chainid);

        string memory json = vm.readFile("deployments/97.json");
        address bullsAddr = vm.parseJsonAddress(json, ".contracts.bulls");
        address duelAddr = vm.parseJsonAddress(json, ".contracts.duel");
        address oldYardsAddr = vm.parseJsonAddress(json, ".contracts.yards");

        Duel duel = Duel(payable(duelAddr));
        Yards oldYards = Yards(oldYardsAddr);
        IBullsRead bullsC = IBullsRead(bullsAddr);

        address sender = msg.sender;
        // Only the owner can propose a wire or set the delay. Fail here, before
        // a deploy is broadcast and paid for, rather than three transactions in.
        if (sender != duel.owner()) revert NotTheDuelOwner(sender, duel.owner());

        // Refuse to run twice. If `Duel` already points at a 5-minute yards
        // there is nothing to do, and a second run would deploy a stray
        // contract and re-open a timelock for no reason.
        if (oldYards.MIN_EJECT_DELAY() == EXPECTED_EJECT_DELAY) {
            revert YardsAlreadyRetuned(oldYardsAddr);
        }

        console2.log("== retune Yards: 15 minute eject -> 5 minute eject ==");
        console2.log("  broadcaster ", sender);
        console2.log("  bulls       ", bullsAddr);
        console2.log("  duel        ", duelAddr);
        console2.log("  yards (old) ", oldYardsAddr);
        console2.log("  old MIN_EJECT_DELAY", oldYards.MIN_EJECT_DELAY());
        console2.log("  old ejectDelay     ", oldYards.ejectDelay());
        console2.log("");

        // ── 1. Photograph the pit BEFORE anything changes ────────────────
        //
        // Two lists, and they are deliberately different:
        //   inPit    -> what the UI must still show after the swap. Re-entered
        //               into the NEW yards so the visible state is preserved
        //               EXACTLY, including which bulls are deliberately out.
        //   mine     -> every living bull the broadcaster owns. Entered into
        //               the OLD yards as the signer-side backstop described in
        //               the header.
        uint256 n = bullsC.nextTokenId();
        uint256[] memory inPitBuf = new uint256[](n);
        uint256[] memory mineBuf = new uint256[](n);
        uint256 inPitCount;
        uint256 mineCount;
        uint256 foreignInPit;

        for (uint256 id = 1; id < n; ++id) {
            address holder = bullsC.ownerOf(id);
            bool live = oldYards.inYards(id);
            if (holder != sender) {
                if (live) {
                    foreignInPit++;
                    console2.log("  [!] in pit but NOT ours - that wallet must re-enter:", id, holder);
                }
                continue;
            }
            if (live) inPitBuf[inPitCount++] = id;
            if (bullsC.isAlive(id)) mineBuf[mineCount++] = id;
        }

        uint256[] memory inPit = _trim(inPitBuf, inPitCount);
        uint256[] memory mine = _trim(mineBuf, mineCount);

        console2.log("  ours, in the pit right now :", inPitCount);
        console2.log("  ours, alive (backstop set) :", mineCount);
        console2.log("  someone else's, in the pit :", foreignInPit);
        console2.log("");

        vm.startBroadcast();

        // ── 2. The new roster ────────────────────────────────────────────
        Yards newYards = new Yards(sender, bullsAddr);

        // The deploy is worthless if `out/` was stale. Prove the bytecode that
        // actually landed carries the retuned floor before anything is wired to
        // it or any bull is entered into it.
        if (
            newYards.MIN_EJECT_DELAY() != EXPECTED_EJECT_DELAY
                || newYards.ejectDelay() != EXPECTED_EJECT_DELAY
        ) {
            revert StaleBytecode(newYards.MIN_EJECT_DELAY(), newYards.ejectDelay());
        }

        // ── 3. Restore the pit, exactly as it was ────────────────────────
        if (inPitCount != 0) newYards.enter(inPit);

        // ── 4. The signer-side backstop on the OLD yards ─────────────────
        //
        // See the header. This is what stops "the UI says it is in the pit but
        // the fight is refused" during the window. Entering also CANCELS any
        // pending eject on the old contract, which is exactly what we want: the
        // old contract's job for the next few hours is to say yes.
        if (mineCount != 0) oldYards.enter(mine);

        // ── 5. Open the timelock ─────────────────────────────────────────
        //
        // ⚠ ORDER MATTERS. `propose` stamps `eta = block.timestamp + wiringDelay`
        // AT PROPOSE TIME, so the delay must be lowered FIRST or the proposal
        // carries the old 24 hours and lowering it afterwards changes nothing.
        duel.setWiringDelay(TESTNET_WIRING_DELAY);
        uint64 eta = duel.proposeWire(Duel.Wire.Yards, address(newYards));

        vm.stopBroadcast();

        console2.log("== done ==");
        console2.log("  yards (new)        ", address(newYards));
        console2.log("  MIN_EJECT_DELAY    ", newYards.MIN_EJECT_DELAY());
        console2.log("  ejectDelay         ", newYards.ejectDelay());
        console2.log("  rewire committable ", eta);
        console2.log("  (now)              ", block.timestamp);
        console2.log("");
        console2.log("== YOU ARE NOT FINISHED. TWO THINGS LEFT ==");
        console2.log("  1. Point the site at the new roster and redeploy:");
        console2.log("       frontend/.env.local  NEXT_PUBLIC_YARDS=", address(newYards));
        console2.log("     Until you do, the UI still drives the 15 minute contract.");
        console2.log("  2. AFTER the eta above, commit the rewire:");
        console2.log("       cast send <duel> 'commitWire(uint8)' 4 --account bnbulls-owner ...");
        console2.log("     THAT is the transaction that makes 5 minutes enforceable.");
        console2.log("     Until it lands, Duel and the signer still gate on the OLD yards.");
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
