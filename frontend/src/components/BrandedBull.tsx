'use client';

import { useEffect, useRef } from 'react';
import { renderTile, TILE_W, TILE_H, type Token } from '@/lib/art/bull';
import {
  brandedTileHeight,
  composeWordmarkTile,
  MARK_BONE,
  MARK_GOLD,
  PLINTH_RGB,
  type TextRun,
} from '@/lib/brandTile';
import { SITE_NAME } from '@/lib/brand';

/**
 * BrandedBull — a bull with the wordmark stamped on a plinth underneath him.
 *
 * ⚠ THE MARK IS COMPOSITED, NOT BAKED. `renderTile()` draws the collection and
 * it is signed off and out of bounds. A wordmark is branding, not a trait:
 * putting it in the engine would print it on all 501 bulls, on every card, in
 * the marketplace, in the token image and in every bot render. So this copies
 * the rendered tile into a taller buffer and paints the mark below it
 * (`src/lib/brandTile.ts`), and `BullSprite` — the component every OTHER bull
 * on the site is drawn with — is untouched.
 *
 * ⚠ USE IT FOR THE 1/1 AND FOR MARKETING, NOT FOR THE HERD. A signed piece is
 * signed once. `<BullSprite />` is still the right component for grids, cards,
 * duels and detail pages.
 *
 * ⚠ MARKETING RENDERS DO NOT GO THROUGH THIS FILE. A node script cannot import
 * a `.tsx` (nothing transforms the JSX), so the composite lives in
 * `src/lib/brandTile.ts` with no imports of its own and this is only the canvas
 * around it. A poster script does:
 *
 *     const tile = { width: TILE_W, height: TILE_H, data: renderTile(token) };
 *     const marked = composeWordmarkTile(tile, runs);
 *     writeFileSync(out, encodePng(upscaleNearest(marked, 8)));
 *
 * Compose at tile resolution, then nearest-neighbour the RESULT by a whole
 * number, so the mark takes exactly the share of the tile the site shows
 * (`VOICE-AND-BRAND.md §5`: everything downstream scales by whole pixels only).
 */

/**
 * BNB Chain's gold on exactly the letters `BNB`, bone on the rest — the same
 * split `<Wordmark />` makes in CSS, and the same one the link-preview card
 * makes in `scripts/gen-brand-assets.ts`. Sliced off `SITE_NAME` so the name
 * itself is never typed twice (`brand.ts` owns it, capitals and all).
 */
const GOLD = 'BNB';
const MARK_RUNS: readonly TextRun[] = [
  { text: SITE_NAME.slice(0, GOLD.length), rgb: MARK_GOLD },
  { text: SITE_NAME.slice(GOLD.length), rgb: MARK_BONE },
];

const COMPOSITE_H = brandedTileHeight(TILE_H);
/** Where the tile stops and the plinth starts, as a percentage of the whole. */
const PLINTH_TOP = `${((TILE_H / COMPOSITE_H) * 100).toFixed(4)}%`;

export interface BrandedBullProps {
  token: Token;
  /** Integer pixel scale — nearest-neighbour only, no resample mush. Ignored
   *  when `fluid` is set. */
  scale?: number;
  /**
   * Let CSS own the width instead of pinning it inline, for a hero that has to
   * change size at a breakpoint. Pass the width on `className`.
   *
   * ⚠ SIZE IT IN WHOLE MULTIPLES OF `TILE_W` (71). `image-rendering: pixelated`
   * never blurs, but at a fractional scale it rounds each source pixel to a 3-
   * or 4-device-pixel block depending on where it lands, so the mark's one-pixel
   * strokes come out uneven across the word. At 3x/4x/5x every block is square
   * and identical.
   */
  fluid?: boolean;
  className?: string;
}

export function BrandedBull({ token, scale = 4, fluid = false, className }: BrandedBullProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx) return;
    // `renderTile` hands back a fresh buffer and `composeWordmarkTile` copies
    // it, so nothing shared is written to.
    const marked = composeWordmarkTile(
      { width: TILE_W, height: TILE_H, data: renderTile(token) },
      MARK_RUNS,
    );
    const imageData = ctx.createImageData(marked.width, marked.height);
    imageData.data.set(marked.data);
    ctx.putImageData(imageData, 0, 0);
  }, [token]);

  const s = Math.max(1, Math.floor(scale));
  const cream = `rgb(${token.bg[0]} ${token.bg[1]} ${token.bg[2]})`;
  const dark = `rgb(${PLINTH_RGB[0]} ${PLINTH_RGB[1]} ${PLINTH_RGB[2]})`;

  return (
    // The frame RESERVES the exact box and pre-paints it, because the canvas
    // is filled in an effect: on a cold load there is one frame with nothing
    // drawn, and on the landing page this bull IS the page. The hard-stop
    // gradient puts the plinth exactly where the composite puts it, so the
    // empty plate is the right shape rather than a gold box round a hole.
    <div
      className={className}
      style={{
        aspectRatio: `${TILE_W} / ${COMPOSITE_H}`,
        background: `linear-gradient(to bottom, ${cream} 0% ${PLINTH_TOP}, ${dark} ${PLINTH_TOP} 100%)`,
        ...(fluid ? null : { width: TILE_W * s }),
      }}
    >
      <canvas
        ref={canvasRef}
        width={TILE_W}
        height={COMPOSITE_H}
        role="img"
        aria-label={`${token.name} · bnbull #${token.id} · ${token.band} · ${SITE_NAME}`}
        style={{ imageRendering: 'pixelated', display: 'block', width: '100%', height: 'auto' }}
      />
    </div>
  );
}
