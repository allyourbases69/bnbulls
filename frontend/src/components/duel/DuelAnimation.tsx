'use client';

/**
 * THE FIGHT, PLAYING OUT ON SCREEN WHILE IT RESOLVES.
 *
 * Owner, twice: *"make the whole process the exact same as I showed you in the
 * GIF. The outcome of the fight should happen on screen via the animation. Yes
 * I know it happens in the backend, but people want to watch their bull win or
 * die LIVE."*
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS IS NOT THE REPLAY, AND THE DIFFERENCE IS THE WHOLE POINT.
 * ═══════════════════════════════════════════════════════════════════════
 * `DuelReplay.tsx` fetches a GIF of a fight that has ALREADY settled. It is the
 * receipt, it is server-rendered, and it is right where it is. This is the
 * opposite thing: it plays BEFORE the receipt exists, off the beat-by-beat
 * `CombatEvent` list `/api/run-duel` already returns alongside the signature.
 * Nothing here is fetched, nothing here is generated, and nothing here needs a
 * new endpoint — the whole fight is on the client the instant the API answers.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHERE IT SITS RELATIVE TO THE TRANSACTION, AND WHY
 * ═══════════════════════════════════════════════════════════════════════
 * The signed result exists BEFORE the transaction is sent: the API rolls it,
 * signs it and hands it over, and the player then submits it themselves. So the
 * order the player experiences is:
 *
 *      press settle  →  gate up, wallet opens  →  they sign
 *                    →  ⚡ THE FIGHT PLAYS  ⚡  (tx is in flight underneath)
 *                    →  the outcome lands, carrying the CHAIN's verdict
 *
 * It plays across the confirmation window because that is the only place it can
 * feel live. Playing it earlier (on the roll) would spoil the fight before any
 * money moved; playing it later (on the receipt) is the GIF, which is the thing
 * the owner said was not what he asked for.
 *
 * ⚠ AND THEREFORE: THE ANIMATION IS NEVER ALLOWED TO BE THE LAST WORD.
 * The events say who won the FIGHT. Only the chain says whether the fight
 * COUNTED. `status` carries the chain's answer and the outcome panel is driven
 * by it, not by the events:
 *
 *   inflight → the winner is on screen, plainly marked as still landing
 *   settled  → the winner stands, "paid out on chain"
 *   failed   → the victory is TAKEN DOWN. The panel goes red, the winner's
 *              halo is dropped, the truck banner is suppressed, and the copy
 *              says nothing moved. A revert must never leave a win on screen.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * HOW IT DRIVES (ported from fighting fefers' `DuelAnimation.tsx`)
 * ═══════════════════════════════════════════════════════════════════════
 *   round_start       → reset the attacker pointer, strobe the pit
 *   attack_hit/miss   → the attacker lunges (or looses a shot), the weapon
 *                       swings, a spark flashes, the defender shakes
 *   fight_end         → freeze the final frame
 *
 * HP bars animate as CSS width transitions on the bar div itself: every event
 * step mutates `hpA`/`hpB`, React re-renders, Tailwind transitions the width.
 * Damage numbers are absolutely-positioned spans with `animate-damage-float`
 * and a unique key per hit, so each mount re-runs the animation.
 *
 * ⚠ THE BUDGET IS FIXED AND THE BEAT IS DERIVED FROM IT. The sim hands over
 * anywhere from ~6 to ~40 events. A fixed per-event interval would make a long
 * fight run a minute. See `eventIntervalMs`.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHAT WAS DELIBERATELY NOT PORTED
 * ═══════════════════════════════════════════════════════════════════════
 *   • the bonded-baby lane — bnbulls has no calves yet (`core/types.ts`), so
 *     there is nothing to draw. The `sidekick_*` events still move the hp bars,
 *     because a fight that emits them must not render a wrong bar.
 *   • founder bands — bnbulls has none.
 *   • the ghost and the RIP banner — `lib/brand.ts` DEATH allows exactly one
 *     death image, the back of the truck, and forbids a second metaphor.
 *   • fefers' hardcoded rarity hexes — the glow comes off `lib/rarity.ts` and
 *     the `--rarity-*` palette instead (`duelFighters.ts`).
 */
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { useReadContracts } from 'wagmi';
import { DuelAbi } from '@/lib/abi';
import { contractAddress, explorerBaseUrl } from '@/lib/env';
import { BullSprite } from '@/components/BullSprite';
import { TILE_H, TILE_W } from '@/lib/art/bull';
import { tierLabel, tierTextClass } from '@/lib/rarity';
// ⚠ THE DEATH WORDS COME FROM `brand.ts`, THEY ARE NOT WRITTEN HERE. Its
// header: "Nothing below may be duplicated into a component. If you find
// yourself typing a lore word in a .tsx file, it belongs here instead." The
// truck and the butcher are exactly that.
import { DEATH, EMOJI } from '@/lib/brand';
import type { CombatEvent } from '@/core/types';
import {
  tierInkStyle,
  useDuelFighters,
  type DuelFighter,
  type ShotKind,
} from '@/components/duel/duelFighters';

// ─── pacing ───────────────────────────────────────────────────────────
// Fefers' numbers, unchanged, and they are a budget rather than a rate: a
// fight is 5-7 seconds start to finish however many swings it took. The floor
// keeps a 40-event slugfest legible, the ceiling stops a 6-event squash
// feeling sleepy, and every sub-animation is scaled off the derived beat so
// nothing bleeds into the next swing.

