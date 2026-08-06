'use client';

import { useMemo } from 'react';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';

/**
 * Every bull the connected wallet currently owns.
 *
 * `Bulls` is a plain ERC-721 (`Bulls.sol`: no `Enumerable` extension — no
 * `tokenOfOwnerByIndex`, no `totalSupply`), so there is no on-chain call that
 * lists "tokens owned by X" directly, and this app has no indexer or subgraph
 * behind it. With a fixed 501-token ceiling the honest, dependency-free
 * approach is to read `ownerOf` for every minted id and filter client-side —
 * `useReadContracts` batches that into a handful of multicall3 aggregate
 * calls (chain.ts wires multicall3 for chain 56), not 501 round trips. This
 * does NOT scale past a small fixed collection; a bigger or growing
 * collection would need a real indexer instead.
 */
export function useMyBulls() {
  const { address } = useAccount();
  const bullsAddress = contractAddress('bullsNft');

  const { data: nextTokenId, isLoading: loadingNext } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'nextTokenId',
    query: { enabled: !!bullsAddress },
  });
  const { data: kingMinted, isLoading: loadingKing } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'kingMinted',
    query: { enabled: !!bullsAddress },
  });

  // Minted ids run 1..nextTokenId-1 (nextTokenId starts at 1, pre-incremented
  // on mint), plus #501 the king iff it has been minted.
  const ids = useMemo(() => {
    const upTo = nextTokenId !== undefined ? Number(nextTokenId) - 1 : 0;
    const out = Array.from({ length: Math.max(0, upTo) }, (_, i) => i + 1);
    if (kingMinted) out.push(501);
    return out;
  }, [nextTokenId, kingMinted]);

  const { data: owners, isLoading: loadingOwners } = useReadContracts({
    contracts: ids.map((id) => ({
      address: bullsAddress ?? undefined,
      abi: BullsAbi,
      functionName: 'ownerOf' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: !!bullsAddress && !!address && ids.length > 0 },
  });

  const myIds = useMemo(() => {
    if (!owners || !address) return [];
    const lower = address.toLowerCase();
    const out: number[] = [];
    owners.forEach((r, i) => {
      const owner = r.status === 'success' ? (r.result as `0x${string}`) : undefined;
      if (owner && owner.toLowerCase() === lower) out.push(ids[i]);
    });
    return out;
  }, [owners, ids, address]);

  return {
    myIds,
    isLoading: !bullsAddress ? false : loadingNext || loadingKing || loadingOwners,
    deployed: !!bullsAddress,
  };
}
