/**
 * ELO rating calculations.
 *
 * ⚠ PORTED VERBATIM from Fighting Fefers (`app/frontend/src/core/elo.ts`). K
 * factors (32 / 24 / 16), their game-count boundaries (10 / 50), the 400-point
 * scale, the `Math.round`, and the 100-point floor are all unchanged —
 * `BNBULLS-BOOTSTRAP.md §3` puts ELO in the "carries over unchanged" list.
 *
 * `Duel.sol` deliberately does NOT re-implement any of this on chain: it says
 * so in its own header — "ELO uses 10^((B-A)/400) in TypeScript; a Solidity
 * re-implementation would diverge on rounding from the very numbers the UI
 * showed the player, so the signer signs its own arithmetic instead". So THIS
 * file is the authority on every rating in the game, and its output travels
 * inside the signed `DuelResult` as `newEloA` / `newEloB`.
 *
 * `Bulls.STARTING_ELO` / `Bulls.MIN_ELO` exist on chain too. Keep the constant
 * below in step with the contract's `STARTING_ELO` if either ever moves.
 */

export const STARTING_ELO = 1000;

export type Outcome = 'win' | 'loss' | 'tie';

function outcomeScore(o: Outcome): number {
  switch (o) {
    case 'win':
      return 1;
    case 'loss':
      return 0;
    case 'tie':
      return 0.5;
  }
}

export function expectedScore(ratingA: number, ratingB: number): number {
  return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

export function kFactor(gamesPlayed: number): number {
  if (gamesPlayed < 0) {
    throw new Error(`gamesPlayed must be non-negative, got ${gamesPlayed}`);
  }
  if (gamesPlayed <= 10) {
    return 32;
  }
  if (gamesPlayed <= 50) {
    return 24;
  }
  return 16;
}

export function ratingChange(
  playerRating: number,
  opponentRating: number,
  outcome: Outcome,
  gamesPlayed: number,
): number {
  const k = kFactor(gamesPlayed);
  const expected = expectedScore(playerRating, opponentRating);
  const actual = outcomeScore(outcome);
  const delta = k * (actual - expected);
  return Math.round(delta);
}

export function applyRatingChange(current: number, change: number): number {
  const next = current + change;
  return next < 100 ? 100 : next;
}

export function applyDuelResult(
  ratingA: number,
  ratingB: number,
  gamesA: number,
  gamesB: number,
  outcomeForA: Outcome,
): { newA: number; newB: number; deltaA: number; deltaB: number } {
  const outcomeForB: Outcome =
    outcomeForA === 'win' ? 'loss' : outcomeForA === 'loss' ? 'win' : 'tie';
  const deltaA = ratingChange(ratingA, ratingB, outcomeForA, gamesA);
  const deltaB = ratingChange(ratingB, ratingA, outcomeForB, gamesB);
  return {
    newA: applyRatingChange(ratingA, deltaA),
    newB: applyRatingChange(ratingB, deltaB),
    deltaA,
    deltaB,
  };
}
