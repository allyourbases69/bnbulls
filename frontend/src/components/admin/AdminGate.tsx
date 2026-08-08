'use client';

/**
 * AdminGate — the LOCKED face of /admin, plus the sign-to-unlock flow.
 *
 * ⚠ READ THIS BEFORE TRUSTING ANYTHING HERE. This file is UI only. It decides
 * nothing. The actual gate is server-side:
 *   - `src/app/admin/page.tsx` is a Server Component that verifies the
 *     HMAC-signed session cookie before it will render the cockpit at all; and
 *   - `src/middleware.ts` 401s /api/admin/* without the same cookie.
 * Editing this component, or the React state behind it, gets you a prettier
 * locked screen and nothing else.
 *
 * What it does:
 *   1. asks POST /api/admin/nonce for a fresh server-issued nonce
 *   2. has the wallet sign the plain-english message the server returned
 *   3. posts { address, signature } to POST /api/admin/verify, which recovers
 *      the signer server-side, checks the allow-list, and sets the cookie
 *   4. hard-navigates to /admin — the middleware now sees the cookie, skips the
 *      rewrite, and serves the real cockpit route
 *
 * The allow-list check below is COSMETIC: it only decides whether to show a
 * sign button or the flat panel. The server keeps its own copy and is the one
 * that matters.
 */
import { useCallback, useState } from 'react';
import Link from 'next/link';
import { useAccount, useSignMessage } from 'wagmi';
import { ConnectButton } from '@/components/ConnectButton';

/** Default allow-list: the dev wallet. Mirrors the server default. */
const DEFAULT_ADMIN = '0x5b1A749cc7bF1dE8ecA505769BD34Ba65f456805';

/** Parsed once at module load. Literal process.env read so Next inlines it. */
const ADMIN_ADDRESSES: readonly string[] = (
  process.env.NEXT_PUBLIC_ADMIN_ADDRESSES?.trim()
    ? process.env.NEXT_PUBLIC_ADMIN_ADDRESSES.split(',')
    : [DEFAULT_ADMIN]
)
  .map((a) => a.trim().toLowerCase())
  .filter((a) => /^0x[0-9a-f]{40}$/.test(a));

/**
 * True when the connected wallet is on the (client-visible) allow-list. UX
 * only — it decides which panel to draw, never whether anything is served. With
 * wagmi `ssr: true` the first client render is always disconnected (= false) so
 * it can't cause a hydration mismatch.
 */
export function useIsAdmin(): boolean {
  const { address, isConnected } = useAccount();
  if (!isConnected || !address) return false;
  return ADMIN_ADDRESSES.includes(address.toLowerCase());
}

/** The flat panel a stranger gets. Deliberately boring and data-free. */
function NothingHere({ children }: { children?: React.ReactNode }) {
  return (
    <div className="flex min-h-[60vh] items-center justify-center p-8">
      <div className="bull-card w-full max-w-md space-y-4 p-8 text-center">
        <div className="bull-header text-xl text-bull-text">nothing here</div>
        <p className="text-sm text-bull-text-dim">
          this page isn&rsquo;t for your wallet. head back to the yards.
        </p>
        {children}
        <Link href="/" className="block text-sm text-bull-gold hover:underline">
          back to the bulls
        </Link>
      </div>
    </div>
  );
}

/**
 * Rendered by the /admin Server Component whenever there is no valid session
 * cookie. Three faces:
 *   - no wallet connected → flat panel + connect button
 *   - wrong wallet        → flat panel, no hints, no sign button
 *   - allow-listed wallet → one "sign to unlock" button
 */
export function AdminSignIn() {
  const { address, isConnected } = useAccount();
  const { signMessageAsync, isPending: isSigning } = useSignMessage();
  const isListed = useIsAdmin();

  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const handleSign = useCallback(async () => {
    if (!address) return;
    setError(null);
    setBusy(true);
    try {
      setStatus('asking the server for a nonce…');
      const nonceRes = await fetch('/api/admin/nonce', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ address }),
        cache: 'no-store',
      });
      const nonceJson = (await nonceRes.json().catch(() => ({}))) as {
        ok?: boolean;
        message?: string;
        error?: string;
      };
      if (!nonceRes.ok || !nonceJson.ok || !nonceJson.message) {
        throw new Error(nonceJson.error ?? `nonce failed (${nonceRes.status})`);
      }

      setStatus('open your wallet and sign…');
      const signature = await signMessageAsync({ account: address, message: nonceJson.message });

      setStatus('checking the signature…');
      const verifyRes = await fetch('/api/admin/verify', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ address, signature }),
        cache: 'no-store',
      });
      const verifyJson = (await verifyRes.json().catch(() => ({}))) as { ok?: boolean; error?: string };
      if (!verifyRes.ok || !verifyJson.ok) {
        throw new Error(verifyJson.error ?? `rejected (${verifyRes.status})`);
      }

      setStatus('unlocked, loading the cockpit…');
      // Full navigation: re-runs the middleware, which now sees the session
      // cookie and serves the real /admin route instead of this one. Deliberately
      // NOT setBusy(false) first — leave the button disabled while the page goes.
      window.location.assign('/admin');
      return;
    } catch (e) {
      setError(e instanceof Error ? e.message : 'sign-in failed');
      setStatus(null);
      setBusy(false);
    }
  }, [address, signMessageAsync]);

  if (!isConnected) {
    return (
      <NothingHere>
        <div className="flex justify-center pt-2">
          <ConnectButton />
        </div>
      </NothingHere>
    );
  }

  // Connected, but not a wallet we'd ever admit. Same flat panel as a stranger.
  if (!isListed) return <NothingHere />;

  return (
    <div className="flex min-h-[60vh] items-center justify-center p-8">
      <div className="bull-card w-full max-w-md space-y-4 p-8">
        <div className="bull-header text-xl text-bull-text">locked</div>
        <p className="text-sm leading-relaxed text-bull-text-dim">
          sign a message to prove you hold this wallet&rsquo;s key. it isn&rsquo;t a transaction,
          nothing moves and nothing is approved.
        </p>
        <div className="break-all font-mono text-xs text-bull-text-faint">{address}</div>
        <button type="button" className="bull-btn w-full" onClick={handleSign} disabled={busy || isSigning}>
          {busy || isSigning ? 'waiting on your wallet…' : 'sign to unlock'}
        </button>
        {status && <div className="text-xs text-bull-text-dim">{status}</div>}
        {error && <div className="break-words text-xs text-bull-red">{error}</div>}
        <p className="text-[11px] leading-relaxed text-bull-text-faint">
          the unlock lasts 4 hours in this browser. it hides the cockpit, not the chain: every
          number in here is public state anyone can read from an rpc, and the contracts&rsquo;
          onlyOwner is what actually stops anyone else changing things.
        </p>
      </div>
    </div>
  );
}
