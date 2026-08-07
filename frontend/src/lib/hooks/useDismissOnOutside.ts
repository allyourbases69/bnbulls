'use client';

import { useEffect, useRef, type RefObject } from 'react';

/** Why the popup was dismissed, for callers that restore focus differently. */
export type DismissReason = 'outside' | 'escape';

/**
 * "Close this popup when the player clicks off it, or hits escape."
 *
 * Returns a ref to attach to the popup's ROOT — and the root must wrap **both
 * the trigger and the panel**, which is the whole trick. Three things that
 * naive versions of this get wrong, and why each is handled the way it is:
 *
 * 1. ⚠ **AN INSIDE CLICK MUST NOT CLOSE IT.** The bnbulls fighter dropdown is a
 *    multi-select — ticking five bulls sends five in — so a handler that closes
 *    on any document click silently destroys the feature it is decorating: the
 *    panel vanishes after the first tick and the player can only ever queue one
 *    bull. `root.contains(target)` is the guard, and it covers the rows, the
 *    checkboxes, their labels and the panel's own scrollbar (a scrollbar
 *    mousedown targets the scrolling element itself, which is inside the root).
 *
 * 2. ⚠ **THE TRIGGER MUST TOGGLE, NOT DOUBLE-FIRE.** This is the classic
 *    open-then-instantly-close bug: a document listener closes the panel on the
 *    trigger's own press, then the button's `onClick` re-opens it (or the other
 *    way round) and the control looks dead. Keeping the trigger INSIDE the ref'd
 *    root means a press on it is an *inside* press, this hook stays out of the
 *    way, and the button's own `onClick` is the single source of the toggle.
 *
 * 3. ⚠ **`pointerdown`, NOT `click`.** It fires before focus moves and before
 *    the pressed thing can be re-rendered out from under the event, so the
 *    `contains` check is evaluated against the DOM as the player actually saw
 *    it. `click` would also miss a drag that starts outside, and `blur` — the
 *    other tempting shortcut — fires on every focus move *within* the panel,
 *    which is failure mode 1 again with extra steps.
 *
 * Listeners are only bound while `enabled`, and always removed on unmount or
 * when it goes false. They are bound in the CAPTURE phase so a child that calls
 * `stopPropagation` cannot wedge the popup permanently open.
 */
export function useDismissOnOutside<T extends HTMLElement>(
  enabled: boolean,
  onDismiss: (reason: DismissReason) => void,
): RefObject<T | null> {
  const ref = useRef<T>(null);

  // The callback is read through a ref so the listeners are subscribed once per
  // open, not re-subscribed on every parent render. Re-subscribing mid-gesture
  // is how handlers like this end up missing the very press that should close
  // them.
  const onDismissRef = useRef(onDismiss);
  useEffect(() => {
    onDismissRef.current = onDismiss;
  });

  useEffect(() => {
    if (!enabled) return;

    function handlePointerDown(event: PointerEvent) {
      const root = ref.current;
      const target = event.target;
      if (!root || !(target instanceof Node)) return;
      // INSIDE: leave it open. Ticking boxes is the point of the control.
      if (root.contains(target)) return;
      onDismissRef.current('outside');
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') onDismissRef.current('escape');
    }

    document.addEventListener('pointerdown', handlePointerDown, true);
    document.addEventListener('keydown', handleKeyDown, true);
    return () => {
      document.removeEventListener('pointerdown', handlePointerDown, true);
      document.removeEventListener('keydown', handleKeyDown, true);
    };
  }, [enabled]);

  return ref;
}
