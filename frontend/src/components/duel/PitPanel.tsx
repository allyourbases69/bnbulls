'use client';

import { useMemo } from 'react';
import Link from 'next/link';
import { PIT } from '@/lib/brand';
import { formatCountdown, formatDuration } from '@/lib/format';
import {
  useEjectDelay,
  useNowSeconds,
  usePitStatus,
  usePitWrites,
  type PitStatus,
} from '@/lib/hooks/useYards';
import type { RosterBull } from '@/lib/hooks/useRoster';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { NotDeployed } from '@/components/shared/NotDeployed';

/**
 * THE ONE BUTTON THAT SENDS THE TICKED BULLS IN, FOR STEP 2 OF THE FLOW.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHY THE ENTRY LEG WAS SPLIT OUT OF THE PANEL BELOW
 * ═══════════════════════════════════════════════════════════════════════
 * Step 2 used to render the WHOLE of `PitPanel` — two bulk buttons, a row per
 * bull with a button each, the eject rules and the full pit roster — in the
 * middle of the money controls. Owner, 2026-08-07: *"the buttons and approvals
 * it's all just a bloody mess bro."* He is right, and fefers does not do that:
 * its step 2 carries ONE primary button and its eject controls live in their own
 * collapsible section further down the page.
 *
 * So this is step 2's button and nothing else. It enters exactly the ids it is
 * handed — the bulls the player ticked in step 1 that the pit says cannot be
 * matched right now — and the management panel below keeps the per-bull and
 * bulk controls for the section at the bottom.
 *
 * ⚠ RE-ENTERING A LEAVING BULL IS A FEATURE, NOT AN ACCIDENT. `Yards.enter`
 * writes `leavesAt: 0` unconditionally, so a bull counting down that gets sent
 * back in has its departure cancelled on the spot. That is why the caller may
 * safely include leaving bulls in `ids`.
 */
export function PitEntryButton({
  ids,
  label,
  note,
  onChanged,
}: {
  /** Bulls to send in. One transaction, however many. */
  ids: readonly number[];
  label: string;
  note?: string;
  onChanged?: () => void;
}) {
  const { wrongNetwork } = useWrongNetwork();
  const writes = usePitWrites(onChanged);

  if (!writes.deployed) {
    return <NotDeployed what={PIT.label} />;
  }

  const busy = writes.isBusy;

  return (
    <div>
      <button
        type="button"
        onClick={() => writes.enter(ids)}
        disabled={busy || wrongNetwork || ids.length === 0}
        // ⚠ `whitespace-normal` OVERRIDES `.bull-btn`'s nowrap on purpose. A
        // full-width button on a 390px phone has about 30 characters before a
        // nowrap label starts pushing the page sideways, and these labels carry
        // a count. Two lines is fine; a horizontally scrolling page is not.
        className="bull-btn w-full whitespace-normal text-center"
      >
        {wrongNetwork
          ? 'wrong network'
          : writes.checking
            ? 'checking it will work…'
            : busy
              ? 'sending them in…'
              : label}
      </button>
      {note && <p className="mt-1.5 font-mono text-[11px] text-bull-text-faint">{note}</p>}
      <WrongNetworkNotice className="mt-3" />
      <RevertNotice error={writes.error} className="mt-3" />
    </div>
  );
}

