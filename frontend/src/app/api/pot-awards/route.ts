/**
 * GET /api/pot-awards?pot=jackpotBnb — every time a jackpot has paid somebody.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THIS IS A SERVER ROUTE AND NOT A HOOK
 * ═══════════════════════════════════════════════════════════════════════
 *
 * The pot cards used to sweep `Awarded` from the browser through
 * `useContractLogs`, and the result was not a slow card — it was a card stuck on
 * "loading…" forever, on both pots, for every visitor. Measured on bnb mainnet:
 * publicnode 403s any window reaching past its retention, drpc 400s, both
 * dataseeds answer `-32005` to even a 500-block window, and the free alchemy key
 * caps `eth_getLogs` to TEN blocks. Neither a 403 nor a rate limit is a
 * range-cap error, so the client scanner's halving path never fired and the
 * chunks disappeared without a sound. The full table is in `lib/serverLogs.ts`.
 *
 * The etherscan v2 multichain api answers the same query for the whole range in
 * one request, with block timestamps attached, using a key that never leaves the
 * server. `⚠ NO KEY MAY GAIN A `NEXT_PUBLIC_` PREFIX` — that prefix is the only
 * thing deciding whether Next inlines a variable into the browser bundle.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE THREE ANSWERS, AND WHY AN EMPTY POT IS ONE OF THEM
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   200 + awards        the payout trail, with the pot's own `awardCount` so
 *                       the card can check its own list
 *   200 + no awards     nobody has hit this pot yet — TRUE on both pots today
 *   502 + error         we could not read the chain
 *
 * The middle one is the normal early state of this game and it must render as a
 * plain sentence, never as a spinner and never as a shrug. Collapsing it into
 * the last one would tell a visitor the site is broken; collapsing the last one
 * into it would tell them a pot has never paid out when we simply could not
 * look.
 */
import { NextResponse } from 'next/server';
import {
  createPublicClient,
  decodeEventLog,
  fallback,
  http,
  parseAbi,
  toEventSelector,
} from 'viem';
import { JackpotAbi, JackpotNativeAbi } from '@/lib/abi';
import { CHAIN_ID, contractAddress, deployBlock, isNativePot, rpcUrls } from '@/lib/env';
import { isValidBullId } from '@/lib/art/collection';
import { cachedPayload } from '@/lib/serverCache';
import { etherscanApiKey, fetchLogsByTopic0 } from '@/lib/serverLogs';
import type { JackpotAwardRow, JackpotAwardsPayload } from '@/lib/jackpotAwards';

export const runtime = 'nodejs';
/** Caching is explicit below (cdn header + kv + memory), never Next's guess. */
export const dynamic = 'force-dynamic';

/**
 * How long a read is served before another one is made.
 *
 * Longer than the deposit feed's 45s because payouts are RARE — a pot fires on
 * a 1-in-N roll, not on every fight — so a minute of staleness costs a visitor
 * nothing while cutting the archive api bill on a public page. The payload
 * carries `fetchedAt` either way.
 */
const CACHE_TTL_MS = 60_000;
/** How long a cached read may still be served after a refresh has failed. */
const STALE_RESCUE_MS = 10 * 60_000;

/** `Awarded(address indexed winner, uint256 indexed tokenId, uint256 amount, uint256 ticketId)`
 *  — byte-identical on `Jackpot.sol` and `JackpotNative.sol`. */
const AWARDED_TOPIC = toEventSelector('Awarded(address,uint256,uint256,uint256)');
const AWARDED_ABI = parseAbi([
  'event Awarded(address indexed winner, uint256 indexed tokenId, uint256 amount, uint256 ticketId)',
]);

type PotName = 'jackpotBnbull' | 'jackpotBnb';

function client() {
  return createPublicClient({ transport: fallback(rpcUrls().map((u) => http(u))) });
}

/**
 * The pot's own counters. Both are best-effort: a card that shows real rows
 * without a cross-check is still worth showing, it just cannot claim the list
 * is complete.
 */
