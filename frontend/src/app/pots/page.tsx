import type { Metadata } from 'next';
import { PotsPanel } from '@/components/pots/PotsPanel';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { EMOJI, POTS } from '@/lib/brand';

export const metadata: Metadata = {
  title: 'the pots',
  description:
    'the two no-withdraw pots: bnbull at 1-in-50, bnb at 1-in-100. current size, the odds, and every win so far.',
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
      <div className="mt-10">
        <PotsPanel />
      </div>
    </div>
  );
}
