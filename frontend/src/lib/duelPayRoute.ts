/**
 * HOW ONE SIDE OF A FIGHT ACTUALLY GETS PAID.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠⚠ THIS FILE EXISTS BECAUSE TWO QUESTIONS STOPPED BEING ONE.
 * ═══════════════════════════════════════════════════════════════════════
 * Before the native migration, "is there `msg.value` riding along with this
 * transaction" and "is this side paid by pulling an ERC-20" had the same answer,
 * so one inline expression in `FightAction` covered both. On `DuelNative` they
 * came apart, and the gap shipped to mainnet as a dead end on the main action of
 * the game.
 *
 * THE BUG, END TO END:
 *
 *   1. `/api/run-duel` returns `nativeValue: 0n` whenever the player's FIGHT
 *      BALANCE covers their side. That is correct and deliberate — paying from
 *      the credit ledger is the entire reason the ledger exists.
 *   2. The BNB leg's asset key is still the WBNB ADDRESS. It has to be:
 *      `fighterCost(WBNB)` is how a BNB fight is priced. So the asset is not
 *      the zero address.
 *   3. The old test read those two facts as "no value + a token address, so
 *      this must be an ERC-20 payment", found a zero WBNB allowance, and put
 *      **"approve wbnb to fight"** in front of the player.
 *
 * Approving achieved exactly nothing. `DuelNative._takeSide` handles
 * `asset == address(wbnb)` through `msg.value` and then `_debitBnb`, and
 * RETURNS before it ever constructs an `IERC20` — there is no `transferFrom` on
 * that path to authorise. The player sat at a button that could not advance,
 * being sent to the one token this project migrated away from.
 *
 * ⚠ AND IT GOT WORSE THE BETTER SOMEBODY FOLLOWED THE FLOW. `nativeValue === 0n`
 * is not an edge case — it is the NORMAL state for anybody who has topped up,
 * which the bull pit now walks every player through step by step. The only
 * wallet that escaped was one with no fight balance at all.
 *
 * ⚠ THE FIX BELONGS HERE, NOT IN THE SIGNER. Making the api send a non-zero
 * `nativeValue` would "work" by never paying from credit, which deletes the
 * feature. What was wrong was the client's inference, so the inference is what
 * changed — and it is a pure function in its own module now so it can be proved
 * rather than argued about. `scripts/verify-pay-route.ts` walks the whole
 * matrix; a regression is a red build, not another live dead end.
 */

/** The asset key a side stakes nothing in. */
export const NO_ASSET = '0x0000000000000000000000000000000000000000';

export interface PaySide {
  /** False when the quote names a pair this component is not showing — see
   *  `mySide` in `FightAction`, where unknown stays unknown. */
  readonly hasSide: boolean;
  /** What the wallet will attach to `submitDuel`. Zero means this side is paid
   *  some other way, NOT that it is unpaid. */
  readonly nativeValue: bigint;
  /** The signed asset key for this side. ⚠ The BNB leg's key is the WBNB
   *  address, so this can never be the discriminator on its own. */
  readonly asset: string;
  /** `stakes.oracleA/B` from the signer, set as `asset.kind === 'bnb'`. THE
   *  only trustworthy "is this the bnb leg" signal on the client. */
  readonly isBnbLeg: boolean;
  /** `NATIVE_DUEL` — told at build time, never sniffed. See `lib/env.ts`. */
  readonly nativeDuel: boolean;
}

/**
 * Does this side need an ERC-20 allowance before the fight can settle?
 *
 * ⚠ ON `DuelNative` THE ANSWER IS ALWAYS NO FOR THE BNB LEG, whatever the
 * attached value is, because that leg has no `transferFrom` path at all. On the
 * LEGACY contract it is still yes when the value falls short — the old bnb leg
 * really does settle out of a WBNB allowance — so the flag is load-bearing and
 * this must never become an unconditional exemption.
 */
export function needsErc20Approval(side: PaySide): boolean {
  if (!side.hasSide) return false;
  // Value attached covers this side outright. Nothing to authorise.
  if (side.nativeValue !== 0n) return false;
  // A side that stakes nothing stakes nothing.
  if (side.asset === NO_ASSET) return false;
  // ⚠ THE FIX. Native contract + bnb leg = custody, never an allowance.
  if (side.nativeDuel && side.isBnbLeg) return false;
  return true;
}
