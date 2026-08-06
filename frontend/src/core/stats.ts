/**
 * Stat allocation and modifier math.
 *
 * ⚠ PORTED VERBATIM from Fighting Fefers (`app/frontend/src/core/stats.ts`).
 * The three functions the sim actually calls are the load-bearing ones and
 * every constant in them is unchanged:
 *
 *   abilityModifier(s) = floor((s - 10) / 2)
 *   startingHp(stats, level) = 25 + conMod * 3 + level * 2
 *   armorClass(stats) = 10 + dexMod + floor(conMod / 2)
 *
 * `Bulls.sol` rolls stats on chain (`_rollStats`), so `rollStats` below is not
 * on the duel path any more — it is kept because the point-buy cost curve it
 * encodes is the same curve the contract uses, and having it here means the
 * validator can catch an impossible stat block coming back from an RPC.
 */
import type { Stats } from './types';
import { POINT_BUY_TOTAL, STAT_MIN, STAT_MAX_AT_CREATION } from './types';
import type { RngState } from './rng';
import { nextInt } from './rng';

export function pointBuyCost(target: number): number {
  if (target < STAT_MIN) {
    throw new Error(`Stat target ${target} is below minimum ${STAT_MIN}`);
  }
  if (target > STAT_MAX_AT_CREATION) {
    throw new Error(`Stat target ${target} exceeds creation maximum ${STAT_MAX_AT_CREATION}`);
  }
  let cost = 0;
  for (let i = STAT_MIN + 1; i <= target; i++) {
    if (i <= 14) {
      cost += 1;
    } else if (i <= 16) {
      cost += 2;
    } else {
      cost += 3;
    }
  }
  return cost;
}

export function totalPointCost(stats: Stats): number {
  return (
    pointBuyCost(stats.strength) +
    pointBuyCost(stats.dexterity) +
    pointBuyCost(stats.constitution) +
    pointBuyCost(stats.intelligence) +
    pointBuyCost(stats.wisdom) +
    pointBuyCost(stats.charisma)
  );
}

export function validateStats(stats: Stats): { ok: true } | { ok: false; reason: string } {
  const entries: [keyof Stats, number][] = [
    ['strength', stats.strength],
    ['dexterity', stats.dexterity],
    ['constitution', stats.constitution],
    ['intelligence', stats.intelligence],
    ['wisdom', stats.wisdom],
    ['charisma', stats.charisma],
  ];
  for (const [name, value] of entries) {
    if (!Number.isInteger(value)) {
      return { ok: false, reason: `${name} must be an integer, got ${value}` };
    }
    if (value < STAT_MIN) {
      return { ok: false, reason: `${name} is ${value}, minimum is ${STAT_MIN}` };
    }
    if (value > STAT_MAX_AT_CREATION) {
      return {
        ok: false,
        reason: `${name} is ${value}, maximum at creation is ${STAT_MAX_AT_CREATION}`,
      };
    }
  }
  const total = totalPointCost(stats);
  if (total !== POINT_BUY_TOTAL) {
    return {
      ok: false,
      reason: `point total is ${total}, must equal ${POINT_BUY_TOTAL}`,
    };
  }
  return { ok: true };
}

export function abilityModifier(stat: number): number {
  return Math.floor((stat - 10) / 2);
}

export function rollStats(state: RngState): Stats {
  const working: Record<keyof Stats, number> = {
    strength: STAT_MIN,
    dexterity: STAT_MIN,
    constitution: STAT_MIN,
    intelligence: STAT_MIN,
    wisdom: STAT_MIN,
    charisma: STAT_MIN,
  };
  const keys: (keyof Stats)[] = [
    'strength',
    'dexterity',
    'constitution',
    'intelligence',
    'wisdom',
    'charisma',
  ];
  let remaining = POINT_BUY_TOTAL;

  const maxIterations = POINT_BUY_TOTAL * 20;
  let iter = 0;
  while (remaining > 0 && iter < maxIterations) {
    iter++;
    const key = keys[nextInt(state, 0, keys.length - 1)]!;
    const current = working[key];
    if (current >= STAT_MAX_AT_CREATION) {
      continue;
    }
    const nextValue = current + 1;
    const incrementCost = pointBuyCost(nextValue) - pointBuyCost(current);
    if (incrementCost > remaining) {
      let canAffordAny = false;
      for (const k of keys) {
        const v = working[k];
        if (v >= STAT_MAX_AT_CREATION) {
          continue;
        }
        const cost = pointBuyCost(v + 1) - pointBuyCost(v);
        if (cost <= remaining) {
          canAffordAny = true;
          break;
        }
      }
      if (!canAffordAny) {
        break;
      }
      continue;
    }
    working[key] = nextValue;
    remaining -= incrementCost;
  }

  const stats: Stats = {
    strength: working.strength,
    dexterity: working.dexterity,
    constitution: working.constitution,
    intelligence: working.intelligence,
    wisdom: working.wisdom,
    charisma: working.charisma,
  };

  const check = validateStats(stats);
  if (!check.ok) {
    throw new Error(`rollStats produced invalid stats: ${check.reason}`);
  }
  return stats;
}

export function startingHp(stats: Stats, level: number): number {
  const conMod = abilityModifier(stats.constitution);
  return 25 + conMod * 3 + level * 2;
}

export function armorClass(stats: Stats): number {
  const dexMod = abilityModifier(stats.dexterity);
  const conMod = abilityModifier(stats.constitution);
  return 10 + dexMod + Math.floor(conMod / 2);
}
