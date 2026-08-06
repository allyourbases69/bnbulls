'use client';

import { useMemo } from 'react';
import { useReadContracts } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useContractLogs } from './useContractLogs';

/**
 * Every token id currently listed on the marketplace.
 *
 * Same shape as `useDeadBulls`: `Marketplace` has no "list every active
 * listing" view, so this scans `Listed` events for candidate ids (bounded —
 * see `useContractLogs`), then re-checks each candidate's live `isListed()`
 * before including it — a listing can be bought, cancelled, or swept since
 * the event fired.
 */
export function useActiveListings() {
  const marketAddress = contractAddress('marketplace');

  const { data: logsResult, isLoading: loadingLogs } = useContractLogs({
    address: marketAddress,
    abi: MarketplaceAbi,
    eventName: 'Listed',
    enabled: !!marketAddress,
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

  const { data: listedFlags, isLoading: loadingFlags } = useReadContracts({
    contracts: candidateIds.map((id) => ({
      address: marketAddress ?? undefined,
      abi: MarketplaceAbi,
      functionName: 'isListed' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: !!marketAddress && candidateIds.length > 0 },
  });

  const listedIds = useMemo(() => {
    if (!listedFlags) return [];
    return candidateIds.filter(
      (_, i) => listedFlags[i]?.status === 'success' && listedFlags[i]?.result === true,
    );
  }, [listedFlags, candidateIds]);

  return {
    listedIds,
    isLoading: !!marketAddress && (loadingLogs || (candidateIds.length > 0 && loadingFlags)),
    incomplete: logsResult?.incomplete ?? false,
    deployed: !!marketAddress,
  };
}
