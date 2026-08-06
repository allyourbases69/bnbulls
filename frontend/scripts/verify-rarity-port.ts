// verify:rarity — the gate that makes "the art and the chain disagree about
// which bull is which" impossible to reintroduce.
//
// Run with: `npm run verify:rarity` (from frontend/), or
// `node scripts/verify-rarity-port.ts` directly. Requires Node 22.7+ for
// native TypeScript execution. Exits non-zero on any mismatch.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT WENT WRONG, SO THE NEXT PERSON KNOWS WHAT THIS IS GUARDING
// ─────────────────────────────────────────────────────────────────────────────
// `Bulls.sol` fixes each token's rarity tier in its constructor and its weapon
// at mint. Both are immutable. The art is deterministic from the token id. So
// if the generator and the chain disagree, a bull the contract calls legendary
// renders a farmhand's sprite FOREVER, nobody notices until after mint, and
// nothing can be done. On the seed that was about to ship:
//
//     377 of 500 tokens had the wrong TIER   (only 3 of 30 legendaries agreed)
//     450 of 500 had the wrong WEAPON        (362 not even in their tier slice)
//
// `DECISIONS.md §27`. The chain is the source of truth; the generator was made
// to agree with it.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE CHAIN OF CUSTODY THIS SCRIPT ENFORCES
// ─────────────────────────────────────────────────────────────────────────────
//   contract  ─┬─ `initialRarityHash`  ─┐
//              └─ weapon table          ├─ PINNED below, produced by two
//                 `namesCommitment`     │  Foundry scripts run against a REAL
//                                       ┘  `Bulls` (see REPIN, bottom of file)
//   generator ─── chainTiers() / chainWeaponId() / assignNames()
//                                       └─ hashed here and compared to the pins
//   committed ─── deployments/rarity.json + names.json
//                                       └─ compared token by token
//   the site  ─── collection.getBull(id) — the exact call the pages make
//                                       └─ compared token by token
//
// The pins are what stop this being circular. Change the master seed or either
// algorithm and the hashes stop matching, and the only way to get new pins is
// to run the contract again — which forces the comparison to actually happen
// instead of being quietly skipped.

import { keccak256, toHex, encodeAbiParameters } from 'viem';
import { readFileSync } from 'node:fs';
import { registerHooks } from 'node:module';
import * as js from '../../generator/bull.mjs';
import * as ts from '../src/lib/art/bull.ts';

// `src/` imports are extensionless (`./bull`), which Next's bundler resolves
// and node's ESM loader does not. Rather than reimplement `getBull()` here —
// the whole point is to check the function the PAGES call, not a copy of it —
// teach the loader the bundler's rule for this one process.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('.') && !/\.[a-z]+$/i.test(specifier)) {
      return nextResolve(`${specifier}.ts`, context);
    }
    return nextResolve(specifier, context);
  },
});
const { getBull } = await import('../src/lib/art/collection.ts');

// ─── The pins. Regenerate with the two commands at the bottom of this file. ──
const PINNED = {
  masterSeed: 186101777n,
  // keccak256 of the 500 tier bytes, straight off `Bulls.initialRarityHash()`
  initialRarityHash: '0x1f0d3bdf707e3be5ce0640a3db1daf21e9f53fd881d47732807ddba152ef0a8d',
  // keccak256 of the 500 `getBull(id).weaponId` bytes, observed from real mints
  weaponTableHash: '0xf6ff910919fb981d972e19ff669d49a1c54c448b6062a4a0bd001bb2528aec12',
  // keccak256(abi.encode(string[] of 501)), the value the Bulls ctor is given
  namesCommitment: '0xa99972bc79e690d4640f4ce2a42ded9bb7809fe46a5aadb2f7c58fa73c5a795d',
} as const;

let failures = 0;
let checks = 0;

function check(label: string, cond: boolean, detail = ''): void {
  checks++;
  if (!cond) {
    failures++;
    console.error(`FAIL: ${label}${detail ? ` — ${detail}` : ''}`);
  }
}

function read(name: string): Record<string, unknown> {
  const url = new URL(`../../deployments/${name}`, import.meta.url);
  return JSON.parse(readFileSync(url, 'utf8'));
}

const rarityJson = read('rarity.json') as unknown as {
  masterSeed: string;
  tiers: number[];
  tierNames: string[];
};
const namesJson = read('names.json') as unknown as { masterSeed: string; names: string[] };

// ─── 1. one seed, everywhere ────────────────────────────────────────────────
// If these ever diverge the art, the names and the deployment are three
// different collections wearing the same numbers.
check('rarity.json masterSeed == generator MASTER_SEED',
  BigInt(rarityJson.masterSeed) === BigInt(js.MASTER_SEED),
  `${rarityJson.masterSeed} vs ${js.MASTER_SEED}`);
