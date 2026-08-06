/**
 * gifEncode.ts — animated GIF89a encoder. Zero dependencies, pure TS, runs
 * both in a Next route handler and under node's type-stripping loader.
 *
 * ⚠ PORTED BYTE-FOR-BYTE from Fighting Fefers (`app/frontend/src/lib/
 * gifEncode.ts`). It has no imports and no game knowledge — it takes RGBA
 * frames and emits GIF bytes — so there was nothing in it to retheme, and
 * copying it verbatim is strictly safer than retyping a spec-level encoder.
 * Every comment below is the original author's reasoning; the palette and LZW
 * notes in particular are the expensive lessons and should not be trimmed.
 *
 * WHY GIF AND NOT WEBP/APNG. The replay's first home is a Telegram post, and
 * `sendAnimation` accepts exactly two things: a GIF, or H.264/MPEG-4 without
 * sound. Animated WebP is a STICKER format there (.webm/.tgs), and APNG is not
 * an animation format to Telegram at all — both arrive as a still or get
 * rejected. MP4 would be smaller again but needs ffmpeg on the box, which is a
 * binary dependency this repo does not have and cannot assume on Vercel. X
 * transcodes a GIF to MP4 on upload anyway, and a browser plays one inline
 * with no player chrome. So: GIF, and the frame builder hands us plain RGBA so
 * an MP4 leg can be added later without touching it.
 *
 * The size problem GIF has is a 256-colour palette and no interframe motion
 * compensation. Both are handled:
 *
 *   • Palette. Every frame's colours are collected once. ≤255 distinct (the
 *     usual case — this is pixel art off a fixed palette) and the palette is
 *     EXACT, no dithering, no drift. Past that a median cut runs. One index is
 *     always held back for transparency.
 *
 *   • Interframe. Only the changed bounding box of each frame is written, and
 *     unchanged pixels inside that box are written as the transparent index
 *     over disposal method 1 (leave the previous frame in place). A duel replay
 *     is mostly a static arena with two sprites twitching in it, so this is
 *     the difference between a ~2 MB file and a ~200 KB one.
 *
 * Deliberately NOT here: dithering (pixel art must not shimmer), interlacing
 * (nothing streams these), and local colour tables (one global table is
 * smaller and every frame shares the same art).
 */

/** One frame: RGBA bytes, w*h*4, plus how long it sits on screen. */
export interface GifFrame {
  readonly rgba: Uint8Array | Uint8ClampedArray;
  /** Hold time in MILLISECONDS. Rounded to GIF's 10ms tick on write. */
  readonly delayMs: number;
}

export interface GifOptions {
  readonly width: number;
  readonly height: number;
  /** Integer nearest-neighbour upscale, same contract as generator/png.mjs. */
  readonly scale?: number;
  /** 0 = forever (the default), n = play n times. */
  readonly loops?: number;
  /**
   * Colours that must survive verbatim even when the palette has to be reduced.
   *
   * Median cut weights buckets by how many pixels they cover, which is right for
   * artwork and wrong for interface: a damage number is a few dozen pixels of
   * pure red, so it is exactly the sort of thing that gets folded into whatever
   * large bucket sits nearest and comes out muddy. Reserving the interface
   * palette guarantees text stays the colour it was drawn in, and costs one
   * table slot per colour out of 255.
   */
  readonly reserve?: readonly (readonly [number, number, number])[];
}

/**
 * GIF stores delay in hundredths of a second. Two extra rules that bite:
 * a delay of 0 or 1 is treated as "as fast as possible" by some viewers and
 * silently clamped to 10 by others (notably older browsers), so the floor here
 * is 2 (50fps) and callers who want reliable pacing should stay at 4+.
 */
const toCentis = (ms: number) => Math.max(2, Math.min(65535, Math.round(ms / 10)));

// ── byte sink ─────────────────────────────────────────────────────────
class ByteSink {
  private buf: Uint8Array;
  private len = 0;

  constructor(initial = 1 << 16) {
    this.buf = new Uint8Array(initial);
  }

  private grow(need: number): void {
    if (this.len + need <= this.buf.length) return;
    let next = this.buf.length * 2;
    while (next < this.len + need) next *= 2;
    const bigger = new Uint8Array(next);
    bigger.set(this.buf.subarray(0, this.len));
    this.buf = bigger;
  }

  u8(v: number): void {
    this.grow(1);
    this.buf[this.len++] = v & 0xff;
  }

  /** GIF is little-endian throughout. */
  u16(v: number): void {
    this.grow(2);
    this.buf[this.len++] = v & 0xff;
    this.buf[this.len++] = (v >> 8) & 0xff;
  }

