'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { BullSprite } from '@/components/BullSprite';
import { Pager } from '@/components/rank/Pager';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { getBull } from '@/lib/art/collection';
import { SUPPLY } from '@/lib/art/bull';
import { useRanks } from '@/lib/hooks/useRanks';
import { usePen } from '@/lib/hooks/usePen';
import { tierLabel, tierTextClass } from '@/lib/rarity';

/**
 * /ranks — the full rarity-rank table, ported from fighting fefers'
 * `app/ranks/page.tsx` block for block:
 *
 *   last-computed line · ⚠ "may shift as more mint" · pager · rows · pager
 *
 * and the row is fefers' row, field for field: rank #, sprite, name + #id,
 * tier · weapon, score, `n / total`.
 *
 * ⚠ FEFERS' EXPLANATION LINE IS LOAD-BEARING AND IS NOT TRIMMED. "this is how
 * rare the bull IS, not how good it fights" is the sentence that stops people
 * reading a rarity rank as a power ranking. It lives on the page above this
 * component.
 *
 * ⚠ NO `/api/rank` HERE. Fefers fetches a server-cached table because it has to
 * read every token's traits off chain. bnbulls derives them (see
 * `lib/hooks/useRanks.ts` for why), so there is no request to fail, no 5-minute
 * staleness and no error taxonomy to write. The one thing that CAN fail is the
 * minted-count read, and it gets the same three-state treatment every other
 * surface gives it: loading / unavailable / genuinely nothing minted.
 */
const DEFAULT_PAGE_SIZE = 20;

export function RanksTable() {
  const { ranks, rankOf, computedAt, deployed, isLoading, unavailable, refetch } = useRanks();
  // ⚠ Only decides WHICH sentence of the warning below is true. It never gates
  // the table itself: `useRanks` already ranks the circulating set either way.
  const { isPen } = usePen();
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);

  const totalPages = Math.max(1, Math.ceil(ranks.length / pageSize));
  const safePage = Math.min(Math.max(1, page), totalPages);
  const rows = useMemo(
    () => ranks.slice((safePage - 1) * pageSize, safePage * pageSize),
    [ranks, safePage, pageSize],
  );

  return (
    <div>
      {/* ⚠ BOTH LINES ARE GATED ON `deployed`, and that is not tidiness. With
          no collection there is nothing to compute and nothing to shift, so
          "computed in your browser" and "rank may shift as more mint" are two
          statements about a table that does not exist, sitting directly above
          a box saying the collection is not live. Three sentences that
          contradict each other is how a deliberate pre-launch page reads as a
          broken one. */}
      {deployed && (
        <>
          <p className="mt-2 text-sm text-bull-text-dim">
            {computedAt === null ? (
              <>computed in your browser, off the same tables the contract holds.</>
            ) : (
              <>
                last computed {new Date(computedAt).toLocaleString('en-US')} · recomputes in your browser
                whenever the minted count changes
              </>
            )}
          </p>
          {/* ⚠ TWO WORDINGS FOR THE SAME WARNING, PICKED OFF THE LIVE WIRING,
              AND THE SPLIT IS NOT HEDGING.

              The pen version has to exist because "locks once the 500 drop
              completes" quietly becomes FALSE at the pre-mint: `BullPen` is
              stocked by minting the whole remaining supply straight into it, so
              `nextTokenId` hits 501 on day one. A reader who knows that, or who
              checks the contract, would take "the drop completed" at face value
              and conclude these ranks were final. They are not. The trigger is
              the pen emptying, not the tokens existing.

              But the pen version cannot ship EARLY. Until the pen is wired there
              is no pen, and "every time one comes out of the pen" would be a
              sentence about machinery that does not exist yet, on the live site,
              today. So the old wording stays until the day it stops being true,
              which is the day `penContract()` goes non-zero. */}
          <p className="mt-2 text-sm text-bull-gold">
            {isPen ? (
              <>
                ⚠ rank is measured against the bulls people actually hold, so it shifts every
                time one comes out of the pen. it settles for good once all {SUPPLY} have been
                bought.
              </>
            ) : (
              <>⚠ rank may shift as more bulls mint. locks once the {SUPPLY} drop completes.</>
            )}
          </p>
        </>
      )}

      {/* ⚠ THREE STATES, AND ONLY ONE OF THEM MAY SAY "NOTHING IS MINTED". A
          read that never answered is not an empty collection. */}
      {!deployed ? (
        <NotDeployed what="the bulls collection" className="mt-6" />
      ) : isLoading ? (
        <p className="mt-6 text-sm text-bull-text-dim">counting the herd…</p>
      ) : unavailable ? (
        <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          <p>
            couldn&apos;t read how many bulls are minted just now. rank is measured against the
            minted set, so nothing here is going to guess at it.
          </p>
          <button
            type="button"
            onClick={refetch}
            className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </div>
      ) : ranks.length === 0 ? (
        <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-6 text-center">
          <p className="text-sm text-bull-text-dim">nothing to rank yet.</p>
          <p className="mt-2 text-sm text-bull-text-faint">
            rarity rank measures every bull against every other one, so it needs some minted
            first.{' '}
            <Link href="/mint" className="text-bull-gold hover:underline">
              bring the first one into the world
            </Link>{' '}
            and it shows up here straight away.
          </p>
        </div>
      ) : null}

      {ranks.length > 0 && (
        <>
          <Pager
            page={safePage}
            pageSize={pageSize}
            total={ranks.length}
            onPageChange={setPage}
            onPageSizeChange={setPageSize}
          />

          <div className="space-y-2">
            {rows.map((row) => (
              <RankRow
                key={row.tokenId}
                tokenId={row.tokenId}
                rank={row.rank}
                rankOf={rankOf}
                score={row.score}
              />
            ))}
          </div>

          <Pager
            page={safePage}
            pageSize={pageSize}
            total={ranks.length}
            onPageChange={setPage}
            onPageSizeChange={setPageSize}
          />
        </>
      )}
    </div>
  );
}

