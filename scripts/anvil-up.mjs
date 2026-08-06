#!/usr/bin/env node
// bnbulls — ONE COMMAND for a full local chain.
//
//   node scripts/anvil-up.mjs
//
// Starts anvil, deploys the mocks + all nine contracts, wires them, verifies
// every silent-failure leg, seeds real game state (mint / fight / kill /
// revive / jackpot / listing), and prints the NEXT_PUBLIC_* block ready to
// paste into frontend/.env.local. Then it stays in the foreground so the chain
// is still there when you open the site. Ctrl-C stops it.
//
// Flags:
//   --no-seed     deploy and wire, but leave the chain empty
//   --no-wait     tear anvil down as soon as the run finishes (CI)
//   --port <n>    default 8545
//   --reuse       do not start anvil; use whatever is already on the port
//
// ─────────────────────────────────────────────────────────────────────────────
// ⚠ THE ADDRESSES THIS PRINTS ARE LOCAL AND WORTHLESS. They are written to
//   .state/anvil/ — which .gitignore already blocks — and NEVER to a real env
//   file. That separation is the whole lesson of DEPLOY-SAFETY-PREFLIGHT §1:
//   fighting fefers lost 154 USDT permanently because a fork rehearsal wrote
//   its throwaway addresses into the MAINNET env file and nobody re-checked
//   them. Do not "helpfully" teach this script to write frontend/.env.local.

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const val = (f, dflt) => {
  const i = args.indexOf(f);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};

const PORT = val("--port", "8545");
const RPC = `http://127.0.0.1:${PORT}`;
const CHAIN_ID = 31337;

// anvil's account 0. A published test key: it holds nothing anywhere real, and
// this file refuses to run against anything but chain 31337.
const PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

for (const dir of ["deployments", ".state/anvil"]) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

// ── 0. the dealt name table has to exist before Bulls can be constructed ────

if (!existsSync("deployments/names.json")) {
  console.log("• dealing the 501 names (deployments/names.json)…");
  run("node", ["scripts/gen-names.mjs"]);
}

// ── 1. anvil ────────────────────────────────────────────────────────────────

let anvil = null;
if (!has("--reuse")) {
  console.log(`• starting anvil on ${RPC}…`);
  anvil = spawn("anvil", ["--port", PORT, "--chain-id", String(CHAIN_ID), "--silent"], {
    stdio: ["ignore", "inherit", "inherit"],
    shell: process.platform === "win32",
  });
  anvil.on("exit", (code) => {
    if (code !== null && code !== 0) {
      console.error(`anvil exited with code ${code}`);
      process.exit(code);
    }
  });
}

await waitForRpc();
console.log(`• anvil is up (chain ${CHAIN_ID})`);

// ── 2. deploy + wire + verify, then seed ────────────────────────────────────
//
// `--slow` sends one transaction at a time and waits for each receipt. Without
// it a ~100-transaction script can outrun a local node's mempool ordering and
// a middle transaction quietly ends up without a receipt — which looks exactly
// like a wiring call that never happened.

try {
  console.log("• deploying + wiring + verifying…");
  forge("script/anvil/DeployLocal.s.sol:DeployLocal");

  if (!has("--no-seed")) {
    console.log("• seeding game state (mint / fight / kill / revive / jackpot)…");
    forge("script/anvil/Seed.s.sol:Seed");
  }
} catch (e) {
  stop();
  console.error("\n" + String(e.message || e));
  process.exit(1);
}

// ── 3. the paste block ──────────────────────────────────────────────────────

const env = readFileSync(".state/anvil/frontend.env.local", "utf8");
console.log("");
console.log("═".repeat(70));
console.log(" paste into frontend/.env.local");
console.log("═".repeat(70));
console.log(env);
console.log("═".repeat(70));
console.log(" deployment record: .state/anvil/deployment.json");
console.log(" anvil accounts:    account 0 is the owner/keeper/signer,");
console.log("                    account 1 is the opponent in the seeded duels.");
console.log("═".repeat(70));

if (has("--no-wait")) {
  stop();
  process.exit(0);
}

console.log("");
console.log("anvil is still running. Ctrl-C to stop it.");
process.on("SIGINT", () => {
  stop();
  process.exit(0);
});
// Park forever.
await new Promise(() => {});

// ── helpers ─────────────────────────────────────────────────────────────────

function forge(target) {
  run("forge", [
    "script",
    target,
    "--rpc-url",
    RPC,
    "--broadcast",
    "--slow",
    "--private-key",
    PK,
  ]);
}

function run(cmd, argv) {
  const r = spawnSync(cmd, argv, {
    stdio: "inherit",
    shell: process.platform === "win32",
  });
  if (r.status !== 0) {
    throw new Error(`${cmd} ${argv.join(" ")}  ->  exit ${r.status}`);
  }
}

async function waitForRpc() {
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      const j = await res.json();
      if (parseInt(j.result, 16) === CHAIN_ID) return;
      throw new Error(
        `something is already listening on ${RPC} and it is chain ` +
          `${parseInt(j.result, 16)}, not ${CHAIN_ID}. Refusing to touch it.`
      );
    } catch (e) {
      if (String(e.message).includes("Refusing")) {
        stop();
        console.error(e.message);
        process.exit(1);
      }
      await sleep(200);
    }
  }
  stop();
  console.error(`anvil did not come up on ${RPC}`);
  process.exit(1);
}

function stop() {
  if (anvil && !anvil.killed) anvil.kill();
}
