'use client';

/**
 * The fight record, as a table. Ported from fighting fefers'
 * `components/DuelHistoryTable.tsx`: same columns in the same order
 * (fighter A · vs · fighter B · rounds · winner · watch · tx), same
 * outcome-coloured names with the rating inline, same YOU badge, same desktop
 * table / mobile card split.
 *
 * ⚠ THE COLOUR IS THE OUTCOME, NOT THE RARITY. Every other list on this site
 * colours a bull by its tier, and this one deliberately does not: a fight log
 * is read for who won, and one gold name against one red name says that at a
 * glance from across the room. The tier is one click away on `/bull/[id]`.
 *
 * ⚠ THE RATING IS THE EVENT'S, NOT A LIVE READ. `newEloA`/`newEloB` are what
 * the chain wrote when that fight settled, so a row keeps saying what the bull
 * was worth on the day even after twenty more fights. Swapping in a current
 * rating would make every historic row silently agree with today.
 *
 * ⚠ THE REPLAY IS A BUTTON, NOT AN `<img>`. Each render costs the server a
 * fight simulation plus a gif encode; a fifty-row page must not fire fifty of
 * them just by existing. See `DuelReplay.tsx`.
 */
import Link from 'next/link';
import { explorerBaseUrl } from '@/lib/env';
import { shortAddr } from '@/lib/format';
import { getBull } from '@/lib/art/collection';
import type { DuelHistoryRow } from '@/lib/hooks/useDuelHistory';
import { DuelReplayButton } from './DuelReplay';

export interface DuelHistoryTableProps {
  rows: readonly DuelHistoryRow[];
  /** Names the CHAIN holds, by token id. The art table is the fallback. */
  nameOf: ReadonlyMap<number, string>;
  /** Token ids in the connected wallet — these get the YOU badge. */
  mineTokenIds?: ReadonlySet<number>;
}

/** `getBull` re-rolls a token's whole trait set on every call, and this table
 *  asks for a name up to four times per row. Memoised because the answer is
 *  deterministic and the alternative is a few hundred rolls per keystroke on
 *  the filter tabs. */
const fallbackNames = new Map<number, string>();
function dealtName(tokenId: number): string {
  const hit = fallbackNames.get(tokenId);
  if (hit !== undefined) return hit;
  const name = getBull(tokenId).name.toLowerCase();
  fallbackNames.set(tokenId, name);
  return name;
}

/** The contract's name wins; the dealt art-table name is the fallback while the
 *  roster is still loading. `verify:rarity` pins the two together, so this can
 *  only ever differ before a read lands. */
function displayName(tokenId: number, nameOf: ReadonlyMap<number, string>): string {
  const onChain = nameOf.get(tokenId);
  if (onChain && onChain.length > 0) return onChain.toLowerCase();
  return dealtName(tokenId);
}

function outcomeClass(won: boolean, tie: boolean): string {
  if (tie) return 'text-bull-text-dim';
  return won ? 'text-bull-gold' : 'text-bull-red';
}

