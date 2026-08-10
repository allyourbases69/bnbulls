'use client';

import { useMemo } from 'react';
import { useAccount, useReadContracts } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useMintedBulls } from './useMintedBulls';

/**
 * Every bull the connected wallet currently owns.
 *
 * `Bulls` is a plain ERC-721 (`Bulls.sol`: no `Enumerable` extension — no
 * `tokenOfOwnerByIndex`, no `totalSupply`), so there is no on-chain call that
 * lists "tokens owned by X" directly, and this app has no indexer or subgraph
 * behind it. With a fixed 501-token ceiling the honest, dependency-free
 * approach is to read `ownerOf` for every circulating id and filter
 * client-side — `useReadContracts` batches that into a handful of multicall3
 * aggregate calls (chain.ts wires multicall3 for chain 56), not 501 round
 * trips. This does NOT scale past a small fixed collection; a bigger or
 * growing collection would need a real indexer instead.
 *
 * ⚠ THE MINTED-ID WALK IS NO LONGER HAND-ROLLED HERE, AND THAT IS A CORRECTNESS
 * FIX RATHER THAN A TIDY-UP. This hook used to derive ids from `nextTokenId` +
 * `kingMinted` itself, which was an exact copy of `useMintedBulls` — fine while
 * the two agreed, and silently wrong the moment `BullPen` landed, because the
 * pen holds several hundred MINTED, UNSOLD bulls that `nextTokenId` counts and
 * nobody owns. The copy here would have kept asking `ownerOf` for all of them:
 * 469 wasted multicall entries per load, every one of them answering with the
 * pen's own address. Sharing the definition means there is one place that can
 * be wrong, and it is the place that documents itself.
 */
export function useMyBulls() {
  const { address } = useAccount();
  const bullsAddress = contractAddress('bullsNft');
  const minted = useMintedBulls();
  const ids = minted.ids;

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
      if (owner && owner.toLowerCase() === lower) out.push(ids[i]!);
    });
    return out;
  }, [owners, ids, address]);

  return {
    myIds,
    isLoading: !bullsAddress ? false : minted.isLoading || (ids.length > 0 && loadingOwners),
    deployed: !!bullsAddress,
  };
}
