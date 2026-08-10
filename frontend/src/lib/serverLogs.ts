/**
 * SERVER-SIDE HISTORICAL LOG READS.
 *
 * ⚠ SERVER ONLY. Reads `ETHERSCAN_API_KEY`, deliberately WITHOUT a
 * `NEXT_PUBLIC_` prefix — that prefix is the only thing that decides whether
 * Next inlines a variable into the browser bundle, and a key shipped to every
 * visitor is a key that gets rate-limited off the planet by lunchtime. Import
 * this from route handlers pinned to `runtime = 'nodejs'` and nowhere else.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THIS EXISTS AT ALL: THE BROWSER CANNOT READ THIS CHAIN'S HISTORY
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Measured on BSC mainnet, 2026-08-10, asking each endpoint in `rpcUrls()` for
 * the pot's own `Funded` logs. Columns are the `fromBlock` of the window:
 *
 *   endpoint                   deploy block   ~5,000 back   ~500 back
 *   bsc-rpc.publicnode.com     HTTP 403       ok            ok
 *   bsc.drpc.org               HTTP 400       HTTP 400      HTTP 400
 *   bsc-dataseed1.defibit.io   -32005         -32005        -32005
 *   bsc-dataseed.bnbchain.org  -32005         -32005        -32005
 *
 * Read the top-left cell. **Only one endpoint will serve this filter at all,
 * and it refuses the moment the window reaches back past its retention** — the
 * same "archive request" 403 it gives on `eth_getTransactionReceipt`. Both
 * dataseeds answer `-32005 limit exceeded` even for a FIVE HUNDRED block
 * window, so no amount of chunking rescues them.
 *
 * So a client-side sweep does not merely run slowly, it is WRONG BY DESIGN:
 * the near chunks answer and the far ones 403 forever, so the page shows a
 * shorter and shorter history while the pot keeps growing. A visitor cannot
 * tell that apart from "the pot is not filling", which is the single most
 * damaging thing this feed could imply. Note that `useContractLogs`' halving
 * path cannot save it either: it handles RANGE-CAP errors, and neither a 403
 * nor a rate-limit is one.
 *
 * The keyed archive endpoint in `alchemy-dprc.env` does not rescue it either:
 * that key is on the free tier, where `eth_getLogs` is capped to a **10 block
 * range**. Covering the ~16,000 blocks since the deploy would be ~1,600
 * requests for one page view, growing forever. Verified, not assumed.
 *
 * The etherscan v2 multichain api answers the SAME query — full range, from
 * the deploy block to head, in ONE request — and hands back `timeStamp` on
 * every log, so there is no second round trip to turn block numbers into
 * clocks. It is the same key and the same `chainid=56` convention the repo
 * already uses to verify contracts (`docs/MAINNET-MIGRATION.md`).
 *
 * ⚠ REUSABLE ON PURPOSE. `/history`'s duel replay fails for exactly these
 * reasons. Anything that needs "every log since the deploy block" should call
 * `fetchLogsByTopic0` from a server route rather than growing another
 * client-side chunking loop.
 */

/** Etherscan's v2 multichain gateway. One host, one key, `chainid` selects. */
const ETHERSCAN_V2 = 'https://api.etherscan.io/v2/api';

/**
 * Records per request. 1000 is etherscan's hard ceiling for this endpoint;
 * asking for more silently returns 1000 anyway.
 */
const PAGE_SIZE = 1000;

/**
 * How many windows the sweep will walk before it gives up and reports itself
 * INCOMPLETE rather than looping.
 *
 * ⚠ THE CAP IS A HONESTY DEVICE, NOT A PERFORMANCE ONE. 25 windows is 25,000
 * events, far beyond anything these contracts will emit this year, so hitting
 * it means something is wrong (a block with >1000 matching logs would also
 * stall the window advance below). The caller is TOLD, and says so on the page,
 * instead of rendering a truncated list as if it were the whole record.
 */
const MAX_WINDOWS = 25;

export interface ChainLog {
  readonly address: `0x${string}`;
  readonly topics: readonly `0x${string}`[];
  readonly data: `0x${string}`;
  readonly blockNumber: number;
  /** Unix seconds. Etherscan returns this inline, so no second round trip. */
  readonly timestamp: number;
  readonly txHash: `0x${string}`;
  readonly logIndex: number;
}

export interface LogSweep {
  readonly logs: ChainLog[];
  /**
   * True when the sweep stopped early and the list is NOT the full record.
   * Callers must surface this — a short list and a complete one must never
   * look the same.
   */
  readonly truncated: boolean;
}

