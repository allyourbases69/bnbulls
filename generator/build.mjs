// bnbulls — art build. writes the contact sheets and runs the border sweep.
//
// ⚠ THE TIER MAP COMES FROM THE CHAIN, VIA `chainBandMap()`.
// This build used to call `assignBands()`, a completely different shuffle to
// the one `Bulls._initializeRarity()` runs, so 377 of the 500 sprites rendered
// the wrong tier — permanently, because the art is deterministic from the
// token id and the chain data is immutable (`DECISIONS.md §27`). There is now
// ONE algorithm, ported from the contract and living in `bull.mjs`, and this
// file cross-checks it against the committed table before it writes a pixel.
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { encodePng, compose } from "./png.mjs";
import { chainBandMap, chainTiers, rollToken, renderTile, tokenGrid, assertBorderClear,
         assertCentred, assignNames, MASTER_SEED, SUPPLY, KING_ID, TILE_W, TILE_H,
         BANDS, BAND_COUNTS, SKINS, WEAPONS, ACC_POOLS, HORN_POOLS } from "./bull.mjs";

const bandMap = chainBandMap();

// ---- the committed table must agree, or nothing gets written.
// `deployments/rarity.json` is what `script/Names.s.sol:PrintNamesCommitment`
// proves against the real `Bulls` constructor and what the 501 names were
// dealt against. It is regenerable (`node scripts/gen-names.mjs`) and it is
// NOT trusted — it is compared. If it is missing we say so loudly rather than
// quietly rendering an unchecked table.
{
  // resolved off this file, not off cwd — the sheets are written next to it.
  const path = fileURLToPath(new URL("../deployments/rarity.json", import.meta.url));
  if (!existsSync(path)) {
    console.log(`/!\\ ${path} not found — cannot cross-check the tier map.`);
    console.log("    run: node scripts/gen-names.mjs");
    process.exitCode = 1;
  } else {
    const file = JSON.parse(readFileSync(path, "utf8"));
    if (String(file.masterSeed) !== String(MASTER_SEED)) {
      console.log(`/!\\ masterSeed mismatch: ${path} says ${file.masterSeed}, ` +
                  `bull.mjs says ${MASTER_SEED}. The art and the names would be ` +
                  "dealt off two different seeds.");
      process.exitCode = 1;
    }
    const derived = chainTiers();
    const wrong = [];
    for (let id = 1; id <= SUPPLY; id++) {
      if (derived[id - 1] !== file.tiers[id - 1]) wrong.push(id);
    }
    if (wrong.length) {
      console.log(`/!\\ ${wrong.length} tokens disagree with ${path} ` +
                  `(first: #${wrong[0]}). Do not ship this art.`);
      process.exitCode = 1;
    } else {
      console.log(`tier map: ${SUPPLY} tokens agree with ${path} (seed ${MASTER_SEED})`);
    }
  }
}

