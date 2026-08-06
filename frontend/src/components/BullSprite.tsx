'use client';

import { useEffect, useRef } from 'react';
import { renderTile, TILE_W, TILE_H, type Token } from '@/lib/art/bull';

interface BullSpriteProps {
  token: Token;
  /** Integer pixel scale — nearest-neighbour only, no resample mush. Ignored
   *  when `fluid` is set. */
  scale?: number;
  /**
   * Let CSS own the size instead of pinning it inline. The canvas keeps its
   * intrinsic TILE_W x TILE_H, `image-rendering: pixelated` still applies, and the
   * caller sizes it with a responsive class (`w-[224px] md:w-[280px]`).
   * Use this for the hero, where the size has to change at a breakpoint;
   * everywhere else the integer `scale` is the right tool because it
   * guarantees whole-pixel blocks.
   */
  fluid?: boolean;
  className?: string;
}

/**
 * Renders a token straight off the art engine to a `<canvas>`, at an integer
 * pixel scale via CSS (`image-rendering: pixelated`) so the sprite stays crisp
 * pixel art at any display size. No image files, no server round trip —
 * `renderTile()` runs in the browser off the same maths as the node build and
 * the marketing renders, so the site can never show a bull the chain does not
 * describe.
 */
export function BullSprite({ token, scale = 4, className, fluid = false }: BullSpriteProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx) return;
    const pixels = renderTile(token);
    const imageData = ctx.createImageData(TILE_W, TILE_H);
    imageData.data.set(pixels);
    ctx.putImageData(imageData, 0, 0);
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
              imageRendering: 'pixelated',
              width: TILE_W * scale,
              height: TILE_H * scale,
              display: 'block',
            }
      }
    />
  );
}
