'use client';

import {
  useAccount,
  useBalance,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { DuelNativeAbi } from '@/lib/abi';
import { CHAIN_ID } from '@/lib/env';
import { WRAP_GAS_RESERVE_WEI } from '@/lib/constants';

/**
 * THE FIGHT BALANCE — native BNB custodied by the duel contract.
 *
 * ⚠ THIS REPLACES `useFightAllowance` + `useWrapBnb` FOR THE BNB LEG, and the
 * reason is worth keeping because the old shape looked like a design wart and
 * was not one. A wallet SIGNING a fight pays natively through `msg.value`. The
 * opponent is not signing, and native BNB has no allowance mechanism on any EVM
 * chain — you cannot pull native currency from a wallet that is not sending the
 * transaction. The original contract solved that with a WBNB allowance, which
 * is correct and is also why players ended up holding a token they never asked
 * for. `DuelNative` solves it by CUSTODY instead: you top up a balance, and a
 * passive stake is debited from it (`_takeSide` → `_debitBnb`). No allowance, no
 * wrapping, no token in anybody's wallet.
 *
 * ── WINNINGS LAND HERE TOO, AND THAT IS THE PART THAT NEEDS SAYING ────
 *
 * `_distributePot` pays the winner by CREDITING this balance, not by
 * transferring anything. That is not an accounting nicety — it is what stops a
 * winner whose wallet has a reverting `receive()` from reverting the entire
 * duel (the old contract had to settle in WBNB precisely to dodge that). The
 * cost is a UX trap: a player wins, looks at their wallet, sees nothing, and
 * concludes they were robbed. Every surface that shows this balance has to make
 * the withdraw obvious, and `FightBalance` is deliberately shaped so a caller
 * cannot render the number without also having `withdrawAll` to hand.
 *
 * ── WITHDRAW IS NOT PAUSABLE, AND THE UI MUST NOT RE-ADD THE PAUSE ───
 *
 * `DuelNative.withdraw` is deliberately outside `whenNotPaused`: "a pause is for
 * stopping fights, not for trapping player money". So nothing in here gates the
 * withdraw controls on fight-readiness, the pit, the picked count, or anything
 * else. If the money is yours you can always take it out. `setPassiveAllowance`
 * is unguarded for the same reason: LOWERING your exposure must always work.
 *
 * ──── THE PASSIVE ALLOWANCE IS THE APPROVAL THAT CUSTODY DELETED ────
 *
 * On the old contract your exposure to a fight you did not sign was the WBNB
 * allowance you granted — a number you chose. The credit ledger removed the
 * approval step and silently replaced that ceiling with YOUR WHOLE BALANCE: a
 * leaked signer key could name your bull at max stake until the float was gone
 * (81 of 90 BNB in a single transaction, in the review's proof of concept).
 * `passiveAllowance` puts that ceiling back.
 *
 * ⚠⚠ IT IS A BUDGET THAT SPENDS DOWN, NOT A PER-FIGHT LIMIT, AND EVERY SURFACE
 * MUST SAY SO. `_takeSide` DECREMENTS it on each passive fight
 * (`passiveAllowance[owner_] = allowed - stake`) — deliberately, because
 * `maxFightCostOf` already bounds ONE fight, and one fight is not what a leaked
 * key does. So a wallet that sets five fights' worth gets exactly five offline
 * fights and then goes quietly unchallengeable. A player who is not told that
 * reads it as the feature having broken.
 *
 * ⚠ IT DEFAULTS TO ZERO, so a wallet that has only DEPOSITED is still not
 * challengeable. Both are required, and a deposit on its own does nothing.
 */
export interface FightBalance {
  /** True once the contract address is known and a fight has a price. */
  readonly configured: boolean;
  /** Custodied BNB. `undefined` while unread — NEVER treat as zero. */
  readonly credit: bigint | undefined;
  /** Native BNB in the wallet, for sizing a deposit. `undefined` = unread. */
  readonly nativeBalance: bigint | undefined;
  /** `DuelNative.fighterCost(wbnb)` — one fight, in wei. */
  readonly perFight: bigint | undefined;
  /** Fights the balance covers. Floor: a part-fight buys no fights. */
  readonly fightsCovered: number;
  /** There is money in here. Gates the winnings banner and the withdraw. */
  readonly hasCredit: boolean;
  /** Not one fight's worth. Only ever true off reads that LANDED. */
  readonly cannotCoverOne: boolean;
  /** Short of the picked run, though it may still cover a fight or two. */
  readonly shortForRun: boolean;
  /** The top-up that would reach the picked run, capped by spendable native. */
  readonly suggested: bigint;
  /** `suggested` is everything the wallet can spare and still short. */
  readonly fallsShort: boolean;
  /** The remaining budget fights you did not start may spend. SPENDS DOWN —
   *  see the header. `undefined` = unread, and never treat that as zero. */
  readonly passiveAllowance: bigint | undefined;
  /** Offline fights the REMAINING allowance still covers. Floor. */
  readonly passiveFightsLeft: number;
  /** Your bulls can be challenged while you are away: the allowance covers at
   *  least one fight AND the balance can actually pay for it. Both, because
   *  either alone is a bull nobody can fight. Only ever off reads that landed. */
  readonly challengeable: boolean;
  /** Set the ceiling once and the allowance has never been set. This is the
   *  state a deposit-only wallet is silently stuck in. */
  readonly allowanceUnset: boolean;
  readonly deposit: (amount: bigint) => Promise<unknown>;
  readonly withdraw: (amount: bigint) => Promise<unknown>;
  readonly withdrawAll: () => Promise<unknown>;
  /** Absolute, not incremental — you state a ceiling rather than topping one
   *  up. Zero switches offline challenges off entirely. */
  readonly setPassiveAllowance: (amount: bigint) => Promise<unknown>;
  readonly isBusy: boolean;
  readonly refetch: () => void;
}

export function useFightBalance(
  /** The DuelNative address. `undefined` disables every read and write. */
  duel: `0x${string}` | undefined,
  /** `fighterCost(wbnb)` — what ONE fight costs. */
  perFight: bigint | undefined,
  /** How many fights the player has picked, for sizing the suggested top-up. */
  fights: number,
): FightBalance {
  const { address: owner } = useAccount();

  const { data: creditRaw, refetch: refetchCredit } = useReadContract({
    address: duel,
    abi: DuelNativeAbi,
    functionName: 'bnbCredit',
    args: owner ? [owner] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: !!duel && !!owner },
  });

  const { data: native, refetch: refetchNative } = useBalance({
    address: owner,
    chainId: CHAIN_ID,
    query: { enabled: !!owner },
  });

  const { data: allowanceRaw, refetch: refetchAllowance } = useReadContract({
    address: duel,
    abi: DuelNativeAbi,
    functionName: 'passiveAllowance',
    args: owner ? [owner] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: !!duel && !!owner },
  });

  const { writeContractAsync, isPending, data: hash } = useWriteContract();
  const { isLoading: isConfirming } = useWaitForTransactionReceipt({ hash });

  // ⚠ EVERY WRITE PINS `chainId`. Without it viem skips `assertCurrentChain`
  // and broadcasts wherever the wallet happens to be sitting — and a deposit on
  // the wrong chain is real money sent to an address that holds no such
  // contract. Same rule as `useErc20Approval` and `useWrapBnb`.
  async function deposit(amount: bigint) {
    if (!duel || amount <= 0n) return;
    return writeContractAsync({
      address: duel,
      abi: DuelNativeAbi,
      chainId: CHAIN_ID,
      functionName: 'deposit',
      value: amount,
    });
  }

  async function withdraw(amount: bigint) {
    if (!duel || amount <= 0n) return;
    return writeContractAsync({
      address: duel,
      abi: DuelNativeAbi,
      chainId: CHAIN_ID,
      functionName: 'withdraw',
      args: [amount],
    });
  }

  /**
   * State the ceiling on what fights you did not start may spend.
   *
   * ⚠ NOT GATED ON ANYTHING, ON PURPOSE. `setPassiveAllowance` is unpausable
   * and unguarded on the contract precisely so a player can always REDUCE their
   * exposure — including to zero, including mid-incident, including while
   * fights are paused. Adding a readiness check here would re-impose the very
   * lock the contract refuses to have.
   */
  async function setPassiveAllowance(amount: bigint) {
    if (!duel) return;
    return writeContractAsync({
      address: duel,
      abi: DuelNativeAbi,
      chainId: CHAIN_ID,
      functionName: 'setPassiveAllowance',
      args: [amount],
    });
  }

  /** The one-tap exit. `withdrawAll` reverts `ZeroAmount` on an empty balance,
   *  so callers gate it on `hasCredit` rather than sending a doomed tx. */
  async function withdrawAll() {
    if (!duel) return;
    return writeContractAsync({
      address: duel,
      abi: DuelNativeAbi,
      chainId: CHAIN_ID,
      functionName: 'withdrawAll',
    });
  }

  const credit = creditRaw as bigint | undefined;
  const nativeBalance = native?.value;

  // ⚠ EVERY FLAG BELOW IS OFF READS THAT LANDED. An unread balance rendering as
  // "you have nothing" would push somebody into a top-up they did not need —
  // the same rule the marketplace peg and the mint panel already follow.
  const priced = perFight !== undefined && perFight > 0n;
  const read = priced && credit !== undefined;
  const runTotal = priced ? perFight * BigInt(Math.max(1, fights)) : undefined;

  // Integer division on purpose: a part-fight of balance buys no fights.
  const fightsCovered = read ? Number(credit / perFight) : 0;

  // Leave gas behind. Depositing is never the last transaction — the fights
  // themselves still have to be paid for, and a wallet that deposits its whole
  // balance is a wallet that cannot then fight with it.
  const spendable =
    nativeBalance !== undefined && nativeBalance > WRAP_GAS_RESERVE_WEI
      ? nativeBalance - WRAP_GAS_RESERVE_WEI
      : 0n;
  const want =
    runTotal !== undefined && credit !== undefined && runTotal > credit ? runTotal - credit : 0n;
  const suggested = want > spendable ? spendable : want;

  const passiveAllowance = allowanceRaw as bigint | undefined;
  const allowanceRead = priced && passiveAllowance !== undefined;
  // Integer division, same as `fightsCovered`: a part-fight of budget buys no
  // fights, and the contract decrements by the full stake or reverts.
  const passiveFightsLeft = allowanceRead ? Number(passiveAllowance / perFight) : 0;

  // ⚠ BOTH HALVES, AND OFF READS THAT LANDED. An allowance with no balance
  // behind it is a bull that reverts `InsufficientCredit` when someone tries;
  // a balance with no allowance reverts `PassiveAllowanceExceeded`. Either one
  // alone is a bull nobody can actually fight, which is exactly the silent
  // half-configured state a deposit-only wallet falls into.
  const challengeable =
    read && allowanceRead && passiveAllowance >= perFight && credit >= perFight;

  return {
    configured: !!duel && priced,
    credit,
    nativeBalance,
    perFight,
    fightsCovered,
    hasCredit: credit !== undefined && credit > 0n,
    cannotCoverOne: read && credit < perFight,
    shortForRun: read && runTotal !== undefined && credit < runTotal,
    suggested,
    fallsShort: suggested > 0n && suggested < want,
    passiveAllowance,
    passiveFightsLeft,
    challengeable,
    allowanceUnset: allowanceRead && passiveAllowance === 0n,
    deposit,
    withdraw,
    withdrawAll,
    setPassiveAllowance,
    isBusy: isPending || isConfirming,
    refetch: () => {
      void refetchCredit();
      void refetchNative();
      void refetchAllowance();
    },
  };
}