// ---- the sweep: every band x weapon x accessory-set x horn combination,
// checked twice.
//
//   assertBorderClear  a body pixel on the outermost ring cannot be outlined,
//                      so it renders with a raw edge. (`§6`.)
//   assertCentred      the bull is mirror-symmetric about CX, and CX is the
//                      frame's centre column. This is the owner's "they need
//                      to be CENTERED in the frame", made a build failure
//                      instead of something you notice on a card.
//
// ⚠ EXACTLY TWO ACCESSORIES ARE EXEMPT FROM THE CENTRING CHECK, and both are
// deliberately one-sided ART rather than a centring slip:
//
//   bandana  the knot tail hangs off one side. That is what a bandana is.
//   shades   each lens carries its glint one pixel in from its LEFT edge, so
//            the highlight reads as one light source crossing both lenses.
//            Mirroring it would put the glints nose-to-nose and kill the
//            lighting.
//
// Everything else on the head — horns, horn caps, crown, brow, eyes, muzzle,
// nostrils, tusks — must mirror to the pixel. That check is what caught the
// legendary coronet running CX-6..CX+5, half a pixel off its own axis.
const CENTRING_EXEMPT = ["bandana", "shades"];
{
  let checked = 0, centreChecked = 0;
  const failures = [], offCentre = [];
  const sweep = [];
  for (const band of BANDS) {
    for (const skin of SKINS[band]) {
      for (const weapon of WEAPONS) {
        for (const accessories of [[], ...ACC_POOLS[band]]) {
          for (const horn of HORN_POOLS[band]) {
            sweep.push({ band, skin, weapon, accessories, horn });
          }
        }
      }
    }
  }
  // the king is not a band x skin combination, so he would otherwise never be
  // swept — and he is the one bull with a hide, horns, crown and weapon nobody
  // else can roll.
  const kingNames = assignNames(bandMap);
  for (const { band, skin, weapon, accessories, horn } of sweep) {
    const t = rollToken(1, bandMap, { band, skin, weapon, accessories, horn });
    const g = tokenGrid(t);
    const err = assertBorderClear(g);
    checked++;
    if (err) failures.push(`${band}/${skin[0]}/${weapon}/[${accessories}] -> ${err}`);
    if (!accessories.some((a) => CENTRING_EXEMPT.includes(a))) {
      centreChecked++;
      const off = assertCentred(g);
      if (off) offCentre.push(`${band}/${skin[0]}/${weapon}/[${accessories}] -> ${off}`);
    }
  }
  {
    const k = rollToken(KING_ID, bandMap, { band: "legendary", names: kingNames });
    const g = tokenGrid(k);
    checked++; centreChecked++;
    const err = assertBorderClear(g);
    if (err) failures.push(`KING #${KING_ID} -> ${err}`);
    const off = assertCentred(g);
    if (off) offCentre.push(`KING #${KING_ID} -> ${off}`);
  }
  console.log(`border sweep:   ${checked} combinations checked, ${failures.length} failed`);
  for (const f of failures.slice(0, 10)) console.log("  " + f);
  console.log(`centring sweep: ${centreChecked} combinations checked, ${offCentre.length} failed ` +
              `(bull axis == frame centre column ${(TILE_W - 1) / 2} of ${TILE_W})`);
  for (const f of offCentre.slice(0, 10)) console.log("  " + f);
  if (failures.length || offCentre.length) process.exitCode = 1;
}

// sheet 1 — one hero per band, big scale, so shape reads clearly
const heroes = BANDS.map((band, i) =>
  rollToken(100 + i * 37, bandMap, {
    band, skin: SKINS[band][i % 6], weapon: WEAPONS[[2, 1, 8, 3, 0][i]],
    accessories: [["ringnose"], ["bandana"], ["shades"], ["shades", "ringnose"], ["crown"]][i],
  }));
const h = compose(heroes.map(renderTile), 5, TILE_W, TILE_H, 2);
writeFileSync("heroes.png", encodePng(h.px, h.w, h.h, 6));

// sheet 2 — a straight roll of 24 tokens, no overrides (what mint actually
// looks like: the chain's tiers, the chain's weapons)
const roll = [];
for (let id = 1; id <= 24; id++) roll.push(rollToken(id, bandMap));
const r = compose(roll.map(renderTile), 8, TILE_W, TILE_H, 2);
writeFileSync("roll.png", encodePng(r.px, r.w, r.h, 4));

// sheet 3 — every weapon on one band, to check the 12-slot catalog.
// weapon is overridden here on purpose: a real uncommon bull only ever carries
// cleaver or hornbow, and this sheet exists to inspect all twelve SHAPES.
const weps = WEAPONS.map((w, i) =>
  rollToken(200 + i, bandMap, { band: "uncommon", skin: SKINS.uncommon[0], weapon: w, accessories: [] }));
const wsheet = compose(weps.map(renderTile), 6, TILE_W, TILE_H, 2);
writeFileSync("weapons.png", encodePng(wsheet.px, wsheet.w, wsheet.h, 4));

// sheet 4 — the rarity ladder. four REAL rolled tokens per tier, taken straight
// off the chain's shuffle, one row per tier, common at the top. this is the
// sheet that answers "can you tell a legendary from an uncommon across a room".
{
  const perTier = 4;
  const rows = [];
  for (const tier of BANDS) {
    const picks = [];
    for (let id = 1; id <= SUPPLY && picks.length < perTier; id++) {
      if (bandMap[id] === tier) picks.push(rollToken(id, bandMap));
    }
    rows.push(picks);
  }
  const ladder = compose(rows.flat().map(renderTile), perTier, TILE_W, TILE_H, 2);
  writeFileSync("ladder.png", encodePng(ladder.px, ladder.w, ladder.h, 5));
  for (const [i, tier] of BANDS.entries()) {
    const ids = rows[i].map((t) => `#${t.id} ${t.weapon}`).join("  ");
    console.log(`  ${String(i + 1)}. ${tier.padEnd(10)} n=${String(BAND_COUNTS[tier]).padStart(3)}  ${ids}`);
  }
}

console.log("wrote heroes.png roll.png weapons.png ladder.png");
