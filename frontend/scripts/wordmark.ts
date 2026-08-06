// A hand-drawn 5x9 bitmap font, for BRAND type only (the link-preview card).
// Build-time; never shipped to a browser.
//
// ⚠ WHY THIS EXISTS WHEN `src/lib/pixelFont.ts` ALREADY DOES TYPE.
// That one is 3x5, tuned by eye for the duel HUD, where the job is fitting 24
// characters across a replay frame. At three pixels wide, M and N cannot be
// told apart: its own comment calls them "the hard pair". Blown up to a
// wordmark, `bnbulls` renders as **bmbulls** — checked, on the first draft of
// the og card, which is the picture that shows up every time somebody drops
// the link in telegram. Five pixels wide gives those two the column they need.
//
// ⚠ WHY 9 ROWS AND NOT 7. The brand is lowercase (`VOICE-AND-BRAND.md §1`,
// and the collection banner already in `public/` sets the name that way). Real
// lowercase needs three zones, so the box is:
//
//     rows 0-1   ascender  (b d f h k l t, and all caps)
//     rows 2-6   x-height  (a c e m n o r s u v w x z)
//     row  6     baseline
//     rows 7-8   descender (g j p q y)
//
// Capitals and digits occupy rows 0-6 and leave 7-8 empty, so mixed-case type
// sits on one baseline. `drawText` is CASE-SENSITIVE for the same reason: the
// old version upper-cased everything, which is exactly what made the card
// disagree with the banner.
//
// Same governing rule as fefers' brand pipeline (`VOICE-AND-BRAND.md §5`):
// hand-drawn pixel wordmarks, NO fonts. Anti-aliased type beside hard pixel
// art looks broken, and a webfont is one more thing a build can fail to fetch.
//
// ⚠ AN UNKNOWN CHARACTER THROWS. It does not render blank and it does not
// render a box. A silently-dropped glyph reflows a wordmark, and the wordmark
// is the one image seen by people who never visit the site.

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
  // side by side before touching either.
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
 * ⚠ CASE-SENSITIVE. The brand is lowercase and the font has both cases, so
 * what you type is what gets drawn. Do not add an `.toUpperCase()` back.
 *
 * `scale` blows each glyph pixel into a scale x scale block, which is how the
 * headline gets bigger without a second font and stays exactly on the grid.
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
