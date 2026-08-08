/**
 * The SHARED standing-fight store — the thing `duelCommit.ts` has demanded
 * since the day it was written ("**A shared store is required before
 * mainnet.**").
 *
 * ─── WHY REST-REDIS AND NOT A DRIVER ─────────────────────────────────
 *
 * The site runs on Vercel serverless. A TCP database driver means connection
 * pools per instance, cold-start handshakes and a dependency; Vercel KV and
 * Upstash Redis both speak a one-POST-per-command REST protocol over plain
 * `fetch`, which is already in the runtime. One command per store call, no
 * pool, nothing to add to package.json.
 *
 * ─── ACTIVATION ──────────────────────────────────────────────────────
 *
 * Entirely by env var, checked at first use:
 *
 *   `KV_REST_API_URL`  + `KV_REST_API_TOKEN`   (Vercel KV's names), or
 *   `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` (Upstash's own).
 *
 * Absent both pairs, `restCommitStoreFromEnv` returns null and `/api/run-duel`
 * falls back to process memory WITH ITS EXISTING LOUD WARNING — deploy logs
 * always say which world you are in. Nothing else needs configuring: create
 * the store in the Vercel dashboard, let the integration inject the vars,
 * redeploy.
 *
 * ─── FAILURE DIRECTION: CLOSED ───────────────────────────────────────
 *
 * If the backend is unreachable, every method THROWS and the fight request
 * 500s. That is deliberate. The alternative — treating "store down" as "no
 * standing fight" — silently mints a fresh outcome, which is precisely the
 * free re-roll this whole mechanism exists to deny. Nobody fighting for a
 * minute beats everybody outcome-shopping for a minute.
 *
 * The ONE softened case is a row that exists but no longer parses as a
 * `DuelCommit` (a schema change by us, ever). That logs and reads as null
 * rather than bricking every wallet that fought across the deploy — the cost
 * is one re-roll per wallet, once, on our own schema migration.
 *
 * ─── KEYING ──────────────────────────────────────────────────────────
 *
 * `duelcommit:{namespace}:{wallet}` where the caller supplies
 * `{chainId}:{duelAddress}`. A commit is only meaningful against the Duel
 * deployment whose `fightSeq` it snapshotted, so testnet and mainnet sharing
 * one Redis can never serve each other's fights.
 *
 * Rows carry a TTL of the 24h liveness backstop plus an hour: any commit that
 * old is released by `releaseReason` anyway, so expiry can never delete a
 * fight the rules would have kept, and the store cleans itself.
 */
import {
  COMMIT_BACKSTOP_SECONDS,
  type CommitStore,
  type DuelCommit,
} from './duelCommit';

const TTL_SECONDS = COMMIT_BACKSTOP_SECONDS + 60 * 60;

/** Minimal shape check — see the softened-case note in the header. */
function isDuelCommit(v: unknown): v is DuelCommit {
  if (typeof v !== 'object' || v === null) return false;
  const c = v as Record<string, unknown>;
  return (
    typeof c.wallet === 'string' &&
    typeof c.challenger === 'number' &&
    typeof c.opponent === 'number' &&
    typeof c.tokenA === 'number' &&
    typeof c.tokenB === 'number' &&
    typeof c.winnerId === 'number' &&
    typeof c.rounds === 'number' &&
    typeof c.seed === 'string' &&
    typeof c.newEloA === 'number' &&
    typeof c.newEloB === 'number' &&
    typeof c.nonce === 'string' &&
    typeof c.seq === 'string' &&
    typeof c.eventsJson === 'string' &&
    typeof c.createdAt === 'number'
  );
}

export class RestCommitStore implements CommitStore {
  constructor(
    private readonly url: string,
    private readonly token: string,
    private readonly namespace: string,
  ) {}

  private key(wallet: string): string {
    return `duelcommit:${this.namespace}:${wallet.toLowerCase()}`;
  }

  /**
   * One Redis command, Upstash REST framing: POST the command as a JSON
   * array, get `{ result }` back. `{ error }` or a non-2xx both throw —
   * failure direction is closed, per the header.
   */
  private async command(cmd: (string | number)[]): Promise<unknown> {
    let res: Response;
    try {
      res = await fetch(this.url, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(cmd),
        cache: 'no-store',
      });
    } catch (e) {
      throw new Error(
        `commit store unreachable (${cmd[0]}): ${e instanceof Error ? e.message : String(e)}`,
      );
    }
    if (!res.ok) {
      throw new Error(`commit store ${cmd[0]} returned HTTP ${res.status}`);
    }
    const body = (await res.json()) as { result?: unknown; error?: string };
    if (typeof body.error === 'string') {
      throw new Error(`commit store ${cmd[0]} error: ${body.error}`);
    }
    return body.result;
  }

  async get(wallet: string): Promise<DuelCommit | null> {
    const raw = await this.command(['GET', this.key(wallet)]);
    if (raw === null || raw === undefined) return null;
    if (typeof raw !== 'string') {
      throw new Error('commit store GET returned a non-string result');
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      parsed = null;
    }
    if (!isDuelCommit(parsed)) {
      console.error(
        `[commit-store] row for ${wallet.toLowerCase()} does not parse as a ` +
          'DuelCommit (schema drift?) — treating as empty and letting it expire',
      );
      return null;
    }
    return parsed;
  }

  async put(commit: DuelCommit): Promise<void> {
    await this.command([
      'SET',
      this.key(commit.wallet),
      JSON.stringify(commit),
      'EX',
      TTL_SECONDS,
    ]);
  }

  async del(wallet: string): Promise<void> {
    await this.command(['DEL', this.key(wallet)]);
  }
}

/**
 * The factory `/api/run-duel` calls: the shared store when the env says one
 * exists, null (→ caller's memory fallback + warning) when it doesn't.
 */
export function restCommitStoreFromEnv(namespace: string): RestCommitStore | null {
  const url = process.env.KV_REST_API_URL ?? process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN ?? process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return null;
  return new RestCommitStore(url, token, namespace);
}
