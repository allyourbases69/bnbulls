/**
 * duelReplay.ts — turns a settled fight into an animation, server-side.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ONE RENDERER, TWO CONSUMERS
 * ═══════════════════════════════════════════════════════════════════════
 * `BNBULLS-BOOTSTRAP.md §5` is explicit that the on-site replay and the
 * Telegram card come from ONE route, because two renderers drift. This is that
 * renderer. The Telegram bot fetches `/api/duel-gif` rather than drawing
 * locally, and the site embeds the same URL.
 *
 * ⚠ WHAT IS AND IS NOT REPRODUCED. The event list is the whole truth of a
 * fight, and every number here — hp, damage, crits, rounds, winner — comes
 * straight off it. Nothing is re-derived, guessed or smoothed. What is drawn on
 * top is presentation only: an arena, hp bars, damage floaters, a crit flash,
 * a hit shake, and a result card.
 *
 * ⚠ HOW THIS DIFFERS FROM THE FEFERS RENDERER, AND WHY. The fefers version
 * (`lib/duelReplay.ts`) is a 900-line compositor built around a 40x52 SVG
 * sprite, an SVG rasteriser and a bonded-baby overlay. Two of those three do
 * not exist here: the bnbulls art engine emits RGBA directly (`renderTile`, no
 * SVG step) at a tile far larger than 40x52, so EVERY layout constant in that
 * file is wrong for this sprite. Porting the numbers verbatim would have
 * produced two overlapping bulls. So the layout below is re-derived for the
 * real tile size and the effect list is the subset that survives at this
 * resolution. The GIF ENCODER and the PIXEL FONT underneath are byte-for-byte
 * ports; this layer is the one that had to move.
 *
 * ⚠ THE TILE GOT BIGGER AGAIN (56x64 -> 71x64) when the bull was centred in
 * its frame. Nothing here needed editing, because every constant below is
 * derived from the imported `TILE_W`/`TILE_H` rather than copied — which is
 * exactly why they are imported. The two facts that matter are re-checked in
 * the layout block.
 *
 * ⚠ THE ART IS NOT TOUCHED. Sprites come from `lib/art/bull.ts` via
 * `renderTile`, which `npm run verify:art` proves byte-identical to
 * `generator/bull.mjs`. This module reads that output and never reaches into
 * the engine.
 *
 * Everything is drawn at 200x150 LOGICAL pixels and integer-scaled on encode,
 * so the output is pixel-exact at any size and the palette never grows from
 * resampling. See gifEncode.ts for why that matters.
 */
import type { CombatEvent } from '@/core/types';
import { getBull } from '@/lib/art/collection';
import { renderTile, TILE_W, TILE_H, type Band } from '@/lib/art/bull';
import { drawText, textWidth, GLYPH_H } from '@/lib/pixelFont';
import { encodeGif, type GifFrame } from '@/lib/gifEncode';

type RGB = readonly [number, number, number];

