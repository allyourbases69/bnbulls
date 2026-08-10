'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { PotCard } from './PotCard';
import { PotDepositFeed } from './PotDepositFeed';
import { POTS } from '@/lib/brand';
import { contractsDeployed, isNativePot } from '@/lib/env';

type PotName = 'jackpotBnbull' | 'jackpotBnb';

/**
 * The hash a pot is reachable at, so the standing panels on `/`, `/mint` and
 * `/duel` can send somebody straight to the right pot's history.
 *
 * ⚠ A HASH, NOT A SEARCH PARAM OR A DYNAMIC SEGMENT. `useSearchParams` forces a
 * client bailout that has to be wrapped in Suspense to build at all, and a
 * dynamic route is the exact shape that 500'd on every deploy until it was
 * given a static fallback (see `/bull/[id]`). A hash is inert: the page stays
 * fully static and the link cannot break the build.
 */
const HASH: Record<PotName, string> = {
  jackpotBnbull: 'bnbull',
  jackpotBnb: 'bnb',
};

function potFromHash(hash: string): PotName | null {
  const h = hash.replace(/^#/, '').toLowerCase();
  if (h === 'bnb' || h === 'jackpotbnb') return 'jackpotBnb';
  if (h === 'bnbull' || h === 'jackpotbnbull') return 'jackpotBnbull';
  return null;
}

export function PotsPanel() {
  /* ⚠ "every row above is …" NEEDS ROWS ABOVE IT, AND PRE-LAUNCH THERE ARE
     NONE. The award list that clause points at lives inside `PotCard`, and
     with no address both cards are replaced by `NotDeployed` - so on the live
     site the sentence pointed at two "not live yet" boxes. A confident
     sentence referring to something that is not on the page is exactly what
     makes a deliberate pre-launch state read as a half-finished one, which is
     the one thing `PreLaunchNotice` exists to prevent. Only the clause that
     needs rows is gated; the rest of the paragraph is true either way. */
  const potsLive = contractsDeployed('jackpotBnbull', 'jackpotBnb');

  /** Which pot's deposit history is showing. One at a time, on purpose: two
   *  open feeds means two columns of numbers in the same asset-less units. */
  const [open, setOpen] = useState<PotName | null>(null);
  const feedRef = useRef<HTMLDivElement | null>(null);

  // Deep link. `/pots#bnb` from the standing panels lands with that pot's
  // history already open, and the back/forward buttons keep working because
  // the hash is the only state that ever hits the url.
  useEffect(() => {
    const apply = () => setOpen(potFromHash(window.location.hash));
    apply();
    window.addEventListener('hashchange', apply);
    return () => window.removeEventListener('hashchange', apply);
  }, []);

  const toggle = useCallback((name: PotName) => {
    setOpen((current) => {
      const next = current === name ? null : name;
      // `replaceState` rather than assigning `location.hash`: assigning it
      // makes the browser jump-scroll to a fragment that does not exist, which
      // on mobile throws the page to the top mid-tap.
      const url = new URL(window.location.href);
      url.hash = next ? HASH[next] : '';
      window.history.replaceState(null, '', url.toString());
      return next;
    });
  }, []);

  // Bring the feed into view when it opens, but never on first paint from a
  // deep link (the browser is already placing the page) and never when it is
  // being closed.
  const opened = useRef<PotName | null>(null);
  useEffect(() => {
    if (open && opened.current !== null && opened.current !== open) {
      feedRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
    opened.current = open;
  }, [open]);

  return (
    <div>
      <div className="grid gap-6 sm:grid-cols-2">
        <PotCard
          name="jackpotBnbull"
          label={POTS.bnbull.label}
          symbolFallback={POTS.bnbull.symbolFallback}
          odds={POTS.bnbull.odds}
          tone="bnbull"
          onOpenDeposits={() => toggle('jackpotBnbull')}
          depositsOpen={open === 'jackpotBnbull'}
        />
        <PotCard
          name="jackpotBnb"
          label={POTS.bnb.label}
          symbolFallback={POTS.bnb.symbolFallback}
          odds={POTS.bnb.odds}
          tone="bnb"
          onOpenDeposits={() => toggle('jackpotBnb')}
          depositsOpen={open === 'jackpotBnb'}
        />
      </div>

      {/* Full width, under both cards: the feed is a list of numbers and dates
          and it reads badly squeezed into half a grid on a phone. */}
      {open ? (
        <div ref={feedRef} className="mt-6 scroll-mt-4">
          <PotDepositFeed
            key={open}
            pot={open}
            label={open === 'jackpotBnbull' ? POTS.bnbull.label : POTS.bnb.label}
            tone={open === 'jackpotBnbull' ? 'bnbull' : 'bnb'}
            onClose={() => toggle(open)}
          />
        </div>
      ) : null}

      <p className="mt-4 text-xs text-bull-text-faint">
        tap a pot to see every deposit that has ever gone into it, and which part of the game paid
        it in.
      </p>

      {/* ⚠ GATED, BECAUSE IT IS ONLY TRUE OF THE OLD POT. `JackpotNative` holds
          and pays RAW BNB — its own header says the wrapper is "a transient
          accounting hop that lives for a few opcodes" and never the resting
          form of the pot. Printed unconditionally, this paragraph now sits
          directly under a deposit feed denominated in bnb telling the reader
          the pot is full of wbnb, which is simply wrong. It stays for a build
          still pointed at the erc-20 pot. */}
      {!isNativePot('jackpotBnb') && (
        <p className="mt-2 text-xs text-bull-text-faint">
          the bnb pot holds wrapped bnb (wbnb), 1:1 with bnb the whole time. it&apos;s the same
          asset, just in erc-20 form so the contract can hold and pay it out.
        </p>
      )}

      <div className="mt-10 rounded border border-bull-gold/30 bg-bull-panel p-5">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-gold">
          how the pots grow
        </p>
        <p className="mt-2 max-w-2xl text-sm text-bull-text-dim">
          {POTS.grow} {POTS.rule} {potsLive ? 'every row above is somebody who rolled it. ' : ''}
          no entry fee and nothing to claim: the tokens just turn up.
        </p>
      </div>
    </div>
  );
}
