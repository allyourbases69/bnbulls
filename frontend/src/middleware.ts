/**
 * Edge middleware: gates the operator cockpit (/admin) and its api (/api/admin).
 *
 * Two server-side layers protect the cockpit, and this is layer 1:
 *   1. THIS middleware verifies the signed session cookie. /api/admin/* without
 *      one gets a 401 (except the four auth endpoints, which are how you obtain
 *      the cookie in the first place). /admin page requests without one get
 *      REWRITTEN to /admin/locked.
 *   2. `src/app/admin/page.tsx` re-checks the same cookie server-side and 404s
 *      if it's missing, so the cockpit still refuses to render even if this
 *      middleware were bypassed or its matcher edited.
 *
 * WHY A REWRITE AND NOT A CONDITIONAL RENDER: a route boundary is also a bundle
 * boundary. Rendering the lock screen from inside /admin would ship the
 * cockpit's client chunk to every visitor — the bundler follows the import
 * whether or not the component renders. Rewriting to a separate route means
 * strangers download that route's bundle and never receive the cockpit's code
 * at all. The URL stays /admin.
 *
 * Honest scope: this protects the cockpit UI and anything served from
 * /api/admin/*. It does not make the chain reads private (all public state
 * anyone can query from an RPC), and it is NOT what stops a stranger changing
 * settings — `onlyOwner` on the contracts does that.
 *
 * Uses Web Crypto via the cookie helpers so it runs on the Edge runtime.
 */
import { NextResponse, type NextRequest } from 'next/server';
import { ADMIN_SESSION_COOKIE, readAdminSession } from '@/lib/adminAuth';

export const config = {
  matcher: ['/admin', '/admin/:path*', '/api/admin/:path*'],
};

// The four /api/admin endpoints that ARE the sign-in flow. Every other
// /api/admin/* route needs the session cookie — including any added later,
// because this is an allow-list, not a block-list.
const PUBLIC_ADMIN_API_PATHS = new Set([
  '/api/admin/nonce',
  '/api/admin/verify',
  '/api/admin/session',
  '/api/admin/logout',
]);

/** The lock screen /admin is rewritten to when there's no valid session. */
const ADMIN_LOCKED_PATH = '/admin/locked';

const NOINDEX = 'noindex, nofollow, noarchive, nosnippet';

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;

  // Always no-index the gated surface, protected or not.
  const makeResponse = (base?: NextResponse) => {
    const res = base ?? NextResponse.next();
    res.headers.set('x-robots-tag', NOINDEX);
    return res;
  };

  if (PUBLIC_ADMIN_API_PATHS.has(pathname)) return makeResponse();

  // The lock screen itself must stay reachable — it IS the sign-in UI. It
  // renders no data.
  if (pathname === ADMIN_LOCKED_PATH) return makeResponse();

  // readAdminSession = valid HMAC + unexpired + address STILL on the allow-list.
  // Returns null when ADMIN_SESSION_SECRET is unset, i.e. a misconfigured deploy
  // denies everyone rather than admitting them.
  const admin = await readAdminSession(req.cookies.get(ADMIN_SESSION_COOKIE)?.value ?? null);
  if (admin) return makeResponse();

  if (pathname.startsWith('/api/admin')) {
    return new NextResponse(JSON.stringify({ ok: false, error: 'unauthenticated' }), {
      status: 401,
      headers: { 'content-type': 'application/json', 'x-robots-tag': NOINDEX },
    });
  }

  // Page route, no session: serve the lock screen's bundle under the /admin URL.
  const url = req.nextUrl.clone();
  url.pathname = ADMIN_LOCKED_PATH;
  return makeResponse(NextResponse.rewrite(url));
}