// ── palette ───────────────────────────────────────────────────────────
// The site's own theme (tailwind.config.ts) plus a drawn arena. Kept as a fixed
// set because every distinct colour costs one of 255 global-colour-table slots,
// shared with two full bull tiles.
const C = {
  bg: [20, 18, 15] as RGB, // bull-bg #14120F
  panel: [29, 26, 22] as RGB, // bull-panel #1D1A16
  border: [51, 45, 36] as RGB, // bull-border #332D24
  text: [240, 234, 224] as RGB, // bull-text #F0EAE0
  dim: [176, 167, 147] as RGB, // bull-text-dim #B0A793
  faint: [110, 102, 86] as RGB, // bull-text-faint #6E6656
  gold: [240, 185, 11] as RGB, // bull-gold #F0B90B — BNB gold
  goldLit: [255, 206, 59] as RGB, // bull-gold-hover
  red: [193, 62, 62] as RGB, // bull-red
  blood: [138, 44, 44] as RGB, // bull-blood
  green: [110, 156, 92] as RGB, // rarity-rare, doubling as "healthy"
  amber: [196, 105, 58] as RGB, // rarity-uncommon, doubling as "hurt"
  white: [255, 255, 255] as RGB,
  // The arena: a walled yard at dusk. Flat rects only — an alpha wash over a
  // gradient invents a colour per band per layer and the palette cannot afford it.
  sky1: [24, 21, 18] as RGB,
  sky2: [33, 29, 24] as RGB,
  sky3: [43, 37, 30] as RGB,
  sky4: [54, 46, 36] as RGB,
  wall: [40, 35, 29] as RGB,
  wallLit: [62, 55, 44] as RGB,
  wallDark: [26, 23, 19] as RGB,
  post: [58, 50, 39] as RGB,
  postLit: [84, 74, 58] as RGB,
  ground: [58, 50, 38] as RGB,
  groundLit: [78, 68, 51] as RGB,
  groundEdge: [98, 86, 63] as RGB,
  lampGlow: [72, 62, 40] as RGB,
  lampCore: [255, 226, 140] as RGB,
  vignette: [12, 11, 9] as RGB,
  bolt: [255, 248, 200] as RGB,
} as const;

/** Tier ink, matching `tailwind.config.ts`'s `rarity-*` so a bull is the same
 *  colour here as it is on the site. Three PRECOMPUTED darkenings stand in for
 *  the CSS bloom the site uses: a real falloff would be an alpha gradient and
 *  every step of it a new palette entry. */
const TIER_INK: Record<Band, { edge: RGB; halo: RGB }> = {
  common: { edge: [156, 146, 132], halo: [72, 68, 61] },
  uncommon: { edge: [196, 105, 58], halo: [90, 48, 27] },
  rare: { edge: [110, 156, 92], halo: [51, 72, 42] },
  epic: { edge: [136, 146, 168], halo: [63, 67, 77] },
  legendary: { edge: [240, 185, 11], halo: [110, 85, 5] },
};

// ── layout ────────────────────────────────────────────────────────────
// Derived from the REAL tile the art engine emits. `TILE_W`/`TILE_H` are
// imported rather than copied so a canvas change in the art engine breaks the
// build here instead of silently overlapping the two bulls.
const W = 200;
const H = 150;
/** Header strip: wordmark and round counter. */
const HEADER_H = 12;
/** Where the ground starts. The bulls stand ON that line, not above it. */
const FLOOR_Y = 96;
const ARENA_BOTTOM = 120;
const TILE_Y = FLOOR_Y - TILE_H;
const A_X = 14;
const B_X = W - 14 - TILE_W;
const GAP_CX = (A_X + TILE_W + B_X) / 2;
/**
 * ⚠ THE TWO BULLS MUST NOT MEET. This is the failure that has already happened
 * once on this project — two overlapping bulls — and it is silent, because a
 * GIF renders happily either way. A tile is `TILE_W` wide and the attacker
 * lunges up to 7px with 2px of shake on top, so the inner edges can close by 9.
 * Asserted rather than eyeballed: the art engine's canvas is allowed to grow
 * again, and this is what will stop it growing past what the arena can hold.
 */
const MAX_CLOSE = 9;
if (B_X < A_X + TILE_W + MAX_CLOSE) {
  throw new Error(
    `duelReplay: a ${TILE_W}px tile leaves only ${B_X - A_X - TILE_W}px between the two bulls, ` +
      `and they close by up to ${MAX_CLOSE}px. Widen the arena or narrow the sprite.`,
  );
}
const NAME_Y = 124;
const BAR_W = 72;
const BAR_H = 6;
const BAR_Y = 133;
const BAR_A_X = 8;
const BAR_B_X = W - 8 - BAR_W;
const STAT_Y = 142;

