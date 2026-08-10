'use client';

import { useMemo, useState } from 'react';
import { explorerBaseUrl } from '@/lib/env';
import { formatDuration, formatToken, formatUsd1e18, shortAddr } from '@/lib/format';
import { usePotDeposits } from '@/lib/hooks/usePotDeposits';
import {
  byRoute,
  completeness,
  DEPOSIT_ROUTES,
  sourceNote,
  type PotDepositsPayload,
} from '@/lib/potDeposits';

/**
 * "WHERE DID ALL THAT MONEY COME FROM?" — the deposit history for one pot.
 *
 * Opens under the two cards on `/pots` when a card is clicked. Every row is one
 * `Funded` event: how much, from where, and when, with a link to the
 * transaction so nothing here has to be taken on faith.
 *
 * ── THE THREE STATES THAT MUST NOT LOOK ALIKE ─────────────────────────
 *
 *   1. no deposits yet        the pot really has had nothing paid in
 *   2. we could not read      the chain read failed
 *   3. not the full record    we read something, but it does not add up to the
 *                             pot's own lifetime counter
 *
 * A page that renders (2) as (1) tells a visitor a pot is empty when it is
 * full, and a page that renders (3) as (1) understates a pot for the same
 * reason. `completeness()` decides between them off the pot's own
 * `totalFunded()`, which is a number the feed cannot fudge.
 *
 * ── WHY THE ROWS DO NOT ADD UP TO THE POT ─────────────────────────────
 *
 * They are not supposed to, and the card says so rather than hiding it: money
 * leaves through wins. `deposits in − paid out = what is sitting there now`,
 * and all three figures are printed together so the arithmetic is visible
 * instead of looking like a discrepancy.
 */
export function PotDepositFeed({
  pot,
  label,
  tone,
  onClose,
}: {
  pot: 'jackpotBnbull' | 'jackpotBnb';
  label: string;
  tone: 'bnbull' | 'bnb';
  onClose: () => void;
}) {
  const { data, isLoading, isError, error, refetch, isFetching } = usePotDeposits(pot, true);
  const [showAll, setShowAll] = useState(false);

  return (
    <section
      className={`pot-card bull-card ${tone === 'bnbull' ? 'pot-bnbull' : 'pot-bnb'} rounded p-4 sm:p-5`}
      aria-live="polite"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-2">
        <div className="min-w-0">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
            {label} · money in
          </p>
          <h2 className="bull-header mt-1 text-lg sm:text-xl">every deposit into this pot</h2>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="shrink-0 rounded-full border border-bull-border px-3 py-1 font-mono text-[11px] uppercase tracking-wide text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
        >
          close
        </button>
      </div>

      {isLoading ? (
        <p className="mt-4 text-sm text-bull-text-dim">reading the chain…</p>
      ) : isError || !data ? (
        <FailedRead message={error instanceof Error ? error.message : null} onRetry={() => void refetch()} />
      ) : (
        <Loaded data={data} showAll={showAll} onShowAll={() => setShowAll(true)} refreshing={isFetching} />
      )}
    </section>
  );
}

/**
 * ⚠ THIS IS NOT "no deposits yet", AND IT MUST NEVER READ LIKE IT. A read that
 * failed and a pot that is empty are completely different facts, and the only
 * one of them that is ever an accusation is the one we would be making by
 * accident.
 */
function FailedRead({ message, onRetry }: { message: string | null; onRetry: () => void }) {
  return (
    <div className="mt-4 rounded border border-bull-border bg-black/20 p-3">
      <p className="text-sm text-bull-text">we could not read the chain just now.</p>
      <p className="mt-1 text-xs text-bull-text-faint">
        this is a problem at our end, not an empty pot. the deposits are all still on chain.
        {message ? ` (${message})` : ''}
      </p>
      <button
        type="button"
        onClick={onRetry}
        className="mt-2 rounded-full border border-bull-gold px-3 py-1 font-mono text-[11px] uppercase tracking-wide text-bull-gold hover:bg-bull-gold/10"
      >
        try again
      </button>
    </div>
  );
}

