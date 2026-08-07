'use client';

import { useMemo } from 'react';
import { useReadContract } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { KING_ID } from '@/lib/art/bull';

/**
 * WHICH TOKEN IDS ACTUALLY EXIST ON CHAIN. One definition, shared by every
 * surface that lists bulls, so "minted" can never mean two different things on
 * two different pages.
 *
 * `Bulls` is a plain ERC-721 with no `Enumerable` extension and no
 * `totalSupply`, so the only honest source is `nextTokenId` (pre-incremented,
 * starts at 1, so minted ids are `1 .. nextTokenId - 1`) plus `kingMinted`,
 * because #501 sits outside `MAX_SUPPLY` and is minted by its own function.
 *
 * ⚠ WHAT THIS IS AND IS NOT. This is what makes the browse page show only
 * bulls that exist. It is a UI rule, NOT a cryptographic one: the rarity table
 * is derived from a PUBLIC `masterSeed` and committed on chain as
 * `initialRarityHash` (`DECISIONS.md §27`), and the same shuffle is ported into
 * `lib/art/bull.ts`, which ships to the browser. Anyone can therefore compute
 * every unminted bull's tier, weapon, name and sprite off chain, today. Nothing
 * here should ever claim otherwise in code or in copy.
 *
 * ── THE THREE STATES ARE DISTINCT, and only one of them is allowed to say
 * "nothing has been minted":
 *
 *   isLoading    → the reads are in flight, say nothing
 *   unavailable  → they settled with no answer, say THAT and offer a retry
 *   count === 0  → `nextTokenId` was actually read and it is 1
 *
 * Collapsing the middle one renders an empty collection against an unreachable
 * RPC, which is the same failure the mint page's sold-out split exists to stop.
 */
export interface MintedBulls {
  /** Minted token ids, ascending, king last. */
  readonly ids: readonly number[];
  readonly count: number;
  /** False when no `Bulls` address is configured for this build. */
  readonly deployed: boolean;
  readonly isLoading: boolean;
  /** Reads settled with no answer. NOT the same as "nothing minted". */
  readonly unavailable: boolean;
  readonly refetch: () => void;
}

export function useMintedBulls(): MintedBulls {
  const bullsAddress = contractAddress('bullsNft');

  const {
    data: nextTokenId,
    isLoading: loadingNext,
    refetch: refetchNext,
  } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'nextTokenId',
    query: { enabled: !!bullsAddress, refetchInterval: 30_000 },
  });

  const {
    data: kingMinted,
    isLoading: loadingKing,
    refetch: refetchKing,
  } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'kingMinted',
    query: { enabled: !!bullsAddress, refetchInterval: 30_000 },
  });

  const ids = useMemo(() => {
    if (nextTokenId === undefined) return [];
    const upTo = Number(nextTokenId) - 1;
    const out = Array.from({ length: Math.max(0, upTo) }, (_, i) => i + 1);
    if (kingMinted === true) out.push(KING_ID);
    return out;
  }, [nextTokenId, kingMinted]);

  const isLoading = !!bullsAddress && (loadingNext || loadingKing);
  const unavailable =
    !!bullsAddress && !isLoading && (nextTokenId === undefined || kingMinted === undefined);

  return {
    ids,
    count: ids.length,
    deployed: !!bullsAddress,
    isLoading,
    unavailable,
    refetch: () => {
      void refetchNext();
      void refetchKing();
    },
  };
}
