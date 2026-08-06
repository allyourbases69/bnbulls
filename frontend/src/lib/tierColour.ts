import type { Band } from './art/bull';

/** Shared tier -> tailwind text colour, so every page renders the ladder in
 *  the same colours as the homepage and the bull detail page. */
export const TIER_COLOUR: Record<Band, string> = {
  common: 'text-rarity-common',
  uncommon: 'text-rarity-uncommon',
  rare: 'text-rarity-rare',
  epic: 'text-rarity-epic',
  legendary: 'text-rarity-legendary',
};
