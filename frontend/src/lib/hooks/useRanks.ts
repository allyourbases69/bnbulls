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
 *   fact the chain still owns is HOW MANY are minted — which `useMintedBulls`
 *   already reads for the browse grid, and which every other surface shares
 *   through react-query's cache.
 *
 * Net: no `/api/rank` route, no rpc pool, no 5-minute staleness, no server
 * fan-out that gets slower as the drop fills. One `nextTokenId` + `kingMinted`
 * read, and a table.
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
 * O(1) signature of the minted set. `useMintedBulls` hands back a contiguous
 * `1..nextTokenId-1` with #501 optionally appended, so length plus the first
 * and last id identify it completely — and joining 501 ids into a string on
 * every render would not.
 */
function signature(ids: readonly number[]): string {
  if (ids.length === 0) return '0';
  return `${ids.length}:${ids[0]}:${ids[ids.length - 1]}`;
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
