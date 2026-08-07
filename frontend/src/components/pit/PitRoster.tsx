'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useAccount } from 'wagmi';
import { BullSprite } from '@/components/BullSprite';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { getBull } from '@/lib/art/collection';
import type { Token } from '@/lib/art/bull';
import { useRoster, type RosterBull } from '@/lib/hooks/useRoster';
import { usePitPool } from '@/lib/hooks/useYards';
import { tierLabel, tierTextClass, type RankTier } from '@/lib/rarity';
import { PIT } from '@/lib/brand';

/**
 * WHO IS WAITING IN THE BULL PIT — the whole roster, densest form, best first.
 *
 * Owner, 2026-08-07: "bulls waiting in bull pit should look nice with their
 * previous like this", against the fefers "waiting in the stomping ground"
 * grid. Same information density and the same at-a-glance scan, in our palette
 * and our words: a small sprite, the name, the tier as a COLOURED WORD, the
 * rating and the record, three to a row, sorted by rating.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHAT "WAITING" MEANS HERE, AND WHY IT IS NOT A CACHED LIST
 * ═══════════════════════════════════════════════════════════════════════
 * A card on this grid is a claim that the bull can be picked and fought right
 * now, so it has to be true at the moment it is painted:
 *
 *   · MEMBERSHIP IS LIVE. `usePitPool` is one `inYardsMany` over the living
 *     roster, and that view resolves each bull's owner INSIDE the contract, so
 *     the answer already folds in ownership. That matters more than it sounds:
 *     `Yards` stores `(enteredBy, leavesAt)` and requires `enteredBy == the
 *     live owner`, so a SALE silently voids a pit spot with no event and no
 *     ERC-721 hook. Any roster built once and kept is stale by construction —
 *     which is exactly the shape of the duel that broke this morning. The hook
 *     polls and refetches on window focus for that reason.
 *
 *   · A BULL WITH AN EJECT STAMPED IS NOT WAITING. It is still `inYards` on
 *     chain so an already-signed loss can land (`Yards.sol`'s anti-dodge
 *     bound), but the matchmaker drops it the second the eject confirms, so no
 *     NEW fight will ever be offered against it. Listing it as available would
 *     be offering a fight nobody can take. `usePitPool.matchable` is exactly
 *     that set: in, and not leaving. The header counts them separately rather
 *     than hiding them.
 *
 *   · AN UNKNOWN MEMBERSHIP IS UNKNOWN. `matchable` is `null` until BOTH reads
 *     land, and null renders as loading — never as an empty pit and never as a
 *     bull quietly missing from the grid. An rpc hiccup must not be allowed to
 *     say "there is nobody to fight", and the count on the right is simply not
 *     printed until there is a real one to print.
 *
 * ⚠ THE POOL IS THE LIVING ROSTER, and the ids handed to `usePitPool` are the
 * same list `DuelPicker` hands it, in the same order, so the two share one
 * cached read rather than issuing two. A dead bull is on the truck and cannot
 * fight whatever `Yards` still says about it, so it is not "waiting" by any
 * useful reading of the word.
 *
 * ⚠ NO COLOUR IS WRITTEN HERE. The tier word takes `tierTextClass`, which
 * resolves to the `--rarity-*` custom properties, so a bull glows the same
 * colour on this grid as on /ranks, /leaders and the browse grid. Everything
 * else on the card is deliberately quiet: the tier is the only thing doing
 * colour work, which is the whole point of the layout.
 */

/** How many cards paint before the "show the rest" button. The pit is bounded
 *  at 501, and every card renders a real canvas off the art engine, so the
 *  first screen is not made to wait on the last one. */
const FIRST_PAGE = 60;

