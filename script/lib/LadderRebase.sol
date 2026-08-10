// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MintDrop} from "../../contracts/MintDrop.sol";

/**
 * @title LadderRebase
 * @notice Moves a `MintDrop` price ladder onto a fresh contract whose
 *         `totalSold` restarts at zero.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      ⚠ THIS IS THE STEP THAT SILENTLY COSTS MONEY IF IT IS SKIPPED
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop.priceForMint(n)` prices the **n-th sale made by that
 *      contract**, and `_quote` calls it with `totalSold + 1`. A replacement
 *      drop starts `totalSold = 0`. So a ladder copied across verbatim restarts
 *      the whole ladder: with 31 bulls already gone and a first rung of
 *      `upToSold: 100`, the $10 rung would run for ANOTHER 100 sales instead of
 *      the 69 that remain, and roughly thirty bulls would sell at $10 that
 *      should have sold at $20.
 *
 *      Nothing reverts, nothing logs, and it is not recoverable afterwards —
 *      those buyers keep their bulls. It is only visible if somebody happens to
 *      compare the rung boundary against the collection's own mint counter,
 *      which is exactly the sort of thing a human does not do at the end of a
 *      six-step deploy.
 *
 *      It lives in its own file, as a pure function over a plain array, for one
 *      reason: so a test can drive it directly. A rebase that can only be
 *      exercised by running the deploy script is a rebase that gets tested on
 *      mainnet.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE THREE RULES
 *      ══════════════════════════════════════════════════════════════════════
 *      1. **Boundaries move down by `minted`. Dollar stickers never move.**
 *         A rebase that changes a price is a re-pricing wearing a rebase's
 *         clothes, and it is not what anybody approved.
 *      2. **A rung already fully spent is dropped, not zeroed.**
 *         `setPriceTiers` requires strictly ascending `upToSold`, so a zero
 *         boundary would revert `InvalidTiers` — but more importantly a rung
 *         covering "sales 1 to 0" is meaningless.
 *      3. **The last boundary is raised to `lastMustCover`, not clamped to what
 *         remains.** `setPriceTiers` reverts `InvalidTiers` unless the final
 *         rung reaches `MAX_MINT`, and there is deliberately no flat-price
 *         fallback — so a table that stopped at the true remaining supply would
 *         leave the tail UNPRICED and every mint past it reverting `NotPriced`.
 *         The real cap is the pen's own `PoolTooSmall`, which is a count of
 *         bulls that physically exist, so the extra headroom is unreachable
 *         rather than loose.
 */
library LadderRebase {
    error NoTiers();
    error EveryRungSpent(uint256 minted);

    /**
     * @param live         The ladder as it stands on the outgoing contract.
     * @param minted       Sales the outgoing contract's ladder has already
     *                     accounted for — i.e. how far down the ladder the
     *                     collection actually is.
     * @param lastMustCover `MintDrop.MAX_MINT`. See rule 3.
     */
    function rebase(MintDrop.PriceTier[] memory live, uint256 minted, uint16 lastMustCover)
        internal
        pure
        returns (MintDrop.PriceTier[] memory out)
    {
        uint256 n = live.length;
        if (n == 0) revert NoTiers();

        MintDrop.PriceTier[] memory tmp = new MintDrop.PriceTier[](n);
        uint256 kept;
        for (uint256 i = 0; i < n; i++) {
            if (uint256(live[i].upToSold) <= minted) continue; // rule 2
            tmp[kept] = MintDrop.PriceTier({
                upToSold: uint16(uint256(live[i].upToSold) - minted), // rule 1
                usdPrice: live[i].usdPrice,
                bnbullPrice: live[i].bnbullPrice
            });
            kept++;
        }
        if (kept == 0) revert EveryRungSpent(minted);

        out = new MintDrop.PriceTier[](kept);
        for (uint256 i = 0; i < kept; i++) {
            out[i] = tmp[i];
        }
        if (out[kept - 1].upToSold < lastMustCover) out[kept - 1].upToSold = lastMustCover; // rule 3
    }
}
