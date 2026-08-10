/**
 * SERVER-SIDE READ CACHE for the archive routes.
 *
 * ⚠ SERVER ONLY. Reads `KV_REST_API_*` / `UPSTASH_REDIS_REST_*`, which are
 * credentials and carry no `NEXT_PUBLIC_` prefix — that prefix is the only thing
 * deciding whether Next inlines a variable into the browser bundle. Import this
 * from route handlers pinned to `runtime = 'nodejs'` and nowhere else.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY A CACHE IS PART OF THE FEATURE AND NOT AN OPTIMISATION
 * ═══════════════════════════════════════════════════════════════════════
 *
 * `/pots` and `/history` are public pages, and behind them sits a keyed archive
 * api with a daily call budget. One uncached page view is one call; a page that
 * gets shared once is a page that spends the budget in an afternoon and then
 * shows every visitor "we could not read the chain" for the rest of the day. So
 * every archive route reads through here:
 *
 *   1. process memory   free, per-instance, survives until the lambda recycles
 *   2. the shared kv    one read serves every instance and every region
 *   3. the archive api  the only leg that costs anything
 *
 * with a cdn window on top (set by the caller's own `Cache-Control`) that
 * absorbs the crowd before any of this is reached.
 *
 * ⚠ A FAILED REFRESH FALLS BACK TO AN OLD ANSWER, NEVER TO AN EMPTY ONE. Every
 * payload carries `fetchedAt` and every page prints it, so a slightly stale
 * record is LABELLED as old rather than passed off as live — and an empty list
 * never gets to stand in for a read that failed. That distinction is the whole
 * point of these routes; see `lib/serverLogs.ts`.
 *
 * ⚠ CACHE FAILURES ARE SWALLOWED ON PURPOSE. A kv that cannot be reached must
 * degrade to a slower page, never to a 500 on a page about money.
 */

/** Anything cached here is a payload that knows when it was read. */
export interface Cacheable {
  readonly fetchedAt: number;
}

export type CachedResult<T> =
  | { readonly ok: true; readonly payload: T }
  | { readonly ok: false; readonly detail: string };

/**
 * Per-instance memory. Deliberately unbounded: the keys are one per route per
 * contract address, a handful in total, not one per visitor.
 */
const memory = new Map<string, Cacheable>();

function kv(): { url: string; token: string } | null {
  const url = process.env.KV_REST_API_URL ?? process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN ?? process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? { url, token } : null;
}

/** One POST per command, the same REST framing `lib/commitStoreRest.ts` uses. */
async function kvCommand(cmd: (string | number)[]): Promise<unknown> {
  const conn = kv();
  if (!conn) return null;
  const res = await fetch(conn.url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${conn.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(cmd),
    cache: 'no-store',
  });
  if (!res.ok) throw new Error(`kv ${cmd[0]} HTTP ${res.status}`);
  const body = (await res.json()) as { result?: unknown; error?: string };
  if (typeof body.error === 'string') throw new Error(`kv ${cmd[0]}: ${body.error}`);
  return body.result ?? null;
}

async function kvGet<T extends Cacheable>(key: string): Promise<T | null> {
  try {
    const raw = await kvCommand(['GET', key]);
    if (typeof raw !== 'string') return null;
    const parsed = JSON.parse(raw) as T;
    return typeof parsed?.fetchedAt === 'number' ? parsed : null;
  } catch {
    return null;
  }
}

async function kvPut<T extends Cacheable>(key: string, payload: T, ttlMs: number): Promise<void> {
  try {
    await kvCommand(['SET', key, JSON.stringify(payload), 'EX', Math.ceil(ttlMs / 1000)]);
  } catch {
    /* a cache that cannot write is still a page that renders */
  }
}

/**
 * Read through memory, then the shared cache, then `build()`.
 *
 * `staleRescueMs` is how long a cached answer may still be served AFTER a
 * refresh has failed. Serving a slightly old record beats serving nothing, but
 * only for a while — past the rescue window the caller gets a refusal and says
 * so, because a record from an hour ago presented as current is its own lie.
 *
 * Never throws. `ok: false` carries the reason so the route can log it and
 * answer with a 502 that a page can turn into "we could not read the chain".
 */
export async function cachedPayload<T extends Cacheable>(opts: {
  readonly key: string;
  readonly ttlMs: number;
  readonly staleRescueMs: number;
  readonly build: () => Promise<T>;
}): Promise<CachedResult<T>> {
  const now = Date.now();

  const hot = memory.get(opts.key) as T | undefined;
  if (hot && now - hot.fetchedAt < opts.ttlMs) return { ok: true, payload: hot };

  const shared = await kvGet<T>(opts.key);
  if (shared && now - shared.fetchedAt < opts.ttlMs) {
    memory.set(opts.key, shared);
    return { ok: true, payload: shared };
  }

  try {
    const payload = await opts.build();
    memory.set(opts.key, payload);
    void kvPut(opts.key, payload, opts.ttlMs);
    return { ok: true, payload };
  } catch (e) {
    const rescue = hot ?? shared;
    if (rescue && now - rescue.fetchedAt < opts.staleRescueMs) {
      return { ok: true, payload: rescue };
    }
    return { ok: false, detail: e instanceof Error ? e.message : String(e) };
  }
}
