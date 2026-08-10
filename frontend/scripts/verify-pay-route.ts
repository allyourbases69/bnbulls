// verify-pay-route.ts — the WBNB approve must be unreachable on the BNB leg.
//
// THE BUG THIS PINS DOWN (2026-08-10, live on mainnet): the fight gate rendered
// "approve wbnb to fight" for every player whose FIGHT BALANCE covered their
// side. `/api/run-duel` returns `nativeValue: 0n` in exactly that case (paying
// from credit is the point of the ledger), and the BNB leg's asset key is the
// WBNB address (that is how `fighterCost(WBNB)` prices a BNB fight) — so a test
// reading "no value + a token address ⇒ ERC-20 payment" turned the normal,
// well-configured player into a dead end on the main action of the game.
// Approving did nothing: `DuelNative._takeSide` returns out of the
// `asset == wbnb` branch before it ever constructs an `IERC20`.
//
// ⚠ THIS IS A BEHAVIOUR TEST, NOT A SOURCE-SHAPE CHECK. `needsErc20Approval` is
// a pure function precisely so this can walk the real decision table. If you
// change the payment routing, these rows must be updated deliberately — and the
// two rows marked THE BUG may never go back to `true`.

import { needsErc20Approval, NO_ASSET, type PaySide } from '../src/lib/duelPayRoute.ts';

const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';
const BNBULL = '0xA8D00F9b3ac9D1F7cd0065083fa3ca9221574444';

let failures = 0;
function check(name: string, ok: boolean, why: string) {
  if (ok) {
    console.log(`  ok   ${name}`);
  } else {
    failures += 1;
    console.error(`  FAIL ${name}\n       ${why}`);
  }
}

function side(p: Partial<PaySide>): PaySide {
  return {
    hasSide: true,
    nativeValue: 0n,
    asset: WBNB,
    isBnbLeg: true,
    nativeDuel: true,
    ...p,
  };
}

console.log('pay route · the retired wbnb approve must be unreachable on the bnb leg');

// ── THE BUG ────────────────────────────────────────────────────────────
check(
  'THE BUG · native duel, bnb leg, paid from the fight balance',
  needsErc20Approval(side({ nativeValue: 0n })) === false,
  'a topped-up player is being asked to approve wbnb. DuelNative never pulls ' +
    'it — this is the exact dead end the fix exists to remove.',
);

check(
  'THE BUG · native duel, bnb leg, value attached',
  needsErc20Approval(side({ nativeValue: 3328000000000000n })) === false,
  'value rides with the transaction; nothing to authorise.',
);

// ── the legacy contract must keep its real approve ─────────────────────
check(
  'legacy duel, bnb leg, no value · the wbnb allowance is REAL there',
  needsErc20Approval(side({ nativeDuel: false, nativeValue: 0n })) === true,
  'the pre-migration bnb leg genuinely settles out of a WBNB allowance when ' +
    'msg.value falls short. the fix must not become an unconditional exemption.',
);

check(
  'legacy duel, bnb leg, value attached',
  needsErc20Approval(side({ nativeDuel: false, nativeValue: 1n })) === false,
  'attached value covers the side on either contract.',
);

// ── the bnbull leg is untouched on BOTH contracts ──────────────────────
check(
  'native duel, bnbull leg · still needs an allowance',
  needsErc20Approval(side({ asset: BNBULL, isBnbLeg: false })) === true,
  '$BNBULL is a real ERC-20 and can only ever move by transferFrom. Breaking ' +
    'this would make the bnbull leg silently unpayable.',
);

check(
  'legacy duel, bnbull leg · still needs an allowance',
  needsErc20Approval(side({ asset: BNBULL, isBnbLeg: false, nativeDuel: false })) === true,
  'the bnbull leg was never wrapped and never changed.',
);

// ── degenerate inputs must not invent an approval ──────────────────────
check(
  'a side that stakes nothing',
  needsErc20Approval(side({ asset: NO_ASSET, isBnbLeg: false })) === false,
  'a zero asset stakes nothing, so there is nothing to authorise.',
);

check(
  'a quote naming a pair this screen is not showing',
  needsErc20Approval(side({ hasSide: false })) === false,
  'unknown must stay unknown — a standing fight can name a different pair, and ' +
    'guessing there once printed the opponent stake as the player own.',
);

// ── and the label can never say wbnb on a native bnb leg ───────────────
// `approveSymbol` is only ever read when `needsErc20` is true, so the two rows
// above are the whole proof. This asserts the coupling has not been broken by
// someone wiring the label to something else.
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(resolve(here, '../src/components/duel/FightAction.tsx'), 'utf8');

check(
  'the gate approve is still gated on needsErc20',
  /const needsGateApproval = needsErc20 && needsApproval;/.test(src),
  'the gate no longer reads `needsErc20`, so the rows above prove nothing ' +
    'about what the button renders.',
);

check(
  'the predicate is the shared one, not a re-inlined copy',
  /needsErc20Approval\(\{/.test(src) &&
    !/const needsErc20 =\s*mySide !== null && nativeValue === 0n/.test(src),
  'FightAction has gone back to computing this inline. That is exactly how the ' +
    'wbnb dead end was written the first time.',
);

if (failures > 0) {
  console.error(`\n${failures} check(s) failed.`);
  process.exit(1);
}
console.log('\nall pay-route checks passed — no wbnb approve can reach a bnb-leg player.');
