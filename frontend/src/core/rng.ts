/**
 * Seeded deterministic random number generator (xorshift128+ with SplitMix64
 * init).
 *
 * ⚠ PORTED VERBATIM from Fighting Fefers (`app/frontend/src/core/rng.ts`). Not
 * one constant, shift or branch has been touched. This is the spine of the
 * whole guarantee: the signer runs a fight, the chain records only the seed,
 * and `/api/duel-gif` re-runs the same seed and refuses to render if it gets a
 * different answer. Any change here — even one that "looks equivalent" — makes
 * every historical replay 409 and every outstanding signature unverifiable.
 *
 * The seeding is the subtle part. Two SplitMix64 rounds fill `s0`/`s1`, and the
 * all-zero state (which xorshift128+ cannot escape) is replaced with `{1, 2}`.
 * Do not "simplify" that special case away.
 */

export interface RngState {
  s0: bigint;
  s1: bigint;
}

const MASK_64 = (1n << 64n) - 1n;

export function createRng(seed: bigint): RngState {
  if (seed < 0n) {
    throw new Error('Seed must be non-negative');
  }
  let z = (seed + 0x9e3779b97f4a7c15n) & MASK_64;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK_64;
  z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK_64;
  const s0 = z ^ (z >> 31n);
  z = (s0 + 0x9e3779b97f4a7c15n) & MASK_64;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK_64;
  z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK_64;
  const s1 = z ^ (z >> 31n);
  if (s0 === 0n && s1 === 0n) {
    return { s0: 1n, s1: 2n };
  }
  return { s0: s0 & MASK_64, s1: s1 & MASK_64 };
}

export function nextUint64(state: RngState): bigint {
  let s1 = state.s0;
  const s0 = state.s1;
  const result = (s0 + s1) & MASK_64;
  state.s0 = s0;
  s1 = s1 ^ ((s1 << 23n) & MASK_64);
  state.s1 = (s1 ^ s0 ^ (s1 >> 17n) ^ (s0 >> 26n)) & MASK_64;
  return result;
}

/**
 * Uniform integer in `[min, max]`, rejection-sampled so the modulo bias is
 * gone. The rejection loop is why a fight consumes an UNPREDICTABLE number of
 * 64-bit words per roll — which is fine, because both the signer and the
 * replayer walk the same stream in the same order.
 */
export function nextInt(state: RngState, min: number, max: number): number {
  if (min > max) {
    throw new Error(`nextInt: min (${min}) must be <= max (${max})`);
  }
  if (min === max) {
    return min;
  }
  const range = BigInt(max - min + 1);
  const maxValid = ((1n << 64n) / range) * range;
  let roll: bigint;
  do {
    roll = nextUint64(state);
  } while (roll >= maxValid);
  return min + Number(roll % range);
}

export function nextFloat(state: RngState): number {
  const value = nextUint64(state) >> 11n;
  return Number(value) / Number(1n << 53n);
}

export function weightedPick<T>(
  state: RngState,
  items: readonly T[],
  weights: readonly number[],
): number {
  if (items.length === 0) {
    throw new Error('weightedPick: items empty');
  }
  if (items.length !== weights.length) {
    throw new Error(
      `weightedPick: items length (${items.length}) must equal weights length (${weights.length})`,
    );
  }
  let total = 0;
  for (const w of weights) {
    if (w < 0) {
      throw new Error('weightedPick: all weights must be non-negative');
    }
    total += w;
  }
  if (total <= 0) {
    throw new Error('weightedPick: weights sum must be positive');
  }
  const roll = nextInt(state, 0, total - 1);
  let cumulative = 0;
  for (let i = 0; i < weights.length; i++) {
    cumulative += weights[i]!;
    if (roll < cumulative) {
      return i;
    }
  }
  throw new Error('weightedPick: unreachable');
}

export function dice(state: RngState, count: number, sides: number, bonus: number = 0): number {
  if (count <= 0 || sides <= 0) {
    throw new Error(`dice: invalid count/sides (${count}d${sides})`);
  }
  let total = bonus;
  for (let i = 0; i < count; i++) {
    total += nextInt(state, 1, sides);
  }
  return total;
}
