/**
 * Combat simulator.
 *
 * Given two bulls and a seed, produce a deterministic FightResult.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ PORTED 1:1 FROM FIGHTING FEFERS — `app/frontend/src/sim/combat.ts`
 * ═══════════════════════════════════════════════════════════════════════
 * `BNBULLS-BOOTSTRAP.md §3` lists the combat engine — stats, weights, type
 * triangle, ELO — under "what carries over unchanged (do NOT re-litigate
 * these)". So the ONLY changes in this file are identifiers: `Outlaw` → `Bull`,
 * `fefer` → `bull`, `bub`/baby → calf in the prose. Every arithmetic line, every
 * comparison, every RNG draw and the ORDER of the draws are the fefers ones.
 *
 * The order matters more than it looks. `/api/run-duel` signs a result whose
 * only public input is the seed, and `/api/duel-gif` re-runs THIS function from
 * that seed and 409s if it disagrees. Reordering two `nextInt` calls — even
 * without changing a single number — desynchronises the stream and makes every
 * past fight unreplayable. Do not tidy the control flow.
 *
 * ── bonded-calf sidekicks (phase 2, additive) ──────────────────────────
 * A bull with a bonded calf fights with a small edge. `simulateFight` takes an
 * OPTIONAL `CombatSidekick` per side; when both are null/undefined the sim runs
 * EXACTLY as it does with no phase 2 at all — same RNG draws, same events, same
 * winner. The effects only ever change arithmetic (hp / ac / initiative / crit
 * window / damage), never the NUMBER of RNG draws, and no calf can beat the
 * on-chain death rule: heal and lastStand fire once, and the winner is still
 * decided by hp. `Duel.sol` signs winnerId + rounds and nothing about the
 * blow-by-blow, so a calf shifts the SIM outcome, not the signed struct's shape.
 *
 * Nothing on bnbulls bonds a calf yet (phase 2 is unbuilt). The parameters are
 * ported anyway so that when it lands, `/api/duel-gif` already has a place to
 * reproduce the bond at `blockNumber - 1` — which it MUST, or every bonded
 * fight 409s and gets no replay (`BNBULLS-BOOTSTRAP.md §5`).
 */
import type { Bull, CombatEvent, FightResult } from '../core/types';
import { createRng, nextInt } from '../core/rng';
import { hasTypeAdvantage, TYPE_ADVANTAGE_MULTIPLIER } from '../core/weapons';
import { abilityModifier, armorClass, startingHp } from '../core/stats';

export const MAX_ROUNDS = 50;
export const CRIT_THRESHOLD = 20;

/**
 * A bonded calf's resolved effect, as the sim consumes it. Kept as a local
 * shape (not an import) so this module stays self-contained. `effect` is one of
 * the sidekick effect strings.
 */
export interface CombatSidekick {
  readonly effect: string;
  readonly magnitude: number;
}

/** magnitude of `sk` if it is the given effect, else 0. */
function magIf(sk: CombatSidekick | null | undefined, effect: string): number {
  return sk && sk.effect === effect ? sk.magnitude : 0;
}

