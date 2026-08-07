/**
 * Rarity-tier vocabulary: the six labels the ladder actually has, and the
 * classes that colour them.
 *
 * ⚠ THIS FILE OWNS NO COLOURS. `lib/tierColour.ts` is still the one place a
 * band's tailwind class is written down, so the homepage, the bull page, the
 * browse grid, /ranks and /leaders can never drift apart. All this file adds is
 * the **sixth** rung — the king — which `Band` deliberately does not have,
 * because #501 has no hide family of its own (`lib/art/collection.ts`).
 *
 * Ported from fighting fefers' `lib/rarity.ts`, which does exactly this job:
 * `RarityTier` = the five normal tiers plus `king`, with `rarityLabel` /
 * `rarityTextClass` / `rarityBorderClass` helpers over it.
 *
 * ⚠ ONE THING FROM FEFERS IS DELIBERATELY NOT PORTED. Fefers derives a tier
 * from the weapon's DROP WEIGHT (`rarityFromWeight`) because that is the only
 * rarity signal its contract carries. bnbulls does not need that and must not
 * use it: `Bulls._initializeRarity()` fixes the tier at construction and
 * `chainBandMap()` is the ported, hash-pinned mirror of it (`DECISIONS.md §27`,
 * `npm run verify:rarity`). Reading the tier back out of the weapon would be a
 * second source of truth for the exact fact that bug was about.
 */
import { KING_ID, type Band } from '@/lib/art/bull';
import { getBandMap } from '@/lib/art/collection';
import { TIER_COLOUR } from '@/lib/tierColour';

/** The five bands plus the 1/1. `rarityOf()` on chain returns 0..5 in this
 *  order, so the index of a tier here IS the contract's tier number. */
export type RankTier = Band | 'king';

/** Ladder order, rarest LAST — matches `Bulls.rarityOf`'s 0..5. */
export const RANK_TIERS: readonly RankTier[] = [
  'common',
  'uncommon',
  'rare',
  'epic',
  'legendary',
  'king',
];

/**
 * The tier the CHAIN gives this token. #501 is its own tier (`rarityOf` returns
 * 5), even though the art engine dresses him off the legendary tables.
 */
export function tierOf(tokenId: number): RankTier {
  if (tokenId === KING_ID) return 'king';
  const band = getBandMap()[tokenId];
  if (!band) throw new Error(`tierOf: no tier for token ${tokenId}`);
  return band;
}

/**
 * Player-facing label, lowercase (`VOICE-AND-BRAND.md §1`). Uppercase it with
 * CSS if a table wants shouting; do not uppercase it here.
 *
 * ⚠ "king 1/1" is the RARITY TIER, not the bull's name. He is called Lord
 * Wagyu (`KING_NAME`). Same distinction fefers draws between its "THE ORIGINAL"
 * badge and "King Fefer" — do not collapse the two. This string matches
 * `BullCard`'s existing badge exactly so a bull cannot be labelled two ways on
 * two pages.
 */
export function tierLabel(tier: RankTier): string {
  return tier === 'king' ? 'king 1/1' : tier;
}

/** Tailwind text colour. Bands defer to `TIER_COLOUR`; the king takes brand
 *  gold, the colour reserved for the 1/1 (`globals.css`). */
export function tierTextClass(tier: RankTier): string {
  return tier === 'king' ? 'text-bull-gold' : TIER_COLOUR[tier];
}

/** Border variant, for badges and row rails. */
export function tierBorderClass(tier: RankTier): string {
  switch (tier) {
    case 'common':
      return 'border-rarity-common';
    case 'uncommon':
      return 'border-rarity-uncommon';
    case 'rare':
      return 'border-rarity-rare';
    case 'epic':
      return 'border-rarity-epic';
    case 'legendary':
      return 'border-rarity-legendary';
    case 'king':
      return 'border-bull-gold';
  }
}
