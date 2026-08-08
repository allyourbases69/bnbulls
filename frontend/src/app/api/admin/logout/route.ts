/**
 * POST /api/admin/logout — the "lock" control. Clears the session cookie.
 *
 * Unconditional: there is nothing to authorise about throwing away your own
 * session. Also clears any half-finished nonce.
 *
 * POST only. A GET here would let any <img src> on the internet log the owner
 * out; harmless, but pointless to allow.
 */
import { buildClearNonceCookieHeader, buildClearSessionCookieHeader } from '@/lib/adminAuth';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST() {
  const headers = new Headers({
    'content-type': 'application/json',
    'cache-control': 'no-store',
  });
  headers.append('set-cookie', buildClearSessionCookieHeader());
  headers.append('set-cookie', buildClearNonceCookieHeader());
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
}
