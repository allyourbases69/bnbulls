/**
 * POST /api/admin/nonce — issue a single-use login nonce.
 *
 * The nonce is not stored server-side. It is put in an HMAC-signed, HttpOnly
 * cookie, which binds it to THIS browser: the signature posted to
 * /api/admin/verify is only accepted alongside the cookie that carries the
 * matching nonce, and the cookie is cleared the moment it's spent. That gives
 * single-use semantics without a database.
 *
 * The response also returns the exact message to sign. The server does not
 * trust it — /api/admin/verify rebuilds the message from its own cookie — it's
 * returned so the wallet prompt and the server agree byte for byte.
 */
import {
  ADMIN_NONCE_TTL_MS,
  buildAdminMessage,
  buildNonceCookieHeader,
  generateNonce,
  isAdminAuthConfigured,
  requestDomain,
  signNonceCookie,
} from '@/lib/adminAuth';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  // Fail closed. No secret means no cookie can be signed, so there is no point
  // issuing a nonce — and we say so plainly rather than 500ing.
  if (!isAdminAuthConfigured()) {
    return Response.json(
      { ok: false, error: 'ADMIN_SESSION_SECRET is not configured on the server' },
      { status: 503 },
    );
  }

  let body: { address?: string };
  try {
    body = (await req.json()) as { address?: string };
  } catch {
    body = {};
  }

  const address = typeof body.address === 'string' ? body.address.toLowerCase() : '';
  if (!/^0x[0-9a-f]{40}$/.test(address)) {
    return Response.json({ ok: false, error: 'missing or invalid address' }, { status: 400 });
  }

  // NOTE: no allow-list check here, deliberately — a stranger probing this
  // endpoint learns nothing about who is allowed in. The allow-list is enforced
  // in /api/admin/verify, after the signature.

  const nonce = generateNonce();
  const domain = requestDomain(req);
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + Math.floor(ADMIN_NONCE_TTL_MS / 1000);

  const cookie = await signNonceCookie({ v: 1, kind: 'nonce', nonce, domain, iat, exp });
  const message = buildAdminMessage({ address, domain, nonce, issuedAt: iat });

  return new Response(JSON.stringify({ ok: true, message, expiresAt: exp }), {
    status: 200,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      'set-cookie': buildNonceCookieHeader(cookie, Math.floor(ADMIN_NONCE_TTL_MS / 1000)),
    },
  });
}
