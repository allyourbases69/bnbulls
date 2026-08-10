'use client';

import { useQuery } from '@tanstack/react-query';
import type { PotDepositsPayload } from '@/lib/potDeposits';

/**
 * Every deposit into a jackpot, read through `/api/pot-deposits`.
 *
 * ⚠ THIS DELIBERATELY DOES NOT GO THROUGH `useContractLogs`, AND THAT IS THE
 * WHOLE POINT. Historical logs cannot be read from a browser on this chain:
 * both bnb dataseeds refuse `eth_getLogs`, drpc's public endpoint rate-limits
 * it, and every free endpoint prunes logs to roughly the last two hours. A
 * client sweep would show a pot that appeared to stop filling. The reasoning,
 * with the measurements, is in `lib/serverLogs.ts`.
 *
 * ⚠ AN ERROR IS AN ERROR, NEVER AN EMPTY LIST. The route answers 502 when it
 * could not read the chain, and this hook throws on it, so the feed can say
 * "we could not read the chain" in words that look nothing like "no deposits
 * yet". Collapsing those two would be the page telling a visitor the pot is
 * empty when it is not.
 */
export function usePotDeposits(pot: 'jackpotBnbull' | 'jackpotBnb', enabled: boolean) {
  return useQuery<PotDepositsPayload>({
    queryKey: ['pot-deposits', pot],
    enabled,
    // The route caches for 45s behind a 30s cdn window; asking faster than
    // that just re-reads the same cached answer.
    staleTime: 30_000,
    refetchInterval: 60_000,
    refetchOnWindowFocus: true,
    retry: 1,
    queryFn: async () => {
      const res = await fetch(`/api/pot-deposits?pot=${pot}`, { cache: 'no-store' });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error ?? `the pot history endpoint answered ${res.status}`);
      }
      return (await res.json()) as PotDepositsPayload;
    },
  });
}
