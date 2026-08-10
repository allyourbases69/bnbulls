'use client';

import { useReadContract } from 'wagmi';
import { ChainReadFailed } from './ChainReadFailed';
import { JackpotAbi, JackpotNativeAbi } from '@/lib/abi';
import {
  contractAddress,
  explorerBaseUrl,
  isNativePot,
  NATIVE_POT_DECIMALS,
  NATIVE_POT_SYMBOL,
} from '@/lib/env';
import { formatToken, shortAddr } from '@/lib/format';
import { tickerToPrint, useTokenDecimals, useTokenSymbol } from '@/lib/hooks/useTokenDecimals';
import { useJackpotAwards } from '@/lib/hooks/useJackpotAwards';
import { awardCompleteness, type JackpotAwardsPayload } from '@/lib/jackpotAwards';
import { QUOTE_REFRESH_MS } from '@/lib/constants';

export function PotCard({
  name,
  label,
  symbolFallback,
  odds,
  tone,
  onOpenDeposits,
  depositsOpen = false,
}: {
  name: 'jackpotBnbull' | 'jackpotBnb';
  label: string;
  /** ⚠ A FALLBACK, NOT THE TICKER. The real one comes off this pot's own
   *  `prizeToken().symbol()` below; this is only reached once that read has
   *  settled with no answer. See `POTS` in `brand.ts`. */
  symbolFallback: string;
  /** ⚠ ONLY EVER RENDERED PRE-LAUNCH, and it comes from `POTS` in `brand.ts` so
   *  there is one place to change it. Once the pot has an address the odds are
   *  read off chain instead — a hardcoded number must never sit next to a live
   *  pool, or a parameter change would leave the page confidently wrong. */
  odds: string;
  /** Which ink this pot wears. Gold is $BNBULL, steel is BNB, and it is the
   *  same vocabulary the ticker strip and the standing panels use so all three
   *  surfaces read as the same two pots. */
  tone: 'bnbull' | 'bnb';
  /**
   * Open this pot's deposit history. Absent, the card behaves exactly as it
   * always did. The PANEL owns which pot is open, not the card, so the two
   * cards can never both believe they are the one showing.
   */
  onOpenDeposits?: () => void;
  depositsOpen?: boolean;
}) {
  const address = contractAddress(name);
  const explorer = explorerBaseUrl();
  // ⚠ Only the BNB pot ever goes native; $BNBULL genuinely IS an ERC-20 and
  // keeps its `prizeToken()`. Branching on the flag alone would point this card
  // at an ABI whose `prizeToken` does not exist for a pot that never changed.
  const native = isNativePot(name);
  const abi = native ? JackpotNativeAbi : JackpotAbi;

  const { data: pool } = useReadContract({
    address: address ?? undefined,
    abi,
    functionName: 'pool',
    query: { enabled: !!address, refetchInterval: QUOTE_REFRESH_MS },
  });
  const { data: oddsOneIn } = useReadContract({
    address: address ?? undefined,
    abi,
    functionName: 'oddsOneIn',
    query: { enabled: !!address },
  });
  const { data: totalAwarded } = useReadContract({
    address: address ?? undefined,
    abi,
    functionName: 'totalAwarded',
    query: { enabled: !!address },
  });
  const { data: awardCount } = useReadContract({
    address: address ?? undefined,
    abi,
    functionName: 'awardCount',
    query: { enabled: !!address },
  });
  // ⚠ NOT ASKED ON A NATIVE POT — the view is gone, and a failed read here used
  // to leave `symbol` on the `WBNB` fallback while the figure beside it read
  // `—`: the exact "right amount, wrong ticker" bug the fallback's own comment
  // warns about, on the one card this migration exists to correct.
  const { data: prizeToken, isError: prizeTokenError } = useReadContract({
    address: address ?? undefined,
    abi: JackpotAbi,
    functionName: 'prizeToken',
    query: { enabled: !!address && !native },
  });
  // Both of the prize token's own facts come off the prize token: the decimals
  // decide the number, the symbol decides what it is called. Reading one live
  // and hardcoding the other renders the right amount with the wrong ticker.
  // A native pot has no token to ask, so both are asserted — there is no
  // contract that could disagree with them.
  const tokenAddr = native ? undefined : (prizeToken as `0x${string}` | undefined);
  const { decimals: tokenDecimals } = useTokenDecimals(tokenAddr);
  const { symbol: liveSymbol, isError: symbolError } = useTokenSymbol(tokenAddr);
  const decimals = native ? NATIVE_POT_DECIMALS : tokenDecimals;
  const symbol = native
    ? NATIVE_POT_SYMBOL
    : tickerToPrint(liveSymbol, !prizeTokenError && !symbolError, symbolFallback);
  /** Pre-spaced, so a still-loading ticker leaves no orphan gap after the
   *  number. Empty is the correct render while we are still asking. */
  const unit = symbol ? ` ${symbol}` : '';

  /**
   * ⚠ THREE STATES, NEVER TWO. Real payouts, a pot nobody has hit yet, and a
   * read that failed are three different facts and the card renders three
   * different things. This list used to sweep logs from the browser and sit on
   * "loading…" forever, on both pots, for every visitor — see `useJackpotAwards`
   * and `lib/serverLogs.ts` for why that was never going to work.
   */
  const awardsRead = useJackpotAwards(name);

  /**
   * PRE-LAUNCH: the real card, at zero.
   *
   * ⚠ THE ZERO IS TRUE, WHICH IS THE ONLY REASON THIS IS ALLOWED. Before the
   * pots exist they hold nothing and have paid nobody, so every figure printed
   * here is the correct figure — this shows the pot, it does not fake one. The
   * card must never render invented pool sizes or a fabricated award list, and
   * the moment an address is configured it drops through to the live path below
   * and reads everything off chain.
   *
   * Owner, 2026-08-07: "on the prod site the BNBULL and BNB pots can be shown
   * but just cosmetically show them at $0." A `NotDeployed` box in their place
   * made a deliberate pre-launch site read as a half-built one.
   */
  if (!address) {
    return (
      <div
        className={`pot-card bull-card ${tone === 'bnbull' ? 'pot-bnbull' : 'pot-bnb'} rounded p-5`}
      >
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">{label}</p>
        <p className="pot-figure bull-header mt-2 font-mono">
          0 <span className="text-base font-normal">{symbolFallback}</span>
        </p>
        <p className="mt-1 text-sm text-bull-text-dim">
          {odds} on every decisive fight, own pool, own roll.
        </p>
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <div>
            <dt className="font-mono text-xs text-bull-text-faint">ever paid out</dt>
            <dd className="font-mono">0 {symbolFallback}</dd>
          </div>
          <div>
            <dt className="font-mono text-xs text-bull-text-faint">wins</dt>
            <dd className="font-mono">0</dd>
          </div>
        </dl>
        <p className="mt-4 font-mono text-xs uppercase tracking-wide text-bull-text-faint">
          recent awards
        </p>
        <p className="mt-2 text-sm text-bull-text-dim">none yet. it starts filling on fight one.</p>
      </div>
    );
  }

  /**
   * The head of the card, and the click target for the deposit history.
   *
   * ⚠ A BUTTON AROUND THIS BLOCK, NOT AROUND THE WHOLE CARD. The awards list
   * below is a list of LINKS to bscscan, and an element that is both a button
   * and full of anchors is invalid markup with genuinely unpredictable
   * behaviour — the tap that was meant to open a transaction opens the feed
   * instead, or neither fires. So the figure is the thing you press and the
   * receipts stay pressable in their own right.
   */
  const head = (
    <>
      <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">{label}</p>
      <p className="pot-figure bull-header mt-2 font-mono">
        {formatToken(pool as bigint | undefined, decimals)}{' '}
        <span className="text-base font-normal">{symbol}</span>
      </p>
      <p className="mt-1 text-sm text-bull-text-dim">
        1-in-{oddsOneIn !== undefined ? String(oddsOneIn) : '…'} on every decisive fight, own pool,
        own roll.
      </p>
      <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
        <div>
          <dt className="font-mono text-xs text-bull-text-faint">ever paid out</dt>
          <dd className="font-mono">
            {formatToken(totalAwarded as bigint | undefined, decimals)}
            {unit}
          </dd>
        </div>
        <div>
          <dt className="font-mono text-xs text-bull-text-faint">wins</dt>
          <dd className="font-mono">{awardCount !== undefined ? String(awardCount) : '—'}</dd>
        </div>
      </dl>
      {onOpenDeposits ? (
        <span className="mt-3 inline-flex items-center gap-1 font-mono text-[11px] uppercase tracking-wide text-bull-text-faint group-hover:text-bull-gold">
          {depositsOpen ? 'showing every deposit' : 'see every deposit'} <span aria-hidden>→</span>
        </span>
      ) : null}
    </>
  );

  return (
    <div
      className={`pot-card bull-card ${tone === 'bnbull' ? 'pot-bnbull' : 'pot-bnb'} rounded p-5`}
    >
      {onOpenDeposits ? (
        <button
          type="button"
          onClick={onOpenDeposits}
          aria-expanded={depositsOpen}
          className="group w-full cursor-pointer text-left"
        >
          {head}
        </button>
      ) : (
        <div>{head}</div>
      )}

      <p className="mt-4 font-mono text-xs uppercase tracking-wide text-bull-text-faint">
        recent awards
      </p>
      {awardsRead.isLoading ? (
        <p className="mt-2 text-sm text-bull-text-dim">reading the chain…</p>
      ) : awardsRead.isError || !awardsRead.data ? (
        <ChainReadFailed
          className="mt-2"
          message={awardsRead.error instanceof Error ? awardsRead.error.message : null}
          onRetry={awardsRead.refetch}
        />
      ) : (
        <Awards data={awardsRead.data} decimals={decimals} unit={unit} explorer={explorer} />
      )}
    </div>
  );
}

