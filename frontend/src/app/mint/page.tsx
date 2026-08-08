import type { Metadata } from 'next';
import Link from 'next/link';
import { MintPanel } from '@/components/mint/MintPanel';
import { JackpotPanel } from '@/components/JackpotPanel';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { CURRENCY, TICKER } from '@/lib/brand';

export const metadata: Metadata = {
  title: 'mint',
  description: `the $10 to $75 bull mint ladder on bnb chain. pay in bnb, or in $${TICKER} at a discount once the curve fills.`,
};

/**
 * Page chrome (nav, pot strip, footer) comes from the root layout, exactly the
 * way fefers does it (`DECISIONS.md §33`) — a page never mounts its own header.
 * The standing pot panels sit under the payment tabs here for the same reason
 * they do on fefers' mint page: this is where the "why does the pot grow"
 * sentence earns its keep.
 */
export default function MintPage() {
  return (
    <div className="mx-auto max-w-3xl px-4 py-8 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">mint</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">bring a bull into the world</h1>
      <p className="mt-3 max-w-xl text-bull-text-dim">
        price climbs by how many have sold, not by token id. every price is a dollar sticker,
        converted to bnb at pay time off a live chainlink feed, and read straight off the
        contract rather than recomputed here. {CURRENCY.discount}
      </p>

      <PreLaunchNotice className="mt-8" />

      <div className="mt-10">
        <MintPanel />
      </div>

      <div className="mt-12">
        <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          where the money goes
        </p>
        {/* ⚠ THE QUALIFIER IS LOAD-BEARING, NOT PADDING. This used to read
            "20% of every mint buys $BNBULL into one pot and 10% goes to the
            other. neither has a withdraw function, for anybody." Both halves
            are true of the POTS and neither is true of the 20% at launch:
            `DECISIONS.md §29` says BNBULL cannot be bought while the four.meme
            curve is filling, so that leg DEFERS into a pending bucket on
            MintDrop, and `§45` is explicit that money in a bucket has not
            reached a pot and IS recoverable (`withdrawPendingForManualBuy` is
            onlyOwner and un-timelocked). `/about` has carried the honest
            version all along; this is the page where somebody is about to
            spend, so it cannot carry the stronger one. The no-withdraw
            guarantee starts AT THE POT, and saying where the line is beats
            letting a sceptic find it in the source. */}
        <p className="mt-2 max-w-xl text-sm text-bull-text-dim">
          30% of every mint lands in the pots. pay bnb and 20% buys ${TICKER} for one pot while
          10% goes to the other. pay ${TICKER} and the whole 30% stays ${TICKER}, never sold.
          once money reaches a pot it can never come back out, for us or for anyone.
        </p>
        <p className="mt-2 max-w-xl text-sm text-bull-text-faint">
          the one gap, while the curve is still filling: ${TICKER} cannot be bought yet, so the $
          {TICKER} buy leg waits in a holding bucket on the mint contract instead, and money in
          that bucket has not reached a pot yet. the bnb leg has no such gap. the long version is
          on{' '}
          <Link href="/about" className="text-bull-gold hover:underline">
            how to play
          </Link>
          .
        </p>
        <div className="mt-4 grid gap-4 empty:hidden sm:grid-cols-2">
          <JackpotPanel pot="bnbull" />
          <JackpotPanel pot="bnb" />
        </div>
      </div>
    </div>
  );
}
