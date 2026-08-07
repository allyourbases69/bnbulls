'use client';

/**
 * /history — every fight ever settled, with a working replay on every row.
 *
 * Ported from fighting fefers' `app/history/page.tsx`: same header, same
 * right-aligned counts, same All/Mine tabs with real numbers, same link across
 * to the rating board, same table underneath.
 *
 * ⚠ FOUR STATES, AND ONLY ONE OF THEM MAY SAY "NOBODY HAS FOUGHT". Not
 * deployed, still reading, read-failed, and genuinely empty are four different
 * facts and they look identical if you collapse them — the same rule
 * `useMintedBulls` and `LeadersTable` already hold to. A page that says "no
 * fights yet" because an rpc timed out is the quiet version of being wrong.
 *
 * ⚠ `incomplete` IS RENDERED, NOT SWALLOWED. The scan is bounded (see
 * `useContractLogs`), so on a long-lived contract the oldest fights fall off
 * the back of the window. Showing a partial record as if it were the whole
 * thing is exactly the failure the flag exists to prevent.
 */
import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useAccount } from 'wagmi';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { DuelHistoryTable } from '@/components/duel/DuelHistoryTable';
import { useDuelHistory } from '@/lib/hooks/useDuelHistory';
import { useRoster } from '@/lib/hooks/useRoster';
import { PIT } from '@/lib/brand';

type Filter = 'all' | 'mine';

export function DuelHistoryPanel() {
  const history = useDuelHistory();
  const roster = useRoster();
  const { address, isConnected } = useAccount();
  const [filter, setFilter] = useState<Filter>('all');

  const nameOf = useMemo(() => {
    const m = new Map<number, string>();
    for (const b of roster.all) m.set(b.id, b.name);
    return m;
  }, [roster.all]);

  const mineTokenIds = useMemo(() => {
    const lower = address?.toLowerCase() ?? null;
    if (lower === null) return new Set<number>();
    return new Set(roster.all.filter((b) => b.owner.toLowerCase() === lower).map((b) => b.id));
  }, [roster.all, address]);

  const myFights = useMemo(
    () =>
      history.rows.filter((r) => mineTokenIds.has(r.tokenA) || mineTokenIds.has(r.tokenB)).length,
    [history.rows, mineTokenIds],
  );

  const shown = useMemo(() => {
    if (filter === 'all') return history.rows;
    return history.rows.filter((r) => mineTokenIds.has(r.tokenA) || mineTokenIds.has(r.tokenB));
  }, [history.rows, filter, mineTokenIds]);

  if (!history.deployed) {
    return <NotDeployed what="the duel contract" className="mt-6" />;
  }

  return (
    <div>
      <div className="flex flex-wrap items-center gap-2">
        <FilterTab
          label={`all (${history.rows.length})`}
          active={filter === 'all'}
          onClick={() => setFilter('all')}
        />
        <FilterTab
          label={isConnected ? `mine (${myFights})` : 'mine'}
          active={filter === 'mine'}
          disabled={!isConnected}
          disabledTitle="connect a wallet to filter to your bulls"
          onClick={() => setFilter('mine')}
        />
        <div className="grow" />
        <Link
          href="/leaders"
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold"
        >
          leaders →
        </Link>
      </div>

      {history.isLoading ? (
        <p className="mt-6 text-sm text-bull-text-dim">reading every settled fight off the chain…</p>
      ) : history.unavailable ? (
        <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          <p>
            couldn&apos;t read the fight record off the chain just now. that is this page
            failing to reach an rpc, not an empty record.
          </p>
          <button
            type="button"
            onClick={history.refetch}
            className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </div>
      ) : (
        <>
          {history.incomplete && history.rows.length > 0 && (
            <div className="mt-6 rounded border border-bull-gold/40 bg-bull-panel px-4 py-3">
              <p className="bull-header text-xs uppercase tracking-wider text-bull-gold">
                this is not the full record
              </p>
              <p className="mt-1 text-sm text-bull-text-dim">
                the chain is only searched back over a bounded window, so fights older than
                that are not on this page. every row you can see is real; there may be more
                behind them.
              </p>
            </div>
          )}

          {shown.length === 0 ? (
            <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-6 text-center">
              <p className="text-sm text-bull-text-dim">
                {filter === 'mine' ? PIT.noneOfMineFought : PIT.quiet}
              </p>
              <p className="mt-2 text-sm text-bull-text-faint">
                pick two bulls and send them in at{' '}
                <Link href="/duel" className="text-bull-gold hover:underline">
                  {PIT.label}
                </Link>
                . a fight lands here the moment it settles on chain.
              </p>
            </div>
          ) : (
            <div className="mt-6">
              <div className="mb-3 text-right font-mono text-xs text-bull-text-faint">
                <span className="text-bull-text-dim">{history.rows.length}</span> total fights
                {isConnected && (
                  <>
                    {' · '}
                    <span className="text-bull-gold">{myFights}</span> involve you
                  </>
                )}
              </div>
              <DuelHistoryTable rows={shown} nameOf={nameOf} mineTokenIds={mineTokenIds} />
            </div>
          )}
        </>
      )}
    </div>
  );
}

/** Same control vocabulary as `LeadersTable` and `BullsGrid`, so the three list
 *  pages carry one set of tabs. */
function FilterTab({
  label,
  active,
  disabled,
  disabledTitle,
  onClick,
}: {
  label: string;
  active: boolean;
  disabled?: boolean;
  disabledTitle?: string;
  onClick: () => void;
}) {
  const base = 'rounded-full border px-3 py-1.5 text-xs font-medium transition';
  let cls: string;
  if (disabled) {
    cls = `${base} cursor-not-allowed border-bull-border text-bull-text-faint opacity-50`;
  } else if (active) {
    cls = `${base} border-bull-gold text-bull-gold`;
  } else {
    cls = `${base} border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-text`;
  }
  return (
    <button
      type="button"
      className={cls}
      disabled={disabled}
      title={disabled ? disabledTitle : undefined}
      onClick={onClick}
    >
      {label}
    </button>
  );
}