function Loaded({
  data,
  showAll,
  onShowAll,
  refreshing,
}: {
  data: PotDepositsPayload;
  showAll: boolean;
  onShowAll: () => void;
  refreshing: boolean;
}) {
  const explorer = explorerBaseUrl();
  const unit = data.symbol ? ` ${data.symbol}` : '';
  const state = completeness(data);
  const routes = useMemo(() => byRoute(data.deposits), [data.deposits]);
  const shown = BigInt(data.shownTotal);

  /** Raw units -> a 1e18-scaled dollar figure, or null when there is no honest
   *  rate to use. $BNBULL has no oracle, so that pot gets no usd at all rather
   *  than a made-up one. */
  const usd = (amount: bigint): bigint | null => {
    if (data.bnbUsd1e18 === null) return null;
    if (data.decimals !== 18) return null;
    return (amount * BigInt(data.bnbUsd1e18)) / 10n ** 18n;
  };

  const headlineUsd = usd(shown);
  const nowSec = Math.floor(Date.now() / 1000);
  const rows = showAll ? data.deposits : data.deposits.slice(0, 20);
  const biggest = routes[0]?.total ?? 0n;
  const awarded = data.totalAwarded === null ? null : BigInt(data.totalAwarded);

  return (
    <>
      <div className="pot-plate mt-4 p-3">
        <p className="font-mono text-[10px] uppercase tracking-wider text-bull-text-faint">
          paid in since day one
        </p>
        {/* ⚠ THE SPACE IS AN EXPLICIT `{' '}`, NOT A LEADING SPACE INSIDE THE
            SPAN. A space at the start of an inline element's own content gets
            collapsed away, which rendered the headline as "0.052754BNB". Same
            shape `PotCard` uses, for the same reason. */}
        <p className="pot-figure bull-header mt-1">
          {formatToken(shown, data.decimals, { maxFractionDigits: 6 })}{' '}
          <span className="text-base font-normal">{data.symbol}</span>
        </p>
        <p className="mt-1 text-[11px] text-bull-text-faint">
          {headlineUsd !== null ? `${formatUsd1e18(headlineUsd)} · ` : ''}
          {data.deposits.length === 1 ? '1 deposit' : `${data.deposits.length} deposits`}
          {/* ⚠ THE ROWS ARE NOT MEANT TO EQUAL THE POT, AND THIS IS THE LINE
              THAT SAYS SO. Money leaves through wins, so "paid in" is always
              the bigger number once a pot has fired. Printing the two totals
              without the sentence between them looks like a discrepancy in a
              feed whose whole job is to be checkable. */}
          {/* Silent on an empty pot: "none of it has been won yet, so the whole
              0 is still money in the middle" is a sentence about nothing. */}
          {data.deposits.length > 0 && data.pool !== null && awarded !== null ? (
            awarded === 0n ? (
              <>
                {' '}· none of it has been won yet, so the whole{' '}
                {formatToken(BigInt(data.pool), data.decimals, { maxFractionDigits: 6 })}
                {unit} is still money in the middle
              </>
            ) : (
              <>
                {' '}· {formatToken(awarded, data.decimals, { maxFractionDigits: 6 })}
                {unit} of it has already been won, leaving{' '}
                {formatToken(BigInt(data.pool), data.decimals, { maxFractionDigits: 6 })}
                {unit} in the middle
              </>
            )
          ) : null}
        </p>
      </div>

      <Honesty state={state} data={data} />

      {data.deposits.length === 0 ? (
        <p className="mt-4 text-sm text-bull-text-dim">
          nothing has been paid into this pot yet. it starts filling on the first fight, mint or
          revive that routes here.
        </p>
      ) : (
        <>
          <p className="mt-5 font-mono text-xs uppercase tracking-wide text-bull-text-faint">
            where it came from
          </p>
          <ul className="mt-2 space-y-2">
            {routes.map((r) => {
              const pct = biggest > 0n ? Number((r.total * 1000n) / biggest) / 10 : 0;
              return (
                <li key={r.route}>
                  <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
                    <span className="text-sm text-bull-text">
                      {DEPOSIT_ROUTES[r.route].line}
                    </span>
                    <span
                      className="font-mono text-xs"
                      style={{ color: 'rgb(var(--pot-ink))', fontVariantNumeric: 'tabular-nums' }}
                    >
                      {formatToken(r.total, data.decimals, { maxFractionDigits: 6 })}
                      {unit}
                      <span className="text-bull-text-faint">
                        {' '}
                        · {r.count === 1 ? '1 drop' : `${r.count} drops`}
                      </span>
                    </span>
                  </div>
                  <div className="mt-1 h-1 overflow-hidden rounded-full bg-black/40">
                    <div
                      className="h-full"
                      style={{ width: `${Math.max(pct, 1)}%`, background: 'rgb(var(--pot-ink) / 0.7)' }}
                    />
                  </div>
                </li>
              );
            })}
          </ul>

          <p className="mt-5 font-mono text-xs uppercase tracking-wide text-bull-text-faint">
            the feed
          </p>
          <ul className="mt-1">
            {rows.map((d) => {
              const amount = BigInt(d.amount);
              const rowUsd = usd(amount);
              const note = sourceNote(d.source);
              const age = Math.max(0, nowSec - d.timestamp);
              return (
                <li
                  key={`${d.txHash}-${d.logIndex}`}
                  className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5 border-t border-bull-border py-2"
                >
                  <span className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
                    <span className="pot-chip font-mono text-[10px] uppercase tracking-wide">
                      {DEPOSIT_ROUTES[d.route].chip}
                    </span>
                    <span className="font-mono text-[11px] text-bull-text-faint">
                      {d.route === 'unknown' ? `${shortAddr(d.from)} · ` : ''}
                      {d.source}
                      {note ? ` · ${note}` : ''}
                    </span>
                  </span>
                  <span className="flex shrink-0 items-baseline gap-2">
                    <span
                      className="font-mono text-sm"
                      style={{ color: 'rgb(var(--pot-ink))', fontVariantNumeric: 'tabular-nums' }}
                    >
                      {/* ⚠ EIGHT PLACES ON A ROW, SIX EVERYWHERE ELSE, AND THE
                          DIFFERENCE IS DELIBERATE. A single fight's cut is
                          around 0.0001 bnb, which at six places rounds every
                          duel row to the identical "0.0001" and makes a live
                          feed look like a stuck one. The summary figures stay
                          at six so they match the pot figure on the card. */}
                      +{formatToken(amount, data.decimals, { maxFractionDigits: 8 })}
                      {unit}
                    </span>
                    {/* A dollar figure that rounds to nothing is noise, so it
                        is simply left off rather than printed as "$0.00". */}
                    {rowUsd !== null && rowUsd >= 10n ** 16n ? (
                      <span className="font-mono text-[11px] text-bull-text-faint">
                        {formatUsd1e18(rowUsd)}
                      </span>
                    ) : null}
                    <a
                      href={`${explorer}/tx/${d.txHash}`}
                      target="_blank"
                      rel="noreferrer noopener"
                      className="font-mono text-[11px] text-bull-text-faint underline decoration-dotted underline-offset-2 hover:text-bull-gold"
                      title={`block ${d.blockNumber}`}
                    >
                      {formatDuration(age)} ago
                    </a>
                  </span>
                </li>
              );
            })}
          </ul>

          {!showAll && data.deposits.length > rows.length ? (
            <button
              type="button"
              onClick={onShowAll}
              className="mt-3 rounded-full border border-bull-border px-3 py-1 font-mono text-[11px] uppercase tracking-wide text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
            >
              show all {data.deposits.length}
            </button>
          ) : null}
        </>
      )}

      <p className="mt-4 text-[11px] text-bull-text-faint">
        read at {new Date(data.fetchedAt).toLocaleTimeString()}
        {refreshing ? ' · refreshing…' : ''} · every row is a transaction on bscscan, tap the clock
        to open it.
      </p>
    </>
  );
}

