'use client';

import { useReadContract } from 'wagmi';
import { Erc20Abi } from '@/lib/abi';

/**
 * `decimals()` read live off a token contract. Returns `undefined` while
 * loading or when there's no address to read — callers must treat that as
 * "don't know yet", never fall back to 18 or any other guess.
 *
 * This is the one and only place token decimals should be read in this app.
 * `BNB-CHAIN-FACTS.md` / the frontend package brief: BSC-USDT is 18dp, unlike
 * ethereum/tron's 6dp, and fefers' hardcoded "marketplace is 6dp" assumption
 * once rendered an $80 listing as $0.00. Native BNB is the one exception —
 * 18dp is a chain invariant, not a token's own setting, so it's a constant.
 */
export const NATIVE_BNB_DECIMALS = 18;

export function useTokenDecimals(address: `0x${string}` | undefined | null) {
  const { data, isLoading, isError } = useReadContract({
    address: address ?? undefined,
    abi: Erc20Abi,
    functionName: 'decimals',
    query: { enabled: !!address },
  });
  return {
    decimals: typeof data === 'number' ? data : undefined,
    isLoading: !!address && isLoading,
    isError,
  };
}

/**
 * `symbol()` read live off a token contract, for the TICKER PRINTED BESIDE a
 * number. Same rule as `decimals()` above: `undefined` means "don't know yet"
 * and a caller must never substitute an assumption of its own.
 *
 * ⚠ WHY THIS EXISTS, and it is the same bug class as the decimals one. The pot
 * surfaces already read `prizeToken()` and its `decimals()` live, but the
 * ticker next to every figure came from a constant in `brand.ts` — so a pot
 * whose prize token was not the one we assumed rendered the RIGHT AMOUNT WITH
 * THE WRONG TICKER. That is worse than either half being wrong on its own,
 * because the number looks trustworthy and carries the lie.
 *
 * A token whose `symbol()` is a `bytes32` (the pre-standard style) fails to
 * decode and lands in `isError`, which is the honest answer, not a crash.
 */
export function useTokenSymbol(address: `0x${string}` | undefined | null) {
  const { data, isLoading, isError } = useReadContract({
    address: address ?? undefined,
    abi: Erc20Abi,
    functionName: 'symbol',
    query: { enabled: !!address },
  });
  return {
    symbol: typeof data === 'string' && data.length > 0 ? data : undefined,
    isLoading: !!address && isLoading,
    isError,
  };
}

/**
 * The ticker to print beside a figure, with the same three-answer discipline
 * `useJackpot.potFigure` applies to the figure itself. ONE rule, one place, so
 * the standing panels and the pots page cannot drift apart.
 *
 *   live value        → print it. always preferred, always the truth.
 *   still asking      → print NOTHING. the figure beside it is a `—`, and a
 *                       ticker guessed while loading is exactly the bug this
 *                       whole change exists to remove.
 *   asked, no answer  → the caller's documented constant. a bare number with
 *                       no unit at all is not an improvement, and `POTS` in
 *                       `brand.ts` records why those constants are safe for
 *                       this deployment specifically.
 */
export function tickerToPrint(
  symbol: string | undefined,
  stillAsking: boolean,
  fallback: string,
): string {
  if (symbol !== undefined) return symbol;
  return stillAsking ? '' : fallback;
}
