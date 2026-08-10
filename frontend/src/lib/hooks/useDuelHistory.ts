'use client';

import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { contractAddress } from '@/lib/env';
import type { DuelRecordPayload } from '@/lib/duelRecord';

/**
 * Every fight ever settled on chain, newest first, read through
 * `/api/duel-history`.
 *
 * ⚠ THIS DELIBERATELY DOES NOT GO THROUGH `useContractLogs`, AND THAT IS THE
 * WHOLE POINT. It used to, and the page was badly short without ever saying so
 * in a way anyone could act on: the refused log ranges came back as NOTHING, not
 * as errors, because neither a 403 nor a rate limit is the range-cap error the
 * scanner's halving path looks for. Measured 2026-08-10, `/history` showed 31 of
 * the 35 fights on chain and the gap widened daily. The endpoint-by-endpoint
 * table is in `lib/serverLogs.ts`.
 *
 * ⚠ THE RETURN SHAPE IS UNCHANGED ON PURPOSE. `DuelHistoryPanel` and
 * `DuelHistoryTable` render four states off these fields and key their rows on
 * `txHash`+`logIndex`; swapping the source underneath is a data fix, not a ui
 * change, so nothing downstream had to move.
 *
 * ⚠ AN ERROR IS AN ERROR, NEVER AN EMPTY LIST. The route answers 502 when it
 * could not read the chain, this hook throws on it, and `unavailable` carries it
 * to the page. "the pit is quiet" printed because a read failed is the page
 * telling a visitor the game is dead.
 *
 * ⚠ `logIndex` IS CARRIED, NOT DROPPED. One transaction can settle more than one
 * duel, and `/api/duel-gif` takes `&log=` to say which. Without it every replay
 * from such a tx would play the first fight in it.
 */
export interface DuelHistoryRow {
  readonly tokenA: number;
  readonly tokenB: number;
  /** The winning token id. **0 means a draw** (`Duel._updateStreaksAndCheckDeaths`). */
  readonly winnerId: number;
  readonly rounds: number;
  /** Rating AFTER this fight, as the chain recorded it. Not a live read: this
   *  is what the bull was worth on the day, which is what a history row means. */
  readonly newEloA: number;
  readonly newEloB: number;
  readonly txHash: `0x${string}`;
  readonly blockNumber: bigint;
  readonly logIndex: number;
}

export interface UseDuelHistoryResult {
  readonly rows: readonly DuelHistoryRow[];
  readonly isLoading: boolean;
  /** False when no `Duel` address is configured for this build. */
  readonly deployed: boolean;
  /** The read settled with no answer. NOT the same as "no fights yet". */
  readonly unavailable: boolean;
  /** The list is not the whole record. Say so out loud. */
  readonly incomplete: boolean;
  readonly refetch: () => void;
}

export function useDuelHistory(): UseDuelHistoryResult {
  const duelAddress = contractAddress('duel');

  const query = useQuery<DuelRecordPayload>({
    queryKey: ['duel-history', duelAddress],
    enabled: !!duelAddress,
    // The route caches for 45s behind a 45s cdn window; asking faster than that
    // just re-reads the same cached answer.
    staleTime: 30_000,
    refetchInterval: 60_000,
    refetchOnWindowFocus: true,
    retry: 1,
    queryFn: async () => {
      const res = await fetch('/api/duel-history', { cache: 'no-store' });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error ?? `the fight record endpoint answered ${res.status}`);
      }
      return (await res.json()) as DuelRecordPayload;
    },
  });

  // `blockNumber` comes back as a json number and goes out as a bigint, because
  // that is what the table has always been handed and a silent type change is
  // the kind of thing that renders as `NaN` three components away.
  const rows = useMemo<DuelHistoryRow[]>(
    () =>
      (query.data?.fights ?? []).map((f) => ({
        tokenA: f.tokenA,
        tokenB: f.tokenB,
        winnerId: f.winnerId,
        rounds: f.rounds,
        newEloA: f.newEloA,
        newEloB: f.newEloB,
        txHash: f.txHash,
        blockNumber: BigInt(f.blockNumber),
        logIndex: f.logIndex,
      })),
    [query.data],
  );

  const loading = !!duelAddress && query.isLoading;

  return {
    rows,
    isLoading: loading,
    deployed: !!duelAddress,
    unavailable: !!duelAddress && !loading && (query.isError || query.data === undefined),
    incomplete: query.data?.truncated ?? false,
    refetch: () => {
      void query.refetch();
    },
  };
}