// ── pacing ────────────────────────────────────────────────────────────
// GIF stores delay in hundredths of a second, so the frame clock is coarse:
// 80ms is 8 ticks (12.5fps), the slowest that still reads as motion and the
// fastest that does not bloat the file. A fixed TOTAL budget with a derived
// per-event beat, because the event count swings from ~6 to ~150 and a fixed
// beat would make a slugfest run for a minute.
const BEAT_MS = 80;
const EVENT_BUDGET_MS = 4400;
const MIN_FRAMES_PER_EVENT = 1;
const MAX_FRAMES_PER_EVENT = 5;
/** The last frame holds so the result can be read before the loop restarts. */
const RESULT_HOLD_MS = 2200;

export interface ReplayFighter {
  readonly tokenId: number;
  /** Display name. Truncated to fit; never used for logic. */
  readonly name: string;
  readonly weaponName: string;
  readonly tier: Band;
  /** `startingHp(stats, level)` as of the fight. Drives the bars. */
  readonly maxHp: number;
}

export interface ReplayInput {
  readonly a: ReplayFighter;
  readonly b: ReplayFighter;
  readonly events: readonly CombatEvent[];
  /** null = draw. Must agree with the event list's `fight_end`. */
  readonly winnerId: number | null;
  readonly rounds: number;
}

// ── canvas ────────────────────────────────────────────────────────────
class Canvas {
  readonly px: Uint8Array;
  readonly w: number;
  readonly h: number;

  // ⚠ Deliberately NOT a TypeScript parameter property (`constructor(readonly
  // w: number, ...)`). Node's strip-only type loader rejects those outright
  // (`ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`), and keeping this module loadable
  // under `node file.ts` is what lets it be smoke-tested — and, later, borrowed
  // by a keeper script — without a build step.
  constructor(w: number, h: number) {
    this.w = w;
    this.h = h;
    this.px = new Uint8Array(w * h * 4);
    for (let i = 3; i < this.px.length; i += 4) this.px[i] = 255;
  }

  fill(c: RGB): void {
    for (let i = 0; i < this.px.length; i += 4) {
      this.px[i] = c[0];
      this.px[i + 1] = c[1];
      this.px[i + 2] = c[2];
    }
  }

  set(x: number, y: number, c: RGB): void {
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    const i = (y * this.w + x) * 4;
    this.px[i] = c[0];
    this.px[i + 1] = c[1];
    this.px[i + 2] = c[2];
  }

  rect(x: number, y: number, w: number, h: number, c: RGB): void {
    for (let yy = y; yy < y + h; yy++) {
      for (let xx = x; xx < x + w; xx++) this.set(xx, yy, c);
    }
  }

  /** One-pixel outline, drawn inside the given box. */
  frame(x: number, y: number, w: number, h: number, c: RGB): void {
    this.rect(x, y, w, 1, c);
    this.rect(x, y + h - 1, w, 1, c);
    this.rect(x, y, 1, h, c);
    this.rect(x + w - 1, y, 1, h, c);
  }

  /**
   * Copy an opaque tile in, optionally mirrored so B faces A.
   *
   * `keyColour` is the tile's flat backdrop. `renderTile` paints a solid
   * band-coloured background behind the sprite, which would paste a coloured
   * box over the arena — so the backdrop and floor colours are keyed out and
   * only the bull itself lands. This is why the tile's `bg`/`floor` are read
   * from the token rather than assumed.
   */
  blitKeyed(
    src: Uint8ClampedArray,
    sw: number,
    sh: number,
    dx: number,
    dy: number,
    keys: readonly RGB[],
    flip: boolean,
  ): void {
    for (let y = 0; y < sh; y++) {
      const ty = dy + y;
      if (ty < 0 || ty >= this.h) continue;
      for (let x = 0; x < sw; x++) {
        const si = (y * sw + x) * 4;
        const r = src[si]!;
        const g = src[si + 1]!;
        const b = src[si + 2]!;
        let keyed = false;
        for (const k of keys) {
          if (r === k[0] && g === k[1] && b === k[2]) {
            keyed = true;
            break;
          }
        }
        if (keyed) continue;
        const tx = dx + (flip ? sw - 1 - x : x);
        if (tx < 0 || tx >= this.w) continue;
        const di = (ty * this.w + tx) * 4;
        this.px[di] = r;
        this.px[di + 1] = g;
        this.px[di + 2] = b;
      }
    }
  }

