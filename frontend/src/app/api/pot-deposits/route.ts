/**
 * GET /api/pot-deposits?pot=jackpotBnb — every deposit that has ever gone into
 * a jackpot, with how much, from where, and when.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THIS IS A SERVER ROUTE AND NOT A HOOK
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Because the browser cannot read this chain's history. Measured on BSC
 * mainnet against these exact pot addresses (the full workings are in
 * `lib/serverLogs.ts`): both bnb dataseeds refuse `eth_getLogs`, drpc's public
 * endpoint rate-limits it, publicnode 403s receipts, and every free endpoint
 * PRUNES logs to roughly the last two hours. A client-side sweep would not be
 * slow, it would be quietly and increasingly WRONG — showing a shrinking
 * history for a growing pot, which reads to a visitor as a pot that stopped
 * filling. That is the one impression this feed must never give.
 *
 * The archive key in `alchemy-dprc.env` does not fix it either: it is free
 * tier, where `eth_getLogs` is capped to a **10 block range**, so one page view
 * would be ~1,600 requests and rising. Verified before this was written.
 *
 * So the history is read here, once, with a key that never leaves the server,
 * and cached so a busy page is not a bill.
 *
 * ⚠ NO KEY MAY GAIN A `NEXT_PUBLIC_` PREFIX. That prefix is the only thing
 * deciding whether Next inlines a variable into the browser bundle.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE THREE ANSWERS THIS ROUTE CAN GIVE, AND WHY THEY ARE THREE
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   200 + deposits        the record, with a `truncated` flag and the pot's own
 *                         `totalFunded` so the page can check its own sum
 *   200 + empty deposits  the pot genuinely has had nothing paid in
 *   502 + error           we could not read the chain
 *
 * The middle and the last must never collapse into each other. "no deposits
 * yet" and "we could not read the chain" look identical if a failed read is
 * allowed to return an empty list, and on a page about money that is a lie.
 */
import { NextResponse } from 'next/server';
import { createPublicClient, decodeEventLog, fallback, http, parseAbi, toEventSelector } from 'viem';
import { JackpotAbi, JackpotNativeAbi, MintDropAbi } from '@/lib/abi';
import {
  CHAIN_ID,
  contractAddress,
  deployBlock,
  isNativePot,
  NATIVE_POT_DECIMALS,
  NATIVE_POT_SYMBOL,
  rpcUrls,
  type ContractName,
} from '@/lib/env';
import { fetchLogsByTopic0, etherscanApiKey } from '@/lib/serverLogs';
import type { DepositRouteKey, PotDeposit, PotDepositsPayload } from '@/lib/potDeposits';

export const runtime = 'nodejs';
/** Caching is explicit below (cdn header + kv + memory), never Next's guess. */
export const dynamic = 'force-dynamic';

/** How long a read is served before another one is made. */
const CACHE_TTL_MS = 45_000;
/**
 * How long a cached read may still be served AFTER a refresh has failed.
 *
 * ⚠ SERVING A SLIGHTLY OLD RECORD BEATS SERVING NOTHING, but only for a while.
 * The payload carries `fetchedAt` and the page prints it, so an old answer is
 * labelled as old rather than passed off as live.
 */
const STALE_RESCUE_MS = 10 * 60_000;

/** Wiring is timelocked 24h on chain, so it is worth caching hard. */
const WIRING_TTL_MS = 10 * 60_000;

const FUNDED_TOPIC = toEventSelector('Funded(address,uint256,string)');
const FUNDED_ABI = parseAbi([
  'event Funded(address indexed from, uint256 amount, string source)',
]);

/**
 * ⚠ THE SECOND DEPOSIT EVENT, AND ONLY THE NATIVE POT HAS IT.
 * `JackpotNative.absorbStrayWbnb()` is permissionless, credits `totalFunded`,
 * and emits THIS rather than `Funded`. Sweeping only `Funded` on that pot would
 * mean the day somebody mis-sends wbnb and anyone pushes it into the pool, the
 * feed reports a shortfall it cannot explain for money that is really there.
 * `Jackpot.sol` has no such function and no such event, so it is not asked.
 */
