/**
 * THE WORDS THE FIGHT SAYS.
 *
 * ⚠ THIS IS A STAGING FILE AND IT SHOULD NOT EXIST FOREVER.
 * `lib/brand.ts` is where every player-facing string belongs, and its own
 * header says so: "Nothing below may be duplicated into a component. If you
 * find yourself typing a lore word in a .tsx file, it belongs here instead."
 * These strings are new copy for the live fight and the victory card, and
 * `brand.ts` was outside the scope of the batch that wrote them. Keeping them
 * in ONE named module rather than sprinkled through three components is the
 * next best thing: the move into `brand.ts` is then a cut and paste, and
 * nothing has to be hunted for. Do not add a fourth home for fight copy.
 *
 * Anything already in `brand.ts` is imported from there and NOT restated here.
 * The truck, the butcher and the rescue line in particular: `DEATH` owns them,
 * this file must never grow a second death metaphor.
 *
 * VOICE (`VOICE-AND-BRAND.md §1`): lowercase, plain, australian. No em-dashes,
 * the separator is `·`. No "stake", no "fully pvp", no "win both pots".
 */

// ─── the fight, while it runs ─────────────────────────────────────────

export const FIGHT = {
  /** `aria-label` on the modal. Screen readers get told what opened. */
  dialogLabel: 'the fight',
  /** Bottom-right, the reference's "Skip to result". */
  skip: 'skip to the result',
  /**
   * Bottom-right, the reference's "Cancel". Two labels because only ONE of
   * them is true at a time: before the wallet signs there is nothing to cancel
   * BUT the fight, and after it there is a transaction on its way that closing
   * a panel cannot call back. Labelling the second one "cancel" would be a lie
   * about money.
   */
  cancel: 'cancel',
  close: 'close the fight',
  /** The live marker, top right, once the last blow has landed. */
  winsSuffix: 'wins',
  draw: 'a draw',
  /** Under the winner marker while the transaction is still going. */
  stillLanding: 'still landing on chain',
} as const;

// ─── the pots, along the top ──────────────────────────────────────────

export const POT_STRIP = {
  label: 'jackpot',
  /**
   * ⚠ "WIN BOTH POTS" IS BANNED AND THIS IS THE LINE THAT REPLACES IT.
   * There are two pools on screen at once, which is exactly the situation the
   * ban exists for. A fight opens a ticket on each at its own odds and the
   * first to roll takes it; one fight never pays both. `brand.ts` POTS.rule
   * says the same thing at length, this is the strip-sized version of it.
   */
  neverBoth: 'one fight never pays both',
  /** Live `oddsOneIn` off the pot, or nothing. Never a guessed number. */
  odds: (oneIn: number) => `1 in ${oneIn}`,
} as const;

// ─── the victory card ─────────────────────────────────────────────────

export const VICTORY = {
  eyebrow: 'victory',
  drawEyebrow: 'no result',
  drawHeadline: 'nobody wins it',
  /** The suffix after the winner's name. */
  winsSuffix: 'wins',
  rounds: (n: number) => `${n} round${n === 1 ? '' : 's'}`,
  confirmed: 'payment confirmed on chain',
  pending: 'still landing on chain. this page updates itself.',
  fightAgain: 'fight again',
  viewTx: 'view the transaction',
  /** Row labels. Lowercase, mono, small. */
  potSlice: 'into the pot',
  /**
   * ⚠ THE ONE FACT THIS CARD EXISTS TO STATE PLAINLY. `brand.ts` DEAL: the
   * winner takes 90% of the money in the middle, 3% drops into the pot and the
   * dev's cut is what is left. The pot slice therefore comes out of the dev
   * side, not out of the winner's 90%, and a player looking at a number leaving
   * their fight deserves to be told which pocket it left.
   */
  potSliceWhere: 'out of the dev cut, not your winnings',
  purse: 'money in the middle',
  purseEach: 'each side put in',
  balance: 'your balance',
  ratingLabel: 'rating',
  /** The fight is over but the chain has not answered yet. */
  landing: 'the chain has not called it yet',
} as const;

/**
 * One line under the winner's name.
 *
 * ⚠ DETERMINISTIC, NOT RANDOM. A `Math.random()` pick changes on every
 * re-render, and this card re-renders every time the receipt poll comes back,
 * so a random line would visibly flicker while the player read it. Keyed off
 * the fight itself, it is the same line for the same fight forever, which also
 * means a screenshot and a re-open agree.
 */
export function victoryFlavour(winnerTokenId: number, rounds: number): string {
  const lines = [
    'the other one is still on the floor.',
    'never really in doubt.',
    'ugly. still counts.',
    'walked in swinging, walked out with the purse.',
    'the pit got what it came for.',
    'horns did the talking.',
    'that will do.',
    'quick work, barely got dirty.',
  ];
  const i = Math.abs(winnerTokenId * 31 + rounds * 7) % lines.length;
  return lines[i];
}

/** Both still standing when the round cap hit. Nobody takes the purse. */
export const DRAW_FLAVOUR = 'both still standing when the bell went. nobody takes the purse.';
