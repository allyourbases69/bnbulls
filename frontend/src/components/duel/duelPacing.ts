/**
 * HOW LONG THE FIGHT TAKES, WORKED OUT ONCE, IN ONE PURE FUNCTION.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHY THIS FILE EXISTS: THE OLD PACING COLLAPSED ON SHORT FIGHTS.
 * ═══════════════════════════════════════════════════════════════════════
 * The previous scheme was fefers': one interval for every event,
 * `clamp(4200 / eventCount, 85, 340)`. The 4200 reads like a budget, but the
 * 340ms CEILING means a short fight can never spend it. Measured against the
 * real simulator (`sim/combat.ts`, 4000 fights, weapons drawn on their real
 * drop weights):
 *
 *   rounds   events   old event walk
 *        1     3-4     0.87s  ← 6% of fights
 *        2     6-7     2.07s  ← 25% of fights
 *        3     9-10    2.94s
 *       10    30-31    3.58s
 *
 * A one-round fight got 0.87 seconds of swinging. That is the "1 second max"
 * the owner watched, and it is not a bug in the walk, it is the cap doing
 * exactly what it says. Slowing every swing to fix it is the wrong lever: a
 * 700ms-per-swing fight is not exciting, it is sleepy.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE RULE HERE INSTEAD: A TOTAL, AND SPARE TIME GOES INTO HELD MOMENTS.
 * ═══════════════════════════════════════════════════════════════════════
 * Every fight is planned to a wall-clock total between `TARGET_MIN_MS` and
 * `TARGET_MAX_MS`, measured from the gate lifting to the victory card landing.
 * Swings keep a readable pace (never slower than `MAX_BEAT_MS`), and whatever
 * time is left over is spent on beats that are MEANT to be held:
 *
 *   1. the finisher — sit on the last blow, hp at zero, before anything moves
 *   2. the round break — a breath on "round 2" instead of a strobe you miss
 *   3. the big hits — a little air after damage lands
 *   4. anything still spare — the freeze on the lit winner
 *
 * So a two-round squash gets the same 3.8 seconds a longer fight gets, and it
 * spends them on the punch that ended it rather than on slow motion throughout.
 *
 * At the other end, a marathon cannot be allowed to run a minute either. When
 * even `HARD_MIN_BEAT_MS` will not fit the budget, events are played in GROUPS
 * (`stride`) so the total holds. Nothing is dropped: every event still lands,
 * some just land together as a flurry.
 *
 * ⚠ PURE, EXPORTED, AND MEASURED. No React, no DOM, no clock. `DuelAnimation`
 * walks the plan this returns and nothing else decides timing, so the numbers
 * in the comments above can be re-measured off real event lists at any time
 * without opening a browser.
 */
import type { CombatEvent } from '@/core/types';

// ─── the envelope ─────────────────────────────────────────────────────
//
// Owner: "the animation should go full screen and last 3-6 seconds". These
// are the ends of that window, with headroom at both edges.

/** Shortest a fight may take, gate-lift to victory card. */
export const TARGET_MIN_MS = 3600;
/** Longest, before the stride kicks in to hold the line. */
export const TARGET_MAX_MS = 5200;

/**
 * Where a fight sits in that window is decided by its WEIGHT, not its event
 * count, so a fight full of misses does not read as longer than one full of
 * hits. `RAMP_LO` is about a one-round fight, `RAMP_HI` about a ten-round one.
 */
const RAMP_LO_WEIGHT = 2;
const RAMP_HI_WEIGHT = 22;

/** The walk-on. Longer for a short fight, because it is a bigger share of the
 *  drama when there are only two swings coming. */
const INTRO_LONG_MS = 1080;
const INTRO_SHORT_MS = 760;
/** How the walk-on splits across its three steps: stare, feint, clash. */
export const INTRO_SHAPE = [0.42, 0.24, 0.34] as const;