async function readCounters(
  pot: PotName,
  address: `0x${string}`,
): Promise<{ awardCount: number | null; totalAwarded: bigint | null }> {
  const c = client();
  const abi = isNativePot(pot) ? JackpotNativeAbi : JackpotAbi;
  const one = async (functionName: 'awardCount' | 'totalAwarded') => {
    try {
      return (await c.readContract({ address, abi, functionName })) as bigint;
    } catch {
      return null;
    }
  };
  const [count, total] = await Promise.all([one('awardCount'), one('totalAwarded')]);
  return {
    // The counter is a uint256 on chain and a payout list in the browser. It
    // cannot realistically exceed a Number, but clamping beats a silent NaN.
    awardCount: count === null ? null : Number(count <= 1_000_000n ? count : 1_000_000n),
    totalAwarded: total,
  };
}

async function build(pot: PotName, address: `0x${string}`): Promise<JackpotAwardsPayload> {
  // Absent a configured deploy block, start at genesis: etherscan is not
  // range-capped, so "everything" is a legitimate answer here in a way it never
  // is against a public node.
  const fromBlock = deployBlock() ?? 0n;

  // ⚠ THE SWEEP IS ALLOWED TO FAIL THE REQUEST, AND NOTHING ELSE IS. With no
  // history there is no list, and an empty list would be indistinguishable from
  // a pot nobody has ever hit — which is exactly the confusion this route
  // exists to prevent. The counter reads below degrade to null instead.
  const sweep = await fetchLogsByTopic0({
    chainId: CHAIN_ID,
    address,
    topic0: AWARDED_TOPIC,
    fromBlock,
  });

  const counters = await readCounters(pot, address);

  const awards: JackpotAwardRow[] = [];
  for (const log of sweep.logs) {
    let winner: `0x${string}`;
    let tokenId: bigint;
    let amount: bigint;
    let ticketId: bigint;
    try {
      const decoded = decodeEventLog({
        abi: AWARDED_ABI,
        data: log.data,
        topics: log.topics as [`0x${string}`, ...`0x${string}`[]],
      });
      winner = decoded.args.winner;
      tokenId = decoded.args.tokenId;
      amount = decoded.args.amount;
      ticketId = decoded.args.ticketId;
    } catch {
      // A log that does not decode is dropped rather than guessed at. It cannot
      // happen for a topic0 we selected on, but a dropped row is a smaller lie
      // than a fabricated one.
      continue;
    }
    const id = Number(tokenId);
    // A payout naming a bull outside the collection cannot be drawn or linked.
    // The pot cannot emit one, so this only fires against a wrong address in
    // config — in which case a blank list is the right answer.
    if (!isValidBullId(id)) continue;

    awards.push({
      winner,
      tokenId: id,
      amount: amount.toString(),
      ticketId: ticketId.toString(),
      txHash: log.txHash,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      timestamp: log.timestamp,
    });
  }

  // Newest first: "recent awards" means the last people to hit it.
  awards.reverse();

  return {
    pot,
    address,
    chainId: CHAIN_ID,
    awards,
    awardCount: counters.awardCount,
    totalAwarded: counters.totalAwarded === null ? null : counters.totalAwarded.toString(),
    truncated: sweep.truncated,
    fetchedAt: Date.now(),
  };
}

function fail(status: number, error: string) {
  return NextResponse.json({ error }, { status, headers: { 'Cache-Control': 'no-store' } });
}

function ok(payload: JackpotAwardsPayload) {
  return NextResponse.json(payload, {
    headers: {
      // The cdn absorbs the crowd; the origin refreshes on its own clock. This
      // is a public page and every uncached visitor hitting an archive api is a
      // bill.
      'Cache-Control': 'public, s-maxage=60, stale-while-revalidate=600',
    },
  });
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
    return fail(503, 'the history reader is not configured on the server (ETHERSCAN_API_KEY)');
  }

  const result = await cachedPayload<JackpotAwardsPayload>({
    key: `potawards:${CHAIN_ID}:${address.toLowerCase()}`,
    ttlMs: CACHE_TTL_MS,
    staleRescueMs: STALE_RESCUE_MS,
    build: () => build(pot, address),
  });

  if (!result.ok) {
    console.error('[pot-awards] read failed:', result.detail);
    return fail(502, 'could not read the chain right now');
  }
  return ok(result.payload);
}