  text(s: string, x: number, y: number, c: RGB, scale = 1): void {
    drawText({ set: (px, py) => this.set(px, py, c) }, s, x, y, scale);
  }

  textCentred(s: string, cx: number, y: number, c: RGB, scale = 1): void {
    this.text(s, Math.round(cx - textWidth(s, scale) / 2), y, c, scale);
  }

  /**
   * Centred text on a dark chip. Damage numbers land ON TOP of a bull — busy
   * pixel art with its own highlights — and three-pixel glyphs simply disappear
   * against it. A padded plate is the cheapest fix that costs no extra palette
   * entries.
   */
  chipCentred(s: string, cx: number, y: number, c: RGB, scale = 1): void {
    const w = textWidth(s, scale);
    const x = Math.round(cx - w / 2);
    this.rect(x - 2, y - 2, w + 4, GLYPH_H * scale + 4, C.bg);
    this.frame(x - 2, y - 2, w + 4, GLYPH_H * scale + 4, c);
    this.text(s, x, y, c, scale);
  }

  snapshot(): Uint8Array {
    return this.px.slice();
  }
}

// ── the arena ─────────────────────────────────────────────────────────
/**
 * The scene the fight happens in, drawn once and reused for every frame.
 *
 * Every shape is a flat rect, so it costs about twenty palette entries and
 * compresses almost to nothing — which matters, because this is the part of the
 * frame that never changes and therefore never gets re-sent after frame one
 * (gifEncode diffs frames and writes only the changed rectangle).
 */
function paintArena(): Canvas {
  const cv = new Canvas(W, H);
  cv.fill(C.bg);

  // Sky, four bands, darkest at the top.
  const bands: readonly [RGB, number][] = [
    [C.sky1, HEADER_H + 14],
    [C.sky2, HEADER_H + 32],
    [C.sky3, HEADER_H + 52],
    [C.sky4, FLOOR_Y],
  ];
  let top = HEADER_H;
  for (const [colour, until] of bands) {
    if (until > top) cv.rect(0, top, W, until - top, colour);
    top = until;
  }

  // A stock wall across the back: dark panels with a lit top rail, so the upper
  // half reads as somewhere enclosed rather than as empty sky. Sits BEHIND the
  // bulls, who are 14px in from either edge.
  const WALL_TOP = HEADER_H + 4;
  const WALL_H = 26;
  cv.rect(0, WALL_TOP, W, WALL_H, C.wall);
  cv.rect(0, WALL_TOP, W, 1, C.wallLit);
  cv.rect(0, WALL_TOP + WALL_H - 1, W, 1, C.wallDark);
  for (let x = 6; x < W; x += 24) cv.rect(x, WALL_TOP + 1, 1, WALL_H - 2, C.wallDark);

  // Corner posts hard against the frame edges only. A pair just inside the
  // fighters reads as grey slabs behind the sprites rather than as structure —
  // at this tile width there is no room for anything between edge and fight.
  const post = (x: number, w: number) => {
    cv.rect(x, HEADER_H, w, FLOOR_Y - HEADER_H, C.post);
    cv.rect(x, HEADER_H, 1, FLOOR_Y - HEADER_H, C.postLit);
    cv.rect(x, HEADER_H, w, 2, C.postLit);
    cv.rect(x, FLOOR_Y - 3, w, 3, C.postLit);
  };
  post(0, 5);
  post(W - 5, 5);

  // Lamps bracketed to the posts, with warm spill on the wall and the ground.
  const lamp = (cx: number) => {
    cv.rect(cx - 3, 30, 7, 20, C.lampGlow);
    cv.rect(cx - 1, 40, 3, 8, C.post);
    cv.rect(cx - 1, 34, 3, 6, C.gold);
    cv.rect(cx, 35, 1, 3, C.lampCore);
  };
  lamp(7);
  lamp(W - 8);

  // Ground, with a lit leading edge and scattered grain.
  cv.rect(0, FLOOR_Y, W, ARENA_BOTTOM - FLOOR_Y, C.ground);
  cv.rect(0, FLOOR_Y, W, 1, C.groundEdge);
  cv.rect(0, FLOOR_Y + 2, W, 1, C.groundLit);
  for (let x = 3; x < W; x += 9) cv.rect(x, FLOOR_Y + 6, 2, 1, C.groundLit);
  for (let x = 11; x < W; x += 13) cv.rect(x, FLOOR_Y + 12, 3, 1, C.groundLit);
  // Lamplight pools where the bulls stand, so they read as lit from the side
  // rather than pasted on.
  cv.rect(2, FLOOR_Y + 1, 26, ARENA_BOTTOM - FLOOR_Y - 1, C.lampGlow);
  cv.rect(W - 28, FLOOR_Y + 1, 26, ARENA_BOTTOM - FLOOR_Y - 1, C.lampGlow);

  // Vignette: a darkened border rather than an alpha wash.
  cv.rect(0, HEADER_H, 1, ARENA_BOTTOM - HEADER_H, C.vignette);
  cv.rect(W - 1, HEADER_H, 1, ARENA_BOTTOM - HEADER_H, C.vignette);
  cv.rect(0, HEADER_H, W, 1, C.vignette);

  // Header and footer plates.
  cv.rect(0, 0, W, HEADER_H, C.bg);
  cv.rect(0, HEADER_H - 1, W, 1, C.border);
  cv.rect(0, ARENA_BOTTOM, W, H - ARENA_BOTTOM, C.bg);
  cv.rect(0, ARENA_BOTTOM, W, 1, C.border);
  return cv;
}