export function simulateFight(
  a: Bull,
  b: Bull,
  seed: bigint,
  sideA: CombatSidekick | null = null,
  sideB: CombatSidekick | null = null,
): FightResult {
  if (a.tokenId === b.tokenId) {
    throw new Error('Cannot fight a bull against itself');
  }
  if (a.status !== 'alive') {
    throw new Error(`Bull ${a.tokenId} is not alive (status: ${a.status})`);
  }
  if (b.status !== 'alive') {
    throw new Error(`Bull ${b.tokenId} is not alive (status: ${b.status})`);
  }

  const rng = createRng(seed);
  const events: CombatEvent[] = [];

  // 'bulk': + starting HP. When no calf, magIf returns 0 and this is the
  // unchanged starting-hp line.
  let hpA = startingHp(a.stats, a.level) + magIf(sideA, 'bulk');
  let hpB = startingHp(b.stats, b.level) + magIf(sideB, 'bulk');
  const maxHpA = hpA;
  const maxHpB = hpB;

  // once-per-fight charges, per side.
  const saved = { a: false, b: false };
  const healed = { a: false, b: false };

  const skOf = (side: 'a' | 'b'): CombatSidekick | null => (side === 'a' ? sideA : sideB);
  const idOf = (side: 'a' | 'b'): number => (side === 'a' ? a.tokenId : b.tokenId);
  const hpOf = (side: 'a' | 'b'): number => (side === 'a' ? hpA : hpB);
  const setHp = (side: 'a' | 'b', v: number): void => {
    if (side === 'a') hpA = v;
    else hpB = v;
  };
  const maxHpOf = (side: 'a' | 'b'): number => (side === 'a' ? maxHpA : maxHpB);

  // 'heal': first time the parent is left alive but below half, top it up once.
  const maybeHeal = (side: 'a' | 'b'): void => {
    const sk = skOf(side);
    if (!sk || sk.effect !== 'heal' || healed[side]) return;
    const hp = hpOf(side);
    if (hp > 0 && hp < maxHpOf(side) / 2) {
      healed[side] = true;
      const next = Math.min(maxHpOf(side), hp + sk.magnitude);
      setHp(side, next);
      events.push({
        type: 'sidekick_heal',
        parentId: idOf(side),
        amount: next - hp,
        parentHpAfter: next,
      });
    }
  };

  // 'lastStand': the calf throws itself in front of ONE killing blow, leaving
  // the parent alive on 1 HP. It can only catch a blow whose OVERKILL is within
  // its magnitude, so a small (common) calf saves only near-misses while a big
  // (epic) one catches deep hits too — the effect scales by tier through HOW
  // OFTEN it can save, not through extra life. Once per fight, and a blow that
  // overkills past the magnitude still gets through, so it is never unkillable.
  const maybeSave = (side: 'a' | 'b'): boolean => {
    const sk = skOf(side);
    const hp = hpOf(side);
    if (hp > 0 || !sk || sk.effect !== 'lastStand' || saved[side]) return false;
    if (-hp > sk.magnitude) return false; // overkill too deep for this calf
    saved[side] = true;
    setHp(side, 1);
    events.push({ type: 'sidekick_save', parentId: idOf(side), hpAfter: 1 });
    return true;
  };

  // Apply a landed attack to `defSide`, honouring soak + lastStand, then heal.
  // With no defender calf this is exactly `hp -= damage` + the attack_hit push.
  const landHit = (
    defSide: 'a' | 'b',
    res: AttackResult,
    attackerId: number,
    defenderId: number,
  ): void => {
    const sk = skOf(defSide);
    let dmg = res.damage;
    if (sk && sk.effect === 'soak') dmg = Math.max(1, dmg - sk.magnitude);
    const hp = hpOf(defSide) - dmg;
    setHp(defSide, hp);
    events.push({
      type: 'attack_hit',
      attackerId,
      defenderId,
      damage: dmg,
      isCritical: res.critical,
      typeAdvantage: res.typeAdvantage,
      defenderHpAfter: Math.max(0, hp),
    });
    maybeSave(defSide);
    maybeHeal(defSide);
  };

  const firstIsA = rollInitiative(a, b);

  let round = 0;

  while (round < MAX_ROUNDS && hpA > 0 && hpB > 0) {
    round++;
    const attackerFirst = firstIsA ? a : b;
    const defenderFirst = firstIsA ? b : a;
    const attackerSecond = firstIsA ? b : a;
    const defenderSecond = firstIsA ? a : b;

    events.push({
      type: 'round_start',
      round,
      attackerId: attackerFirst.tokenId,
      defenderId: defenderFirst.tokenId,
    });

    // 'chip': each bonded calf butts the opponent once per round, before the
    // swings. Skipped entirely when neither side has a chip calf, so the event
    // stream is unchanged for a normal fight.
    for (const atkSide of ['a', 'b'] as const) {
      const sk = skOf(atkSide);
      if (!sk || sk.effect !== 'chip') continue;
      const tgtSide: 'a' | 'b' = atkSide === 'a' ? 'b' : 'a';
      const hp = hpOf(tgtSide) - sk.magnitude;
      setHp(tgtSide, hp);
      events.push({
        type: 'sidekick_chip',
        parentId: idOf(atkSide),
        targetId: idOf(tgtSide),
        damage: sk.magnitude,
        defenderHpAfter: Math.max(0, hp),
      });
      maybeSave(tgtSide);
      maybeHeal(tgtSide);
    }
    if (hpA <= 0 || hpB <= 0) break;

    const firstResult = resolveAttack(attackerFirst, defenderFirst, rng, skOf(firstIsA ? 'a' : 'b'), skOf(firstIsA ? 'b' : 'a'));
    if (firstResult.hit) {
      landHit(firstIsA ? 'b' : 'a', firstResult, attackerFirst.tokenId, defenderFirst.tokenId);
    } else {
      events.push({
        type: 'attack_miss',
        attackerId: attackerFirst.tokenId,
        defenderId: defenderFirst.tokenId,
      });
    }

    if (hpA <= 0 || hpB <= 0) {
      break;
    }

    const secondResult = resolveAttack(attackerSecond, defenderSecond, rng, skOf(firstIsA ? 'b' : 'a'), skOf(firstIsA ? 'a' : 'b'));
    if (secondResult.hit) {
      landHit(firstIsA ? 'a' : 'b', secondResult, attackerSecond.tokenId, defenderSecond.tokenId);
    } else {
      events.push({
        type: 'attack_miss',
        attackerId: attackerSecond.tokenId,
        defenderId: defenderSecond.tokenId,
      });
    }
  }

  const winnerId = resolveWinner(a, b, hpA, hpB);

  events.push({
    type: 'fight_end',
    winnerId,
    rounds: round,
  });

  return {
    seed,
    bullAId: a.tokenId,
    bullBId: b.tokenId,
    winnerId,
    rounds: round,
    events,
  };

  function rollInitiative(x: Bull, y: Bull): boolean {
    // 'firstStrike': + initiative for the bonded side (0 when unbonded).
    const xInit = x.weapon.speed + abilityModifier(x.stats.dexterity) + magIf(skOf(x === a ? 'a' : 'b'), 'firstStrike');
    const yInit = y.weapon.speed + abilityModifier(y.stats.dexterity) + magIf(skOf(y === a ? 'a' : 'b'), 'firstStrike');
    if (xInit !== yInit) {
      return xInit > yInit;
    }
    if (x.elo !== y.elo) {
      return x.elo > y.elo;
    }
    return x.tokenId < y.tokenId;
  }
}

