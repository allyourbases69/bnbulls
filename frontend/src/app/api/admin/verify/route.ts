/**
 * POST /api/admin/verify — body { address, signature }.
 *
 * The whole gate, in order:
 *   1. Read the HMAC-signed nonce cookie this server issued. No cookie, a
 *      forged one, or an expired one → reject. The client cannot supply its
 *      own nonce.
 *   2. Rebuild the exact message from the SERVER's copy of the nonce, domain
 *      and issued-at, plus the claimed address. The client's idea of what it
 *      signed is never used.
 *   3. viem `verifyMessage` server-side: does that signature really come from
 *      that address? (Handles EOA personal_sign and EIP-1271 wallets.)
 *   4. Second factor: is the address on the allow-list?
 *   5. Only then, mint the session cookie — HMAC-signed, HttpOnly,
 *      SameSite=Strict, 4h — with the address inside the signed payload so it
 *      can't be replayed as a different wallet.
 *
 * The nonce cookie is cleared on every outcome, so a nonce is genuinely
 * single-use and can't be ground against.
 *
 * Honest scope: passing this proves key ownership and opens the cockpit UI. It
 * grants no on-chain authority whatsoever — the contracts' `onlyOwner` is what
 * actually decides whether a write lands.
 */
import { verifyMessage } from 'viem';
import {
  ADMIN_NONCE_COOKIE,
  ADMIN_SESSION_MS,
  buildAdminMessage,
  buildClearNonceCookieHeader,
  buildSessionCookieHeader,
  isAdminAuthConfigured,
  isAllowListed,
  requestDomain,
  signSessionCookie,
  verifyNonceCookie,
} from '@/lib/adminAuth';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Nonces already spent on this server instance, nonce → expiry ms.
 *
 * Clearing the cookie makes a nonce single-use for a browser that plays by the
 * rules. This Map makes it single-use even for something replaying a captured
 * cookie+signature pair by hand.
 *
 * HONEST LIMIT: this is process memory. On a serverless platform a replay that
 * lands on a different instance won't see it, so the real backstop there is the
 * 5-minute nonce TTL plus the fact that the nonce cookie is HttpOnly and
 * travels over TLS. A DB-backed nonce table would close the gap fully; it was
 * skipped so an outage can't lock the owner out of his own cockpit.
 */
const spentNonces = new Map<string, number>();

function isSpent(nonce: string): boolean {
  const now = Date.now();
  if (spentNonces.size > 256) {
    for (const [k, exp] of spentNonces) if (exp <= now) spentNonces.delete(k);
  }
  const exp = spentNonces.get(nonce);
  if (exp === undefined) return false;
  if (exp <= now) {
    spentNonces.delete(nonce);
    return false;
  }
  return true;
}

function markSpent(nonce: string, expUnixSeconds: number): void {
  spentNonces.set(nonce, expUnixSeconds * 1000);
}

/** Every failure looks the same to the caller and always burns the nonce. */
function deny(error: string, status = 401): Response {
  return new Response(JSON.stringify({ ok: false, error }), {
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      'set-cookie': buildClearNonceCookieHeader(),
    },
  });
}

function readCookie(req: Request, name: string): string | null {
  const header = req.headers.get('cookie');
  if (!header) return null;
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq === -1) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}

export async function POST(req: Request) {
  if (!isAdminAuthConfigured()) {
    return deny('ADMIN_SESSION_SECRET is not configured on the server', 503);
  }

  let body: { address?: string; signature?: string };
  try {
    body = (await req.json()) as { address?: string; signature?: string };
  } catch {
    return deny('invalid JSON body', 400);
  }

  const address = typeof body.address === 'string' ? body.address.toLowerCase() : '';
  const signature = typeof body.signature === 'string' ? body.signature : '';
  if (!/^0x[0-9a-f]{40}$/.test(address)) return deny('missing or invalid address', 400);
  if (!/^0x[0-9a-fA-F]+$/.test(signature)) return deny('missing or invalid signature', 400);

  // (1) the nonce must be one WE issued to THIS browser, unexpired.
  const nonceCookie = await verifyNonceCookie(readCookie(req, ADMIN_NONCE_COOKIE));
  if (!nonceCookie) return deny('nonce missing, expired or already used');

  // Single use, enforced rather than merely encouraged.
  if (isSpent(nonceCookie.nonce)) return deny('nonce already used');
  markSpent(nonceCookie.nonce, nonceCookie.exp);

  // The nonce was issued for a host; refuse to honour it on another one.
  if (nonceCookie.domain !== requestDomain(req)) return deny('nonce domain mismatch');

  // (2) rebuild the message from server-held facts only.
  const message = buildAdminMessage({
    address,
    domain: nonceCookie.domain,
    nonce: nonceCookie.nonce,
    issuedAt: nonceCookie.iat,
  });

  // (3) does the signature actually come from that key?
  let valid = false;
  try {
    valid = await verifyMessage({
      address: address as `0x${string}`,
      message,
      signature: signature as `0x${string}`,
    });
  } catch {
    return deny('signature verification failed');
  }
  if (!valid) return deny('signature does not match that address');

  // (4) second factor: signature alone isn't enough.
  if (!isAllowListed(address)) return deny('that wallet is not on the admin allow-list');

  // (5) mint the session.
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + Math.floor(ADMIN_SESSION_MS / 1000);
  const session = await signSessionCookie({ v: 1, kind: 'session', addr: address, iat, exp });

  const headers = new Headers({
    'content-type': 'application/json',
    'cache-control': 'no-store',
  });
  headers.append('set-cookie', buildClearNonceCookieHeader());
  headers.append('set-cookie', buildSessionCookieHeader(session, Math.floor(ADMIN_SESSION_MS / 1000)));

  return new Response(JSON.stringify({ ok: true, addr: address, expiresAt: exp }), {
    status: 200,
    headers,
  });
}
