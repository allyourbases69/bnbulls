'use client';

import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { AbiEvent } from 'viem';
import { deployBlock } from '@/lib/env';

// Public BSC RPCs cap `eth_getLogs` block ranges (BNB-CHAIN-FACTS.md §2), so a
// scan from genesis on a live chain would just fail. Chunk it, and cap the
// total chunks so one page load can never turn into hundreds of RPC calls.
const CHUNK_SIZE = 5_000n;
const MAX_CHUNKS = 20;
// ~3.5 days of BSC blocks at a ~3s block time. Used only when no deploy block
// is configured — see `deployBlock()` in env.ts.
const FALLBACK_LOOKBACK = 100_000n;

interface LogsResult<T> {
  logs: T[];
  /** True when the scan could not cover full history — either because no
   *  deploy block is configured (so anything before the lookback window is
   *  invisible) or the chunk cap was hit. Surface this in the UI rather than
   *  silently presenting a partial list as complete. */
  incomplete: boolean;
}

/**
 * Historical logs for one event, chunked and range-bounded. Wagmi has no
 * built-in "fetch past logs" hook (only `useWatchContractEvent` for live
 * events), so this wraps `publicClient.getLogs` in a react-query cache.
 */
export function useContractLogs<TAbi extends readonly unknown[]>(params: {
  address: `0x${string}` | undefined | null;
  abi: TAbi;
  eventName: string;
  enabled?: boolean;
}) {
  const client = usePublicClient();
  const { address, abi, eventName, enabled = true } = params;

  return useQuery<LogsResult<Record<string, unknown>>>({
    queryKey: ['contract-logs', address, eventName],
    enabled: !!client && !!address && enabled,
    staleTime: 30_000,
    queryFn: async () => {
      if (!client || !address) return { logs: [], incomplete: false };
      const event = (abi as readonly unknown[]).find(
        (x): x is AbiEvent => (x as AbiEvent).type === 'event' && (x as AbiEvent).name === eventName,
      );
      if (!event) throw new Error(`no event named "${eventName}" in the supplied abi`);

      const latest = await client.getBlockNumber();
      const configuredFrom = deployBlock();
      const from = configuredFrom ?? (latest > FALLBACK_LOOKBACK ? latest - FALLBACK_LOOKBACK : 0n);

      const chunks: Array<{ from: bigint; to: bigint }> = [];
      let cursor = from;
      while (cursor <= latest && chunks.length < MAX_CHUNKS) {
        const to = cursor + CHUNK_SIZE > latest ? latest : cursor + CHUNK_SIZE;
        chunks.push({ from: cursor, to });
        cursor = to + 1n;
      }
      const hitChunkCap = cursor <= latest;

      // Sequential on purpose, not Promise.all — a free-tier RPC batches
      // concurrent requests poorly (BNB-CHAIN-FACTS.md §2).
      const logs: Record<string, unknown>[] = [];
      for (const c of chunks) {
        const found = await client.getLogs({ address, event, fromBlock: c.from, toBlock: c.to });
        logs.push(...(found as unknown as Record<string, unknown>[]));
      }

      return { logs, incomplete: configuredFrom === null || hitChunkCap };
    },
  });
}
