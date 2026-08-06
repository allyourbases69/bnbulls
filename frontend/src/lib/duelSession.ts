/**
 * The duel session — one `personal_sign` message, good for a day.
 *
 * ⚠ THE TRAP THIS FILE EXISTS TO AVOID. The session is a SIGNED MESSAGE, not a
 * transaction: nothing is sent, spent or approved. The server verifies the
 * signature over EXACTLY the string it was handed and then re-reads the terms
 * out of that same string, so a client can never claim terms it did not sign.
 * That only works if both sides build the message identically, byte for byte —
 * so `buildSessionMessage` lives HERE, is imported by the client component AND
 * by `/api/run-duel`, and is never duplicated. A stray character on either side
 * fails as `malformed`, which reads exactly like a bad signature and is not.
 *
 * The second half of the same trap is the POST shape. `/api/run-duel` wants
 * THREE fields — `{ address, message, signature }`. Omitting `address` 401s
 * with "sign in", which also reads like a bad signature and also is not: the
 * server needs the claimed wallet to check the message's `wallet:` line and to
 * verify through the chain (so ERC-1271 smart-contract wallets work, not just
 * EOAs). Send all three, always.
 *
 * Ported from Fighting Fefers `lib/duelCommit.ts` (the session half). The
 * message TEXT is rewritten for bnbulls — it has to be, it names the game and
 * describes what it authorises — and the prefix check below is what makes a
 * fefers session unusable here.
 */

/**
 * How long one signature keeps the fight endpoint open. A day, because the
 * point of the session is that the honest player signs ONCE and then fights
 * with a single tap; asking per fight would add a wallet prompt to every fight
 * for no extra security (the anti-grind slot is pinned to the WALLET, not to
 * the signature — see `duelCommit.ts`).
 */
export const SESSION_TTL_SECONDS = 24 * 60 * 60;

/** Tolerance for clock skew between the player's browser and the server. */
export const SESSION_CLOCK_SKEW_SECONDS = 5 * 60;

/** First line of the message. Also the prefix guard — a session signed for
 *  another game (or another fork of this one) cannot be spent here. */
export const SESSION_HEADING = 'bnbulls — duel session';

export interface SessionMessageFields {
  /** Lowercased wallet the session belongs to. */
  wallet: string;
  chainId: number;
  domain: string;
  /** Unix seconds. */
  issued: number;
  /** Unix seconds. */
  expires: number;
}

/**
 * The exact text the wallet is asked to sign.
 *
 * Deliberately plain English. Whoever reads the wallet prompt should be able to
 * tell what they are authorising and that it is not a transaction.
 */
export function buildSessionMessage(f: SessionMessageFields): string {
  return [
    SESSION_HEADING,
    '',
    `wallet: ${f.wallet.toLowerCase()}`,
    `chain: ${f.chainId}`,
    `domain: ${f.domain}`,
    `issued: ${new Date(f.issued * 1000).toISOString()}`,
    `expires: ${new Date(f.expires * 1000).toISOString()}`,
    '',
    'signing this lets the game pin one standing fight to your wallet, so',
    'nobody can roll fights until they find a win and drop the rest. it',
    'lasts 24 hours and you only sign it once.',
    'it is not a transaction: nothing is sent, spent or approved.',
  ].join('\n');
}

function readField(message: string, key: string): string | null {
  for (const line of message.split('\n')) {
    if (line.startsWith(`${key}: `)) return line.slice(key.length + 2).trim();
  }
  return null;
}

/**
 * Pull the terms back out of a signed message. Returns null on anything that
 * doesn't look exactly like `buildSessionMessage` output — we never guess.
 */
export function parseSessionMessage(message: string): SessionMessageFields | null {
  if (typeof message !== 'string' || message.length > 2000) return null;
  if (!message.startsWith(SESSION_HEADING)) return null;

  const wallet = readField(message, 'wallet');
  const chainRaw = readField(message, 'chain');
  const domain = readField(message, 'domain');
  const issuedRaw = readField(message, 'issued');
  const expiresRaw = readField(message, 'expires');
  if (!wallet || !chainRaw || !domain || !issuedRaw || !expiresRaw) return null;
  if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) return null;

  const chainId = Number(chainRaw);
  if (!Number.isInteger(chainId) || chainId < 1) return null;

  const issued = Math.floor(Date.parse(issuedRaw) / 1000);
  const expires = Math.floor(Date.parse(expiresRaw) / 1000);
  if (!Number.isFinite(issued) || !Number.isFinite(expires)) return null;

  return { wallet: wallet.toLowerCase(), chainId, domain, issued, expires };
}

export type SessionRejection =
  | 'malformed'
  | 'wrong-wallet'
  | 'wrong-chain'
  | 'wrong-domain'
  | 'expired'
  | 'not-yet-valid'
  | 'ttl-too-long';

/**
 * Everything about a session that can be checked WITHOUT recovering the
 * signature (that part needs viem and lives in the route). Split out so the
 * terms logic is testable on its own.
 *
 * @returns null when the terms are good, otherwise why they aren't.
 */
export function checkSessionTerms(args: {
  message: string;
  claimedWallet: string;
  chainId: number;
  /** Host the request actually arrived on. Null skips the domain binding. */
  domain: string | null;
  now: number;
}): SessionRejection | null {
  const f = parseSessionMessage(args.message);
  if (!f) return 'malformed';
  if (f.wallet !== args.claimedWallet.toLowerCase()) return 'wrong-wallet';
  if (f.chainId !== args.chainId) return 'wrong-chain';
  if (args.domain !== null && f.domain !== args.domain) return 'wrong-domain';
  if (f.expires - f.issued > SESSION_TTL_SECONDS) return 'ttl-too-long';
  if (f.issued > args.now + SESSION_CLOCK_SKEW_SECONDS) return 'not-yet-valid';
  if (f.expires <= args.now) return 'expired';
  return null;
}

/** Player-facing text for each way a session can fail its terms check. */
export const SESSION_ERROR: Record<SessionRejection | 'bad-signature', string> = {
  malformed: "that isn't a bnbulls duel session message. sign in again.",
  'wrong-wallet': 'that session belongs to a different wallet. sign in again.',
  'wrong-chain': 'that session was signed for a different network. sign in again.',
  'wrong-domain': 'that session was signed for a different site. sign in again.',
  expired: 'your duel session has run out. sign in again.',
  'not-yet-valid': "that session is dated in the future — check your device's clock.",
  'ttl-too-long': 'that session asks for longer than 24 hours. sign in again.',
  'bad-signature': 'that session signature does not match the wallet it claims. sign in again.',
};