const STRAY_TOPIC = toEventSelector('StrayWbnbAbsorbed(uint256)');
const STRAY_ABI = parseAbi(['event StrayWbnbAbsorbed(uint256 amount)']);

type PotName = 'jackpotBnbull' | 'jackpotBnb';

interface CacheEntry {
  at: number;
  payload: PotDepositsPayload;
}
const memory = new Map<string, CacheEntry>();

function client() {
  return createPublicClient({ transport: fallback(rpcUrls().map((u) => http(u))) });
}

// ─── the shared cache, when one is configured ─────────────────────────
//
// Same env pair `lib/commitStoreRest.ts` uses, same one-POST-per-command REST
// framing. Absent, this route falls back to per-instance memory, which is a
// smaller win but never a wrong answer. Cache failures are swallowed on
// purpose: a broken cache must degrade to a slower page, never a 500.

function kv(): { url: string; token: string } | null {
  const url = process.env.KV_REST_API_URL ?? process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN ?? process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? { url, token } : null;
}

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

async function kvGet(key: string): Promise<PotDepositsPayload | null> {
  try {
    const raw = await kvCommand(['GET', key]);
    if (typeof raw !== 'string') return null;
    return JSON.parse(raw) as PotDepositsPayload;
  } catch {
    return null;
  }
}

async function kvPut(key: string, payload: PotDepositsPayload): Promise<void> {
  try {
    await kvCommand(['SET', key, JSON.stringify(payload), 'EX', Math.ceil(CACHE_TTL_MS / 1000)]);
  } catch {
    /* a cache that cannot write is still a page that renders */
  }
}

// ─── who paid: the sender decides the route ───────────────────────────

interface Wiring {
  at: number;
  map: Map<string, DepositRouteKey>;
}
/** Keyed by pot, because the pot's own `owner()` is part of the answer. */
const wiringCache = new Map<string, Wiring>();

function put(map: Map<string, DepositRouteKey>, addr: string | null | undefined, key: DepositRouteKey) {
  if (!addr || !/^0x[0-9a-fA-F]{40}$/.test(addr)) return;
  if (addr === '0x0000000000000000000000000000000000000000') return;
  // First writer wins, so a splitter that also answers a second wire read
  // cannot overwrite the name it was first given.
  const lower = addr.toLowerCase();
  if (!map.has(lower)) map.set(lower, key);
}

/**
 * Build the sender → route lookup.
 *
 * ⚠ THE THREE SPLITTERS ARE NOT IN ENV, AND ARE READ OFF CHAIN RATHER THAN
 * HARDCODED. Their addresses live in `deployments/56.json`, not in any
 * `NEXT_PUBLIC_*` var, and pasting them here would be a second copy that goes
 * stale the next time one is redeployed — on a page whose whole job is to say
 * truthfully where money came from. Each is instead read from the contract
 * that PAYS it, which is the same wire the money actually travels down:
 *
 *   MintDrop.lpTreasury()      → MintBnbullSplitter   (`script/Wire.s.sol:234`)
 *   Graveyard.wires().mintDrop_ → ReviveBuySplitter   (`script/Wire.s.sol` routes
 *                                 the graveyard's pot slice through this wire;
 *                                 the ABI's parameter NAME is historical)
 *   Marketplace.jackpotSink()  → MarketPotSplitter
 *   pot.owner()                → the house's own hand top-ups
 *
 * ⚠ THE OWNER IS READ, NOT INFERRED FROM THE `"dev-topup"` LABEL. That label is
 * hardcoded inside `topUp()`, which is `onlyOwner`, so it looks like proof of
 * who sent it — but `fund(amount, source)` takes the source as an ARGUMENT, so
 * any whitelisted funder could emit the same string. Naming a sender off a
 * string it could have chosen for itself is exactly the kind of shortcut this
 * page cannot afford. The address is the fact.
 *
 * Every read is best-effort. A sender we cannot name renders as its address
 * with its raw `source` label beside it, which is honest; inventing a name for
 * it would not be.
 */