/**
 * WHO OF YOURS IS IN THE BULL PIT, AND THE TWO BUTTONS THAT MOVE THEM.
 *
 * ⚠ THIS IS THE BOTTOM-OF-PAGE MANAGEMENT SECTION NOW, not a block inside step
 * 2. Fefers ranks the same thing the same way: its "eject status" panel is its
 * own collapsible section under the fight flow, because it is the way back OUT
 * and it is the only control on the page that does not need a fight set up to
 * be useful. Step 2's own entry leg is `PitEntryButton` above.
 *
 * Owner, 2026-08-07: "people need to be able to EJECT their individual bulls or
 * all their bulls from the bull pit, yes make those buttons as well." Both, and
 * the same both on the way in — `Yards.enter`/`eject` each take `uint256[]`, so
 * one bull is a one-element array and "all of mine" is the whole list in a
 * single transaction.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE THING THIS PANEL EXISTS TO GET RIGHT: EJECT IS DELAYED.
 * ═══════════════════════════════════════════════════════════════════════
 * `eject` stamps `leavesAt = now + ejectDelay` and the bull KEEPS FIGHTING
 * until it passes. So an ejected bull renders as a live countdown that says, in
 * words, that a fight signed before the eject can still land — never as "done",
 * never as a bull that has left. Anything softer is a lie the contract will
 * contradict at the worst possible moment, on somebody's loss.
 *
 * The delay is the anti-dodge bound, not caution: a duel settles on a signed
 * result, BSC's mempool is public, and an instant eject would let the losing
 * side yank the bull out from under a loss they can already see. See
 * `useYards.ts` and `Yards.sol`'s header for the full argument.
 *
 * ⚠ THE COUNTDOWN'S NUMBER IS READ, NOT WRITTEN HERE. `ejectDelay` is
 * owner-settable inside a bounded range; the copy says "the wait" and the
 * figure comes off `Yards.ejectDelay()`. Nothing on this panel hardcodes
 * a duration — the deployed value and the source differ right now, which is
 * exactly why.
 */
