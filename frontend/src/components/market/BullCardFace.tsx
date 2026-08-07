'use client';

import { BullSprite } from '@/components/BullSprite';
import { type Token } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import type { BullRecord } from './bullRecord';

/**
 * The face of a bull card — a port of fighting fefers' `OutlawCard` /
 * `/market` `ListingCard` face, beat for beat: id + rarity badge on the top
 * row, a square art box, the name, the weapon, then rating and record.
 *
 * ⚠ ONE ART PATH, NOT TWO. The sprite comes from `getBull(id)` →
 * `BullSprite`, the same call `/bull/[id]`, `/bulls` and the homepage make.
 * A market-only thumbnail pipeline would be a second place for the art to
 * disagree with the chain, and `DECISIONS.md §27` is what that costs.
 *
 * ⚠ NOTHING HERE IS INVENTED. The name and the tier come off the chain's own
 * shuffle, ported (`chainBandMap()`, `assignNames()`, pinned by
 * `npm run verify:rarity`). Rating and record come off `Bulls.getBull`, and
 * when that read has not landed they render as a marker, never as a zero.
 *
 * Two things on fefers' card have no bnbulls equivalent and are deliberately
 * absent rather than faked:
 *   - `FounderBadge` — founder tiers are DELETED (`DECISIONS.md §11`).
 *   - the rarity RANK row (`useOutlawRanks`) — bnbulls has no rank scorer, and
 *     inventing a score here would be a number nobody can vouch for.
 */
export function BullCardFace({
  token,
  record,
  recordFailed,
}: {
  token: Token;
  /** `null` while `Bulls.getBull` is in flight, or if it failed. */
  record: BullRecord | null;
  /** The read settled with no answer, so `null` means "couldn't load" rather
   *  than "still loading". Without it the art box and the stats say "…"
   *  forever — fefers hit exactly this and passed `rosterFailed` down for it. */
  recordFailed?: boolean;
}) {
  const isDead = record?.isDead ?? false;
  const tierLabel = token.king ? 'king' : token.band;
  const tierClass = token.king ? 'text-bull-gold' : TIER_COLOUR[token.band];
  const stat = (v: number | undefined) => (record ? v : recordFailed ? '—' : '…');

  return (
    <>
      {/* Top row: token id + rarity badge. */}
      <div className="mb-1 flex items-center justify-between">
        <div className="font-mono text-sm text-bull-text-faint">#{token.id}</div>
        <div className={`bull-header text-xs uppercase tracking-wider ${tierClass}`}>
          {tierLabel}
        </div>
      </div>

      {/* Art. Square box like fefers so every card in the grid is the same
          height whatever the sprite does inside it. */}
      <div className="mb-2 flex aspect-square w-full items-center justify-center bg-bull-bg">
        <BullSprite token={token} fluid className={isDead ? 'opacity-50' : undefined} />
      </div>

      {/* Name */}
      <div
        className={
          'bull-header mb-1 truncate text-sm leading-tight ' +
          (isDead ? 'text-bull-text-faint line-through' : 'text-bull-text')
        }
        title={token.name}
      >
        {token.name}
      </div>

      {/* Weapon */}
      <div className="mb-2 truncate text-sm capitalize text-bull-gold/80" title={token.weapon}>
        {token.weapon}
      </div>

      {/* Stats row: rating + record.
          ⚠ flex-wrap + whitespace-nowrap, not a plain justify-between row.
          Straight off fefers, which learned it the hard way: in the 2-column
          phone grid a card is ~145px wide, so "rating 1000" and "0W / 0L / 0T"
          do not fit side by side — and without these two the values broke
          INSIDE themselves ("0W / 0L /" then "0T"), which reads as a different
          number entirely. Now each value stays whole and the second drops to
          its own line when there is no room. */}
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 text-sm">
        <span className="whitespace-nowrap font-mono">
          <span className="text-bull-text-dim">rating </span>
          <span className="font-bold text-bull-text">{stat(record?.elo)}</span>
        </span>
        <span className="whitespace-nowrap font-mono text-bull-text-dim">
          {record ? `${record.wins}W / ${record.losses}L / ${record.ties}T` : stat(undefined)}
        </span>
      </div>

      {isDead && (
        <div className="mt-2 text-xs uppercase tracking-wider text-bull-red">
          on the truck 💀
        </div>
      )}
    </>
  );
}