/** The hold on the finished frame — winner lit, loser grey — BEFORE the card.
 *  ⚠ This is the reveal. It used to be zero: the card dropped on the same tick
 *  as the last event, so nobody ever saw the frame they had been watching for. */
const FREEZE_LONG_MS = 900;
const FREEZE_SHORT_MS = 640;

/** The last blow gets its own beat. Share of the walk, then clamped. */
const FINISHER_SHARE = 0.18;
const FINISHER_MIN_MS = 300;
const FINISHER_MAX_MS = 800;

/** A swing never runs slower than this, however much time is spare. */
export const MAX_BEAT_MS = 340;
/** ...and never faster than this, however many events there are. Below it,
 *  events group instead of blurring past one frame at a time. */
const HARD_MIN_BEAT_MS = 45;

/** Ceilings on the spare-time holds, so one of them cannot eat the lot. */
const ROUND_HOLD_MAX_MS = 340;
const HIT_HOLD_MAX_MS = 260;

/**
 * What each kind of event is worth in pacing terms. A hit is the unit. A round
 * start is scene-setting. `fight_end` draws nothing at all, so it carries no
 * weight — its beat is the finisher hold, allocated separately.
 */
const EVENT_WEIGHT: Record<CombatEvent['type'], number> = {
  round_start: 0.55,
  attack_hit: 1,
  attack_miss: 0.75,
  // Calves are phase 2 and no bnbulls fight emits these yet. Weighted anyway,
  // because the day one does, an unweighted event would silently shorten the
  // plan instead of being paced like the hit it is.
  sidekick_chip: 0.7,
  sidekick_heal: 0.7,
  sidekick_save: 0.7,
  fight_end: 0,
};

// ─── the plan ─────────────────────────────────────────────────────────

/** One tick of the walk: wait, then apply `events[from..to)`. */
export interface FightStep {
  /** Wall-clock wait BEFORE this step's events are applied. */
  readonly delayMs: number;
  readonly from: number;
  /** Exclusive. `to - from` is 1 for every fight short of a marathon. */
  readonly to: number;
}

