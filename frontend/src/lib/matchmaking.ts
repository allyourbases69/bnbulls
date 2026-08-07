import type { RosterBull } from '@/lib/hooks/useRoster';

/**
 * OPPONENT MATCHING, by rating. Pure — no hooks, no chain reads, no randomness
 * that could differ between the server render and the client one.
 *
 * ⚠⚠ THIS FILE USED TO SAY "there is no `ArenaOptOut` contract here — fighting
 * fefers has one, bnbulls deliberately does not", AND THAT WAS THE BUG.
 * `contracts/Yards.sol` IS that contract, it is deployed, and `Duel`'s wiring
 * slot points at it. An opponent is NOT freely nameable: `Duel._requireInYards`
 * runs on every duel and reverts `BullNotInYards` unless BOTH bulls are in the
 * yards under their LIVE owners. Ranking a bull that is out therefore offers a
 * fight that can never settle, and the way that surfaces is vicious — gas
 * estimation on a reverting call returns a garbage number and the RPC rejects
 * *that*, so the player is told "gas limit too high" about a transaction whose
 * gas was never the problem. That is what `matchable` below exists to prevent.
 *
 * ⚠ AND MEMBERSHIP MOVES WITHOUT ANYONE TOUCHING `Yards`. Entry is stored as
 * `(enteredBy, leavesAt)` and requires `enteredBy == the live owner`, so a
 * MARKETPLACE SALE silently voids it. A freshly bought bull ranks perfectly on
 * rating and cannot fight. It has to be filtered, not assumed.
 *
 * ⚠ WHY THIS IS STILL A CONVENIENCE AND NOT A FAIRNESS MECHANISM, stated
 * plainly because it would be easy to over-claim. Within the set of bulls that
 * ARE in the yards, an opponent is passive: their owner opted into being fought
 * by anybody, so choosing one for the player takes nothing away and grants
 * nothing. Matching here is a better default than a token-id box, no more.
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
  /**
   * Ids that are actually fightable: in the yards under their live owner, with
   * no eject counting down. `usePitPool` builds it off `Yards.inYardsMany` plus
   * `statusOf` for the ones that came back in.
   *
   * ⚠ `null`/`undefined` MEANS "WE DO NOT KNOW", AND MUST NOT MEAN "NOBODY".
   * The membership read reverts whole if any id is unreadable, so a flaky rpc
   * would otherwise empty the opponent pool and the page would announce that
   * there is nobody left alive to fight. Unknown therefore falls through to the
   * old behaviour and lets the contract be the one to refuse — a worse error,
   * but an honest one, and `/api/run-duel` still refuses to sign it.
   */
  readonly matchable?: ReadonlySet<number> | null;
}

/**
 * Every legal opponent, closest rating first. The head of this list is the
 * match; rerolling walks down it.
 */
export function rankOpponents(opts: MatchOptions): RosterBull[] {
  const { challenger, pool, myAddress, allowSelfDuel, matchable } = opts;
  const excluded = new Set(opts.exclude ?? []);
  return pool
    .filter((b) => {
      if (b.id === challenger.id) return false;
      if (b.isDead) return false;
      if (excluded.has(b.id)) return false;
      // Not in the yards, or on its way out. `Duel` would revert
      // `BullNotInYards`, and the signer refuses to sign it either way.
      if (matchable && !matchable.has(b.id)) return false;
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
