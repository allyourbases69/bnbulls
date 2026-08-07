'use client';

import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { Erc20Abi } from '@/lib/abi';
import { CHAIN_ID } from '@/lib/env';

/**
 * Shared allowance check + approve flow for the three surfaces that need it
 * (mint, graveyard revives, marketplace buys/lists — every stablecoin/BNBULL
 * payment leg here is approval-based, never escrow-based).
 */
export function useErc20Approval(
  token: `0x${string}` | undefined,
  spender: `0x${string}` | undefined,
  required: bigint | undefined,
  /**
   * What the approve TRANSACTION should ask for, when that differs from what
   * this one action needs. The duel page uses it to cover a run of N fights in
   * a single approval — the one thing on that page that genuinely batches,
   * since the contract runs fights one per wallet at a time and there is
   * nothing else to bundle. Defaults to `required`, so every existing caller
   * behaves exactly as before.
   *
   * ⚠ `needsApproval` is still measured against `required`, never against
   * this. Otherwise a wallet with enough allowance for the fight in front of
   * it would be told to approve again just because it had not pre-paid for the
   * whole queue.
   */
  approveAmount?: bigint,
) {
  const { address: owner } = useAccount();

  const { data: allowance, isLoading: loadingAllowance, refetch } = useReadContract({
    address: token,
    abi: Erc20Abi,
    functionName: 'allowance',
    args: owner && spender ? [owner, spender] : undefined,
    query: { enabled: !!token && !!owner && !!spender },
  });

  const needsApproval =
    required !== undefined && required > 0n && (allowance === undefined || (allowance as bigint) < required);

  const { writeContractAsync, isPending: isApproving, data: approveHash } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: approveConfirmed } = useWaitForTransactionReceipt({
    hash: approveHash,
  });

  async function approve() {
    if (!token || !spender || required === undefined) return;
    // Never ask for less than the action in front of us actually needs.
    const amount =
      approveAmount !== undefined && approveAmount > required ? approveAmount : required;
    const hash = await writeContractAsync({
      address: token,
      abi: Erc20Abi,
      // ⚠ PIN THE CHAIN. Without it wagmi hands viem `chain: null` and viem
      // skips `assertCurrentChain`, so this approve broadcasts on whatever
      // chain the wallet is on. See `useWrongNetwork` for the full note.
      chainId: CHAIN_ID,
      functionName: 'approve',
      args: [spender, amount],
    });
    return hash;
  }

  /**
   * Drop the allowance back to zero. This is the `revoke` control fefers puts
   * next to its standing-approval line on the duel page — "approvals are per
   * wallet and per currency", so a player who has approved a run of fights
   * needs a way to take that permission back without leaving the site.
   */
  async function revoke() {
    if (!token || !spender) return;
    return writeContractAsync({
      address: token,
      abi: Erc20Abi,
      chainId: CHAIN_ID,
      functionName: 'approve',
      args: [spender, 0n],
    });
  }

  return {
    allowance: allowance as bigint | undefined,
    needsApproval,
    revoke,
    loadingAllowance,
    approve,
    isApproving: isApproving || isConfirming,
    approveConfirmed,
    refetchAllowance: refetch,
  };
}