export function DuelHistoryTable({ rows, nameOf, mineTokenIds }: DuelHistoryTableProps) {
  const base = explorerBaseUrl();

  return (
    // `overflow-x-auto`, not `overflow-hidden`: seven columns on a narrow
    // laptop must SCROLL, never clip the tx off the right edge. The body
    // already forbids the page scrolling sideways (globals.css), so an inner
    // scroller is the only place that width can go.
    <div className="overflow-x-auto rounded border border-bull-border">
      {/* Desktop */}
      <table className="hidden w-full text-sm md:table">
        <thead>
          <tr className="border-b border-bull-border bg-bull-panel text-xs uppercase tracking-wider text-bull-text-faint">
            <th className="px-3 py-2 text-left font-medium">fighter a</th>
            <th className="px-2 py-2 text-center font-medium">vs</th>
            <th className="px-3 py-2 text-left font-medium">fighter b</th>
            <th className="px-3 py-2 text-center font-medium">rounds</th>
            <th className="px-3 py-2 text-left font-medium">winner</th>
            <th className="px-3 py-2 text-center font-medium">watch</th>
            <th className="px-3 py-2 text-right font-medium">tx</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const tie = r.winnerId === 0;
            const aWon = !tie && r.winnerId === r.tokenA;
            const bWon = !tie && r.winnerId === r.tokenB;
            const winnerName = tie
              ? 'tie'
              : displayName(aWon ? r.tokenA : r.tokenB, nameOf);

            return (
              <tr
                key={`${r.txHash}-${r.logIndex}`}
                className="border-b border-bull-border/40 transition-colors hover:bg-bull-panel-hover"
              >
                <td className="px-3 py-2">
                  <FighterCell
                    tokenId={r.tokenA}
                    nameOf={nameOf}
                    rating={r.newEloA}
                    won={aWon}
                    tie={tie}
                    mine={mineTokenIds?.has(r.tokenA) ?? false}
                  />
                </td>
                <td className="px-2 py-2 text-center text-xs text-bull-text-faint">vs</td>
                <td className="px-3 py-2">
                  <FighterCell
                    tokenId={r.tokenB}
                    nameOf={nameOf}
                    rating={r.newEloB}
                    won={bWon}
                    tie={tie}
                    mine={mineTokenIds?.has(r.tokenB) ?? false}
                  />
                </td>
                <td className="px-3 py-2 text-center font-mono text-xs tabular-nums text-bull-text-dim">
                  {r.rounds}
                </td>
                <td className={`px-3 py-2 text-sm ${tie ? 'text-bull-text-dim' : 'text-bull-gold'}`}>
                  {winnerName}
                </td>
                <td className="px-3 py-2 text-center">
                  <DuelReplayButton txHash={r.txHash} logIndex={r.logIndex} />
                </td>
                <td className="px-3 py-2 text-right">
                  <a
                    href={`${base}/tx/${r.txHash}`}
                    target="_blank"
                    rel="noreferrer"
                    title={r.txHash}
                    className="font-mono text-xs text-bull-text-faint hover:text-bull-gold"
                  >
                    {shortAddr(r.txHash)}
                  </a>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {/* Mobile */}
      <div className="divide-y divide-bull-border md:hidden">
        {rows.map((r) => {
          const tie = r.winnerId === 0;
          const aWon = !tie && r.winnerId === r.tokenA;
          const bWon = !tie && r.winnerId === r.tokenB;
          const winnerName = tie ? 'tie' : displayName(aWon ? r.tokenA : r.tokenB, nameOf);

          return (
            <div key={`${r.txHash}-${r.logIndex}`} className="space-y-2 p-3">
              <div className="flex items-center justify-between gap-2 text-xs">
                <span className="font-mono text-bull-text-faint">
                  block {r.blockNumber.toString()}
                </span>
                <span className={tie ? 'text-bull-text-dim' : 'text-bull-gold'}>{winnerName}</span>
              </div>
              <FighterCell
                tokenId={r.tokenA}
                nameOf={nameOf}
                rating={r.newEloA}
                won={aWon}
                tie={tie}
                mine={mineTokenIds?.has(r.tokenA) ?? false}
              />
              <p className="text-xs text-bull-text-faint">vs · {r.rounds} rounds</p>
              <FighterCell
                tokenId={r.tokenB}
                nameOf={nameOf}
                rating={r.newEloB}
                won={bWon}
                tie={tie}
                mine={mineTokenIds?.has(r.tokenB) ?? false}
              />
              <div className="flex items-center justify-between gap-3">
                <DuelReplayButton txHash={r.txHash} logIndex={r.logIndex} />
                <a
                  href={`${base}/tx/${r.txHash}`}
                  target="_blank"
                  rel="noreferrer"
                  title={r.txHash}
                  className="font-mono text-xs text-bull-text-faint hover:text-bull-gold"
                >
                  {shortAddr(r.txHash)}
                </a>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function FighterCell({
  tokenId,
  nameOf,
  rating,
  won,
  tie,
  mine,
}: {
  tokenId: number;
  nameOf: ReadonlyMap<number, string>;
  rating: number;
  won: boolean;
  tie: boolean;
  mine: boolean;
}) {
  const name = displayName(tokenId, nameOf);

  return (
    <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
      {/* py on phones is hit area only: on a mobile card the name is the row's
          only tap target. md:py-0 leaves the desktop table alone. */}
      <Link
        href={`/bull/${tokenId}`}
        title={name}
        className={`max-w-[12rem] truncate py-2 text-sm hover:underline md:py-0 ${outcomeClass(won, tie)}`}
      >
        {name}
      </Link>
      {mine && (
        <span className="border border-bull-gold/50 px-1 text-[10px] uppercase tracking-wider text-bull-gold">
          you
        </span>
      )}
      <span className="text-[10px] uppercase tracking-wider text-bull-text-faint">rating</span>
      <span className="font-mono text-xs tabular-nums text-bull-text-dim">{rating}</span>
    </div>
  );
}
