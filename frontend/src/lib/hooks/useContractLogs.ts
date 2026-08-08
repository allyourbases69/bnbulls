'use client';

import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { AbiEvent } from 'viem';
import { deployBlock } from '@/lib/env';

// Public BSC RPCs cap `eth_getLogs` block ranges (BNB-CHAIN-FACTS.md §2), so a
// scan from genesis on a live chain would just fail. Chunk it, and cap the
// total chunks so one page load can never turn into hundreds of RPC calls.
const CHUNK_SIZE = 5_000n;
// 40 x 5,000 = 200,000 blocks of coverage. At BSC's ~0.75s blocks that is
// roughly two days back from the tip, and it comfortably spans the gap that
// had already opened on testnet between the deploy block and the head.
// `incomplete` still goes true if even this does not reach `deployBlock`, so
// the UI never silently claims a partial list is the whole list.
const MAX_CHUNKS = 40;
// ~3.5 days of BSC blocks at a ~3s block time. Used only when no deploy block
// is configured — see `deployBlock()` in env.ts.
const FALLBACK_LOOKBACK = 100_000n;
// The narrowest range we will retry down to when an endpoint rejects a chunk
// for being too wide. Public nodes disagree on the cap (some 5,000, some
// 1,000, some by result COUNT), so a chunk that fails is halved and retried
// rather than discarded — the widest range a given endpoint will actually
// serve is discovered, not assumed.
const MIN_CHUNK = 500n;
// How many chunks in a row may fail before the walk gives up and stops going
// further back. This is the backstop for the one failure that has no clean
// signal: a PUBLIC RPC that has dropped old logs. It answers a pruned range
// with an error, but wagmi's `fallback` transport can mask that behind the
// NEXT endpoint's error (a rate limit, a wrong-chain empty), so the message is
// not reliable. Pruning only ever removes the OLDEST blocks, so a run of
// consecutive failures walking backward means we have reached the end of what
// this endpoint keeps — everything older is gone too, and hammering it for
// another 20 pruned ranges just makes the page load slower for nothing.
const MAX_CONSECUTIVE_FAILURES = 3;

interface LogsResult<T> {
  logs: T[];
  /** True when the scan could not cover full history — either because no
   *  deploy block is configured (so anything before the lookback window is
   *  invisible), the chunk cap was hit, or a range could not be read (a public
   *  node that has pruned its oldest logs). Surface this in the UI rather than
   *  silently presenting a partial list as complete. */
  incomplete: boolean;
}

/** viem stacks a human sentence, a details line and the raw message onto its
 *  errors, and which one carries the useful text varies by transport. Join
 *  them so classification below can match against all of it at once. */
function errorText(e: unknown): string {
  if (e && typeof e === 'object') {
    const o = e as { shortMessage?: unknown; details?: unknown; message?: unknown };
    const parts = [o.shortMessage, o.details, o.message].filter(
      (s): s is string => typeof s === 'string' && s.length > 0,
    );
    if (parts.length > 0) return parts.join(' | ');
  }
  return String(e);
}

/** The endpoint served the request but capped the block range or the result
 *  size. A NARROWER range may still succeed, so these get retried smaller
 *  rather than skipped. Deliberately excludes "rate limit", which narrowing
 *  cannot fix and which only means try again later. */
function isRangeCapped(msg: string): boolean {
  if (/rate limit/i.test(msg)) return false;
  return /block range|range is too|range too|too wide|too many blocks|max(imum)? .*block|logs matched|more than \d+ results|result set too large|response size|query timeout exceeded|exceed|-32602/i.test(
    msg,
  );
}

/** A public node that has dropped the state/logs for old blocks. Not an outage
 *  and not an empty record — the end of what this endpoint can see. */
function isPruned(msg: string): boolean {
  return /pruned|missing trie node|no historical|older than|not available.*block|block.*(is )?not available/i.test(
    msg,
  );
}

