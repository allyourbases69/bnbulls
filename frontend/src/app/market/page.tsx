import type { Metadata } from 'next';
import { MarketPanel } from '@/components/market/MarketPanel';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { DEATH, PIT } from '@/lib/brand';

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
    // `max-w-7xl px-4 md:px-8` is fighting fefers' own market container, and
    // the card grid below is ported to its 2/3/4/5/6 column ladder — the two
    // have to agree or the widest breakpoint has nothing to fill.
    <div className="mx-auto max-w-7xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">marketplace</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">buy and sell bulls</h1>
      <p className="mt-3 max-w-2xl text-bull-text-dim">
        approval based, not escrow, so the nft stays in your wallet the whole time. a listed bull
        is locked out of fights. the dead flag, the loss streak and the revive rung all travel
        with the token, so check {DEATH.label} before you buy one off someone else.
      </p>
      {/* ⚠ THE ONE THING THAT DOES **NOT** TRAVEL WITH THE TOKEN, and it has
          already cost us a debugging session: `Yards` membership is stored
          against the wallet that entered the bull, so a sale voids it silently.
          A buyer who is not told this owns a bull that looks fightable, cannot
          be matched, and reverts `BullNotInYards` if anybody tries. It belongs
          on the page where the buying happens, not only on the duel page. */}
      <p className="mt-2 max-w-2xl text-sm text-bull-text-faint">{PIT.saleVoidsEntry}</p>
      <PreLaunchNotice className="mt-8 max-w-3xl" />

      <div className="mt-10">
        <MarketPanel />
      </div>
    </div>
  );
}
