'use client';

import Link from 'next/link';
import { BullSprite } from '@/components/BullSprite';
import { getBull } from '@/lib/art/collection';
import { KING_ID } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import { DEATH } from '@/lib/brand';
import { useRank } from '@/lib/hooks/useRanks';
import { formatPoints } from '@/lib/rank';

/**
 * ONE bull card. A direct port of fighting fefers' `OutlawCard`, field for
 * field and in the same order:
 *
 *   #id + tier badge · sprite · name · weapon · RATING + W/L/T · dead badge
 *
 * ⚠ THE POINT IS THE DATA, NOT THE FRAME. Owner, 2026-08-07: "simple things
 * like minting and showing the nfts with rich data experience". A card that is
 * a picture and a number is not what fefers ships and is not the bar. Every
 * bull the site lists — browse, the post-mint reveal, the duel picker — uses
 * this one component so none of them can drift back to an id and a sprite.
 *
 * ⚠ ONE ART PATH, ONE STAT PATH. Sprite, tier, name and weapon come from
 * `getBull`, which is what `/bulls` and `/bull/[id]` already draw with and
 * which mirrors the chain's own rarity shuffle and weapon slice
 * (`DECISIONS.md §27`, pinned by `npm run verify:rarity`). Rating, record and
 * alive/dead are contract state and come from whatever the caller READ. A
 * figure the caller has not got renders as a dash. Nothing here is estimated.
 */
export interface BullFacts {
  /** The name the CONTRACT holds. Falls back to the dealt table when absent. */
  readonly name?: string;
  readonly elo?: number;
  readonly wins?: number;
  readonly losses?: number;
  readonly ties?: number;
  readonly isDead?: boolean;
}

export function BullCard({
  id,
  facts,
  scale = 3,
  className = '',
}: {
  id: number;
  facts?: BullFacts;
  scale?: number;
  className?: string;
}) {
  const token = getBull(id);
  const isKing = id === KING_ID;
  const isDead = facts?.isDead === true;
  const name = facts?.name ?? token.name;
  const tierLabel = isKing ? 'king 1/1' : token.band;
  const record =
    facts?.wins !== undefined && facts?.losses !== undefined && facts?.ties !== undefined
      ? `${facts.wins}w / ${facts.losses}l / ${facts.ties}t`
      : null;

  return (
    <div className={className}>
      <div className="mb-1 flex items-center justify-between gap-2">
        <span className="font-mono text-xs text-bull-text-faint">#{token.id}</span>
        <span
          className={`bull-header text-[10px] uppercase tracking-wider ${TIER_COLOUR[token.band]}`}
        >
          {tierLabel}
        </span>
      </div>

      <div className="mb-2 flex justify-center bg-bull-bg py-1">
        <BullSprite token={token} scale={scale} />
      </div>

      <div
        className={`truncate text-sm leading-tight ${isDead ? 'text-bull-text-faint line-through' : 'text-bull-text'}`}
        title={name}
      >
        {name.toLowerCase()}
      </div>

      <div className="mb-2 truncate text-xs capitalize text-bull-gold" title={token.weapon}>
        {token.weapon}
      </div>

      {/* ⚠ TWO ROWS, EACH `justify-between` + `flex-wrap`, ported from fefers'
          `OutlawCard` including its comment: at ~145px in the 2-column phone
          grid "RATING 1000" and "0W / 0L / 0T" do not fit side by side, and
          without the wrap + `whitespace-nowrap` pair the VALUES broke inside
          themselves ("RANK #7 /" then "34", which reads as a different number
          entirely). Each value stays whole and drops to its own line when
          there is no room, which is the stacked look in the screenshot. */}
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 text-xs">
        <span className="whitespace-nowrap font-mono">
          <span className="text-bull-text-faint">rating </span>
          <span className="font-bold text-bull-text">{facts?.elo ?? '—'}</span>
        </span>
        <span className="whitespace-nowrap font-mono text-bull-text-dim">{record ?? '—'}</span>
      </div>

      {/* RARITY RANK — a different axis from the duel rating above it, which is
          why it gets its own row rather than being crammed onto that one.
          Renders nothing at all until the minted count is known: rank is
          measured against the minted set, so before that there is no honest
          number and a placeholder would be a fake position. */}
      <RankRow tokenId={token.id} />

      {isDead && (
        <div className="mt-2 text-[10px] uppercase tracking-wider text-bull-red">
          💀 {DEATH.listHeading}
        </div>
      )}
    </div>
  );
}

/**
 * `RANK #61 / 147` on the left, `374 pts` on the right — fefers' second stats
 * row, laid out the same way as the rating row above it.
 *
 * ⚠ USES THE HOOK RATHER THAN `<RankLine>` ON PURPOSE. `RankLine` prints the
 * whole thing as one run (`rank #61 / 147 · 374 pts`), which is right for a
 * one-line context; the browse card in the screenshot puts the rank and the
 * points at opposite ends of a `justify-between` row so they line up under
 * `RATING` and the record. Same numbers, same source, same `null`-until-known
 * behaviour — only the arrangement differs. And no `link`: this row sits
 * inside `BullCardLink`'s anchor, and nested anchors are invalid HTML.
 */
function RankRow({ tokenId }: { tokenId: number }) {
  const rank = useRank(tokenId);
  if (!rank) return null;
  return (
    <div className="mt-1 flex flex-wrap items-baseline justify-between gap-x-3 text-xs">
      <span className="whitespace-nowrap font-mono tabular-nums">
        <span className="text-bull-text-faint">rank </span>
        <span className="font-bold text-bull-gold">#{rank.rank}</span>
        <span className="text-bull-text-faint"> / {rank.rankOf}</span>
      </span>
      <span className="whitespace-nowrap font-mono tabular-nums text-bull-text-faint">
        {formatPoints(rank.score)}
      </span>
    </div>
  );
}

/** The same card, clickable through to the bull's own page — which is how
 *  every card in fefers' browse grid behaves. */
export function BullCardLink({
  id,
  facts,
  scale = 3,
  className = '',
}: {
  id: number;
  facts?: BullFacts;
  scale?: number;
  className?: string;
}) {
  return (
    <Link
      href={`/bull/${id}`}
      className={`bull-card block rounded border border-bull-border p-3 transition hover:border-bull-gold ${className}`}
    >
      <BullCard id={id} facts={facts} scale={scale} />
    </Link>
  );
}
