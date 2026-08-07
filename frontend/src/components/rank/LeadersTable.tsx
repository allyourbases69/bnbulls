'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useAccount } from 'wagmi';
import { BullSprite } from '@/components/BullSprite';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { getBull } from '@/lib/art/collection';
import type { Token } from '@/lib/art/bull';
import { useRoster, type RosterBull } from '@/lib/hooks/useRoster';
import { tierLabel, tierTextClass, type RankTier } from '@/lib/rarity';
import { DEATH, PIT } from '@/lib/brand';

/**
 * /leaders — the DUEL RATING table. Ported from fighting fefers'
 * `app/leaderboard/page.tsx`: same columns in the same order (rank · bull ·
 * rarity · weapon · record · rating), same two filter tabs, same
 * "only bulls that have actually fought" rule, same desktop-table /
 * mobile-card split.
 *
 * ⚠ RATING IS CHAIN STATE, NOT A DERIVATION. `elo`, `wins`, `losses`, `ties`
 * and `isDead` all come off `Bulls.getBull()` through `useRoster`. Nothing on
 * this page is computed by us — the sprite, tier and weapon come from the art
 * tables (which mirror the chain's own shuffle, `DECISIONS.md §27`), and every
 * number comes from a read. There is no fallback and no estimate: a figure we
 * have not got renders as a dash.
 *
 * ⚠ ONE THING FROM FEFERS IS DELIBERATELY NOT PORTED: FEFERS HIDES ITS KING.
 * Its leaderboard drops tokenId 501 with the comment "the King is a 1/1 and
 * doesn't compete in the rankings". On bnbulls he DOES compete —
 * `Bulls.mintKing()` gives #501 a real stat block, level 10, a starting elo of
 * 2000 and the Gilded Pike, `Duel.sol` has no king exception anywhere, and
 * `useRoster().others` already offers him as an opponent in the duel picker. So
 * filtering him out here would hide a bull that can take your money. If the
 * owner ever wants Lord Wagyu out of the rankings, that is a DUEL rule (stop
 * him fighting), not a display rule (stop showing that he did).
 *
 * ⚠ "only bulls that have fought" IS ported. A leaderboard of 500 bulls all
 * sitting on the starting elo is not a leaderboard. The full roster, with
 * filters, is /bulls — same division fefers draws with /browse.
 */
type Filter = 'alive' | 'all';

