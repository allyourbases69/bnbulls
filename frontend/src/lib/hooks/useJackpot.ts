'use client';

/**
 * useJackpot — one pot, read live.
 *
 * Ported from fighting fefers' `lib/useJackpot.ts`, which the PotTicker, the
 * standing panels and the landing page all share so the same number can never
 * be computed two different ways on two surfaces.
 *
 * THE RESILIENCE CONTRACT, in order (this is the part worth copying exactly):
 *
 *   - pot address unset  → `configured: false`, ZERO rpc calls, and every
 *     caller renders nothing. Pre-deploy that is the whole site's state, so it
 *     has to cost nothing rather than spin.
 *   - values loading     → `isLoading`, and callers show `—`.
 *   - values UNREADABLE  → `error`, and callers show `?`, never the loading
 *     dash. On fefers the strip sits on every page, so a dash that never
 *     resolves would have been the site's most-seen lie: it reads as "a pot
 *     still being counted" when the truth is "the rpc did not answer". The
 *     poll keeps running underneath, so a `?` becomes a number on its own with
 *     nothing for the player to do.
 *
 * ⚠ THE NUMBER HIERARCHY (fefers learned this the hard way):
 *   pendingPayout — what the NEXT winner walks off with. THE headline.
 *   pool          — everything sitting in the pot right now.
 *   totalAwarded  — lifetime, already paid and gone. NOT money owing.
 * Whenever `payoutBps < 100%` the headline is SMALLER than the pool, and two
 * bare numbers side by side read as a contradiction. Callers draw them as one
 * bar: filled part is the payout, hatched part rides on to the next hit.
 */
import { useReadContracts } from 'wagmi';
import { JackpotAbi } from '@/lib/abi';
import { contractAddress, type ContractName } from '@/lib/env';
import { formatToken } from '@/lib/format';
import { tickerToPrint, useTokenDecimals, useTokenSymbol } from '@/lib/hooks/useTokenDecimals';

/** Faster than the standing panels: the strip exists to be seen moving. */
export const TICKER_REFRESH_MS = 8_000;
export const PANEL_REFRESH_MS = 20_000;

export interface JackpotRead {
  /** False when this pot has no address yet. No RPC happens; render nothing. */
  configured: boolean;
  isLoading: boolean;
  /** Non-null when the chain would not answer. Show `?`, never the dash. */
  error: Error | null;
  pool: bigint | undefined;
  pendingPayout: bigint | undefined;
  payoutBps: bigint | undefined;
  totalAwarded: bigint | undefined;
  awardCount: bigint | undefined;
  oddsOneIn: bigint | undefined;
  prizeToken: `0x${string}` | undefined;
  /** The prize token's own `decimals()`, read live and never assumed. */
  decimals: number | undefined;
  /** The prize token's own `symbol()`, read live and never assumed — the
   *  ticker that goes NEXT TO the number. Undefined until it answers. */
  symbol: string | undefined;
  /** True while the symbol is unknown and nothing has failed yet, i.e. we are
   *  still asking. Consumers print no ticker at all in that window rather than
   *  a guess: see `potSymbol` below. */
  symbolPending: boolean;
  formatted: {
    pool: string;
    pendingPayout: string;
    totalAwarded: string;
  };
}

const VIEWS = [
  'pool',
  'pendingPayout',
  'payoutBps',
  'totalAwarded',
  'awardCount',
  'oddsOneIn',
  'prizeToken',
] as const;

export function useJackpot(
  name: Extract<ContractName, 'jackpotBnbull' | 'jackpotBnb'>,
  refreshMs: number = PANEL_REFRESH_MS,
): JackpotRead {
  const address = contractAddress(name);
  const configured = address !== null;

  const { data, isLoading, error } = useReadContracts({
    allowFailure: true,
    contracts: VIEWS.map((functionName) => ({
      address: address ?? undefined,
      abi: JackpotAbi,
      functionName,
    })),
    query: { enabled: configured, refetchInterval: refreshMs },
  });

  const at = <T,>(i: number): T | undefined =>
    data?.[i]?.status === 'success' ? (data[i].result as T) : undefined;

  const pool = at<bigint>(0);
  const pendingPayout = at<bigint>(1);
  const payoutBps = at<bigint>(2);
  const totalAwarded = at<bigint>(3);
  const awardCount = at<bigint>(4);
  const oddsOneIn = at<bigint>(5);
  const prizeToken = at<`0x${string}`>(6);

  // ⚠ BOTH of the prize token's own facts, read off the prize token. The
  // decimals decide the number; the symbol decides what it is called. Reading
  // one live and hardcoding the other is how a pot renders the right amount
  // with the wrong ticker.
  const { decimals } = useTokenDecimals(prizeToken);
  const { symbol, isError: symbolError } = useTokenSymbol(prizeToken);

  // A read that came back but FAILED is not the same as one still in flight.
  // Only the second may render as a dash.
  const firstFailure = data?.find((r) => r.status === 'failure');
  const readError =
    (error as Error | null) ??
    (firstFailure && 'error' in firstFailure ? (firstFailure.error as Error) : null);

  // Still asking = we have no symbol, and nothing has come back failed. A
  // `prizeToken` that has not landed yet lives here too: the symbol read is
  // switched off until it does, so "no address to ask" IS "still asking".
  const symbolPending = configured && symbol === undefined && !symbolError && readError === null;

  return {
    configured,
    isLoading: configured && isLoading,
    error: configured ? readError : null,
    pool,
    pendingPayout,
    payoutBps,
    totalAwarded,
    awardCount,
    oddsOneIn,
    prizeToken,
    decimals,
    symbol,
    symbolPending,
    formatted: {
      pool: formatToken(pool, decimals),
      pendingPayout: formatToken(pendingPayout, decimals),
      totalAwarded: formatToken(totalAwarded, decimals),
    },
  };
}

/** Three answers, three glyphs. `—` we are still asking, `?` we asked and could
 *  not get an answer, a number means a number. Never let the first two share a
 *  symbol: that is the whole bug this exists to kill. */
export function potFigure(read: JackpotRead, key: 'pool' | 'pendingPayout' | 'totalAwarded'): string {
  if (read.error) return '?';
  if (read.isLoading || read.decimals === undefined) return '—';
  return read.formatted[key];
}

/**
 * The ticker printed beside one of those figures. `fallback` is the matching
 * `POTS.*.symbolFallback` from `brand.ts`, and it is genuinely a fallback: the
 * live `symbol()` off the pot's own `prizeToken()` wins whenever we have it.
 *
 * While we are still asking, this prints NOTHING. The figure beside it is a
 * `—` in that window, and a ticker asserted next to a dash is the same class
 * of bug as a number asserted next to one — it is a claim about which token
 * this pot pays, made before anything answered.
 */
export function potSymbol(read: JackpotRead, fallback: string): string {
  return tickerToPrint(read.symbol, read.symbolPending, fallback);
}
