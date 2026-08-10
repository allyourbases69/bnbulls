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

/**
 * A dollar figure that stays honest when the amount is tiny.
 *
 * ⚠ `formatUsd1e18` PINS TWO DECIMALS, which is right for a mint price and
 * wrong for a fight top-up: half a cent of BNB would print as "$0.00", and a
 * zero next to an amount somebody is about to send is exactly the class of lie
 * this app refuses everywhere else. Anything under a cent says so instead.
 *
 * Returns `—` for an unread input, never a guessed zero.
 */
export function formatUsdApprox(value: bigint | undefined | null): string {
  if (value === undefined || value === null) return '—';
  const n = Number(formatUnits(value, USD_DECIMALS));
  if (n === 0) return '$0.00';
  if (n < 0.01) return '<$0.01';
  const maxFrac = n < 100 ? 2 : 0;
  return `$${n.toLocaleString('en-US', { minimumFractionDigits: maxFrac, maximumFractionDigits: maxFrac })}`;
}

/**
 * A native-BNB wei amount, restated on the protocol's 1e18 dollar scale.
 *
 * ⚠ THIS IS A DISPLAY CONVERSION, NOT A PRICE. `usdPerBnb1e18` must come from
 * a LIVE `bnbUsdPrice()` read — the same Chainlink answer the contract itself
 * converts the dollar sticker through — so the dollars beside a BNB figure move
 * with the chain rather than with a constant somebody typed. `useBnbUsdPrice`
 * is the only sanctioned source.
 *
 * ⚠ RETURNS `undefined` WHEN EITHER SIDE IS UNREAD, and callers must render a
 * dash rather than filling it in. A dollar figure computed off a missing feed
 * would be a confident wrong number attached to money about to be spent, which
 * is the one failure this whole page is built to avoid.
 */
export function usdFromBnbWei(
  wei: bigint | undefined | null,
  usdPerBnb1e18: bigint | undefined | null,
): bigint | undefined {
  if (wei === undefined || wei === null) return undefined;
  if (usdPerBnb1e18 === undefined || usdPerBnb1e18 === null || usdPerBnb1e18 <= 0n) {
    return undefined;
  }
  // BNB is 18dp by chain invariant and the price is 1e18-scaled, so the two
  // scales cancel to a plain 1e18 dollar figure.
  return (wei * usdPerBnb1e18) / 10n ** 18n;
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

/**
 * A ticking `mm:ss` clock — "04:31". Used for the pit's eject countdown, where
 * the point is that the number is MOVING and the bull is still fightable until
 * it reaches zero.
 *
 * ⚠ DIFFERENT JOB FROM `formatDuration`, which drops zero components ("4m") so
 * a static window reads cleanly. A countdown that hides its seconds looks
 * frozen, and this one has to look like it is running out, because it is.
 *
 * ⚠ NEVER ROUNDS UP PAST ZERO. `00:00` means the departure has landed; while
 * any time remains, some digit is non-zero.
 */
export function formatCountdown(totalSeconds: number): string {
  if (totalSeconds <= 0) return '00:00';
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = Math.floor(totalSeconds % 60);
  const mm = String(minutes).padStart(2, '0');
  const ss = String(seconds).padStart(2, '0');
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}
