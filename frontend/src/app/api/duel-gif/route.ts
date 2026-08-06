/**
 * GET /api/duel-gif?tx=0x…
 *
 * The shareable replay of a settled fight, as an animated GIF.
 *
 * ⚠ THIS IS THE ONLY PLACE A REPLAY IS RENDERED, and that is a decision, not an
 * accident. `BNBULLS-BOOTSTRAP.md §5` says it plainly: the on-site replay and
 * the Telegram card come from ONE route, because two renderers drift and the
 * day they disagree is the day the site and the group chat show two different
 * winners for the same fight. The Telegram duel-bot fetches from here rather
 * than rendering locally.
 *
 * Query:
 *   tx     required, the transaction that settled the duel
 *   log    optional log index, for a tx that settled more than one fight
 *   scale  optional integer upscale, 1-8, default 4
 *
 * A settled duel is immutable, and so is its replay, so responses carry a
 * one-year immutable cache header and the CDN answers almost every hit. The
 * in-process cache below only absorbs a burst on a cold instance — the bot, a
 * browser and a retry all asking within a second of each other.
 *
 * ⚠ IT ANSWERS 409, NOT A PICTURE, when the re-simulated fight does not match
 * what the chain recorded. See `lib/duelReplaySource.ts`: a replay that
 * contradicts the on-chain result would be a lie about somebody's money, and
 * "no replay for this one" is the only honest failure.
 */
import { NextResponse } from 'next/server';
import { replayInputFromChain } from '@/lib/duelReplaySource';
import { renderDuelReplayGif } from '@/lib/duelReplay';

// `simulateFight` and the encoder are pure CPU, but viem's http transport and
// the buffer work want node. Edge would also cap the CPU budget lower than a
// hundred-frame slugfest can need.
export const runtime = 'nodejs';

const DEFAULT_SCALE = 4;
const MAX_SCALE = 8;

// Rate limit: same shape as `/api/run-duel`. Per-instance and therefore
// best-effort — it exists so one caller cannot pin an instance's CPU rendering
// the same fight over and over, not as a hard quota.
const RL_WINDOW_MS = 60_000;
const RL_MAX = 40;
const rlHits = new Map<string, { count: number; resetAt: number }>();
function rateLimited(ip: string): boolean {
  const now = Date.now();
  const e = rlHits.get(ip);
  if (!e || now > e.resetAt) {
    rlHits.set(ip, { count: 1, resetAt: now + RL_WINDOW_MS });
    return false;
  }
  e.count += 1;
  return e.count > RL_MAX;
}

/** Tiny bounded cache. Insertion-ordered Map, oldest evicted first. */
const CACHE_MAX = 12;
const cache = new Map<string, Uint8Array>();
function cached(key: string): Uint8Array | undefined {
  const hit = cache.get(key);
  if (hit) {
    // Re-insert so a hot fight is the last thing evicted.
    cache.delete(key);
    cache.set(key, hit);
  }
  return hit;
}
function remember(key: string, bytes: Uint8Array): void {
  cache.set(key, bytes);
  while (cache.size > CACHE_MAX) {
    const oldest = cache.keys().next().value;
    if (oldest === undefined) break;
    cache.delete(oldest);
  }
}

const STATUS: Record<string, number> = {
  config: 503,
  'not-found': 404,
  'no-duel': 404,
  rpc: 503,
  // The one that matters: the replay and the chain disagree, so there is no
  // honest picture to serve.
  mismatch: 409,
};

export async function GET(request: Request) {
  const ip =
    request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    request.headers.get('x-real-ip') ||
    'unknown';
  if (rateLimited(ip)) {
    return NextResponse.json({ error: 'too many requests, slow down.' }, { status: 429 });
  }

  const url = new URL(request.url);
  const tx = (url.searchParams.get('tx') || '').trim().toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(tx)) {
    return NextResponse.json({ error: 'tx must be a 32-byte transaction hash' }, { status: 400 });
  }

  const rawLog = url.searchParams.get('log');
  let logIndex: number | null = null;
  if (rawLog !== null && rawLog !== '') {
    logIndex = Number(rawLog);
    if (!Number.isInteger(logIndex) || logIndex < 0) {
      return NextResponse.json({ error: 'log must be a non-negative integer' }, { status: 400 });
    }
  }

  const rawScale = url.searchParams.get('scale');
  let scale = DEFAULT_SCALE;
  if (rawScale) {
    scale = Number(rawScale);
    if (!Number.isInteger(scale) || scale < 1 || scale > MAX_SCALE) {
      return NextResponse.json(
        { error: `scale must be an integer 1-${MAX_SCALE}` },
        { status: 400 },
      );
    }
  }

  const key = `${tx}:${logIndex ?? 'first'}:${scale}`;
  const hit = cached(key);
  if (hit) return gifResponse(hit, tx, true);

  const src = await replayInputFromChain({ txHash: tx as `0x${string}`, logIndex });
  if (!src.ok) {
    return NextResponse.json(
      { error: src.detail, reason: src.reason },
      { status: STATUS[src.reason] ?? 500 },
    );
  }

  let bytes: Uint8Array;
  try {
    bytes = renderDuelReplayGif(src.input, scale).gif;
  } catch (e) {
    // A throw here is a bug in the compositor or the encoder, not a bad request.
    return NextResponse.json(
      { error: e instanceof Error ? e.message : String(e), reason: 'render' },
      { status: 500 },
    );
  }

  remember(key, bytes);
  return gifResponse(bytes, tx, false);
}

function gifResponse(bytes: Uint8Array, tx: string, fromCache: boolean): Response {
  // Uint8Array -> a fresh ArrayBuffer, so a subarray view can never leak the
  // rest of the buffer it was cut from.
  const body = bytes.slice().buffer as ArrayBuffer;
  return new Response(body, {
    status: 200,
    headers: {
      'Content-Type': 'image/gif',
      'Content-Length': String(bytes.length),
      'Content-Disposition': `inline; filename="bnbulls-duel-${tx.slice(2, 12)}.gif"`,
      // A settled duel cannot change, so this is safe to cache forever, and
      // caching it forever is what keeps the render cost near zero.
      'Cache-Control': 'public, max-age=31536000, immutable',
      'X-Replay-Cache': fromCache ? 'hit' : 'miss',
    },
  });
}
