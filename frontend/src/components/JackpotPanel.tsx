'use client';

/**
 * JackpotPanel — the standing "what's in the pot" card. Ported from fighting
 * fefers (`DECISIONS.md §33`), reskinned to the $BNBULL / BNB pair.
 *
 * Read-only, and it never states a number of its own: every figure comes off
 * chain. Renders NOTHING at all when its pot has no address yet, which is the
 * whole site's state until the deploy.
 *
 * ── THE NUMBER HIERARCHY. There are four figures and a flat row of them makes
 * two look like they contradict:
 *
 *   pendingPayout — what the NEXT winner walks off with. THE headline.
 *   pool          — everything sitting in the pot right now.
 *   totalAwarded  — lifetime, already paid and gone.
 *   awardCount    — how many times it has ever fired.
 *
 * The trap: whenever `payoutBps < 100%` the headline is SMALLER than the pool.
 * So the pool and the payout are drawn as ONE bar — filled part is the
 * headline, hatched part is what rides on to the next hit — with a sentence
 * spelling out the same thing. Lifetime figures sit below a rule so they can
 * never be mistaken for money owing.
 *
 * ── THE LOOK. Gold is $BNBULL, steel is BNB, and you should never have to
 * read the label to know which pot you are on. The ink rides in as a single
 * `pot-bnbull` / `pot-bnb` class and globals.css does the rest.
 */
import { POTS } from '@/lib/brand';
import { formatBps } from '@/lib/format';
import { useJackpot, potFigure, potSymbol } from '@/lib/hooks/useJackpot';

export interface JackpotPanelProps {
  pot: 'bnbull' | 'bnb';
  className?: string;
}

export function JackpotPanel({ pot, className = '' }: JackpotPanelProps) {
  const name = pot === 'bnbull' ? 'jackpotBnbull' : 'jackpotBnb';
  const read = useJackpot(name);
  const meta = POTS[pot];
  // The pot's own `prizeToken().symbol()`, live. The constant in brand.ts is
  // only reached once that read has settled with no answer, and NEVER while it
  // is still in flight — an empty string there is deliberate.
  const symbol = potSymbol(read, meta.symbolFallback);

  if (!read.configured) return null;

  // The bar. `pendingPayout / pool` as a percentage, clamped, and simply
  // absent while either half is unknown — a bar drawn off a guess is worse
  // than no bar.
  const pool = read.pool;
  const payout = read.pendingPayout;
  const fillPct =
    pool !== undefined && payout !== undefined && pool > 0n
      ? Math.max(0, Math.min(100, Number((payout * 10_000n) / pool) / 100))
      : null;

  return (
    <div
      className={`pot-card bull-card ${pot === 'bnbull' ? 'pot-bnbull' : 'pot-bnb'} rounded p-4 ${className}`}
    >
      <div className="flex items-baseline justify-between gap-2">
        <p className="bull-header text-xs uppercase tracking-[0.18em] text-bull-text-dim">
          {meta.label}
        </p>
        <span className="pot-chip font-mono text-[10px] uppercase tracking-wide">
          {read.oddsOneIn !== undefined ? `1-in-${String(read.oddsOneIn)}` : meta.odds}
        </span>
      </div>

      <div className="pot-plate mt-3 p-3">
        <p className="font-mono text-[10px] uppercase tracking-wider text-bull-text-faint">
          next winner takes
        </p>
        <p className="pot-figure bull-header mt-1">
          {potFigure(read, 'pendingPayout')}{' '}
          <span className="text-base font-normal">{symbol}</span>
        </p>
      </div>

      {fillPct !== null && (
        <div className="mt-3">
          <div
            className="relative h-2 overflow-hidden rounded-full border border-bull-border bg-black/40"
            role="img"
            aria-label={`${fillPct.toFixed(0)}% of the pool pays out on the next win`}
          >
            <div
              className="absolute inset-y-0 left-0 bg-bull-gold/80"
              style={{ width: `${fillPct}%` }}
            />
          </div>
          <p className="mt-1.5 text-[11px] text-bull-text-faint">
            {potFigure(read, 'pool')}
            {symbol ? ` ${symbol}` : ''} in the pool.{' '}
            {read.payoutBps !== undefined ? formatBps(read.payoutBps) : '—'} of it goes to the next
            winner, the rest rides on to the one after.
          </p>
        </div>
      )}

      <dl className="mt-4 grid grid-cols-2 gap-x-4 border-t border-bull-border pt-3 text-sm">
        <div>
          <dt className="font-mono text-[10px] uppercase tracking-wide text-bull-text-faint">
            all time paid
          </dt>
          <dd className="font-mono" style={{ fontVariantNumeric: 'tabular-nums' }}>
            {potFigure(read, 'totalAwarded')}
          </dd>
        </div>
        <div>
          <dt className="font-mono text-[10px] uppercase tracking-wide text-bull-text-faint">
            times it has fired
          </dt>
          <dd className="font-mono" style={{ fontVariantNumeric: 'tabular-nums' }}>
            {read.error ? '?' : read.awardCount !== undefined ? String(read.awardCount) : '—'}
          </dd>
        </div>
      </dl>
    </div>
  );
}
