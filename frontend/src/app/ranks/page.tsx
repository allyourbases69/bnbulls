import type { Metadata } from 'next';
import Link from 'next/link';
import { RanksTable } from '@/components/rank/RanksTable';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { SUPPLY } from '@/lib/art/bull';

/**
 * /ranks — RARITY RANK. Ported from fighting fefers' ranks page.
 *
 * ⚠ THE TWO NUMBERS ARE DIFFERENT AND THE PAGE HAS TO SAY SO. Rank is how rare
 * a bull IS. Rating is elo — how good it fights — and it lives on /leaders.
 * Fefers puts that sentence in the first paragraph of this page, and it is the
 * whole reason nobody over there reads a rarity table as a power ranking.
 */
export const metadata: Metadata = {
  title: 'rarity rank',
  description: `every bull people hold, ranked by how rare it is. rank 1 = rarest, out of ${SUPPLY} plus the 1/1.`,
};

export default function RanksPage() {
  return (
    <div className="mx-auto max-w-4xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">the ladder</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">rarity rank</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        {/* ⚠ "PEOPLE HOLD", not "minted". The pen is stocked by minting the
            whole unsold supply into it, so a field of "every minted bull" would
            be the entire drop from day one — and a rank measured against bulls
            nobody has bought is a rank against a field that is not playing. */}
        rank 1 = rarest. the score adds up tier, weapon and stat-distribution rarity across
        every bull people hold so far. this is not your duel{' '}
        <Link href="/leaders" className="text-bull-gold hover:underline">
          rating
        </Link>
        : it is how rare the bull <em>is</em>, not how good it fights.
      </p>
      <PreLaunchNotice className="mt-8" />
      <div className="mt-6">
        <RanksTable />
      </div>
    </div>
  );
}
