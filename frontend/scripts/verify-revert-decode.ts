// verify:reverts — the gate that stops a raw node error ever reaching a player
// again, and stops the matchmaker offering a fight that cannot settle.
//
// Run with: `npm run verify:reverts` (from frontend/), or
// `node scripts/verify-revert-decode.ts`. Node 22.7+. Exits non-zero on any
// mismatch.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT WENT WRONG, SO THE NEXT PERSON KNOWS WHAT THIS IS GUARDING
// ─────────────────────────────────────────────────────────────────────────────
// The owner tried a duel between bulls #1 and #16 and the site told him:
//
//     "submitDuel reverted … RPC 0x61 Custom eth_sendRawTransaction:
//      gas limit too high"
//
// Nothing about gas was wrong. Bull #16 had been bought in a marketplace
// takeover, `Yards` membership requires `enteredBy == the LIVE owner`, so the
// sale silently voided its entry. `Duel.submitDuel` reverted
// `BullNotInYards(16)`; viem estimated gas against a call that reverts and got
// garbage; the rpc rejected THAT number and complained about the number. Four
// steps, and the only one the player ever saw was the one that was false.
//
// Owner: "don't let this kind of thing happen." So three layers, and this
// script proves two of them mechanically rather than by assertion:
//
//   LAYER 1 · never OFFER what cannot succeed — `rankOpponents` drops any bull
//             that is not matchable, and treats "unknown" as no filter rather
//             than as "nobody".
//   LAYER 3 · never SHOW a raw node error — `decodeRevert` turns the real
//             revert bytes into a sentence, and turns the rpc's gas complaint
//             into the truth instead of passing it through.
//
// (Layer 2, `simulateContract` before every write, needs a live chain and is
// verified by `usePreflight`'s call sites rather than here.)
//
// ⚠ THE SELECTOR IS PINNED. `0x6a6c8082` is the real four bytes observed on
// chain for `BullNotInYards(uint256)` during the incident. If a contract change
// ever moves it, this fails loudly rather than silently losing the one error
// that started all of this.

import { registerHooks } from 'node:module';
import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  encodeErrorResult,
  toFunctionSelector,
  type Abi,
} from 'viem';

