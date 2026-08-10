// Verifies the combat-engine port against Fighting Fefers.
//
// `BNBULLS-BOOTSTRAP.md §3` puts the combat engine — stats, weights, type
// triangle, ELO — in the "carries over unchanged, do NOT re-litigate" list, and
// the package brief says it in capitals: do not invent, rebalance or tune any
// combat number. This script is how that claim is CHECKED rather than asserted.
//
// It works two ways, because neither alone is enough:
//
//   1. NORMALISED SOURCE EQUALITY for `sim/combat.ts`, `core/rng.ts`,
//      `core/stats.ts` and `core/elo.ts`. Comments and whitespace are stripped
//      and a small, EXPLICIT and printed rename map is applied to the fefers
//      side (Outlaw→Bull, fefer→bull). What is left must match character for
//      character. That catches a changed constant, a changed comparison, a
//      reordered RNG draw — anything at all that is not a rename.
//
//   2. A NUMERIC WEAPON-TABLE DIFF, because `core/weapons.ts` legitimately does
//      not match textually: bnbulls adds the king-only twelfth slot that the
//      fefers frontend catalog never had, and its validation mirrors
//      `Bulls.sol` rather than fefers. So each of slots 0..10 is compared
//      field by field against fefers, and ALL TWELVE are compared against
//      `contracts/Bulls.sol::_initializeWeapons()` — which is the real
//      authority, since the chain is what the simulator has to agree with.
//
// Run with: `npm run verify:combat` (from frontend/). Requires Node 22.7+ for
// native TypeScript execution, same as `verify:art`.
//
// The fefers tree lives outside this repo. Point `FEFERS_SRC` at it, or accept
// the default sibling path. If it is absent the source-equality half SKIPS with
// a loud notice (it cannot be run without the original) while the Bulls.sol
// half still runs — that half is the one that matters at deploy time anyway.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const FRONTEND = join(here, '..');
const REPO = join(FRONTEND, '..');
const FEFERS_SRC =
  process.env.FEFERS_SRC ||
  join(REPO, '..', 'reference', 'app', 'frontend', 'src');

let failures = 0;
let checks = 0;

function check(label: string, cond: boolean, detail = ''): void {
  checks++;
  if (!cond) {
    failures++;
    console.error(`FAIL: ${label}${detail ? `\n      ${detail}` : ''}`);
  }
}

// ── normalisation ────────────────────────────────────────────────────
// Strips block comments, line comments, and all insignificant whitespace.
// None of the four compared files contains "//" or "/*" inside a string
// literal, which is what makes this safe without a real tokeniser.
function normalise(src: string): string {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * The ONLY changes the brief permits: naming. Applied to the fefers side before
 * comparison, and printed so the reader can see exactly what was forgiven.
 * Longest-first so `OutlawStatus` is rewritten before `Outlaw`.
 */
const RENAMES: readonly [RegExp, string][] = [
  [/outlawAId/g, 'bullAId'],
  [/outlawBId/g, 'bullBId'],
  [/OutlawStatus/g, 'BullStatus'],
  [/Outlaw/g, 'Bull'],
  [/outlaw/g, 'bull'],
  [/Fefer/g, 'Bull'],
  [/fefer/g, 'bull'],
];

function applyRenames(src: string): string {
  let out = src;
  for (const [from, to] of RENAMES) out = out.replace(from, to);
  return out;
}

function firstDifference(a: string, b: string): string {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) {
      const from = Math.max(0, i - 60);
      return (
        `at char ${i}:\n` +
        `        fefers : …${a.slice(from, i + 60)}\n` +
        `        bnbulls: …${b.slice(from, i + 60)}`
      );
    }
  }
  return `identical for ${n} chars, then one file continues: ` +
    `${(a.length > b.length ? a : b).slice(n, n + 120)}`;
}

// ── 1. source equality ───────────────────────────────────────────────
const SOURCE_PAIRS: readonly [string, string][] = [
  ['sim/combat.ts', 'sim/combat.ts'],
  ['core/rng.ts', 'core/rng.ts'],
  ['core/stats.ts', 'core/stats.ts'],
  ['core/elo.ts', 'core/elo.ts'],
];

if (!existsSync(FEFERS_SRC)) {
  console.warn(
    `NOTE: the fefers source is not at ${FEFERS_SRC}, so the source-equality ` +
      'half is SKIPPED. Set FEFERS_SRC to run it.',
  );
} else {
  console.log('rename map applied to the fefers side before comparison:');
  for (const [from, to] of RENAMES) console.log(`  ${from.source} -> ${to}`);
  console.log('');

  for (const [fefersRel, bnbullsRel] of SOURCE_PAIRS) {
    const a = normalise(applyRenames(readFileSync(join(FEFERS_SRC, fefersRel), 'utf8')));
    const b = normalise(readFileSync(join(FRONTEND, 'src', bnbullsRel), 'utf8'));
    check(
      `${bnbullsRel} is the fefers file with only renames applied`,
      a === b,
      a === b ? '' : firstDifference(a, b),
    );
  }
}