export function PitPanel({
  bulls,
  onChanged,
}: {
  /** The connected wallet's LIVING bulls. Dead ones cannot fight either way. */
  bulls: readonly RosterBull[];
  /** Fired once a write has confirmed, so the page above can re-read. */
  onChanged?: () => void;
}) {
  const ids = useMemo(() => bulls.map((b) => b.id), [bulls]);
  const owners = useMemo(() => new Map(bulls.map((b) => [b.id, b.owner as string])), [bulls]);
  const nameOf = useMemo(() => new Map(bulls.map((b) => [b.id, b.name])), [bulls]);

  const pit = usePitStatus(ids, owners);
  const { seconds: ejectDelay } = useEjectDelay();
  const { wrongNetwork } = useWrongNetwork();

  const writes = usePitWrites(() => {
    pit.refetch();
    onChanged?.();
  });

  // Only tick a clock when something is actually counting down.
  const now = useNowSeconds(pit.leavingIds.length > 0);

  if (!pit.deployed) {
    return <NotDeployed what={PIT.label} className="mt-3" />;
  }
  if (bulls.length === 0) {
    return <p className="mt-3 text-sm text-bull-text-dim">{PIT.emptyWallet}</p>;
  }
  if (pit.isLoading) {
    return <p className="mt-3 text-sm text-bull-text-dim">{PIT.loading}</p>;
  }
  if (pit.unavailable) {
    return (
      <div className="mt-3 text-sm text-bull-text-dim">
        <p>{PIT.unreadable}</p>
        <button
          type="button"
          onClick={() => pit.refetch()}
          className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
        >
          try again
        </button>
      </div>
    );
  }

  const inIds = pit.inIds;
  const outIds = pit.outIds;
  const leavingIds = pit.leavingIds;
  // ⚠ "Pull them all out" must not include a bull that is already on its way
  // out. `Yards.eject` refuses to push an existing, earlier departure back, so
  // including them changes nothing on chain — but it would make the button
  // count bulls it is not going to move, and a button that overstates what it
  // did is how a player concludes the eject "didn't work".
  const ejectableIds = inIds.filter((id) => !leavingIds.includes(id));
  const busy = writes.isBusy;
  const disabled = busy || wrongNetwork;

  return (
    <div>
      {/* ⚠ NO TITLE ROW. The collapsible section this sits in is titled "your
          herd in the bull pit" already, and a panel that repeats its own
          container's heading is how a page ends up looking like it was built by
          two people who never spoke. The counts are the part worth keeping. */}
      <p className="text-right font-mono text-[11px] text-bull-text-faint">
        {inIds.length} in · {outIds.length} out
        {leavingIds.length > 0 ? ` · ${leavingIds.length} leaving` : ''}
      </p>

      {/* ── THE BULK CONTROLS ─────────────────────────────────────── */}
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button
          type="button"
          onClick={() => writes.enter(outIds.length > 0 ? outIds : ids)}
          disabled={disabled || (outIds.length === 0 && leavingIds.length === 0)}
          className="rounded-full border border-bull-gold bg-bull-gold px-3 py-1.5 text-xs font-semibold text-bull-gold-ink transition disabled:cursor-not-allowed disabled:opacity-40"
        >
          {wrongNetwork
            ? 'wrong network'
            : busy && writes.action?.kind === 'enter'
              ? 'sending them in…'
              : `${PIT.enterAllCta}${outIds.length > 0 ? ` (${outIds.length})` : ''}`}
        </button>
        <button
          type="button"
          onClick={() => writes.eject(ejectableIds)}
          disabled={disabled || ejectableIds.length === 0}
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim transition hover:border-bull-red hover:text-bull-red disabled:cursor-not-allowed disabled:opacity-40"
        >
          {wrongNetwork
            ? 'wrong network'
            : busy && writes.action?.kind === 'eject'
              ? 'stamping the eject…'
              : `${PIT.ejectAllCta}${ejectableIds.length > 0 ? ` (${ejectableIds.length})` : ''}`}
        </button>
      </div>

      <WrongNetworkNotice className="mt-3" />

      <RevertNotice error={writes.error} className="mt-3" />

      {/* ── ONE ROW PER BULL, EACH WITH ITS OWN BUTTON ───────────── */}
      <ul className="mt-3 divide-y divide-bull-border rounded border border-bull-border bg-bull-bg">
        {bulls.map((b) => (
          <PitRow
            key={b.id}
            id={b.id}
            name={nameOf.get(b.id) ?? ''}
            status={pit.byId.get(b.id)}
            now={now}
            disabled={disabled}
            busyHere={busy && !!writes.action?.ids.includes(b.id)}
            onEnter={() => writes.enter([b.id])}
            onEject={() => writes.eject([b.id])}
          />
        ))}
      </ul>

      {/* ⚠ `PitRoster` USED TO RENDER HERE AND IT HAS MOVED, NOT GONE. Owner,
          2026-08-07: *"the roster of all of them waiting should be at bottom."*
          It is the browse-the-field surface, not a step in the fight, so it is
          its own section at the foot of the page — the same rank fefers gives
          "Waiting in the stomping ground". See `DuelPicker`. */}

      {/* ── THE RULES, IN THE ORDER THEY BITE ─────────────────────── */}
      <div className="mt-3 space-y-1.5 text-[11px] text-bull-text-faint">
        <p>{PIT.rule}</p>
        <p>{PIT.enterInstant}</p>
        <p>
          {PIT.ejectDelayed}
          {ejectDelay !== undefined && (
            <>
              {' '}
              right now the wait is{' '}
              <span className="text-bull-text-dim">{formatDuration(ejectDelay)}</span>.
            </>
          )}
        </p>
        <p>{PIT.ejectImmediate}</p>
        <p>{PIT.reenterCancels}</p>
      </div>

      <details className="mt-3">
        <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
          why pulling one out takes a while
        </summary>
        <p className="mt-2 text-[11px] text-bull-text-faint">{PIT.ejectWhy}</p>
        <p className="mt-2 text-[11px] text-bull-text-faint">{PIT.saleVoidsEntry}</p>
      </details>
    </div>
  );
}

/**
 * One bull. Four states and they are genuinely different, so none of them is
 * allowed to borrow another's words:
 *
 *   in        · fightable, staying           -> offer eject
 *   leaving   · fightable, counting down     -> offer "send back in" (cancels)
 *   never/out · not fightable                -> offer enter
 *   sold      · not fightable, entry voided  -> offer enter, and SAY WHY
 */