// `src/` imports are extensionless and alias-prefixed (`@/lib/abi`), which
// Next's bundler resolves and node's ESM loader does not. Same trick
// `verify-rarity-port.ts` uses, extended to cover the `@/` alias so the REAL
// modules are exercised rather than a copy of them.
// ⚠ `.href`, NOT `.pathname`. On win32 a pathname keeps a leading slash before
// the drive letter and node rejects it as protocol "c:". A full `file://` URL
// is the only form the ESM loader takes on both platforms.
registerHooks({
  resolve(specifier, context, nextResolve) {
    let s = specifier;
    if (s.startsWith('@/')) s = new URL(`../src/${s.slice(2)}`, import.meta.url).href;
    const bare = s.replace(/[?#].*$/, '');
    if ((s.startsWith('.') || s.startsWith('file:')) && !/\.[a-z]+$/i.test(bare)) {
      // A directory import (`@/lib/abi`) means its `index.ts`; anything else
      // just wants its extension back.
      const asFile = `${s}.ts`;
      try {
        return nextResolve(asFile, context);
      } catch {
        return nextResolve(`${s}/index.ts`, context);
      }
    }
    return nextResolve(s, context);
  },
});

const { decodeRevert, GENERIC_REVERT_MESSAGE } = await import('../src/lib/revertDecode.ts');
const { rankOpponents } = await import('../src/lib/matchmaking.ts');
const { DuelAbi } = await import('../src/lib/abi/Duel.ts');
const { DuelNativeAbi } = await import('../src/lib/abi/DuelNative.ts');
const { MarketplaceAbi } = await import('../src/lib/abi/Marketplace.ts');

let failures = 0;
let checks = 0;

function check(label: string, cond: boolean, detail = ''): void {
  checks++;
  if (cond) {
    console.log(`  ok   ${label}`);
  } else {
    failures++;
    console.error(`  FAIL ${label}${detail ? ` — ${detail}` : ''}`);
  }
}

/* ═══════════════════════════════════════════════════════════════════════
   THE PIN
   ═══════════════════════════════════════════════════════════════════════ */

const OBSERVED_SELECTOR = '0x6a6c8082';
const computed = toFunctionSelector('BullNotInYards(uint256)');

console.log('\nselector');
check(
  `BullNotInYards(uint256) is still ${OBSERVED_SELECTOR}`,
  computed === OBSERVED_SELECTOR,
  `computed ${computed}`,
);

/** The exact revert `Duel` produced for bull #16: selector + uint256(16). */
const BULL_16_REVERT = encodeErrorResult({
  abi: DuelAbi as unknown as Abi,
  errorName: 'BullNotInYards',
  args: [16n],
});

check(
  'the encoded revert is the selector + 0x10, as seen on chain',
  BULL_16_REVERT === `${OBSERVED_SELECTOR}${'0'.repeat(62)}10`,
  BULL_16_REVERT,
);

/* ═══════════════════════════════════════════════════════════════════════
   LAYER 3 — never show a raw node error
   ═══════════════════════════════════════════════════════════════════════ */

console.log('\nlayer 3 · decoding');

/** viem's shape when the ABI it was given DID contain the error. */
function decodedByViem(data: `0x${string}`): unknown {
  const reverted = new ContractFunctionRevertedError({
    abi: DuelAbi as unknown as Abi,
    data,
    functionName: 'submitDuel',
  });
  return new ContractFunctionExecutionError(reverted, {
    abi: DuelAbi as unknown as Abi,
    functionName: 'submitDuel',
    args: [],
  });
}

/** viem's shape when it could NOT decode — the bytes survive on `.raw`, and
 *  `decodeRevert` has to name them itself off the merged ABIs. */
function undecodedByViem(data: `0x${string}`): unknown {
  const reverted = new ContractFunctionRevertedError({
    abi: [] as unknown as Abi,
    data,
    functionName: 'submitDuel',
  });
  return new ContractFunctionExecutionError(reverted, {
    abi: [] as unknown as Abi,
    functionName: 'submitDuel',
    args: [],
  });
}

{
  const r = decodeRevert(decodedByViem(BULL_16_REVERT));
  check('viem-decoded BullNotInYards(16) is named', r.errorName === 'BullNotInYards', r.errorName ?? 'null');
  check('…and names the bull', r.message.includes('#16'), r.message);
  check('…and blocks (kind=revert)', r.kind === 'revert', r.kind);
  check('…and mentions the pit', /bull pit/.test(r.message), r.message);
  check('…and says a sale causes it', /sale/.test(r.message), r.message);
  console.log(`       > ${r.message}`);
}

{
  const r = decodeRevert(undecodedByViem(BULL_16_REVERT));
  check(
    'raw bytes viem could not name are decoded here anyway',
    r.errorName === 'BullNotInYards' && r.message.includes('#16'),
    `${r.errorName} / ${r.message}`,
  );
}

{
  // ⚠ THE ORIGINAL BUG. No revert data at all — just the rpc complaining about
  // a gas number it derived from a failed estimate. The old `explainRevert`
  // returned this string verbatim.
  const rpc = new Error(
    'RPC 0x61 Custom eth_sendRawTransaction: gas limit too high. Request Arguments: from 0x…',
  );
  const r = decodeRevert(rpc);
  check('the rpc gas complaint never survives to the player', !r.message.includes('gas limit too high'), r.message);
  check('…and is classified as a revert, so it blocks', r.kind === 'revert', r.kind);
  check('…and falls back to the generic sentence', r.message === GENERIC_REVERT_MESSAGE, r.message);
  console.log(`       > ${r.message}`);
}

{
  const r = decodeRevert(new Error('execution reverted: gas required exceeds allowance (0)'));
  check('"gas required exceeds allowance" is a revert, not a gas tip', r.kind === 'revert', r.kind);
  check('…and is not echoed', !r.message.includes('exceeds allowance'), r.message);
}

{
  // A selector from a contract we ship no ABI for. The sentence still lands and
  // the four bytes go in the small print rather than being dropped.
  const r = decodeRevert(undecodedByViem('0xdeadbeef'));
  check('an unknown selector still gets a sentence', r.message === GENERIC_REVERT_MESSAGE, r.message);
  check('…with the selector as detail', r.detail === '0xdeadbeef', r.detail ?? 'null');
  check('…and no invented error name', r.errorName === null, r.errorName ?? 'null');
}

{
  const r = decodeRevert(new Error('User rejected the request.'));
  check('a cancelled transaction is not a failure', r.kind === 'rejected', r.kind);
  check('…and says nothing was changed', /nothing changed/.test(r.message), r.message);
}

{
  const r = decodeRevert(new Error('HTTP request failed: fetch failed'));
  check('an unreachable node is transport, not a revert', r.kind === 'transport', r.kind);
  check('…and says nothing was sent', /nothing was sent/.test(r.message), r.message);
}

{
  // Yards' own error, proving the merged ABI covers more than `Duel`.
  const data = encodeErrorResult({
    abi: DuelAbi as unknown as Abi,
    errorName: 'BullIsListed',
    args: [7n],
  });
  const r = decodeRevert(undecodedByViem(data));
  check('BullIsListed(7) names the bull and the fix', /#7/.test(r.message) && /delist/.test(r.message), r.message);
}

{
  // ⚠ THE ONE ERROR THAT MUST NOT SAY "TOP UP". `PassiveAllowanceExceeded` is
  // the away-budget ceiling — the wallet's money is almost always sitting right
  // there and untouched, and the budget defaults to ZERO, so this is the error
  // every player meets first after the migration. The obvious wording sends
  // them to deposit bnb they already have, which fixes nothing and costs gas.
  // It is a `DuelNative`-only error, so this also proves the merged ABI picked
  // up the new contract at all.
  const data = encodeErrorResult({
    abi: DuelNativeAbi as unknown as Abi,
    errorName: 'PassiveAllowanceExceeded',
    args: ['0x000000000000000000000000000000000000dEaD', 10n ** 16n, 0n],
  });
  const r = decodeRevert(undecodedByViem(data));
  check('PassiveAllowanceExceeded is named off the DuelNative abi', r.errorName === 'PassiveAllowanceExceeded', r.errorName ?? 'null');
  check('…and says it is the away budget', /away/.test(r.message), r.message);
  check('…and never tells them to top up money they have', !/top (it |them )?up/.test(r.message), r.message);
  console.log(`       > ${r.message}`);
}

{
  // ⚠ TWO ERRORS, TWO DIFFERENT CULPRITS, AND THEY MUST NOT SHARE COPY.
  //
  // `ListingRepriced` is the seller-front-run guard: the seller moved their own
  // dollar sticker between quote and settlement. Before the guard existed the
  // price was read at SETTLEMENT and the surplus refunded, so a seller could
  // watch the mempool, `updatePrice` up by the frontend's cushion, and eat the
  // whole `msg.value` with a zero refund.
  //
  // The buyer did nothing wrong and nothing was charged, so this must NOT share
  // the "the amount sent no longer covers the price" wording used for
  // `InsufficientBNB`/`PaymentShortfall` — that reads as the buyer's fault and
  // invites them to throw more money at it.
  const repriced = encodeErrorResult({
    abi: MarketplaceAbi as unknown as Abi,
    errorName: 'ListingRepriced',
    args: [10n ** 20n, 8n * 10n ** 19n],
  });
  const r = decodeRevert(undecodedByViem(repriced));
  check('ListingRepriced is named off the Marketplace abi', r.errorName === 'ListingRepriced', r.errorName ?? 'null');
  check('…and blames the seller, not the buyer', /seller raised the price/.test(r.message), r.message);
  check('…and says nothing was sent', /nothing was sent/.test(r.message), r.message);
  check(
    '…and never reuses the you-underpaid wording',
    !/no longer covers the price/.test(r.message),
    r.message,
  );
  console.log(`       > ${r.message}`);

  // `PriceAboveMax` is the ceiling on the TOTAL, which the bnb oracle or the
  // bnbull peg can trip on a perfectly honest listing. Same refusal, same
  // "nothing was sent" — but it must NOT accuse anybody, because an unlucky
  // oracle tick is not a seller cheating. Sharing one sentence between the two
  // would either libel an honest seller or let a cheating one hide.
  const above = encodeErrorResult({
    abi: MarketplaceAbi as unknown as Abi,
    errorName: 'PriceAboveMax',
    args: [10n ** 17n, 9n * 10n ** 16n],
  });
  const p2 = decodeRevert(undecodedByViem(above));
  check('PriceAboveMax is named off the Marketplace abi', p2.errorName === 'PriceAboveMax', p2.errorName ?? 'null');
  check('…and says nothing was sent', /nothing was sent/.test(p2.message), p2.message);
  check('…and does NOT accuse the seller of anything', !/seller/.test(p2.message), p2.message);
  check('…and the two do not share a sentence', r.message !== p2.message, p2.message);
  console.log(`       > ${p2.message}`);
}

/* ═══════════════════════════════════════════════════════════════════════
   LAYER 1 — never offer what cannot succeed
   ═══════════════════════════════════════════════════════════════════════ */

console.log('\nlayer 1 · matchmaking');

interface TestBull {
  id: number;
  owner: `0x${string}`;
  name: string;
  elo: number;
  wins: number;
  losses: number;
  ties: number;
  isDead: boolean;
}
const bull = (id: number, owner: string, elo = 1000): TestBull => ({
  id,
  owner: owner as `0x${string}`,
  name: `bull ${id}`,
  elo,
  wins: 0,
  losses: 0,
  ties: 0,
  isDead: false,
});

const ME = '0x1111111111111111111111111111111111111111';
const THEM = '0x2222222222222222222222222222222222222222';

const challenger = bull(1, ME);
// #16 is the real one: alive, unlisted, perfectly rated, and NOT in the pit
// because a marketplace takeover voided its entry.
const pool = [challenger, bull(16, THEM), bull(17, THEM), bull(18, THEM)];

{
  const ranked = rankOpponents({
    challenger,
    pool,
    myAddress: ME.toLowerCase(),
    allowSelfDuel: false,
    matchable: new Set([17, 18]),
  });
  check(
    'a bull that left the pit is never offered',
    !ranked.some((b) => b.id === 16),
    `got ${ranked.map((b) => b.id).join(',')}`,
  );
  check('…and the ones still in it are', ranked.length === 2, `got ${ranked.length}`);
}

{
  // A bull with an eject counting down is still `inYards` on chain, so an
  // already-signed loss lands — but no NEW fight may be matched against it.
  const ranked = rankOpponents({
    challenger,
    pool,
    myAddress: ME.toLowerCase(),
    allowSelfDuel: false,
    matchable: new Set([18]),
  });
  check(
    'a bull with a pending eject is not offered either',
    ranked.length === 1 && ranked[0]!.id === 18,
    `got ${ranked.map((b) => b.id).join(',')}`,
  );
}

{
  // ⚠ THE FAILURE MODE OF THE FIX. An unread membership set must NOT empty the
  // pool, or an rpc blip turns into "there is nobody left to fight".
  const ranked = rankOpponents({
    challenger,
    pool,
    myAddress: ME.toLowerCase(),
    allowSelfDuel: false,
    matchable: null,
  });
  check(
    'unknown membership does not empty the pool',
    ranked.length === 3,
    `got ${ranked.length}`,
  );
}

{
  const ranked = rankOpponents({
    challenger,
    pool: [challenger, bull(16, THEM)],
    myAddress: ME.toLowerCase(),
    allowSelfDuel: false,
    matchable: new Set<number>(),
  });
  check(
    'an empty pit offers nobody, rather than offering an unfightable bull',
    ranked.length === 0,
    `got ${ranked.length}`,
  );
}

/* ═══════════════════════════════════════════════════════════════════════ */

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures > 0) {
  console.error(`\n${failures} FAILED`);
  process.exit(1);
}
console.log('revert decoding and pit filtering verified.\n');