export function LeadersTable() {
  const roster = useRoster();
  const { address } = useAccount();
  const [filter, setFilter] = useState<Filter>('alive');

  const lower = address?.toLowerCase() ?? null;

  const fighters = useMemo(
    () => roster.all.filter((b) => b.wins > 0 || b.losses > 0 || b.ties > 0),
    [roster.all],
  );

  const ranked = useMemo(() => {
    const list = filter === 'alive' ? fighters.filter((b) => !b.isDead) : fighters;
    return [...list].sort((a, b) => b.elo - a.elo || a.id - b.id);
  }, [fighters, filter]);

  const aliveCount = fighters.filter((b) => !b.isDead).length;

  return (
    <div>
      {/* ⚠ THE CONTROL ROW IS GATED ON `deployed`. Pre-launch it renders
          "still standing (0) · all fighters (0) · 0 ranked by rating" over a box
          saying the collection is not live — a row of filters that filter
          nothing, above an explanation of why. The zeroes look like a failed
          read rather than a game that has not started.

          ⚠ THE FIRST TAB IS `DEATH.standing`, NOT A PIT WORD. It filters on
          `isDead`, so it counts HEARTBEATS. It used to be labelled "in the
          yards", which was harmless while nothing read the roster and is a lie
          now that `PIT` membership is a real on-chain fact: a bull can be very
          much alive and not in the pit, and calling it "in the pit" here would
          send somebody to the duel page with a herd that cannot fight. */}
      {roster.deployed && (
        <div className="flex flex-wrap items-center gap-2">
          <FilterTab
            label={`${DEATH.standing} (${aliveCount})`}
            active={filter === 'alive'}
            onClick={() => setFilter('alive')}
          />
          <FilterTab
            label={`all fighters (${fighters.length})`}
            active={filter === 'all'}
            onClick={() => setFilter('all')}
          />
          <div className="grow" />
          <span className="font-mono text-xs text-bull-text-faint">
            {ranked.length} ranked by rating
          </span>
          <Link
            href="/duel"
            className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold"
          >
            {PIT.label} →
          </Link>
        </div>
      )}

      {/* ⚠ THREE STATES, AND ONLY ONE OF THEM MAY SAY "NOBODY HAS FOUGHT". */}
      {!roster.deployed ? (
        <NotDeployed what="the bulls collection" className="mt-6" />
      ) : roster.isLoading ? (
        <p className="mt-6 text-sm text-bull-text-dim">reading the herd off the chain…</p>
      ) : roster.unavailable ? (
        <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          <p>
            couldn&apos;t read the herd off the chain just now. that is this page failing to
            reach an rpc, not an empty board.
          </p>
          <button
            type="button"
            onClick={roster.refetch}
            className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </div>
      ) : ranked.length === 0 ? (
        <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-6 text-center">
          <p className="text-sm text-bull-text-dim">
            {fighters.length === 0
              ? 'nobody has fought yet. be the first name on the board.'
              : DEATH.noneStanding}
          </p>
          <p className="mt-2 text-sm text-bull-text-faint">
            pick two bulls and send them in at{' '}
            <Link href="/duel" className="text-bull-gold hover:underline">
              {PIT.label}
            </Link>
            . a bull lands here the moment its first fight settles on chain.
          </p>
        </div>
      ) : (
        // ⚠ `overflow-x-auto`, not `overflow-hidden`. Six columns on a narrow
        // laptop must SCROLL the table, never clip a rating off the right edge
        // — and the body already forbids the page itself scrolling sideways
        // (`globals.css`), so an inner scroller is the only place that width
        // can go.
        <div className="mt-6 overflow-x-auto rounded border border-bull-border">
          {/* Desktop */}
          <table className="hidden w-full text-sm md:table">
            <thead>
              <tr className="border-b border-bull-border bg-bull-panel text-xs uppercase tracking-wider text-bull-text-faint">
                <th className="w-16 px-3 py-2 text-right font-medium">rank</th>
                <th className="px-3 py-2 text-left font-medium">bull</th>
                <th className="px-3 py-2 text-left font-medium">rarity</th>
                <th className="px-3 py-2 text-left font-medium">weapon</th>
                <th className="px-3 py-2 text-right font-medium">record</th>
                <th className="px-3 py-2 text-right font-medium">rating</th>
              </tr>
            </thead>
            <tbody>
              {ranked.map((b, i) => (
                <LeaderRow
                  key={b.id}
                  bull={b}
                  rank={i + 1}
                  mine={!!lower && b.owner.toLowerCase() === lower}
                />
              ))}
            </tbody>
          </table>

          {/* Mobile */}
          <div className="divide-y divide-bull-border md:hidden">
            {ranked.map((b, i) => (
              <LeaderCardMobile
                key={b.id}
                bull={b}
                rank={i + 1}
                mine={!!lower && b.owner.toLowerCase() === lower}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

/** Rank 1 takes the star and the gold; below that it fades out rather than
 *  inventing a second and third accent colour the palette does not have. */
function rankClass(rank: number): string {
  if (rank === 1) return 'text-bull-gold';
  if (rank <= 3) return 'text-bull-text';
  return 'text-bull-text-dim';
}

/** One `getBull` per row, shared by everything the row draws — the sprite, the
 *  tier and the weapon all have to come from the same token or a row could
 *  contradict itself. */
function facts(bull: RosterBull): {
  token: Token;
  tier: RankTier;
  weapon: string;
  name: string;
  record: string;
} {
  const token = getBull(bull.id);
  return {
    token,
    tier: token.king ? 'king' : token.band,
    weapon: token.weapon,
    // The CONTRACT's name wins. The dealt table agrees (`verify:rarity` pins
    // it), but the chain is the source.
    name: (bull.name && bull.name.length > 0 ? bull.name : token.name).toLowerCase(),
    record: `${bull.wins}w / ${bull.losses}l / ${bull.ties}t`,
  };
}

function LeaderRow({ bull, rank, mine }: { bull: RosterBull; rank: number; mine: boolean }) {
  const { token, tier, weapon, name, record } = useMemo(() => facts(bull), [bull]);

  return (
    <tr
      className={
        'border-b border-bull-border/40 transition-colors hover:bg-bull-panel-hover ' +
        (mine ? 'bg-bull-gold/5' : '')
      }
    >
      <td className={`bull-header px-3 py-2 text-right tabular-nums ${rankClass(rank)}`}>
        {rank === 1 ? '★ ' : ''}
        {rank}
      </td>
      <td className="px-3 py-2">
        <Link href={`/bull/${bull.id}`} className="group flex items-center gap-3">
          <div className="w-10 shrink-0 bg-bull-bg">
            <BullSprite token={token} fluid />
          </div>
          <div className="min-w-0">
            <div
              className={
                'truncate text-sm leading-tight group-hover:text-bull-gold ' +
                (bull.isDead ? 'text-bull-text-faint line-through' : 'text-bull-text')
              }
              title={name}
            >
              {name}
            </div>
            <div className="flex items-center gap-2 font-mono text-xs text-bull-text-faint">
              <span>#{bull.id}</span>
              {bull.isDead && <span className="text-bull-red">· {DEATH.listHeading}</span>}
              {mine && <span className="text-bull-gold">· you</span>}
            </div>
          </div>
        </Link>
      </td>
      <td className={`px-3 py-2 text-xs uppercase tracking-wider ${tierTextClass(tier)}`}>
        {tierLabel(tier)}
      </td>
      <td className="max-w-[10rem] truncate px-3 py-2 text-xs capitalize text-bull-gold" title={weapon}>
        {weapon}
      </td>
      <td className="px-3 py-2 text-right font-mono text-xs tabular-nums text-bull-text-dim">
        {record}
      </td>
      <td className="px-3 py-2 text-right font-mono tabular-nums">
        <span className="font-bold text-bull-text">{bull.elo}</span>
      </td>
    </tr>
  );
}

function LeaderCardMobile({
  bull,
  rank,
  mine,
}: {
  bull: RosterBull;
  rank: number;
  mine: boolean;
}) {
  const { token, tier, weapon, name, record } = useMemo(() => facts(bull), [bull]);

  return (
    <Link
      href={`/bull/${bull.id}`}
      className={
        'flex items-center gap-3 p-3 transition-colors hover:bg-bull-panel-hover ' +
        (mine ? 'bg-bull-gold/5' : '')
      }
    >
      <div className={`bull-header w-8 text-right text-lg tabular-nums ${rankClass(rank)}`}>
        {rank}
      </div>
      <div className="w-11 shrink-0 bg-bull-bg">
        <BullSprite token={token} fluid />
      </div>
      <div className="min-w-0 flex-1">
        <div
          className={
            'truncate text-sm leading-tight ' +
            (bull.isDead ? 'text-bull-text-faint line-through' : 'text-bull-text')
          }
          title={name}
        >
          {name} <span className="font-mono text-xs text-bull-text-faint">#{bull.id}</span>
        </div>
        <div className="flex flex-wrap items-center gap-x-1.5 text-xs">
          <span className={tierTextClass(tier)}>{tierLabel(tier)}</span>
          <span className="capitalize text-bull-gold">· {weapon}</span>
          <span className="font-mono text-bull-text-dim">· {record}</span>
        </div>
      </div>
      <div className="shrink-0 text-right font-mono">
        <div className="text-lg font-bold tabular-nums text-bull-text">{bull.elo}</div>
        <div className="text-[10px] uppercase tracking-wider text-bull-text-faint">rating</div>
      </div>
    </Link>
  );
}

/** Fefers' leaderboard `FilterTab`, reskinned to match `BullsGrid`'s so the two
 *  list pages carry one control vocabulary. */
function FilterTab({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  const base = 'rounded-full border px-3 py-1.5 text-xs font-medium transition';
  const cls = active
    ? `${base} border-bull-gold text-bull-gold`
    : `${base} border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-text`;
  return (
    <button type="button" className={cls} onClick={onClick}>
      {label}
    </button>
  );
}
