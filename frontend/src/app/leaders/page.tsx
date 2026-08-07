import type { Metadata } from 'next';
import Link from 'next/link';
import { LeadersTable } from '@/components/rank/LeadersTable';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { PIT } from '@/lib/brand';

/**
 * /leaders — the DUEL RATING board. Ported from fighting fefers'
 * `/leaderboard`, at the shorter route the owner's spec names.
 *
 * ⚠ THE OTHER HALF OF /ranks. Rank is how rare a bull is; rating is how well it
 * fights. Each page links to the other in its first paragraph so neither number
 * can be mistaken for the other.
 */
export const metadata: Metadata = {
  title: 'leaders',
  description: PIT.leadersDescription,
};

export default function LeadersPage() {
  return (
    <div className="mx-auto max-w-6xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">the board</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">leaders</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        {PIT.onlyFought} ranked by rating: beat a higher-rated bull
        and you climb faster. this is how good it fights, not how rare it is, which is what{' '}
        <Link href="/ranks" className="text-bull-gold hover:underline">
          rarity rank
        </Link>{' '}
        measures. the full herd, with filters, lives on{' '}
        <Link href="/bulls" className="text-bull-gold hover:underline">
          browse
        </Link>
        .
      </p>
      <PreLaunchNotice className="mt-8" />
      <div className="mt-6">
        <LeadersTable />
      </div>
    </div>
  );
}
