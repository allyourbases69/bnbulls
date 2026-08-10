'use client';

import { useQuery } from '@tanstack/react-query';
import { contractAddress } from '@/lib/env';
import type { JackpotAwardsPayload } from '@/lib/jackpotAwards';

/**
 * Every `Awarded` payout a jackpot has ever made — the receipt trail, read
 * through `/api/pot-awards`.
 *
 * ⚠ THIS DELIBERATELY DOES NOT GO THROUGH `useContractLogs`, AND THAT IS THE
 * WHOLE POINT. It used to, and the card never left "loading…": on bnb mainnet
 * every endpoint in the browser pool either 403s a window that reaches past its
 * retention or refuses `eth_getLogs` outright, and neither a 403 nor a rate
 * limit is a range-cap error, so the scanner's halving path never fired and the
 * chunks vanished in silence. The measurements are in `lib/serverLogs.ts`.
 *
 * ⚠ AN ERROR IS AN ERROR, NEVER AN EMPTY LIST. The route answers 502 when it
 * could not read the chain, and this hook throws on it, so the card can say "we
 * could not read the chain" in words that look nothing like "nobody has hit this
 * pot yet". Both pots genuinely have zero payouts today, so the empty state is
 * the TRUE state — which is exactly why it must not be allowed to double as the
 * failure state.
 */
export function useJackpotAwards(name: 'jackpotBnbull' | 'jackpotBnb') {
  const address = contractAddress(name);

  const query = useQuery<JackpotAwardsPayload>({
    queryKey: ['pot-awards', name],
    enabled: !!address,
    // The route caches for 60s behind a 60s cdn window; asking faster than that
    // just re-reads the same cached answer.
    staleTime: 45_000,
    refetchInterval: 90_000,
    refetchOnWindowFocus: true,
    retry: 1,
    queryFn: async () => {
      const res = await fetch(`/api/pot-awards?pot=${name}`, { cache: 'no-store' });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error ?? `the award history endpoint answered ${res.status}`);
      }
      return (await res.json()) as JackpotAwardsPayload;
    },
  });

  return {
    data: query.data ?? null,
    awards: query.data?.awards ?? [],
    isLoading: !!address && query.isLoading,
    /** The read failed. NOT the same fact as "no payouts yet". */
    isError: !!address && query.isError,
    error: query.error,
    refetch: () => {
      void query.refetch();
    },
    deployed: !!address,
  };
}
