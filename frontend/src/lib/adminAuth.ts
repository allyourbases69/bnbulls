/**
 * Admin session auth — the signature-verified gate around /admin.
 *
 * Ported from the fighting fefers cockpit, adapted to bnbulls. The security
 * model is unchanged and MUST stay that way.
 *
 * WHAT THIS PROTECTS
 *   The cockpit UI at /admin and anything served from /api/admin/*. To get
 *   in you must (a) hold the private key for an allow-listed address and
 *   sign a fresh server-issued nonce, and (b) present the HMAC-signed
 *   session cookie the server hands back. Both checks run on the server,
 *   so editing the client bundle or React state does nothing.
 *
 * WHAT THIS DOES NOT PROTECT
 *   - It does NOT make the chain reads private. Every number the cockpit
 *     shows is public chain state that anyone can query straight from an
 *     RPC node. This hides the convenient control panel, not the data.
 *   - It is NOT what stops a stranger changing settings. The contracts'
 *     `onlyOwner` modifiers do that, and they would still revert a
 *     non-owner write even if this gate were removed entirely.
 *
 * FAIL CLOSED
 *   Every entry point here returns null / false when ADMIN_SESSION_SECRET
 *   is missing or too short. A misconfigured deploy denies everyone rather
 *   than letting everyone in.
 *
 * RUNTIME
 *   Web Crypto only (no node:crypto), so the same module is importable
 *   from the Edge middleware AND from Node API routes.
 *
 * ⚠ ENV TIMING. `src/middleware.ts` runs on the Edge runtime, and Next
 *   inlines `process.env.*` reads into the Edge bundle AT BUILD TIME for a
 *   self-hosted `next build && next start`. So ADMIN_SESSION_SECRET and
 *   ADMIN_ADDRESSES must be present when you BUILD, not just when you start.
 *   On Vercel this is a non-issue: env vars are injected into Edge functions
 *   at runtime. The Node-runtime API routes always read the live process env.
 *   Leaving the allow-list unset entirely sidesteps the issue, because the
 *   default is a code constant.
 */

/** Session cookie: proves a signature was verified for `addr`. */
export const ADMIN_SESSION_COOKIE = 'bn_admin_session';
/** Nonce cookie: binds a freshly issued nonce to this browser. */
export const ADMIN_NONCE_COOKIE = 'bn_admin_nonce';

/** How long a signed-in session lasts. Short on purpose. */
export const ADMIN_SESSION_MS = 4 * 60 * 60 * 1000; // 4h
/** How long an unspent nonce stays valid. */
export const ADMIN_NONCE_TTL_MS = 5 * 60 * 1000; // 5min
export const ADMIN_NONCE_BYTES = 24;

/** Fallback allow-list: the dev / deployer wallet. Same as fefers. */
export const DEFAULT_ADMIN_ADDRESS =
  '0x5b1A749cc7bF1dE8ecA505769BD34Ba65f456805';

export interface AdminNoncePayload {
  v: 1;
  kind: 'nonce';
  /** Hex nonce echoed back inside the signed message. */
  nonce: string;
  /** Host the nonce was issued for; the message names it, so it's bound. */
  domain: string;
  /** Issued-at, unix seconds. Also rendered into the message. */
  iat: number;
  /** Expiry, unix seconds. */
  exp: number;
}

export interface AdminSessionPayload {
  v: 1;
  kind: 'session';
  /** Lowercased address whose signature opened this session. */
  addr: string;
  iat: number;
  exp: number;
}

type AdminPayload = AdminNoncePayload | AdminSessionPayload;

/* ── base64url helpers (btoa/atob exist in Edge + Node ≥16) ───────── */

function base64urlEncodeBytes(bytes: Uint8Array): string {
  let str = '';
  for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i] ?? 0);
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64urlEncodeString(s: string): string {
  return base64urlEncodeBytes(new TextEncoder().encode(s));
}

function base64urlDecodeToString(s: string): string {
  const pad = '==='.slice(0, (4 - (s.length % 4)) % 4);
  return atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
}