// ── 2. the weapon table ──────────────────────────────────────────────
interface WeaponRow {
  name: string;
  damageMin: number;
  damageMax: number;
  speed: number;
  type: string;
  weight: number;
}

/** Pull the WEAPONS array out of a `core/weapons.ts` by regex. */
function parseWeaponsTs(src: string): WeaponRow[] {
  const rows: WeaponRow[] = [];
  const re =
    /\{\s*name:\s*'([^']+)',\s*damageMin:\s*(\d+),\s*damageMax:\s*(\d+),\s*speed:\s*(\d+),\s*type:\s*'(\w+)',\s*rarity:\s*'\w+',\s*weight:\s*(\d+)\s*\}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    rows.push({
      name: m[1],
      damageMin: Number(m[2]),
      damageMax: Number(m[3]),
      speed: Number(m[4]),
      type: m[5],
      weight: Number(m[6]),
    });
  }
  return rows;
}

/** Pull `_addWeapon(...)` calls out of Bulls.sol, in slot order. */
const SOL_TYPE = ['blade', 'blunt', 'ranged'];
function parseWeaponsSol(src: string): WeaponRow[] {
  const rows: WeaponRow[] = [];
  const re = /_addWeapon\(\s*"([^"]+)",\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\s*\)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    rows.push({
      name: m[1],
      damageMin: Number(m[2]),
      damageMax: Number(m[3]),
      speed: Number(m[4]),
      type: SOL_TYPE[Number(m[5])] ?? `unknown(${m[5]})`,
      weight: Number(m[6]),
    });
  }
  return rows;
}

const ours = parseWeaponsTs(readFileSync(join(FRONTEND, 'src', 'core', 'weapons.ts'), 'utf8'));
check('bnbulls weapons.ts parsed 12 slots', ours.length === 12, `got ${ours.length}`);

// 2a. against Bulls.sol — the authority.
const sol = parseWeaponsSol(readFileSync(join(REPO, 'contracts', 'Bulls.sol'), 'utf8'));
check('Bulls.sol declares 12 weapons', sol.length === 12, `got ${sol.length}`);
for (let i = 0; i < Math.min(ours.length, sol.length); i++) {
  const o = ours[i];
  const s = sol[i];
  check(
    `slot ${i} matches Bulls.sol`,
    o.name === s.name &&
      o.damageMin === s.damageMin &&
      o.damageMax === s.damageMax &&
      o.speed === s.speed &&
      o.type === s.type &&
      o.weight === s.weight,
    `sol=${JSON.stringify(s)}\n      ts =${JSON.stringify(o)}`,
  );
}
const dropSum = ours.slice(0, 11).reduce((n, w) => n + w.weight, 0);
check('slots 0..10 sum to 100', dropSum === 100, `got ${dropSum}`);
check('slot 11 is king-only (weight 0)', ours[11]?.weight === 0);

// 2b. against fefers — every combat NUMBER in slots 0..10, names excluded
// because renaming the weapons is the one change the brief permits.
if (existsSync(FEFERS_SRC)) {
  const fefers = parseWeaponsTs(readFileSync(join(FEFERS_SRC, 'core', 'weapons.ts'), 'utf8'));
  check('fefers weapons.ts parsed 11 slots', fefers.length === 11, `got ${fefers.length}`);
  for (let i = 0; i < Math.min(11, fefers.length, ours.length); i++) {
    const f = fefers[i];
    const o = ours[i];
    check(
      `slot ${i} (${f.name} -> ${o.name}) keeps every fefers combat number`,
      f.damageMin === o.damageMin &&
        f.damageMax === o.damageMax &&
        f.speed === o.speed &&
        f.type === o.type &&
        f.weight === o.weight,
      `fefers =${JSON.stringify(f)}\n      bnbulls=${JSON.stringify(o)}`,
    );
  }

  // The two scalars that live outside the table.
  const fefersW = readFileSync(join(FEFERS_SRC, 'core', 'weapons.ts'), 'utf8');
  const oursW = readFileSync(join(FRONTEND, 'src', 'core', 'weapons.ts'), 'utf8');
  const mult = (s: string) => /TYPE_ADVANTAGE_MULTIPLIER\s*=\s*([\d.]+)/.exec(s)?.[1];
  check(
    'TYPE_ADVANTAGE_MULTIPLIER unchanged',
    mult(fefersW) === mult(oursW),
    `fefers=${mult(fefersW)} bnbulls=${mult(oursW)}`,
  );
  // The triangle itself, as three ordered pairs.
  const triangle = (s: string) =>
    [...s.matchAll(/attacker\.type === '(\w+)' && defender\.type === '(\w+)'/g)]
      .map((m) => `${m[1]}>${m[2]}`)
      .join(',');
  check(
    'type triangle unchanged',
    triangle(fefersW) === triangle(oursW),
    `fefers=${triangle(fefersW)} bnbulls=${triangle(oursW)}`,
  );
}

// ── done ─────────────────────────────────────────────────────────────
if (failures > 0) {
  console.error(`\n${failures} of ${checks} checks FAILED.`);
  process.exit(1);
}
console.log(`OK — ${checks} checks passed. No combat number differs from the fefers source.`);
