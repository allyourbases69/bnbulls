import type { Metadata } from 'next';
import { PotsPanel } from '@/components/pots/PotsPanel';
import { JackpotPrizeBanner } from '@/components/pots/JackpotPrizeBanner';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { EMOJI, POTS } from '@/lib/brand';

export const metadata: Metadata = {
  title: 'the pots',
  // ⚠ no "no-withdraw" framing here — the pots are pitched as jackpots that
  // grow and pay, not as a trust story. see `POTS` in `lib/brand.ts`.
  description:
    'the two jackpots: bnbull at 1-in-50, bnb at 1-in-100 on every decisive fight. current size, the odds, and every win so far.',
};

export default function PotsPage() {
  return (
    <div className="mx-auto max-w-4xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">
        {EMOJI.pot} the pots
      </p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">two pots, no way out but a win</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        the currency you pay in decides which pot fattens. {POTS.rule}
      </p>
      <PreLaunchNotice className="mt-8" />
      {/* ⚠ ABOVE the pots, not inside one. On the native pot a win is credited
          rather than sent, so the winner's wallet shows nothing until they
          claim — the loudest possible moment to leave someone guessing. It
          renders itself away when there is no prize, so it costs nothing until
          it is the most important thing on the page. */}
      <div className="mt-8">
        <JackpotPrizeBanner />
      </div>
      <div className="mt-10">
        <PotsPanel />
      </div>
    </div>
  );
}
