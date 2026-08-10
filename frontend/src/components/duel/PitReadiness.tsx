'use client';

import type { ReactNode } from 'react';
import { READY } from '@/lib/brand';
import { BnbAmount, bnbLabel } from '@/components/duel/BnbAmount';
import type { FightBalance } from '@/lib/hooks/useFightBalance';

/** The size the away rungs quote themselves at when there is nothing of the
 *  player's own to report. Matches `FightBalanceRow`'s suggested budget, so the
 *  figure a first-timer reads here is the figure the control below defaults to
 *  rather than a second, differently-sized guess. */
const EXAMPLE_FIGHTS = 5;

/**
 * THE LADDER. WHERE A PLAYER IS UP TO, AND WHAT EACH RUNG COSTS.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHY THIS COMPONENT EXISTS — READ BEFORE CHANGING THE RUNGS.
 * ═══════════════════════════════════════════════════════════════════════
 * Moving the bnb leg from an allowance to native custody turned one signature
 * into three separate jobs, and the page went on presenting them as scattered
 * controls rather than a sequence:
 *
 *   `Yards.enter`                       · gas only, and NOTHING fights without it
 *   `DuelNative.deposit`                · real bnb, for fights you did not start
 *   `DuelNative.setPassiveAllowance`    · DEFAULTS TO ZERO
 *
 * The third is the one that hurt. A wallet does the first two, sees its money on
 * screen, and every incoming fight is refused `PassiveAllowanceExceeded` with
 * nothing anywhere to explain it — a run of "cannot be fought" reports in the
 * telegram group, all from the same silent half-configured state. So the rungs
 * are rendered AS rungs, each with its own live state, and a wallet with money
 * parked behind a zero budget is told out loud that it is not finished.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠⚠ AND IT MUST NOT RE-TEACH THE LIE THE LAST FIX REMOVED.
 * ═══════════════════════════════════════════════════════════════════════
 * Starting your own fight needs NEITHER of the bottom two rungs. `_takeSide`
 * spends `msg.value` first and only falls through to the ledger when the
 * submitter attached nothing (or not enough), so the amount rides along with the
 * transaction for anybody actually at the keyboard. Six mainnet wallets once
 * signed for setup they never needed because a control in the primary slot read
 * as the price of entry. Hence TWO NAMED GROUPS: what lets you fight, and what
 * lets others fight your bulls. The second group carries "optional" in its own
 * heading, not in a footnote underneath it.
 *
 * ⚠ EVERY FIGURE IS LIVE AND EVERY UNREAD FIGURE IS A DASH. `BnbAmount` owns
 * that rule; nothing here may format an amount itself. A rung whose reads have
 * not landed renders `unread`, which is deliberately NOT the same badge as "you
 * have not done it" — those send a player to two different places.
 */

/**
 * ⚠ FIVE STATES, AND `unread` IS NOT `todo`. The brief asks for done / needs
 * doing / not applicable; the other two are what honesty about chain reads
 * costs. `urgent` is reserved for the one state where the player has already
 * spent money that is doing nothing.
 */
type RungState = 'done' | 'todo' | 'urgent' | 'unread' | 'waiting';

interface Rung {
  readonly key: string;
  readonly title: string;
  readonly state: RungState;
  /** The live figure, right-aligned. A node so it can be a dash, a price, or a
   *  plain word like "gas only" for a rung that takes no bnb. ⚠ NEVER EMPTY:
   *  a blank cell beside three priced ones reads as a figure that failed. */
  readonly figure: ReactNode;
  /** One sentence. What this rung is and what happens without it. */
  readonly line: string;
  /** Offered only where the rung is outstanding. */
  readonly action?: ReactNode;
}

/** The badge, straight off `DuelFlowStep`'s rule: exactly one filled badge on
 *  screen, and it is the thing to do next. */
function RungBadge({ state, n, isNext }: { state: RungState; n: number; isNext: boolean }) {
  const cls =
    state === 'done'
      ? 'border-bull-gold text-bull-gold'
      : state === 'urgent'
        ? 'border-bull-red bg-bull-red text-bull-text'
        : isNext
          ? 'border-bull-gold bg-bull-gold text-bull-gold-ink'
          : 'border-bull-border text-bull-text-faint';
  return (
    <span
      aria-hidden="true"
      className={`mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border-2 font-mono text-[10px] ${cls}`}
    >
      {state === 'done' ? '✓' : state === 'urgent' ? '!' : state === 'unread' ? '?' : n}
    </span>
  );
}