export interface FightPlan {
  /** Milliseconds per walk-on step, one entry per step. */
  readonly intro: readonly number[];
  /** The walk, in order. `steps[k].from === steps[k - 1].to`. */
  readonly steps: readonly FightStep[];
  /** The hold on the last frame before the victory card. */
  readonly finalFreezeMs: number;
  /**
   * The unheld pace of one swing. Lunges and shots scale off this so a sub
   * animation can never bleed into the next swing.
   */
  readonly baseBeatMs: number;
  readonly introMs: number;
  readonly walkMs: number;
  /** intro + every step + the freeze. What the player actually sits through. */
  readonly totalMs: number;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/**
 * Plan a fight.
 *
 * Deterministic for a given event list, so the same fight always plays at the
 * same speed, and `skipToResult` can never disagree with what a watcher saw.
 */
export function buildFightPlan(events: readonly CombatEvent[]): FightPlan {
  let weight = 0;
  for (const ev of events) weight += EVENT_WEIGHT[ev.type] ?? 1;

  const ramp = clamp((weight - RAMP_LO_WEIGHT) / (RAMP_HI_WEIGHT - RAMP_LO_WEIGHT), 0, 1);
  const target = TARGET_MIN_MS + (TARGET_MAX_MS - TARGET_MIN_MS) * ramp;
  const introMs = Math.round(INTRO_LONG_MS + (INTRO_SHORT_MS - INTRO_LONG_MS) * ramp);
  let finalFreezeMs = Math.round(FREEZE_LONG_MS + (FREEZE_SHORT_MS - FREEZE_LONG_MS) * ramp);

  const intro = INTRO_SHAPE.map((f) => Math.round(introMs * f));

  // Nothing to walk. Can only happen if the signer returned an empty fight,
  // which the component treats as "never finishes" on purpose — better a
  // stalled arena than a victory card for a fight with no events in it.
  if (events.length === 0) {
    return {
      intro,
      steps: [],
      finalFreezeMs,
      baseBeatMs: MAX_BEAT_MS,
      introMs,
      walkMs: 0,
      totalMs: introMs + finalFreezeMs,
    };
  }

  const walkBudget = Math.max(600, Math.round(target) - introMs - finalFreezeMs);
  let finisherMs = clamp(Math.round(walkBudget * FINISHER_SHARE), FINISHER_MIN_MS, FINISHER_MAX_MS);
  const eventBudget = Math.max(200, walkBudget - finisherMs);

  // The pace one swing WANTS, then capped so a two-swing fight does not crawl.
  const rawBeat = eventBudget / Math.max(weight, 0.001);
  const beat = Math.min(MAX_BEAT_MS, rawBeat);

  // Too many events to give each its own readable beat? Play them in groups.
  // The total holds; the fight just reads as a flurry, which is what a
  // forty-swing grind is.
  const stride = beat >= HARD_MIN_BEAT_MS ? 1 : Math.max(1, Math.ceil(HARD_MIN_BEAT_MS / beat));

  // Whatever the cap left on the table. Only ever positive on a short fight.
  let slack = Math.max(0, Math.round(eventBudget - weight * beat));

  const take = (want: number) => {
    const got = Math.max(0, Math.min(slack, want));
    slack -= got;
    return got;
  };

  // 1. the finisher first: the single most watchable beat in the fight.
  finisherMs += take(FINISHER_MAX_MS - finisherMs);

  /** Spread what is left evenly over `count` beats, capped per beat. */
  const spread = (count: number, perBeatMax: number): number => {
    if (count <= 0 || slack <= 0) return 0;
    const per = Math.min(perBeatMax, Math.floor(slack / count));
    take(per * count);
    return per;
  };

  // 2. a breath on each round break.
  const roundHoldMs = spread(
    events.filter((e) => e.type === 'round_start').length,
    ROUND_HOLD_MAX_MS,
  );

  // 3. air after each landed hit.
  const hitHoldMs = spread(events.filter((e) => e.type === 'attack_hit').length, HIT_HOLD_MAX_MS);

  // 4. anything still spare rides on the freeze, where it costs nothing.
  finalFreezeMs += take(slack);

  // ── lay the steps out ───────────────────────────────────────────────
  const lastIndex = events.length - 1;
  const holdAt = (i: number): number => {
    // The finisher hold sits before the LAST event whatever it is, which for a
    // normal fight is `fight_end` and therefore the frame of the killing blow.
    if (i === lastIndex) return finisherMs;
    const t = events[i].type;
    if (t === 'round_start') return roundHoldMs;
    if (t === 'attack_hit') return hitHoldMs;
    return 0;
  };

  const steps: FightStep[] = [];
  let i = 0;
  while (i < events.length) {
    // A group never swallows the last event: its hold is the finisher and it
    // has to land on its own beat.
    const room = Math.max(1, Math.min(stride, lastIndex - i));
    const to = i === lastIndex ? events.length : Math.min(i + room, lastIndex);
    let delay = 0;
    for (let k = i; k < to; k++) delay += (EVENT_WEIGHT[events[k].type] ?? 1) * beat + holdAt(k);
    steps.push({ delayMs: Math.max(16, Math.round(delay)), from: i, to });
    i = to;
  }

  const walkMs = steps.reduce((s, st) => s + st.delayMs, 0);
  return {
    intro,
    steps,
    finalFreezeMs,
    baseBeatMs: Math.round(beat),
    introMs,
    walkMs,
    totalMs: introMs + walkMs + finalFreezeMs,
  };
}

/** The step that starts at `cursor`, or null once the walk is done. */
export function stepAt(plan: FightPlan, cursor: number): FightStep | null {
  return plan.steps.find((s) => s.from === cursor) ?? null;
}
