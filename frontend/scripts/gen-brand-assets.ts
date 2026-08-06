// Generates every Lord Wagyu brand asset from the LIVE ART ENGINE.
//
// `DECISIONS.md §34`: the king (#501) is the face of the project. He is the
// landing hero, the browser tab icon, the app icon, and the picture that shows
// up when somebody drops a link in telegram or on X.
//
// ⚠ RENDERED, NEVER DRAWN. `VOICE-AND-BRAND.md §5` is a governing rule: no AI
// hero art, no stock art, no hand-redrawn mascot. Every pixel below comes out
// of `src/lib/art/bull.ts`, the same module the site, the mint and the cards
// call, so the marketing can never drift from the bull the chain describes.
// Fefers learned this the hard way with a checked-in `/original.png` that went
// stale the day the king got his coronation treatment.
//
// ⚠ THE TIER AND THE WEAPON COME FROM THE CHAIN'S OWN ALGORITHMS.
// `chainBandMap()` / `chainWeapon()` are line-for-line ports of
// `Bulls._initializeRarity()` and `_rollWeaponInTier()`, verified by
// `npm run verify:rarity` against hashes pinned from a real deployment. The
// assertions below re-check the two facts this script depends on, so a wrong
// king can never be published even if something upstream breaks
// (`DECISIONS.md §27` is what that costs: 377 of 500 tiers wrong, permanently).
//
// Run: `npm run gen:brand`. Requires Node 22.7+ for native TypeScript.

import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import {
  chainBandMap,
  chainWeapon,
  assignNames,
  rollToken,
  renderTile,
  KING_ID,
  KING_NAME,
  KING_WEAPON,
  TILE_W,
  TILE_H,
} from '../src/lib/art/bull.ts';
// ⚠ THE 5x9 BRAND FONT, NOT `src/lib/pixelFont.ts`. That one is 3x5 and
// cannot tell m from n by its own admission, so `bnbulls` came out as
// `bmbulls` on the first draft of this card, and it has no lowercase at all.
import { drawText, textWidth, GLYPH_H } from './wordmark.ts';
import {
  assertUniformBlocks,
  blit,
  createBitmap,
  crop,
  downscaleBox,
  encodePng,
  getPixel,
  setPixel,
  upscaleNearest,
  type Bitmap,
} from './png.ts';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.join(__dirname, '../src/app');
const publicDir = path.join(__dirname, '../public');
mkdirSync(publicDir, { recursive: true });

// ─── the king, off the real engine ───────────────────────────────────

const bandMap = chainBandMap();
const names = assignNames(bandMap);
// #501 has no entry in the 1..500 tier map; `legendary` is the band override
// the site's `art/collection.ts` uses so he renders coherently under his own
// name. His WEAPON is not an override: `chainWeapon` returns the king-only
// weapon for #501, matching `Bulls.mintKing()`.
const king = rollToken(KING_ID, bandMap, { band: 'legendary', names });

if (king.name !== KING_NAME) {
  throw new Error(`the king is not ${KING_NAME}: got "${king.name}". Refusing to publish.`);
}
/*
 * ⚠ THIS DOES NOT PIN A WEAPON. `KING_WEAPON` is the ENGINE's own export, so
 * when the king's weapon is redesigned this check follows it and every asset
 * below re-renders with the new one for free. What it asserts is only that
 * #501 got the KING-ONLY weapon rather than a tier draw, which is the one way
 * these renders could quietly ship the wrong bull.
 *
 * ⚠ NOTHING IN THIS SCRIPT MAY HARD-CODE, HAND-DRAW OR NAME THE WEAPON. It is
 * being changed. Everything published here is rendered through `renderTile`
 * precisely so that is a re-run, not a redraw.
 */
if (king.weapon !== KING_WEAPON || chainWeapon(KING_ID, 'legendary') !== KING_WEAPON) {
  throw new Error(
    `#501 did not receive the engine's king-only weapon (${KING_WEAPON}): got "${king.weapon}".`,
  );
}

const tilePixels = renderTile(king);
const tile: Bitmap = { width: TILE_W, height: TILE_H, data: tilePixels };
const BG = [king.bg[0], king.bg[1], king.bg[2], 255] as const;

// ─── the head crop ───────────────────────────────────────────────────
//
// ⚠ A FULL-BODY BULL AT 16px IS MUD. The favicon has to be a hard-edged,
// legible crop of the head and horns, and the only way to know it reads is to
// render it at 16px and look. `--proof` writes exactly that.
//
// The bounding box is MEASURED, not typed in: anything that is not the tile's
// background colour, in the rows above the neck. That way an art change that
// moves the horns moves the crop with it instead of silently clipping them.

