/**
 * brandTile.ts — the hand-drawn brand type, and the one way a rendered tile
 * gets the wordmark stamped under it.
 *
 * ⚠ THIS FILE DOES NOT TOUCH THE ART ENGINE, AND IT NEVER WILL.
 * `generator/` and `src/lib/art/` are signed off and out of bounds. A wordmark
 * is BRANDING, not a trait: baking it into `renderTile` would put it on all 501
 * bulls, on every card, in the marketplace, in the token image and in every bot
 * render. So this composites — it takes a tile somebody else rendered, copies
 * it into a taller buffer, and paints the mark on the plinth underneath. The
 * input buffer is never written to.
 *
 * ⚠ IT ALSO HAS NO IMPORTS, DELIBERATELY.
 * `scripts/gen-brand-assets.ts` runs under plain `node` with native TypeScript,
 * where there is no `@/` path mapping and no bundler. A single self-contained
 * file loads identically from a node script, a server component and the
 * browser, which is the whole point: the site and the marketing renders draw
 * the same mark from the same glyphs.
 *
 * ── the font ────────────────────────────────────────────────────────────
 *
 * A hand-drawn 5x9 bitmap font, MOVED HERE VERBATIM from
 * `scripts/wordmark.ts` (glyph shapes byte-for-byte identical — do not
 * redraw them). It moved because the browser needs it now too, and two copies
 * of a wordmark font is exactly how two brand assets end up disagreeing about
 * how the name is set.
 *
 * ⚠ WHY THIS FONT AND NOT `src/lib/pixelFont.ts`.
 * That one is 3x5, tuned by eye for the duel HUD, where the job is fitting 24
 * characters across a replay frame. At three pixels wide, M and N cannot be
 * told apart: its own comment calls them "the hard pair". Blown up to a
 * wordmark, `bnbulls` renders as **bmbulls** — checked, on the first draft of
 * the og card. Five pixels wide gives those two the column they need. It is
 * also uppercase-only, and the mark is `BNBulls`.
 *
 * ⚠ WHY 9 ROWS AND NOT 7. Real lowercase needs three zones, so the box is:
 *
 *     rows 0-1   ascender  (b d f h k l t, and all caps)
 *     rows 2-6   x-height  (a c e m n o r s u v w x z)
 *     row  6     baseline
 *     rows 7-8   descender (g j p q y)
 *
 * Capitals and digits occupy rows 0-6 and leave 7-8 empty, so mixed-case type
 * sits on one baseline. `drawText` is CASE-SENSITIVE for the same reason.
 *
 * Governing rule (`VOICE-AND-BRAND.md §5`): hand-drawn pixel wordmarks, NO
 * fonts. Anti-aliased type beside hard pixel art looks broken, and a webfont is
 * one more thing a build can fail to fetch.
 *
 * ⚠ AN UNKNOWN CHARACTER THROWS. It does not render blank and it does not
 * render a box. A silently-dropped glyph reflows a wordmark, and the wordmark
 * is the one image seen by people who never visit the site.
 */

export const GLYPH_W = 5;
export const GLYPH_H = 9;
/** Advance per character, including the 1px letter gap. */
export const GLYPH_ADVANCE = 6;
/** Rows 7-8 are the descender zone; caps and digits never reach it. */
const BLANK = '.....';
const cap = (...rows: string[]): readonly string[] => [...rows, BLANK, BLANK];
/** Lowercase with no descender: two blank rows above the x-height. */
const x5 = (...rows: string[]): readonly string[] => [BLANK, BLANK, ...rows, BLANK, BLANK];

