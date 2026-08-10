'use client';

import { useCallback, useMemo } from 'react';
import { useReadContract } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { KING_ID } from '@/lib/art/bull';
import { usePen } from './usePen';

/**
 * WHICH TOKEN IDS ARE ACTUALLY IN CIRCULATION. One definition, shared by every
 * surface that lists bulls, so "minted" can never mean two different things on
 * two different pages.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ "THE TOKEN EXISTS" AND "SOMEBODY BOUGHT IT" ARE NO LONGER THE SAME FACT.
 *   THIS COMMENT USED TO SAY `nextTokenId` WAS THE ONLY HONEST SOURCE. THAT
 *   WAS TRUE FOR EXACTLY AS LONG AS BULLS WERE MINTED ONE PER SALE.
 * ═══════════════════════════════════════════════════════════════════════════
 * `contracts/BullPen.sol` is stocked by TRANSFER — the owner mints the entire
 * remaining supply straight to the pen, and the pen deals ids out at random as
 * people buy. That is what stops the snipe (`Bulls._initializeRarity` shuffles
 * from a PUBLIC `masterSeed`, so anybody can compute which ids are legendary
 * and watch the counter), and it costs `Bulls.sol` nothing: every id keeps the
 * rarity it already has, and `initialRarityHash` is untouched.
 *
 * What it does cost is this hook's old premise. After the pre-mint,
 * `nextTokenId()` reads 501 while several hundred of those bulls have never
 * been sold. `nextTokenId` alone would therefore report a sold-out collection
 * on day one, fill the browse grid with bulls nobody owns, and offer the pen
 * contract as a duel opponent.
 *
 * So the definition is now:
 *
 *   existingIds    = 1 .. nextTokenId-1, plus #501 when `kingMinted`
 *   penHeldIds     = `BullPen.poolIds()` when the pen is wired, else empty
 *   circulatingIds = existingIds MINUS penHeldIds   ← THIS is `ids` below
 *
 * `nextTokenId` is still the source for what EXISTS — that has not changed, and
 * `Bulls` still has no `Enumerable` extension and no `totalSupply` to ask
 * instead. It is simply no longer the whole answer.
 *
 * ⚠ WHAT THIS IS AND IS NOT. This is what makes the browse page show only
 * bulls that somebody actually holds. It is a UI rule, NOT a cryptographic one:
 * the rarity table is derived from a PUBLIC `masterSeed` and committed on chain
 * as `initialRarityHash` (`DECISIONS.md §27`), and the same shuffle is ported
 * into `lib/art/bull.ts`, which ships to the browser. Anyone can therefore
 * compute every unsold bull's tier, weapon, name and sprite off chain, today —
 * and `poolIds()` publishes the unsold SET deliberately, because knowing what
 * is left tells you the odds and is the honest thing to publish. What nobody
 * can compute is WHICH one they will be dealt, because that is decided by a
 * seed that does not exist when they pay. Nothing here should ever claim
 * otherwise in code or in copy.
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
 *
 * ⚠ AND THE PEN'S OWN READ IS FOLDED INTO `unavailable` FOR A SHARPER REASON
 * THAN TIDINESS. If `poolIds()` does not answer, subtracting nothing does not
 * degrade gracefully — it publishes several hundred unsold bulls as owned. An
 * unread pen is "we do not know who holds what", never "the pen holds nothing".
 */
export interface MintedBulls {
  /** Token ids in circulation, ascending, king last. Excludes anything the
   *  pen is still holding. */
  readonly ids: readonly number[];
  readonly count: number;
  /** Every id that EXISTS on chain, pen-held ones included. Almost nothing
   *  wants this — it is here for the one surface that has to tell "this token
   *  was never minted" apart from "this token is minted and unsold". */
  readonly existingIds: readonly number[];
  /** False when no `Bulls` address is configured for this build. */
  readonly deployed: boolean;
  readonly isLoading: boolean;
  /** Reads settled with no answer. NOT the same as "nothing minted". */
  readonly unavailable: boolean;
  readonly refetch: () => void;
}

export function useMintedBulls(): MintedBulls {
  const bullsAddress = contractAddress('bullsNft');
  const pen = usePen();

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

  const existingIds = useMemo(() => {
    if (nextTokenId === undefined) return [];
    const upTo = Number(nextTokenId) - 1;
    const out = Array.from({ length: Math.max(0, upTo) }, (_, i) => i + 1);
    if (kingMinted === true) out.push(KING_ID);
    return out;
  }, [nextTokenId, kingMinted]);

  const ids = useMemo(() => {
    // ⚠ `heldIds` is empty on the legacy path AND while the pen read is in
    // flight, so this is a no-op filter in both — the array identity is what
    // matters downstream (`useRanks` memoises on it), not the branch.
    if (pen.heldIds.size === 0) return existingIds;
    return existingIds.filter((id) => !pen.heldIds.has(id));
  }, [existingIds, pen.heldIds]);

  const isLoading = !!bullsAddress && (loadingNext || loadingKing || pen.loading);
  const unavailable =
    !!bullsAddress &&
    !isLoading &&
    (nextTokenId === undefined || kingMinted === undefined || pen.unavailable);

  // ⚠ STABLE IDENTITY. Callers put this straight into `useCallback` deps and
  // into effects (`useActiveListings.refetch`, the market browse retry), so a
  // fresh arrow every render would give them a fresh identity every render and
  // an effect that re-runs forever. The wagmi refetchers are stable; `penRefetch`
  // is pulled out of the object for the same reason.
  const penRefetch = pen.refetch;
  const refetch = useCallback(() => {
    void refetchNext();
    void refetchKing();
    penRefetch();
  }, [refetchNext, refetchKing, penRefetch]);

  return {
    ids,
    count: ids.length,
    existingIds,
    deployed: !!bullsAddress,
    isLoading,
    unavailable,
    refetch,
  };
}
