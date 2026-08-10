'use client';

import { READY } from '@/lib/brand';
import { BnbAmount } from '@/components/duel/BnbAmount';

/**
 * WHAT ONE FIGHT COSTS, ABOVE EVERYTHING, FOR EVERYBODY.
 *
 * ⚠ THIS RENDERS FOR A DISCONNECTED VISITOR TOO, AND THAT IS THE POINT. The
 * price used to live inside a folded "what a fight costs, per currency" table
 * three sections down and behind a wallet connection, so the first question
 * anybody has about a money game — how much is this — was the hardest thing on
 * the page to find. A stranger can now read it before they connect anything.
 *
 * ⚠ THE FIGURE IS `fighterCost`, READ, NEVER DERIVED. It is a dollar sticker
 * converted through chainlink inside the contract and it moves every block, so
 * a hardcoded ladder would drift and quietly under-quote. When the read has not
 * landed the amount is a dash; when the contract REFUSES to quote (a stale or
 * out-of-band oracle round, which is a designed answer and not a fault) the
 * strip says so in words instead of showing a number.
 *
 * ⚠ NEVER RENDER `0` HERE AS A PRICE. A zero cost is a FREE fight on the
 * contract (`Duel.sol:536`) and an unpegged leg in practice, so it is treated as
 * "not priced" rather than printed as a bargain.
 */
export function FightPrice({
  perFight,
  decimals,
  usdPerBnb,
  className = '',
}: {
  /** `fighterCost(wbnb)`. `undefined` = the read has not landed or the contract
   *  refused to quote. */
  perFight: bigint | undefined;
  decimals: number | undefined;
  usdPerBnb: bigint | undefined;
  className?: string;
}) {
  const priced = perFight !== undefined && perFight > 0n;

  return (
    <div
      className={`rounded border border-bull-border bg-bull-panel px-3 py-2.5 ${className}`}
    >
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <span className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
          {READY.priceLabel}
        </span>
        {priced ? (
          <BnbAmount
            wei={perFight}
            decimals={decimals}
            usdPerBnb={usdPerBnb}
            emphasis
            className="text-sm"
          />
        ) : (
          <span className="font-mono text-sm text-bull-text-faint">—</span>
        )}
      </div>
      {/* ⚠ THREE OUTCOMES, THREE SENTENCES, AND THEY ARE NOT INTERCHANGEABLE.
          A read that has not answered, a contract that REFUSED to quote off a
          sick oracle, and a leg nobody has pegged are different facts, and only
          the last one is anything like "zero". */}
      <p className="mt-1 text-[11px] text-bull-text-faint">
        {priced ? (
          <>
            {READY.priceLine} {READY.priceMoves}
          </>
        ) : perFight === undefined ? (
          READY.priceUnreadable
        ) : (
          READY.priceUnset
        )}
      </p>
    </div>
  );
}
