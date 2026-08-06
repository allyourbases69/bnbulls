import type { Metadata } from 'next';
import { DuelPicker } from '@/components/duel/DuelPicker';
import { JackpotPanel } from '@/components/JackpotPanel';

export const metadata: Metadata = {
  title: 'duel',
  description:
    'pick your bull, name an opponent, and see exactly what each side puts in before anything is signed.',
};

export default function DuelPage() {
  return (
    <div className="mx-auto max-w-3xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">⚔️ duel</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">pick a fight</h1>
      <p className="mt-3 max-w-xl text-bull-text-dim">
        a wallet cannot fight itself, and each wallet carries one signed fight in flight at a
        time. both are enforced on chain at settlement, not just checked here. this page reads
        the live guardrails so you cannot build a fight that would revert.
      </p>

      {/* The pots sit at the top of the fight page on fefers, framed as the
          reason to fight. Same slot, same framing. `DECISIONS.md §17` parked
          the arena/roman vocabulary, so only the PLACEMENT is ported. */}
      <div className="mt-8 grid gap-4 empty:hidden sm:grid-cols-2">
        <JackpotPanel pot="bnbull" />
        <JackpotPanel pot="bnb" />
      </div>

      <div className="mt-10">
        <DuelPicker />
      </div>
    </div>
  );
}
