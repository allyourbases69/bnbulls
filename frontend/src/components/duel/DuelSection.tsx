'use client';

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';

/**
 * A FOLDABLE SECTION OF THE DUEL PAGE, AND THE MEMORY THAT KEEPS IT FOLDED.
 *
 * ⚠ PORTED FROM FEFERS' `CollapsibleSection`, off the live `app/frontend/src/
 * app/duel/page.tsx`. Owner, 2026-08-07: *"you could collapse each section in
 * fefers… ours is one long unfoldable wall."* Same shape: a clickable header row
 * (title left, an optional count right, a chevron) over a body that folds away.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE BODY IS HIDDEN, NEVER UNMOUNTED. THIS IS LOAD-BEARING.
 * ═══════════════════════════════════════════════════════════════════════
 * Folding a section away must not throw anything inside it out. The fight flow
 * holds a signed quote, an in-flight transaction hash and a receipt watcher, and
 * unmounting it mid-fight would orphan the receipt the page is waiting on and
 * lose the fight the player is watching. So `open` toggles a `hidden` class and
 * nothing else, exactly as fefers does it — and `hidden` (the prop) drops the
 * whole section from view while STILL keeping its child mounted, so a panel that
 * reports its own emptiness upward can flip its section on the moment it has
 * something to show.
 *
 * ⚠ IT REMEMBERS WITHIN A SESSION, NOT FOREVER. Owner: *"sections should
 * remember their state within a session."* `sessionStorage`, so a reload or a
 * hop to /mint and back keeps the page the way it was left, and a new tab
 * tomorrow starts from the defaults rather than from a fold somebody made once.
 *
 * ⚠ THE STORED STATE IS READ AFTER MOUNT, NOT DURING RENDER. Reading it in the
 * `useState` initialiser would make the client's first paint disagree with the
 * server's markup — a hydration mismatch on every `aria-expanded` on the page.
 * The defaults paint, then the saved state lands.
 */

export function DuelSection({
  id,
  title,
  meta,
  open,
  onOpenChange,
  hidden = false,
  children,
}: {
  /** Also the dom id, so a link or a scroll can find it. */
  id: string;
  title: string;
  /** A quiet count on the right of the header. Readable while folded. */
  meta?: ReactNode;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Nothing to show at all: no header, no body, child still mounted. */
  hidden?: boolean;
  children: ReactNode;
}) {
  const headingId = `${id}-heading`;
  const bodyId = `${id}-body`;

  return (
    <section
      id={id}
      className={hidden ? 'hidden' : 'scroll-mt-24'}
      aria-hidden={hidden || undefined}
    >
      {!hidden && (
        <button
          type="button"
          id={headingId}
          aria-expanded={open}
          aria-controls={bodyId}
          onClick={() => onOpenChange(!open)}
          className="flex w-full items-center justify-between gap-3 rounded border border-bull-border bg-bull-panel px-4 py-3 text-left transition hover:border-bull-gold/50"
        >
          <span className="bull-header shrink-0 text-sm lowercase text-bull-gold">{title}</span>
          <span className="flex min-w-0 items-center gap-3">
            {/* ⚠ `min-w-0` ON THE TRUNCATING SPAN ITSELF, not just its parent. A
                flex item defaults to `min-width: auto`, so `truncate` alone does
                nothing to it — it refuses to shrink and pushes the chevron off a
                phone instead. Bull names on this project run to "the marquess of
                wrenfield-harkaway", so this is a real width, not a hypothetical. */}
            {meta !== undefined && (
              <span className="min-w-0 truncate font-mono text-[11px] text-bull-text-faint">
                {meta}
              </span>
            )}
            <span
              aria-hidden
              className={`shrink-0 text-xs text-bull-gold transition-transform motion-reduce:transition-none ${
                open ? 'rotate-180' : ''
              }`}
            >
              ▾
            </span>
          </span>
        </button>
      )}
      <div
        id={bodyId}
        role="region"
        aria-labelledby={headingId}
        className={!hidden && open ? 'mt-3' : 'hidden'}
      >
        {children}
      </div>
    </section>
  );
}

/**
 * The open/closed map for one page's worth of sections, remembered for the
 * session.
 *
 * ⚠ THE WRITE HAPPENS IN THE SETTER, NOT IN AN EFFECT, AND THAT IS DELIBERATE.
 * An effect keyed on the state would run once on mount — in the SAME commit as
 * the loader below, before the loaded value has landed — and write the defaults
 * straight over what was saved. The setter only ever runs from a click, which is
 * safely outside render and cannot race the load.
 */
export function useDuelSectionState<Id extends string>(
  storageKey: string,
  defaults: Readonly<Record<Id, boolean>>,
): { open: Record<Id, boolean>; setSection: (id: Id, open: boolean) => void } {
  const [open, setOpen] = useState<Record<Id, boolean>>(() => ({ ...defaults }));
  const openRef = useRef(open);
  openRef.current = open;

  useEffect(() => {
    if (typeof window === 'undefined') return;
    let saved: Partial<Record<Id, boolean>>;
    try {
      const raw = window.sessionStorage.getItem(storageKey);
      if (!raw) return;
      saved = JSON.parse(raw) as Partial<Record<Id, boolean>>;
    } catch {
      // private mode, quota, or somebody's hand-edited json. The defaults are
      // a perfectly good page; they are just not the one that was left behind.
      return;
    }
    setOpen((prev) => {
      let changed = false;
      const next = { ...prev };
      for (const key of Object.keys(prev) as Id[]) {
        const v = saved[key];
        if (typeof v === 'boolean' && v !== next[key]) {
          next[key] = v;
          changed = true;
        }
      }
      if (!changed) return prev;
      openRef.current = next;
      return next;
    });
  }, [storageKey]);

  const setSection = useCallback(
    (id: Id, v: boolean) => {
      if (openRef.current[id] === v) return;
      const next = { ...openRef.current, [id]: v };
      openRef.current = next;
      setOpen(next);
      try {
        window.sessionStorage.setItem(storageKey, JSON.stringify(next));
      } catch {
        /* it still folds, it just will not be folded next time */
      }
    },
    [storageKey],
  );

  return { open, setSection };
}
