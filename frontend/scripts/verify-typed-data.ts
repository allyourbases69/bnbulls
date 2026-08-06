// Verifies the duel signer's EIP-712 typed data against `contracts/Duel.sol`.
//
// `Duel.submitDuel` does `ECDSA.recover(hashDuelResult(result), sig) ==
// trustedSigner`. Order, names and types are ALL hashed into
// `DUEL_RESULT_TYPEHASH`, and the domain name, version, chain id and verifying
// contract are all hashed into the domain separator. So a single character of
// drift between the contract and `api/run-duel` does not degrade gracefully —
// EVERY fight reverts `InvalidSignature`, with nothing in the error pointing at
// the cause. `DECISIONS.md §13` and the Duel header both call this out by name.
//
// Four independent things are checked:
//   1. the literal typehash STRING in Duel.sol == the literal in route.ts
//   2. the string REBUILT from route.ts's `DUEL_TYPES` array == both of those
//      (so the array viem actually hashes is proved, not just the comment)
//   3. the EIP-712 domain name and version match Duel.sol's constants
//   4. viem's own `hashTypedData` uses the same typehash, computed by hashing
//      an all-zero struct two ways and comparing
//
// Run with: `npm run verify:typed-data` (from frontend/). Node 22.7+.

import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  concatHex,
  encodeAbiParameters,
  hashTypedData,
  keccak256,
  pad,
  toHex,
  type Address,
} from 'viem';

const here = dirname(fileURLToPath(import.meta.url));
const FRONTEND = join(here, '..');
const REPO = join(FRONTEND, '..');

const sol = readFileSync(join(REPO, 'contracts', 'Duel.sol'), 'utf8');
const ts = readFileSync(join(FRONTEND, 'src', 'app', 'api', 'run-duel', 'route.ts'), 'utf8');

let failures = 0;
function check(label: string, cond: boolean, detail = ''): void {
  if (cond) {
    console.log(`  ok  ${label}`);
  } else {
    failures++;
    console.error(`FAIL  ${label}${detail ? `\n      ${detail}` : ''}`);
  }
}

// ── 1. the literal strings ───────────────────────────────────────────
const solType = /DuelResult\(uint256 tokenA[^"]*\)/.exec(sol)?.[0];
const tsType = /DuelResult\(uint256 tokenA[^']*\)/.exec(ts)?.[0];
check('Duel.sol declares a DuelResult typehash string', !!solType);
check('route.ts carries a DuelResult typehash string', !!tsType);
check('the two literal strings are identical', solType === tsType, `sol=${solType}\n      ts =${tsType}`);

// ── 2. the array viem actually hashes ────────────────────────────────
const arrayBlock = /DuelResult:\s*\[([\s\S]*?)\]\s*,?\s*\}\s*as const;/.exec(ts)?.[1] ?? '';
const fields = [...arrayBlock.matchAll(/\{\s*name:\s*'(\w+)',\s*type:\s*'([\w\d]+)'\s*\}/g)].map(
  (m) => ({ name: m[1], type: m[2] }),
);
const rebuilt = `DuelResult(${fields.map((f) => `${f.type} ${f.name}`).join(',')})`;
check(`route.ts's DUEL_TYPES array parsed (${fields.length} fields)`, fields.length === 15, `got ${fields.length}`);
check('the array rebuilds to the same string', rebuilt === solType, `rebuilt=${rebuilt}`);

const typehash = keccak256(toHex(solType ?? ''));
console.log(`\n  DUEL_RESULT_TYPEHASH = ${typehash}\n`);

// ── 3. the domain ────────────────────────────────────────────────────
const solName = /EIP712_NAME\s*=\s*"([^"]+)"/.exec(sol)?.[1];
const solVersion = /EIP712_VERSION\s*=\s*"([^"]+)"/.exec(sol)?.[1];
const tsName = /EIP712_DOMAIN_NAME\s*=\s*'([^']+)'/.exec(ts)?.[1];
const tsVersion = /EIP712_DOMAIN_VERSION\s*=\s*'([^']+)'/.exec(ts)?.[1];
check(`domain name matches ("${solName}")`, !!solName && solName === tsName, `sol=${solName} ts=${tsName}`);
check(`domain version matches ("${solVersion}")`, !!solVersion && solVersion === tsVersion, `sol=${solVersion} ts=${tsVersion}`);
check('domain name is the locked value from DECISIONS.md §13', solName === 'BNBullsDuel', `got ${solName}`);

// ── 4. viem agrees, byte for byte ────────────────────────────────────
// Hash a fully-populated struct two ways: through viem's typed-data path, and
// by hand-building exactly what `Duel.hashDuelResult` builds (typehash ‖ each
// member as a 32-byte word, then `_hashTypedDataV4`). Equality proves viem's
// encoder and the contract's encoder agree about this struct, not merely that
// two strings match.
const DOMAIN = {
  name: solName!,
  version: solVersion!,
  chainId: 56,
  verifyingContract: '0x00000000000000000000000000000000000000dd' as Address,
} as const;

const message = {
  tokenA: 7n,
  tokenB: 42n,
  winnerId: 42,
  rounds: 9,
  seed: 0x1234567890abcdefn,
  newEloA: 1013,
  newEloB: 987,
  assetA: '0x00000000000000000000000000000000000000aa' as Address,
  assetB: '0x00000000000000000000000000000000000000bb' as Address,
  stakeA: 5_000_000_000_000_000_000n,
  stakeB: 5_000_000_000_000_000_000n,
  seqA: 3n,
  seqB: 11n,
  nonce: 0xdeadbeefn,
  expiry: 1_800_000_000n,
};

const viemDigest = hashTypedData({
  domain: DOMAIN,
  types: { DuelResult: fields as { name: string; type: string }[] },
  primaryType: 'DuelResult',
  message,
});

// `_hashTypedDataV4(structHash)` == keccak256(0x1901 ‖ domainSeparator ‖ structHash)
const EIP712_DOMAIN_TYPEHASH = keccak256(
  toHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
);
const domainSeparator = keccak256(
  encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
    [
      EIP712_DOMAIN_TYPEHASH,
      keccak256(toHex(DOMAIN.name)),
      keccak256(toHex(DOMAIN.version)),
      BigInt(DOMAIN.chainId),
      DOMAIN.verifyingContract,
    ],
  ),
);
// The contract encodes in two halves and concatenates; every member is a value
// type, so that is byte-identical to encoding all sixteen words at once.
const structHash = keccak256(
  concatHex([
    typehash,
    pad(toHex(message.tokenA)),
    pad(toHex(message.tokenB)),
    pad(toHex(message.winnerId)),
    pad(toHex(message.rounds)),
    pad(toHex(message.seed)),
    pad(toHex(message.newEloA)),
    pad(toHex(message.newEloB)),
    pad(message.assetA),
    pad(message.assetB),
    pad(toHex(message.stakeA)),
    pad(toHex(message.stakeB)),
    pad(toHex(message.seqA)),
    pad(toHex(message.seqB)),
    pad(toHex(message.nonce)),
    pad(toHex(message.expiry)),
  ]),
);
const manualDigest = keccak256(concatHex(['0x1901', domainSeparator, structHash]));

check(
  'viem hashes the struct exactly as Duel.hashDuelResult does',
  viemDigest === manualDigest,
  `viem  =${viemDigest}\n      manual=${manualDigest}`,
);

if (failures > 0) {
  console.error(`\n${failures} check(s) FAILED — every fight would revert InvalidSignature.`);
  process.exit(1);
}
console.log('\nOK — the signer and Duel.sol agree on the typed data.');