function RankRow({
  tokenId,
  rank,
  rankOf,
  score,
}: {
  tokenId: number;
  rank: number;
  rankOf: number;
  score: number;
}) {
  // ⚠ Sprite, name and weapon all come off `getBull`, the same call the browse
  // grid and the bull page draw with, so a bull can never be shown one way here
  // and another way there. The TIER shown is the one the score was computed
  // from, which is the same chain table `getBull` reads.
  const token = useMemo(() => getBull(tokenId), [tokenId]);
  const tier = token.king ? 'king' : token.band;

  return (
    <Link
      href={`/bull/${tokenId}`}
      className="bull-card flex items-center gap-3 rounded border border-bull-border px-3 py-2 transition hover:border-bull-gold sm:gap-4 sm:px-4 sm:py-3"
    >
      <div className="bull-header w-10 shrink-0 text-right text-base text-bull-gold sm:w-14">
        #{rank}
      </div>

      <div className="w-11 shrink-0 bg-bull-bg sm:w-12">
        <BullSprite token={token} fluid />
      </div>

      <div className="min-w-0 flex-1">
        <div className="truncate text-sm leading-tight text-bull-text" title={token.name}>
          {token.name.toLowerCase()}{' '}
          <span className="font-mono text-xs text-bull-text-faint">#{tokenId}</span>
        </div>
        <div className="flex flex-wrap items-center gap-x-2 text-xs text-bull-text-dim">
          <span className={tierTextClass(tier)}>{tierLabel(tier)}</span>
          <span aria-hidden>·</span>
          <span className="capitalize text-bull-gold">{token.weapon}</span>
        </div>
      </div>

      <div className="shrink-0 text-right">
        <div className="bull-header text-base tabular-nums text-bull-gold">{score.toFixed(1)}</div>
        <div className="font-mono text-xs tabular-nums text-bull-text-faint">
          {rank}/{rankOf}
        </div>
      </div>
    </Link>
  );
}
