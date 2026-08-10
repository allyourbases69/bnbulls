'use client';

import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { JackpotNativeAbi } from '@/lib/abi';
import { CHAIN_ID, contractAddress, isNativePot } from '@/lib/env';

/**
 * AN UNCLAIMED JACKPOT PRIZE — native BNB the pot owes you.
 *
 * ⚠ ON THE NATIVE POT, "AWARDED" NO LONGER MEANS "PAID", AND NOTHING ELSE ON
 * THE SITE SAYS SO. `JackpotNative.resolve` settles a win by writing
 * `owed[winner]`; the winner then calls `withdraw`/`withdrawAll` themselves.
 * That is not bookkeeping fussiness — `resolve` walks a BATCH of tickets, so a
 * single winner with a reverting `receive()` could otherwise revert the whole
 * batch and wedge the queue for everybody behind them. A storage write cannot
 * revert, so the hostile wallet can only ever fail its own withdrawal.
 *
 * The cost of that safety is a UX trap sharper than the duel one, because the
 * jackpot is the loudest event in the game: the telegram card announces a
 * winner, the player checks their wallet, finds nothing, and concludes the
 * game stole from them. Every surface that can know about `owed` has to show
 * it and make the claim obvious. Same reasoning as `useFightBalance`, and the
 * same shape deliberately — a caller cannot hold the number without also
 * holding the button that empties it.
 *
 * ── WITHDRAW IS NOT PAUSABLE ─────────────────────────────────────────
 *
 * `withdraw` sits outside `whenNotPaused` on purpose. Nothing here gates the
 * claim on anything: if the prize is yours it is always claimable.
 *
 * ── THE $BNBULL POT IS NOT THIS ──────────────────────────────────────
 *
 * It still transfers an ERC-20 straight to the winner, so there is nothing to
 * claim and this hook stays dormant for it (`isNativePot`).
 */
export interface JackpotPrize {
  /** True only for a native pot with a connected wallet. */
  readonly configured: boolean;
  /** Native BNB the pot owes this wallet. `undefined` = unread, NOT zero. */
  readonly owed: bigint | undefined;
  /** There is a prize waiting. Gates the whole banner. */
  readonly hasPrize: boolean;
  readonly claim: () => Promise<unknown>;
  readonly isBusy: boolean;
  readonly refetch: () => void;
}

export function useJackpotPrize(
  name: 'jackpotBnbull' | 'jackpotBnb' = 'jackpotBnb',
): JackpotPrize {
  const { address: owner } = useAccount();
  const potAddress = contractAddress(name);
  const native = isNativePot(name);
  // Dormant unless this pot actually custodies prizes. Passing `undefined`
  // disables the read rather than pointing it at a contract with no such view.
  const address = native && potAddress ? potAddress : undefined;

  const { data, refetch } = useReadContract({
    address,
    abi: JackpotNativeAbi,
    functionName: 'owed',
    args: owner ? [owner] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: !!address && !!owner },
  });

  const { writeContractAsync, isPending, data: hash } = useWriteContract();
  const { isLoading: isConfirming } = useWaitForTransactionReceipt({ hash });

  /** ⚠ PINS `chainId`, same rule as every other write in this app: without it
   *  viem skips `assertCurrentChain` and broadcasts wherever the wallet is
   *  sitting. `withdrawAll` reverts on an empty balance, so callers gate on
   *  `hasPrize` rather than sending a doomed transaction. */
  async function claim() {
    if (!address) return;
    return writeContractAsync({
      address,
      abi: JackpotNativeAbi,
      chainId: CHAIN_ID,
      functionName: 'withdrawAll',
    });
  }

  const owed = data as bigint | undefined;

  return {
    configured: !!address && !!owner,
    owed,
    // Only ever true off a read that LANDED — an unread prize must not render
    // as "nothing owing", and an unread failure must not render as a prize.
    hasPrize: owed !== undefined && owed > 0n,
    claim,
    isBusy: isPending || isConfirming,
    refetch: () => void refetch(),
  };
}