/**
 * The state, in words, for a screen reader.
 *
 * ⚠ `waiting` HAS TWO CAUSES AND THEY NEED DIFFERENT WORDS. No wallet is "go
 * and connect one"; a connected wallet holding no bulls has genuinely nothing to
 * do on this rung yet, and telling that player to connect a wallet they already
 * connected is the kind of small wrongness that makes people stop trusting the
 * rest of the panel.
 */
function stateWord(state: RungState, connected: boolean): string {
  switch (state) {
    case 'done':
      return READY.done;
    case 'unread':
      return READY.unread;
    case 'waiting':
      return connected ? READY.notYet : READY.connect;
    default:
      return READY.todo;
  }
}

function RungRow({
  rung,
  n,
  isNext,
  connected,
}: {
  rung: Rung;
  n: number;
  isNext: boolean;
  connected: boolean;
}) {
  return (
    <li className="grid grid-cols-[1.25rem_1fr] gap-x-2.5 gap-y-1 px-3 py-2.5">
      <RungBadge state={rung.state} n={n} isNext={isNext} />
      {/* ⚠ THE TITLE AND THE FIGURE SHARE A WRAPPING ROW, NOT A FIXED TWO-COLUMN
          GRID. On a 390px phone a title plus "0.033200 bnb ≈ $20.10" does not
          fit on one line, and a fixed grid would either clip the figure or push
          the page sideways. Wrapping puts the money on its own line instead,
          which is the one thing on the row that must never be cut off. */}
      <div className="flex min-w-0 flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
        <span
          className={`bull-header text-xs lowercase ${
            rung.state === 'done' ? 'text-bull-text-dim' : 'text-bull-text'
          }`}
        >
          {rung.title}
        </span>
        <span className="font-mono text-[11px]">{rung.figure}</span>
      </div>
      {/* ⚠ `text-bull-text-dim`, NOT `-faint`, AND THAT IS A DELIBERATE BREAK
          FROM THE SMALL-PRINT DEFAULT. These sentences are the only place the
          game explains itself to a first-timer, and the step around them is
          rendered at 60% opacity while it is not actionable — faint on top of
          dimmed is a paragraph nobody reads on a phone in daylight. Footnotes
          stay faint; the explanation does not. */}
      <p
        className={`col-start-2 text-[11px] ${
          rung.state === 'urgent' ? 'text-bull-gold' : 'text-bull-text-dim'
        }`}
      >
        {rung.line}
      </p>
      {rung.action && <div className="col-start-2 pt-1">{rung.action}</div>}
      <span className="sr-only">{stateWord(rung.state, connected)}</span>
    </li>
  );
}

function GroupHeading({ children }: { children: ReactNode }) {
  return (
    <p className="border-b border-bull-border bg-bull-bg/60 px-3 py-1.5 font-mono text-[10px] uppercase tracking-wide text-bull-text-faint">
      {children}
    </p>
  );
}

