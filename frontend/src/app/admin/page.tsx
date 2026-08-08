/**
 * /admin — the operator cockpit. Only ever reached WITH a valid session.
 *
 * Two things keep it that way, both server-side:
 *   1. `src/middleware.ts` verifies the HMAC-signed session cookie before this
 *      route is reached and REWRITES unauthenticated requests to /admin/locked.
 *      That rewrite is what stops the cockpit's client chunk being downloaded by
 *      strangers: they receive a different route's bundle entirely.
 *   2. This file re-checks the same cookie anyway and 404s if it's absent —
 *      belt and braces, if the middleware were ever bypassed or its matcher
 *      edited.
 *
 * The cookie is only ever issued by POST /api/admin/verify, which requires a
 * wallet signature over a fresh server-issued nonce. So seeing this page means
 * holding the key.
 *
 * BE HONEST ABOUT THE SCOPE:
 *   - Protects: this UI, and any server data served behind /api/admin/*.
 *   - Does NOT protect the chain data. Everything the cockpit displays is public
 *     state anyone can read straight from an RPC node.
 *   - Does NOT stop anyone changing settings. The contracts' `onlyOwner` does
 *     that, and would still do it with this gate deleted.
 *
 * Calling `cookies()` makes this route dynamic, so it is never prerendered with
 * somebody's session baked in.
 */
import type { Metadata } from 'next';
import { cookies } from 'next/headers';
import { notFound } from 'next/navigation';
import { ADMIN_SESSION_COOKIE, readAdminSession } from '@/lib/adminAuth';
import { AdminCockpit } from '@/components/admin/AdminCockpit';

export const dynamic = 'force-dynamic';

// Unlisted route: no nav link anywhere, and no reason for a crawler to hold it.
export const metadata: Metadata = {
  title: 'nothing here',
  robots: { index: false, follow: false, nocache: true },
};

export default async function AdminPage() {
  const jar = await cookies();
  const session = await readAdminSession(jar.get(ADMIN_SESSION_COOKIE)?.value);

  // Should be unreachable (middleware rewrote already). If it ever isn't, a
  // plain 404 is the right answer — no panel, no hint, no cockpit.
  if (!session) notFound();

  return <AdminCockpit sessionAddress={session.addr} expiresAt={session.exp} />;
}