async function wiring(potAddress: `0x${string}`): Promise<Map<string, DepositRouteKey>> {
  const now = Date.now();
  const cacheKey = potAddress.toLowerCase();
  const cached = wiringCache.get(cacheKey);
  if (cached && now - cached.at < WIRING_TTL_MS) return cached.map;

  const map = new Map<string, DepositRouteKey>();
  const named: [ContractName, DepositRouteKey][] = [
    ['duel', 'duel'],
    ['mintDrop', 'mint'],
  ];
  for (const [name, key] of named) put(map, contractAddress(name), key);

  const c = client();
  const mintDrop = contractAddress('mintDrop');
  const graveyard = contractAddress('graveyard');
  const marketplace = contractAddress('marketplace');

  const reads: Promise<void>[] = [
    c
      .readContract({
        address: potAddress,
        abi: parseAbi(['function owner() view returns (address)']),
        functionName: 'owner',
      })
      .then((a) => put(map, a, 'house'))
      .catch(() => {}),
  ];
  if (mintDrop) {
    reads.push(
      c
        .readContract({
          address: mintDrop,
          abi: parseAbi(['function lpTreasury() view returns (address)']),
          functionName: 'lpTreasury',
        })
        .then((a) => put(map, a, 'bnbullMint'))
        .catch(() => {}),
    );
  }
  if (graveyard) {
    reads.push(
      c
        .readContract({
          address: graveyard,
          abi: parseAbi(['function wires() view returns (address,address,address)']),
          functionName: 'wires',
        })
        .then((w) => put(map, w[1], 'revive'))
        .catch(() => {}),
    );
  }
  if (marketplace) {
    reads.push(
      c
        .readContract({
          address: marketplace,
          abi: parseAbi(['function jackpotSink() view returns (address)']),
          functionName: 'jackpotSink',
        })
        .then((a) => put(map, a, 'market'))
        .catch(() => {}),
    );
  }
  await Promise.all(reads);

  wiringCache.set(cacheKey, { at: now, map });
  return map;
}

// ─── the pot's own numbers ────────────────────────────────────────────

interface PotState {
  pool: bigint | null;
  totalFunded: bigint | null;
  totalAwarded: bigint | null;
  symbol: string;
  decimals: number;
  bnbUsd1e18: bigint | null;
}

