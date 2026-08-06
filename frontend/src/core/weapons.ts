/**
 * The twelve weapons, mirroring `Bulls.sol::_initializeWeapons()` slot for
 * slot.
 *
 * ⚠ NOT ONE COMBAT NUMBER IS NEW. Every `damageMin`, `damageMax`, `speed`,
 * `type` and `weight` below is the Fighting Fefers value in the Fighting Fefers
 * slot order (`app/frontend/src/core/weapons.ts`); only the NAME moved, exactly
 * as `BNBULLS-BOOTSTRAP.md §3` prescribes ("weapon renames are sprite/name-level
 * only ... do NOT touch stats/weights"). The mapping, for anyone auditing:
 *
 *   slot  fefers          bnbulls        dmg     spd  type    weight
 *   ────  ──────────────  ─────────────  ──────  ───  ──────  ──────
 *    0    Dagger          Shiv            6-11    9   blade     18
 *    1    Trident         Pitchfork       8-13    6   blunt     17
 *    2    Mace            Maul            8-13    5   blunt     15
 *    3    Gladius         Cleaver        10-15    6   blade     12
 *    4    Short Bow       Hornbow        11-16    7   ranged    11
 *    5    Crossbow        Bolter         14-22    4   ranged     9
 *    6    Flail           Morningstar    14-24    3   blunt      7
 *    7    Flaming Sword   Reaper         15-22    6   blade      5
 *    8    War Axe         Sledge         16-24    5   blade      3
 *    9    Warbow          Ring           22-35    2   ranged     2
 *   10    Arbalest        Pike           25-40    6   ranged     1
 *   11    —               Gilded Pike    50-100  10   ranged     0   (king only)
 *
 * Slot 11 has no fefers counterpart: the fefers frontend catalog stopped at
 * eleven and the king never fought there. Its numbers are NOT invented here —
 * they are read straight off `Bulls.sol` (`_addWeapon("Gilded Pike", 50, 100,
 * 10, 2, 0)`), and weight 0 keeps it out of every weighted pool, exactly as
 * `generator/bull.mjs`'s `WEAPON_WEIGHT` does.
 *
 * The two invariants below are the same ones `Bulls.sol` enforces in its
 * constructor: slots 0..10 sum to 100, and names are unique. They throw at
 * import so a bad edit fails the build rather than quietly re-weighting the
 * drop.
 */
import type { Weapon } from './types';

/** Solidity's `weaponType` uint8 → the strings the sim's type triangle uses. */
export const WEAPON_TYPE_MAP: readonly ('blade' | 'blunt' | 'ranged')[] = [
  'blade',
  'blunt',
  'ranged',
];

/** The king-only slot. Index 11 in `Bulls.sol`, weight 0, never rolled. */
export const KING_WEAPON_INDEX = 11;
/** Slots that make up the ordinary weighted drop. Must sum to 100. */
const DROP_SLOTS = 11;

export const WEAPONS: readonly Weapon[] = [
  { name: 'Shiv',        damageMin: 6,  damageMax: 11,  speed: 9,  type: 'blade',  rarity: 'common',    weight: 18 },
  { name: 'Pitchfork',   damageMin: 8,  damageMax: 13,  speed: 6,  type: 'blunt',  rarity: 'common',    weight: 17 },
  { name: 'Maul',        damageMin: 8,  damageMax: 13,  speed: 5,  type: 'blunt',  rarity: 'common',    weight: 15 },
  { name: 'Cleaver',     damageMin: 10, damageMax: 15,  speed: 6,  type: 'blade',  rarity: 'uncommon',  weight: 12 },
  { name: 'Hornbow',     damageMin: 11, damageMax: 16,  speed: 7,  type: 'ranged', rarity: 'uncommon',  weight: 11 },
  { name: 'Bolter',      damageMin: 14, damageMax: 22,  speed: 4,  type: 'ranged', rarity: 'rare',      weight: 9  },
  { name: 'Morningstar', damageMin: 14, damageMax: 24,  speed: 3,  type: 'blunt',  rarity: 'rare',      weight: 7  },
  { name: 'Reaper',      damageMin: 15, damageMax: 22,  speed: 6,  type: 'blade',  rarity: 'epic',      weight: 5  },
  { name: 'Sledge',      damageMin: 16, damageMax: 24,  speed: 5,  type: 'blade',  rarity: 'epic',      weight: 3  },
  { name: 'Ring',        damageMin: 22, damageMax: 35,  speed: 2,  type: 'ranged', rarity: 'legendary', weight: 2  },
  { name: 'Pike',        damageMin: 25, damageMax: 40,  speed: 6,  type: 'ranged', rarity: 'legendary', weight: 1  },
  { name: 'Gilded Pike', damageMin: 50, damageMax: 100, speed: 10, type: 'ranged', rarity: 'king',      weight: 0  },
];

const dropWeight = WEAPONS.slice(0, DROP_SLOTS).reduce((sum, w) => sum + w.weight, 0);
if (dropWeight !== 100) {
  throw new Error(
    `Weapon weights for slots 0..${DROP_SLOTS - 1} must sum to 100, got ${dropWeight}. ` +
      'Fix frontend/src/core/weapons.ts — and check it still matches Bulls.sol.',
  );
}

const names = new Set(WEAPONS.map((w) => w.name));
if (names.size !== WEAPONS.length) {
  throw new Error('Weapon names must be unique');
}

export function getWeapon(name: string): Weapon {
  const w = WEAPONS.find((x) => x.name === name);
  if (!w) {
    throw new Error(`Unknown weapon: ${name}`);
  }
  return w;
}

export function findWeapon(name: string): Weapon | undefined {
  return WEAPONS.find((w) => w.name === name);
}

/**
 * The type triangle: blade beats blunt beats ranged beats blade.
 *
 * ⚠ Unchanged from fefers, including the multiplier. `BNBULLS-BOOTSTRAP.md §3`
 * lists the type triangle among the things that carry over and must not be
 * re-litigated.
 */
export function hasTypeAdvantage(attacker: Weapon, defender: Weapon): boolean {
  if (attacker.type === 'blade' && defender.type === 'blunt') {
    return true;
  }
  if (attacker.type === 'blunt' && defender.type === 'ranged') {
    return true;
  }
  if (attacker.type === 'ranged' && defender.type === 'blade') {
    return true;
  }
  return false;
}

export const TYPE_ADVANTAGE_MULTIPLIER = 1.15;
