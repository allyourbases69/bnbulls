import type { Metadata } from 'next';
import Link from 'next/link';
import { BullsGrid } from '@/components/bulls/BullsGrid';
import { BullSprite } from '@/components/BullSprite';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { getBull } from '@/lib/art/collection';
import { BANDS, BAND_COUNTS, BAND_INFO, KING_ID, KING_NAME, SUPPLY } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import { KING_FLAVOUR, TIER_FLAVOUR } from '@/lib/brand';
import { contractsDeployed } from '@/lib/env';

/**
 * ⚠ THE ONLY PLACE THE HERD IS SHOWN. `DECISIONS.md §33` is explicit that the
 * landing page must NOT carry a wall of bulls; the browse page is where they
 * belong, filterable, the way fefers does it.
 *
 * ⚠ MINTED ONLY. Fefers' equivalent copy is "Every fefer minted to the
 * stomping ground" — the browse page is a record of what has been bought, not
 * a catalogue of the drop. `BullsGrid` enforces it against `nextTokenId`; see
 * its header for what that does and does NOT make secret.
 *
 * ⚠ BEFORE THE DROP OPENS THE GRID IS REPLACED, NOT LEFT EMPTY. A page of
 * filters that filter nothing, over a "not deployed" box, is the single worst
 * thing a stranger can land on: it reads as a broken app rather than a game
 * that has not started. Pre-launch this page is the ladder plus the one bull we
 * are allowed to show, which says the same true things without publishing the
 * unminted table (`DECISIONS.md §34` makes Lord Wagyu the deliberate
 * exception).
 */
export const metadata: Metadata = {
  title: 'browse',
  description: `every bull minted so far, out of ${SUPPLY} plus the 1/1. filter by tier, weapon and gear.`,
};

const king = getBull(KING_ID);

export default function BullsPage() {
  const deployed = contractsDeployed('bullsNft');

  if (!deployed) return <PreLaunchHerd />;

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">the herd</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">every bull minted so far</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        only bulls that exist on chain show up here. the rest of the {SUPPLY}, and{' '}
        {KING_NAME.toLowerCase()}, arrive as they are minted. filter by tier, weapon or gear
        to find one.
      </p>
      <div className="mt-10">
        <BullsGrid />
      </div>
    </div>
  );
}

/**
 * The pre-launch browse page: the king, the ladder, and a straight sentence
 * about why there is nothing else on it.
 *
 * ⚠ WHAT IS SHOWN HERE REVEALS NOTHING TOKEN-SPECIFIC. Tier counts, hide
 * families and beef grades are properties of the COLLECTION and are already on
 * `/about`; none of them says which token is which. The one sprite on the page
 * is #501, and he is on the favicon and the og card already.
 */
function PreLaunchHerd() {
  return (
    <div className="mx-auto max-w-4xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">the herd</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">{SUPPLY} bulls, plus the king</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        nothing has been minted, so there is no herd yet. this page fills up one bull at a time
        as people buy them, and it only ever shows bulls that exist on chain. there is no
        catalogue of what is left, on purpose.
      </p>

      <PreLaunchNotice className="mt-8" />

      {/* ── the one bull we show (DECISIONS.md §34) ──────────────── */}
      <section className="mt-12 grid gap-8 sm:grid-cols-[auto_1fr] sm:items-center">
        <div className="mx-auto w-[200px] rounded border-2 border-bull-gold/70 p-1.5 shadow-[0_0_40px_-14px_rgb(var(--bull-gold)/0.6)] sm:mx-0 sm:w-[224px]">
          <div
            className="aspect-[56/64]"
            style={{ backgroundColor: `rgb(${king.bg[0]} ${king.bg[1]} ${king.bg[2]})` }}
          >
            <BullSprite token={king} fluid />
          </div>
        </div>
        <div>
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
            bnbull #{KING_ID} · the 1/1
          </p>
          <h2 className="bull-header mt-2 text-2xl sm:text-3xl">{KING_NAME.toLowerCase()}</h2>
          <p className="mt-2 text-sm font-semibold text-bull-gold">
            king <span className="text-bull-text-faint">· {KING_FLAVOUR.grade}</span>
          </p>
          <p className="mt-2 text-bull-text-dim">{KING_FLAVOUR.line}</p>
          <Link
            href={`/bull/${KING_ID}`}
            className="mt-4 inline-block rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold hover:bg-bull-gold/10"
          >
            his full papers →
          </Link>
        </div>
      </section>

      {/* ── the ladder ───────────────────────────────────────────── */}
      <section className="mt-14">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">what is in the drop</h2>
        <p className="mt-2 max-w-2xl text-sm text-bull-text-dim">
          the tier a bull lands on is fixed in the contract at deploy and hash-committed there,
          so it cannot be moved afterwards by anyone, us included. three tells escalate
          together and read across a room: the hide family, the horn colour, and whether it has
          boots.
        </p>
        <div className="mt-5 overflow-x-auto">
          <table className="w-full min-w-[520px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                <th className="py-2 pr-4">tier</th>
                <th className="py-2 pr-4">grade</th>
                <th className="py-2 pr-4">how many</th>
                <th className="py-2 pr-4">what it reads as</th>
              </tr>
            </thead>
            <tbody>
              {BANDS.map((band) => (
                <tr key={band} className="border-b border-bull-border/60">
                  <td className={`py-2 pr-4 font-semibold ${TIER_COLOUR[band]}`}>{band}</td>
                  <td className="py-2 pr-4 text-bull-text">{TIER_FLAVOUR[band].grade}</td>
                  <td className="py-2 pr-4 font-mono">{BAND_COUNTS[band]}</td>
                  <td className="py-2 pr-4 text-bull-text-dim">
                    {BAND_INFO[band].family} hide · {TIER_FLAVOUR[band].line}
                  </td>
                </tr>
              ))}
              <tr>
                <td className="py-2 pr-4 font-semibold text-bull-gold">king (1/1)</td>
                <td className="py-2 pr-4 text-bull-gold">{KING_FLAVOUR.grade}</td>
                <td className="py-2 pr-4 font-mono">1</td>
                <td className="py-2 pr-4 text-bull-text-dim">
                  {KING_NAME.toLowerCase()} · {KING_FLAVOUR.line}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="mt-4 text-sm text-bull-text-faint">
          the whole ladder, the mint prices and where the money goes are on{' '}
          <Link href="/about" className="text-bull-gold hover:underline">
            how to play
          </Link>
          .
        </p>
      </section>
    </div>
  );
}