async function readPotState(pot: PotName, address: `0x${string}`): Promise<PotState> {
  const c = client();
  const native = isNativePot(pot);
  const abi = native ? JackpotNativeAbi : JackpotAbi;

  const one = async (functionName: 'pool' | 'totalFunded' | 'totalAwarded') => {
    try {
      return (await c.readContract({ address, abi, functionName })) as bigint;
    } catch {
      return null;
    }
  };
  const [pool, totalFunded, totalAwarded] = await Promise.all([
    one('pool'),
    one('totalFunded'),
    one('totalAwarded'),
  ]);

  // ⚠ A NATIVE POT HAS NO `prizeToken()` AT ALL — the view is gone from
  // `JackpotNative`, so asking would fail and leave the ticker on a fallback
  // beside a real number. Native facts are asserted; only a real erc-20 pot is
  // asked what it holds.
  let symbol = NATIVE_POT_SYMBOL;
  let decimals: number = NATIVE_POT_DECIMALS;
  if (!native) {
    symbol = '';
    try {
      const token = (await c.readContract({
        address,
        abi: JackpotAbi,
        functionName: 'prizeToken',
      })) as `0x${string}`;
      const erc20 = parseAbi([
        'function symbol() view returns (string)',
        'function decimals() view returns (uint8)',
      ]);
      const [s, d] = await Promise.all([
        c.readContract({ address: token, abi: erc20, functionName: 'symbol' }),
        c.readContract({ address: token, abi: erc20, functionName: 'decimals' }),
      ]);
      symbol = s as string;
      decimals = Number(d);
    } catch {
      // Left empty rather than guessed. The client prints the amount with no
      // ticker instead of the wrong one.
    }
  }

  // A rough dollar figure, only where it is honestly available: the native pot
  // is BNB and `MintDrop.bnbUsdPrice()` is the same chainlink read every price
  // in the game already goes through. $BNBULL has no oracle, so that pot simply
  // does not get a usd column rather than getting an invented one.
  let bnbUsd1e18: bigint | null = null;
  const mintDrop = contractAddress('mintDrop');
  if (native && mintDrop) {
    try {
      bnbUsd1e18 = (await c.readContract({
        address: mintDrop,
        abi: MintDropAbi,
        functionName: 'bnbUsdPrice',
      })) as bigint;
    } catch {
      bnbUsd1e18 = null;
    }
  }

  return { pool, totalFunded, totalAwarded, symbol, decimals, bnbUsd1e18 };
}

// ─── the payload ──────────────────────────────────────────────────────

async function build(pot: PotName, address: `0x${string}`): Promise<PotDepositsPayload> {
  // Absent a configured deploy block, start at genesis: etherscan is not
  // range-capped, so "everything" is a legitimate answer here in a way it never
  // is against a public node.
  const fromBlock = deployBlock() ?? 0n;

  // The log sweeps are the one read allowed to fail the request: with no
  // history there is no feed, and an empty list would be indistinguishable from
  // a pot nobody has funded.
  const sweep = await fetchLogsByTopic0({
    chainId: CHAIN_ID,
    address,
    topic0: FUNDED_TOPIC,
    fromBlock,
  });
  const strays = isNativePot(pot)
    ? await fetchLogsByTopic0({ chainId: CHAIN_ID, address, topic0: STRAY_TOPIC, fromBlock })
    : { logs: [], truncated: false };

  const [routes, state] = await Promise.all([wiring(address), readPotState(pot, address)]);

  const deposits: PotDeposit[] = [];
  let shownTotal = 0n;
  for (const log of sweep.logs) {
    let from: `0x${string}`;
    let amount: bigint;
    let source: string;
    try {
      const decoded = decodeEventLog({
        abi: FUNDED_ABI,
        data: log.data,
        topics: log.topics as [`0x${string}`, ...`0x${string}`[]],
      });
      from = decoded.args.from;
      amount = decoded.args.amount;
      source = decoded.args.source;
    } catch {
      // A log that does not decode is dropped rather than guessed at. It cannot
      // happen for a topic0 we selected on, but a dropped row is a smaller lie
      // than a fabricated one.
      continue;
    }
    // A zero-value Funded cannot be emitted by either contract (both return
    // early on `amount == 0`), so this is belt and braces against a row that
    // would render as a deposit of nothing.
    if (amount === 0n) continue;

    shownTotal += amount;
    deposits.push({
      amount: amount.toString(),
      source,
      from,
      route: routes.get(from.toLowerCase()) ?? 'unknown',
      txHash: log.txHash,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      timestamp: log.timestamp,
    });
  }

  for (const log of strays.logs) {
    let amount: bigint;
    try {
      amount = decodeEventLog({
        abi: STRAY_ABI,
        data: log.data,
        topics: log.topics as [`0x${string}`, ...`0x${string}`[]],
      }).args.amount;
    } catch {
      continue;
    }
    if (amount === 0n) continue;
    shownTotal += amount;
    deposits.push({
      amount: amount.toString(),
      // The contract's own word for it. Kept raw like every other source, so
      // the row is still checkable against the log.
      source: 'stray-wbnb',
      // ⚠ THE EVENT CARRIES NO SENDER. This is the pot's own address, and the
      // ui prints an address only for the `unknown` route, so it is never shown
      // as if it were the person who paid.
      from: address,
      route: 'stray',
      txHash: log.txHash,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      timestamp: log.timestamp,
    });
  }

  // Two sweeps, one timeline. Sorted rather than concatenated, or a stray
  // absorb would sit at the bottom of the feed no matter when it happened.
  deposits.sort((a, b) =>
    a.blockNumber !== b.blockNumber ? a.blockNumber - b.blockNumber : a.logIndex - b.logIndex,
  );

  // Newest first: the point of the feed is that the pot is filling NOW.
  deposits.reverse();

  return {
    pot,
    address,
    symbol: state.symbol,
    decimals: state.decimals,
    chainId: CHAIN_ID,
    deposits,
    shownTotal: shownTotal.toString(),
    totalFunded: state.totalFunded === null ? null : state.totalFunded.toString(),
    pool: state.pool === null ? null : state.pool.toString(),
    totalAwarded: state.totalAwarded === null ? null : state.totalAwarded.toString(),
    bnbUsd1e18: state.bnbUsd1e18 === null ? null : state.bnbUsd1e18.toString(),
    truncated: sweep.truncated || strays.truncated,
    fetchedAt: Date.now(),
  };
}

