import type { Metadata } from 'next';
import { DuelPicker } from '@/components/duel/DuelPicker';
import { JackpotPanel } from '@/components/JackpotPanel';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { POTS, PIT } from '@/lib/brand';

/**
 * ⚠ THE ROUTE STAYS `/duel`. The page is LABELLED `PIT.label` — "the bull pit",
 * the owner's own rename of the fighting area — and the url is not touched,
 * because urls get shared and a 404 is worse than a label that does not match a
 * path. Exactly the precedent `/graveyard` set by being labelled "the butcher".
 * The contract behind it stays `Yards` for the same reason, one layer down.
 */
export const metadata: Metadata = {
  title: PIT.label,
  description:
    'pick your bull, get matched on rating, and see exactly what each side puts in before anything is signed.',
};

export default function DuelPage() {
  return (
    <div className="mx-auto max-w-3xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">
        {PIT.eyebrow}
      </p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">{PIT.heading}</h1>
      {/* Fefers' own two lines, translated: "pick your fefer and hit fight.
          we'll find you an opponent." / "winner takes 90% of the pot, and
          every fight rolls for the pots up top." The 90% is `DECISIONS.md
          §23`, not a round number someone liked. The pots sit at the BOTTOM
          here, so the pointer points down. */}
      <p className="mt-3 max-w-xl text-bull-text-dim">{PIT.lead}</p>
      {/* ⚠ THE MEMBERSHIP RULE GOES ABOVE THE FOLD, not in a details block.
          `Duel._requireInYards` reverts `BullNotInYards` on any bull that is
          out, and a player who does not know that reads the resulting failed
          gas estimate as a broken site. */}
      <p className="mt-1 max-w-xl text-sm text-bull-text-dim">{PIT.rule}</p>
      {/* ⚠ "every fight rolls for the pots" was loose enough to be read as the
          banned "every fight rolls BOTH pots" (`VOICE-AND-BRAND.md §2`). A
          decisive fight opens a ticket on both pools and exactly one of them
          can pay. `POTS.rule` is the one sentence that says it correctly, and
          it is used everywhere else, so it is used here too.

          ⚠ THE SELF-DUEL AND ONE-SIGNED-FIGHT RULES USED TO BE ON THE END OF
          THIS LINE AND HAVE MOVED, NOT GONE. They are enforcement trivia, and
          fefers keeps its header to two short lines for exactly that reason —
          what to do, and what you win. They now live in step 3's "how the fight
          is decided" disclosure, next to the button they constrain. */}
      <p className="mt-1 max-w-xl text-sm text-bull-text-dim">
        winner takes 90% of what is in the middle. {POTS.rule}
      </p>

      <PreLaunchNotice className="mt-8" />

      <div className="mt-10">
        <DuelPicker />
      </div>

      {/* ⚠ THE POTS SIT AT THE BOTTOM, SMALL, AND THAT IS DELIBERATE.
          They are standings, not something you act on, so they must not push
          the fight down the page. Fefers ranks the same two elements the same
          way on its own duel page: "these sit BELOW the roster on purpose…
          they're standings, not a thing you act on". Owner call, 2026-08-07:
          "the jackpots should be smaller looking and down the bottom below
          everything else." The full-weight cards still live on `/pots` and
          `/mint`, where the pot IS the pitch. */}
      <div className="mt-14 border-t border-bull-border pt-6">
        <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          what is riding on it
        </p>
        <div className="mt-3 grid gap-3 empty:hidden sm:grid-cols-2">
          <JackpotPanel pot="bnbull" compact />
          <JackpotPanel pot="bnb" compact />
        </div>
      </div>
    </div>
  );
}