function PitRow({
  id,
  name,
  status,
  now,
  disabled,
  busyHere,
  onEnter,
  onEject,
}: {
  id: number;
  name: string;
  status: PitStatus | undefined;
  now: number;
  disabled: boolean;
  busyHere: boolean;
  onEnter: () => void;
  onEject: () => void;
}) {
  // ⚠ An unread row says so. It must not default to "out": that would offer an
  // enter transaction for a bull that is already in, and read as the contract
  // having lost the entry.
  if (!status) {
    return (
      <li className="flex items-center gap-3 px-3 py-2 font-mono text-xs">
        <span className="text-bull-text-faint">#{id}</span>
        <span className="truncate text-bull-text">{name.toLowerCase()}</span>
        <span className="ml-auto text-bull-text-faint">status unread</span>
      </li>
    );
  }

  const secondsLeft = status.leaving ? Math.max(0, status.leavesAt - now) : 0;

  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2">
      <span className="font-mono text-xs text-bull-text-faint">#{id}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-xs text-bull-text">
        {name.toLowerCase()}
      </span>

      {status.leaving ? (
        <span className="font-mono text-[11px] text-bull-gold">
          {PIT.leavingLabel} in {formatCountdown(secondsLeft)}
        </span>
      ) : status.inPit ? (
        <span className="font-mono text-[11px] text-bull-gold">✓ {PIT.inLabel}</span>
      ) : (
        <span className="font-mono text-[11px] text-bull-text-faint">{PIT.outLabel}</span>
      )}

      {status.inPit && !status.leaving ? (
        <button
          type="button"
          onClick={onEject}
          disabled={disabled}
          className="rounded-full border border-bull-border px-2.5 py-1 text-[11px] text-bull-text-dim transition hover:border-bull-red hover:text-bull-red disabled:cursor-not-allowed disabled:opacity-40"
        >
          {busyHere ? 'stamping…' : 'eject'}
        </button>
      ) : (
        <button
          type="button"
          onClick={onEnter}
          disabled={disabled}
          className="rounded-full border border-bull-gold px-2.5 py-1 text-[11px] font-medium text-bull-gold transition disabled:cursor-not-allowed disabled:opacity-40"
        >
          {busyHere ? 'sending…' : status.leaving ? 'keep him in' : 'send in'}
        </button>
      )}

      {/* The per-state footnote. One line, under the row, only where the state
          needs explaining. */}
      {/* ⚠ THE GOOD HALF FIRST. On its own `ejectPending` reads as "your bull
          is still up for grabs until the countdown ends", which is not true and
          is how the owner read it. Nothing new can be matched against it from
          the moment the eject confirms — the countdown only keeps already-signed
          fights alive. Lead with what he actually wanted to hear. */}
      {status.leaving && (
        <p className="w-full text-[11px] text-bull-text-faint">
          {PIT.ejectImmediate} {PIT.ejectPending}
        </p>
      )}
      {status.reason === 'sold' && (
        <p className="w-full text-[11px] text-bull-text-faint">
          this one changed hands, and a sale voids the old entry. send it in and it fights again.
        </p>
      )}
    </li>
  );
}

/**
 * The buyer-facing version of the same fact, for the marketplace.
 *
 * ⚠ THIS IS NOT DUPLICATION FOR ITS OWN SAKE. `Yards` membership requires
 * `enteredBy == the live owner`, so a purchase silently takes the bull out of
 * the pit with no event and nothing on the token to show it. A buyer who is
 * never told this owns a bull that looks fightable, cannot be matched, and
 * reverts `BullNotInYards` if anybody tries. It has already cost us a
 * debugging session on testnet, so it goes where a buyer will read it.
 */
export function PitSaleNotice({ className }: { className?: string }) {
  return (
    <p className={`text-xs text-bull-text-faint ${className ?? ''}`}>
      {PIT.saleVoidsEntry}{' '}
      <Link href="/duel" className="text-bull-gold hover:underline">
        {PIT.label} →
      </Link>
    </p>
  );
}
