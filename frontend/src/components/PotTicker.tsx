'use client';

/**
 * PotTicker — the site-wide pot strip, mounted under the nav on EVERY page so
 * the pots are always in view, growing. Straight port of fighting fefers'
 * `PotTicker` (`DECISIONS.md §33`), reskinned to the $BNBULL / BNB pair.
 *
 * Resilience rules, in order:
 *   - neither pot deployed  → no bar at all, zero layout cost, zero RPC.
 *   - one pot deployed      → only that chip renders.
 *   - values loading        → the bar keeps its fixed height and shows a dash,
 *     so nothing shifts when the first batch lands. tabular-nums stops later
 *     ticks jittering the row.
 *   - values UNREADABLE     → `?` and a tooltip saying so, NOT the loading
 *     dash. See `useJackpot`: this strip is on every page, so a dash that
 *     never resolves would be the site's most-seen lie.
 *
 * Wallet connection is irrelevant here. These are public reads.
 */
import Link from 'next/link';
import { POTS } from '@/lib/brand';
import { useJackpot, potFigure, TICKER_REFRESH_MS, type JackpotRead } from '@/lib/hooks/useJackpot';

export function PotTicker() {
  const bnbull = useJackpot('jackpotBnbull', TICKER_REFRESH_MS);
  const bnb = useJackpot('jackpotBnb', TICKER_REFRESH_MS);
  if (!bnbull.configured && !bnb.configured) return null;

  return (
    <div className="sticky top-16 z-40 border-b-2 border-bull-gold/40 bg-gradient-to-r from-bull-bg via-bull-panel to-bull-bg backdrop-blur md:top-28">
      {/* min-h rather than a fixed h on phones: the chips are real controls and
          have to clear Apple's 44px tap floor. The height is still FIXED, so
          the "nothing shifts when the first batch lands" guarantee holds. */}
      <div className="mx-auto flex min-h-[44px] max-w-7xl items-center justify-center gap-2.5 overflow-x-auto whitespace-nowrap px-4 md:h-10 md:min-h-0 md:gap-8 md:px-8">
        {bnbull.configured && (
          <PotChip label={POTS.bnbull.label} read={bnbull} tone="bnbull" coin="🪙" />
        )}
        {bnb.configured && <PotChip label={POTS.bnb.label} read={bnb} tone="bnb" coin="💠" />}
      </div>
    </div>
  );
}

/**
 * The pots are the product, so they carry the only shine on the site chrome: a
 * nudging coin, a glow on the number and a slow shimmer. All of it is behind
 * `prefers-reduced-motion` (globals.css) and the number itself never moves.
 *
 * The ink comes from the same `pot-*` vocabulary the standing panels use, so
 * gold always means $BNBULL and steel always means BNB wherever you are.
 */
function PotChip({
  label,
  read,
  tone,
  coin,
}: {
  label: string;
  read: JackpotRead;
  tone: 'bnbull' | 'bnb';
  coin: string;
}) {
  return (
    <Link
      href="/pots"
      className={`pot-ticker-chip ${tone === 'bnbull' ? 'pot-bnbull' : 'pot-bnb'} flex min-h-[44px] items-baseline gap-1.5 px-2.5 py-2.5 font-mono text-xs text-bull-text-dim transition-colors hover:text-bull-text md:min-h-0 md:py-0.5`}
      style={{ fontVariantNumeric: 'tabular-nums' }}
      title={
        read.error
          ? "the rpc isn't answering, so we can't read this pot right now. it's still on chain, and this'll fix itself the moment the chain answers."
          : 'the pots page: current size, the odds, and every win so far.'
      }
    >
      <span aria-hidden className="pot-coin">
        {coin}
      </span>
      <span className="bull-header tracking-wide">{label}:</span>
      <span className="pot-ticker-value pot-shimmer text-sm font-bold">
        {potFigure(read, 'pool')}
      </span>
    </Link>
  );
}
