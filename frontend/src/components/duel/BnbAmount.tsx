'use client';

import { formatToken, formatUsdApprox, usdFromBnbWei } from '@/lib/format';

/**
 * ONE BNB FIGURE, WITH THE DOLLARS BESIDE IT, AND NEVER A FAKE ZERO.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS COMPONENT EXISTS SO THAT "HOW MUCH" IS ANSWERED THE SAME WAY EVERY
 * TIME IT IS ASKED.
 * ═══════════════════════════════════════════════════════════════════════
 * Owner, 2026-08-10: *"cant see anywhere there easy it quotes HOW MUCH bnb will
 * be deposited."* Every amount on the bull pit now goes through here, so a
 * figure cannot end up formatted one way beside a preset and another way inside
 * the button that spends it.
 *
 * ⚠ THE THREE STATES ARE GENUINELY DIFFERENT AND NONE MAY BORROW ANOTHER'S
 * LOOK:
 *
 *   · A REAL ZERO      · "0.000000 bnb", plain. An empty balance is a fact.
 *   · AN UNREAD AMOUNT · a dash, dimmed, with a title saying so. NEVER a zero.
 *     Rendering a failed read as 0.0000 is the one bug on this page that costs
 *     somebody money: it tells a player their balance is empty when it is not,
 *     or prices a top-up at nothing.
 *   · NO DOLLAR RATE   · the bnb stands alone, no "≈$0.00". The oracle read
 *     reverts on a stale or out-of-band round on purpose, and a dollar figure
 *     invented over the top of that refusal would be a confident wrong number
 *     attached to money about to move.
 *
 * ⚠ THE DOLLARS ARE ALWAYS PREFIXED `≈`. They are a display conversion of a
 * live chainlink read, rounded for humans; the BNB is the number that gets
 * signed. Nothing here may ever be the source of an amount to send.
 */
export function BnbAmount({
  wei,
  decimals,
  usdPerBnb,
  /** Bigger and gold, for the one figure a row is actually about. */
  emphasis = false,
  className = '',
}: {
  /** `undefined` means the read has not landed. It does NOT mean zero. */
  wei: bigint | undefined;
  /** BNB is 18dp by chain invariant, but it is passed rather than assumed,
   *  exactly like every other token amount in this app. */
  decimals: number | undefined;
  /** Live `bnbUsdPrice()`. `undefined` renders no dollars at all. */
  usdPerBnb: bigint | undefined;
  emphasis?: boolean;
  className?: string;
}) {
  if (wei === undefined) {
    return (
      <span
        className={`font-mono text-bull-text-faint ${className}`}
        title="not read off the chain yet"
      >
        {/* ⚠ AN EM-DASH IS BANNED IN COPY (`VOICE-AND-BRAND §1`) and this is not
            copy, it is the numeric placeholder every other panel already uses
            via `formatToken`. Kept identical so "unread" looks the same
            site-wide. */}
        —
      </span>
    );
  }

  const usd = usdFromBnbWei(wei, usdPerBnb);

  return (
    <span className={`whitespace-nowrap ${className}`}>
      <span className={`font-mono ${emphasis ? 'text-bull-gold' : 'text-bull-text'}`}>
        {formatToken(wei, decimals)} bnb
      </span>
      {usd !== undefined && (
        <span className="ml-1.5 font-mono text-bull-text-faint">≈ {formatUsdApprox(usd)}</span>
      )}
    </span>
  );
}

/**
 * The same figure as a plain string, for the inside of a button label.
 *
 * ⚠ BUTTONS CARRY THE AMOUNT, AND THAT IS THE WHOLE POINT OF THIS HELPER. A
 * player must be able to read what a press is about to spend without looking
 * anywhere else on the page, because the next thing on screen after the press is
 * a wallet, and a wallet shows wei-precision hex to people who did not ask for
 * it. `— bnb` is returned for an unread amount so a caller that forgets to
 * disable the button still cannot advertise a zero.
 */
export function bnbLabel(
  wei: bigint | undefined,
  decimals: number | undefined,
  usdPerBnb: bigint | undefined,
): string {
  if (wei === undefined) return '— bnb';
  const usd = usdFromBnbWei(wei, usdPerBnb);
  const bnb = `${formatToken(wei, decimals)} bnb`;
  return usd === undefined ? bnb : `${bnb} · ≈ ${formatUsdApprox(usd)}`;
}
