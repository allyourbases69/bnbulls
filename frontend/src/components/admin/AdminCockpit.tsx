'use client';

/**
 * AdminCockpit — the operator cockpit body.
 *
 * ONLY ever rendered by `src/app/admin/page.tsx` after that Server Component has
 * verified the signed session cookie. It does no gating of its own on purpose:
 * one gate, server-side, in one place.
 *
 * Every number here is a live chain read for chain 56, and every control writes
 * through the connected wallet after a pre-send simulation. There is no server
 * data layer: what you see is what the contracts say — which also means none of
 * it is secret. Hiding this page hides the convenience, not the facts. A write
 * from a wallet the contract doesn't consider the owner just reverts; the
 * pre-send simulation catches that and shows a decoded reason.
 */
import { useCallback, useState } from 'react';
import { ConnectButton } from '@/components/ConnectButton';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { IS_TESTNET, CHAIN_ID } from '@/lib/env';
import { AdminPots } from '@/components/admin/AdminPots';
import { AdminMint } from '@/components/admin/AdminMint';
import { AdminFights } from '@/components/admin/AdminFights';
import { AdminGraveyard } from '@/components/admin/AdminGraveyard';
import { AdminMarketplace } from '@/components/admin/AdminMarketplace';
import { AdminYards } from '@/components/admin/AdminYards';

function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

const TABS = [
  { key: 'pots', label: 'the pots', render: () => <AdminPots /> },
  { key: 'mint', label: 'the mint', render: () => <AdminMint /> },
  { key: 'fights', label: 'the fights', render: () => <AdminFights /> },
  { key: 'butcher', label: 'the butcher', render: () => <AdminGraveyard /> },
  { key: 'market', label: 'marketplace', render: () => <AdminMarketplace /> },
  { key: 'pit', label: 'the pit', render: () => <AdminYards /> },
] as const;

type TabKey = (typeof TABS)[number]['key'];

export function AdminCockpit({
  sessionAddress,
  expiresAt,
}: {
  /** Address from the SIGNED cookie payload, not from wagmi. */
  sessionAddress: string;
  /** Session expiry, unix seconds, straight off the signed payload. */
  expiresAt: number;
}) {
  const [tab, setTab] = useState<TabKey>('pots');
  const [locking, setLocking] = useState(false);

  // The "lock" control: drops the session cookie server-side, then reloads
  // /admin. With the cookie gone the middleware rewrites to the lock screen, so
  // the cockpit's code leaves the page along with the session.
  const handleLock = useCallback(async () => {
    setLocking(true);
    try {
      await fetch('/api/admin/logout', { method: 'POST', cache: 'no-store' });
    } catch {
      /* clearing your own cookie failing is not worth an error UI */
    }
    window.location.assign('/admin');
  }, []);

  const active = TABS.find((t) => t.key === tab) ?? TABS[0];

  return (
    <div>
      <div className="border-b border-bull-border bg-bull-panel/40">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-4 py-2 font-mono text-xs md:px-8">
          <span className="text-bull-text-dim">
            signed in as <span className="text-bull-gold">{shortAddr(sessionAddress)}</span>
            <span className="ml-2 text-bull-text-faint">
              until {new Date(expiresAt * 1000).toLocaleTimeString()}
            </span>
          </span>
          <div className="flex items-center gap-3">
            <ConnectButton />
            <button
              type="button"
              className="text-bull-red hover:underline disabled:opacity-50"
              onClick={handleLock}
              disabled={locking}
            >
              {locking ? 'locking…' : 'lock'}
            </button>
          </div>
        </div>
      </div>

      <div className="mx-auto max-w-6xl space-y-6 px-4 py-8 md:px-8">
        <header className="space-y-2">
          <h1 className="bull-header text-3xl text-bull-text">the cockpit</h1>
          <p className="text-sm text-bull-text-dim">
            live off chain, writes go through your connected wallet. every write is simulated first,
            so anything the contract would reject is stopped with a reason before your wallet opens.
            the contracts have the final say — anything you aren&rsquo;t the owner of just bounces.
          </p>
          <p className="font-mono text-xs text-bull-text-dim">
            {IS_TESTNET ? 'bnb testnet' : 'bnb chain'} · chain {CHAIN_ID}
          </p>
        </header>

        <WrongNetworkNotice />

        <nav className="flex flex-wrap gap-2 border-b border-bull-border pb-3">
          {TABS.map((t) => (
            <button
              key={t.key}
              type="button"
              onClick={() => setTab(t.key)}
              className={`rounded-full border px-3 py-1.5 text-xs font-medium ${
                t.key === tab
                  ? 'border-bull-gold text-bull-gold'
                  : 'border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-gold'
              }`}
            >
              {t.label}
            </button>
          ))}
        </nav>

        <div className="pt-2">{active.render()}</div>
      </div>
    </div>
  );
}
