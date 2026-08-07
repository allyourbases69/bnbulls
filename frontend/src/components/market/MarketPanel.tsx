'use client';

import { useReadContract } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatBps } from '@/lib/format';
import { useActiveListings } from '@/lib/hooks/useActiveListings';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { TICKER } from '@/lib/brand';
import { MarketBrowse } from './MarketBrowse';
import { ListBullForm } from './ListBullForm';

/**
 * ⚠ THE FEE IS SPLIT, AND THIS PANEL USED TO CLAIM ALL OF IT WENT TO THE
 * TREASURY. `DECISIONS.md §21`, and the contract: `feeBps = 750` is the whole
 * fee, `jackpotFeeBps = 250` is the slice of it that market-buys BNBULL into
 * the BNBULL pot, and the difference is the protocol fee. So a sale is 92.5%
 * seller / 2.5% pot / 5% treasury, and `/about` has always said so — the two
 * pages disagreed, on the disclosure that matters most.
 *
 * ⚠ AND THE FALLBACK WAS A HARDCODED '5%', SHOWN WHILE THE READ WAS IN FLIGHT.
 * That is the pre-`§21` number, so a slow rpc rendered a fee that has not been
 * true since 2026-08-06. A number nobody can vouch for is worse than no number:
 * every leg below falls back to '…', which is this codebase's "not read yet"
 * marker everywhere else.
 */
export function MarketPanel() {
  const marketAddress = contractAddress('marketplace');
  // Only for "don't offer me a bull I've already listed". The browse half owns
  // its own copy of this hook; both land on the same react-query keys, so the
  // second call is a cache hit and not a second scan.
  const { listedIds } = useActiveListings();

  const { data: feeBps } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'feeBps',
    query: { enabled: !!marketAddress },
  });
  const { data: jackpotFeeBps } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'jackpotFeeBps',
    query: { enabled: !!marketAddress },
  });

  const feePct = feeBps !== undefined ? formatBps(feeBps) : '…';
  const potPct = jackpotFeeBps !== undefined ? formatBps(jackpotFeeBps) : '…';
  // Derived, never typed in, so it cannot drift from the two reads above.
  const devPct =
    feeBps !== undefined && jackpotFeeBps !== undefined
      ? formatBps(Number(feeBps) - Number(jackpotFeeBps))
      : '…';

  if (!marketAddress) {
    /**
     * ⚠ THE FEE IS THE ONE FACT THIS PAGE OWES A READER, so it is stated even
     * with nothing deployed rather than hidden behind the empty panel. Every
     * figure is `DECISIONS.md §21` and the `Marketplace` constructor:
     * `feeBps = 750`, `jackpotFeeBps = 250`, so 92.5 seller / 2.5 pot / 5
     * protocol, under a `MAX_FEE_BPS = 1000` ceiling that is NOT raised.
     * It is labelled as the built-in value, not a live read, because it is.
     */
    return (
      <div>
        <NotDeployed what="the marketplace" />
        <p className="mt-4 max-w-3xl text-sm text-bull-text-dim">
          when it is live: the fee on a sale is <strong className="text-bull-text">7.5%</strong>,
          split three ways. <strong className="text-bull-text">92.5%</strong> to the seller,{' '}
          <strong className="text-bull-text">2.5%</strong> market-buys ${TICKER} into the {TICKER}{' '}
          pot, and <strong className="text-bull-text">5%</strong> is the protocol fee. the fee is
          capped in the contract, so it cannot be raised past that cap by anyone.
        </p>
        <p className="mt-3 max-w-3xl text-xs text-bull-text-faint">
          that is the figure the contract is built with, not a live read, because there is no
          contract to read yet. the panel above replaces this with the on-chain numbers the day
          there is one.
        </p>
      </div>
    );
  }

  return (
    <div>
      <p className="text-sm text-bull-text-dim">
        standard erc-721, approval-based, not escrow. the seller keeps the bull in their
        wallet the whole time. the fee on a sale is {feePct}, and it is split: {potPct}{' '}
        market-buys ${TICKER} into the {TICKER} pot, {devPct} is the protocol fee, and the
        seller keeps everything else. a dead bull can&apos;t be listed, and a listed bull
        can&apos;t be sent into a fight.
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
          on the block
        </h2>
        <div className="mt-4">
          <MarketBrowse />
        </div>
      </section>
    </div>
  );
}
