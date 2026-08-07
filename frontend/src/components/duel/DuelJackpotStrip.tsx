'use client';

/**
 * THE POTS, PINNED ACROSS THE TOP OF THE FIGHT.
 *
 * The reference frame carries one strip above the fighters — "JACKPOT 35,332
 * $FIGHT · 1 in 50 fights" — and it is doing real work: it is the reason the
 * fight matters beyond the purse, and it sits in the player's eyeline for the
 * whole three to six seconds without competing with the hp bars.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ bnbulls HAS TWO POOLS, AND "WIN BOTH POTS" IS A BANNED PHRASE.
 * ═══════════════════════════════════════════════════════════════════════
 * `VOICE-AND-BRAND.md §2` bans it as a FACTUAL error: a fight opens a ticket on
 * each pool at its own odds and the first to roll takes it, so one fight never
 * pays both. Two numbers side by side is exactly the layout that would imply
 * otherwise, so the strip says so out loud in `POT_STRIP.neverBoth` rather than
 * leaving a player to add them up.
 *
 * ⚠ EVERY NUMBER IS READ, NONE ARE WRITTEN. The figures come from `useJackpot`
 * — the same hook `PotTicker` and the standing panels use, at the same refresh,
 * so react-query serves all three off ONE set of reads and no surface can drift
 * from another. The ticker beside each figure is the prize token's own
 * `symbol()`, and the odds are the pot's own `oddsOneIn`. Nothing here is
 * hardcoded, which also means an unread pot prints `—` or `?` and no odds at
 * all instead of a confident guess.
 *
 * Renders NOTHING when neither pot has an address, which is the whole
 * pre-deploy state, and it costs zero rpc calls to be in that state.
 */
import { POTS } from '@/lib/brand';
import {
  potFigure,
  potHeadline,
  potSymbol,
  useJackpot,
  TICKER_REFRESH_MS,
  type JackpotRead,
} from '@/lib/hooks/useJackpot';
import { POT_STRIP } from '@/components/duel/duelCopy';

export function DuelJackpotStrip() {
  const bnbull = useJackpot('jackpotBnbull', TICKER_REFRESH_MS);
  const bnb = useJackpot('jackpotBnb', TICKER_REFRESH_MS);
  if (!bnbull.configured && !bnb.configured) return null;

  return (
    <div className="duel-jackpot-strip flex flex-wrap items-center justify-center gap-x-3 gap-y-1 px-3 py-1.5 text-center">
      <span className="bull-header text-[0.6rem] tracking-[0.2em] text-bull-text-faint md:text-[0.68rem]">
        {POT_STRIP.label}
      </span>
      {bnbull.configured && (
        <PotFigure read={bnbull} fallback={POTS.bnbull.symbolFallback} tone="gold" />
      )}
      {bnbull.configured && bnb.configured && (
        <span aria-hidden className="text-bull-text-faint">
          ·
        </span>
      )}
      {bnb.configured && <PotFigure read={bnb} fallback={POTS.bnb.symbolFallback} tone="steel" />}
      {bnbull.configured && bnb.configured && (
        <span className="hidden font-mono text-[0.6rem] text-bull-text-faint sm:inline">
          · {POT_STRIP.neverBoth}
        </span>
      )}
    </div>
  );
}

function PotFigure({
  read,
  fallback,
  tone,
}: {
  read: JackpotRead;
  fallback: string;
  tone: 'gold' | 'steel';
}) {
  const symbol = potSymbol(read, fallback);
  // `oddsOneIn` is a live read. No answer means no odds printed, never the
  // brand string standing in for one: this strip sits beside a real pot figure
  // and an invented probability next to a real number reads as fact.
  const oneIn = read.oddsOneIn !== undefined ? Number(read.oddsOneIn) : null;

  return (
    <span
      className="flex items-baseline gap-1.5 font-mono text-xs md:text-sm"
      style={{ fontVariantNumeric: 'tabular-nums' }}
    >
      <span className={tone === 'gold' ? 'text-bull-gold' : 'text-bull-text-dim'}>
        {potHeadline(potFigure(read, 'pool'))}
      </span>
      {symbol && <span className="text-bull-text-dim">{symbol}</span>}
      {oneIn !== null && oneIn > 0 && (
        <span className="text-[0.6rem] text-bull-text-faint md:text-xs">
          · {POT_STRIP.odds(oneIn)}
        </span>
      )}
    </span>
  );
}
