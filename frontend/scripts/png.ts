// A minimal PNG encoder, plus the two resampling primitives the brand assets
// need. No dependency: `sharp` is not in this package and pulling a native
// image library in just to write a handful of icons would be a bad trade for a
// frontend that ships no images at runtime.
//
// ⚠ THE TWO RESAMPLERS ARE NOT INTERCHANGEABLE, and picking the wrong one is
// how pixel art turns to mush:
//
//   `upscaleNearest` — integer factor ONLY. Every source pixel becomes an
//   exact NxN block of identical pixels. This is the only legal way to make a
//   sprite bigger. `assertUniformBlocks` proves after the fact that it really
//   did that, so a future refactor cannot quietly introduce a smooth filter.
//
//   `downscaleBox` — area average. Used ONLY to work out what a browser will
//   actually put in a 16px tab, so the result can be looked at rather than
//   hoped about. Never used to produce a sprite that gets displayed large.

import { deflateSync } from 'node:zlib';

export interface Bitmap {
  width: number;
  height: number;
  /** RGBA, 4 bytes per pixel, row-major. */
  data: Uint8ClampedArray;
}

export function createBitmap(width: number, height: number, fill: readonly number[]): Bitmap {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    data[i * 4] = fill[0];
    data[i * 4 + 1] = fill[1];
    data[i * 4 + 2] = fill[2];
    data[i * 4 + 3] = fill[3] ?? 255;
  }
  return { width, height, data };
}

export function getPixel(b: Bitmap, x: number, y: number): [number, number, number, number] {
  const o = (y * b.width + x) * 4;
  return [b.data[o], b.data[o + 1], b.data[o + 2], b.data[o + 3]];
}

export function setPixel(b: Bitmap, x: number, y: number, p: readonly number[]): void {
  if (x < 0 || y < 0 || x >= b.width || y >= b.height) return;
  const o = (y * b.width + x) * 4;
  b.data[o] = p[0];
  b.data[o + 1] = p[1];
  b.data[o + 2] = p[2];
  b.data[o + 3] = p[3] ?? 255;
}

/** Copy `src` onto `dst` with its top-left at (dx, dy). Out-of-bounds clipped. */
export function blit(dst: Bitmap, src: Bitmap, dx: number, dy: number): void {
  for (let y = 0; y < src.height; y++) {
    for (let x = 0; x < src.width; x++) {
      setPixel(dst, dx + x, dy + y, getPixel(src, x, y));
    }
  }
}

/** A rectangular window of `src`, clamped at the edges. */
export function crop(src: Bitmap, x0: number, y0: number, w: number, h: number): Bitmap {
  const out = createBitmap(w, h, [0, 0, 0, 0]);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const sx = Math.min(src.width - 1, Math.max(0, x0 + x));
      const sy = Math.min(src.height - 1, Math.max(0, y0 + y));
      setPixel(out, x, y, getPixel(src, sx, sy));
    }
  }
  return out;
}

/**
 * Integer nearest-neighbour upscale. THE ONLY legal way to enlarge a sprite:
 * the pixels stay pixels, no resample mush.
 */
export function upscaleNearest(src: Bitmap, factor: number): Bitmap {
  if (!Number.isInteger(factor) || factor < 1) {
    throw new Error(`upscaleNearest: factor must be a positive integer, got ${factor}`);
  }
  const out = createBitmap(src.width * factor, src.height * factor, [0, 0, 0, 0]);
  for (let y = 0; y < src.height; y++) {
    for (let x = 0; x < src.width; x++) {
      const p = getPixel(src, x, y);
      for (let dy = 0; dy < factor; dy++) {
        for (let dx = 0; dx < factor; dx++) {
          setPixel(out, x * factor + dx, y * factor + dy, p);
        }
      }
    }
  }
  return out;
}

/**
 * Self-audit: every `factor x factor` block must be one solid colour. If it is
 * not, something smoothed the image, and a smooth-scaled sprite next to hard
 * pixel type looks broken. Same check the fefers banner script runs on itself.
 */
export function assertUniformBlocks(b: Bitmap, factor: number, label: string): void {
  for (let by = 0; by < b.height; by += factor) {
    for (let bx = 0; bx < b.width; bx += factor) {
      const first = getPixel(b, bx, by).join(',');
      for (let dy = 0; dy < factor; dy++) {
        for (let dx = 0; dx < factor; dx++) {
          if (getPixel(b, bx + dx, by + dy).join(',') !== first) {
            throw new Error(
              `${label}: block at (${bx},${by}) is not uniform at scale ${factor} — ` +
                'something resampled the art instead of nearest-neighbour scaling it.',
            );
          }
        }
      }
    }
  }
}

/**
 * Area-average downscale to an arbitrary size. Used ONLY to model what a
 * browser will show in a small tab, so the result can be inspected instead of
 * assumed. Handles non-integer ratios correctly by weighting partial coverage.
 */
export function downscaleBox(src: Bitmap, w: number, h: number): Bitmap {
  const out = createBitmap(w, h, [0, 0, 0, 255]);
  const sx = src.width / w;
  const sy = src.height / h;
  for (let y = 0; y < h; y++) {
    const y0 = y * sy;
    const y1 = (y + 1) * sy;
    for (let x = 0; x < w; x++) {
      const x0 = x * sx;
      const x1 = (x + 1) * sx;
      let r = 0,
        g = 0,
        b = 0,
        a = 0,
        wsum = 0;
      for (let py = Math.floor(y0); py < Math.ceil(y1); py++) {
        const covY = Math.min(y1, py + 1) - Math.max(y0, py);
        if (covY <= 0) continue;
        for (let pxx = Math.floor(x0); pxx < Math.ceil(x1); pxx++) {
          const covX = Math.min(x1, pxx + 1) - Math.max(x0, pxx);
          if (covX <= 0) continue;
          const wgt = covX * covY;
          const p = getPixel(src, pxx, py);
          r += p[0] * wgt;
          g += p[1] * wgt;
          b += p[2] * wgt;
          a += p[3] * wgt;
          wsum += wgt;
        }
      }
      setPixel(out, x, y, [
        Math.round(r / wsum),
        Math.round(g / wsum),
        Math.round(b / wsum),
        Math.round(a / wsum),
      ]);
    }
  }
  return out;
}

// ─── PNG container ───────────────────────────────────────────────────

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}

/** 8-bit RGBA PNG. Filter type 0 on every scanline: the images are tiny and a
 *  filter search would buy nothing but a slower script. */
export function encodePng(b: Bitmap): Buffer {
  const raw = Buffer.alloc(b.height * (1 + b.width * 4));
  for (let y = 0; y < b.height; y++) {
    const rowStart = y * (1 + b.width * 4);
    raw[rowStart] = 0;
    for (let x = 0; x < b.width * 4; x++) {
      raw[rowStart + 1 + x] = b.data[y * b.width * 4 + x];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(b.width, 0);
  ihdr.writeUInt32BE(b.height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // colour type: truecolour with alpha
  ihdr[10] = 0; // deflate
  ihdr[11] = 0; // adaptive filtering
  ihdr[12] = 0; // no interlace
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