const GLYPHS: Record<string, readonly string[]> = {
  // ── capitals, rows 0-6 ────────────────────────────────────────────
  A: cap('.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'),
  B: cap('####.', '#...#', '#...#', '####.', '#...#', '#...#', '####.'),
  C: cap('.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'),
  D: cap('####.', '#...#', '#...#', '#...#', '#...#', '#...#', '####.'),
  E: cap('#####', '#....', '#....', '####.', '#....', '#....', '#####'),
  F: cap('#####', '#....', '#....', '####.', '#....', '#....', '#....'),
  G: cap('.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.###.'),
  H: cap('#...#', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'),
  I: cap('#####', '..#..', '..#..', '..#..', '..#..', '..#..', '#####'),
  J: cap('..###', '...#.', '...#.', '...#.', '...#.', '#..#.', '.##..'),
  K: cap('#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#'),
  L: cap('#....', '#....', '#....', '#....', '#....', '#....', '#####'),
  // ⚠ THE PAIR THIS FONT EXISTS FOR. M fills both upper shoulders; N keeps one
  // diagonal from top-left to bottom-right and fills neither. Compare them
  // side by side before touching either. `BNBulls` contains an N.
  M: cap('#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'),
  N: cap('#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#', '#...#'),
  O: cap('.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'),
  P: cap('####.', '#...#', '#...#', '####.', '#....', '#....', '#....'),
  Q: cap('.###.', '#...#', '#...#', '#...#', '#.#.#', '#..#.', '.##.#'),
  R: cap('####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'),
  S: cap('.####', '#....', '#....', '.###.', '....#', '....#', '####.'),
  T: cap('#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'),
  U: cap('#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'),
  V: cap('#...#', '#...#', '#...#', '#...#', '#...#', '.#.#.', '..#..'),
  W: cap('#...#', '#...#', '#...#', '#.#.#', '#.#.#', '##.##', '#...#'),
  X: cap('#...#', '#...#', '.#.#.', '..#..', '.#.#.', '#...#', '#...#'),
  Y: cap('#...#', '#...#', '.#.#.', '..#..', '..#..', '..#..', '..#..'),
  Z: cap('#####', '....#', '...#.', '..#..', '.#...', '#....', '#####'),

  // ── lowercase ─────────────────────────────────────────────────────
  a: x5('.###.', '....#', '.####', '#...#', '.####'),
  b: cap('#....', '#....', '####.', '#...#', '#...#', '#...#', '####.'),
  c: x5('.###.', '#....', '#....', '#....', '.###.'),
  d: cap('....#', '....#', '.####', '#...#', '#...#', '#...#', '.####'),
  e: x5('.###.', '#...#', '#####', '#....', '.###.'),
  f: cap('..##.', '.#...', '####.', '.#...', '.#...', '.#...', '.#...'),
  // descender
  g: [BLANK, BLANK, '.####', '#...#', '#...#', '.####', '....#', '#...#', '.###.'],
  h: cap('#....', '#....', '####.', '#...#', '#...#', '#...#', '#...#'),
  i: cap('..#..', '.....', '.##..', '..#..', '..#..', '..#..', '.###.'),
  j: ['...#.', '.....', '...#.', '...#.', '...#.', '...#.', '...#.', '#..#.', '.##..'],
  k: cap('#....', '#....', '#..#.', '#.#..', '##...', '#.#..', '#..#.'),
  l: cap('.##..', '..#..', '..#..', '..#..', '..#..', '..#..', '.###.'),
  m: x5('##.#.', '#.#.#', '#.#.#', '#.#.#', '#.#.#'),
  n: x5('####.', '#...#', '#...#', '#...#', '#...#'),
  o: x5('.###.', '#...#', '#...#', '#...#', '.###.'),
  p: [BLANK, BLANK, '####.', '#...#', '#...#', '####.', '#....', '#....', '#....'],
  q: [BLANK, BLANK, '.####', '#...#', '#...#', '.####', '....#', '....#', '....#'],
  r: x5('#.##.', '##..#', '#....', '#....', '#....'),
  s: x5('.####', '#....', '.###.', '....#', '####.'),
  t: cap('.#...', '.#...', '####.', '.#...', '.#...', '.#...', '..##.'),
  u: x5('#...#', '#...#', '#...#', '#...#', '.####'),
  v: x5('#...#', '#...#', '#...#', '.#.#.', '..#..'),
  w: x5('#...#', '#...#', '#.#.#', '#.#.#', '.#.#.'),
  x: x5('#...#', '.#.#.', '..#..', '.#.#.', '#...#'),
  y: [BLANK, BLANK, '#...#', '#...#', '#...#', '.####', '....#', '#...#', '.###.'],
  z: x5('#####', '...#.', '..#..', '.#...', '#####'),

  // ── digits, rows 0-6 ──────────────────────────────────────────────
  '0': cap('.###.', '#...#', '#..##', '#.#.#', '##..#', '#...#', '.###.'),
  '1': cap('..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'),
  '2': cap('.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'),
  '3': cap('####.', '....#', '....#', '.###.', '....#', '....#', '####.'),
  '4': cap('...#.', '..##.', '.#.#.', '#..#.', '#####', '...#.', '...#.'),
  '5': cap('#####', '#....', '####.', '....#', '....#', '#...#', '.###.'),
  '6': cap('.###.', '#...#', '#....', '####.', '#...#', '#...#', '.###.'),
  '7': cap('#####', '....#', '...#.', '..#..', '.#...', '.#...', '.#...'),
  '8': cap('.###.', '#...#', '#...#', '.###.', '#...#', '#...#', '.###.'),
  '9': cap('.###.', '#...#', '#...#', '.####', '....#', '#...#', '.###.'),

  // ── punctuation ───────────────────────────────────────────────────
  ' ': cap(BLANK, BLANK, BLANK, BLANK, BLANK, BLANK, BLANK),
  // ⚠ THE SANCTIONED SEPARATOR IS THE MID-DOT (`VOICE-AND-BRAND.md §1`).
  // There is deliberately NO em-dash glyph in this font: it is an AI tell and
  // it is banned in every piece of copy this project ships. You cannot draw
  // one by accident because it does not exist.
  '·': cap(BLANK, BLANK, BLANK, BLANK, '..#..', BLANK, BLANK),
  '.': cap(BLANK, BLANK, BLANK, BLANK, BLANK, BLANK, '..#..'),
  ',': [BLANK, BLANK, BLANK, BLANK, BLANK, BLANK, '..#..', '.#...', BLANK],
  '!': cap('..#..', '..#..', '..#..', '..#..', '..#..', BLANK, '..#..'),
  '?': cap('.###.', '#...#', '....#', '...#.', '..#..', BLANK, '..#..'),
  '-': cap(BLANK, BLANK, BLANK, '#####', BLANK, BLANK, BLANK),
  ':': cap(BLANK, '..#..', BLANK, BLANK, BLANK, '..#..', BLANK),
  "'": cap('..#..', '..#..', BLANK, BLANK, BLANK, BLANK, BLANK),
  '/': cap('....#', '....#', '...#.', '..#..', '.#...', '#....', '#....'),
  // The stroke pokes above and below the S body, or it reads as an I.
  $: cap('..#..', '.####', '#.#..', '.###.', '..#.#', '####.', '..#..'),
};

export interface GlyphTarget {
  /** Set one pixel. Out-of-bounds coordinates must be ignored by the sink. */
  set(x: number, y: number): void;
}

/** Width in pixels of `text` when drawn at `scale`, excluding the trailing gap. */
export function textWidth(text: string, scale = 1): number {
  if (!text.length) return 0;
  return (text.length * GLYPH_ADVANCE - 1) * scale;
}

export const textHeight = (scale = 1) => GLYPH_H * scale;

/**
 * Stamp `text` with its top-left at (x, y).
 *
 * ⚠ CASE-SENSITIVE. `BNBulls` is the mark and the font has both cases, so what
 * you type is what gets drawn. Do not add a `.toUpperCase()` back.
 *
 * `scale` blows each glyph pixel into a scale x scale block, which is how type
 * gets bigger without a second font and stays exactly on the grid.
 */
export function drawText(
  target: GlyphTarget,
  text: string,
  x: number,
  y: number,
  scale = 1,
): void {
  const s = Math.max(1, Math.floor(scale));
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    const g = GLYPHS[ch];
    if (!g) {
      throw new Error(
        `wordmark font has no glyph for ${JSON.stringify(ch)}. Add it, or change the ` +
          'copy — a silently dropped character reflows the wordmark.',
      );
    }
    const gx = x + i * GLYPH_ADVANCE * s;
    for (let row = 0; row < GLYPH_H; row++) {
      const bits = g[row]!;
      for (let col = 0; col < GLYPH_W; col++) {
        if (bits[col] !== '#') continue;
        for (let dy = 0; dy < s; dy++) {
          for (let dx = 0; dx < s; dx++) target.set(gx + col * s + dx, y + row * s + dy);
        }
      }
    }
  }
}

