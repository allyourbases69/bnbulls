// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title Xorshift128+ PRNG (SplitMix64-seeded)
 * @notice Byte-identical port of `src/core/rng.ts`. Any given (seed, sequence
 *         of calls) must produce the same output in both implementations.
 *
 * @dev PORTED FROM FIGHTING FEFERS UNCHANGED. This file is the rarity shuffle
 *      and the stat roll. Touching it re-rolls every bull. Do not "improve" it.
 *
 *      `unchecked` everywhere on purpose: all xorshift operations rely on
 *      natural modulo-2^64 wraparound, which is what JavaScript's `& MASK_64`
 *      does. Safe because we only work with uint64 values.
 */
library Xorshift {
    /// @notice Mutable RNG state (two 64-bit words).
    struct State {
        uint64 s0;
        uint64 s1;
    }

    /**
     * @notice Initialize a new RNG state from a seed using SplitMix64.
     * @param seed Any uint256. Internally mixed down to two uint64 words.
     * @return state New RNG state. Guaranteed non-zero (the degenerate
     *         (0,0) state is replaced with (1,2)).
     */
    function create(uint256 seed) internal pure returns (State memory state) {
        unchecked {
            // First SplitMix64 iteration -> s0
            uint64 z = uint64(seed) + 0x9e3779b97f4a7c15;
            z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
            uint64 s0 = z ^ (z >> 31);

            // Second SplitMix64 iteration seeded from s0 -> s1
            z = s0 + 0x9e3779b97f4a7c15;
            z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
            uint64 s1 = z ^ (z >> 31);

            // Guard against the degenerate all-zeros state.
            if (s0 == 0 && s1 == 0) {
                state.s0 = 1;
                state.s1 = 2;
            } else {
                state.s0 = s0;
                state.s1 = s1;
            }
        }
    }

    /**
     * @notice Advance the RNG and return the next uint64 value.
     * @dev MUTATES the passed-in state.
     */
    function nextUint64(State memory state) internal pure returns (uint64 result) {
        unchecked {
            uint64 s1 = state.s0;
            uint64 s0 = state.s1;
            result = s0 + s1;
            state.s0 = s0;
            s1 = s1 ^ (s1 << 23);
            state.s1 = s1 ^ s0 ^ (s1 >> 17) ^ (s0 >> 26);
        }
    }

    /**
     * @notice Return an integer in [min, max] inclusive using rejection sampling.
     * @dev Reverts on min > max.
     */
    function nextInt(State memory state, int256 min, int256 max)
        internal
        pure
        returns (int256 result)
    {
        require(min <= max, "Xorshift: min > max");
        if (min == max) {
            return min;
        }
        unchecked {
            // range fits in uint256 because (max - min + 1) <= 2^256 - 1
            uint256 range = uint256(max - min + 1);
            // Ranges larger than 2^64 would make maxValid 0 and the reject
            // loop would never terminate. Game usage never hits this.
            require(range <= (uint256(1) << 64), "Xorshift: range too large");
            // Largest multiple of range that fits in uint64.
            uint256 maxValid = ((uint256(1) << 64) / range) * range;
            uint256 roll;
            do {
                roll = uint256(nextUint64(state));
            } while (roll >= maxValid);
            result = min + int256(roll % range);
        }
    }

    /**
     * @notice Pick a weighted index. Equivalent to weightedPick in TS.
     */
    function weightedPick(State memory state, uint256[] memory weights)
        internal
        pure
        returns (uint256 index)
    {
        require(weights.length > 0, "Xorshift: empty weights");
        uint256 total = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            total += weights[i];
        }
        require(total > 0, "Xorshift: zero total weight");
        // nextInt returns a value in [0, total - 1]
        uint256 roll = uint256(nextInt(state, 0, int256(total - 1)));
        uint256 cumulative = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            cumulative += weights[i];
            if (roll < cumulative) {
                return i;
            }
        }
        // Unreachable if total > 0.
        revert("Xorshift: unreachable");
    }

    /**
     * @notice Roll count * dN + bonus. TTRPG-style dice notation.
     */
    function dice(State memory state, uint256 count, uint256 sides, int256 bonus)
        internal
        pure
        returns (int256 total)
    {
        require(count > 0 && sides > 0, "Xorshift: invalid dice");
        total = bonus;
        for (uint256 i = 0; i < count; i++) {
            total += nextInt(state, 1, int256(sides));
        }
    }
}