/** The api key, or null when unconfigured. Never throws: a route answering
 *  "we could not read the chain" is better than a stack trace. */
export function etherscanApiKey(): string | null {
  const raw = process.env.ETHERSCAN_API_KEY?.trim();
  return raw ? raw : null;
}

interface EtherscanLog {
  address?: string;
  topics?: string[];
  data?: string;
  blockNumber?: string;
  timeStamp?: string;
  transactionHash?: string;
  logIndex?: string;
}

function hexToInt(v: string | undefined): number {
  if (!v) return 0;
  const n = v.startsWith('0x') ? Number.parseInt(v, 16) : Number.parseInt(v, 10);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Every log matching `topic0` on `address` between `fromBlock` and head.
 *
 * ⚠ THE SWEEP ADVANCES BY BLOCK, NOT BY PAGE NUMBER. Deep `page=N` pagination
 * on this endpoint is both slower and unreliable past a few pages; walking the
 * window forward to the last block seen is one cheap request per 1000 events.
 * The window restarts ON the last block rather than after it, because a single
 * block can carry several matching logs and skipping it would silently drop
 * them — so results are de-duplicated on `txHash:logIndex`.
 */
export async function fetchLogsByTopic0(params: {
  chainId: number;
  address: `0x${string}`;
  topic0: `0x${string}`;
  fromBlock: bigint;
}): Promise<LogSweep> {
  const key = etherscanApiKey();
  if (!key) throw new Error('ETHERSCAN_API_KEY is not configured on the server');

  const seen = new Set<string>();
  const out: ChainLog[] = [];
  let cursor = params.fromBlock;
  let truncated = false;

  for (let window = 0; ; window += 1) {
    if (window >= MAX_WINDOWS) {
      truncated = true;
      break;
    }

    const query = new URLSearchParams({
      chainid: String(params.chainId),
      module: 'logs',
      action: 'getLogs',
      address: params.address,
      fromBlock: cursor.toString(),
      toBlock: 'latest',
      topic0: params.topic0,
      page: '1',
      offset: String(PAGE_SIZE),
      apikey: key,
    });

    const res = await fetch(`${ETHERSCAN_V2}?${query.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`etherscan getLogs returned HTTP ${res.status}`);

    const body = (await res.json()) as {
      status?: string;
      message?: string;
      result?: EtherscanLog[] | string;
    };

    // ⚠ "No records found" IS A SUCCESSFUL EMPTY ANSWER, not a failure. It
    // arrives as status "0", the same shape as a real error, and treating the
    // two alike is exactly how "this pot has had no deposits" would come to
    // look like "the chain is down" (or, far worse, the other way round).
    if (!Array.isArray(body.result)) {
      const message = body.message ?? 'unknown';
      if (/no records found/i.test(message)) break;
      const detail = typeof body.result === 'string' ? `: ${body.result}` : '';
      throw new Error(`etherscan getLogs failed (${message})${detail}`);
    }

    const page = body.result;
    let added = 0;
    let maxBlock = cursor;

    for (const raw of page) {
      const txHash = (raw.transactionHash ?? '') as `0x${string}`;
      const logIndex = hexToInt(raw.logIndex);
      const id = `${txHash}:${logIndex}`;
      if (!txHash || seen.has(id)) continue;
      seen.add(id);

      const blockNumber = hexToInt(raw.blockNumber);
      out.push({
        address: (raw.address ?? params.address) as `0x${string}`,
        topics: (raw.topics ?? []) as `0x${string}`[],
        data: (raw.data ?? '0x') as `0x${string}`,
        blockNumber,
        timestamp: hexToInt(raw.timeStamp),
        txHash,
        logIndex,
      });
      added += 1;
      if (BigInt(blockNumber) > maxBlock) maxBlock = BigInt(blockNumber);
    }

    // A short page is the end of the chain's history for this filter.
    if (page.length < PAGE_SIZE) break;

    // A full page that advanced nothing means one block holds more than
    // PAGE_SIZE matching logs. The window cannot move without losing some, so
    // stop and say the record is incomplete rather than loop or lie.
    if (added === 0 || maxBlock <= cursor) {
      truncated = true;
      break;
    }
    cursor = maxBlock;
  }

  out.sort((a, b) =>
    a.blockNumber !== b.blockNumber ? a.blockNumber - b.blockNumber : a.logIndex - b.logIndex,
  );
  return { logs: out, truncated };
}
