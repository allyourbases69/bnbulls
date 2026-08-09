'use client';

import { useAccount, useBalance, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { CHAIN_ID } from '@/lib/env';
import { WRAP_GAS_RESERVE_WEI } from '@/lib/constants';

/**
 * WRAP NATIVE BNB INTO WBNB, WITHOUT LEAVING THE SITE.
 *
 * ⚠ THIS EXISTS BECAUSE APPROVING AN EMPTY BALANCE IS A DEAD END, AND THE SITE
 * USED TO LET PLAYERS WALK STRAIGHT INTO IT. A real wallet on mainnet
 * (`0xbafb…e331`) sent five bulls into the bull pit, approved 0.165514 WBNB to
 * the duel contract, and held ZERO WBNB — so every attempt to fight one of its
 * bulls came back "that wallet holds 0 and has approved 0.165514". The approval
 * was real, the permission was real, and there was nothing behind it. Nothing on
 * the page offered a way to get WBNB, so the only fix was to leave and find a
 * DEX.
 *
 * ⚠ AND WBNB IS NOT A DESIGN WART, SO DO NOT "SIMPLIFY" IT AWAY. The wallet
 * SIGNING a fight pays natively through `msg.value`. The opponent is not
 * signing, and native BNB has no allowance mechanism on any EVM chain — you
 * cannot pull native currency from a wallet that is not sending the
 * transaction. `Duel._takeSide` gates its native path on
 * `owner_ == msg.sender` for exactly that reason and drops to the WBNB
 * `balanceOf` + `allowance` path for everyone else. So a bull that can be
 * CHALLENGED is a bull whose owner holds WBNB. Wrapping is the price of being
 * fightable while you are offline.
 *
 * `deposit()` is the canonical native-wrap entrypoint and is 1:1 and
 * instant — no pool, no slippage, no counterparty. The generated `Erc20Abi`
 * does not carry it, so it is declared inline here, the same way `AdminPots`
 * does for the pot top-up.
 */
const WbnbAbi = [
  { type: 'function', name: 'deposit', stateMutability: 'payable', inputs: [], outputs: [] },
] as const;

export interface WrapBnb {
  /** Native BNB this wallet holds. `undefined` while unread — never treat as 0. */
  readonly nativeBalance: bigint | undefined;
  /**
   * Not one fight's worth of WBNB in the wallet. THE state that traps players:
   * the bulls are in the pit, the approval is signed, and nobody can be drawn
   * into a fight. Only ever true off reads that landed.
   */
  readonly cannotCoverOne: boolean;
  /** Short of the whole picked run, which may still cover a fight or two. */
  readonly shortForRun: boolean;
  /** What to wrap: the shortfall, capped by what the wallet can spare for gas. */
  readonly amount: bigint;
  /** There is a real, non-zero amount this wallet can wrap right now. */
  readonly canWrap: boolean;
  /** `amount` is all it can spare and still short of the run. */
  readonly fallsShort: boolean;
  readonly wrap: (amount: bigint) => Promise<unknown>;
  readonly isWrapping: boolean;
  readonly refetch: () => void;
}

/**
 * ⚠ THE SIZING LIVES IN HERE, NOT IN THE COMPONENTS, because two places show
 * this control: the primary slot at the top of step 2 (when wrapping is the
 * blocking step) and the quiet allowance row underneath. Two copies of "how
 * much should we wrap" would eventually disagree, and the number is money.
 */
export function useWrapBnb(
  wbnb: `0x${string}` | undefined,
  sizing?: {
    /** WBNB the wallet holds. `undefined` = unread, never assumed empty. */
    balance: bigint | undefined;
    /** `Duel.fighterCost(wbnb)` — one fight. */
    perFight: bigint | undefined;
    /** How many fights the player picked. */
    fights: number;
  },
): WrapBnb {
  const { address: owner } = useAccount();

  const { data: native, refetch: refetchNative } = useBalance({
    address: owner,
    chainId: CHAIN_ID,
    query: { enabled: !!owner },
  });

  const { writeContractAsync, isPending, data: hash } = useWriteContract();
  const { isLoading: isConfirming } = useWaitForTransactionReceipt({ hash });

  async function wrap(amount: bigint) {
    if (!wbnb || amount <= 0n) return;
    return writeContractAsync({
      address: wbnb,
      abi: WbnbAbi,
      // ⚠ PIN THE CHAIN, same reasoning as `useErc20Approval` — without it
      // viem skips `assertCurrentChain` and this broadcasts wherever the
      // wallet happens to be sitting. Wrapping on the wrong chain buys a
      // worthless token with real money.
      chainId: CHAIN_ID,
      functionName: 'deposit',
      value: amount,
    });
  }

  const nativeBalance = native?.value;
  const balance = sizing?.balance;
  const perFight = sizing?.perFight;

  // ⚠ EVERY FLAG BELOW IS OFF READS THAT LANDED. An unread balance rendering as
  // "you have nothing" would push somebody into a wrap they did not need.
  const read = balance !== undefined && perFight !== undefined && perFight > 0n;
  const runTotal = perFight !== undefined ? perFight * BigInt(Math.max(1, sizing?.fights ?? 1)) : undefined;
  const cannotCoverOne = read && balance < perFight;
  const shortForRun = read && runTotal !== undefined && balance < runTotal;

  // Leave gas behind: wrapping is never the last transaction — the approve and
  // then the fights themselves all still have to be paid for.
  const spendable =
    nativeBalance !== undefined && nativeBalance > WRAP_GAS_RESERVE_WEI
      ? nativeBalance - WRAP_GAS_RESERVE_WEI
      : 0n;
  const want = runTotal !== undefined && balance !== undefined && runTotal > balance ? runTotal - balance : 0n;
  const amount = want > spendable ? spendable : want;

  return {
    nativeBalance,
    cannotCoverOne,
    shortForRun,
    amount,
    canWrap: !!wbnb && amount > 0n,
    fallsShort: amount > 0n && amount < want,
    wrap,
    isWrapping: isPending || isConfirming,
    refetch: () => void refetchNative(),
  };
}
