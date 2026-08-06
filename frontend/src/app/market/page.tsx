import type { Metadata } from 'next';
import { MarketPanel } from '@/components/market/MarketPanel';
import { DEATH } from '@/lib/brand';

/**
 * ⚠ Label is "marketplace", the ROUTE stays `/market` — a url is a shared,
 * linkable thing and renaming it buys nothing. Straight from the fefers
 * precedent.
 */
export const metadata: Metadata = {
  title: 'marketplace',
  description: 'buy, list and unlist bulls. approval based, so the nft never leaves your wallet.',
};

export default function MarketPage() {
  return (
    <div className="mx-auto max-w-4xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">marketplace</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">buy and sell bulls</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        approval based, not escrow, so the nft stays in your wallet the whole time. a listed bull
        is locked out of fights. the dead flag, the loss streak and the revive rung all travel
        with the token, so check {DEATH.label} before you buy one off someone else.
      </p>
      <div className="mt-10">
        <MarketPanel />
      </div>
    </div>
  );
}
