// Verifies the TypeScript art engine port (`src/lib/art/bull.ts`) renders
// byte-identically to the node build (`generator/bull.mjs`) — the whole
// contract of the port per DECISIONS.md §6 and the frontend package brief.
//
// Run with: `npm run verify:art` (from frontend/), or `node
// scripts/verify-art-port.ts` directly. Requires Node 22.7+ for native
// TypeScript execution (no build step, no ts-node/tsx dependency).
//
// Checks, in order: the rng primitives, the CHAIN's rarity shuffle and weapon
// draw (`chainBandMap` / `chainWeaponId` — the ported ones; `assignBands()` is
// deleted, see DECISIONS.md §27), the name dealer, then for every one of the
// 500 tokens plus the king #501 override path: the rolled token object, the
// char grid, the derived palette, and finally the rendered RGBA pixel buffer —
// byte for byte.
//
// This proves the two engines are the same engine. Whether that engine agrees
// with the CONTRACT is `verify:rarity`'s job — run both.

import * as js from '../../generator/bull.mjs';
import * as ts from '../src/lib/art/bull.ts';

let failures = 0;

function check(label: string, cond: boolean): void {
  if (!cond) {
    failures++;
    console.error(`FAIL: ${label}`);
  }
}

function deepEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function buffersEqual(a: Uint8ClampedArray, b: Uint8ClampedArray): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// ---- constants ----
check('MASTER_SEED', js.MASTER_SEED === ts.MASTER_SEED);
check('SUPPLY', js.SUPPLY === ts.SUPPLY);
check('KING_ID', js.KING_ID === ts.KING_ID);
check('KING_NAME', js.KING_NAME === ts.KING_NAME);
check(
  'canvas dims',
  js.W === ts.W && js.H === ts.H && js.TILE_W === ts.TILE_W &&
    js.TILE_H === ts.TILE_H && js.MARGIN === ts.MARGIN,
);

// ---- rng streams ----
for (const seed of [0, 1, 12345, 0x0b17b011, 4294967295]) {
  const a = js.lcg(seed);
  const b = ts.lcg(seed);
  for (let i = 0; i < 20; i++) check(`lcg(${seed})[${i}]`, a() === b());
}
for (let id = 1; id <= 505; id++) check(`tokenSeed(${id})`, js.tokenSeed(id) === ts.tokenSeed(id));

// ---- the chain's rarity shuffle + weapon draw ----
const bandMapJS = js.chainBandMap();
const bandMapTS = ts.chainBandMap();
check('chainBandMap()', deepEqual(bandMapJS, bandMapTS));
check('chainTiers()', deepEqual(js.chainTiers(), ts.chainTiers()));
for (let id = 1; id <= js.SUPPLY; id++) {
  const tier = js.BANDS.indexOf(bandMapJS[id]);
  check(`chainWeaponId(${id})`, js.chainWeaponId(id, tier) === ts.chainWeaponId(id, tier));
}

// ---- name dealer ----
const namesJS = js.assignNames(bandMapJS);
const namesTS = ts.assignNames(bandMapTS);
check('assignNames()', deepEqual(namesJS, namesTS));
check('501 unique names (js)', new Set(Object.values(namesJS)).size === 501);
check('501 unique names (ts)', new Set(Object.values(namesTS)).size === 501);

// ---- every token 1..500: roll, grid, palette, rendered pixels ----
for (let id = 1; id <= js.SUPPLY; id++) {
  const tJS = js.rollToken(id, bandMapJS, { names: namesJS });
  const tTS = ts.rollToken(id, bandMapTS, { names: namesTS });
  check(`token#${id} roll`, deepEqual(tJS, tTS));

  const gJS = js.tokenGrid(tJS);
  const gTS = ts.tokenGrid(tTS);
  check(`token#${id} grid`, deepEqual(gJS, gTS));

  const pJS = js.derivePalette(tJS);
  const pTS = ts.derivePalette(tTS);
  check(`token#${id} palette`, deepEqual(pJS, pTS));

  const rJS = js.renderTile(tJS);
  const rTS = ts.renderTile(tTS);
  check(`token#${id} pixels`, buffersEqual(rJS, rTS));
}

// ---- king #501: no bandMap entry, so the app always overrides band —
// verify that override path matches too, since /bull/[id] uses it. ----
{
  const overrideJS = { band: 'legendary', names: namesJS };
  const overrideTS = { band: 'legendary' as const, names: namesTS };
  const tJS = js.rollToken(js.KING_ID, bandMapJS, overrideJS);
  const tTS = ts.rollToken(ts.KING_ID, bandMapTS, overrideTS);
  check('king roll', deepEqual(tJS, tTS));
  check('king name is Lord Wagyu (js)', tJS.name === js.KING_NAME);
  check('king name is Lord Wagyu (ts)', tTS.name === ts.KING_NAME);
  const rJS = js.renderTile(tJS);
  const rTS = ts.renderTile(tTS);
  check('king pixels', buffersEqual(rJS, rTS));
}

if (failures === 0) {
  console.log(`OK — ${js.SUPPLY} tokens + king #501 override, byte-identical to generator/bull.mjs.`);
} else {
  console.error(`${failures} mismatch(es) between the TS port and generator/bull.mjs.`);
}
process.exit(failures === 0 ? 0 : 1);
