'use client';

import type { ReactNode } from 'react';

/**
 * ONE NUMBERED STEP OF THE FIGHT FLOW.
 *
 * ⚠ PORTED FROM FEFERS' `FlowStep`, off the live duel page. A badge, a title, an
 * optional status word hard right, and whatever the step needs underneath.
 *
 *   `active`  · this is the step to act on now
 *   `done`    · satisfied, so the body folds itself to a summary line
 *   `waiting` · visible so the shape of the whole thing is readable, but not
 *               reachable yet
 *   `todo`    · neutral
 *
 * ⚠ A `waiting` STEP IS DIMMED, NEVER HIDDEN. Fefers' own note: a step that
 * vanishes and reappears reads as a bug, and the owner wants to see the shape of
 * the flow on first load. Its contents stay rendered and its buttons stay
 * disabled, so nobody clicks into a dead end either.
 */
export type DuelStepState = 'todo' | 'active' | 'done' | 'waiting';

export function DuelFlowStep({
  n,
  title,
  state,
  status,
  children,
}: {
  n: number;
  title: string;
  state: DuelStepState;
  /** The quiet word on the right: "3 alive in your herd", "step 2 first". */
  status?: string | undefined;
  children?: ReactNode;
}) {
  const done = state === 'done';
  // The active step is the only filled badge on the page, which is what makes
  // "where am i" answerable at a glance.
  const badge = done
    ? 'border-bull-gold text-bull-gold'
    : state === 'active'
      ? 'border-bull-gold bg-bull-gold text-bull-gold-ink'
      : 'border-bull-border text-bull-text-faint';

  return (
    <section
      className={`space-y-3 p-4 ${state === 'waiting' ? 'opacity-60' : ''}`}
      aria-current={state === 'active' ? 'step' : undefined}
    >
      <div className="flex flex-wrap items-center gap-2">
        <span
          aria-hidden="true"
          className={`inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2 font-mono text-[11px] ${badge}`}
        >
          {done ? '✓' : n}
        </span>
        <h2 className="bull-header text-sm lowercase text-bull-text">{title}</h2>
        {status && (
          <span className="ml-auto text-right font-mono text-[11px] text-bull-text-faint">
            {status}
          </span>
        )}
      </div>
      {children}
    </section>
  );
}
