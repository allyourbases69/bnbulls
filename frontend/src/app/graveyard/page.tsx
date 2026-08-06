import type { Metadata } from 'next';
import { GraveyardPanel } from '@/components/graveyard/GraveyardPanel';
import { DEATH, EMOJI } from '@/lib/brand';

/**
 * ⚠ THE ROUTE STAYS `/graveyard`. It matches the contract, urls get shared,
 * and a 404 is worse than a label that does not match the path. Only the LABEL
 * is themed, and it comes from `lib/brand.ts` — same precedent fefers set by
 * labelling `/market` "Marketplace".
 */
export const metadata: Metadata = {
  title: DEATH.label,
  description:
    'dead bulls, the revive ladder, and the holder head start before anyone else can take one over.',
};

export default function GraveyardPage() {
  return (
    <div className="mx-auto max-w-4xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">
        {EMOJI.death} {DEATH.label}
      </p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">{DEATH.heading}</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">{DEATH.rule}</p>
      {/* The rescue is the emotional core of this page, per the owner, so it
          runs before any ladder or number. */}
      <p className="mt-3 max-w-2xl text-lg text-bull-text">{DEATH.rescue}</p>
      <p className="mt-3 max-w-2xl text-bull-text-dim">{DEATH.philosophy}</p>
      <div className="mt-10">
        <GraveyardPanel />
      </div>
    </div>
  );
}
