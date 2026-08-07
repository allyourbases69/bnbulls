// verify-fight-pin.ts — regression guard for the pinned-fight state machine.
//
// THE BUG THIS PINS DOWN (2026-08-08): the receipt lands ~3s into a 4-6s
// animation, `onSettled()` marks the bull done, DuelPicker advances `currentId`
// to the next queued bull, the pair-change effect wipes the quote — and the
// arena, gated on the quote, unmounted MID-FIGHT with no victory card. Owner:
// "animation flashed up for about 3 seconds then just disappeared."
//
// The fix is a PIN: the fight snapshots itself at broadcast (`fight` state),
// the arena renders off `view` (pin outranks live quote), the pair-change
// effect leaves the pin alone, and dismissal clears EVERYTHING — quote
// included, or a failed fight's modal re-renders off the surviving quote and
// close/Escape become no-ops (the review's critical #1).
//
// ⚠ THIS IS A SOURCE-STRUCTURE CHECK, NOT A BEHAVIOUR TEST. There is no React
// test harness in this repo, so this guards the load-bearing SHAPE of
// FightAction.tsx: each check names the teardown it prevents. If you
// deliberately restructured the state machine, update these checks in the same
// commit and keep their intent — a fight on screen must never be unmountable
// by background state it did not cause.

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const file = resolve(here, '../src/components/duel/FightAction.tsx');
const src = readFileSync(file, 'utf8');

let failures = 0;
function check(name: string, ok: boolean, why: string) {
  if (ok) {
    console.log(`  ok   ${name}`);
  } else {
    failures += 1;
    console.error(`  FAIL ${name}\n       ${why}`);
  }
}

console.log('fight pin · the queue must not tear down a playing fight');

check(
  'the pin exists',
  /const \[fight, setFight\] = useState</.test(src),
  'no `fight` state — the arena has nothing to survive a queue advance on.',
);

check(
  'the fight is pinned at broadcast',
  /setFight\(\{ quote, txHash: hash \}\)/.test(src),
  'submit() no longer snapshots the fight when the tx broadcasts.',
);

// The pair-change effect (deps [myTokenId, oppTokenId, account]) wipes the
// live-quote state. It must not touch the pin — that wipe firing mid-fight IS
// the original bug.
// Anchor to the NEAREST useEffect before these deps — a lazy [\s\S]*? from the
// file's first useEffect would span the roll function's legitimate
// setFight(null) and fail on innocent code.
const pairEffect = src.match(
  /useEffect\(\(\) => \{(?:(?!useEffect)[\s\S])*?\}, \[myTokenId, oppTokenId, account\]\)/,
);
check(
  'the pair-change effect leaves the pin alone',
  pairEffect !== null && !/setFight\(/.test(pairEffect[0]),
  pairEffect === null
    ? 'could not find the pair-change effect keyed on [myTokenId, oppTokenId, account].'
    : 'the pair-change effect calls setFight — a queue advance mid-fight will unmount the arena again.',
);

check(
  'the arena renders off the pin, not the live quote',
  /view !== null && !hidden && \(/.test(src) && /const view = useMemo\(/.test(src),
  'the DuelAnimation mount is no longer gated on `view` — a cleared quote will take a playing fight down.',
);

// Dismissal must clear the QUOTE too. After a wallet-reject or revert the pair
// never advances, so the quote survives — and `view` falls back to it,
// re-rendering the modal the player just closed (review critical #1).
const dismiss = src.match(/const dismissFight = useCallback\(\(\) => \{[\s\S]*?\}, \[\]\)/);
check(
  'dismissal clears the quote as well as the pin',
  dismiss !== null && /setQuote\(null\)/.test(dismiss[0]) && /setFight\(null\)/.test(dismiss[0]),
  dismiss === null
    ? 'could not find dismissFight.'
    : 'dismissFight does not clear both fight and quote — a failed fight becomes an inescapable modal.',
);

check(
  'the receipt follows the pinned hash',
  /hash: activeHash \?\? undefined/.test(src) && /const activeHash = fight\?\.txHash \?\? txHash/.test(src),
  'the receipt hook no longer watches the pinned hash — a pair change mid-fight resets the verdict to "signing" under a live arena.',
);

// Mid-fight close must FOLD, not dismiss. `settled` is true ~3s in by design,
// so it must not count as "the outcome has been seen" (review high #3).
check(
  'closing mid-fight folds instead of dismissing',
  /watched \|\| reverted \|\| revert !== null/.test(src),
  'onClose treats `settled` as watched again — closing 3s in will throw the fight away mid-animation.',
);

if (failures > 0) {
  console.error(`\n${failures} pin check(s) failed. Read the header before "fixing" this file.`);
  process.exit(1);
}
console.log('\nall pin checks passed — a playing fight cannot be torn down by the queue.');
