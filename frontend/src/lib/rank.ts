/**
 * RARITY RANK — a straight port of fighting fefers' `lib/rankCalc.ts`.
 *
 * Fefers' own docblock, unchanged in substance and reproduced here because it
 * IS the specification:
 *
 *   Score is the empirical "trait rarity" sum: for each trait a bull has,
 *   (totalMinted / countOfBullsWithSameTraitValue) × weight. Rarer traits
 *   contribute more to the score. Ranks are assigned by sorting all minted
 *   bulls' scores DESCENDING — rank 1 = rarest.
 *
 *   v1: ranks recompute against currently minted bulls. They shift slightly as
 *   more mint. The UI disclaims it.
 *
 *   v2 (post-drop): the set stops changing at 501, so the table freezes on its
 *   own. Nothing has to be done to make that happen.
 *
 * Weights are fefers' weights, unchanged: 100 / 20 / 1.
 *
 * ⚠ NOTHING HERE IS INVENTED. Every input traces to on-chain state or to a
 * deterministic function already ported from the contract:
 *
 *   tier    `chainBandMap()`   ← `Bulls._initializeRarity()`   (§27, hash-pinned)
 *   weapon  `chainWeapon()`    ← `Bulls._rollWeaponInTier()`   (§27, hash-pinned)
 *   stats   `chainStats()`     ← `Bulls._rollBull` + `_rollStats`  (below)
 *
 * so a rank costs ZERO rpc beyond the minted COUNT. That is the one thing the
 * chain has to tell us, because rank is "of the minted set" and the art tables
 * describe all 501 whether they exist yet or not.
 *
 * ⚠ RANK IS NOT RATING. Rank is how rare the bull IS. Rating is elo, it is real
 * chain state on `Bulls.getBull().elo`, and it lives on /leaders. Two different
 * numbers, never to be mixed.
 */
import { createRng } from '@/core/rng';
import { rollStats } from '@/core/stats';
import type { Stats } from '@/core/types';
import {
  KING_ID,
  KING_WEAPON,
  MASTER_SEED,
  chainWeapon,
  type Band,
} from '@/lib/art/bull';
import { getBandMap } from '@/lib/art/collection';
import type { RankTier } from '@/lib/rarity';

// ─── the stat block, off chain ───────────────────────────────────────────

/**
 * `Bulls._rollBull`, line 710: `uint256 statsSeed = masterSeed ^ (tokenId *
 * 0xbf58476d1ce4e5b9)`. Sibling of `WEAPON_SEED_MULT` in `lib/art/bull.ts` —
 * the two sub-seeds are decorrelated on purpose so changing one cannot shift
 * the other.
 */
export const STATS_SEED_MULT = 0xbf58476d1ce4e5b9n;

/**
 * The king's stat block. `Bulls.mintKing()` ASSIGNS 18s straight into storage
 * (lines 502-507); it never calls `_rollStats`.
 *
 * ⚠ This block is deliberately NOT point-buy legal — six 18s cost 96 against a
 * `POINT_BUY_TOTAL` of 32 — which is why it is a constant here and not a roll.
 * Do not run `validateStats` over it; it will (correctly) fail.
 */
export const KING_STATS: Stats = {
  strength: 18,
  dexterity: 18,
  constitution: 18,
  intelligence: 18,
  wisdom: 18,
  charisma: 18,
};

/** Memo, keyed by `seed:id`, so 501 stat rolls happen once per page load and
 *  not once per card. */
const STAT_CACHE = new Map<string, Stats>();

/**
 * `Bulls._rollStats(masterSeed ^ tokenId * 0xbf58476d1ce4e5b9)`, off chain.
 *
 * ⚠ THIS ADDS NO NEW ALGORITHM. It is two already-proven ports composed:
 *
 *   `core/rng.ts::createRng`  ==  `Xorshift.create`   (its own header says
 *      "byte-identical port"; the solidity truncates the uint256 seed to
 *      uint64 before the first splitmix add, the JS masks after it — equal
 *      mod 2^64)
 *   `core/stats.ts::rollStats` == `Bulls._rollStats`  (same loop, same
 *      `maxIterations`, same point-buy cost curve, same `canAffordAny`
 *      break, and its stat key order matches `_getStatByIndex`'s 0..5
 *      exactly: strength, dexterity, constitution, intelligence, wisdom,
 *      charisma)
 *
 * The only NEW line is the seed derivation, and it mirrors `chainWeaponId`'s
 * (`masterSeed ^ (tokenId * MULT)`) which is already covered by
 * `npm run verify:rarity`. `tokenId * 0xbf58476d1ce4e5b9` cannot overflow
 * uint256 for tokenId ≤ 501, so no modular reduction is needed here either.
 *
 * ⚠ If a bull's stats ever have to be TRUSTED rather than displayed — signing,
 * settling, replaying — read them off chain with `readBullAt()`. This is a
 * display derivation. `bullOnchain.ts` says the fighter's stats come from chain
 * state and never from the client, and that rule is not weakened by this file.
 */
export function chainStats(tokenId: number, masterSeed: bigint | number = MASTER_SEED): Stats {
  if (tokenId === KING_ID) return KING_STATS;
  const key = `${masterSeed}:${tokenId}`;
  const hit = STAT_CACHE.get(key);
  if (hit) return hit;
  const seed = BigInt(masterSeed) ^ (BigInt(tokenId) * STATS_SEED_MULT);
  const rolled = rollStats(createRng(seed));
  STAT_CACHE.set(key, rolled);
  return rolled;
}

// ─── the scorer ──────────────────────────────────────────────────────────

