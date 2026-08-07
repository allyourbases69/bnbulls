'use client';

import { useMemo } from 'react';
import { DuelAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { isValidBullId } from '@/lib/art/collection';
import { useContractLogs } from './useContractLogs';

/**
 * Every fight ever settled on chain, newest first.
 *
 * ⚠ THE EVENT IS THE ONLY ARCHIVE. `Duel` keeps no list of past fights — the
 * standing-fight slot holds ONE row per wallet and is cleared the moment the
 * fight settles — so `DuelCompleted` is the whole record. That is also why a
 * replay needs nothing but a tx hash: the seed rides in the event and the fight
 * is deterministic from it (`lib/duelReplaySource.ts`).
 *
 * ⚠ NO INDEXER, AND THAT IS THE DIFFERENCE FROM FEFERS. Fefers reads a postgres
 * cache first and falls back to chain. bnbulls has no history API, so this is
 * the chain leg only, through the same bounded, backward-walking scanner every
 * other log-reading surface here uses (`useContractLogs`). Its `incomplete`
 * flag comes straight through and the page MUST render it: a partial list shown
 * as a whole one is the quiet version of being wrong.
 *
 * ⚠ `logIndex` IS CARRIED, NOT DROPPED. One transaction can settle more than
 * one duel, and `/api/duel-gif` takes `&log=` to say which. Without it every
 * replay from such a tx would play the first fight in it.
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
  /** The scan settled with no answer. NOT the same as "no fights yet". */
  readonly unavailable: boolean;
  /** The scan could not cover full history. Say so out loud. */
  readonly incomplete: boolean;
  readonly refetch: () => void;
}

interface RawDuelLog {
  args?: {
    tokenA?: bigint;
    tokenB?: bigint;
    winnerId?: number;
    rounds?: number;
    newEloA?: number;
    newEloB?: number;
  };
  blockNumber?: bigint | null;
  transactionHash?: `0x${string}` | null;
  logIndex?: number | null;
}

export function useDuelHistory(): UseDuelHistoryResult {
  const duelAddress = contractAddress('duel');

  const { data, isLoading, error, refetch } = useContractLogs({
    address: duelAddress,
    abi: DuelAbi,
    eventName: 'DuelCompleted',
    enabled: !!duelAddress,
  });

  const rows = useMemo<DuelHistoryRow[]>(() => {
    if (!data) return [];
    const out: DuelHistoryRow[] = [];
    const seen = new Set<string>();
    for (const log of data.logs) {
      const l = log as RawDuelLog;
      const a = l.args;
      if (
        !a ||
        a.tokenA === undefined ||
        a.tokenB === undefined ||
        a.winnerId === undefined ||
        a.rounds === undefined
      ) {
        continue;
      }
      const txHash = l.transactionHash;
      const logIndex = l.logIndex;
      // A log with no home cannot be replayed and cannot be linked, so it has
      // nothing to offer a row. Dropping it beats rendering a dead ▶.
      if (!txHash || logIndex === undefined || logIndex === null) continue;
      const key = `${txHash}-${logIndex}`;
      if (seen.has(key)) continue;
      seen.add(key);

      const tokenA = Number(a.tokenA);
      const tokenB = Number(a.tokenB);
      // Ids outside the collection cannot be named, drawn or linked. `Duel`
      // cannot emit one, so this only ever fires against a wrong address in
      // config — in which case a blank list is the right answer.
      if (!isValidBullId(tokenA) || !isValidBullId(tokenB)) continue;

      out.push({
        tokenA,
        tokenB,
        winnerId: Number(a.winnerId),
        rounds: Number(a.rounds),
        newEloA: Number(a.newEloA ?? 0),
        newEloB: Number(a.newEloB ?? 0),
        txHash,
        blockNumber: l.blockNumber ?? 0n,
        logIndex,
      });
    }
    // Newest first. Same block: the later log is the later fight.
    out.sort((x, y) => {
      if (x.blockNumber !== y.blockNumber) return x.blockNumber > y.blockNumber ? -1 : 1;
      return y.logIndex - x.logIndex;
    });
    return out;
  }, [data]);

  const loading = !!duelAddress && isLoading;

  return {
    rows,
    isLoading: loading,
    deployed: !!duelAddress,
    unavailable: !!duelAddress && !loading && (error !== null || data === undefined),
    incomplete: data?.incomplete ?? false,
    refetch: () => {
      void refetch();
    },
  };
}
