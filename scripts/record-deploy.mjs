#!/usr/bin/env node
// bnbulls — refine deployments/<chainid>.json with the EXACT deploy block of
// every contract, read back off forge's broadcast receipts.
//
//   node scripts/record-deploy.mjs 97
//   node scripts/record-deploy.mjs 97 --script DeployTestnet.s.sol
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THIS EXISTS
// ─────────────────────────────────────────────────────────────────────────────
// The deploy script records `block.number` as it stood BEFORE the first
// transaction — safe, because a cursor that is early only re-reads empty
// blocks, whereas a late one loses events forever and a ZERO one forces a
// full-chain rescan on every keeper restart (DEPLOY-SAFETY-PREFLIGHT §4).
//
// But safe is not exact, and on BSC "a few blocks early" is a few thousand
// getLogs rows on a public RPC that caps block range. Once the broadcast has
// landed, the receipts hold the real numbers. This reads them back and writes
// `deployBlock` (the earliest) plus a per-contract `deployBlocks` map.
//
// It NEVER writes an env file, and it will not touch a record for a chain the
// broadcast artifact does not belong to.

import { readFileSync, writeFileSync, existsSync } from "node:fs";

const chainId = process.argv[2];
if (!chainId || !/^\d+$/.test(chainId)) {
  console.error("usage: node scripts/record-deploy.mjs <chainId> [--script Name.s.sol]");
  process.exit(1);
}

const i = process.argv.indexOf("--script");
const scriptName = i >= 0 ? process.argv[i + 1] : "Deploy.s.sol";

const recordPath =
  chainId === "31337" ? ".state/anvil/deployment.json" : `deployments/${chainId}.json`;
const broadcastPath = `broadcast/${scriptName}/${chainId}/run-latest.json`;

if (!existsSync(recordPath)) {
  console.error(`no deployment record at ${recordPath}`);
  process.exit(1);
}
if (!existsSync(broadcastPath)) {
  console.error(`no broadcast artifact at ${broadcastPath}`);
  console.error("(was the run --broadcast, and is --script the right file name?)");
  process.exit(1);
}

const record = JSON.parse(readFileSync(recordPath, "utf8"));
const run = JSON.parse(readFileSync(broadcastPath, "utf8"));

if (String(run.chain) !== chainId) {
  console.error(
    `REFUSING: the broadcast artifact is chain ${run.chain}, the record is chain ${chainId}.`
  );
  process.exit(1);
}

// hash -> block number
const blockOf = new Map();
for (const r of run.receipts || []) {
  blockOf.set(r.transactionHash, parseInt(r.blockNumber, 16));
}
// address -> block, for CREATE transactions only
const createdAt = new Map();
for (const t of run.transactions || []) {
  if (t.transactionType !== "CREATE" && t.transactionType !== "CREATE2") continue;
  const b = blockOf.get(t.hash);
  if (b !== undefined && t.contractAddress) {
    createdAt.set(t.contractAddress.toLowerCase(), b);
  }
}

const blocks = {};
let earliest = Infinity;
for (const [name, addr] of Object.entries(record.contracts || {})) {
  const b = createdAt.get(String(addr).toLowerCase());
  if (b === undefined) continue; // pre-existing (four.meme BNBULL) or resumed
  blocks[name] = b;
  if (b < earliest) earliest = b;
}

if (earliest === Infinity) {
  console.log("no CREATE receipts matched the recorded addresses — record unchanged.");
  console.log("(a fully resumed run, or a pre-existing token: both are fine.)");
  process.exit(0);
}

const before = record.deployBlock;
record.deployBlock = earliest;
record.deployBlocks = blocks;
writeFileSync(recordPath, JSON.stringify(record, null, 2) + "\n");

console.log(`chain ${chainId}`);
console.log(`  deployBlock ${before} -> ${earliest}`);
for (const [name, b] of Object.entries(blocks)) {
  console.log(`    ${name.padEnd(18)} ${b}`);
}
console.log("");
console.log(`wrote ${recordPath}`);
console.log("Point every keeper/indexer cursor at deployBlock. Never 0.");