/** The lightning thrown on a crit, as a list of 1px segments down the middle. */
const BOLT: readonly (readonly [number, number])[] = [
  [100, 13], [97, 24], [105, 34], [95, 46], [108, 58], [93, 70], [102, 82], [99, 92],
];

// ── sprites ───────────────────────────────────────────────────────────
interface Sprite {
  readonly px: Uint8ClampedArray;
  /** Backdrop colours to key out so the arena shows through. */
  readonly keys: readonly RGB[];
}

/**
 * Rasterise one bull once per fight and blit it per frame.
 *
 * The art engine is the source of truth for what a bull looks like: this reads
 * `renderTile` and keys out the tile's own backdrop. It does NOT tint, grey out
 * or recolour anything — every derived colour would be a new palette entry, and
 * the palette is the scarce resource here.
 */
function spriteFor(f: ReplayFighter): Sprite {
  const token = getBull(f.tokenId);
  return {
    px: renderTile(token),
    keys: [token.bg as RGB, token.floor as RGB],
  };
}

// ── one rendered moment ───────────────────────────────────────────────
interface Shot {
  round: number;
  hpA: number;
  hpB: number;
  /** Pixels the attacker's tile has closed toward the opponent. */
  lunge: { side: 'a' | 'b'; px: number } | null;
  /** The struck side jitters. */
  shake: 'a' | 'b' | null;
  flash: RGB | null;
  bolt: boolean;
  floater: { side: 'a' | 'b'; text: string; colour: RGB; rise: number } | null;
  vs: boolean;
  banner: { title: string; titleColour: RGB; name: string; sub: string } | null;
  delayMs: number;
}

const HP_COLOUR = (pct: number): RGB => (pct > 0.6 ? C.green : pct > 0.25 ? C.amber : C.red);

function clampName(s: string, max: number): string {
  const t = s.trim();
  return t.length <= max ? t : `${t.slice(0, max - 1)}.`;
}

/**
 * Walk the event list into a list of moments.
 *
 * ⚠ HP COMES OFF THE EVENTS, NEVER OFF A RE-DERIVED SUBTRACTION.
 * `attack_hit` and `sidekick_chip` both carry `defenderHpAfter`, and the heal
 * and save events carry the post-effect hp too. Reading those directly is what
 * makes the bars agree with the fight the contract recorded even if this file
 * ever falls behind the sim's arithmetic.
 */
