'use client';

import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { Erc20Abi } from '@/lib/abi';

/**
 * Shared allowance check + approve flow for the three surfaces that need it
 * (mint, graveyard revives, marketplace buys/lists — every stablecoin/BNBULL
 * payment leg here is approval-based, never escrow-based).
 */
export function useErc20Approval(
  token: `0x${string}` | undefined,
  spender: `0x${string}` | undefined,
  required: bigint | undefined,
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
    const hash = await writeContractAsync({
      address: token,
      abi: Erc20Abi,
      functionName: 'approve',
      args: [spender, required],
    });
    return hash;
  }

  return {
    allowance: allowance as bigint | undefined,
    needsApproval,
    loadingAllowance,
    approve,
    isApproving: isApproving || isConfirming,
    approveConfirmed,
    refetchAllowance: refetch,
  };
}