// ─── the branded tile ────────────────────────────────────────────────

export type RGB = readonly [number, number, number];

/** A raw RGBA raster. Matches what `renderTile()` hands back, and what
 *  `scripts/png.ts`'s `Bitmap` takes. */
export interface PixelBuffer {
  readonly width: number;
  readonly height: number;
  readonly data: Uint8ClampedArray;
}

/** One coloured stretch of the line. Runs sit hard against each other with the
 *  font's normal letter gap, so `BNB` + `ulls` reads as one word in two
 *  colours — exactly what `<Wordmark />` does in CSS. */
export interface TextRun {
  readonly text: string;
  readonly rgb: RGB;
}

/*
 * The three colours, and they are the SAME THREE the rest of the site uses.
 * A canvas cannot read a CSS custom property, so these are the literal values
 * of `--bull-bg`, `--bull-gold` and `--bull-text` from `globals.css`. If the
 * palette is ever rethemed, these three follow it.
 */
/** `--bull-bg` (#14120F). */
export const PLINTH_RGB: RGB = [20, 18, 15];
/** `--bull-gold` (#F0B90B) — BNB Chain's own colour, on exactly `BNB`. */
export const MARK_GOLD: RGB = [240, 185, 11];
/** `--bull-text` (#F0EAE0) — bone, on `ulls`. */
export const MARK_BONE: RGB = [240, 234, 224];