check('names.json masterSeed == generator MASTER_SEED',
  BigInt(namesJson.masterSeed) === BigInt(js.MASTER_SEED),
  `${namesJson.masterSeed} vs ${js.MASTER_SEED}`);
check('generator MASTER_SEED == the pinned seed',
  BigInt(js.MASTER_SEED) === PINNED.masterSeed,
  `${js.MASTER_SEED} vs ${PINNED.masterSeed} — re-run the probe if this was intended`);
check('TS port MASTER_SEED == JS', js.MASTER_SEED === ts.MASTER_SEED);

// ─── 2. the rng port itself ─────────────────────────────────────────────────
// Cheap, and it localises a break: if these fail the Xorshift port is wrong and
// every table below is meaningless.
for (const seed of [0n, 1n, 0x0b17b011n, (1n << 64n) - 1n, PINNED.masterSeed]) {
  const a = js.xorshiftCreate(seed);
  const b = ts.xorshiftCreate(seed);
  check(`xorshiftCreate(${seed}) parity`, a.s0 === b.s0 && a.s1 === b.s1);
  for (let i = 0; i < 16; i++) {
    check(`xorshiftNext(${seed})[${i}] parity`, js.xorshiftNext(a) === ts.xorshiftNext(b));
  }
}

// ─── 3. the rarity table ────────────────────────────────────────────────────
const tiersJS = js.chainTiers();
const tiersTS = ts.chainTiers();

check('chainTiers() length', tiersJS.length === js.SUPPLY, `${tiersJS.length}`);
check('chainTiers() TS port == JS', JSON.stringify(tiersJS) === JSON.stringify(tiersTS));

// against the committed map, token by token
{
  const wrong: number[] = [];
  for (let id = 1; id <= js.SUPPLY; id++) {
    if (tiersJS[id - 1] !== rarityJson.tiers[id - 1]) wrong.push(id);
  }
  check('every token matches deployments/rarity.json', wrong.length === 0,
    wrong.length ? `${wrong.length} tokens differ, first #${wrong[0]}` : '');
}

// against the contract, via the hash it publishes
{
  const bytes = Uint8Array.from(tiersJS);
  check('keccak256(tiers) == Bulls.initialRarityHash (pinned)',
    keccak256(toHex(bytes)) === PINNED.initialRarityHash,
    keccak256(toHex(bytes)));
}

// the distribution must still be the DECISIONS.md §7 ladder
{
  const counts = [0, 0, 0, 0, 0];
  for (const t of tiersJS) counts[t]++;
  js.BANDS.forEach((band: string, i: number) => {
    check(`tier count ${band}`, counts[i] === js.BAND_COUNTS[band],
      `${counts[i]} vs ${js.BAND_COUNTS[band]}`);
  });
}

// ─── 4. what the SITE actually renders ──────────────────────────────────────
// Not the engine in isolation — `getBull()` is the function every page calls.
{
  const bandMap = ts.chainBandMap();
  const wrongBand: number[] = [];
  const wrongMapBand: number[] = [];
  const wrongWeapon: number[] = [];
  const wrongWeaponPort: number[] = [];
  const outOfSlice: number[] = [];
  const weaponIds = new Uint8Array(js.SUPPLY);

  for (let id = 1; id <= js.SUPPLY; id++) {
    const tier = rarityJson.tiers[id - 1];
    const token = getBull(id);

    if (token.band !== js.BANDS[tier]) wrongBand.push(id);

    // the chain's own draw, re-derived: `Bulls._rollWeaponInTier()`
    const expectedId = js.chainWeaponId(id, tier);
    weaponIds[id - 1] = expectedId;
    if (token.weapon !== js.WEAPONS[expectedId]) wrongWeapon.push(id);

    // and the invariant behind it: a bull can only carry a weapon from its own
    // tier's slice. this is the check the old global weighted draw failed.
    const [start, count] = js.TIER_WEAPON_SLICE[tier];
    const idx = js.WEAPONS.indexOf(token.weapon);
    if (idx < start || idx >= start + count) outOfSlice.push(id);

    // TS/JS parity on the weapon derivation itself
    if (ts.chainWeaponId(id, tier) !== expectedId) wrongWeaponPort.push(id);

    // the band map the engine hands out must agree with the same table
    if (bandMap[id] !== js.BANDS[tier]) wrongMapBand.push(id);
  }

  check('getBull(id).band == the chain tier, for all 500', wrongBand.length === 0,
    wrongBand.length ? `${wrongBand.length} wrong, first #${wrongBand[0]}` : '');
  check('chainBandMap() == the chain tier, for all 500', wrongMapBand.length === 0,
    wrongMapBand.length ? `${wrongMapBand.length} wrong, first #${wrongMapBand[0]}` : '');
  check('getBull(id).weapon == the chain weapon, for all 500', wrongWeapon.length === 0,
    wrongWeapon.length ? `${wrongWeapon.length} wrong, first #${wrongWeapon[0]}` : '');
  check('chainWeaponId() TS port == JS, for all 500', wrongWeaponPort.length === 0,
    wrongWeaponPort.length ? `${wrongWeaponPort.length} wrong, first #${wrongWeaponPort[0]}` : '');
  check('every weapon is inside its tier slice', outOfSlice.length === 0,
    outOfSlice.length ? `${outOfSlice.length} out of slice, first #${outOfSlice[0]}` : '');
  check('keccak256(weaponIds) == the contract weapon table (pinned)',
    keccak256(toHex(weaponIds)) === PINNED.weaponTableHash,
    keccak256(toHex(weaponIds)));
}