/** Wall-clock budget for the event playback itself. */
const EVENT_BUDGET_MS = 4200;
const MIN_EVENT_MS = 85;
const MAX_EVENT_MS = 340;
/** The whole walk-on, split across `INTRO_STEPS`. */
const INTRO_TOTAL_MS = 780;
/** Beat on the final frame before the outcome panel takes over. */
const FINAL_FREEZE_MS = 650;
/** The truck: slump, then hauled off, then the banner. */
const TRUCK_SLUMP_AT_MS = 150;
const TRUCK_BANNER_AT_MS = 900;
const TRUCK_TOTAL_MS = 1500;
/** Longest a lunge may take. Scaled down with the beat. */
const LUNGE_MS = 260;
/**
 * How long a shot is in the air. Ranged hits hold their impact — the hp drop,
 * the shake, the blood, the number — for this long so the shot visibly lands
 * before the damage reads. Must stay under the beat.
 * ⚠ Pairs with the 0.22s `shot-fly-*` keyframes in `globals.css`.
 */
const SHOT_FLIGHT_MS = 220;

/**
 * The walk-on, before a single real event: a stare-down, one feint, then both
 * of them throwing everything at once. Three steps, not four — fefers cut the
 * second feint because it read as dead air once the whole fight came down to
 * six seconds.
 */
const INTRO_STEPS = ['staredown', 'feint-a', 'clash'] as const;
const INTRO_STEP_MS = Math.round(INTRO_TOTAL_MS / INTRO_STEPS.length);

// ─── the chain's verdict ──────────────────────────────────────────────

/**
 * What the CHAIN says about the fight the animation is playing.
 *
 * ⚠ THIS IS THE PROP THAT STOPS THE ANIMATION LYING. The events are a
 * signed prediction of what settling will record; this is what settling
 * actually did. The outcome panel reads this, never the events.
 */
export type DuelChainStatus =
  /** The wallet is open. The gate is up and nothing has played yet. */
  | { readonly kind: 'signing' }
  /** Broadcast. THE FIGHT PLAYS HERE, over the confirmation window. */
  | { readonly kind: 'inflight'; readonly txHash: `0x${string}` }
  /** The receipt landed. The winner stands and the money moved. */
  | { readonly kind: 'settled'; readonly txHash: `0x${string}` }
  /**
   * Rejected, reverted, or never sent. Nothing moved, and the panel says so
   * instead of leaving a victory on screen.
   *
   * `headline` exists because "the chain knocked it back" is wrong for the most
   * common failure of all: a player pressing cancel in their wallet. Nothing
   * reached a node in that case, so pass something like "you called it off"
   * and the body copy underneath stays true either way.
   */
  | {
      readonly kind: 'failed';
      readonly message: string;
      readonly headline?: string;
      readonly txHash?: `0x${string}`;
    };

export interface DuelAnimationProps {
  /** Canonical side A — `Number(result.tokenA)`. Side A stands on the left. */
  aTokenId: number;
  bTokenId: number;
  /** `events` off the `/api/run-duel` response. Already on the client. */
  events: readonly CombatEvent[];
  status: DuelChainStatus;
  /** Headline on the gate while the wallet is open. */
  signingMessage?: string;
  /**
   * The tap-to-open-your-wallet button on the gate.
   *
   * ⚠ REQUIRED ON MOBILE, not a nicety. A native wallet deep link can only be
   * opened from inside a user-gesture callback, so a `writeContract` fired from
   * an effect silently does nothing on a phone. Give this a handler that calls
   * the write directly.
   */
  signingAction?: { label: string; onTap: () => void; disabled?: boolean } | null;
  /** Fired after the last event plus the freeze beat (and the truck, if it
   *  came to that). The parent can use it to reveal anything below. */
  onFinished?: () => void;
  /** Renders a "hide the fight" control. Omit and there is none. */
  onClose?: () => void;
  /** Extra panel content under the outcome line — the money, the receipt, a
   *  "fight again". Kept a slot so no money copy is written twice. */
  finishedOverlay?: ReactNode;
}

interface Floater {
  /** Unique per hit, so React remounts and the float animation re-runs. */
  readonly id: number;
  readonly side: 'a' | 'b';
  readonly text: string;
  readonly kind: 'damage' | 'miss' | 'crit';
}

