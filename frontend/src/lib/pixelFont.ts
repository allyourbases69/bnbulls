/**
 * pixelFont.ts — a hand-drawn 3x5 bitmap font.
 *
 * ⚠ PORTED BYTE-FOR-BYTE from Fighting Fefers (`app/frontend/src/lib/
 * pixelFont.ts`). No imports, no game knowledge, nothing to retheme — the
 * glyph shapes are the whole content and they were tuned by eye at 3x5.
 *
 * The duel replay is rendered at a small logical size and then integer-scaled,
 * so any real font would either be resampled (fuzzy, and fuzzy text next to
 * hard pixel art looks broken) or drag in a font file the deploy does not have.
 * This is the same call the brand assets made with their 5x7 wordmark: draw the
 * letters by hand, keep everything on the pixel grid.
 *
 * 3x5 with a 1px gap means 4px per character, so 24 characters fit across the
 * replay's full width. Only the glyphs the HUD actually needs exist; anything
 * unmapped renders as a blank, never as a box, because a missing glyph must not
 * turn a winner's name into rubble.
 */

export const GLYPH_W = 3;
export const GLYPH_H = 5;
/** Advance per character, including the 1px letter gap. */
export const GLYPH_ADVANCE = 4;

/** Five rows of three bits, MSB = leftmost pixel. */
const GLYPHS: Record<string, readonly string[]> = {
  '0': ['111', '101', '101', '101', '111'],
  '1': ['010', '110', '010', '010', '111'],
  '2': ['111', '001', '111', '100', '111'],
  '3': ['111', '001', '111', '001', '111'],
  '4': ['101', '101', '111', '001', '001'],
  '5': ['111', '100', '111', '001', '111'],
  '6': ['111', '100', '111', '101', '111'],
  '7': ['111', '001', '001', '001', '001'],
  '8': ['111', '101', '111', '101', '111'],
  '9': ['111', '101', '111', '001', '001'],
  A: ['111', '101', '111', '101', '101'],
  B: ['110', '101', '110', '101', '110'],
  C: ['111', '100', '100', '100', '111'],
  D: ['110', '101', '101', '101', '110'],
  E: ['111', '100', '111', '100', '111'],
  F: ['111', '100', '111', '100', '100'],
  G: ['111', '100', '101', '101', '111'],
  H: ['101', '101', '111', '101', '101'],
  I: ['111', '010', '010', '010', '111'],
  J: ['001', '001', '001', '101', '111'],
  K: ['101', '101', '110', '101', '101'],
  L: ['100', '100', '100', '100', '111'],
  // M and N are the hard pair at three pixels wide. M takes both top rows
  // solid, N keeps a single top pixel pair and drops the shoulder — the two
  // shapes that read least ambiguously against each other at this size.
  M: ['111', '111', '101', '101', '101'],
  N: ['101', '111', '111', '101', '101'],
  O: ['111', '101', '101', '101', '111'],
  P: ['111', '101', '111', '100', '100'],
  Q: ['111', '101', '101', '111', '001'],
  R: ['111', '101', '111', '110', '101'],
  S: ['111', '100', '111', '001', '111'],
  T: ['111', '010', '010', '010', '010'],
  U: ['101', '101', '101', '101', '111'],
  V: ['101', '101', '101', '101', '010'],
  W: ['101', '101', '111', '111', '101'],
  X: ['101', '101', '010', '101', '101'],
  Y: ['101', '101', '010', '010', '010'],
  Z: ['111', '001', '010', '100', '111'],
  ' ': ['000', '000', '000', '000', '000'],
  '#': ['101', '111', '101', '111', '101'],
  '-': ['000', '000', '111', '000', '000'],
  '+': ['000', '010', '111', '010', '000'],
  '!': ['010', '010', '010', '000', '010'],
  '?': ['111', '001', '010', '000', '010'],
  '.': ['000', '000', '000', '000', '010'],
  ',': ['000', '000', '000', '010', '100'],
  ':': ['000', '010', '000', '010', '000'],
  '/': ['001', '001', '010', '100', '100'],
  '%': ['101', '001', '010', '100', '101'],
  '*': ['101', '010', '111', '010', '101'],
  "'": ['010', '010', '000', '000', '000'],
  '(': ['010', '100', '100', '100', '010'],
  ')': ['010', '001', '001', '001', '010'],
  // The stroke has to poke ABOVE the S body or it reads as an 'I' at this size
  // — which it did, on a live buyback card that said "THE IFEFER BUYBACK".
  // Compared against four alternatives rendered side by side; this is the only
  // one that reads as a dollar sign at 3x5.
  $: ['010', '111', '110', '011', '111'],
};

/** Width in pixels of `text` when drawn, excluding the trailing gap. */
export function textWidth(text: string, scale = 1): number {
  if (!text.length) return 0;
  return (text.length * GLYPH_ADVANCE - 1) * scale;
}

/** Height in pixels of a line at `scale`. */
export const textHeight = (scale = 1) => GLYPH_H * scale;

export interface GlyphTarget {
  /** Set one pixel. Out-of-bounds coordinates must be ignored by the sink. */
  set(x: number, y: number): void;
}

/**
 * Stamp `text` with its top-left at (x, y). Unknown characters advance without
 * drawing. Case-insensitive: the font has one case and shouting suits the
 * arena.
 *
 * `scale` blows each glyph pixel up into a scale x scale block, which is how
 * headings get to be bigger without a second font: at 2x this is a chunky 6x10
 * that still lands exactly on the pixel grid. Anti-aliased type next to hard
 * pixel art looks broken, so growing the blocks is the only way up.
 */
export function drawText(
  target: GlyphTarget,
  text: string,
  x: number,
  y: number,
  scale = 1,
): void {
  const upper = text.toUpperCase();
  const s = Math.max(1, Math.floor(scale));
  for (let i = 0; i < upper.length; i++) {
    const g = GLYPHS[upper[i]!];
    const gx = x + i * GLYPH_ADVANCE * s;
    if (!g) continue;
    for (let row = 0; row < GLYPH_H; row++) {
      const bits = g[row]!;
      for (let col = 0; col < GLYPH_W; col++) {
        if (bits[col] !== '1') continue;
        for (let dy = 0; dy < s; dy++) {
          for (let dx = 0; dx < s; dx++) target.set(gx + col * s + dx, y + row * s + dy);
        }
      }
    }
  }
}
