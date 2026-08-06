'use client';

import { useMemo } from 'react';
import { useReadContracts } from 'wagmi';
import { BullsAbi, DuelAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useContractLogs } from './useContractLogs';

/**
 * Token ids currently sitting in the graveyard.
 *
 * `Bulls`/`Graveyard` have no "list every dead token" view — the only durable
 * signal is `Duel`'s `BullDied(tokenId)` event, so this scans that (bounded —
 * see `useContractLogs`), dedupes, then re-checks EACH candidate's live
 * `isDead()` before including it. That re-check matters: a bull can die, get
 * revived, and die again, so "ever appeared in a BullDied log" is a superset
 * of "dead right now" and the live read is what resolves it.
 */
export function useDeadBulls() {
  const duelAddress = contractAddress('duel');
  const bullsAddress = contractAddress('bullsNft');

  const { data: logsResult, isLoading: loadingLogs } = useContractLogs({
    address: duelAddress,
    abi: DuelAbi,
    eventName: 'BullDied',
    enabled: !!duelAddress,
  });

  const candidateIds = useMemo(() => {
    if (!logsResult) return [];
    const ids = new Set<number>();
    for (const log of logsResult.logs) {
      const args = (log as { args?: { tokenId?: bigint } }).args;
      if (args?.tokenId !== undefined) ids.add(Number(args.tokenId));
    }
    return Array.from(ids).sort((a, b) => a - b);
  }, [logsResult]);

  const { data: deadFlags, isLoading: loadingFlags } = useReadContracts({
    contracts: candidateIds.map((id) => ({
      address: bullsAddress ?? undefined,
      abi: BullsAbi,
      functionName: 'isDead' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: !!bullsAddress && candidateIds.length > 0 },
  });

  const deadIds = useMemo(() => {
    if (!deadFlags) return [];
    return candidateIds.filter(
      (_, i) => deadFlags[i]?.status === 'success' && deadFlags[i]?.result === true,
    );
  }, [deadFlags, candidateIds]);

  return {
    deadIds,
    isLoading: !!duelAddress && (loadingLogs || (candidateIds.length > 0 && loadingFlags)),
    incomplete: logsResult?.incomplete ?? false,
    deployed: !!duelAddress && !!bullsAddress,
  };
}
