import { PotCard } from './PotCard';
import { POTS } from '@/lib/brand';

export function PotsPanel() {
  return (
    <div>
      <div className="grid gap-6 sm:grid-cols-2">
        <PotCard
          name="jackpotBnbull"
          label={POTS.bnbull.label}
          symbolFallback={POTS.bnbull.symbolFallback}
          tone="bnbull"
        />
        <PotCard
          name="jackpotBnb"
          label={POTS.bnb.label}
          symbolFallback={POTS.bnb.symbolFallback}
          tone="bnb"
        />
      </div>
      <p className="mt-4 text-xs text-bull-text-faint">
        the bnb pot holds wrapped bnb (wbnb), 1:1 with bnb the whole time. it&apos;s the same
        asset, just in erc-20 form so the contract can hold and pay it out.
      </p>

      <div className="mt-10 rounded border border-bull-gold/30 bg-bull-panel p-5">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-gold">
          the trust story
        </p>
        <p className="mt-2 max-w-2xl text-sm text-bull-text-dim">
          {POTS.trust} every row above is one of those wins. {POTS.rule} winning is the only way
          in: no entry fee, nothing to claim, the tokens just turn up.
        </p>
      </div>
    </div>
  );
}
