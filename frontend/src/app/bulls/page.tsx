import type { Metadata } from 'next';
import { BullsGrid } from '@/components/bulls/BullsGrid';
import { KING_NAME, SUPPLY } from '@/lib/art/bull';

/**
 * ⚠ THE ONLY PLACE THE WHOLE HERD IS SHOWN. `DECISIONS.md §33` is explicit
 * that the landing page must NOT carry a wall of bulls; the browse page is
 * where they belong, filterable, the way fefers does it.
 */
export const metadata: Metadata = {
  title: 'browse',
  description: `browse all ${SUPPLY} bulls plus the 1/1. filter by tier, weapon and gear.`,
};

export default function BullsPage() {
  return (
    <div className="mx-auto max-w-6xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">the herd</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">every bull, filterable</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        all {SUPPLY} of them plus {KING_NAME.toLowerCase()}, drawn live off the same
        deterministic engine the mint uses. filter by tier, weapon or gear to find one.
      </p>
      <div className="mt-10">
        <BullsGrid />
      </div>
    </div>
  );
}
