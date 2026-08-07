/**
 * THE PRE-LAUNCH STATEMENT. One block, on every route, saying out loud what
 * this site is waiting for.
 *
 * ⚠ WHY IT IS NOT JUST `NotDeployed`. Every panel already renders an honest
 * "not deployed yet" when its address is unset, and that is the problem: a
 * panel that says that because a READ FAILED is indistinguishable from one that
 * means it. A visitor landing on eight empty boxes has no way to tell a
 * deliberate pre-launch site from a broken one. This block is the difference,
 * and it is the reason the empty panels below it read as intent.
 *
 * ⚠ IT DISAPPEARS ON ITS OWN. It gates on the SET of contracts a game flow
 * needs (`contractsDeployed`), never on one address in isolation — a partial
 * deploy would otherwise leave a half-wired page claiming to be live. So the
 * testnet build, which has every address, never renders this at all, and
 * nothing here has to be edited on deploy day.
 *
 * ⚠ EVERY WORD COMES FROM `lib/brand.ts`. No lore, no claim and no number is
 * typed in this file. `PRELAUNCH` carries the `DECISIONS.md §29` / `§28.1`
 * reasoning next to the strings, which is where a copy change has to be
 * argued.
 *
 * ⚠ NOT the same thing as `NotDeployed`. That one replaces a specific panel
 * ("the mint isn't deployed yet"); this one is the site-level statement.
 */
import Link from 'next/link';
import { contractsDeployed, telegramUrl, xUrl } from '@/lib/env';
import { KING_ID } from '@/lib/art/bull';
import { PRELAUNCH } from '@/lib/brand';

export function PreLaunchNotice({
  className = '',
  /**
   * The landing page's version: the headline fact and the links, without the
   * two paragraphs of detail.
   *
   * ⚠ WHY IT EXISTS. `DECISIONS.md §36` cut the front page down to Lord Wagyu
   * and one line, and was explicit about not stacking explanatory copy under
   * it. The site still has to state that it is not open, so the front page gets
   * the shortest true version of that and the game pages carry the rest.
   */
  compact = false,
}: {
  className?: string;
  compact?: boolean;
}) {
  if (contractsDeployed('bullsNft', 'mintDrop', 'duel')) return null;

  return (
    <aside
      className={`rounded border border-bull-gold/40 bg-bull-panel p-4 text-left sm:p-5 ${className}`}
    >
      <p className="bull-header text-sm text-bull-gold sm:text-base">{PRELAUNCH.heading}</p>

      <p className="mt-2 text-sm leading-relaxed text-bull-text-dim">{PRELAUNCH.state}</p>
      {!compact && (
        <>
          <p className="mt-2 text-sm leading-relaxed text-bull-text-dim">{PRELAUNCH.order}</p>
          <p className="mt-2 text-xs leading-relaxed text-bull-text-faint">
            {PRELAUNCH.addresses}
          </p>
        </>
      )}

      <p className="mt-4 flex flex-wrap items-center gap-x-1 gap-y-2 text-sm text-bull-text-faint">
        <span className="mr-1">{PRELAUNCH.meanwhile}</span>
        <Link href="/about" className="px-1 py-0.5 text-bull-gold hover:underline">
          how it works
        </Link>
        <span aria-hidden>·</span>
        <Link href={`/bull/${KING_ID}`} className="px-1 py-0.5 text-bull-gold hover:underline">
          meet lord wagyu
        </Link>
        <span aria-hidden>·</span>
        <a
          href={xUrl()}
          target="_blank"
          rel="noreferrer noopener"
          className="px-1 py-0.5 text-bull-gold hover:underline"
        >
          x
        </a>
        <span aria-hidden>·</span>
        <a
          href={telegramUrl()}
          target="_blank"
          rel="noreferrer noopener"
          className="px-1 py-0.5 text-bull-gold hover:underline"
        >
          telegram
        </a>
      </p>
    </aside>
  );
}