function isBackground(x: number, y: number): boolean {
  const p = getPixel(tile, x, y);
  return p[0] === BG[0] && p[1] === BG[1] && p[2] === BG[2];
}

/** Rows 0..NECK_Y are head and horns. Below that the neck runs into the chest
 *  and the shoulders spread out under it. */
const NECK_Y = 28;

/*
 * ⚠ WHERE THE HEAD ENDS AND THE WEAPON BEGINS IS MEASURED, NOT TYPED IN.
 *
 * An earlier version cut at a hard-coded column, on the strength of
 * `DECISIONS.md §6`'s rule that the shaft sits at a fixed x. That number is
 * about to stop being safe: the king's weapon is being redesigned. A magic
 * column would either crop his new weapon into the favicon or slice a horn off
 * the side of it, silently, on an icon nobody re-checks.
 *
 * Splitting on empty columns does not work either — measured: the current
 * weapon's head TOUCHES the right horn's outline, so the two are one run.
 *
 * What does work is the two properties the art engine actually guarantees:
 *
 *   1. THE BULL IS SYMMETRIC. Horns, brow, eyes, muzzle and neck are all
 *      mirrored about one centre column (`§6`: the horn sweep is drawn for
 *      `dir` of -1 and +1 off the same points).
 *   2. THE WEAPON IS ALWAYS ON THE RIGHT. `§6` again, and it is a hard rule
 *      rather than a coincidence: "weapons held vertical through the fist" on
 *      the right side, because a mirrored duel sprite has to read as gripped.
 *
 * So: find the axis of symmetry by comparing whole COLUMNS (each column's
 * occupancy down the head rows, as a string) outwards from every candidate
 * centre and keeping the one that agrees furthest. Then take the LEFT edge,
 * which no weapon can ever reach, and mirror it. Nothing below contains a
 * column number.
 */
const columnMask: string[] = [];
for (let x = 0; x < TILE_W; x++) {
  let mask = '';
  for (let y = 0; y <= NECK_Y; y++) mask += isBackground(x, y) ? '.' : '#';
  columnMask.push(mask);
}
const columnOccupied = columnMask.map((m) => m.includes('#'));

let centreX = -1;
let bestAgreement = -1;
for (let cx = 1; cx < TILE_W - 1; cx++) {
  if (!columnOccupied[cx]) continue;
  let d = 0;
  while (cx - d - 1 >= 0 && cx + d + 1 < TILE_W && columnMask[cx - d - 1] === columnMask[cx + d + 1]) {
    d++;
  }
  if (d > bestAgreement) {
    bestAgreement = d;
    centreX = cx;
  }
}

let hx0 = TILE_W;
for (let x = 0; x < TILE_W; x++) {
  if (columnOccupied[x]) {
    hx0 = x;
    break;
  }
}
// Mirror the left edge. The right horn is the same shape as the left one, and
// anything further right is the weapon.
const hx1 = 2 * centreX - hx0;
const headW = hx1 - hx0 + 1;

/*
 * Sanity gates. A heuristic that fails silently is worse than no heuristic:
 * every one of these means "the sprite changed shape, go and look at the crop
 * before you publish an icon of it".
 */
if (centreX < 0 || bestAgreement < 8) {
  throw new Error(
    `could not find the bull's axis of symmetry in the head rows (best agreement ` +
      `${bestAgreement}px at x ${centreX}). The sprite is no longer mirror-symmetric up top.`,
  );
}
if (headW < 20 || hx1 >= TILE_W) {
  throw new Error(
    `the mirrored head is ${headW}px wide, centred on x ${centreX}. That is not a head and ` +
      'horns. Check the crop before publishing.',
  );
}
if (hx0 === 0 || hx1 === TILE_W - 1) {
  // `DECISIONS.md §6`: the whole composition is inset by a pixel and the build
  // fails if anything reaches the border ring. If it happens here, something
  // upstream is already broken.
  throw new Error(`the head touches the tile border (x ${hx0}..${hx1}). Refusing to crop.`);
}
if (!columnOccupied[hx1]) {
  throw new Error(
    `the mirrored right edge (x ${hx1}) is empty, so the head is not symmetric about x ` +
      `${centreX}. Refusing to crop a lopsided king.`,
  );
}

let hy0 = TILE_H;
let hy1 = 0;
for (let y = 0; y <= NECK_Y; y++) {
  for (let x = hx0; x <= hx1; x++) {
    if (isBackground(x, y)) continue;
    if (y < hy0) hy0 = y;
    if (y > hy1) hy1 = y;
  }
}
const headH = hy1 - hy0 + 1;

