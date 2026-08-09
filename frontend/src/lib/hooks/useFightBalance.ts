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
 * else. If the money is yours you can always take it out.
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
  readonly deposit: (amount: bigint) => Promise<unknown>;
  readonly withdraw: (amount: bigint) => Promise<unknown>;
  readonly withdrawAll: () => Promise<unknown>;
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
    deposit,
    withdraw,
    withdrawAll,
    isBusy: isPending || isConfirming,
    refetch: () => {
      void refetchCredit();
      void refetchNative();
    },
  };
}
