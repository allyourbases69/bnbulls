import type { Metadata } from 'next';
import Link from 'next/link';
import { KING_ID } from '@/lib/art/bull';

/**
 * The 404, in the site's own voice.
 *
 * ⚠ WHY IT EARNS A FILE. Without one, Next serves its built-in page: a bare
 * "404 / This page could not be found." in title case, inside our chrome. On a
 * url that is about to be handed out and pasted around, a mistyped link is a
 * completely ordinary event, and the default reads as a site that fell over
 * rather than a page that is not there. It is also the only capitalised
 * sentence on a lowercase site (`VOICE-AND-BRAND.md §1`).
 *
 * ⚠ IT CLAIMS NOTHING. No pre-launch statement here on purpose: this page can
 * be reached long after launch, and a notice that goes stale on a route nobody
 * revisits is exactly how a site starts lying. The links carry the weight.
 */
export const metadata: Metadata = {
  title: 'not found',
  description: 'nothing at this address.',
};

export default function NotFound() {
  return (
    <div className="mx-auto flex min-h-[60vh] max-w-2xl flex-col justify-center px-4 py-16 md:px-8">
      <p className="bull-header text-xs uppercase tracking-[0.2em] text-bull-gold">404</p>
      <h1 className="bull-header mt-3 text-3xl sm:text-4xl">nothing in this paddock</h1>
      <p className="mt-4 text-bull-text-dim">
        that address does not go anywhere. either the link is bent or the page never existed.
      </p>
      <div className="mt-8 flex flex-wrap items-center gap-3">
        <Link href="/" className="bull-btn">
          back to the front
        </Link>
        <Link href="/about" className="bull-btn bull-btn-secondary">
          how to play
        </Link>
        <Link href={`/bull/${KING_ID}`} className="bull-btn bull-btn-secondary">
          meet lord wagyu
        </Link>
      </div>
    </div>
  );
}
