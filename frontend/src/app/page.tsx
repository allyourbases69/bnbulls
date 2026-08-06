import Link from 'next/link';
import { BullSprite } from '@/components/BullSprite';
import { JackpotPanel } from '@/components/JackpotPanel';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { getBull } from '@/lib/art/collection';
import { KING_ID } from '@/lib/art/bull';
import { HERO_LINE } from '@/lib/brand';

/**
 * THE LANDING PAGE.
 *
 * The SKELETON is fighting fefers' home page (`DECISIONS.md §33`, owner:
 * "other than the theme, lore etc, keep the same layout as fefers"): the 1/1
 * alone and centred, then the way into the game, then the pots, then the
 * "first time here?" pointer. Full-height, centred, one column.
 *
 * ⚠⚠ THE COPY IS ONE LINE, AND THAT IS THE WHOLE INSTRUCTION. ⚠⚠
 * Owner, directly: strip the explanatory copy, just leave `HERO_LINE`. There
 * is no subtitle, no tagline, no caption naming the king, no "the deal" block,
 * no stat row, and no CTA under the line. `VOICE-AND-BRAND.md §1`: "never
 * explain the joke, the sentence after a punchline kills it."
 *
 * The facts that used to be here (1 of 1, token 501, what the other 500 do)
 * are still on the site, at `/about` and `/bull/501`. They are just not the
 * first thing anybody reads. If you are about to add a sentence to this page,
 * that is where it goes.
 *
 * ⚠ THERE IS NO GRID OF BULLS HERE (`§33`, owner: "don't show all those BULLS
 * on there, just use the King Wagyu"). The full herd lives at `/bulls`.
 *
 * ⚠ THE KING IS RENDERED LIVE FROM THE ART ENGINE, not from a static file.
 * Fefers used a checked-in `/original.png` here and it silently went stale the
 * moment the king got its coronation treatment. It matters again right now:
 * his weapon is being redesigned, and rendering through `renderTile` means the
 * hero picks the new one up for free. `getBull` runs at build time (pure,
 * deterministic, no client cost) and hands the token down as plain data.
 */

const king = getBull(KING_ID);

export default function HomePage() {
  return (
    <div className="bg-yard-grid relative flex min-h-[calc(100vh-4rem)] items-center justify-center overflow-hidden px-4 py-10 md:p-8">
      <div className="relative z-10 w-full max-w-3xl space-y-10 text-center">
        {/* LORD WAGYU. Him alone, big, not in a grid, and with no caption
            telling you who he is. He is the picture; the line is the pitch.

            ⚠ THE SIZE LIVES ON THE FRAME, NOT ON THE CANVAS. `fluid` makes the
            sprite `width: 100%`, so its parent decides how big the king is;
            a width class on the canvas gets overridden by that inline style
            and he renders at his intrinsic 56px. The frame also RESERVES the
            space via aspect-ratio, so the page cannot jump when the canvas
            paints. */}
        <div className="flex justify-center">
          <div className="w-[236px] rounded-md border-2 border-bull-gold/70 p-1.5 shadow-[0_0_50px_-12px_rgb(var(--bull-gold)/0.6)] sm:w-[280px] md:w-[336px]">
            {/* ⚠ THE PLATE IS PAINTED IN THE SPRITE'S OWN BACKGROUND COLOUR,
                taken from the engine rather than typed in. `BullSprite` fills
                its canvas in an effect, so on a cold load there is one frame
                where nothing is drawn yet — and on THIS page the king is the
                entire page, so that frame was a gold rectangle around a black
                hole. Matching the tile's background turns the gap into an
                empty plate nobody notices, and it re-themes itself if the
                band palette ever moves. */}
            <div
              className="aspect-[56/64]"
              style={{ backgroundColor: `rgb(${king.bg[0]} ${king.bg[1]} ${king.bg[2]})` }}
            >
              <BullSprite token={king} fluid />
            </div>
          </div>
        </div>

        <h1 className="bull-header mx-auto max-w-2xl text-balance text-xl leading-snug text-bull-text sm:text-2xl md:text-3xl">
          {HERO_LINE}
        </h1>

        {/* The pots, live and growing. Same standing panels as /pots; each
            renders nothing at all when its address is unset, and `empty:hidden`
            stops the row eating a gap while that is true. Numbers, not copy. */}
        <div className="mx-auto grid max-w-2xl gap-4 text-left empty:hidden sm:grid-cols-2">
          <JackpotPanel pot="bnbull" />
          <JackpotPanel pot="bnb" />
        </div>

        {/* The way in. Fefers puts exactly these three here; they are
            navigation, not a pitch, and they carry no explanatory copy. */}
        <div className="flex flex-wrap items-center justify-center gap-3">
          <Link href="/mint" className="bull-btn">
            mint a bull
          </Link>
          <Link href="/duel" className="bull-btn bull-btn-secondary">
            pick a fight
          </Link>
          <Link href="/bulls" className="bull-btn bull-btn-secondary">
            browse the herd
          </Link>
        </div>

        {/* The pointer to everything that came off this page. */}
        <p className="font-mono text-sm text-bull-text-faint">
          first time here?{' '}
          <Link href="/about" className="text-bull-gold hover:underline">
            read the handbook
          </Link>
        </p>

        {/* The honest pre-launch state, and the only paragraph allowed on this
            page: the site is live while the contracts are not, so it has to
            say so. It renders NOTHING once they are wired, which is also why
            it is safe to keep here. */}
        <PreLaunchNotice />
      </div>
    </div>
  );
}
