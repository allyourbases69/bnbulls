// minimal png encoder (rgba, no filtering) — node only, zero deps
// lifted verbatim from fighting fefers generator/png.mjs
import { deflateSync } from "node:zlib";

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

export function encodePng(rgba, w, h, scale = 1) {
  const sw = w * scale, sh = h * scale;
  const raw = Buffer.alloc(sh * (1 + sw * 4));
  let o = 0;
  for (let y = 0; y < sh; y++) {
    raw[o++] = 0;
    const sy = Math.floor(y / scale);
    for (let x = 0; x < sw; x++) {
      const si = (sy * w + Math.floor(x / scale)) * 4;
      raw[o++] = rgba[si]; raw[o++] = rgba[si + 1];
      raw[o++] = rgba[si + 2]; raw[o++] = rgba[si + 3];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(sw, 0);
  ihdr.writeUInt32BE(sh, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

export function compose(tiles, cols, tw, th, gap = 2, bg = [245, 242, 235]) {
  const rows = Math.ceil(tiles.length / cols);
  const w = cols * (tw + gap) - gap, h = rows * (th + gap) - gap;
  const out = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < out.length; i += 4) {
    out[i] = bg[0]; out[i + 1] = bg[1]; out[i + 2] = bg[2]; out[i + 3] = 255;
  }
  tiles.forEach((t, i) => {
    const cx = (i % cols) * (tw + gap), cy = Math.floor(i / cols) * (th + gap);
    for (let y = 0; y < th; y++) {
      for (let x = 0; x < tw; x++) {
        const si = (y * tw + x) * 4, di = ((cy + y) * w + cx + x) * 4;
        out[di] = t[si]; out[di + 1] = t[si + 1]; out[di + 2] = t[si + 2]; out[di + 3] = 255;
      }
    }
  });
  return { px: out, w, h };
}