  bytes(v: ArrayLike<number>): void {
    this.grow(v.length);
    for (let i = 0; i < v.length; i++) this.buf[this.len++] = v[i]! & 0xff;
  }

  ascii(s: string): void {
    this.grow(s.length);
    for (let i = 0; i < s.length; i++) this.buf[this.len++] = s.charCodeAt(i) & 0xff;
  }

  take(): Uint8Array {
    return this.buf.subarray(0, this.len);
  }
}

// ── palette ───────────────────────────────────────────────────────────
/** 0xRRGGBB, ignoring alpha: every frame the composer hands us is opaque. */
const keyOf = (r: number, g: number, b: number) => (r << 16) | (g << 8) | b;

interface Palette {
  /** Flat RGB triples, length = size*3. */
  readonly table: Uint8Array;
  /** 0xRRGGBB → index, exact hits only. */
  readonly exact: Map<number, number>;
  readonly size: number;
  /** True when every colour in the animation is in the table verbatim. */
  readonly lossless: boolean;
}

/**
 * Median cut over the distinct colours of the whole animation (not per frame —
 * a per-frame palette would need local colour tables AND would make a static
 * background shimmer as the palette shifted under it).
 *
 * Buckets split on the channel with the widest spread, at the MEDIAN, and each
 * bucket collapses to its population-weighted mean. Weighting the MEAN by pixel
 * count matters: a duel frame is mostly backdrop, and an unweighted mean lets
 * eleven stray highlight pixels drag a bucket off the colour that actually
 * covers the screen.
 *
 * ⚠ THE BOX TO SPLIT IS THE WIDEST, NOT THE HEAVIEST. Classic median cut picks
 * the box with the most pixels in it, which is right when you are crushing
 * thousands of colours down to 256 and want the palette spent where the eye
 * spends its time. This encoder is doing the opposite job: a duel animation has
 * a few hundred colours and needs to lose maybe forty of them. Under
 * heaviest-first, a box full of low-population but far-apart colours never gets
 * split at all, because a big smooth sky gradient always outweighs it — so the
 * handful of rare colours (a rim light, one bright accent in the art) are the
 * ones that collapse, and they are the visible error. Measured on a king vs epic
 * fight (the worst case in the collection — two gradient skies at once):
 * heaviest-first drifted 25 pixels by more than 24/255, widest-first tops out at
 * 13/255 across the whole animation. Widest-first minimises the WORST error,
 * which is what matters when the reduction is small.
 */
function medianCut(counts: Map<number, number>, max: number): Palette {
  interface Box {
    colours: number[];
    weight: number;
    /** Widest channel extent, and the bit shift of that channel. */
    spread: number;
    axis: number;
  }

  const measure = (colours: number[]): { spread: number; axis: number } => {
    let rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0;
    for (const c of colours) {
      const r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
      if (r < rMin) rMin = r;
      if (r > rMax) rMax = r;
      if (g < gMin) gMin = g;
      if (g > gMax) gMax = g;
      if (b < bMin) bMin = b;
      if (b > bMax) bMax = b;
    }
    const dr = rMax - rMin, dg = gMax - gMin, db = bMax - bMin;
    if (dr >= dg && dr >= db) return { spread: dr, axis: 16 };
    if (dg >= db) return { spread: dg, axis: 8 };
    return { spread: db, axis: 0 };
  };
  const weigh = (colours: number[]) => colours.reduce((n, c) => n + counts.get(c)!, 0);
  const makeBox = (colours: number[]): Box => ({ colours, weight: weigh(colours), ...measure(colours) });

  const all = [...counts.keys()];
  // Mutated in place by splice below, never reassigned.
  const boxes: Box[] = [makeBox(all)];

  while (boxes.length < max) {
    let target = -1;
    let bestSpread = -1;
    let bestWeight = -1;
    for (let i = 0; i < boxes.length; i++) {
      const b = boxes[i]!;
      if (b.colours.length < 2) continue;
      // Widest first; pixel count only breaks ties.
      if (b.spread > bestSpread || (b.spread === bestSpread && b.weight > bestWeight)) {
        bestSpread = b.spread;
        bestWeight = b.weight;
        target = i;
      }
    }
    // Every box is a single colour, or every remaining box has zero extent
    // (duplicate colours cannot happen, so this means we are done).
    if (target < 0 || bestSpread <= 0) break;

    const box = boxes[target]!;
    box.colours.sort((x, y) => ((x >> box.axis) & 0xff) - ((y >> box.axis) & 0xff));
    const mid = box.colours.length >> 1;
    boxes.splice(target, 1, makeBox(box.colours.slice(0, mid)), makeBox(box.colours.slice(mid)));
  }

  const table = new Uint8Array(boxes.length * 3);
  const exact = new Map<number, number>();
  boxes.forEach((box, i) => {
    let r = 0, g = 0, b = 0, n = 0;
    for (const c of box.colours) {
      const w = counts.get(c)!;
      r += ((c >> 16) & 0xff) * w;
      g += ((c >> 8) & 0xff) * w;
      b += (c & 0xff) * w;
      n += w;
    }
    table[i * 3] = Math.round(r / n);
    table[i * 3 + 1] = Math.round(g / n);
    table[i * 3 + 2] = Math.round(b / n);
    // A single-colour bucket IS that colour, so it can still be matched
    // exactly and skip the nearest-neighbour search below.
    if (box.colours.length === 1) exact.set(box.colours[0]!, i);
  });

  return { table, exact, size: boxes.length, lossless: false };
}