/**
 * The payout list, and the two honest ways it can be short.
 *
 * ⚠ AN EMPTY POT IS A COMPLETE RECORD, NOT A MISSING ONE. Neither pot has paid
 * anybody yet, so "nobody has hit this pot yet" is simply the truth and has to
 * look like a fact rather than a failure — no spinner, no shrug, no caveat
 * underneath it. The caveats only appear when the pot's OWN win counter
 * disagrees with what we can show, which is the one case where the list really
 * is missing something.
 */
function Awards({
  data,
  decimals,
  unit,
  explorer,
}: {
  data: JackpotAwardsPayload;
  decimals: number | undefined;
  unit: string;
  explorer: string;
}) {
  const state = awardCompleteness(data);

  if (data.awards.length === 0) {
    // ⚠ THE POT'S OWN COUNTER OVERRULES AN EMPTY LIST. `awardCount` ticks once
    // per `Awarded` (`Jackpot.sol:795`), and it is printed as `wins` a few lines
    // above this. If it says somebody has won and we have no rows, then the list
    // is broken, not the pot — and saying "nobody has hit this pot yet" directly
    // under "wins 3" is a flat contradiction on a card about money.
    if (state === 'partial') {
      return (
        <p className="mt-2 text-sm text-bull-text-dim">
          this pot has paid out, but we could not put the list of wins together just now. the
          payouts are all on chain either way.
        </p>
      );
    }
    return (
      <p className="mt-2 text-sm text-bull-text-dim">
        nobody has hit this pot yet. it is all still money in the middle.
      </p>
    );
  }

  return (
    <>
      <ul className="mt-2 space-y-1.5 text-sm">
        {/* ⚠ KEYED ON `logIndex`, NOT ON `ticketId`. One vrf fulfilment settles
            every pending ticket in the queue, so a single transaction can emit
            `Awarded` more than once; two payouts that agree on everything else
            differ only here. Keyed on less, react merges two real wins into one
            row and the card under-reports what the pot has paid. */}
        {data.awards.slice(0, 8).map((a) => (
          <li key={`${a.txHash}-${a.logIndex}`} className="flex items-center justify-between gap-2">
            <a
              href={`${explorer}/tx/${a.txHash}`}
              target="_blank"
              rel="noreferrer noopener"
              className="font-mono text-xs text-bull-text-dim hover:text-bull-gold"
            >
              bull #{a.tokenId} → {shortAddr(a.winner)}
            </a>
            <span className="font-mono text-xs text-bull-gold">
              {formatToken(BigInt(a.amount), decimals)}
              {unit}
            </span>
          </li>
        ))}
      </ul>
      {/* ⚠ ONLY WHEN THE LIST IS ACTUALLY SHORT. Printed unconditionally this is
          a caveat about nothing, and a caveat about nothing on a money card
          reads as an admission. `complete` — including a complete record of no
          payouts — says nothing at all. */}
      {state === 'partial' ? (
        <p className="mt-2 text-[11px] text-bull-text-faint">
          this is not every win. the pot&apos;s own counter says{' '}
          {data.awardCount === null ? 'there are more' : `${data.awardCount} of them`} and we can
          only show {data.awards.length} here.
        </p>
      ) : null}
      {state === 'unknown' ? (
        <p className="mt-2 text-[11px] text-bull-text-faint">
          we could not reach the pot&apos;s own win counter, so we cannot promise this is every
          payout. what is listed is real and on chain either way.
        </p>
      ) : null}
    </>
  );
}