export interface BullForRank {
  readonly tokenId: number;
  readonly tier: RankTier;
  readonly weapon: string;
  readonly stats: Stats;
}

export interface RankedBull {
  readonly tokenId: number;
  /** 1 = rarest. */
  readonly rank: number;
  /** How many bulls this rank was computed against. The `147` in `61 / 147`. */
  readonly rankOf: number;
  readonly score: number;
  readonly tier: RankTier;
  readonly weapon: string;
}

/**
 * ⚠ FEFERS' THREE WEIGHTS, UNCHANGED. Private, exactly as they are over there —
 * they are the algorithm, not configuration, and a caller that could retune
 * them could quietly publish a different ladder than /ranks shows.
 */
const RARITY_WEIGHT = 100;
const WEAPON_WEIGHT = 20;
const STAT_WEIGHT = 1;

const STAT_KEYS: readonly (keyof Stats)[] = [
  'strength',
  'dexterity',
  'constitution',
  'intelligence',
  'wisdom',
  'charisma',
];

/**
 * Compute ranks for the given set of bulls.
 *
 * @param bulls (tier / weapon / stats) per MINTED bull. Pass only minted ones —
 *              the whole point is that rarity is measured against what exists.
 * @returns rank assignments sorted by rank ascending (rank 1 first).
 */
export function computeRanks(bulls: readonly BullForRank[]): RankedBull[] {
  const total = bulls.length;
  if (total === 0) return [];

  // Tally trait frequencies.
  const tierCount = new Map<string, number>();
  const weaponCount = new Map<string, number>();
  // Per-stat-name buckets of value → count.
  const statBuckets = new Map<keyof Stats, Map<number, number>>();
  for (const k of STAT_KEYS) statBuckets.set(k, new Map());

  for (const b of bulls) {
    tierCount.set(b.tier, (tierCount.get(b.tier) ?? 0) + 1);
    weaponCount.set(b.weapon, (weaponCount.get(b.weapon) ?? 0) + 1);
    for (const k of STAT_KEYS) {
      const value = b.stats[k];
      const bucket = statBuckets.get(k)!;
      bucket.set(value, (bucket.get(value) ?? 0) + 1);
    }
  }

  // Score each bull.
  const scored = bulls.map((b) => {
    let score = 0;
    // Tier (dominant). Fefers calls this the rarity term.
    const rCount = tierCount.get(b.tier) ?? 1;
    score += (total / rCount) * RARITY_WEIGHT;
    // Weapon (moderate).
    const wCount = weaponCount.get(b.weapon) ?? 1;
    score += (total / wCount) * WEAPON_WEIGHT;
    // Each stat (subtle). This is what separates two bulls that share a tier
    // and a weapon; without it every such pair would tie and fall back to
    // token id, and /ranks would render long runs of identical scores.
    for (const k of STAT_KEYS) {
      const value = b.stats[k];
      const vCount = statBuckets.get(k)!.get(value) ?? 1;
      score += (total / vCount) * STAT_WEIGHT;
    }
    return { tokenId: b.tokenId, score, tier: b.tier, weapon: b.weapon };
  });

  // Sort descending. Tiebreaker: lower tokenId wins (older mint).
  scored.sort((a, b) => {
    if (a.score !== b.score) return b.score - a.score;
    return a.tokenId - b.tokenId;
  });

  return scored.map((s, i) => ({
    tokenId: s.tokenId,
    rank: i + 1,
    rankOf: total,
    score: Math.round(s.score * 100) / 100,
    tier: s.tier,
    weapon: s.weapon,
  }));
}

// ─── assembling the inputs ───────────────────────────────────────────────

/**
 * Tier + weapon + stats for one token, all three from the ported chain
 * functions. Cheaper than `getBull()` on purpose: it skips the cosmetic roll
 * (hide, eyes, horns, gear) which the score does not read.
 *
 * ⚠ THE COSMETICS ARE NOT SCORED, AND THAT IS FEFERS' RULE, NOT A SHORTCUT.
 * Fefers scores tier, weapon and the six stats — nothing else. bnbulls has
 * traits fefers never had (hide, horn colour, gear, cape, metal), and every one
 * of them is DERIVED FROM THE TIER off the same `tokenSeed` stream, so scoring
 * them would be counting the tier again under five other names and would
 * silently reweight the ladder away from 100/20/1. If the owner ever wants gear
 * in the score it is a deliberate change to the weights, made here, and it
 * should be argued for out loud.
 */
export function bullForRank(tokenId: number): BullForRank {
  if (tokenId === KING_ID) {
    return { tokenId, tier: 'king', weapon: KING_WEAPON, stats: KING_STATS };
  }
  const band: Band | undefined = getBandMap()[tokenId];
  if (!band) throw new Error(`bullForRank: token ${tokenId} is outside the drop`);
  return {
    tokenId,
    tier: band,
    weapon: chainWeapon(tokenId, band),
    stats: chainStats(tokenId),
  };
}

/** `computeRanks` over a list of minted ids. The whole rank table in one call,
 *  with no chain read of its own. */
export function ranksForIds(ids: readonly number[]): RankedBull[] {
  return computeRanks(ids.map(bullForRank));
}

/** `tokenId → RankedBull`, for the card lookups. */
export function rankIndex(ranks: readonly RankedBull[]): Map<number, RankedBull> {
  const map = new Map<number, RankedBull>();
  for (const r of ranks) map.set(r.tokenId, r);
  return map;
}

/** The score as fefers prints it on a card: `374 pts`. */
export function formatPoints(score: number): string {
  return `${Math.round(score)} pts`;
}
