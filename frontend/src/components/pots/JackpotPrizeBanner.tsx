'use client';

import { formatUnits } from 'viem';
import { useJackpotPrize } from '@/lib/hooks/useJackpotPrize';
import { NATIVE_POT_DECIMALS } from '@/lib/env';
import { POTS } from '@/lib/brand';

/**
 * "YOU WON THE POT, COME AND GET IT."
 *
 * ⚠ THIS EXISTS BECAUSE THE JACKPOT CARD LIES BY OMISSION WITHOUT IT. On the
 * native pot a win is a storage write (`owed[winner]`), not a transfer — see
 * `useJackpotPrize` for why the batch resolve cannot safely push money. The
 * `Awarded` event is byte-identical to the old contract's, so the telegram bot
 * announces a winner exactly as loudly as it always did, for money that has not
 * moved. Without something on the site saying "it is waiting for you", the
 * player's whole experience is: a card says they won, their wallet says
 * otherwise. That reads as theft, and it would be the most damaging possible
 * misunderstanding for a game whose product is a jackpot.
 *
 * Renders nothing when there is no prize, so it is silent until the one moment
 * it is the most important thing on the page.
 */
export function JackpotPrizeBanner() {
  const prize = useJackpotPrize('jackpotBnb');

  // Off a read that LANDED. An unread balance must never render as a prize,
  // and must never render as "nothing owing" either — it simply says nothing.
  if (!prize.hasPrize) return null;

  const amount = Number(formatUnits(prize.owed ?? 0n, NATIVE_POT_DECIMALS)).toFixed(6);

  return (
    <div
      role="status"
      className="rounded border border-bull-gold bg-bull-panel px-4 py-3 text-sm"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="text-bull-text">
          <strong className="bull-header text-bull-gold">{amount} bnb</strong> of{' '}
          {POTS.bnb.label} is waiting for you
        </span>
        <button
          type="button"
          onClick={() => void prize.claim()}
          disabled={prize.isBusy}
          className="shrink-0 rounded-full border border-bull-gold px-3 py-1 text-xs font-semibold text-bull-gold hover:bg-bull-gold/10 disabled:opacity-40"
        >
          {prize.isBusy ? 'working…' : 'claim it'}
        </button>
      </div>
      <p className="mt-1 text-xs text-bull-text-faint">{POTS.prizeHeld}</p>
    </div>
  );
}