/**
 * ⚠ THE PLINTH IS DARK, AND THAT IS THE WHOLE REASON IT READS.
 *
 * Every tile in the collection has a pale background (the king's is cream,
 * `246 232 188`). Gold on cream is a luminance difference of about 30 out of
 * 255 and white on cream is worse — the mark would be there and nobody would
 * be able to read it. The font is a flat-fill bitmap with 1px counters, so an
 * outline shell is not the way out either: dilating a 5x9 `s` closes its own
 * gaps and it turns into a blob.
 *
 * So the mark gets a plinth, in the site's own near-black, and the type is
 * flat gold + bone on top. That is the identical treatment as the link-preview
 * card in `scripts/gen-brand-assets.ts`, which is the other place this wordmark
 * is set, and it means the mark reads on ALL 501 tiles rather than only on the
 * pale ones.
 */
/** Plinth height in tile pixels. Fixed, so a caller can reserve the composite's
 *  aspect box before the canvas has painted a single pixel. */
export const PLINTH_H = 13;

/** Clear pixels kept either side of the type. */
const SIDE_INSET = 3;

export interface WordmarkTileOptions {
  /** Integer glyph scale. Omitted, the largest scale that fits is used, which
   *  is the only way this stays whole-pixel at every tile size. */
  scale?: number;
  /** Plinth height in tile pixels. Defaults to `PLINTH_H`. */
  plinthH?: number;
  /** Plinth fill. Defaults to `PLINTH_RGB`. */
  plinth?: RGB;
}

/** The composite's height for a given tile — known without rendering anything,
 *  so a layout can reserve the space up front and never jump. */
export function brandedTileHeight(tileH: number, plinthH: number = PLINTH_H): number {
  return tileH + plinthH;
}

