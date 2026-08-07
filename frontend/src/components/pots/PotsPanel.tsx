import { PotCard } from './PotCard';
import { POTS } from '@/lib/brand';
import { contractsDeployed } from '@/lib/env';

export function PotsPanel() {
  /* ⚠ "every row above is …" NEEDS ROWS ABOVE IT, AND PRE-LAUNCH THERE ARE
     NONE. The award list that clause points at lives inside `PotCard`, and
     with no address both cards are replaced by `NotDeployed` - so on the live
     site the sentence pointed at two "not live yet" boxes. A confident
     sentence referring to something that is not on the page is exactly what
     makes a deliberate pre-launch state read as a half-finished one, which is
     the one thing `PreLaunchNotice` exists to prevent. Only the clause that
     needs rows is gated; the rest of the paragraph is true either way. */
  const potsLive = contractsDeployed('jackpotBnbull', 'jackpotBnb');

  return (
    <div>
      <div className="grid gap-6 sm:grid-cols-2">
        <PotCard
          name="jackpotBnbull"
          label={POTS.bnbull.label}
          symbolFallback={POTS.bnbull.symbolFallback}
          odds={POTS.bnbull.odds}
          tone="bnbull"
        />
        <PotCard
          name="jackpotBnb"
          label={POTS.bnb.label}
          symbolFallback={POTS.bnb.symbolFallback}
          odds={POTS.bnb.odds}
          tone="bnb"
        />
      </div>
      <p className="mt-4 text-xs text-bull-text-faint">
        the bnb pot holds wrapped bnb (wbnb), 1:1 with bnb the whole time. it&apos;s the same
        asset, just in erc-20 form so the contract can hold and pay it out.
      </p>

      <div className="mt-10 rounded border border-bull-gold/30 bg-bull-panel p-5">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-gold">
          how the pots grow
        </p>
        <p className="mt-2 max-w-2xl text-sm text-bull-text-dim">
          {POTS.grow} {POTS.rule} {potsLive ? 'every row above is somebody who rolled it. ' : ''}
          no entry fee and nothing to claim: the tokens just turn up.
        </p>
      </div>
    </div>
  );
}
