'use client';

import { useMemo } from 'react';
import { useMintedBulls } from './useMintedBulls';
import { ranksForIds, rankIndex, type RankedBull } from '@/lib/rank';

/**
 * THE RARITY RANK OF EVERY MINTED BULL, computed in the browser.
 *
 * Fefers does this on the server (`lib/rankCache.ts`): a 5-minute cache with
 * single-flight, in front of a walk that reads `getOutlaw` + `getOutlawWeapon`
 * for every minted token off an rpc pool. bnbulls does not need any of that
 * machinery, and the reason is a real data difference worth stating:
 *
 *   **fefers has to ASK the chain for a token's traits. bnbulls can DERIVE
 *   them.** `Bulls._initializeRarity()`, `_rollWeaponInTier()` and `_rollStats()`
 *   are all ported into `lib/art/bull.ts` / `lib/rank.ts` and pinned against a
 *   real `Bulls` by `npm run verify:rarity` (`DECISIONS.md §27`). So the only
 *   fact the chain still owns is WHICH ids are in circulation — which
 *   `useMintedBulls` already reads for the browse grid, and which every other
 *   surface shares through react-query's cache.
 *
 * ⚠ "WHICH", NOT "HOW MANY", AND THAT CHANGED WITH `BullPen`. A rank is a
 * position in a field, so the field has to be the bulls somebody actually
 * holds. Ranking against a COUNT was the same thing while ids came out
 * sequentially; it is not any more, because the pen holds a scattered subset of
 * minted-but-unsold bulls that would otherwise pad every field they sit in.
 *
 * Net: no `/api/rank` route, no rpc pool, no 5-minute staleness, no server
 * fan-out that gets slower as the drop fills. Two `Bulls` reads plus the pen's
 * `poolIds()`, and a table.
 *
 * ⚠ COMPUTED ONCE PER MINTED SET, NOT ONCE PER CARD. The table is memoised at
 * MODULE level, so a browse grid of 48 `BullCard`s each calling `useRanks()`
 * scores the collection exactly once. Do not "optimise" this by threading ranks
 * down through props — calling the hook per card is the intended usage and is
 * what keeps the number impossible to get out of sync with the row it sits on.
 *
 * ⚠ RANK ≠ RATING. This is how rare the bull IS. Rating is elo, real chain
 * state, and comes off `useRoster()`.
 */
export interface RanksView {
  /** Rank 1 first. Empty until the minted count is known. */
  readonly ranks: readonly RankedBull[];
  /** `tokenId → RankedBull`. The lookup a card wants. */
  readonly byId: ReadonlyMap<number, RankedBull>;
  /** How many bulls the table was computed against. The `147` in `61 / 147`. */
  readonly rankOf: number;
  /** When this table was built, ms. Null until there is one. Only moves when
   *  the minted set actually changes, so a "last computed" line does not tick
   *  on every poll. */
  readonly computedAt: number | null;
  /** False when no `Bulls` address is configured for this build. */
  readonly deployed: boolean;
  readonly isLoading: boolean;
  /** The minted-count read settled with no answer. NOT "nothing is minted". */
  readonly unavailable: boolean;
  readonly refetch: () => void;
}

interface CacheEntry {
  readonly key: string;
  readonly at: number;
  readonly ranks: RankedBull[];
  readonly byId: Map<number, RankedBull>;
}

let CACHE: CacheEntry | null = null;

const EMPTY_INDEX: ReadonlyMap<number, RankedBull> = new Map();

/**
 * A signature of the circulating set that is correct for an ARBITRARY set of
 * ids.
 *
 * ⚠ THIS USED TO BE `length:first:last`, AND THAT KEY IS NOW UNSOUND. It was
 * justified by a contiguity invariant — `useMintedBulls` handed back a solid
 * `1..nextTokenId-1` with #501 optionally appended, so three numbers pinned the
 * whole set — and `BullPen` destroys that invariant outright. The pen holds a
 * scattered, RANDOM subset of the ids and deals them in an order nobody can
 * predict, so the circulating set is full of holes that move.
 *
 * Two different sets sharing a length, a first and a last id is not a freak
 * coincidence under those rules, it is the ordinary case: one bull settling out
 * of the pen while another is drawn leaves the length and both endpoints
 * untouched. The cache would then hand back a table computed against a
 * DIFFERENT set of bulls, and every rank on the page would be silently wrong
 * with nothing on screen to indicate it. That is the worst failure shape this
 * codebase has, and it is why this is a hash rather than three numbers.
 *
 * FNV-1a over the ids, order included. Order-sensitivity is deliberately the
 * SAFE direction: the ids arrive ascending, so a differing order could only
 * ever cost one wasted recompute, whereas an order-INDEPENDENT mix trades that
 * for a real chance of two genuinely different sets colliding. O(n) over at
 * most 501 numbers, and it only runs when the array identity changes, which is
 * when the chain reads actually moved.
 */
function signature(ids: readonly number[]): string {
  // FNV-1a, 32-bit. `Math.imul` keeps the multiply in int32 rather than letting
  // it go through a float and quietly lose the low bits.
  let h = 0x811c9dc5;
  h = Math.imul(h ^ ids.length, 0x01000193);
  for (let i = 0; i < ids.length; i++) {
    const id = ids[i]!;
    h = Math.imul(h ^ (id & 0xff), 0x01000193);
    h = Math.imul(h ^ ((id >>> 8) & 0xff), 0x01000193);
  }
  return `${ids.length}:${(h >>> 0).toString(16)}`;
}

function tableFor(ids: readonly number[]): CacheEntry | null {
  if (ids.length === 0) return null;
  const key = signature(ids);
  if (CACHE && CACHE.key === key) return CACHE;
  const ranks = ranksForIds(ids);
  CACHE = { key, at: Date.now(), ranks, byId: rankIndex(ranks) };
  return CACHE;
}

export function useRanks(): RanksView {
  const minted = useMintedBulls();

  // `minted.ids` is itself memoised on the two chain reads, so this recomputes
  // only when the minted set really changed — a 30s poll that returns the same
  // count does not rebuild the table or move `computedAt`.
  const table = useMemo(() => tableFor(minted.ids), [minted.ids]);

  return {
    ranks: table?.ranks ?? [],
    byId: table?.byId ?? EMPTY_INDEX,
    rankOf: table?.ranks.length ?? 0,
    computedAt: table?.at ?? null,
    deployed: minted.deployed,
    isLoading: minted.isLoading,
    unavailable: minted.unavailable,
    refetch: minted.refetch,
  };
}

/**
 * One bull's rank, or null while the minted count is unknown or the token is
 * not minted. This is the call a card makes.
 *
 *   const rank = useRank(id);
 *   rank && `rank #${rank.rank} / ${rank.rankOf}`   // "rank #61 / 147"
 *   rank && formatPoints(rank.score)                // "374 pts"
 */
export function useRank(tokenId: number): RankedBull | null {
  const { byId } = useRanks();
  return byId.get(tokenId) ?? null;
}
