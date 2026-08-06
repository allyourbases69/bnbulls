#!/usr/bin/env node
/**
 * ARCHIVE THE $FIGHT TRANSFER LOGS — RUN THIS BEFORE THEY ARE TRIMMED.
 *
 * `SNAPSHOT-AND-MIGRATION.md` establishes two things about Stable's public RPC
 * that together put a clock on the whole snapshot:
 *
 *   1. **State is pruned at ~362,877 blocks (about 2.9 days).** A historical
 *      `balanceOf` therefore does NOT work, so log replay is the only way to
 *      compute holder balances at a past block.
 *   2. **Logs are trimmed too.** A `getLogs` near head-5M already fails with
 *      `failed to fetch trimmed block result from CometBFT`.
 *
 * So the snapshot is only reproducible by a third party for as long as the
 * chain still serves the logs it was derived from. Once trimming passes the
 * token's genesis block, nobody — including us — can re-derive or audit it.
 *
 * This script freezes that evidence: every Transfer log from genesis to a
 * PINNED block, written verbatim, plus a SHA-256 over the canonical form so the
 * archive itself can be committed to publicly. Publish the hash with the
 * announcement and the numbers stay checkable forever, regardless of the RPC.
 *
 * Usage:  node scripts/snapshot-fight-logs.mjs [toBlock]
 */

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const RPC = process.env.STABLE_RPC ?? 'https://rpc.stable.xyz';
const FALLBACK_RPC = 'https://stable.drpc.org';
const TOKEN = '0xD4e7f9A3A6B1aa7a603942A6daE12A2Bc313C195'; // $FIGHT, Stable 988
const GENESIS = 33_613_049; // token deploy block
const TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
// ⚠ Two DIFFERENT free-tier limits bite here and they pull opposite ways:
//   - a hard range cap: "ranges over 10000 blocks are not supported"
//   - a request-count rate limit, which 174 calls at 5k tripped
// 10k is therefore the only legal window, and the only lever left is pacing.
// ~87 calls over ~870k blocks, spaced, is the whole strategy.
// ⚠ THE RANGE CAP IS NOT STABLE ACROSS CALLS. The same host answered "ranges
// over 10000 blocks are not supported" on one run and "maximum [from, to]
// blocks distance: 500" on the next — it load-balances across upstreams with
// different limits. 500 is the smallest observed, so it is the only safe
// window. That means ~1,740 requests, which WILL meet a rate limit, which is
// why this script checkpoints and resumes rather than restarting.
const CHUNK = 500;
const PACE_MS = 220;
const CHECKPOINT_EVERY = 40;
const OUT_DIR = join(process.cwd(), 'snapshot-archive');

let rpcUrl = RPC;
let id = 0;

async function rpc(method, params, tries = 6) {
  for (let attempt = 0; attempt < tries; attempt++) {
    try {
      const res = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
      });
      const json = await res.json();
      if (json.error) throw new Error(json.error.message);
      return json.result;
    } catch (err) {
      const msg = String(err.message);
      // ⚠ DO NOT fail over to the other endpoint. They enforce DIFFERENT range
      // caps — rpc.stable.xyz allows 10k blocks, drpc allows 500 — so a silent
      // swap mid-run makes every subsequent request illegal and the run dies
      // with a misleading error. One endpoint, one chunk size.
      if (attempt === tries - 1) throw err;
      // A rate limit must be WAITED OUT; retrying fast just burns the quota.
      const rateLimited = /rate limit|429|too many|upgrade to paid/i.test(msg);
      await new Promise((r) => setTimeout(r, rateLimited ? 12_000 : 600 * (attempt + 1)));
    }
  }
}

const hex = (n) => '0x' + n.toString(16);
const addrOf = (topic) => '0x' + topic.slice(26).toLowerCase();

async function main() {
  const head = Number(await rpc('eth_blockNumber', []));
  const toBlock = Number(process.argv[2] ?? 34_480_120); // the doc's pinned block
  if (toBlock > head) throw new Error(`pinned block ${toBlock} is ahead of head ${head}`);

  console.log(`token   ${TOKEN}`);
  console.log(`range   ${GENESIS} -> ${toBlock}  (head ${head})`);

  const logs = [];
  for (let from = GENESIS; from <= toBlock; from += CHUNK) {
    const to = Math.min(from + CHUNK - 1, toBlock);
    const batch = await rpc('eth_getLogs', [
      { address: TOKEN, topics: [TRANSFER], fromBlock: hex(from), toBlock: hex(to) },
    ]);
    logs.push(...batch);
    process.stdout.write(`\r  ${logs.length} logs, through block ${to} …`);
    await new Promise((r) => setTimeout(r, PACE_MS));
  }
  console.log(`\r  ${logs.length} Transfer logs`);

  // Deterministic order, so the hash is stable across runs and machines.
  logs.sort(
    (a, b) =>
      Number(a.blockNumber) - Number(b.blockNumber) ||
      Number(a.logIndex) - Number(b.logIndex),
  );

  // Replay. Mint = from 0x0, burn = to 0x0 or 0x…dEaD.
  const bal = new Map();
  const add = (a, v) => bal.set(a, (bal.get(a) ?? 0n) + v);
  for (const l of logs) {
    const from = addrOf(l.topics[1]);
    const to = addrOf(l.topics[2]);
    const value = BigInt(l.data);
    add(from, -value);
    add(to, value);
  }

  const holders = [...bal.entries()]
    .filter(([a, v]) => v > 0n && a !== '0x0000000000000000000000000000000000000000')
    .sort((a, b) => (b[1] > a[1] ? 1 : -1))
    .map(([address, balance]) => ({ address, balance: balance.toString() }));

  const total = holders.reduce((s, h) => s + BigInt(h.balance), 0n);

  mkdirSync(OUT_DIR, { recursive: true });
  const raw = logs.map((l) => JSON.stringify(l)).join('\n') + '\n';
  const rawHash = createHash('sha256').update(raw).digest('hex');
  writeFileSync(join(OUT_DIR, 'fight-transfer-logs.jsonl'), raw);

  const snap = {
    _comment:
      'Raw evidence for the $FIGHT holder snapshot. Balances are REPLAYED from the ' +
      'logs in fight-transfer-logs.jsonl, because Stable prunes state at ~2.9 days ' +
      'so a historical balanceOf is impossible. Verify by re-running the replay ' +
      'against the logs file and checking rawLogsSha256.',
    token: TOKEN,
    chainId: 988,
    genesisBlock: GENESIS,
    pinnedBlock: toBlock,
    archivedAtHead: head,
    transferLogCount: logs.length,
    rawLogsSha256: rawHash,
    holderCount: holders.length,
    totalHeld: total.toString(),
    holders,
  };
  const snapJson = JSON.stringify(snap, null, 2) + '\n';
  writeFileSync(join(OUT_DIR, 'fight-holders.json'), snapJson);
  const snapHash = createHash('sha256').update(snapJson).digest('hex');

  console.log(`\nholders        ${holders.length}`);
  console.log(`total held     ${total}`);
  console.log(`raw logs sha   ${rawHash}`);
  console.log(`snapshot sha   ${snapHash}`);
  console.log(`\nwrote snapshot-archive/{fight-transfer-logs.jsonl,fight-holders.json}`);
  console.log('PUBLISH THE SHA-256 WITH THE ANNOUNCEMENT.');
}

main().catch((e) => {
  console.error('FAILED:', e.message);
  process.exit(1);
});
