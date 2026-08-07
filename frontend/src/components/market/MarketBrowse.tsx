'use client';

/**
 * /market browsing — a port of fighting fefers' `app/market/page.tsx`.
 *
 * Data, as fefers states it: "listings … full roster … Join the two
 * client-side so we can render rich cards (art, rarity, weapon, record)
 * alongside the listing price." Same join here — `useActiveListings` for the
 * listings and their terms, `getBull(id)` for the art/tier/name/weapon, and
 * one batched `Bulls.getBull` for the fight records.
 *
 * ⚠ THE ROSTER LEG IS NARROWER THAN FEFERS' AND STRICTLY BETTER FOR IT.
 * `useAllOutlaws` reads the whole collection off chain because fefers' art,
 * name and rarity all come off chain state. Here the tier, name, weapon and
 * sprite are PURE — `chainBandMap()` is a port of `Bulls._initializeRarity()`
 * and `assignNames()` deals against it, pinned by `npm run verify:rarity`
 * (`DECISIONS.md §27`) — so they cost no rpc at all and the rarity filter keeps
 * working even when the chain is unreachable. The only thing that needs a read
 * is the record, and that is fetched for the LISTED ids rather than all 501.
 *
 * Three fefers states have no bnbulls counterpart and are absent rather than
 * faked:
 *   - the "reading listings straight off the chain" degraded banner — fefers
 *     has a Postgres listings cache with a chain fallback. bnbulls has no
 *     cache; the chain is the only source, so there is no degraded mode.
 *   - the `incomplete` banner — that existed because the listing set came from
 *     a bounded log scan. `useActiveListings` no longer scans logs at all, so
 *     the set is complete by construction and there is nothing to disclose.
 *   - `BabyMarketSection` — phase 2 calves (`DECISIONS.md §24`) are not built.
 */
import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContracts } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { getBull } from '@/lib/art/collection';
import { BANDS, type Band, type Token } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import { useActiveListings, type ActiveListing } from '@/lib/hooks/useActiveListings';
import { ListingCard } from './ListingCard';
import { decodeBull, type BullRecord } from './bullRecord';

/** Fefers: `type RarityFilter = 'all' | RarityTier`. bnbulls' `Band` has no
 *  king member — #501 is a legendary-band token flagged `king` — so the 1/1
 *  gets its own filter value, exactly as `BullsGrid` already does on /bulls. */
type RarityFilter = 'all' | Band | 'king';
/** Fefers, verbatim. */
type SortKey = 'price-asc' | 'price-desc' | 'newest' | 'oldest';

interface JoinedListing {
  listing: ActiveListing;
  token: Token;
  record: BullRecord | null;
}