function storyboard(input: ReplayInput): Shot[] {
  const { a, b, events } = input;
  const shots: Shot[] = [];

  const playable = events.filter((e) => e.type !== 'fight_end');
  const perEvent = Math.max(
    MIN_FRAMES_PER_EVENT,
    Math.min(
      MAX_FRAMES_PER_EVENT,
      Math.floor(EVENT_BUDGET_MS / BEAT_MS / Math.max(1, playable.length)),
    ),
  );

  let hpA = a.maxHp;
  let hpB = b.maxHp;
  let round = 0;

  const sideOf = (tokenId: number): 'a' | 'b' => (tokenId === a.tokenId ? 'a' : 'b');

  const push = (partial: Partial<Shot>, frames: number) => {
    for (let i = 0; i < frames; i++) {
      shots.push({
        round,
        hpA,
        hpB,
        lunge: null,
        shake: null,
        flash: null,
        bolt: false,
        floater: null,
        vs: false,
        banner: null,
        delayMs: BEAT_MS,
        ...partial,
        // A floater rises across the frames it is shown for.
        ...(partial.floater ? { floater: { ...partial.floater, rise: i } } : {}),
        // The lunge and the shake are the FIRST frame of a beat only; holding
        // them for the whole beat reads as a pose, not a swing.
        ...(i > 0 ? { lunge: null, shake: null, bolt: false, flash: null } : {}),
      });
    }
  };

  // Intro: both bulls squared up, "VS" in the gap.
  push({ vs: true }, 6);

  for (const e of playable) {
    switch (e.type) {
      case 'round_start': {
        round = e.round;
        push({}, 1);
        break;
      }
      case 'attack_miss': {
        const atk = sideOf(e.attackerId);
        push(
          {
            lunge: { side: atk, px: 3 },
            floater: { side: atk === 'a' ? 'b' : 'a', text: 'MISS', colour: C.dim, rise: 0 },
          },
          perEvent,
        );
        break;
      }
      case 'attack_hit': {
        const atk = sideOf(e.attackerId);
        const def = sideOf(e.defenderId);
        if (def === 'a') hpA = e.defenderHpAfter;
        else hpB = e.defenderHpAfter;
        const label = e.isCritical
          ? `CRIT ${e.damage}`
          : e.typeAdvantage
            ? `${e.damage}!`
            : `${e.damage}`;
        push(
          {
            lunge: { side: atk, px: e.isCritical ? 7 : 4 },
            shake: def,
            bolt: e.isCritical,
            flash: e.isCritical ? C.bolt : null,
            floater: {
              side: def,
              text: label,
              colour: e.isCritical ? C.goldLit : e.typeAdvantage ? C.amber : C.red,
              rise: 0,
            },
          },
          perEvent,
        );
        break;
      }
      case 'sidekick_chip': {
        const tgt = sideOf(e.targetId);
        if (tgt === 'a') hpA = e.defenderHpAfter;
        else hpB = e.defenderHpAfter;
        push(
          {
            shake: tgt,
            floater: { side: tgt, text: `${e.damage}`, colour: C.blood, rise: 0 },
          },
          perEvent,
        );
        break;
      }
      case 'sidekick_heal': {
        const side = sideOf(e.parentId);
        if (side === 'a') hpA = e.parentHpAfter;
        else hpB = e.parentHpAfter;
        push(
          { floater: { side, text: `+${e.amount}`, colour: C.green, rise: 0 } },
          perEvent,
        );
        break;
      }
      case 'sidekick_save': {
        const side = sideOf(e.parentId);
        if (side === 'a') hpA = e.hpAfter;
        else hpB = e.hpAfter;
        push(
          { flash: C.goldLit, floater: { side, text: 'SAVED', colour: C.gold, rise: 0 } },
          perEvent,
        );
        break;
      }
    }
  }

  // The result card.
  const win = input.winnerId;
  const banner =
    win === null
      ? { title: 'DRAW', titleColour: C.dim, name: '', sub: `${input.rounds} ROUNDS` }
      : {
          title: 'WINNER',
          titleColour: C.gold,
          name: clampName(win === a.tokenId ? a.name : b.name, 22),
          sub: `#${win} IN ${input.rounds} ROUND${input.rounds === 1 ? '' : 'S'}`,
        };
  const hold = shots.length ? { ...shots[shots.length - 1]! } : null;
  shots.push({
    round: input.rounds,
    hpA: hold ? hold.hpA : a.maxHp,
    hpB: hold ? hold.hpB : b.maxHp,
    lunge: null,
    shake: null,
    flash: null,
    bolt: false,
    floater: null,
    vs: false,
    banner,
    delayMs: RESULT_HOLD_MS,
  });

  return shots;
}