function base64urlDecodeToBytes(s: string): Uint8Array {
  const bin = base64urlDecodeToString(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/* ── secret + allow-list ──────────────────────────────────────────── */

/**
 * The HMAC key for cookie signing. Server-only (no NEXT_PUBLIC_ prefix, so
 * Next never inlines it into the browser bundle).
 *
 * Returns null when unset or shorter than 32 chars — every caller treats
 * null as "deny", which is why a deploy that forgets the secret locks
 * everybody out instead of letting everybody in.
 */
export function getAdminSecret(): string | null {
  const raw = process.env.ADMIN_SESSION_SECRET;
  if (typeof raw !== 'string' || raw.length < 32) return null;
  return raw;
}

/** True when the secret is present and long enough. */
export function isAdminAuthConfigured(): boolean {
  return getAdminSecret() !== null;
}

function parseAddressList(raw: string | undefined): string[] {
  if (typeof raw !== 'string' || raw.trim() === '') return [];
  return raw
    .split(',')
    .map((a) => a.trim().toLowerCase())
    .filter((a) => /^0x[0-9a-f]{40}$/.test(a));
}

/**
 * The allow-list, lowercased. Second factor: a valid signature is not
 * enough, the recovered address must also be on this list.
 *
 * ADMIN_ADDRESSES (server-only) wins so the authoritative list can be kept
 * out of the client bundle; NEXT_PUBLIC_ADMIN_ADDRESSES is the fallback and
 * is what the client uses for the cosmetic "show the sign button" check.
 * Default is the dev wallet so the gate works with no env at all.
 */
export function getAdminAllowList(): readonly string[] {
  const server = parseAddressList(process.env.ADMIN_ADDRESSES);
  if (server.length > 0) return server;
  const pub = parseAddressList(process.env.NEXT_PUBLIC_ADMIN_ADDRESSES);
  if (pub.length > 0) return pub;
  return [DEFAULT_ADMIN_ADDRESS.toLowerCase()];
}

export function isAllowListed(address: string | null | undefined): boolean {
  if (typeof address !== 'string') return false;
  return getAdminAllowList().includes(address.toLowerCase());
}

/* ── HMAC ─────────────────────────────────────────────────────────── */

async function hmacSha256(keyString: string, data: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(keyString),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return new Uint8Array(sig);
}

/** Constant-time compare so a wrong signature leaks no timing information. */
function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

/**
 * `base64url(json) . base64url(hmac)`. The client sees an opaque blob it
 * cannot mint or edit — flipping a single byte of either half invalidates
 * the HMAC and the cookie is rejected.
 */
async function signPayload(payload: AdminPayload): Promise<string> {
  const secret = getAdminSecret();
  if (!secret) throw new Error('ADMIN_SESSION_SECRET not configured');
  const body = base64urlEncodeString(JSON.stringify(payload));
  return `${body}.${base64urlEncodeBytes(await hmacSha256(secret, body))}`;
}

async function verifyPayload(value: string | null | undefined): Promise<AdminPayload | null> {
  if (!value) return null;
  const secret = getAdminSecret();
  if (!secret) return null; // fail closed

  const parts = value.split('.');
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  if (!body || !sig) return null;

  let expected: Uint8Array;
  let provided: Uint8Array;
  try {
    expected = await hmacSha256(secret, body);
    provided = base64urlDecodeToBytes(sig);
  } catch {
    return null;
  }
  if (!timingSafeEqual(expected, provided)) return null;

  let parsed: AdminPayload;
  try {
    parsed = JSON.parse(base64urlDecodeToString(body)) as AdminPayload;
  } catch {
    return null;
  }
  if (parsed?.v !== 1) return null;
  if (typeof parsed.iat !== 'number' || typeof parsed.exp !== 'number') return null;
  if (parsed.exp <= Math.floor(Date.now() / 1000)) return null;
  return parsed;
}

/* ── nonce cookie ─────────────────────────────────────────────────── */

export function generateNonce(): string {
  const bytes = new Uint8Array(ADMIN_NONCE_BYTES);
  crypto.getRandomValues(bytes);
  let hex = '';
  for (let i = 0; i < bytes.length; i++) hex += (bytes[i] ?? 0).toString(16).padStart(2, '0');
  return hex;
}

export function signNonceCookie(payload: AdminNoncePayload): Promise<string> {
  return signPayload(payload);
}

export async function verifyNonceCookie(
  value: string | null | undefined,
): Promise<AdminNoncePayload | null> {
  const p = await verifyPayload(value);
  if (!p || p.kind !== 'nonce') return null; // `kind` stops slot-swapping
  if (typeof p.nonce !== 'string' || !/^[0-9a-f]{32,96}$/.test(p.nonce)) return null;
  if (typeof p.domain !== 'string') return null;
  return p;
}

/* ── session cookie ───────────────────────────────────────────────── */

export function signSessionCookie(payload: AdminSessionPayload): Promise<string> {
  return signPayload(payload);
}

/**
 * Returns the verified session payload or null. Callers must ALSO re-check
 * `isAllowListed(payload.addr)` — the address is baked into the signed
 * payload so an old cookie can't be replayed for a different wallet, and
 * re-checking means removing a wallet from the allow-list kills its live
 * sessions immediately rather than at expiry.
 */
export async function verifySessionCookie(
  value: string | null | undefined,
): Promise<AdminSessionPayload | null> {
  const p = await verifyPayload(value);
  if (!p || p.kind !== 'session') return null;
  if (typeof p.addr !== 'string' || !/^0x[0-9a-f]{40}$/.test(p.addr)) return null;
  return p;
}

/** One call for the two things every server-side check needs to know. */
export async function readAdminSession(
  cookieValue: string | null | undefined,
): Promise<AdminSessionPayload | null> {
  const payload = await verifySessionCookie(cookieValue);
  if (!payload) return null;
  if (!isAllowListed(payload.addr)) return null;
  return payload;
}

/* ── the message the wallet is asked to sign ──────────────────────── */

/**
 * Built identically on client and server; the server rebuilds it from the
 * nonce cookie it issued, so the client cannot smuggle in different terms.
 * Deliberately plain english — whoever reads the wallet prompt should be
 * able to tell exactly what they are authorising, and that it isn't a
 * transaction.
 */
export function buildAdminMessage(args: {
  address: string;
  domain: string;
  nonce: string;
  issuedAt: number;
}): string {
  return [
    'bnbulls admin access',
    '',
    `wallet: ${args.address.toLowerCase()}`,
    `domain: ${args.domain}`,
    `nonce: ${args.nonce}`,
    `issued: ${new Date(args.issuedAt * 1000).toISOString()}`,
    '',
    'signing this proves you hold this wallet, and unlocks the /admin',
    'cockpit in this browser for 4 hours.',
    'it is not a transaction: nothing is sent, spent or approved.',
  ].join('\n');
}

/* ── Set-Cookie builders ──────────────────────────────────────────── */

/**
 * HttpOnly (JS can't read or forge it), SameSite=Strict (never sent on a
 * cross-site navigation, so no CSRF into the cockpit), Secure in prod
 * (omitted locally so http://localhost dev still works).
 */
function buildCookie(name: string, value: string, maxAgeSeconds: number): string {
  const parts = [
    `${name}=${value}`,
    'Path=/',
    'HttpOnly',
    'SameSite=Strict',
    `Max-Age=${Math.max(0, Math.floor(maxAgeSeconds))}`,
  ];
  if (process.env.NODE_ENV === 'production') parts.push('Secure');
  return parts.join('; ');
}

export function buildSessionCookieHeader(value: string, maxAgeSeconds: number): string {
  return buildCookie(ADMIN_SESSION_COOKIE, value, maxAgeSeconds);
}

export function buildClearSessionCookieHeader(): string {
  return buildCookie(ADMIN_SESSION_COOKIE, '', 0);
}

export function buildNonceCookieHeader(value: string, maxAgeSeconds: number): string {
  return buildCookie(ADMIN_NONCE_COOKIE, value, maxAgeSeconds);
}

/** Nonces are single-use: cleared on both success and failure. */
export function buildClearNonceCookieHeader(): string {
  return buildCookie(ADMIN_NONCE_COOKIE, '', 0);
}

/** Host for the signed message. Falls back to the configured site host. */
export function requestDomain(req: Request): string {
  const host = req.headers.get('host');
  if (host && /^[a-zA-Z0-9.\-:[\]]+$/.test(host)) return host;
  return 'bnbulls.xyz';
}
