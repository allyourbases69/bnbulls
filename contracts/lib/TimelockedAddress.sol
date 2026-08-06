// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title TimelockedAddress
 * @notice A single re-settable address slot with a timelock on every change
 *         after the first.
 *
 * @dev THIS EXISTS BECAUSE OF A SPECIFIC, EXPENSIVE FIGHTING FEFERS MISTAKE.
 *      The live fefers NFT wired its Duel and Graveyard with a ONE-TIME-SET
 *      (`if (duelContract != address(0)) revert AlreadySet();`). The intent
 *      was good — a stolen owner key cannot repoint the wiring at a malicious
 *      contract — but the cost was that `CONSECUTIVE_LOSSES_TO_DIE = 3` and
 *      every other number frozen into those contracts became permanent. A
 *      later request for a 4-loss death threshold was flat impossible without
 *      redeploying the collection.
 *
 *      `BNBULLS-BOOTSTRAP.md §0` / `BUILD-PLAN.md` rule 2 therefore require
 *      every wiring leg to be **two-step propose/accept or timelocked, never
 *      one-time-set**. Propose/accept is wrong here: the target of a wiring
 *      slot is a game contract, not an EOA, and it cannot call `accept`. So
 *      the pattern is a timelock:
 *
 *        - while the slot is still zero (deploy day), `bootstrap` sets it
 *          immediately, so wiring a fresh deployment is not a two-day job;
 *        - once it holds an address, ANY change must be `propose`d, wait out
 *          `delay`, and then be `commit`ted. The pending target and its ETA
 *          are public the whole time, so a compromised key cannot repoint the
 *          money silently — holders get the full delay to react;
 *        - `cancel` drops a pending change.
 *
 *      Events are deliberately NOT declared here. Internal library functions
 *      are inlined into the caller, so an event declared in a library is
 *      emitted under the caller's address but is missing from the caller's
 *      ABI, which quietly breaks indexers. Each contract declares and emits
 *      its own.
 */
library TimelockedAddress {
    struct Slot {
        /// @notice The live address. Zero means "never wired".
        address current;
        /// @notice Proposed replacement, zero when nothing is pending.
        address pending;
        /// @notice Earliest timestamp `commit` may run. Zero when idle.
        uint64 eta;
    }

    /// @dev `bootstrap` called on a slot that already holds an address.
    error AlreadyWired(address current);
    /// @dev A wiring target of zero is never meaningful.
    error ZeroTarget();
    /// @dev `commit`/`cancel` with nothing proposed.
    error NothingPending();
    /// @dev `commit` before the timelock elapsed.
    error TimelockNotElapsed(uint64 eta, uint64 nowTs);

    /**
     * @notice First-time wiring. Immediate, and only while the slot is empty.
     */
    function bootstrap(Slot storage s, address target) internal {
        if (s.current != address(0)) revert AlreadyWired(s.current);
        if (target == address(0)) revert ZeroTarget();
        s.current = target;
        // A bootstrap always clears any stale proposal.
        s.pending = address(0);
        s.eta = 0;
    }

    /**
     * @notice Propose a replacement. Overwrites any existing proposal and
     *         restarts the clock, so the published ETA is always the real one.
     * @param delay Seconds the proposal must age before it can be committed.
     * @return eta Timestamp at which `commit` becomes callable.
     */
    function propose(Slot storage s, address target, uint256 delay) internal returns (uint64 eta) {
        if (target == address(0)) revert ZeroTarget();
        eta = uint64(block.timestamp + delay);
        s.pending = target;
        s.eta = eta;
    }

    /**
     * @notice Commit a matured proposal.
     * @return previous The address being replaced.
     * @return next The address now live.
     */
    function commit(Slot storage s) internal returns (address previous, address next) {
        next = s.pending;
        if (next == address(0)) revert NothingPending();
        uint64 eta = s.eta;
        if (block.timestamp < eta) revert TimelockNotElapsed(eta, uint64(block.timestamp));
        previous = s.current;
        s.current = next;
        s.pending = address(0);
        s.eta = 0;
    }

    /**
     * @notice Drop a pending proposal.
     * @return dropped The target that was cancelled.
     */
    function cancel(Slot storage s) internal returns (address dropped) {
        dropped = s.pending;
        if (dropped == address(0)) revert NothingPending();
        s.pending = address(0);
        s.eta = 0;
    }
}