export function DuelAnimation({
  aTokenId,
  bTokenId,
  events,
  status,
  signingMessage = 'put your half in the middle',
  signingAction = null,
  onFinished,
  onClose,
  finishedOverlay,
}: DuelAnimationProps) {
  const { a, b } = useDuelFighters(aTokenId, bTokenId, events);

  const gated = status.kind === 'signing';
  const chainFailed = status.kind === 'failed';

  // ── timers, all of them, cleaned up on unmount ──────────────────────
  // Fefers leaks these. A duel page that unmounts mid-fight (the player hits
  // "fight again", or the queue moves on) would otherwise keep firing setState
  // into a dead component for another second and a half.
  const timersRef = useRef<ReturnType<typeof setTimeout>[]>([]);
  const later = useCallback((fn: () => void, ms: number) => {
    const t = setTimeout(fn, ms);
    timersRef.current.push(t);
    return t;
  }, []);
  useEffect(
    () => () => {
      timersRef.current.forEach(clearTimeout);
      timersRef.current = [];
    },
    [],
  );

  const [hpA, setHpA] = useState(a.maxHp);
  const [hpB, setHpB] = useState(b.maxHp);
  const [shownCount, setShownCount] = useState(0);
  const [currentRound, setCurrentRound] = useState(0);
  const [attackSide, setAttackSide] = useState<'a' | 'b' | null>(null);
  const [hitSide, setHitSide] = useState<'a' | 'b' | null>(null);
  const [bloodSide, setBloodSide] = useState<'a' | 'b' | null>(null);
  const [clashing, setClashing] = useState(false);
  const [floaters, setFloaters] = useState<Floater[]>([]);
  const [shot, setShot] = useState<{ id: number; from: 'a' | 'b' } | null>(null);
  const [introStep, setIntroStep] = useState(0);
  const [strobeKey, setStrobeKey] = useState<number | null>(null);
  const [flash, setFlash] = useState(false);
  const [strikeKey, setStrikeKey] = useState<number | null>(null);
  const [shakeActive, setShakeActive] = useState(false);
  const [ended, setEnded] = useState(false);
  const [winnerId, setWinnerId] = useState<number | null | 'pending'>('pending');
  const [truckSide, setTruckSide] = useState<'a' | 'b' | null>(null);
  const [truckBanner, setTruckBanner] = useState(false);

  const keyRef = useRef(0);
  const nextKey = useCallback(() => ++keyRef.current, []);
  const lungeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const onFinishedRef = useRef(onFinished);
  onFinishedRef.current = onFinished;
  /**
   * The finalise effect runs once and only once. Without this its own cleanup
   * cancels its own freeze timeout the moment `ended` flips, and `onFinished`
   * never fires — a fefers bug worth carrying the fix for, not the bug.
   */
  const finalisedRef = useRef(false);

  // ── the beat ────────────────────────────────────────────────────────
  const eventIntervalMs = useMemo(() => {
    const n = Math.max(1, events.length);
    return Math.round(Math.min(MAX_EVENT_MS, Math.max(MIN_EVENT_MS, EVENT_BUDGET_MS / n)));
  }, [events.length]);
  const lungeMs = Math.max(80, Math.min(LUNGE_MS, Math.round(eventIntervalMs * 0.75)));
  const shotMs = Math.max(60, Math.min(SHOT_FLIGHT_MS, Math.round(eventIntervalMs * 0.5)));

  // ── is the loser going on the truck? ────────────────────────────────
  /**
   * `Duel.consecutiveLosses` + `Duel.lossesToDie`, read ONCE at mount — which
   * is before the transaction is sent, so the streak on screen is the streak
   * the loser is carrying INTO this fight. One more makes the chop.
   *
   * ⚠ FAILS CLOSED, ALWAYS. An unread streak, a zero `lossesToDie`, or a
   * transaction the chain rejected all mean NO truck. Missing a real death is
   * a shrug; announcing one that did not happen contradicts `/graveyard` and
   * the bull's own page, and it is the kind of wrong a player screenshots.
   *
   * `staleTime: 0` + `refetchOnMount: 'always'` on purpose: a value cached
   * from a PREVIOUS fight in the same session is exactly the stale read that
   * would produce a false truck.
   */
  const duelAddress = contractAddress('duel');
  const { data: streakData } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        address: duelAddress ?? undefined,
        abi: DuelAbi,
        functionName: 'consecutiveLosses' as const,
        args: [BigInt(aTokenId)] as const,
      },
      {
        address: duelAddress ?? undefined,
        abi: DuelAbi,
        functionName: 'consecutiveLosses' as const,
        args: [BigInt(bTokenId)] as const,
      },
      {
        address: duelAddress ?? undefined,
        abi: DuelAbi,
        functionName: 'lossesToDie' as const,
      },
    ],
    query: {
      enabled: !!duelAddress,
      staleTime: 0,
      refetchOnMount: 'always',
      refetchOnWindowFocus: false,
    },
  });

  const chopsAt = useMemo(() => {
    const read = (i: number): number | null =>
      streakData?.[i]?.status === 'success' ? Number(streakData[i].result) : null;
    const limit = read(2);
    if (limit === null || limit <= 0) return { a: false, b: false };
    const lossesA = read(0);
    const lossesB = read(1);
    return {
      a: lossesA !== null && lossesA + 1 >= limit,
      b: lossesB !== null && lossesB + 1 >= limit,
    };
  }, [streakData]);

  // ── helpers ─────────────────────────────────────────────────────────
  const sideOf = useCallback(
    (tokenId: number): 'a' | 'b' | null => {
      if (tokenId === a.tokenId) return 'a';
      if (tokenId === b.tokenId) return 'b';
      return null;
    },
    [a.tokenId, b.tokenId],
  );

  const pushFloater = useCallback(
    (side: 'a' | 'b', text: string, kind: Floater['kind']) => {
      const id = nextKey();
      setFloaters((f) => [...f, { id, side, text, kind }]);
      later(() => setFloaters((f) => f.filter((x) => x.id !== id)), 1200);
    },
    [later, nextKey],
  );

  const lunge = useCallback(
    (side: 'a' | 'b') => {
      setAttackSide(side);
      if (lungeTimerRef.current) clearTimeout(lungeTimerRef.current);
      lungeTimerRef.current = later(() => setAttackSide(null), lungeMs);
    },
    [later, lungeMs],
  );

  const loose = useCallback(
    (side: 'a' | 'b') => {
      const id = nextKey();
      setShot({ id, from: side });
      later(() => setShot((s) => (s && s.id === id ? null : s)), shotMs + 120);
    },
    [later, nextKey, shotMs],
  );

  // ── one event ───────────────────────────────────────────────────────
  const applyEvent = useCallback(
    (ev: CombatEvent) => {
      switch (ev.type) {
        case 'round_start': {
          setCurrentRound(ev.round);
          setStrobeKey(nextKey());
          const s = sideOf(ev.attackerId);
          if (s) lunge(s);
          break;
        }
        case 'attack_hit': {
          const defSide = sideOf(ev.defenderId);
          const attSide = sideOf(ev.attackerId);
          const ranged = attSide === 'a' ? a.ranged : attSide === 'b' ? b.ranged : false;
          const hp = Math.max(0, ev.defenderHpAfter);

          // The attacker moves immediately either way: melee closes the
          // distance and sparks, ranged plants itself and lets the shot travel.
          if (attSide) lunge(attSide);
          if (ranged && attSide) {
            loose(attSide);
          } else {
            setClashing(true);
            later(() => setClashing(false), lungeMs);
          }

          const impact = () => {
            if (defSide === 'a') setHpA(hp);
            if (defSide === 'b') setHpB(hp);
            if (defSide) {
              setHitSide(defSide);
              setBloodSide(defSide);
              later(() => setHitSide(null), lungeMs);
              later(() => setBloodSide(null), 600);
              pushFloater(
                defSide,
                ev.isCritical ? `crit! -${ev.damage}` : `-${ev.damage}`,
                ev.isCritical ? 'crit' : 'damage',
              );
            }
            setFlash(true);
            later(() => setFlash(false), ev.isCritical ? 260 : 140);
            if (ev.isCritical || ev.damage >= 15 || hp <= 0) {
              setShakeActive(true);
              later(() => setShakeActive(false), 420);
            }
            if (ev.isCritical || hp <= 0) setStrikeKey(nextKey());
          };

          // Hold the damage until the shot lands, or the hit reads before the
          // arrow gets there.
          if (ranged) later(impact, shotMs);
          else impact();
          break;
        }
        case 'attack_miss': {
          const defSide = sideOf(ev.defenderId);
          const attSide = sideOf(ev.attackerId);
          const ranged = attSide === 'a' ? a.ranged : attSide === 'b' ? b.ranged : false;
          if (attSide) lunge(attSide);
          // A missed shot still flies. It just sails past.
          if (ranged && attSide) loose(attSide);
          if (defSide) {
            const show = () => pushFloater(defSide, 'miss', 'miss');
            if (ranged) later(show, shotMs);
            else show();
          }
          break;
        }
        // ── calves (phase 2) ────────────────────────────────────────────
        // bnbulls has no calf collection, so a fight here NEVER emits these.
        // They move the hp anyway, because the day one does, a bar that
        // ignored them would be wrong on screen — and wrong quietly.
        case 'sidekick_chip': {
          const tgt = sideOf(ev.targetId);
          const hp = Math.max(0, ev.defenderHpAfter);
          if (tgt === 'a') setHpA(hp);
          if (tgt === 'b') setHpB(hp);
          if (tgt) pushFloater(tgt, `-${ev.damage}`, 'damage');
          break;
        }
        case 'sidekick_heal': {
          const parent = sideOf(ev.parentId);
          if (parent === 'a') setHpA(Math.min(a.maxHp, ev.parentHpAfter));
          if (parent === 'b') setHpB(Math.min(b.maxHp, ev.parentHpAfter));
          if (parent) pushFloater(parent, `+${ev.amount}`, 'miss');
          break;
        }
        case 'sidekick_save': {
          const parent = sideOf(ev.parentId);
          const hp = Math.max(0, ev.hpAfter);
          if (parent === 'a') setHpA(hp);
          if (parent === 'b') setHpB(hp);
          break;
        }
        case 'fight_end':
          setWinnerId(ev.winnerId);
          break;
      }
    },
    [a.maxHp, a.ranged, b.maxHp, b.ranged, later, loose, lunge, lungeMs, nextKey, pushFloater, shotMs, sideOf],
  );

  /**
   * ⚠ THE BEAT MUST NOT RESTART WHEN SOMETHING ELSE RE-RENDERS.
   *
   * `applyEvent` closes over the fighters, so it gets a new identity every time
   * the chain read settles or refetches — and if the event-walk effect below
   * depended on it, that would clear its pending timer and re-arm the SAME
   * beat, stuttering the fight at exactly the moment a player tabbed back from
   * their wallet. Held in a ref so the walk depends only on the step it is on.
   */
  const applyEventRef = useRef(applyEvent);
  applyEventRef.current = applyEvent;

  // ── the walk-on ─────────────────────────────────────────────────────
  // Runs only once the gate lifts, so the stare-down is the first thing the
  // player sees after their wallet closes rather than something they missed.
  useEffect(() => {
    if (gated) return;
    if (introStep >= INTRO_STEPS.length) return;
    const step = INTRO_STEPS[introStep];
    const timer = setTimeout(() => {
      if (step === 'staredown') {
        setStrobeKey(nextKey());
      } else if (step === 'feint-a') {
        lunge('a');
        setClashing(true);
        later(() => setClashing(false), lungeMs);
      } else {
        lunge('a');
        setClashing(true);
        setStrobeKey(nextKey());
        setFlash(true);
        later(() => setFlash(false), 220);
        setShakeActive(true);
        later(() => setShakeActive(false), 400);
        later(() => lunge('b'), lungeMs / 2);
        later(() => setClashing(false), lungeMs);
      }
      setIntroStep((s) => s + 1);
    }, INTRO_STEP_MS);
    return () => clearTimeout(timer);
  }, [introStep, gated, later, lunge, lungeMs, nextKey]);

  // ── walk the events, one beat at a time ─────────────────────────────
  useEffect(() => {
    if (gated) return;
    if (introStep < INTRO_STEPS.length) return;
    if (shownCount >= events.length) return;
    const ev = events[shownCount];
    // A round start is scene-setting, not a swing — give it a short beat so
    // the actual swings keep the bulk of the budget.
    const beat =
      ev.type === 'round_start'
        ? Math.max(50, Math.round(eventIntervalMs * 0.55))
        : eventIntervalMs;
    const timer = setTimeout(() => {
      applyEventRef.current(ev);
      setShownCount((c) => c + 1);
    }, beat);
    return () => clearTimeout(timer);
  }, [shownCount, events, gated, introStep, eventIntervalMs]);

  // ── skip to the result ──────────────────────────────────────────────
  /**
   * Folds every remaining event in one pass and lands on the final frame. The
   * same fold the walk would have produced, so skipping cannot show a
   * different fight from watching.
   */
  const skipToResult = useCallback(() => {
    timersRef.current.forEach(clearTimeout);
    timersRef.current = [];
    let hA = a.maxHp;
    let hB = b.maxHp;
    let round = 0;
    let winner: number | null | 'pending' = 'pending';
    for (const ev of events) {
      if (ev.type === 'round_start') round = ev.round;
      else if (ev.type === 'attack_hit') {
        if (ev.defenderId === a.tokenId) hA = Math.max(0, ev.defenderHpAfter);
        if (ev.defenderId === b.tokenId) hB = Math.max(0, ev.defenderHpAfter);
      } else if (ev.type === 'sidekick_chip') {
        if (ev.targetId === a.tokenId) hA = Math.max(0, ev.defenderHpAfter);
        if (ev.targetId === b.tokenId) hB = Math.max(0, ev.defenderHpAfter);
      } else if (ev.type === 'sidekick_heal') {
        if (ev.parentId === a.tokenId) hA = Math.min(a.maxHp, ev.parentHpAfter);
        if (ev.parentId === b.tokenId) hB = Math.min(b.maxHp, ev.parentHpAfter);
      } else if (ev.type === 'sidekick_save') {
        if (ev.parentId === a.tokenId) hA = Math.max(0, ev.hpAfter);
        if (ev.parentId === b.tokenId) hB = Math.max(0, ev.hpAfter);
      } else if (ev.type === 'fight_end') {
        winner = ev.winnerId;
      }
    }
    setFloaters([]);
    setShot(null);
    setAttackSide(null);
    setHitSide(null);
    setBloodSide(null);
    setClashing(false);
    setHpA(hA);
    setHpB(hB);
    setCurrentRound(round);
    setWinnerId(winner);
    setIntroStep(INTRO_STEPS.length);
    setShownCount(events.length);
  }, [a.maxHp, a.tokenId, b.maxHp, b.tokenId, events]);

  /**
   * ⚠ A FIGHT THE CHAIN HAS ALREADY REFUSED STOPS DEAD.
   *
   * Once `submitDuel` has reverted there is nothing left to watch: no money
   * moved and no result was recorded, so carrying on swinging for another three
   * seconds is the animation insisting on an outcome that is not going to
   * happen. Jump straight to the final frame and let the red panel take over.
   */
  const stoppedRef = useRef(false);
  useEffect(() => {
    if (status.kind !== 'failed') return;
    if (stoppedRef.current) return;
    stoppedRef.current = true;
    skipToResult();
  }, [status.kind, skipToResult]);

  // ── the last frame ──────────────────────────────────────────────────
  useEffect(() => {
    if (events.length === 0) return;
    if (shownCount < events.length) return;
    if (finalisedRef.current) return;
    finalisedRef.current = true;

    const last = events[events.length - 1];
    if (last && last.type === 'fight_end') setWinnerId(last.winnerId);
    setEnded(true);

    // Who loses, and are they on the truck for it? A draw kills nobody, and a
    // fight the chain refused kills nobody either.
    const loser =
      last && last.type === 'fight_end' && last.winnerId !== null
        ? last.winnerId === a.tokenId
          ? 'b'
          : last.winnerId === b.tokenId
            ? 'a'
            : null
        : null;
    const hauled = loser !== null && chopsAt[loser] ? loser : null;

    if (hauled === null) {
      later(() => onFinishedRef.current?.(), FINAL_FREEZE_MS);
      return;
    }
    later(() => setTruckSide(hauled), TRUCK_SLUMP_AT_MS);
    later(() => setTruckBanner(true), TRUCK_BANNER_AT_MS);
    later(() => onFinishedRef.current?.(), TRUCK_TOTAL_MS);
  }, [shownCount, events, a.tokenId, b.tokenId, chopsAt, later]);

  /**
   * Pin both bars to full until the first event lands.
   *
   * Only does anything when the chain read resolves AFTER mount and moves
   * `maxHp` off its event-derived stand-in — without this the bar would sit
   * under 100% until the first hit. Inert once playback starts.
   */
  useEffect(() => {
    if (shownCount > 0) return;
    setHpA(a.maxHp);
    setHpB(b.maxHp);
  }, [a.maxHp, b.maxHp, shownCount]);

  // ── derived ─────────────────────────────────────────────────────────
  const hpPctA = Math.max(0, Math.min(100, (hpA / Math.max(1, a.maxHp)) * 100));
  const hpPctB = Math.max(0, Math.min(100, (hpB / Math.max(1, b.maxHp)) * 100));

  const settledWinner = winnerId === 'pending' ? null : winnerId;
  const showWinner = ended && !chainFailed;
  const winnerName =
    settledWinner === null
      ? null
      : settledWinner === a.tokenId
        ? a.name
        : settledWinner === b.tokenId
          ? b.name
          : null;

  const txUrl = 'txHash' in status && status.txHash ? `${explorerBaseUrl()}/tx/${status.txHash}` : null;
  const playing = !gated && !ended;

  return (
    <div className="space-y-2">
      <div
        className={
          'duel-arena duel-arena-floor bull-card rounded p-4 md:p-5 ' +
          (truckSide ? 'duel-arena-truck ' : '') +
          (shakeActive ? 'animate-arena-shake' : '')
        }
      >
        {/* Round start, one quick pulse of gold and blood across the pit. */}
        {strobeKey !== null && (
          <div
            key={`strobe-${strobeKey}`}
            className="pointer-events-none absolute inset-0 z-[1] animate-round-strobe"
            aria-hidden
          />
        )}

        {/* Every hit. Brighter on a crit. */}
        {flash && (
          <div className="pointer-events-none absolute inset-0 z-[1] bg-bull-text/50" aria-hidden />
        )}

        {/* Crits and killing blows get the bolt. */}
        {strikeKey !== null && (
          <svg
            key={`strike-${strikeKey}`}
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            className="pointer-events-none absolute inset-0 z-[2] h-full w-full animate-strike-flash"
            aria-hidden
          >
            <polyline
              points="50,-5 45,18 58,32 42,48 60,62 40,78 55,100"
              fill="none"
              className="stroke-bull-gold-hot"
              strokeWidth="2.5"
              strokeLinejoin="miter"
            />
            <polyline
              points="50,-5 45,18 58,32 42,48 60,62 40,78 55,100"
              fill="none"
              className="stroke-bull-gold"
              strokeWidth="1"
              strokeLinejoin="miter"
            />
          </svg>
        )}

        {/* ── the gate ──────────────────────────────────────────────
            Up while the wallet is open. The fight is loaded and waiting
            behind it; the first swing happens the moment the signature
            comes back. */}
        {gated && (
          <div className="absolute inset-0 z-30 flex items-center justify-center bg-bull-bg/85 backdrop-blur-sm">
            <div className="max-w-[92%] space-y-3 px-3 text-center md:max-w-sm">
              <div className="text-3xl" aria-hidden>
                {EMOJI.pot}
              </div>
              <p className="bull-header text-base text-bull-gold">{signingMessage}</p>
              {/* ⚠ NO PERCENTAGE HERE ON PURPOSE. The winner's cut and the pot
                  slice are stated once, in `brand.ts` DEAL, and a shortened
                  copy of a number in a component is a number that drifts. */}
              <p className="text-sm leading-relaxed text-bull-text-dim">
                both sides put the same amount in the middle.
              </p>
              {signingAction ? (
                <div className="pt-1">
                  <button
                    type="button"
                    className="bull-btn w-full max-w-[18rem]"
                    onClick={signingAction.onTap}
                    disabled={!!signingAction.disabled}
                  >
                    {signingAction.label}
                  </button>
                  <p className="mt-2 text-xs leading-relaxed text-bull-text-faint">
                    tap to open your wallet. confirm it there and you come straight back here for
                    the fight.
                  </p>
                </div>
              ) : (
                <p className="text-xs leading-relaxed text-bull-text-faint">
                  the fight starts the second your wallet signs. no popup? check the wallet icon in
                  your toolbar, it may have opened behind the window.
                </p>
              )}
            </div>
          </div>
        )}

        {/* Round counter and, once it is over, who won. */}
        <div className="relative z-10 mb-3 flex flex-wrap items-center justify-between gap-2 font-mono text-xs">
          <span className="text-bull-text-faint">
            round <span className="text-bull-gold">{currentRound || '·'}</span>
          </span>
          {showWinner && (
            <span className={winnerName === null ? 'text-bull-text-dim' : 'text-bull-gold'}>
              {winnerName === null ? 'a draw' : `${winnerName} wins`}
              {status.kind === 'inflight' && (
                <span className="ml-2 text-bull-text-faint">· still landing on chain</span>
              )}
            </span>
          )}
        </div>

        {/* The shot in the air. Keyed per shot so back-to-back shots re-run. */}
        {shot && (
          <div
            key={`shot-${shot.id}`}
            className={
              'pointer-events-none absolute top-[42%] z-20 ' +
              (shot.from === 'a' ? 'animate-shot-fly-right' : 'animate-shot-fly-left')
            }
            aria-hidden
          >
            <ShotSprite kind={shot.from === 'a' ? a.shot : b.shot} flip={shot.from === 'b'} />
          </div>
        )}

        <div className="relative z-10 grid grid-cols-[1fr_auto_1fr] items-stretch gap-2 md:gap-4">
          <FighterLane
            side="a"
            fighter={a}
            hp={hpA}
            hpPct={hpPctA}
            attacking={attackSide === 'a'}
            hit={hitSide === 'a'}
            bloody={bloodSide === 'a'}
            floaters={floaters.filter((f) => f.side === 'a')}
            winner={showWinner && settledWinner === a.tokenId}
            loser={showWinner && settledWinner !== null && settledWinner !== a.tokenId}
            hauled={truckSide === 'a'}
            banner={truckBanner && truckSide === 'a'}
          />
          <div className="relative flex min-w-[3rem] flex-col items-center justify-center self-center px-1">
            {clashing ? (
              // No key needed: `clashing` unmounts between swings (the clear
              // always fires inside one beat, because `lungeMs < beat`), so the
              // spark remounts and re-runs on its own.
              <span
                className="bull-header animate-clash-spark text-2xl text-bull-gold md:text-4xl"
                aria-hidden
              >
                ✦
              </span>
            ) : (
              <span className="bull-header text-lg text-bull-text-faint md:text-2xl">vs</span>
            )}
          </div>
          <FighterLane
            side="b"
            fighter={b}
            hp={hpB}
            hpPct={hpPctB}
            attacking={attackSide === 'b'}
            hit={hitSide === 'b'}
            bloody={bloodSide === 'b'}
            floaters={floaters.filter((f) => f.side === 'b')}
            winner={showWinner && settledWinner === b.tokenId}
            loser={showWinner && settledWinner !== null && settledWinner !== b.tokenId}
            hauled={truckSide === 'b'}
            banner={truckBanner && truckSide === 'b'}
          />
        </div>

        {/* ── the outcome ───────────────────────────────────────────
            ⚠ BELOW `md` THIS IS NOT AN OVERLAY. The arena is
            `overflow-hidden`, and on a phone the panel is comfortably
            taller than the fight — as an `absolute inset-0` it would be
            clipped and the buttons at the bottom of it could be neither
            seen nor tapped. Fefers shipped that bug to a real phone. So
            it renders in normal flow under the fight on small screens
            and goes back to being the overlay from `md` up, where there
            is room for the nicer reveal. */}
        {ended && (
          <div className="animate-outcome-drop relative z-20 mt-3 flex justify-center md:absolute md:inset-0 md:mt-0 md:items-center md:pointer-events-none">
            <div
              className={
                'pointer-events-auto w-full max-w-lg space-y-3 rounded border-2 bg-bull-bg/92 p-4 backdrop-blur-sm md:mx-4 md:p-5 ' +
                (chainFailed ? 'border-bull-red' : 'border-bull-gold')
              }
            >
              {chainFailed ? (
                <>
                  {/* ⚠ THE VICTORY COMES DOWN. The fight rolled a winner and
                      the chain would not take it, so there is no winner to
                      show — showing one anyway would be a lie about money. */}
                  <p className="bull-header text-lg text-bull-red">
                    {status.headline ?? 'the chain knocked it back'}
                  </p>
                  <p className="text-sm text-bull-text-dim">
                    nothing moved. nobody was charged, nobody got paid, and this one is not on the
                    record. what you just watched was the roll, not a result.
                  </p>
                  <p className="break-words font-mono text-xs text-bull-text-faint">
                    {status.message}
                  </p>
                </>
              ) : (
                <>
                  <p className="bull-header text-lg text-bull-gold">
                    {winnerName === null ? 'nobody wins it' : `${winnerName} wins`}
                  </p>
                  <p className="font-mono text-xs text-bull-text-faint">
                    {currentRound} round{currentRound === 1 ? '' : 's'}
                    {status.kind === 'settled' ? ' · paid out on chain' : ' · still landing on chain'}
                  </p>
                </>
              )}
              {txUrl && (
                <p className="text-xs">
                  <a
                    href={txUrl}
                    target="_blank"
                    rel="noreferrer"
                    className="text-bull-gold hover:underline"
                  >
                    view the transaction
                  </a>
                </p>
              )}
              {finishedOverlay}
            </div>
          </div>
        )}
      </div>

      {/* Skip / hide, the way the reference has them: small, under the pit,
          never competing with the fight. */}
      {(playing || onClose) && (
        <div className="flex flex-wrap items-center justify-end gap-4 font-mono text-xs">
          {playing && (
            <button
              type="button"
              onClick={skipToResult}
              className="text-bull-text-dim transition-colors hover:text-bull-gold"
            >
              skip to the result
            </button>
          )}
          {onClose && (
            <button
              type="button"
              onClick={onClose}
              className="text-bull-text-faint transition-colors hover:text-bull-gold"
            >
              hide the fight
            </button>
          )}
        </div>
      )}
    </div>
  );
}