/**
 * The line that says whether this is the whole record.
 *
 * ⚠ SILENT ONLY WHEN THE SUM MATCHES THE POT'S OWN COUNTER. Partial and unknown
 * both get words, because a visitor comparing this total against the pot figure
 * on the card above deserves to be told why they differ rather than left to
 * conclude one of the two is wrong.
 */
function Honesty({
  state,
  data,
}: {
  state: 'complete' | 'partial' | 'unknown';
  data: PotDepositsPayload;
}) {
  if (state === 'complete') return null;
  const unit = data.symbol ? ` ${data.symbol}` : '';

  if (state === 'unknown') {
    return (
      <p className="mt-3 rounded border border-bull-border bg-black/20 p-2 text-[11px] text-bull-text-faint">
        we could not reach the pot&apos;s own lifetime counter, so we cannot promise this is every
        deposit. what is listed is real and on chain either way.
      </p>
    );
  }

  return (
    <p className="mt-3 rounded border border-bull-border bg-black/20 p-2 text-[11px] text-bull-text-faint">
      this is not the full record. the pot&apos;s own counter says{' '}
      {data.totalFunded !== null
        ? `${formatToken(BigInt(data.totalFunded), data.decimals, { maxFractionDigits: 6 })}${unit}`
        : 'more'}{' '}
      has been paid in and we can only account for{' '}
      {formatToken(BigInt(data.shownTotal), data.decimals, { maxFractionDigits: 6 })}
      {unit} of it here. nothing is missing from the pot, only from this list.
    </p>
  );
}