// ─── 4b. the weapon CATALOG, read straight out of Bulls.sol ─────────────────
// The pins above would catch a reordering, but only via a hash — which tells
// you "something moved" and not what. This reads `_initializeWeapons()` and
// compares slot for slot, because the generator's weapon list HAS been out of
// order against the contract before, and that is the sort of thing you want
// named in the failure message.
{
  const src = readFileSync(new URL('../../contracts/Bulls.sol', import.meta.url), 'utf8');
  const rows = [...src.matchAll(/_addWeapon\(\s*"([^"]+)"\s*,\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*(\d+)\s*\)/g)];
  check('found 12 _addWeapon() rows in Bulls.sol', rows.length === 12, `${rows.length}`);

  rows.forEach((row, i) => {
    // Slot 11 is the king's gilded version of a normal weapon — the same
    // relationship the fefers Golden Warbow had to the Warbow. It is the ONE
    // slot whose Solidity name and engine key differ by more than case:
    //
    //   Bulls.sol   "Gilded Pike"   the display name a holder and a
    //                               marketplace see
    //   WEAPONS[11] "kingpike"      the SPRITE key, which must not collide
    //                               with slot 10's "pike" — the king does not
    //                               carry a recoloured commoner's weapon, he
    //                               has his own shape
    //
    // ⚠ The rule is still DERIVED both ways, so a rename on either side still
    // fails here. It was `strip "gilded "` alone, which only worked while slot
    // 11's base weapon had no counterpart of its own ("Gilded Prod" -> "prod",
    // and nothing else was called "prod"). Do not weaken this to a hard-coded
    // pair; the whole point of §27 is that the two sides are compared.
    const base = row[1].toLowerCase().replace(/^gilded /, '');
    const expected = i === 11 ? `king${base}` : base;
    check(`weapon slot ${i} name`, expected === js.WEAPONS[i],
      `Bulls.sol "${row[1]}" vs WEAPONS[${i}] "${js.WEAPONS[i]}"`);
    check(`weapon slot ${i} weight`, Number(row[2]) === js.WEAPON_WEIGHT[i],
      `Bulls.sol ${row[2]} vs WEAPON_WEIGHT[${i}] ${js.WEAPON_WEIGHT[i]}`);
  });

  // slots 0..10 must sum to 100 — the contract reverts in its constructor
  // otherwise (`WeightsMustSumTo100`), so a generator that disagrees is
  // describing a contract that cannot deploy.
  const normalTotal = js.WEAPON_WEIGHT.slice(0, 11).reduce((a: number, b: number) => a + b, 0);
  check('weapon weights 0..10 sum to 100', normalTotal === 100, `${normalTotal}`);

  // and the slices must tile the catalog exactly: no gap, no overlap, all 12.
  const covered = new Set<number>();
  for (const [start, count] of js.TIER_WEAPON_SLICE) {
    for (let i = start; i < start + count; i++) covered.add(i);
  }
  check('the tier slices tile all 12 catalog slots exactly',
    covered.size === 12 && js.WEAPONS.every((_: string, i: number) => covered.has(i)),
    `${covered.size} covered`);
}

// ─── 5. the king #501 ───────────────────────────────────────────────────────
// `mintKing()` sets weaponId 11 directly and `rarityOf(501)` is tier 5, so the
// king is the one token whose weapon is not rolled at all.
{
  const king = getBull(js.KING_ID);
  check('king #501 name', king.name === js.KING_NAME, king.name);
  check('king #501 carries the king-only weapon', king.weapon === js.KING_WEAPON, king.weapon);
  check('KING_WEAPON is catalog slot 11', js.WEAPONS.indexOf(js.KING_WEAPON) === 11);
  check('tier 5 slice is exactly slot 11',
    JSON.stringify(js.TIER_WEAPON_SLICE[5]) === JSON.stringify([11, 1]));
  check('no bull 1..500 can be handed slot 11', js.WEAPON_WEIGHT[11] === 0);
}

// ─── 6. the names, which are DEALT AGAINST THE TIER (DECISIONS.md §9) ───────
// The peerage rank in a name IS the rarity ladder, so a name dealt against the
// wrong tier is the same permanent bug wearing a different hat.
{
  const dealt = js.assignNames(js.chainBandMap());
  const dealtTS = ts.assignNames(ts.chainBandMap());
  const ordered: string[] = [];
  for (let id = 1; id <= js.SUPPLY; id++) ordered.push(dealt[id]);
  ordered.push(dealt[js.KING_ID]);

  check('assignNames() TS port == JS', JSON.stringify(dealt) === JSON.stringify(dealtTS));
  check('501 names dealt', ordered.length === 501, `${ordered.length}`);
  check('501 unique', new Set(ordered).size === 501, `${new Set(ordered).size}`);

  const wrongName: number[] = [];
  for (let i = 0; i < 501; i++) if (ordered[i] !== namesJson.names[i]) wrongName.push(i + 1);
  check('every name matches deployments/names.json', wrongName.length === 0,
    wrongName.length ? `${wrongName.length} differ, first #${wrongName[0]}` : '');

  // `BnbullsConfig.namesCommitment` is `keccak256(abi.encode(string[] memory))`
  // — a DYNAMIC array, so the encoding carries an offset and a length prefix.
  // `string[501]` hashes to something different and would silently "prove" the
  // wrong table.
  const encoded = encodeAbiParameters([{ type: 'string[]' }], [ordered]);
  check('keccak256(abi.encode(names)) == Bulls.namesCommitment (pinned)',
    keccak256(encoded) === PINNED.namesCommitment, keccak256(encoded));

  // the human-legible half of §9: you must be able to read the tier off the
  // name. a commoner is never "His Grace"; a duke is never "Sid Calverley".
  const RANK: Record<string, RegExp> = {
    common: /^(Old )?[A-Z][a-z]+ [A-Z][a-z]+$/,
    uncommon: /^(Sir|Master) /,
    rare: /^(Lord|Baron) /,
    epic: /^(The Earl of|Viscount) /,
    legendary: /^(His Grace the Duke of|The Marquess of)|Champion [IVX]+$/,
  };
  const wrongRank: number[] = [];
  for (let id = 1; id <= js.SUPPLY; id++) {
    const band = js.BANDS[rarityJson.tiers[id - 1]];
    if (!RANK[band].test(dealt[id])) wrongRank.push(id);
  }
  check("every name's peerage rank matches its tier", wrongRank.length === 0,
    wrongRank.length
      ? `${wrongRank.length} wrong, first #${wrongRank[0]} "${dealt[wrongRank[0]]}" ` +
        `is ${js.BANDS[rarityJson.tiers[wrongRank[0] - 1]]}`
      : '');
}

// ─── 7. the deleted functions must stay deleted ─────────────────────────────
// `assignBands()` and `pickWeighted()` were the two wrong answers. A named
// import of a missing export already fails at link time, but re-exporting them
// under the old names would slip past that — so say it out loud here too.
check('assignBands() is gone from generator/bull.mjs',
  (js as Record<string, unknown>).assignBands === undefined);
check('assignBands() is gone from src/lib/art/bull.ts',
  (ts as Record<string, unknown>).assignBands === undefined);

// ─── Report ─────────────────────────────────────────────────────────────────
if (failures === 0) {
  console.log(
    `OK — ${checks} checks. 500 tokens + the king #501: tier, weapon and name all ` +
    `agree with the chain (seed ${js.MASTER_SEED}).`,
  );
  console.log(`  initialRarityHash ${PINNED.initialRarityHash}`);
  console.log(`  weaponTableHash   ${PINNED.weaponTableHash}`);
  console.log(`  namesCommitment   ${PINNED.namesCommitment}`);
} else {
  console.error('');
  console.error(`${failures} of ${checks} checks FAILED.`);
  console.error('The art and the chain disagree about which bull is which. This is');
  console.error('permanent and unrecoverable after mint — do not deploy, do not ship');
  console.error('the sprites. See DECISIONS.md §27.');
}

// ─── REPIN ──────────────────────────────────────────────────────────────────
// If the master seed changes, all three pins change. Get the new ones from a
// real `Bulls`, never by copying whatever this script computed:
//
//   node scripts/gen-names.mjs                    # (from the repo root)
//   forge script script/Names.s.sol:PrintNamesCommitment
//       -> namesCommitment, initialRarityHash
//   FOUNDRY_SCRIPT=generator/probe forge script \
//       generator/probe/ChainTableProbe.s.sol:ChainTableProbe
//       -> initialRarityHash, weaponTableHash
//   node generator/build.mjs                      # re-render the sheets
//
process.exit(failures === 0 ? 0 : 1);
