import type { RosterBull } from '@/lib/hooks/useRoster';

/**
 * OPPONENT MATCHING, by rating. Pure — no hooks, no chain reads, no randomness
 * that could differ between the server render and the client one.
 *
 * ⚠ WHY THIS IS A CLIENT-SIDE CONVENIENCE AND NOT A FAIRNESS MECHANISM, stated
 * plainly because it would be easy to over-claim.
 *
 * On bnbulls an opponent is PASSIVE: `Duel.sol` lets a player name ANY living,
 * unlisted bull and its owner never opts in (there is no `ArenaOptOut`
 * contract here — fighting fefers has one, bnbulls deliberately does not). So
 * a player could always pick any opponent by hand, and choosing one for them
 * takes nothing away and grants nothing. Matching here is a better default
 * than a token-id box, no more.
 *
 * The thing that actually stops fight-shopping is server-side and unchanged:
 * `/api/run-duel` pins ONE standing outcome per wallet, so re-asking hands the
 * same fight back until it settles. That is why rerolling below only re-picks
 * an opponent BEFORE a fight is rolled — it cannot be used to re-roll a result.
 *
 * ── HOW IT RANKS
 *   1. closest rating first — `|challenger.elo - candidate.elo|`
 *   2. ties broken by a stable per-pair key, NOT by token id
 *
 * Rule 2 earns its place at launch, not later: every bull starts on the same
 * `STARTING_ELO`, so on day one EVERY candidate is an exact rating tie. Sorted
 * by id, every player in the game would be matched against bull #1, and the
 * reroll would walk everyone through #2, #3, #4 in lockstep. The pair key
 * spreads that out while staying deterministic, so the same player rerolling
 * the same fighter gets the same sequence back.
 */

/** A tiny deterministic 32-bit mixer. Same inputs, same answer, every time and
 *  on both sides of a server render — which `Math.random()` would not be. */
function pairKey(a: number, b: number): number {
  let h = (a * 0x27d4eb2d) ^ (b + 0x9e3779b9);
  h = Math.imul(h ^ (h >>> 15), 0x85ebca6b);
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
  return (h ^ (h >>> 16)) >>> 0;
}

export interface MatchOptions {
  /** The bull that is about to fight. */
  readonly challenger: RosterBull;
  /** Every candidate opponent. Already filtered to alive bulls. */
  readonly pool: readonly RosterBull[];
  /** The connected wallet, lowercased. Its bulls are excluded unless
   *  `allowSelfDuel` is on, because `Duel.submitDuel` reverts
   *  `SelfDuelBlocked` on them at settlement (`DECISIONS.md §16`). */
  readonly myAddress: string | null;
  readonly allowSelfDuel: boolean;
  /** Ids to leave out — the rest of the player's own fight queue. */
  readonly exclude?: readonly number[];
}

/**
 * Every legal opponent, closest rating first. The head of this list is the
 * match; rerolling walks down it.
 */
export function rankOpponents(opts: MatchOptions): RosterBull[] {
  const { challenger, pool, myAddress, allowSelfDuel } = opts;
  const excluded = new Set(opts.exclude ?? []);
  return pool
    .filter((b) => {
      if (b.id === challenger.id) return false;
      if (b.isDead) return false;
      if (excluded.has(b.id)) return false;
      if (!allowSelfDuel && myAddress && b.owner.toLowerCase() === myAddress) return false;
      return true;
    })
    .sort((x, y) => {
      const dx = Math.abs(x.elo - challenger.elo);
      const dy = Math.abs(y.elo - challenger.elo);
      if (dx !== dy) return dx - dy;
      return pairKey(challenger.id, x.id) - pairKey(challenger.id, y.id);
    });
}

/**
 * Pick the opponent at `rerolls` steps down the ranked list, wrapping. Wrapping
 * rather than stopping means the reroll button never dead-ends on a two-bull
 * testnet, and it is honest: it is showing you the same short list again.
 */
export function pickOpponent(ranked: readonly RosterBull[], rerolls: number): RosterBull | null {
  if (ranked.length === 0) return null;
  const i = ((rerolls % ranked.length) + ranked.length) % ranked.length;
  return ranked[i] ?? null;
}

/** How far apart the two ratings are, for the "how close is this match" line. */
export function ratingGap(a: RosterBull, b: RosterBull): number {
  return Math.abs(a.elo - b.elo);
}
