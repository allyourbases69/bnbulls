/**
 * GET /api/duel-history — every fight ever settled on chain, newest first.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THIS IS A SERVER ROUTE AND NOT A HOOK
 * ═══════════════════════════════════════════════════════════════════════
 *
 * `/history` swept `DuelCompleted` from the browser and quietly lost most of it.
 * Not with an error — the refused ranges came back as nothing. On bnb mainnet
 * publicnode 403s any window reaching past its retention, drpc 400s, and both
 * dataseeds refuse even a 500-block window; none of those is a range-cap error,
 * so `useContractLogs`' halving path never fired and the chunks disappeared in
 * silence. Measured 2026-08-10 the page showed 31 of the 35 fights on chain, and
 * the gap widens every day the contract lives. The table is in
 * `lib/serverLogs.ts`.
 *
 * The etherscan v2 multichain api answers the same query for the whole range in
 * one request, with block timestamps attached, using a key that never leaves the
 * server. ⚠ NO KEY MAY GAIN A `NEXT_PUBLIC_` PREFIX — that prefix is the only
 * thing deciding whether Next inlines a variable into the browser bundle.
 *
 * ⚠ THIS ROUTE FEEDS THE REPLAY. Every row carries `txHash` AND `logIndex`, and
 * `/api/duel-gif?tx=…&log=…` needs both to pick the right fight out of a
 * transaction that settled several. Dropping `logIndex` to save bytes would
 * point half the ▶ buttons at the wrong fight.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE THREE ANSWERS
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   200 + fights      the record, with `truncated` saying whether it is all of it
 *   200 + no fights   nobody has fought yet
 *   502 + error       we could not read the chain
 *
 * The last two must never collapse into each other. "the pit is quiet" printed
 * because a read failed is the page telling a visitor the game is dead.
 */
import { NextResponse } from 'next/server';
import { decodeEventLog, parseAbi, toEventSelector } from 'viem';
import { CHAIN_ID, contractAddress, deployBlock } from '@/lib/env';
import { isValidBullId } from '@/lib/art/collection';
import { cachedPayload } from '@/lib/serverCache';
import { etherscanApiKey, fetchLogsByTopic0 } from '@/lib/serverLogs';
import type { DuelRecordPayload, DuelRecordRow } from '@/lib/duelRecord';

export const runtime = 'nodejs';
/** Caching is explicit below (cdn header + kv + memory), never Next's guess. */
export const dynamic = 'force-dynamic';

/** How long a read is served before another one is made. Short, because a fight
 *  that has just settled is the row its two owners are refreshing for. */
const CACHE_TTL_MS = 45_000;
/** How long a cached read may still be served after a refresh has failed. */
const STALE_RESCUE_MS = 10 * 60_000;

/**
 * The most rows one response may carry.
 *
 * ⚠ A PAYLOAD BUDGET, NOT AN OPINION ABOUT THE RECORD. At roughly 180 bytes a
 * row, 2,000 fights is a ~360kb json — already a lot to hand a phone, and the
 * page renders every row it is given. Past that the newest are kept and
 * `truncated` goes true, which the page prints as "this is not the full record"
 * rather than passing a trimmed list off as the whole thing. Nothing here caps
 * what is READ: the sweep still walks the entire chain so `total` is the honest
 * number of fights that have ever happened.
 */
const MAX_ROWS = 2_000;

/** `DuelCompleted(uint256 indexed tokenA, uint256 indexed tokenB, uint32 winnerId,
 *  uint16 rounds, uint256 seed, uint256 nonce, uint32 newEloA, uint32 newEloB)`
 *  — byte-identical on `Duel.sol` and `DuelNative.sol`, so one topic serves both
 *  and a migration does not need a second sweep. */
const DUEL_TOPIC = toEventSelector(
  'DuelCompleted(uint256,uint256,uint32,uint16,uint256,uint256,uint32,uint32)',
);
const DUEL_ABI = parseAbi([
  'event DuelCompleted(uint256 indexed tokenA, uint256 indexed tokenB, uint32 winnerId, uint16 rounds, uint256 seed, uint256 nonce, uint32 newEloA, uint32 newEloB)',
]);

async function build(address: `0x${string}`): Promise<DuelRecordPayload> {
  // Absent a configured deploy block, start at genesis: etherscan is not
  // range-capped, so "everything" is a legitimate answer here in a way it never
  // is against a public node.
  const fromBlock = deployBlock() ?? 0n;

  const sweep = await fetchLogsByTopic0({
    chainId: CHAIN_ID,
    address,
    topic0: DUEL_TOPIC,
    fromBlock,
  });

  const fights: DuelRecordRow[] = [];
  for (const log of sweep.logs) {
    let args;
    try {
      args = decodeEventLog({
        abi: DUEL_ABI,
        data: log.data,
        topics: log.topics as [`0x${string}`, ...`0x${string}`[]],
      }).args;
    } catch {
      // A log that does not decode is dropped rather than guessed at. It cannot
      // happen for a topic0 we selected on, but a dropped row is a smaller lie
      // than a fabricated one.
      continue;
    }

    const tokenA = Number(args.tokenA);
    const tokenB = Number(args.tokenB);
    // Ids outside the collection cannot be named, drawn or linked. `Duel` cannot
    // emit one, so this only ever fires against a wrong address in config — in
    // which case a blank list is the right answer.
    if (!isValidBullId(tokenA) || !isValidBullId(tokenB)) continue;

    fights.push({
      tokenA,
      tokenB,
      winnerId: Number(args.winnerId),
      rounds: Number(args.rounds),
      newEloA: Number(args.newEloA),
      newEloB: Number(args.newEloB),
      txHash: log.txHash,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      timestamp: log.timestamp,
    });
  }

  // Newest first. The sweep hands them back oldest-first, so this is one
  // reversal rather than a sort: within a block the later log is the later
  // fight, which reversing preserves.
  fights.reverse();

  const total = fights.length;
  return {
    chainId: CHAIN_ID,
    address,
    fights: total > MAX_ROWS ? fights.slice(0, MAX_ROWS) : fights,
    total,
    truncated: sweep.truncated || total > MAX_ROWS,
    fetchedAt: Date.now(),
  };
}

function fail(status: number, error: string) {
  return NextResponse.json({ error }, { status, headers: { 'Cache-Control': 'no-store' } });
}

function ok(payload: DuelRecordPayload) {
  return NextResponse.json(payload, {
    headers: {
      // The cdn absorbs the crowd; the origin refreshes on its own clock.
      // `/history` is a public page and every uncached visitor hitting an
      // archive api is a bill.
      'Cache-Control': 'public, s-maxage=45, stale-while-revalidate=300',
    },
  });
}

export async function GET() {
  const address = contractAddress('duel');
  if (!address) return fail(503, 'the duel contract has no address configured on this build');

  if (!etherscanApiKey()) {
    return fail(503, 'the history reader is not configured on the server (ETHERSCAN_API_KEY)');
  }

  const result = await cachedPayload<DuelRecordPayload>({
    key: `duelhistory:${CHAIN_ID}:${address.toLowerCase()}`,
    ttlMs: CACHE_TTL_MS,
    staleRescueMs: STALE_RESCUE_MS,
    build: () => build(address),
  });

  if (!result.ok) {
    console.error('[duel-history] read failed:', result.detail);
    return fail(502, 'could not read the chain right now');
  }
  return ok(result.payload);
}
