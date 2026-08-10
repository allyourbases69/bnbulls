'use client';

import { useCallback, useMemo } from 'react';
import { useReadContracts } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useMintedBulls } from './useMintedBulls';

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

/** One live listing, flattened out of `Marketplace.Listing`. */
export interface ActiveListing {
  tokenId: number;
  seller: `0x${string}`;
  /** `Listing.listedAt`, unix seconds. Sorts newest/oldest. */
  listedAt: number;
  /** `Marketplace.BnbullMode`: 0 off, 1 pegged, 2 fixed. */
  bnbullMode: number;
  /**
   * ⚠ The seller's dollar sticker at the protocol's fixed 1e18 scale — NOT a
   * token's `decimals()`. Format it with `formatUsd1e18`. Sorting on it is
   * exact because every listing shares the one scale.
   */
  usdPrice: bigint;
  bnbullPrice: bigint;
}

interface RawListing {
  seller: `0x${string}`;
  listedAt: bigint;
  bnbullMode: number;
  usdPrice: bigint;
  bnbullPrice: bigint;
}

/**
 * Every listing currently live on the marketplace, with its terms.
 *
 * ⚠ THIS DOES NOT USE `getLogs`, AND THAT IS THE PORT. It used to scan
 * `Listed` events for candidate ids and re-check each one — which meant the
 * market was only ever as complete as a bounded, chunk-capped block scan, and
 * a listing older than the window was INVISIBLE with nothing but an
 * `incomplete` footnote to admit it. Fighting fefers hit this and wrote the
 * conclusion down in `useMarketListings.ts`: "neither leg trusts getLogs for
 * state … it does not call getLogs. `listingOf` is a plain mapping read that
 * returns the CURRENT listing, so one batched multicall over the roster
 * answers the question exactly, with no block range to breach, no event
 * replay, and no chance of a missed Unlisted event leaving a ghost."
 *
 * That applies here without modification: `Bulls` is a fixed 501-token
 * collection, `Marketplace._listings` is a plain mapping, and wagmi folds the
 * reads into a handful of multicall3 aggregates. So the answer is now complete
 * by construction and there is no "this might not be every listing" caveat to
 * render, because there is no window to fall outside of.
 *
 * ⚠ `Marketplace.isListed` is not called either, and that is not a weakening:
 * it is literally `_listings[tokenId].seller != address(0)` (`Marketplace.sol`
 * line 523), so reading the struct answers the same question AND hands back
 * the price, the seller and the timestamp in the same batch. The browse grid
 * cannot sort or filter on a price no component above the card has seen.
 *
 * ⚠ THE MINTED-ID WALK USED TO BE DUPLICATED FROM `useMyBulls` AND IS NOW
 * SHARED. The old note here said "worth collapsing later; both derive ids the
 * same way, from `nextTokenId` and `kingMinted`" — and `BullPen` is what made
 * "later" arrive. The pen holds several hundred MINTED, UNSOLD bulls, so
 * `nextTokenId` on its own now over-counts by exactly the pen's holdings, and
 * three separate copies of that walk meant three places to get it wrong. They
 * all read `useMintedBulls` now, which subtracts `poolIds()`.
 *
 * That also removes 469 dead entries from this multicall: nothing the pen holds
 * can be listed, because a listing needs an owner who approved the marketplace,
 * and the pen never does either.
 */
export function useActiveListings() {
  const marketAddress = contractAddress('marketplace');
  const minted = useMintedBulls();
  const mintedIds = minted.ids;

  const {
    data: listingData,
    isLoading: loadingListings,
    error: listingsError,
    refetch: refetchListings,
  } = useReadContracts({
    contracts: mintedIds.map((id) => ({
      address: marketAddress ?? undefined,
      abi: MarketplaceAbi,
      functionName: 'listingOf' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: !!marketAddress && mintedIds.length > 0 },
  });

  const listings = useMemo<ActiveListing[]>(() => {
    if (!listingData) return [];
    const out: ActiveListing[] = [];
    mintedIds.forEach((id, i) => {
      const entry = listingData[i];
      if (entry?.status !== 'success') return;
      const l = entry.result as unknown as RawListing | undefined;
      // seller == 0 is the contract's own definition of "not listed".
      if (!l || !l.seller || l.seller === ZERO_ADDR) return;
      out.push({
        tokenId: id,
        seller: l.seller,
        listedAt: Number(l.listedAt),
        bnbullMode: Number(l.bnbullMode),
        usdPrice: BigInt(l.usdPrice),
        bnbullPrice: BigInt(l.bnbullPrice),
      });
    });
    return out;
  }, [listingData, mintedIds]);

  const listedIds = useMemo(() => listings.map((l) => l.tokenId), [listings]);

  // ⚠ AN EMPTY GRID MUST NOT BE ABLE TO MEAN "THE RPC REFUSED".
  // `useReadContracts` only sets a top-level `error` when the whole call
  // fails; a per-call revert lands as `status: 'failure'` on that entry. If we
  // know tokens are minted and could not read a single one of them back, that
  // is a failure to load, not an empty marketplace — say so. Same reasoning as
  // fefers' `listingsError`: "a seller who lists, sees 'nothing on the block
  // right now', and concludes the transaction failed is a much worse outcome
  // than a slow page."
  const allReadsFailed =
    mintedIds.length > 0 &&
    !!listingData &&
    listingData.length > 0 &&
    listingData.every((r) => r?.status === 'failure');

  // ⚠ The roster read failing is the same class of problem as the listings read
  // failing, so it lands in the same place. `useMintedBulls.unavailable` covers
  // `nextTokenId`, `kingMinted` AND the pen's `poolIds()` — and an unread pen
  // matters here for a reason of its own: it would put several hundred unsold
  // bulls back into the `listingOf` batch, which is slow rather than wrong, but
  // an empty market rendered off a half-read roster is neither.
  const rosterError = minted.unavailable
    ? new Error('the herd could not be read off the chain, so the market has nothing to check')
    : null;

  const error =
    rosterError ??
    (listingsError as Error | null) ??
    (allReadsFailed ? new Error('the listings read came back empty-handed on every token') : null);

  const mintedRefetch = minted.refetch;
  const refetch = useCallback(() => {
    mintedRefetch();
    void refetchListings();
  }, [mintedRefetch, refetchListings]);

  return {
    listings,
    listedIds,
    isLoading:
      !!marketAddress && (minted.isLoading || (mintedIds.length > 0 && loadingListings)),
    error,
    refetch,
    deployed: !!marketAddress,
  };
}