// ─── one lane ─────────────────────────────────────────────────────────

interface FighterLaneProps {
  side: 'a' | 'b';
  fighter: DuelFighter;
  hp: number;
  hpPct: number;
  attacking: boolean;
  hit: boolean;
  bloody: boolean;
  floaters: Floater[];
  winner: boolean;
  loser: boolean;
  /** Being loaded onto the truck. */
  hauled: boolean;
  banner: boolean;
}

function FighterLane({
  side,
  fighter,
  hp,
  hpPct,
  attacking,
  hit,
  bloody,
  floaters,
  winner,
  loser,
  hauled,
  banner,
}: FighterLaneProps) {
  const down = hp <= 0;
  // Idle breath stops for anything that means something. `hauled` is in here
  // because a fight can end on the round cap with the loser still on hp, and
  // two `animation` shorthands on one element is a coin toss nobody should
  // have to read the stylesheet order to predict.
  const idle = !attacking && !hit && !down && !hauled;

  // Melee closes a good chunk of the distance; ranged plants itself and
  // recoils, because the shot is what travels. A on the left moves right.
  const lungeClass = attacking
    ? fighter.ranged
      ? side === 'a'
        ? '-translate-x-1 md:-translate-x-2'
        : 'translate-x-1 md:translate-x-2'
      : side === 'a'
        ? 'translate-x-8 md:translate-x-16'
        : '-translate-x-8 md:-translate-x-16'
    : 'translate-x-0';

  /**
   * ⚠ HP INK IS NOT THE RARITY LADDER. Fefers goes green → yellow → red;
   * this palette has no green and its greens are spoken for (`--rarity-rare`
   * is the "rare" band). Bone draining to blood draining to bright red is the
   * same three-step read in the colours this site already owns, and it does
   * not spend gold, which `globals.css` reserves for brand and the 1/1.
   */
  const hpInk = hpPct > 60 ? 'bg-bull-text' : hpPct > 25 ? 'bg-bull-blood' : 'bg-bull-red';

  const weaponSwing = attacking
    ? side === 'a'
      ? 'rotate-[35deg] scale-125'
      : '-rotate-[35deg] scale-125'
    : 'rotate-0 scale-100';

  return (
    <div className="space-y-2">
      <div className="relative">
        <div
          className={
            'duel-portrait relative overflow-visible transition-transform duration-500 ease-out ' +
            `${lungeClass} ` +
            (hit ? 'animate-hit-shake ' : '') +
            (idle ? 'animate-float-idle ' : '') +
            (winner ? 'duel-portrait-winner ' : '') +
            (loser ? 'duel-portrait-loser ' : '') +
            (hauled ? 'animate-bull-hauled' : '')
          }
          style={{ ...tierInkStyle(fighter.tier), aspectRatio: `${TILE_W} / ${TILE_H}` }}
        >
          {fighter.art && (
            <div className={down ? 'brightness-75 grayscale' : undefined}>
              <BullSprite token={fighter.art} fluid className="pixel" />
            </div>
          )}
          <span
            className={
              'absolute top-1/2 -translate-y-1/2 text-xl drop-shadow-[0_0_4px_rgba(0,0,0,0.85)] transition-transform duration-300 md:text-3xl ' +
              (side === 'a' ? 'right-1 ' : 'left-1 ') +
              weaponSwing
            }
            aria-hidden
          >
            {fighter.glyph}
          </span>
        </div>

        {/* Blood, scattered where the hit landed. */}
        {bloody && (
          <svg
            viewBox="0 0 32 32"
            preserveAspectRatio="none"
            className="pointer-events-none absolute inset-0 h-full w-full animate-blood-splat"
            aria-hidden
          >
            <rect x="6" y="10" width="2" height="2" className="fill-bull-red" />
            <rect x="22" y="8" width="2" height="2" className="fill-bull-blood" />
            <rect x="10" y="16" width="2" height="2" className="fill-bull-red" />
            <rect x="18" y="20" width="2" height="2" className="fill-bull-blood" />
            <rect x="4" y="18" width="1" height="1" className="fill-bull-red" />
            <rect x="27" y="14" width="1" height="1" className="fill-bull-red" />
            <rect x="14" y="5" width="1" height="1" className="fill-bull-blood" />
            <rect x="20" y="26" width="2" height="2" className="fill-bull-blood" />
            <rect x="2" y="24" width="1" height="1" className="fill-bull-red" />
            <rect x="28" y="22" width="1" height="1" className="fill-bull-red" />
          </svg>
        )}

        {/* Damage / miss numbers. */}
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
          {floaters.map((f) => (
            <span
              key={f.id}
              className={
                'bull-header absolute animate-damage-float text-sm md:text-lg ' +
                (f.kind === 'crit'
                  ? 'text-bull-gold'
                  : f.kind === 'miss'
                    ? 'text-bull-text-faint'
                    : 'text-bull-red')
              }
            >
              {f.text}
            </span>
          ))}
        </div>

        {down && !hauled && !banner && (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-bull-bg/60">
            <span className="bull-header text-lg text-bull-red">down</span>
          </div>
        )}

        {/* Onto the truck. `lib/brand.ts` DEATH: this is the ONE death image,
            and there is deliberately no second one. */}
        {hauled && (
          <div
            className="animate-bull-slump pointer-events-none absolute inset-0 bg-gradient-to-b from-transparent via-transparent to-bull-bg/80"
            aria-hidden
          />
        )}
        {banner && (
          <div className="animate-truck-banner pointer-events-none absolute inset-0 flex items-center justify-center">
            <div className="border-2 border-bull-red bg-bull-bg/92 px-3 py-2 text-center">
              <p className="bull-header text-sm text-bull-red">
                {EMOJI.death} {DEATH.listHeading}
              </p>
              <p className="mt-1 text-xs text-bull-text-dim">{DEATH.rescue}</p>
            </div>
          </div>
        )}
      </div>

      <div>
        <div className="flex items-baseline justify-between gap-2 font-mono text-sm">
          <span
            className={
              'bull-header truncate ' + (winner ? 'text-bull-gold' : 'text-bull-text')
            }
            title={`${fighter.name} · #${fighter.tokenId}`}
          >
            {fighter.name}
          </span>
          {/* Withheld rather than guessed while the starting hp is unknown. */}
          {fighter.maxHpKnown && (
            <span className="shrink-0 tabular-nums text-bull-text-dim">
              {hp} / {fighter.maxHp}
            </span>
          )}
        </div>
        <div className="h-2 overflow-hidden border border-bull-border bg-bull-bg">
          <div
            className={`h-full transition-[width] duration-500 ease-out ${hpInk}`}
            style={{ width: `${hpPct}%` }}
          />
        </div>
        <p className="mt-1 truncate font-mono text-xs text-bull-text-faint">
          <span className={tierTextClass(fighter.tier)}>{tierLabel(fighter.tier)}</span>
          {' · '}
          <span aria-hidden className="mr-1">
            {fighter.glyph}
          </span>
          {fighter.weaponLabel}
          {fighter.weapon && ` · dmg ${fighter.weapon.damageMin}-${fighter.weapon.damageMax}`}
        </p>
      </div>
    </div>
  );
}