export function MarketBrowse() {
  const bullsAddress = contractAddress('bullsNft');
  const { address } = useAccount();
  const { listings, isLoading, error, refetch } = useActiveListings();

  const [rarityFilter, setRarityFilter] = useState<RarityFilter>('all');
  const [sortKey, setSortKey] = useState<SortKey>('newest');
  const [onlyMine, setOnlyMine] = useState(false);

  // One multicall for every record on the board, not one read per card.
  const { data: recordData, status: recordsStatus } = useReadContracts({
    contracts: listings.map((l) => ({
      address: bullsAddress ?? undefined,
      abi: BullsAbi,
      functionName: 'getBull' as const,
      args: [BigInt(l.tokenId)] as const,
    })),
    query: { enabled: !!bullsAddress && listings.length > 0 },
  });

  const joined: JoinedListing[] = useMemo(
    () =>
      listings.map((listing, i) => ({
        listing,
        token: getBull(listing.tokenId),
        record: decodeBull(recordData?.[i]),
      })),
    [listings, recordData],
  );

  const lowerAddr = address?.toLowerCase() ?? null;

  const filtered = useMemo(() => {
    // Fefers, ported with its reasoning intact: "Dead bulls can't be played, so
    // we hide them from the marketplace. The contract still allows the listing
    // to exist, but a buyer would only be acquiring a corpse."
    // ⚠ On bnbulls this should be unreachable, not merely unhelpful:
    // `Marketplace.list` reverts `BullIsDead` (Marketplace.sol:682) and `Duel`
    // refuses a fight for a listed bull, so a listed bull cannot die. Kept as
    // the same belt-and-braces fefers ships, since `blocksDeadListings` is a
    // settable flag rather than a hard rule.
    let out = joined.filter((j) => !j.record?.isDead);
    if (rarityFilter === 'king') {
      out = out.filter((j) => j.token.king);
    } else if (rarityFilter !== 'all') {
      out = out.filter((j) => !j.token.king && j.token.band === rarityFilter);
    }
    if (onlyMine && lowerAddr) {
      out = out.filter((j) => j.listing.seller.toLowerCase() === lowerAddr);
    }
    return [...out].sort((a, b) => {
      switch (sortKey) {
        // usdPrice is a bigint on one fixed 1e18 scale for every listing, so
        // comparing them directly is exact — no Number() rounding.
        case 'price-asc':
          return a.listing.usdPrice < b.listing.usdPrice ? -1 : 1;
        case 'price-desc':
          return a.listing.usdPrice > b.listing.usdPrice ? -1 : 1;
        case 'newest':
          return b.listing.listedAt - a.listing.listedAt;
        case 'oldest':
          return a.listing.listedAt - b.listing.listedAt;
      }
    });
  }, [joined, rarityFilter, onlyMine, lowerAddr, sortKey]);

  // ⚠ A read that has SETTLED with nothing is a different state from one still
  // in flight: the first renders a dash, the second renders "…". This is
  // fefers' `rosterFailed` prop and it exists for the same reason — without it
  // every card's art box says "loading…" forever.
  const recordsFailed = listings.length > 0 && (!bullsAddress || recordsStatus === 'error');

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 border-b border-bull-border pb-4 md:flex-row md:items-end md:justify-between">
        <p className="max-w-2xl text-sm text-bull-text-dim">
          every bull on sale right now. filter by tier, sort by price or age, and click
          through to the bull&apos;s own page for the full trait list.
        </p>
        <div className="text-left font-mono text-sm text-bull-text-dim md:text-right">
          {!isLoading && !error && (
            <div>
              <span className="text-bull-gold">{listings.length}</span> active listing
              {listings.length === 1 ? '' : 's'}
            </div>
          )}
        </div>
      </div>

      {/* Controls */}
      <div className="flex flex-wrap items-center gap-2">
        <FilterTab active={rarityFilter === 'all'} onClick={() => setRarityFilter('all')}>
          all
        </FilterTab>
        {BANDS.map((b) => (
          <FilterTab key={b} active={rarityFilter === b} onClick={() => setRarityFilter(b)}>
            <span className={rarityFilter === b ? undefined : TIER_COLOUR[b]}>{b}</span>
          </FilterTab>
        ))}
        <FilterTab active={rarityFilter === 'king'} onClick={() => setRarityFilter('king')}>
          <span className={rarityFilter === 'king' ? undefined : 'text-bull-gold'}>king</span>
        </FilterTab>
        <div className="mx-1 hidden h-6 w-px bg-bull-border md:block" />
        <FilterTab active={onlyMine} onClick={() => setOnlyMine((v) => !v)} disabled={!address}>
          my listings
        </FilterTab>
        <div className="grow" />
        <label className="bull-header flex items-center gap-2 text-xs text-bull-text-faint">
          sort
          <select
            className="min-h-[2.75rem] border-2 border-bull-border bg-bull-bg px-2 py-2 font-mono text-sm text-bull-text focus:border-bull-gold focus:outline-none"
            value={sortKey}
            onChange={(e) => setSortKey(e.target.value as SortKey)}
          >
            <option value="newest">newest</option>
            <option value="oldest">oldest</option>
            <option value="price-asc">price (low→high)</option>
            <option value="price-desc">price (high→low)</option>
          </select>
        </label>
      </div>

      {/* ── couldn't load ──────────────────────────────────────────────
          The chain refused. An empty grid here would be a lie, so say nothing
          was loaded and let the seller retry. */}
      {error && (
        <div className="rounded border border-bull-red bg-bull-panel p-6">
          <h3 className="bull-header mb-2 text-sm text-bull-red">couldn&apos;t load listings</h3>
          <p className="mb-2 text-sm text-bull-text-dim">
            this is not an empty marketplace, we couldn&apos;t reach the chain. anything you
            have listed is still live on it.
          </p>
          <p className="mb-4 break-words font-mono text-sm text-bull-text-faint">
            {error.message}
          </p>
          <button type="button" className="bull-btn bull-btn-secondary" onClick={refetch}>
            retry
          </button>
        </div>
      )}

      {/* ── the listings loaded, the records didn't ────────────────────
          Prices, sellers and buy buttons all come off the listing itself, so
          the market still WORKS here — it is the ratings and records that are
          missing, because those come from a second read against the same rpc.
          Say which half is missing rather than leaving every card quietly stuck
          on "…". */}
      {!error && recordsFailed && filtered.length > 0 && (
        <div className="rounded border border-bull-gold bg-bull-panel p-4">
          <div className="bull-header mb-1 text-xs text-bull-gold">
            listings loaded, bull records didn&apos;t
          </div>
          <p className="text-sm text-bull-text-dim">
            the prices below are real and you can still buy. the ratings and fight records
            need a second read off the chain and that one didn&apos;t come back.
          </p>
          <button type="button" className="bull-btn bull-btn-secondary mt-3" onClick={refetch}>
            retry
          </button>
        </div>
      )}

      {isLoading && !error && (
        <div className="bull-header py-12 text-center text-sm text-bull-text-dim">
          loading the marketplace…
        </div>
      )}

      {!isLoading && !error && filtered.length === 0 && (
        <div className="space-y-3 rounded border border-bull-border bg-bull-panel p-8 text-center">
          <div className="bull-header text-sm text-bull-text-dim">
            nothing on the block right now.
          </div>
          <p className="text-sm text-bull-text-faint">
            {listings.length > 0
              ? 'nothing listed matches that filter.'
              : 'own a bull you want to sell? pick it out up there and set a price.'}
          </p>
          <div className="flex flex-wrap items-center justify-center gap-2">
            {listings.length > 0 ? (
              <button
                type="button"
                className="bull-btn bull-btn-secondary"
                onClick={() => {
                  setRarityFilter('all');
                  setOnlyMine(false);
                }}
              >
                clear the filters
              </button>
            ) : (
              <Link href="/bulls" className="bull-btn bull-btn-secondary">
                browse the herd
              </Link>
            )}
            <button type="button" className="bull-btn bull-btn-secondary" onClick={refetch}>
              retry
            </button>
          </div>
        </div>
      )}

      {!isLoading && !error && filtered.length > 0 && (
        // Fefers' grid, ported: 2 up on a phone, 6 across on a wide screen.
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
          {filtered.map((j) => (
            <ListingCard
              key={j.listing.tokenId}
              listing={j.listing}
              token={j.token}
              record={j.record}
              recordFailed={recordsFailed}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/** Fefers' `FilterTab`, ported. `min-h-[2.75rem]` is the 44px tap floor and is
 *  not negotiable on a phone — same rule `.bull-btn` already follows. */
function FilterTab({
  active,
  onClick,
  disabled,
  children,
}: {
  active: boolean;
  onClick: () => void;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  const base =
    'bull-header min-h-[2.75rem] border-2 px-2 py-2 text-xs transition-colors md:px-3 md:py-1.5';
  let cls: string;
  if (disabled) {
    cls = `${base} cursor-not-allowed border-bull-border text-bull-text-faint`;
  } else if (active) {
    cls = `${base} border-bull-gold text-bull-gold`;
  } else {
    cls = `${base} border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-text`;
  }
  return (
    <button type="button" className={cls} disabled={disabled} onClick={onClick}>
      {children}
    </button>
  );
}