interface AttackResult {
  readonly hit: boolean;
  readonly damage: number;
  readonly critical: boolean;
  readonly typeAdvantage: boolean;
}

function resolveAttack(
  attacker: Bull,
  defender: Bull,
  rng: { s0: bigint; s1: bigint },
  attackerSk: CombatSidekick | null = null,
  defenderSk: CombatSidekick | null = null,
): AttackResult {
  const rawRoll = nextInt(rng, 1, 20);
  const attackMod = abilityModifier(attacker.stats.dexterity);
  const total = rawRoll + attackMod;
  // 'ward': + defender armour class (0 when the defender has no calf).
  const defenderAc = armorClass(defender.stats) + magIf(defenderSk, 'ward');

  if (rawRoll === 1) {
    return { hit: false, damage: 0, critical: false, typeAdvantage: false };
  }

  // 'critFloor': widen the crit window. With magnitude 0 this is exactly
  // `rawRoll === CRIT_THRESHOLD` (20 is the max roll), i.e. the unchanged rule.
  const isCrit = rawRoll >= CRIT_THRESHOLD - magIf(attackerSk, 'critFloor');
  const hit = isCrit || total >= defenderAc;

  if (!hit) {
    return { hit: false, damage: 0, critical: false, typeAdvantage: false };
  }

  const baseDamage = nextInt(rng, attacker.weapon.damageMin, attacker.weapon.damageMax);
  const strMod = abilityModifier(attacker.stats.strength);
  let damage = baseDamage + strMod;
  if (damage < 1) {
    damage = 1;
  }

  // 'flatDamage': + flat damage before the crit multiply (0 when unbonded).
  damage += magIf(attackerSk, 'flatDamage');

  if (isCrit) {
    damage *= 2;
  }

  // 'typeEdge': force the type-edge multiply on at (1 + magnitude/100). Without
  // it, the normal rock-paper-scissors +15% applies exactly as before.
  const typeEdgeMag = magIf(attackerSk, 'typeEdge');
  let typeAdvantage: boolean;
  if (typeEdgeMag > 0) {
    typeAdvantage = true;
    damage = Math.round(damage * (1 + typeEdgeMag / 100));
  } else {
    typeAdvantage = hasTypeAdvantage(attacker.weapon, defender.weapon);
    if (typeAdvantage) {
      damage = Math.round(damage * TYPE_ADVANTAGE_MULTIPLIER);
    }
  }

  return { hit: true, damage, critical: isCrit, typeAdvantage };
}

function resolveWinner(
  a: Bull,
  b: Bull,
  hpA: number,
  hpB: number,
): number | null {
  if (hpA <= 0 && hpB <= 0) {
    return null;
  }
  if (hpA <= 0) {
    return b.tokenId;
  }
  if (hpB <= 0) {
    return a.tokenId;
  }
  if (hpA > hpB) {
    return a.tokenId;
  }
  if (hpB > hpA) {
    return b.tokenId;
  }
  return null;
}