/**
 * The icon canvas is square and sized so the head fills it edge to edge
 * horizontally, with the vertical slack split evenly. Boldness is what
 * survives being shrunk to a tab; a head floating in a wide margin does not.
 *
 * ⚠ The head is an ODD number of columns wide (the sprite is symmetric about
 * one centre column), so a square canvas that fits it has one spare row or
 * column of margin on one side. That asymmetry is in the MARGIN, never in the
 * bull: clipping a horn outline to make the numbers rounder would make the
 * king visibly lopsided at large sizes, which is a worse trade than a pixel of
 * uneven background nobody can see.
 */
const ICON_SRC = Math.max(headW, headH);
const headCrop = createBitmap(ICON_SRC, ICON_SRC, BG);
blit(
  headCrop,
  crop(tile, hx0, hy0, headW, headH),
  Math.floor((ICON_SRC - headW) / 2),
  Math.floor((ICON_SRC - headH) / 2),
);

// ─── outputs ─────────────────────────────────────────────────────────

function write(file: string, b: Bitmap, dir = appDir): void {
  const p = path.join(dir, file);
  writeFileSync(p, encodePng(b));
  console.log(`  ${path.relative(path.join(__dirname, '..'), p)}  ${b.width}x${b.height}`);
}

console.log(`rendering ${KING_NAME} (#${KING_ID}, ${king.band}, ${king.weapon}) from the art engine`);
console.log(`  head bbox: x ${hx0}..${hx1} (${headW}px), y ${hy0}..${hy1} (${headH}px)`);
console.log(`  icon source: ${ICON_SRC}x${ICON_SRC}\n`);

// The tab icon. Big enough for bookmarks, app lists and high-DPI, produced by
// integer nearest-neighbour so nothing but a browser's own downscale ever
// touches it.
const ICON_SCALE = 16;
const icon = upscaleNearest(headCrop, ICON_SCALE);
assertUniformBlocks(icon, ICON_SCALE, 'icon.png');
write('icon.png', icon);

// apple-touch-icon / home-screen. Same head: an iOS home screen is a small
// square too, and the full body loses to the head there for the same reason.
write('apple-icon.png', icon);

// The nav logo, and a plain copy for anywhere that wants the head as a file.
write('lord-wagyu-head.png', upscaleNearest(headCrop, 8), publicDir);
// The full body, for posts and any surface with room for the whole bull.
write('lord-wagyu.png', upscaleNearest(tile, 8), publicDir);

// ─── the link-preview card ───────────────────────────────────────────
//
// 1200x630 is what telegram and X actually crop to. Type is stamped from the
// hand-drawn 5x9 bitmap font at an integer scale, NOT a webfont: anti-aliased
// type beside hard pixel art looks broken, and a font file is one more thing a
// build can fail to fetch (`VOICE-AND-BRAND.md §5`).
//
// ⚠ LOWERCASE, to match `public/banner-1500x500.png`. Two brand assets for one
// project must not disagree about how the name is set, and the voice is
// lowercase everywhere else on the site.

const OG_W = 1200;
const OG_H = 630;
const INK = { bg: [20, 18, 15, 255], gold: [240, 185, 11, 255], bone: [176, 167, 147, 255] };

// `VOICE-AND-BRAND.md §1`: one or two lines, never a paragraph, mid-dot as the
// separator. Hoisted out of `buildCard` because the bull's scale is derived
// from the widest of them.
const LINES: Array<[string, number, readonly number[]]> = [
  ['bnbulls', 13, INK.gold],
  ['pixel bull pvp on bnb chain', 4, INK.bone],
  ['real money in the middle', 4, INK.bone],
  ['lord wagyu · 1 of 1', 3, INK.gold],
];

function textSink(b: Bitmap, colour: readonly number[]) {
  return { set: (x: number, y: number) => setPixel(b, x, y, colour) };
}

