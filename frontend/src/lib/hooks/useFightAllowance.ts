'use client';

import { useReadContract } from 'wagmi';
import { useAccount } from 'wagmi';
import { Erc20Abi } from '@/lib/abi';
import { useErc20Approval } from './useErc20Approval';

/**
 * HOW MANY FIGHTS THIS WALLET'S WHOLE PACK IS ALLOWED, IN ONE CURRENCY.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS APPLIES TO **BOTH** CURRENCIES, INCLUDING BNB. READ THIS BEFORE
 *   "SIMPLIFYING" IT AWAY.
 * ═══════════════════════════════════════════════════════════════════════
 *
 * It is tempting to think a BNB fight needs no approval, because the amount
 * rides along as `msg.value`. `Duel._takeSide` shows why that is only half
 * true — the native convenience path is gated on `owner_ == msg.sender`:
 *
 *     // The native convenience path: only ever for the wallet that sent the
 *     // BNB, because only `msg.sender` can post value. A passive opponent
 *     // stakes by allowance, always.
 *     if (asset == address(wbnb) && owner_ == msg.sender && credit >= stake) {
 *
 * So raw BNB covers YOUR OWN side when YOU submit. The moment one of your
 * bulls is the one somebody ELSE picked, you are the passive side: `owner_`
 * is you, `msg.sender` is them, the condition fails, and settlement drops to
 * the WBNB `balanceOf` + `allowance` path below it, reverting
 * `StakeNotApproved` if there is no allowance.
 *
 * ⚠ IT USED TO FAIL SILENTLY, AND THAT WAS THE REAL DAMAGE. `/api/run-duel`'s
 * `resolveSide` walked its candidate assets and simply `continue`d past a side
 * that was not `erc20Ready`. On the old default `AUTO` pick a bull whose owner
 * had no WBNB allowance was never matched, never errored and never explained
 * itself — the owner just watched their bulls sit there.
 *
 * `AUTO` is gone (owner call, 2026-08-07) and the skip went with it: every
 * currency the signer tries now comes back in the error with its own reason, so
 * a missing allowance reads as "bull #N cannot be drawn into this fight, it
 * holds X and has approved Y". THIS HOOK IS STILL THE FIX, not a leftover — the
 * error tells you after the fact, the numbers below tell you before.
 *
 * ── WHAT "ALLOWED" ACTUALLY MEANS ────────────────────────────────────
 *
 * `_takeSide` checks BOTH `balanceOf` and `allowance` before it will pull a
 * passive stake, so the honest count is limited by whichever is smaller. A
 * wallet that approved 50 fights but holds two fights' worth of WBNB can be
 * drawn into two, not fifty — and telling it "50 approved" would be the same
 * class of lie as the one this file exists to fix.
 *
 * ── AND IT IS A SHARED POOL, NOT A PER-BULL BUDGET ───────────────────
 *
 * The allowance is per WALLET and per CURRENCY. It is not divided between the
 * bulls you sent in: send ten in and approve one fight, and the first fight by
 * any one of them consumes the whole allowance, leaving the other nine
 * unfightable until it is topped up. That is the owner's own description of
 * the behaviour he wants, and it is what the ERC-20 allowance already does.
 *
 * ── ONE APPROVAL, SIZED FOR THE RUN (owner call, 2026-08-07) ─────────
 *
 * Owner, verbatim: *"they should be able to sign BNB or BNBULL ONCE and onchain
 * will remember they have done that approval, then they just need to say how
 * many fights they are keen for."*
 *
 * `fights` IS that control, and `covers` is what makes it stick: once the
 * standing allowance already reaches the picked number, the approve button goes
 * away entirely instead of sitting there inviting another signature for
 * permission the chain has already recorded. Nothing here batches on chain and
 * nothing pretends to — `Duel.sol` settles one signed fight per wallet at a
 * time. What this collapses is the SIGNING, from one approve per fight down to
 * one per run.
 */
export interface FightAllowance {
  /** True once we know the token and what a fight costs in it. */
  readonly configured: boolean;
  /** The ERC-20 being approved. The bnb row needs it to offer a wrap. */
  readonly token: `0x${string}` | undefined;
  readonly perFight: bigint | undefined;
  readonly allowance: bigint | undefined;
  readonly balance: bigint | undefined;
  /** Fights the pack can still be drawn into, limited by allowance AND balance. */
  readonly fightsAllowed: number;
  /** The binding constraint is the wallet's balance, not the approval — a
   *  different problem with a different fix, so the UI must not say "approve
   *  more" when more approval would change nothing. */
  readonly limitedByBalance: boolean;
  /** What the approve transaction will ask for, at the currently picked count. */
  readonly approvalTotal: bigint | undefined;
  /**
   * The standing allowance already reaches the picked run, so there is nothing
   * to sign. This is the whole point of sizing the approve: it turns the button
   * off rather than leaving one up that would re-approve what the chain already
   * remembers.
   */
  readonly covers: boolean;
  /** An allowance exists at all, whatever size. Gates the revoke control. */
  readonly hasAny: boolean;
  readonly approve: () => Promise<unknown>;
  readonly revoke: () => Promise<unknown>;
  readonly isApproving: boolean;
  readonly refetch: () => void;
}

export function useFightAllowance(
  token: `0x${string}` | undefined,
  spender: `0x${string}` | undefined,
  /** `Duel.fighterCost(asset)` — what ONE fight costs in this currency. */
  perFight: bigint | undefined,
  /** How many fights the player has picked to approve. */
  fights: number,
): FightAllowance {
  const { address: owner } = useAccount();
  const priced = perFight !== undefined && perFight > 0n;
  const approvalTotal = priced ? perFight * BigInt(Math.max(1, fights)) : undefined;

  const { allowance, approve, revoke, isApproving, refetchAllowance } = useErc20Approval(
    token,
    spender,
    approvalTotal,
  );

  const { data: balance, refetch: refetchBalance } = useReadContract({
    address: token,
    abi: Erc20Abi,
    functionName: 'balanceOf',
    args: owner ? [owner] : undefined,
    query: { enabled: !!token && !!owner },
  });

  const bal = balance as bigint | undefined;
  // Integer division on purpose: a part-fight of allowance buys no fights.
  const byAllowance = priced && allowance !== undefined ? allowance / perFight : undefined;
  const byBalance = priced && bal !== undefined ? bal / perFight : undefined;
  const fightsAllowed =
    byAllowance === undefined
      ? 0
      : byBalance === undefined
        ? Number(byAllowance)
        : Number(byAllowance < byBalance ? byAllowance : byBalance);

  const current = allowance as bigint | undefined;

  return {
    configured: !!token && priced,
    token,
    perFight,
    allowance: current,
    balance: bal,
    fightsAllowed,
    limitedByBalance:
      byAllowance !== undefined && byBalance !== undefined && byBalance < byAllowance,
    approvalTotal,
    // ⚠ UNDEFINED IS NOT "COVERED". An allowance read that has not landed must
    // never switch the approve button off — that would hide the one control a
    // player needs, off a read that simply has not answered yet.
    covers: approvalTotal !== undefined && current !== undefined && current >= approvalTotal,
    hasAny: current !== undefined && current > 0n,
    approve,
    revoke,
    isApproving,
    refetch: () => {
      void refetchAllowance();
      void refetchBalance();
    },
  };
}