/**
 * Historical logs for one event, chunked and range-bounded. Wagmi has no
 * built-in "fetch past logs" hook (only `useWatchContractEvent` for live
 * events), so this wraps `publicClient.getLogs` in a react-query cache.
 *
 * ⚠ ONE BAD CHUNK MUST NOT SINK THE WHOLE READ. The scanner walks a wide
 * window, and on a public RPC the oldest part of that window is routinely
 * PRUNED — `getLogs` there throws. An earlier version had no per-chunk guard
 * and queried the oldest chunk FIRST, so the very first pruned range rejected
 * the entire query and `/history` (plus the graveyard and the pots) showed
 * "couldn't read" while real, recent records sat readable near the head. Each
 * chunk is now read in isolation: a range that cannot be served is a hole in
 * the record (`incomplete: true`), never a reason to throw away the ranges
 * that could. The read only fails outright when NOT ONE chunk came back.
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

      // ⚠ WALK BACKWARD FROM THE HEAD. DO NOT "SIMPLIFY" THIS TO A FORWARD SCAN.
      //
      // It used to start at `deployBlock` and walk FORWARD, capped at
      // MAX_CHUNKS — so it covered the first ~100k blocks after deploy and
      // stopped. Every block mined after that widened a blind spot at the TIP,
      // which is the only part a player actually looks at. Observed live on
      // testnet: deploy 123,440,452, scan ended 123,540,452, head 123,604,943 —
      // a freshly minted bull sat 64,491 blocks past the end of the search and
      // the UI showed nothing. It is silent, and it gets worse daily, so on
      // mainnet it would have started working and then quietly stopped.
      //
      // Scanning backward makes truncation drop the OLDEST range instead of the
      // newest. A just-minted token is always in the first chunk queried.
      const chunks: Array<{ from: bigint; to: bigint }> = [];
      let cursor = latest;
      let reachedStart = false;
      while (chunks.length < MAX_CHUNKS) {
        const span = cursor - from >= CHUNK_SIZE ? CHUNK_SIZE : cursor - from;
        const chunkFrom = cursor - span;
        chunks.push({ from: chunkFrom, to: cursor });
        if (chunkFrom <= from) {
          reachedStart = true;
          break;
        }
        cursor = chunkFrom - 1n;
      }
      const hitChunkCap = !reachedStart;

      let lastError: unknown = null;

      // Read one range. Retries narrower on a range/result cap so a stricter
      // endpoint is discovered, not fought. Never throws: it reports what it
      // managed to read plus whether the range was pruned (stop the walk) or
      // skipped (surface `incomplete`).
      const readRange = async (
        lo: bigint,
        hi: bigint,
      ): Promise<{ logs: Record<string, unknown>[]; pruned: boolean; ok: boolean; skipped: boolean }> => {
        try {
          const found = await client.getLogs({ address, event, fromBlock: lo, toBlock: hi });
          return {
            logs: found as unknown as Record<string, unknown>[],
            pruned: false,
            ok: true,
            skipped: false,
          };
        } catch (e) {
          lastError = e;
          const msg = errorText(e);
          if (isPruned(msg)) return { logs: [], pruned: true, ok: false, skipped: true };
          if (isRangeCapped(msg) && hi - lo + 1n > MIN_CHUNK * 2n) {
            const mid = lo + (hi - lo) / 2n;
            const a = await readRange(lo, mid);
            const b = await readRange(mid + 1n, hi);
            return {
              logs: [...a.logs, ...b.logs],
              pruned: a.pruned || b.pruned,
              ok: a.ok || b.ok,
              skipped: a.skipped || b.skipped,
            };
          }
          return { logs: [], pruned: false, ok: false, skipped: true };
        }
      };

      // Sequential on purpose, not Promise.all — a free-tier RPC batches
      // concurrent requests poorly (BNB-CHAIN-FACTS.md §2). Newest chunk first,
      // so the tip (where a just-settled fight is) is always read before the
      // walk reaches, and stops at, the pruned tail.
      const logs: Record<string, unknown>[] = [];
      let okReads = 0;
      let anySkipped = false;
      let consecutiveFailures = 0;
      for (const c of chunks) {
        const r = await readRange(c.from, c.to);
        logs.push(...r.logs);
        if (r.ok) {
          okReads += 1;
          consecutiveFailures = 0;
        } else {
          consecutiveFailures += 1;
        }
        if (r.skipped) anySkipped = true;
        // The end of what this endpoint keeps: pruning removes the oldest
        // blocks, so nothing further back is readable. Stop rather than burn
        // the rest of the budget on ranges that will all fail the same way.
        if (r.pruned || consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) break;
      }

      // Not one range came back. That is an endpoint that cannot be reached,
      // not an empty record — throw so the caller can render "couldn't read"
      // rather than "nobody has done this yet". The two are different facts.
      if (okReads === 0) {
        throw lastError instanceof Error
          ? lastError
          : new Error('every log range failed to read');
      }

      // Chronological (oldest → newest), because callers are entitled to assume
      // it even though today's three all re-sort. Cheap to guarantee here, a
      // silent bug to leave to chance.
      logs.sort((a, b) => {
        const ab = (a.blockNumber as bigint | null) ?? 0n;
        const bb = (b.blockNumber as bigint | null) ?? 0n;
        if (ab !== bb) return ab < bb ? -1 : 1;
        const ai = (a.logIndex as number | null) ?? 0;
        const bi = (b.logIndex as number | null) ?? 0;
        return ai - bi;
      });

      return { logs, incomplete: configuredFrom === null || hitChunkCap || anySkipped };
    },
  });
}