function buildCard(): Bitmap {
  const card = createBitmap(OG_W, OG_H, INK.bg);

  // A stockyard-rail grid, the same motif as the site's hero backdrop, kept
  // very faint so it never competes with the bull.
  for (let y = 0; y < OG_H; y += 44) {
    for (let x = 0; x < OG_W; x++) setPixel(card, x, y, [34, 30, 24, 255]);
  }
  for (let x = 0; x < OG_W; x += 44) {
    for (let y = 0; y < OG_H; y++) setPixel(card, x, y, [34, 30, 24, 255]);
  }

  // ⚠ THE BULL SCALE IS DERIVED, NOT TYPED IN.
  //
  // It was a hard-coded 7, sized by eye against a 56px-wide tile. When the bull
  // was centred in its frame the tile went to 71px, the type block was pushed
  // 105px right, and the overflow guard below fired — which is the guard doing
  // its job, but a magic number that only fails on a canvas change is a magic
  // number that will fail again. So: take the largest INTEGER scale (nothing
  // else keeps the pixels square) that still leaves room for the widest line of
  // type at its authored size, and for vertical breathing room.
  //
  // At 71px wide that lands on 5, which puts the king at very nearly the same
  // share of the card as the old 7x of a 56px tile — the composition does not
  // move, only the arithmetic that produces it.
  const bx = 64;
  const TEXT_GAP = 56;
  const RIGHT_PAD = 40;
  const widestLine = Math.max(...LINES.map(([text, sc]) => textWidth(text, sc)));
  let BULL_SCALE = 0;
  for (let s = 1; s <= 12; s++) {
    const fitsWide = bx + tile.width * s + TEXT_GAP + widestLine <= OG_W - RIGHT_PAD;
    const fitsTall = tile.height * s <= OG_H - 80;
    if (fitsWide && fitsTall) BULL_SCALE = s;
  }
  if (BULL_SCALE < 4) {
    throw new Error(
      `og card: a ${tile.width}x${tile.height} tile leaves no room for the king beside the type ` +
        `(best integer scale ${BULL_SCALE}). Re-lay the card rather than shrinking him further.`,
    );
  }
  const bull = upscaleNearest(tile, BULL_SCALE);
  assertUniformBlocks(bull, BULL_SCALE, 'og bull');
  const by = Math.round((OG_H - bull.height) / 2);
  // A gold frame, because he is the 1/1 and a cream tile needs an edge to sit
  // on against a near-black card.
  for (let y = by - 4; y < by + bull.height + 4; y++) {
    for (let x = bx - 4; x < bx + bull.width + 4; x++) setPixel(card, x, y, INK.gold);
  }
  blit(card, bull, bx, by);

  const tx = bx + bull.width + TEXT_GAP;
  const lines = LINES;
  const gaps = [38, 16, 32];
  const blockH =
    lines.reduce((a, [, sc]) => a + GLYPH_H * sc, 0) + gaps.reduce((a, g) => a + g, 0);
  let ty = Math.round((OG_H - blockH) / 2);
  for (let i = 0; i < lines.length; i++) {
    const [text, sc, colour] = lines[i];
    // Guard: type that has quietly run off the right edge is the kind of thing
    // nobody notices until it is on twitter.
    const right = tx + textWidth(text, sc);
    if (right > OG_W - 40) {
      throw new Error(`og card: "${text}" overflows the card (${right} > ${OG_W - 40})`);
    }
    drawText(textSink(card, colour), text, tx, ty, sc);
    ty += GLYPH_H * sc + (gaps[i] ?? 0);
  }
  return card;
}

const card = buildCard();
write('opengraph-image.png', card);
write('twitter-image.png', card);

// ─── the 16px proof ──────────────────────────────────────────────────
//
// The whole point. `--proof` writes what a browser actually puts in a tab,
// plus a magnified copy so the same pixels can be inspected by eye. If the
// small one does not read as a horned skull, the crop above is wrong.

if (process.argv.includes('--proof')) {
  const proofDir = path.join(__dirname, '../.brand-proof');
  mkdirSync(proofDir, { recursive: true });
  const sizes = [16, 32, 48, 64];
  // One sheet: each size rendered at its true size on the top row, and blown
  // up underneath so the pixels are readable.
  const pad = 16;
  const magnify = 8;
  const sheetW = sizes.reduce((a, s) => a + s * magnify + pad, pad);
  const sheet = createBitmap(sheetW, 64 + 64 * magnify + pad * 3, INK.bg);
  let x = pad;
  for (const s of sizes) {
    const small = downscaleBox(icon, s, s);
    writeFileSync(path.join(proofDir, `icon-${s}.png`), encodePng(small));
    blit(sheet, small, x, pad);
    blit(sheet, upscaleNearest(small, magnify), x, pad + 72);
    x += s * magnify + pad;
  }
  writeFileSync(path.join(proofDir, 'sheet.png'), encodePng(sheet));
  console.log(`\n  proof: .brand-proof/ (icon-16/32/48/64.png + sheet.png)`);

  // And an ASCII dump of the 16px one, so the check survives being read in a
  // terminal with no image viewer.
  const tiny = downscaleBox(icon, 16, 16);
  console.log('\n  what a 16px tab shows:');
  for (let y = 0; y < 16; y++) {
    let line = '  ';
    for (let xx = 0; xx < 16; xx++) {
      const p = getPixel(tiny, xx, y);
      const lum = (p[0] * 299 + p[1] * 587 + p[2] * 114) / 1000;
      line += lum > 200 ? ' ' : lum > 150 ? '.' : lum > 100 ? '+' : lum > 55 ? '%' : '#';
    }
    console.log(line);
  }
}

console.log('\ndone.');
