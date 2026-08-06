/**
 * Core type definitions for the bnbulls combat engine.
 *
 * ⚠ PORTED 1:1 from Fighting Fefers (`app/frontend/src/core/types.ts`). Only
 * identifiers moved: `Outlaw` → `Bull`, `OutlawStatus` → `BullStatus`. Every
 * NUMBER here — `STAT_MIN`, `STAT_MAX_AT_CREATION`, `POINT_BUY_TOTAL` — is the
 * fefers value, unchanged, because `BNBULLS-BOOTSTRAP.md §3` puts the combat
 * engine in the "carries over unchanged, do NOT re-litigate" list. If you find
 * yourself picking one of these numbers, you have misread the task.
 */

// ─── Weapons ─────────────────────────────────────────────────────────────

export type WeaponType = 'blade' | 'blunt' | 'ranged';

export type WeaponRarity = 'common' | 'uncommon' | 'rare' | 'epic' | 'legendary' | 'king';

export interface Weapon {
  readonly name: string;
  readonly damageMin: number;
  readonly damageMax: number;
  readonly speed: number;
  readonly type: WeaponType;
  readonly rarity: WeaponRarity;
  readonly weight: number;
}

// ─── Stats ───────────────────────────────────────────────────────────────

export interface Stats {
  readonly strength: number;
  readonly dexterity: number;
  readonly constitution: number;
  readonly intelligence: number;
  readonly wisdom: number;
  readonly charisma: number;
}

export const STAT_MIN = 8;
export const STAT_MAX_AT_CREATION = 18;
export const POINT_BUY_TOTAL = 32;

// ─── Bull ────────────────────────────────────────────────────────────────

export type BullStatus = 'alive' | 'dead';

export interface Bull {
  readonly tokenId: number;
  readonly name: string;
  readonly stats: Stats;
  readonly weapon: Weapon;
  readonly level: number;
  readonly xp: number;
  readonly elo: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly status: BullStatus;
  readonly createdAt: number;
}

// ─── Combat log ──────────────────────────────────────────────────────────

export type CombatEvent =
  | {
      readonly type: 'round_start';
      readonly round: number;
      readonly attackerId: number;
      readonly defenderId: number;
    }
  | {
      readonly type: 'attack_hit';
      readonly attackerId: number;
      readonly defenderId: number;
      readonly damage: number;
      readonly isCritical: boolean;
      readonly typeAdvantage: boolean;
      readonly defenderHpAfter: number;
    }
  | {
      readonly type: 'attack_miss';
      readonly attackerId: number;
      readonly defenderId: number;
    }
  // ── bonded-calf sidekick shots (phase 2) ──────────────────────────────
  // Additive only. A fight with no bonded calf NEVER emits any of these, so a
  // no-bond duel's event list is byte-identical to a pre-phase-2 duel. The
  // calves collection does not exist yet on bnbulls; these variants are ported
  // so the sim's shape does not have to change when it does.
  | {
      /** A bonded calf butts the opponent for flat damage ('chip'). */
      readonly type: 'sidekick_chip';
      /** The bonded parent whose calf fired. */
      readonly parentId: number;
      /** The opponent taking the chip. */
      readonly targetId: number;
      readonly damage: number;
      /** Opponent hp after the chip (clamped at 0). */
      readonly defenderHpAfter: number;
    }
  | {
      /** A calf tops its parent up once when it drops below half ('heal'). */
      readonly type: 'sidekick_heal';
      readonly parentId: number;
      readonly amount: number;
      readonly parentHpAfter: number;
    }
  | {
      /** A calf eats one killing blow, leaving the parent alive ('lastStand'). */
      readonly type: 'sidekick_save';
      readonly parentId: number;
      readonly hpAfter: number;
    }
  | {
      readonly type: 'fight_end';
      readonly winnerId: number | null;
      readonly rounds: number;
    };

export interface FightResult {
  readonly seed: bigint;
  readonly bullAId: number;
  readonly bullBId: number;
  readonly winnerId: number | null;
  readonly rounds: number;
  readonly events: readonly CombatEvent[];
}