// ── draw one moment ───────────────────────────────────────────────────
function drawShot(
  arena: Canvas,
  cv: Canvas,
  input: ReplayInput,
  sprites: { a: Sprite; b: Sprite },
  s: Shot,
): void {
  cv.px.set(arena.px);

  const { a, b } = input;

  // Header: wordmark left, round right. `round` is 0 during the intro, before
  // the first `round_start` has been walked — "ROUND 0" is not a thing, so the
  // squaring-up frames say so instead.
  const label = s.banner ? 'FINAL' : s.round === 0 ? 'READY' : `ROUND ${s.round}`;
  cv.text('BNBULLS', 4, 4, C.gold);
  cv.text(label, W - 4 - textWidth(label), 4, C.dim);

  // Tier haloes behind the bulls, so a legendary reads as a legendary at a
  // glance without a bloom the palette cannot pay for.
  const halo = (x: number, tier: Band) => {
    const ink = TIER_INK[tier];
    cv.frame(x - 2, TILE_Y - 2, TILE_W + 4, TILE_H + 4, ink.halo);
    cv.frame(x - 1, TILE_Y - 1, TILE_W + 2, TILE_H + 2, ink.edge);
  };

  const jitter = (side: 'a' | 'b'): number => (s.shake === side ? 2 : 0);
  const lungeOf = (side: 'a' | 'b'): number => {
    if (!s.lunge || s.lunge.side !== side) return 0;
    return side === 'a' ? s.lunge.px : -s.lunge.px;
  };

  const ax = A_X + lungeOf('a') + jitter('a');
  const bx = B_X + lungeOf('b') - jitter('b');

  halo(ax, a.tier);
  halo(bx, b.tier);
  // A faces right (as drawn), B is mirrored so the two square up.
  cv.blitKeyed(sprites.a.px, TILE_W, TILE_H, ax, TILE_Y, sprites.a.keys, false);
  cv.blitKeyed(sprites.b.px, TILE_W, TILE_H, bx, TILE_Y, sprites.b.keys, true);

  if (s.bolt) {
    for (let i = 0; i < BOLT.length - 1; i++) {
      const [x0, y0] = BOLT[i]!;
      const [x1, y1] = BOLT[i + 1]!;
      const steps = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0));
      for (let t = 0; t <= steps; t++) {
        const x = Math.round(x0 + ((x1 - x0) * t) / steps);
        const y = Math.round(y0 + ((y1 - y0) * t) / steps);
        cv.set(x, y, C.bolt);
        cv.set(x + 1, y, C.gold);
      }
    }
  }

  if (s.vs) {
    cv.chipCentred('VS', GAP_CX, FLOOR_Y - 34, C.gold, 2);
  }

  if (s.floater) {
    const cx = s.floater.side === 'a' ? A_X + TILE_W / 2 : B_X + TILE_W / 2;
    cv.chipCentred(
      s.floater.text,
      cx,
      TILE_Y + 12 - Math.min(6, s.floater.rise * 2),
      s.floater.colour,
    );
  }

  // Names.
  cv.text(clampName(a.name, 20), BAR_A_X, NAME_Y, C.text);
  const bName = clampName(b.name, 20);
  cv.text(bName, W - BAR_A_X - textWidth(bName), NAME_Y, C.text);

  // HP bars.
  const bar = (x: number, hp: number, maxHp: number, rightToLeft: boolean) => {
    const pct = Math.max(0, Math.min(1, maxHp > 0 ? hp / maxHp : 0));
    const filled = Math.round((BAR_W - 2) * pct);
    cv.rect(x, BAR_Y, BAR_W, BAR_H, C.panel);
    cv.frame(x, BAR_Y, BAR_W, BAR_H, C.border);
    if (filled > 0) {
      const fx = rightToLeft ? x + 1 + (BAR_W - 2 - filled) : x + 1;
      cv.rect(fx, BAR_Y + 1, filled, BAR_H - 2, HP_COLOUR(pct));
    }
  };
  bar(BAR_A_X, s.hpA, a.maxHp, false);
  bar(BAR_B_X, s.hpB, b.maxHp, true);

  // Weapon + hp readout under each bar.
  const aStat = `${clampName(a.weaponName, 12)} ${Math.max(0, s.hpA)}/${a.maxHp}`;
  const bStat = `${Math.max(0, s.hpB)}/${b.maxHp} ${clampName(b.weaponName, 12)}`;
  cv.text(aStat, BAR_A_X, STAT_Y, C.faint);
  cv.text(bStat, W - BAR_A_X - textWidth(bStat), STAT_Y, C.faint);

  if (s.flash) {
    // A thin border pulse rather than a full-screen wash: a wash would blow the
    // interframe diff up to the whole canvas on every crit.
    cv.frame(0, HEADER_H, W, ARENA_BOTTOM - HEADER_H, s.flash);
  }

  if (s.banner) {
    const bw = 122;
    const bh = 34;
    const bxx = Math.round(W / 2 - bw / 2);
    const byy = Math.round((HEADER_H + ARENA_BOTTOM) / 2 - bh / 2);
    cv.rect(bxx, byy, bw, bh, C.bg);
    cv.frame(bxx, byy, bw, bh, s.banner.titleColour);
    cv.textCentred(s.banner.title, W / 2, byy + 5, s.banner.titleColour, 2);
    if (s.banner.name) cv.textCentred(s.banner.name, W / 2, byy + 18, C.text);
    cv.textCentred(s.banner.sub, W / 2, byy + 26, C.dim);
  }
}