// ─── the projectile ───────────────────────────────────────────────────

/**
 * What a ranged bull throws. Three shapes for the five ranged slots: a bolt
 * for the Bolter, a spinning ring for the Ring (`WEAPON_KIND` calls it a
 * boomerang, so it comes back), and a fletched shaft for everything else.
 *
 * Inks are Tailwind `fill-*` classes off the site palette, so there is no hex
 * in here and a reskin carries it.
 */
function ShotSprite({ kind, flip }: { kind: ShotKind; flip: boolean }) {
  if (kind === 'ring') {
    return (
      <svg
        width="18"
        height="18"
        viewBox="0 0 18 18"
        className="animate-shot-spin drop-shadow-[0_0_3px_rgba(0,0,0,0.9)]"
        aria-hidden
      >
        <circle cx="9" cy="9" r="6" fill="none" className="stroke-bull-gold" strokeWidth="3" />
      </svg>
    );
  }
  const bolt = kind === 'bolt';
  const len = bolt ? 34 : 48;
  return (
    <svg
      width={len}
      height="10"
      viewBox={`0 0 ${len} 10`}
      style={{ transform: flip ? 'scaleX(-1)' : undefined }}
      className="drop-shadow-[0_0_3px_rgba(0,0,0,0.9)]"
      aria-hidden
    >
      {/* fletching */}
      <rect x="0" y="1" width="3" height="3" className="fill-bull-red" />
      <rect x="0" y="6" width="3" height="3" className="fill-bull-red" />
      <rect x="3" y="3" width="3" height="4" className="fill-bull-red" />
      {/* shaft */}
      <rect
        x="6"
        y="4"
        width={len - 14}
        height="2"
        className={bolt ? 'fill-bull-border' : 'fill-bull-gold'}
      />
      {/* head */}
      <polygon points={`${len - 8},1 ${len},5 ${len - 8},9`} className="fill-bull-text" />
    </svg>
  );
}
