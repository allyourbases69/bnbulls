'use client';

import { useReadContract } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatBps } from '@/lib/format';
import { useActiveListings } from '@/lib/hooks/useActiveListings';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { ListingCard } from './ListingCard';
import { ListBullForm } from './ListBullForm';

export function MarketPanel() {
  const marketAddress = contractAddress('marketplace');
  const { listedIds, isLoading, incomplete } = useActiveListings();

  const { data: feeBps } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'feeBps',
    query: { enabled: !!marketAddress },
  });

  if (!marketAddress) {
    return <NotDeployed what="the marketplace" />;
  }

  return (
    <div>
      <p className="text-sm text-bull-text-dim">
        standard erc-721, approval-based, not escrow. the seller keeps the bull in their
        wallet the whole time. {feeBps !== undefined ? formatBps(feeBps) : '5%'} goes to the
        treasury on a sale, the rest to the seller. a dead bull can&apos;t be listed, and a
        listed bull can&apos;t be sent into a fight.
      </p>

      <section className="mt-8">
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          list one of yours
        </h2>
        <div className="mt-3">
          <ListBullForm listedIds={listedIds} />
        </div>
      </section>

      <section className="mt-10">
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          listings
        </h2>
        {isLoading ? (
          <p className="mt-3 text-sm text-bull-text-dim">loading listings…</p>
        ) : listedIds.length === 0 ? (
          <p className="mt-3 text-sm text-bull-text-dim">nothing listed yet.</p>
        ) : (
          <>
            {incomplete && (
              <p className="mt-2 text-xs text-bull-text-faint">
                this list is built from event history and may not cover the full lifetime of
                the game yet. set a deploy block to widen the scan.
              </p>
            )}
            <div className="mt-4 grid gap-4 sm:grid-cols-2">
              {listedIds.map((id) => (
                <ListingCard key={id} tokenId={id} />
              ))}
            </div>
          </>
        )}
      </section>
    </div>
  );
}