// ── the renderer ──────────────────────────────────────────────────────
export interface RenderedReplay {
  readonly gif: Uint8Array;
  readonly frames: number;
  readonly width: number;
  readonly height: number;
}

/**
 * Render a verified replay to an animated GIF.
 *
 * `scale` is an integer nearest-neighbour upscale applied inside the encoder,
 * on palette INDICES rather than pixels, so a bigger picture costs almost
 * nothing and introduces no new colours.
 */
export function renderDuelReplayGif(input: ReplayInput, scale = 4): RenderedReplay {
  const arena = paintArena();
  const cv = new Canvas(W, H);
  const sprites = { a: spriteFor(input.a), b: spriteFor(input.b) };
  const shots = storyboard(input);

  const frames: GifFrame[] = shots.map((s) => {
    drawShot(arena, cv, input, sprites, s);
    return { rgba: cv.snapshot(), delayMs: s.delayMs };
  });

  const gif = encodeGif(frames, {
    width: W,
    height: H,
    scale,
    loops: 0,
    // Interface ink is reserved so a damage number never gets folded into a
    // neighbouring bucket by median cut and come out muddy — see gifEncode.ts.
    reserve: [C.gold, C.goldLit, C.red, C.green, C.amber, C.text, C.dim, C.bg, C.bolt],
  });

  return { gif, frames: frames.length, width: W * scale, height: H * scale };
}

/** Exposed so the route can bound `scale` against the real canvas size. */
export const REPLAY_LOGICAL_SIZE = { width: W, height: H } as const;