export function PitRoster({ className = '' }: { className?: string }) {
  const roster = useRoster();
  const { address } = useAccount();
  const [showAll, setShowAll] = useState(false);

  // ⚠ Same derivation as `DuelPicker`'s, deliberately: identical ids in an
  // identical order means one shared `inYardsMany` read, not two.
  const alive = useMemo(() => roster.all.filter((b) => !b.isDead), [roster.all]);
  const aliveIds = useMemo(() => alive.map((b) => b.id), [alive]);
  const pit = usePitPool(aliveIds);

  /** `null` while membership is unknown. Sorted best first, id breaking ties,
   *  the same order `/leaders` ranks in. */
  const waiting = useMemo<RosterBull[] | null>(() => {
    const matchable = pit.matchable;
    if (!matchable) return null;
    return alive
      .filter((b) => matchable.has(b.id))
      .sort((a, b) => b.elo - a.elo || a.id - b.id);
  }, [alive, pit.matchable]);

  /** In the pit with a departure stamped. Counted, never listed as available. */
  const leaving = useMemo(() => {
    const matchable = pit.matchable;
    if (!matchable) return 0;
    return alive.filter((b) => pit.inPit.has(b.id) && !matchable.has(b.id)).length;
  }, [alive, pit.inPit, pit.matchable]);

  const wallets = useMemo(
    () => (waiting ? new Set(waiting.map((b) => b.owner.toLowerCase())).size : 0),
    [waiting],
  );

  const lower = address?.toLowerCase() ?? null;
  const shown = waiting && !showAll ? waiting.slice(0, FIRST_PAGE) : waiting;

  return (
    <div className={className}>
      {/* ── HEADER: the label left, the truth right ───────────────────
          ⚠ THE COUNT IS NOT PRINTED UNTIL IT IS KNOWN. A number here is a
          claim about how many fights are actually on offer, and a placeholder
          would be the same class of lie as rendering an ejected bull as
          gone. */}
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
          waiting in {PIT.label}
        </p>
        {waiting && (
          <p className="font-mono text-[11px] text-bull-text-faint">
            {waiting.length} {PIT.inLabel}
            {leaving > 0 ? ` · ${leaving} ${PIT.leavingLabel}` : ''} · {wallets} wallet
            {wallets === 1 ? '' : 's'}
          </p>
        )}
      </div>

      {/* ⚠ FIVE STATES, AND ONLY ONE OF THEM MAY SAY THE PIT IS EMPTY. Not
          deployed, still reading, read and failed, nothing minted, and an
          actual empty pit are five different facts. */}
      {!roster.deployed || !pit.deployed ? (
        <NotDeployed what={PIT.label} className="mt-3" />
      ) : roster.unavailable || pit.unavailable ? (
        <div className="mt-3 text-sm text-bull-text-dim">
          <p>{PIT.unreadable}</p>
          <button
            type="button"
            onClick={() => {
              roster.refetch();
              pit.refetch();
            }}
            className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </div>
      ) : roster.isLoading || waiting === null ? (
        <p className="mt-3 text-sm text-bull-text-dim">{PIT.loading}</p>
      ) : waiting.length === 0 ? (
        <p className="mt-3 text-sm text-bull-text-dim">
          {leaving > 0
            ? `every bull in ${PIT.short} has an eject stamped, so there is nobody to match right now.`
            : PIT.empty}
        </p>
      ) : (
        <>
          {/* ⚠ THREE COLUMNS ON A DESKTOP, ONE ON A PHONE. The card is a
              sprite BESIDE its facts, so it needs its width: at 390px a third
              of the screen would truncate every name to two letters. One
              column keeps the same row, full width, still scannable. */}
          <ul className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-2 md:grid-cols-3">
            {shown?.map((b) => (
              <PitCard key={b.id} bull={b} mine={!!lower && b.owner.toLowerCase() === lower} />
            ))}
          </ul>

          {!showAll && waiting.length > FIRST_PAGE && (
            <button
              type="button"
              onClick={() => setShowAll(true)}
              className="mt-3 rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold"
            >
              show the other {waiting.length - FIRST_PAGE}
            </button>
          )}
        </>
      )}
    </div>
  );
}

/**
 * One `getBull` per card, shared by everything the card draws. The sprite, the
 * tier and the name all have to come off the same token or a card could
 * contradict itself — the same rule `LeadersTable.facts()` follows.
 */
function facts(bull: RosterBull): {
  token: Token;
  tier: RankTier;
  name: string;
  record: string;
} {
  const token = getBull(bull.id);
  return {
    token,
    tier: token.king ? 'king' : token.band,
    // The CONTRACT's name wins. The dealt table agrees (`verify:rarity` pins
    // it), but the chain is the source.
    name: (bull.name && bull.name.length > 0 ? bull.name : token.name).toLowerCase(),
    record: `${bull.wins}w / ${bull.losses}l / ${bull.ties}t`,
  };
}

/**
 * THE CARD. Sprite left, then name · tier · rating · record, in that order:
 *
 *   [🐂]  lanky bazza                you
 *         EPIC · R 1227
 *         77w / 29l / 0t
 *
 * ⚠ `uppercase` IS A CSS DECISION, NOT A COPY ONE. Every string in the source
 * stays lowercase (`VOICE-AND-BRAND.md §1`) and the shouting is done by the
 * stylesheet, the same way every other label on this site does it. That keeps
 * `tierLabel()` the single spelling of a tier and lets the grid read as loud as
 * the screenshot does.
 */
function PitCard({ bull, mine }: { bull: RosterBull; mine: boolean }) {
  const { token, tier, name, record } = useMemo(() => facts(bull), [bull]);

  return (
    <li>
      <Link
        href={`/bull/${bull.id}`}
        className={`group flex items-start gap-2.5 rounded border p-2 transition hover:border-bull-gold ${
          mine ? 'border-bull-gold/40 bg-bull-gold/5' : 'border-bull-border bg-bull-bg'
        }`}
      >
        {/* `w-10` is `LeadersTable`'s row-sprite width, so a bull is the same
            size here as it is on the board it climbs. `fluid` keeps the canvas
            at its intrinsic 71x64 and lets CSS size it, `image-rendering:
            pixelated` and all. */}
        <div className="w-10 shrink-0">
          <BullSprite token={token} fluid />
        </div>

        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-1.5">
            <span
              className="min-w-0 flex-1 truncate text-xs font-bold leading-tight text-bull-text group-hover:text-bull-gold"
              title={`${name} #${bull.id}`}
            >
              {name}
            </span>
            {mine && (
              <span className="shrink-0 font-mono text-[10px] text-bull-gold">you</span>
            )}
          </div>

          {/* THE ONE LINE DOING COLOUR WORK. The tier ink comes off
              `--rarity-*` via `tierTextClass`, never a hex. */}
          <div className="mt-0.5 flex flex-wrap items-baseline gap-x-1.5 font-mono text-[10px] leading-tight">
            <span className={`uppercase tracking-wider ${tierTextClass(tier)}`}>
              {tierLabel(tier)}
            </span>
            <span className="text-bull-text-faint">·</span>
            <span className="whitespace-nowrap tabular-nums">
              <span className="uppercase text-bull-text-faint">r </span>
              <span className="font-bold text-bull-text">{bull.elo}</span>
            </span>
          </div>

          <div className="mt-0.5 font-mono text-[10px] leading-tight tabular-nums text-bull-text-faint">
            {record}
          </div>
        </div>
      </Link>
    </li>
  );
}
