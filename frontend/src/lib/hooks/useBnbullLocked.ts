'use client';

import { useReadContract } from 'wagmi';
import { QUOTE_REFRESH_MS } from '@/lib/constants';

/**
 * IS $BNBULL STILL TRANSFER-LOCKED ON FOUR.MEME'S CURVE?
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHY THIS EXISTS, WHEN EVERY OTHER BNBULL LEG GATES ON A ZERO PRICE
 * ═══════════════════════════════════════════════════════════════════════
 * `/mint`, `/market` and `/graveyard` all decide "is the bnbull leg usable"
 * from a PRICE: `MintDrop.quote` returns `bnbullDue = 0`, `Marketplace`'s peg
 * is `0`, `Graveyard.bnbullPerUsd` is `0`. Each of those contracts treats zero
 * as "this leg is not priced", reverts `BnbullPathNotPriced`, and the UI reads
 * the zero and greys the option. That works and those pages need nothing else.
 *
 * ⚠ DUEL IS THE EXCEPTION, AND IT INVERTS THE MEANING OF ZERO.
 * `Duel.sol:536`: *"Zero means 'the BNB leg is not priced', which reads as a
 * FREE BNB fight exactly as `fightCostOf[bnbull] == 0` reads as a free BNBULL
 * one."* A free fight still opens a jackpot ticket, so zeroing the duel's
 * bnbull price would be a WORSE hole than the mispricing it was fixing. The
 * duel's bnbull cost is therefore a real, non-zero number
 * (`fightCostOf[BNBULL]`, repriced 2026-08-09 off the live curve) — which means
 * `/duel` cannot use the zero test the other three pages use. It has to ask the
 * question directly.
 *
 * ⚠ THE HONEST QUESTION IS THE TOKEN'S OWN LOCK, NOT A PROXY FOR IT.
 * Pre-graduation four.meme holds $BNBULL in a transfer-locked custodial phase:
 * a plain `transfer` reverts `Token: Transfer is restricted`, and
 * `Duel.submitDuel` moves the stake with `transferFrom`. So EVERY bnbull duel
 * is impossible until the curve fills, whatever the price says. Reading the
 * lock itself beats the alternatives:
 *
 *   · a "does a BNBULL/WBNB pair exist yet" probe infers the lock from a
 *     SIDE EFFECT of graduation, and would need the factory address and a fee
 *     tier sweep to answer a question the token answers directly; and
 *   · a hardcoded flag has to be remembered and shipped at graduation, which
 *     is exactly the sort of manual step that gets missed.
 *
 * `_mode` flips 1 -> 0 on the SAME token address the moment the curve fills, so
 * this re-enables the leg by itself with nothing to deploy.
 *
 * ⚠ THREE-VALUED ON PURPOSE. `undefined` is "we have not read it", which is
 * NOT "unlocked" and NOT "locked". Callers must only ever disable on a
 * definitive `true` — the rule `ListBullForm` states for the marketplace peg:
 * never switch a feature off because an rpc blipped.
 */

/** `_mode()` is four.meme's own getter and is public on the token. */
const FourMemeModeAbi = [
  {
    type: 'function',
    name: '_mode',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint8', name: '' }],
  },
] as const;

/** four.meme's curve phase: transfers are gated to the pad. */
const MODE_CURVE_LOCKED = 1;

export interface BnbullLock {
  /** `true` only when the token definitively says it is still locked.
   *  `undefined` while unread, or when the read reverted. */
  readonly locked: boolean | undefined;
}

export function useBnbullLocked(token: `0x${string}` | undefined): BnbullLock {
  const { data } = useReadContract({
    address: token,
    abi: FourMemeModeAbi,
    functionName: '_mode',
    query: {
      enabled: !!token,
      // Graduation is a one-shot event we do not otherwise hear about, so poll
      // on the same clock as the fight quotes and the leg lights up on its own.
      refetchInterval: QUOTE_REFRESH_MS,
    },
  });

  return {
    // ⚠ ONLY MODE 1 IS TREATED AS LOCKED. An unreadable `_mode` (a token that
    // is not a four.meme one, a reverting read, a node that did not answer)
    // leaves this `undefined` and the caller leaves the leg alone. Disabling a
    // currency off a failed read is the failure this is written to avoid.
    locked: data === undefined ? undefined : Number(data) === MODE_CURVE_LOCKED,
  };
}
