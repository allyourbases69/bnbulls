// side-by-side: the live fighting fefers 32x44 engine vs the bnbulls 48x56 one.
// both rendered from their own real generators, pasted at identical zoom.
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { encodePng } from "./png.mjs";
import * as bull from "./bull.mjs";

const FEF = "C:/tools/Claude/Fighting_Fefers/generator/core.mjs";
const fef = await import(pathToFileURL(FEF).href);

const PAD = 6, GAP = 10, BG = [233, 235, 240];

// paste an RGBA tile into a sheet at (ox, oy)
function paste(sheet, sw, tile, tw, th, ox, oy) {
  for (let y = 0; y < th; y++) {
    for (let x = 0; x < tw; x++) {
      const si = (y * tw + x) * 4, di = ((oy + y) * sw + ox + x) * 4;
      sheet[di] = tile[si]; sheet[di + 1] = tile[si + 1];
      sheet[di + 2] = tile[si + 2]; sheet[di + 3] = 255;
    }
  }
}

// ---- left: a real fefer at 40x52 tile (32x44 sprite) ----
const fefBands = fef.assignBands();
const fefTok = fef.rollToken(7, fefBands);
const fefTile = fef.renderTile(fefTok);

// ---- right: a bnbull at 56x64 tile (48x56 sprite) ----
// the chain's tier map (`assignBands()` is deleted — see DECISIONS.md §27).
// every trait is overridden below anyway; this is here so the call is legal.
const bullBands = bull.chainBandMap();
const bullTok = bull.rollToken(7, bullBands, {
  band: "uncommon", skin: bull.SKINS.uncommon[0], weapon: "sledge", accessories: ["horncaps"],
});
const bullTile = bull.renderTile(bullTok);

const w = PAD + fef.TILE_W + GAP + bull.TILE_W + PAD;
const h = PAD + Math.max(fef.TILE_H, bull.TILE_H) + PAD;
const sheet = new Uint8ClampedArray(w * h * 4);
for (let i = 0; i < sheet.length; i += 4) {
  sheet[i] = BG[0]; sheet[i + 1] = BG[1]; sheet[i + 2] = BG[2]; sheet[i + 3] = 255;
}
const baseline = PAD + Math.max(fef.TILE_H, bull.TILE_H);
paste(sheet, w, fefTile, fef.TILE_W, fef.TILE_H, PAD, baseline - fef.TILE_H);
paste(sheet, w, bullTile, bull.TILE_W, bull.TILE_H, PAD + fef.TILE_W + GAP, baseline - bull.TILE_H);

writeFileSync("compare.png", encodePng(sheet, w, h, 7));
console.log(`wrote compare.png — fefer ${fef.W}x${fef.H} vs bnbull ${bull.W}x${bull.H}`);