function fail(status: number, error: string) {
  return NextResponse.json({ error }, { status, headers: { 'Cache-Control': 'no-store' } });
}

export async function GET(request: Request) {
  const raw = new URL(request.url).searchParams.get('pot');
  const pot: PotName | null =
    raw === 'jackpotBnb' || raw === 'bnb'
      ? 'jackpotBnb'
      : raw === 'jackpotBnbull' || raw === 'bnbull'
        ? 'jackpotBnbull'
        : null;
  if (!pot) return fail(400, 'pot must be jackpotBnb or jackpotBnbull');

  const address = contractAddress(pot);
  if (!address) return fail(503, 'that pot has no address configured on this build');

  if (!etherscanApiKey()) {
    return fail(
      503,
      'the history reader is not configured on the server (ETHERSCAN_API_KEY)',
    );
  }

  const key = `potdeposits:${CHAIN_ID}:${address.toLowerCase()}`;
  const now = Date.now();

  const hot = memory.get(key);
  if (hot && now - hot.at < CACHE_TTL_MS) return ok(hot.payload);

  const shared = await kvGet(key);
  if (shared && now - shared.fetchedAt < CACHE_TTL_MS) {
    memory.set(key, { at: now, payload: shared });
    return ok(shared);
  }

  try {
    const payload = await build(pot, address);
    memory.set(key, { at: now, payload });
    void kvPut(key, payload);
    return ok(payload);
  } catch (e) {
    // ⚠ A FAILED READ FALLS BACK TO AN OLD RECORD, NEVER TO AN EMPTY ONE. The
    // payload carries `fetchedAt` and the page prints it, so a stale answer is
    // labelled. With nothing to fall back to we say so, loudly, with a 502.
    const rescue = hot ?? shared;
    if (rescue) {
      const payload = 'payload' in rescue ? rescue.payload : rescue;
      if (now - payload.fetchedAt < STALE_RESCUE_MS) return ok(payload);
    }
    const detail = e instanceof Error ? e.message : String(e);
    console.error('[pot-deposits] read failed:', detail);
    return fail(502, 'could not read the chain right now');
  }
}

function ok(payload: PotDepositsPayload) {
  return NextResponse.json(payload, {
    headers: {
      // The cdn absorbs the crowd; the origin refreshes on its own clock. This
      // is a public page and every visitor hitting an archive api is a bill.
      'Cache-Control': 'public, s-maxage=30, stale-while-revalidate=300',
    },
  });
}