function buildPalette(
  frames: readonly GifFrame[],
  max: number,
  reserve: readonly (readonly [number, number, number])[] = [],
): Palette {
  const counts = new Map<number, number>();
  for (const f of frames) {
    const px = f.rgba;
    for (let i = 0; i < px.length; i += 4) {
      const k = keyOf(px[i]!, px[i + 1]!, px[i + 2]!);
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
  }

  if (counts.size <= max) {
    const table = new Uint8Array(counts.size * 3);
    const exact = new Map<number, number>();
    let i = 0;
    for (const k of counts.keys()) {
      table[i * 3] = (k >> 16) & 0xff;
      table[i * 3 + 1] = (k >> 8) & 0xff;
      table[i * 3 + 2] = k & 0xff;
      exact.set(k, i);
      i++;
    }
    return { table, exact, size: counts.size, lossless: true };
  }

  // Over budget. Pin the reserved colours first, then median-cut everything
  // else into whatever slots are left. Reserved colours are removed from the
  // cut's input so their (small) pixel counts cannot skew a bucket either.
  const pinned: number[] = [];
  for (const [r, g, b] of reserve) {
    const k = keyOf(r, g, b);
    if (!pinned.includes(k)) pinned.push(k);
  }
  if (!pinned.length) return medianCut(counts, max);

  const rest = new Map(counts);
  for (const k of pinned) rest.delete(k);

  const slots = Math.max(1, max - pinned.length);
  const cut: Palette = rest.size
    ? medianCut(rest, slots)
    : { table: new Uint8Array(0), exact: new Map(), size: 0, lossless: false };

  const size = pinned.length + cut.size;
  const table = new Uint8Array(size * 3);
  const exact = new Map<number, number>();
  pinned.forEach((k, i) => {
    table[i * 3] = (k >> 16) & 0xff;
    table[i * 3 + 1] = (k >> 8) & 0xff;
    table[i * 3 + 2] = k & 0xff;
    exact.set(k, i);
  });
  table.set(cut.table.subarray(0, cut.size * 3), pinned.length * 3);
  // Re-home the cut's single-colour exact hits behind the reserved block.
  for (const [k, i] of cut.exact) exact.set(k, i + pinned.length);
  return { table, exact, size, lossless: false };
}

/** Nearest entry by squared RGB distance. Memoised via `exact`. */
function indexOf(pal: Palette, r: number, g: number, b: number): number {
  const k = keyOf(r, g, b);
  const hit = pal.exact.get(k);
  if (hit !== undefined) return hit;
  let best = 0;
  let bestD = Infinity;
  for (let i = 0; i < pal.size; i++) {
    const dr = r - pal.table[i * 3]!;
    const dg = g - pal.table[i * 3 + 1]!;
    const db = b - pal.table[i * 3 + 2]!;
    const d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  pal.exact.set(k, best);
  return best;
}

// ── LZW ───────────────────────────────────────────────────────────────
/**
 * GIF's variable-width LZW. Codes start at minCodeSize+1 bits and widen as the
 * dictionary fills; at 4096 entries a CLEAR is emitted and the dictionary
 * restarts. Output is packed LSB-first into 255-byte sub-blocks.
 *
 * The dictionary is a Map keyed by (prefix<<8)|next rather than a trie — a
 * duel frame is a few thousand pixels, so the constant factor is irrelevant
 * next to keeping this readable enough to audit against the spec.
 */
function lzwCompress(indices: Uint8Array, minCodeSize: number): Uint8Array {
  const clear = 1 << minCodeSize;
  const eoi = clear + 1;

  const out = new ByteSink(indices.length + 64);
  let block: number[] = [];
  let bitBuf = 0;
  let bitCount = 0;

  const flushBlock = () => {
    if (!block.length) return;
    out.u8(block.length);
    out.bytes(block);
    block = [];
  };
  const emit = (code: number, width: number) => {
    bitBuf |= code << bitCount;
    bitCount += width;
    while (bitCount >= 8) {
      block.push(bitBuf & 0xff);
      bitBuf >>= 8;
      bitCount -= 8;
      if (block.length === 255) flushBlock();
    }
  };

  let dict = new Map<number, number>();
  let next = eoi + 1;
  let width = minCodeSize + 1;

  out.u8(minCodeSize);
  emit(clear, width);

  let prefix = indices.length ? indices[0]! : -1;
  for (let i = 1; i < indices.length; i++) {
    const c = indices[i]!;
    const key = (prefix << 8) | c;
    const found = dict.get(key);
    if (found !== undefined) {
      prefix = found;
      continue;
    }
    emit(prefix, width);
    if (next < 4096) {
      dict.set(key, next);
      // Widen only AFTER the code that filled the previous width is out.
      if (next === 1 << width && width < 12) width += 1;
      next += 1;
    } else {
      emit(clear, width);
      dict = new Map();
      next = eoi + 1;
      width = minCodeSize + 1;
    }
    prefix = c;
  }
  if (prefix >= 0) emit(prefix, width);
  emit(eoi, width);

  if (bitCount > 0) {
    block.push(bitBuf & 0xff);
    if (block.length === 255) flushBlock();
  }
  flushBlock();
  out.u8(0); // block terminator
  return out.take();
}

// ── frame quantise + diff ─────────────────────────────────────────────
interface Quantised {
  readonly indices: Uint8Array;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  readonly usesTransparency: boolean;
}

/**
 * RGBA → palette indices for the sub-rectangle that actually changed since
 * `prev`. Unchanged pixels inside the rectangle become `transparentIndex`,
 * which under disposal 1 means "keep what is already there".
 *
 * `prev` is compared in PALETTE space, not RGB space: after quantisation two
 * different source colours can land on the same index, and a pixel whose index
 * did not change must not be redrawn just because its float RGB wobbled.
 */
function quantiseFrame(
  rgba: Uint8Array | Uint8ClampedArray,
  prev: Uint8Array | null,
  pal: Palette,
  width: number,
  height: number,
  transparentIndex: number,
): { full: Uint8Array; frame: Quantised } {
  const full = new Uint8Array(width * height);
  for (let i = 0, p = 0; p < full.length; i += 4, p++) {
    full[p] = indexOf(pal, rgba[i]!, rgba[i + 1]!, rgba[i + 2]!);
  }

  if (!prev) {
    return {
      full,
      frame: { indices: full, x: 0, y: 0, w: width, h: height, usesTransparency: false },
    };
  }

  let minX = width, minY = height, maxX = -1, maxY = -1;
  for (let y = 0; y < height; y++) {
    const row = y * width;
    for (let x = 0; x < width; x++) {
      if (full[row + x] === prev[row + x]) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  // Nothing moved. A 1x1 transparent patch is the cheapest legal frame and
  // keeps the delay (i.e. the pause) without re-sending the picture.
  if (maxX < 0) {
    return {
      full,
      frame: {
        indices: new Uint8Array([transparentIndex]),
        x: 0, y: 0, w: 1, h: 1,
        usesTransparency: true,
      },
    };
  }

  const w = maxX - minX + 1;
  const h = maxY - minY + 1;
  const indices = new Uint8Array(w * h);
  let usesTransparency = false;
  for (let y = 0; y < h; y++) {
    const src = (minY + y) * width + minX;
    const dst = y * w;
    for (let x = 0; x < w; x++) {
      const cur = full[src + x]!;
      if (cur === prev[src + x]) {
        indices[dst + x] = transparentIndex;
        usesTransparency = true;
      } else {
        indices[dst + x] = cur;
      }
    }
  }
  return { full, frame: { indices, x: minX, y: minY, w, h, usesTransparency } };
}

/**
 * Nearest-neighbour integer upscale of a PALETTE-INDEX block.
 *
 * Upscaling indices rather than RGBA is the whole reason this encoder is fast
 * enough to run inside a request: quantisation is the expensive step (a map
 * lookup per pixel), and doing it at logical resolution instead of output
 * resolution is a scale² saving — at scale 4 that is 16x fewer lookups. The
 * result is bit-identical because a nearest-neighbour upscale introduces no
 * new colours, so the palette and every pixel's index are unchanged.
 */
function upscaleIndices(src: Uint8Array, w: number, h: number, scale: number): Uint8Array {
  if (scale === 1) return src;
  const sw = w * scale;
  const out = new Uint8Array(sw * h * scale);
  for (let y = 0; y < h; y++) {
    const rowStart = y * scale * sw;
    // Build one output row, then copy it `scale` times.
    for (let x = 0; x < w; x++) {
      const v = src[y * w + x]!;
      const at = rowStart + x * scale;
      for (let k = 0; k < scale; k++) out[at + k] = v;
    }
    const row = out.subarray(rowStart, rowStart + sw);
    for (let k = 1; k < scale; k++) out.set(row, rowStart + k * sw);
  }
  return out;
}

// ── the encoder ───────────────────────────────────────────────────────
/**
 * Frames → GIF89a bytes.
 *
 * Throws only on an empty frame list or a frame of the wrong length: both are
 * programming errors in the composer, and a silently short GIF is worse than a
 * caller that has to handle a throw.
 */
export function encodeGif(frames: readonly GifFrame[], opts: GifOptions): Uint8Array {
  const { width, height } = opts;
  const scale = Math.max(1, Math.floor(opts.scale ?? 1));
  const loops = Math.max(0, Math.floor(opts.loops ?? 0));

  if (!frames.length) throw new Error('encodeGif: no frames');
  const expect = width * height * 4;
  frames.forEach((f, i) => {
    if (f.rgba.length !== expect) {
      throw new Error(`encodeGif: frame ${i} is ${f.rgba.length} bytes, expected ${expect} (${width}x${height} rgba)`);
    }
  });

  const outW = width * scale;
  const outH = height * scale;

  // 255, not 256: one index is held for transparency so interframe diffing has
  // something to say "unchanged" with.
  const pal = buildPalette(frames, 255, opts.reserve ?? []);
  const transparentIndex = pal.size;
  const tableEntries = Math.max(2, 1 << Math.ceil(Math.log2(Math.max(2, pal.size + 1))));
  const colourBits = Math.log2(tableEntries);

  const out = new ByteSink(1 << 18);
  out.ascii('GIF89a');
  // Logical screen descriptor.
  out.u16(outW);
  out.u16(outH);
  out.u8(0x80 | (colourBits - 1)); // global table present, its size
  out.u8(0); // background colour index
  out.u8(0); // pixel aspect ratio: none
  // Global colour table, padded out to the power of two the header claims.
  const table = new Uint8Array(tableEntries * 3);
  table.set(pal.table.subarray(0, pal.size * 3));
  out.bytes(table);

  // NETSCAPE2.0 loop block. Must come before the first frame.
  out.u8(0x21);
  out.u8(0xff);
  out.u8(11);
  out.ascii('NETSCAPE2.0');
  out.u8(3);
  out.u8(1);
  out.u16(loops);
  out.u8(0);

  const minCodeSize = Math.max(2, colourBits);
  let prev: Uint8Array | null = null;

  for (const f of frames) {
    // Quantise and diff at LOGICAL size, then blow the changed block up. The
    // rectangle scales exactly because `scale` is an integer.
    const { full, frame } = quantiseFrame(f.rgba, prev, pal, width, height, transparentIndex);
    prev = full;
    const indices = upscaleIndices(frame.indices, frame.w, frame.h, scale);

    // Graphic control extension: disposal 1 (leave in place) so a
    // transparent-diffed frame composites onto what came before.
    out.u8(0x21);
    out.u8(0xf9);
    out.u8(4);
    out.u8((1 << 2) | (frame.usesTransparency ? 1 : 0));
    out.u16(toCentis(f.delayMs));
    out.u8(frame.usesTransparency ? transparentIndex : 0);
    out.u8(0);

    // Image descriptor for the changed rectangle only.
    out.u8(0x2c);
    out.u16(frame.x * scale);
    out.u16(frame.y * scale);
    out.u16(frame.w * scale);
    out.u16(frame.h * scale);
    out.u8(0); // no local table, not interlaced
    out.bytes(lzwCompress(indices, minCodeSize));
  }

  out.u8(0x3b); // trailer
  return out.take();
}

/** Whether the animation's colours survived verbatim. Diagnostics only. */
export function paletteIsLossless(frames: readonly GifFrame[]): boolean {
  const seen = new Set<number>();
  for (const f of frames) {
    for (let i = 0; i < f.rgba.length; i += 4) {
      seen.add(keyOf(f.rgba[i]!, f.rgba[i + 1]!, f.rgba[i + 2]!));
      if (seen.size > 255) return false;
    }
  }
  return true;
}