/**
 * Copy `tile` into a taller buffer and stamp `runs` centred on the plinth
 * underneath it.
 *
 * ⚠ `tile` IS NEVER MUTATED. The pixels are copied into a fresh buffer, so the
 * same rendered tile can be handed to this and to anything else.
 *
 * ⚠ EVERYTHING LANDS ON A WHOLE PIXEL. The glyph scale is an integer, and the
 * type is centred on its measured INK box (not its 9-row layout box, which has
 * two empty descender rows for text with no descenders) at rounded integer
 * coordinates. Nothing here can produce a half-pixel, so `image-rendering:
 * pixelated` has clean square blocks to work with and the mark stays as hard-
 * edged as the bull above it.
 *
 * ⚠ SCALE UP, NEVER DOWN. Marketing renders want this at 8x or 16x: compose
 * once at tile resolution and nearest-neighbour the RESULT by a whole number
 * (`VOICE-AND-BRAND.md §5`). Composing at a bigger canvas instead would let
 * the mark take a different share of the tile than the site shows, and two
 * brand assets that disagree is the failure this is trying to avoid.
 */
export function composeWordmarkTile(
  tile: PixelBuffer,
  runs: readonly TextRun[],
  opts: WordmarkTileOptions = {},
): PixelBuffer {
  const { width, height } = tile;
  const plinthH = opts.plinthH ?? PLINTH_H;
  const plinth = opts.plinth ?? PLINTH_RGB;
  const line = runs.map((r) => r.text).join('');

  // The biggest whole-pixel scale that still clears the inset. Nothing else
  // keeps the glyph blocks square.
  let scale = Math.max(1, Math.floor(opts.scale ?? 0));
  if (!opts.scale) {
    scale = 0;
    for (let s = 1; s <= 64; s++) if (textWidth(line, s) <= width - SIDE_INSET * 2) scale = s;
  }
  if (scale < 1 || textWidth(line, scale) > width - SIDE_INSET * 2) {
    throw new Error(
      `"${line}" does not fit across a ${width}px tile at scale ${scale || 1}. Shorten the ` +
        'mark rather than letting it run into the frame.',
    );
  }

  // Draw once into a sparse map to MEASURE the ink, because the layout box is
  // not the ink box: caps sit in rows 0-6 of a 9-row box, so centring the box
  // would hang the mark two rows high on the plinth.
  const ink: Array<{ x: number; y: number; rgb: RGB }> = [];
  let cursor = 0;
  for (const run of runs) {
    drawText({ set: (x, y) => ink.push({ x, y, rgb: run.rgb }) }, run.text, cursor, 0, scale);
    cursor += run.text.length * GLYPH_ADVANCE * scale;
  }
  if (!ink.length) throw new Error('the wordmark drew no pixels. Check the runs.');

  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  for (const p of ink) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.y > maxY) maxY = p.y;
  }
  const inkW = maxX - minX + 1;
  const inkH = maxY - minY + 1;
  if (inkH > plinthH) {
    throw new Error(
      `the mark is ${inkH}px tall and the plinth is ${plinthH}px. Raise PLINTH_H rather ` +
        'than clipping the type.',
    );
  }

  const outH = height + plinthH;
  const out = new Uint8ClampedArray(width * outH * 4);
  out.set(tile.data.subarray(0, width * height * 4), 0);
  for (let i = width * height; i < width * outH; i++) {
    const o = i * 4;
    out[o] = plinth[0];
    out[o + 1] = plinth[1];
    out[o + 2] = plinth[2];
    out[o + 3] = 255;
  }

  // Centred on the ink box, on whole pixels, in both axes.
  const ox = Math.round((width - inkW) / 2) - minX;
  const oy = height + Math.round((plinthH - inkH) / 2) - minY;
  for (const p of ink) {
    const x = p.x + ox;
    const y = p.y + oy;
    if (x < 0 || x >= width || y < 0 || y >= outH) continue;
    const o = (y * width + x) * 4;
    out[o] = p.rgb[0];
    out[o + 1] = p.rgb[1];
    out[o + 2] = p.rgb[2];
    out[o + 3] = 255;
  }

  return { width, height: outH, data: out };
}
