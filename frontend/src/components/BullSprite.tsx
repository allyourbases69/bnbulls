'use client';

import { useEffect, useRef } from 'react';
import { renderTile, TILE_W, TILE_H, type Token } from '@/lib/art/bull';

interface BullSpriteProps {
  token: Token;
  /** Requested display width, as an integer multiple of the tile (CSS pixels =
   *  `TILE_W * scale`). The canvas may still be clamped narrower by its column
   *  (`maxWidth: 100%`) — the backing store below adapts so the clamp never
   *  costs pixel fidelity. Ignored when `fluid` is set. */
  scale?: number;
  /**
   * Let CSS own the size instead of pinning it inline: the caller sizes the
   * canvas with a responsive class or a sized parent, and the sprite fills it
   * (`width: 100%`). Use this wherever the width is decided by layout — the
   * duel arena, grid cards, table thumbnails.
   */
  fluid?: boolean;
  className?: string;
}

/**
 * Renders a token straight off the art engine to a `<canvas>`. No image files,
 * no server round trip — `renderTile()` runs in the browser off the same maths
 * as the node build and the marketing renders, so the site can never show a
 * bull the chain does not describe.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ HOW THE SPRITE STAYS CRISP AT *ANY* DISPLAY SIZE — READ BEFORE TOUCHING
 * ═══════════════════════════════════════════════════════════════════════
 * The old scheme kept the canvas at its native 71×64 and let CSS blow it up
 * with `image-rendering: pixelated`. That is only clean when the displayed
 * size is a WHOLE multiple of the tile in DEVICE pixels. At any fractional
 * multiple, `pixelated` (which IS nearest-neighbour) gives some art pixels
 * 3 device pixels and their neighbours 4 — and the 1px features (eyes,
 * nostrils, the mouth line) come out visibly uneven or half-missing. That was
 * the "face all messed up" bug in the duel arena (portraits are sized by a
 * `min()/clamp()` expression, essentially never an integer multiple) and in
 * the post-mint reveal (the `maxWidth: 100%` containment clamp squeezes a
 * 284px request into a ~198px column: 2.79×).
 *
 * The fix, per rendered size, measured with a ResizeObserver:
 *
 *   1. If the displayed width IS a whole multiple of `TILE_W` in device
 *      pixels (the browse grid at scale 3 on a 1x/2x screen, the hero's
 *      213/284/355 ladder): keep the native-resolution canvas and
 *      `pixelated` — bit-exact, and no extra memory across a 500-card grid.
 *
 *   2. Otherwise: repaint the canvas backing store at the SMALLEST integer
 *      scale that covers the displayed device size (nearest-neighbour, whole
 *      blocks, done in the 2d context), and let the browser's default SMOOTH
 *      filtering take it the final ≤1× step down. Every art pixel then lands
 *      within one device pixel of its ideal footprint — the artifacts fall
 *      below visibility instead of landing on the face.
 *
 * `globals.css` forces `pixelated` on every `canvas`; the inline
 * `imageRendering` set here per-mode wins over that rule, which is what lets
 * case 2 opt back into smooth filtering for the final downscale only. The NN
 * crispness in case 2 comes from the integer pre-scale, not from CSS.
 */

/** Ceiling on the oversampled backing store (71×16 = 1136px wide, ~4.5MB
 *  RGBA). Only approached by the duel portraits on a 3x phone; grid cards and
 *  thumbnails measure out at 1–6. */
const MAX_BACKING_SCALE = 16;

/** How close (in art-pixel multiples) the displayed size must be to a whole
 *  multiple before the native `pixelated` path is trusted with it. 0.02 of a
 *  multiple is under 1.5 device pixels across the whole tile — at worst one
 *  column in the margin runs a pixel narrow. */
const INTEGER_TOLERANCE = 0.02;

export function BullSprite({ token, scale = 4, className, fluid = false }: BullSpriteProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    // The tile, rasterised once per token at native resolution. Redraws on
    // resize are then a single `drawImage`, not a re-render of the art.
    const tile = document.createElement('canvas');
    tile.width = TILE_W;
    tile.height = TILE_H;
    const tileCtx = tile.getContext('2d');
    if (!tileCtx) return;
    const imageData = tileCtx.createImageData(TILE_W, TILE_H);
    imageData.data.set(renderTile(token));
    tileCtx.putImageData(imageData, 0, 0);

    // 0 = the native `pixelated` path; k ≥ 1 = oversampled backing at k×.
    let drawnMode = -1;

    const draw = () => {
      // `clientWidth`, not `getBoundingClientRect()`: the rect reflects CSS
      // transforms (`.bull-card` animates one on hover) and would re-derive a
      // different scale mid-animation; the layout width is the stable answer.
      const cssW = canvas.clientWidth;
      if (!cssW) return; // hidden or not laid out yet — the observer will call back
      const need = (cssW * (window.devicePixelRatio || 1)) / TILE_W;
      const nearest = Math.round(need);
      const isWhole = nearest >= 1 && Math.abs(need - nearest) <= INTEGER_TOLERANCE;
      const mode = isWhole
        ? 0
        : Math.min(MAX_BACKING_SCALE, Math.max(1, Math.ceil(need)));
      if (mode === drawnMode) return;
      drawnMode = mode;

      const k = mode === 0 ? 1 : mode;
      // ⚠ Assigning width/height wipes the bitmap AND resets context state,
      // so `imageSmoothingEnabled` must be set after, every time.
      canvas.width = TILE_W * k;
      canvas.height = TILE_H * k;
      canvas.style.imageRendering = mode === 0 ? 'pixelated' : 'auto';
      const ctx = canvas.getContext('2d');
      if (!ctx) return;
      ctx.imageSmoothingEnabled = false; // the integer pre-scale is NN, always
      ctx.drawImage(tile, 0, 0, canvas.width, canvas.height);
    };

    draw();
    const ro = new ResizeObserver(draw);
    ro.observe(canvas);
    // Browser zoom changes `devicePixelRatio` WITHOUT changing the element's
    // CSS size, so the observer alone would miss it. Zoom always fires a
    // window resize.
    window.addEventListener('resize', draw);
    return () => {
      ro.disconnect();
      window.removeEventListener('resize', draw);
    };
  }, [token]);

  return (
    <canvas
      ref={canvasRef}
      width={TILE_W}
      height={TILE_H}
      role="img"
      aria-label={`${token.name} · bnbull #${token.id} · ${token.band}`}
      className={className}
      style={
        fluid
          ? { imageRendering: 'pixelated', display: 'block', width: '100%', height: 'auto' }
          : {
              // ⚠ `maxWidth` + `height: auto` are the containment fix: the
              // fixed `TILE_W * scale` width used to be honoured even when the
              // card was narrower (the post-mint single reveal caps its column
              // at 14rem, scale 4 wants 284px), so the canvas spilled past the
              // panel edge and under the stats block. Clamped, it fills the
              // card and the intrinsic width/height attrs keep the ratio.
              // Pixel fidelity under the clamp is the effect's job (above),
              // NOT a reason to remove this.
              imageRendering: 'pixelated',
              width: TILE_W * scale,
              maxWidth: '100%',
              height: 'auto',
              display: 'block',
            }
      }
    />
  );
}
