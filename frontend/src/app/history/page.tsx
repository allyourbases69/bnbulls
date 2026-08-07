import type { Metadata } from 'next';
import Link from 'next/link';
import { DuelHistoryPanel } from '@/components/duel/DuelHistoryPanel';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';

/**
 * /history — the public record of every fight, and the only place you can
 * re-watch one.
 *
 * ⚠ THE REPLAY IS THE POINT OF THIS PAGE. Every row can be played back from the
 * signed seed in its own `DuelCompleted` event, and `/api/duel-gif` refuses
 * with a 409 rather than draw a fight that does not match what the chain
 * recorded. So this is not a log with a nice extra on it — it is the receipt,
 * and the animation is how you check it.
 *
 * Ported from fighting fefers' `/history`. Same shape, bnbulls theme.
 */
export const metadata: Metadata = {
  title: 'history',
  description:
    'every fight ever settled on chain, newest first. watch any of them play back from the seed the fight was signed with.',
};

export default function HistoryPage() {
  return (
    <div className="mx-auto max-w-6xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">the record</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">history</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        every fight ever settled on chain. hit ▶ replay on any row and it plays back from the
        seed that fight was signed with, so what you are watching is the fight itself and not
        a re-enactment of it. click a bull to see their record, or a hash to open it in the
        explorer. the rating board lives on{' '}
        <Link href="/leaders" className="text-bull-gold hover:underline">
          leaders
        </Link>
        .
      </p>
      <PreLaunchNotice className="mt-8" />
      <div className="mt-6">
        <DuelHistoryPanel />
      </div>
    </div>
  );
}
