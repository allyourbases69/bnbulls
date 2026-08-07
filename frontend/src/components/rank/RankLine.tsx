'use client';

import Link from 'next/link';
import { useRank } from '@/lib/hooks/useRanks';
import { formatPoints } from '@/lib/rank';

/**
 * The rarity-rank line for a bull card: `rank #61 / 147 · 374 pts`.
 *
 * This is the ONE thing another agent has to add to put rank on a card. Drop it
 * under the rating/record row in `BullCard` (or any card) and nothing else
 * changes:
 *
 *   import { RankLine } from '@/components/rank/RankLine';
 *   …
 *   <RankLine tokenId={id} />
 *
 * Fefers renders exactly this on its browse card, under RATING and the record:
 *
 *   RATING 989
 *   4W / 6L / 0T
 *   RANK #61 / 147
 *   374 pts
 *
 * ⚠ CALLING THIS PER CARD IS THE INTENDED USAGE AND IS NOT EXPENSIVE. The rank
 * table is memoised at module level in `useRanks`, and the only chain read
 * behind it (`nextTokenId` / `kingMinted`) is deduped by react-query across
 * every consumer. Forty-eight of these on a browse grid score the collection
 * once between them.
 *
 * ⚠ RENDERS NOTHING UNTIL THE TABLE EXISTS. No placeholder rank, no "—" that
 * could be mistaken for a real position, no guess while the minted count is in
 * flight. Rank is measured against the minted set; before we know that set,
 * there is no honest number to print.
 */
export function RankLine({
  tokenId,
  className = '',
  /** Link the line through to /ranks. Off inside a card that is already a link
   *  (nested anchors are invalid HTML and React will warn). */
  link = false,
}: {
  tokenId: number;
  className?: string;
  link?: boolean;
}) {
  const rank = useRank(tokenId);
  if (!rank) return null;

  const body = (
    <>
      <span className="text-bull-text-faint">rank </span>
      <span className="font-bold text-bull-text">#{rank.rank}</span>
      <span className="text-bull-text-faint"> / {rank.rankOf}</span>
      <span className="text-bull-text-faint"> · {formatPoints(rank.score)}</span>
    </>
  );

  const cls = `whitespace-nowrap font-mono text-xs tabular-nums ${className}`;

  if (!link) return <span className={cls}>{body}</span>;
  return (
    <Link href="/ranks" className={`${cls} hover:text-bull-gold`} title="rarity rank">
      {body}
    </Link>
  );
}