export function PitReadiness({
  connected,
  hasBulls,
  pitState,
  inPitCount,
  herdCount,
  balance,
  decimals,
  usdPerBnb,
  /** The bnb leg's custody controls apply. False on the bnbull leg and before
   *  the native cutover, where the bottom group describes nothing that exists. */
  awayApplies,
  onOpenAway,
}: {
  connected: boolean;
  hasBulls: boolean;
  /** ⚠ THREE-VALUED, LIKE `usePitPool`. `unread` must never render as "out": a
   *  membership read that has not answered is not a bull that is not in. */
  pitState: 'in' | 'out' | 'unread';
  inPitCount: number;
  herdCount: number;
  balance: FightBalance;
  decimals: number | undefined;
  usdPerBnb: bigint | undefined;
  awayApplies: boolean;
  /**
   * Unfolds and scrolls to the money panel below.
   *
   * ⚠ THE ONLY ACTION THIS LADDER IS ALLOWED TO OFFER IS A JUMP, NEVER A
   * TRANSACTION. Rung one deliberately carries no button even though it is the
   * one thing that blocks every fight: step 2's primary button already signs
   * exactly that transaction, a few lines below, and two buttons asking for one
   * signature is the clutter the flow was restructured to remove. A ladder is a
   * map, and a map with its own steering wheel is two steering wheels.
   */
  onOpenAway?: () => void;
}) {
  const jump = (label: string) =>
    onOpenAway ? (
      <button
        type="button"
        onClick={onOpenAway}
        className="rounded-full border border-bull-gold px-3 py-1 font-mono text-[11px] text-bull-gold transition hover:bg-bull-gold/10"
      >
        {label}
      </button>
    ) : undefined;

  const rungs: Rung[] = [];

  // ── rung 1 · the pit. Blocks everything, so it is always first. ────
  rungs.push({
    key: 'pit',
    title: READY.pitTitle,
    state: !connected || !hasBulls ? 'waiting' : pitState === 'unread' ? 'unread' : pitState === 'in' ? 'done' : 'todo',
    figure: <span className="text-bull-text-faint">{READY.pitFree}</span>,
    line:
      connected && hasBulls && pitState === 'in'
        ? `${inPitCount} of your ${herdCount} in the pit.`
        : READY.pitLine,
  });

  // ── rung 2 · bnb in the wallet. NOT a contract call, and still a real
  //    blocker: `/api/run-duel` refuses a submitter whose wallet cannot cover
  //    the value AND whose ledger cannot either. Saying so here beats
  //    discovering it inside a failed quote.
  const walletShort =
    balance.nativeBalance !== undefined &&
    balance.perFight !== undefined &&
    balance.perFight > 0n &&
    balance.nativeBalance < balance.perFight;
  rungs.push({
    key: 'wallet',
    title: READY.walletTitle,
    state: !connected
      ? 'waiting'
      : balance.nativeBalance === undefined || balance.perFight === undefined
        ? 'unread'
        : walletShort
          ? 'todo'
          : 'done',
    figure: <BnbAmount wei={balance.nativeBalance} decimals={decimals} usdPerBnb={usdPerBnb} />,
    line: walletShort ? READY.walletShort : READY.walletLine,
  });

  if (awayApplies) {
    /**
     * ⚠⚠ WITHOUT A PRICE, NOTHING DOWN HERE CAN BE JUDGED, AND THIS GUARD IS
     * THE FIX FOR A REAL BUG THAT SHIPPED FOR ABOUT AN HOUR.
     *
     * Both away rungs are answers to "is this enough", and enough is measured in
     * fights. `useFightBalance` derives `cannotCoverOne` and `fightsCovered`
     * from `perFight`, and when the oracle refuses to quote it floors them to
     * "no" and "0" — so a balance with real bnb in it rendered as a ticked-off
     * rung reading "covers 0 away fights". Both halves of that are wrong at
     * once: it is not done, and we do not know what it covers.
     *
     * An unread price is therefore an unread RUNG, which is the same rule the
     * pit membership already follows. Not knowing and being finished are not
     * the same state and must not share a badge.
     */
    const pricedLeg = balance.perFight !== undefined && balance.perFight > 0n;

    /**
     * ⚠ AN EMPTY RUNG STILL HAS TO ANSWER "HOW MUCH". A player who has put
     * nothing in yet gets a dash in the figure column, which is honest about
     * their balance and completely useless as an answer to the only question
     * they have. So the SENTENCE carries a worked example at the same size the
     * control below defaults to — live, off `perFight`, and simply absent when
     * the price has not been read rather than filled in with a zero.
     */
    const example = balance.perFight !== undefined && balance.perFight > 0n
      ? balance.perFight * BigInt(EXAMPLE_FIGHTS)
      : undefined;
    const exampleLine =
      example === undefined
        ? ''
        : ` ${EXAMPLE_FIGHTS} fights' worth is ${bnbLabel(example, decimals, usdPerBnb)}.`;

    // ── rung 3 · the fight balance ───────────────────────────────────
    rungs.push({
      key: 'balance',
      title: READY.balanceTitle,
      state: !connected
        ? 'waiting'
        : balance.credit === undefined || !pricedLeg
          ? 'unread'
          : balance.cannotCoverOne
            ? 'todo'
            : 'done',
      figure: (
        <BnbAmount
          wei={balance.credit}
          decimals={decimals}
          usdPerBnb={usdPerBnb}
          emphasis={balance.hasCredit}
        />
      ),
      line:
        // ⚠ ONLY CLAIM A FIGHT COUNT OFF READS THAT LANDED, AND THAT MEANS THE
        // PRICE AS WELL AS THE BALANCE. `fightsCovered` floors to 0 when either
        // is missing, so "covers 0 away fights" is what an unpriced leg says
        // about a balance that may well be plenty.
        !pricedLeg
          ? READY.balanceLine
          : balance.credit !== undefined && !balance.cannotCoverOne
            ? `covers ${balance.fightsCovered} away fight${balance.fightsCovered === 1 ? '' : 's'}.`
            : balance.credit !== undefined
              ? READY.balanceEmpty + exampleLine
              : READY.balanceLine + exampleLine,
      action:
        connected && pricedLeg && balance.credit !== undefined && balance.cannotCoverOne
          ? jump('put money in')
          : undefined,
    });

    // ── rung 4 · the away budget. THE ONE THAT BITES. ────────────────
    //
    // ⚠ `urgent` IS RESERVED FOR THE TRAP AND NOTHING ELSE. A wallet that has
    // put real bnb in and left the budget at zero is not "not finished yet", it
    // is actively having fights refused against money it has already parked.
    // A wallet that has done neither is simply at the start of an optional
    // ladder and gets the ordinary `todo`.
    const trapped = balance.hasCredit && balance.allowanceUnset;
    rungs.push({
      key: 'budget',
      title: READY.budgetTitle,
      state: !connected
        ? 'waiting'
        : balance.passiveAllowance === undefined
          ? 'unread'
          : trapped
            ? 'urgent'
            : balance.challengeable
              ? 'done'
              : 'todo',
      figure: (
        <BnbAmount
          wei={balance.passiveAllowance}
          decimals={decimals}
          usdPerBnb={usdPerBnb}
          emphasis={trapped}
        />
      ),
      line: trapped
        ? READY.budgetTrap
        : balance.challengeable
          ? `${balance.passiveFightsLeft} away fight${
              balance.passiveFightsLeft === 1 ? '' : 's'
            } left in the budget. it counts down as they happen.`
          : balance.passiveAllowance !== undefined && balance.passiveAllowance === 0n
            ? READY.budgetOff + exampleLine
            : READY.budgetLine + exampleLine,
      action:
        connected && balance.passiveAllowance !== undefined && !balance.challengeable
          ? jump(trapped ? 'switch away fights on' : 'set a budget')
          : undefined,
    });
  }

  const applicable = rungs.filter((r) => r.state !== 'waiting');
  const doneCount = applicable.filter((r) => r.state === 'done').length;
  // ⚠ THE FILLED BADGE IS THE FIRST OUTSTANDING RUNG, and an `unread` one is
  // never it: pointing a player at a rung we have not read yet would send them
  // to sign for something that may already be done.
  const nextKey = rungs.find((r) => r.state === 'todo' || r.state === 'urgent')?.key ?? null;

  const selfCount = awayApplies ? 2 : rungs.length;

  return (
    <div className="rounded border border-bull-border bg-bull-bg">
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 px-3 pb-1 pt-3">
        <h3 className="bull-header text-sm lowercase text-bull-text">{READY.heading}</h3>
        {applicable.length > 0 && (
          <span className="font-mono text-[11px] text-bull-text-faint">
            {READY.progress(doneCount, applicable.length)}
          </span>
        )}
      </div>
      <p className="px-3 pb-3 text-[11px] text-bull-text-dim">{READY.lead}</p>

      <GroupHeading>{READY.groupSelf}</GroupHeading>
      <ul className="divide-y divide-bull-border/60">
        {rungs.slice(0, selfCount).map((r, i) => (
          <RungRow key={r.key} rung={r} n={i + 1} isNext={r.key === nextKey} connected={connected} />
        ))}
      </ul>

      {awayApplies && (
        <>
          <GroupHeading>{READY.groupAway}</GroupHeading>
          <ul className="divide-y divide-bull-border/60">
            {rungs.slice(selfCount).map((r, i) => (
              <RungRow
                key={r.key}
                rung={r}
                n={selfCount + i + 1}
                isNext={r.key === nextKey}
                connected={connected}
              />
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
