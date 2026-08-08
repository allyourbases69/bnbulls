/**
 * GET /api/admin/session — "am I signed in?" for the client UI.
 *
 * Returns only what the browser already knows (its own address) plus an expiry.
 * It never reveals the allow-list, and never says WHY a session is absent, so an
 * unauthenticated probe learns nothing.
 *
 * This endpoint is advisory: nothing renders or is served on the strength of
 * its answer. The page's own server-side check and the middleware are the gate.
 */
import { cookies } from 'next/headers';
import { ADMIN_SESSION_COOKIE, readAdminSession } from '@/lib/adminAuth';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  const jar = await cookies();
  const payload = await readAdminSession(jar.get(ADMIN_SESSION_COOKIE)?.value);
  if (!payload) {
    return Response.json({ ok: true, authed: false }, { headers: { 'cache-control': 'no-store' } });
  }
  return Response.json(
    { ok: true, authed: true, addr: payload.addr, expiresAt: payload.exp },
    { headers: { 'cache-control': 'no-store' } },
  );
}
