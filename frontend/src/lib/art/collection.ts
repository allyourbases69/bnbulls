/**
 * Thin wrapper around the art engine for the pages that need to look up a
 * token by id. `chainBandMap()` (the contract's rarity shuffle, ported) and
 * `assignNames()` (the name dealer) are both O(supply) and deterministic, so
 * they're computed once per process/module-load and reused — not on every
 * render.
 *
 * ⚠ THE TIER MAP IS THE CHAIN'S, NOT THE ENGINE'S OWN.
 * This used to call `assignBands()`, an LCG shuffle unrelated to the one
 * `Bulls._initializeRarity()` runs — so the site would have shown 377 of the
 * 500 bulls at the wrong tier, with the wrong hide, horns, armour, cape and
 * WEAPON, against on-chain data that can never be changed. `assignBands()` is
 * deleted; `chainBandMap()` is the only band map there is. See
 * `DECISIONS.md §27` and `npm run verify:rarity`.
 *
 * ⚠ Token #501, the king, has no entry in the map (it covers ids 1..500;
 * `rarityOf(501)` is tier 5, "king", which has no hide family of its own).
 * This treats #501 as a `legendary`-band override so his armour, cape and BNB
 * diamond come from the legendary tables — the same assumption
 * `marketing/keeper/bull-png.mjs` makes. Its WEAPON is not a guess:
 * `chainWeapon()` returns the king-only Gilded Pike for #501, matching
 * `mintKing()`.
 *
 * ⚠ THE OVERRIDE IS NO LONGER ALL HE GETS. The previous note here said to
 * "flag it if the king ever needs bespoke traits" — the owner did, so
 * `rollToken` now recognises #501 by ID and gives him a hide, marbling, horn
 * veins and a crown nobody else can roll (`DECISIONS.md §34`/`§35`). Callers
 * do not opt in: passing `{ band: 'legendary' }` is still all that is needed,
 * and a normal bull can never receive the king's look.
 */
import { chainBandMap, assignNames, rollToken, KING_ID, type Band, type Token } from './bull';

let cachedBandMap: Record<number, Band> | null = null;
let cachedNames: Record<number, string> | null = null;

function ensure(): { bandMap: Record<number, Band>; names: Record<number, string> } {
  if (!cachedBandMap) cachedBandMap = chainBandMap();
  if (!cachedNames) cachedNames = assignNames(cachedBandMap);
  return { bandMap: cachedBandMap, names: cachedNames };
}

export const MIN_ID = 1;
export const MAX_ID = KING_ID; // 501, the king

export function isValidBullId(id: number): boolean {
  return Number.isInteger(id) && id >= MIN_ID && id <= MAX_ID;
}

export function getBull(id: number): Token {
  const { bandMap, names } = ensure();
  if (id === KING_ID) {
    return rollToken(id, bandMap, { band: 'legendary', names });
  }
  return rollToken(id, bandMap, { names });
}

export function getBandMap(): Record<number, Band> {
  return ensure().bandMap;
}
