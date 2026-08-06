/**
 * Display formatting for on-chain numbers. Two scales matter here and they
 * must never be conflated:
 *
 * 1. **Protocol dollars** — `usd1e18` fields (`MintDrop.PriceTier.usdPrice`,
 *    `Graveyard`'s ladders, `Marketplace.Listing.usdPrice`, every `quote()`'s
 *    `usdTotal1e18`/`usdPrice1e18`). These are ALWAYS scaled by 1e18 as a
 *    protocol convention — it is not a token's `decimals()` and never varies.
 * 2. **Token amounts** — raw units of whatever token paid, scaled by THAT
 *    token's own `decimals()`, read live off the token, never assumed. BNB is
 *    18dp by chain invariant; BSC-USDT is 18dp unlike ethereum/tron's 6dp; the
 *    fefers "marketplace is 6dp" rule does not apply here — see
 *    `DECISIONS.md` and the frontend package brief's hard constraints.
 */
import { formatUnits } from 'viem';

const USD_DECIMALS = 18;

/** Format a `usd1e18`-scaled dollar figure, e.g. `10_000000000000000000n` -> "$10.00". */
export function formatUsd1e18(value: bigint | undefined | null, opts?: { withSign?: boolean }): string {
  if (value === undefined || value === null) return '—';
  const n = Number(formatUnits(value, USD_DECIMALS));
  const s = n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return opts?.withSign === false ? s : `$${s}`;
}

/** Format a raw token amount at that token's own `decimals()`. Returns "—"
 *  while `decimals` hasn't loaded yet — NEVER falls back to a guessed value. */
export function formatToken(
  value: bigint | undefined | null,
  decimals: number | undefined | null,
  opts?: { maxFractionDigits?: number },
): string {
  if (value === undefined || value === null || decimals === undefined || decimals === null) {
    return '—';
  }
  const n = Number(formatUnits(value, decimals));
  const maxFrac = opts?.maxFractionDigits ?? (n >= 1 ? 4 : 6);
  return n.toLocaleString('en-US', { maximumFractionDigits: maxFrac });
}

/** Basis points -> a percent string, e.g. 1000 -> "10%", 250 -> "2.5%". */
export function formatBps(bps: number | bigint | undefined | null): string {
  if (bps === undefined || bps === null) return '—';
  const n = Number(bps) / 100;
  return `${n % 1 === 0 ? n.toFixed(0) : n.toFixed(2)}%`;
}

/** Rescale a raw token amount from its own `decimals()` to the protocol's
 *  fixed 1e18 dollar scale. Only valid as an approximation for an asset that
 *  is itself ~1:1 with a dollar (a payment stablecoin) — never use this on a
 *  volatile asset like BNB/WBNB, which is the whole reason Chainlink exists
 *  in this app (`DECISIONS.md §1`). */
export function scaleToUsd1e18(amount: bigint, decimals: number): bigint {
  if (decimals <= 18) return amount * 10n ** BigInt(18 - decimals);
  return amount / 10n ** BigInt(decimals - 18);
}

export function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Seconds -> a short "Xh Ym" / "Xd Yh" style duration, floor-rounded. Used
 *  for the graveyard's owner-priority countdown. Never rounds UP past zero —
 *  a countdown must not read "0s" while the window is still open. */
export function formatDuration(totalSeconds: number): string {
  if (totalSeconds <= 0) return 'now';
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor((totalSeconds % 86400) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = Math.floor(totalSeconds % 60);
  // ⚠ A ZERO COMPONENT IS DROPPED. The graveyard's 24h owner head start is
  // exactly one day, and "1d 0h" reads like a bug on a page that is otherwise
  // careful about numbers.
  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  if (minutes > 0) return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
  return `${seconds}s`;
}
