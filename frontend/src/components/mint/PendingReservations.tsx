'use client';

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useQueryClient } from '@tanstack/react-query';
import { useAccount, useReadContract } from 'wagmi';
import { BullPenAbi } from '@/lib/abi';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { PEN, TICKER } from '@/lib/brand';
import { formatToken } from '@/lib/format';
import { NATIVE_BNB_DECIMALS, useTokenDecimals } from '@/lib/hooks/useTokenDecimals';
import {
  RESCUE,
  actionFor,
  useOpenReservations,
  usePen,
  usePenWrites,
  useReservation,
  useUnclaimedBulls,
  useUnclaimedRefund,
  type ReservationView,
} from '@/lib/hooks/usePen';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';

/**
 * "YOU HAVE BULLS ON THE WAY", AND WHEN IT GOES WRONG, "YOUR MONEY HAS BEEN
 * RETURNED" — the two screens that make an asynchronous mint safe to sell.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ WHY THIS IS A SEPARATE, ALWAYS-MOUNTED COMPONENT RATHER THAN A BRANCH OF
 *   THE MINT PANEL
 * ═══════════════════════════════════════════════════════════════════════════
 * Under `BullPen` the mint is two transactions: you pay, and the bulls are
 * drawn and handed over afterwards. Between those two moments the buyer owns
 * nothing an ERC-721 wallet can show them. If the only handle on that window
 * were a `reservationId` the mint panel happened to be holding in memory, then
 * a refresh, a closed tab, a phone that went to sleep, or simply opening the
 * site on a different device would lose it — and the buyer would be left with
 * "I paid and nothing happened", which is indistinguishable, from where they
 * are standing, from being robbed.
 *
 * So this reads `openReservationsOf(you)` and nothing else. It is derived
 * PURELY from the connected address and chain state, which means it survives
 * every one of those, on any device, forever.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ THE MONEY IS ESCROWED IN THE PEN NOW, AND THAT CHANGES WHAT THIS SCREEN IS
 * ═══════════════════════════════════════════════════════════════════════════
 * Payment is held by the pen from `reserve` and only routed onward when the
 * draw settles. So this is no longer just a progress indicator over a delivery
 * — it is the only place a person can see where their money physically is
 * while a draw they cannot influence takes its time.
 *
 * That is why the escrow figure is READ AND SHOWN rather than summarised as
 * "your funds are safe". A promise is worth nothing on this screen; "the pen is
 * holding 0.0234 bnb of yours, here is the contract" is checkable, and it is
 * true in both branches, whether the reservation ends as a bull or as a refund.
 *
 * ⚠ AND IT NEVER PROMISES AN INSTANT REFUND. The refund window is mandatory —
 * refunding before the draw definitively cannot land would race a VRF word and
 * hand somebody both the money and the bull. So the countdown is shown from the
 * start, in blocks, off `reservedAtBlock + refundAfterBlocks`. Telling the
 * player early is the way out of that constraint. Pretending it is instant is
 * not.
 *
 * ⚠ RENDERS ABSOLUTELY NOTHING on the legacy path, with no wallet connected, or
 * with nothing outstanding. It must be safe to mount anywhere.
 */
export function PendingReservations({
  className,
  excludeIds,
}: {
  className?: string;
  /**
   * Reservations the CALLER is already rendering inline, so exactly one screen
   * owns each one.
   *
   * ⚠ THIS IS NOT DEDUPLICATION FOR TIDINESS. The mint panel mounts this banner
   * AND shows the reservation it just created directly under the mint button,
   * which is where the buyer is looking. Rendering both would put two copies of
   * "your money has been returned" on one page, and a person who is already
   * worried about their money reads two notices as two problems.
   */
  excludeIds?: readonly bigint[];
}) {
  const pen = usePen();
  const { address } = useAccount();
  const open = useOpenReservations();
  const unclaimedBulls = useUnclaimedBulls();
  const unclaimedRefund = useUnclaimedRefund();
  const queryClient = useQueryClient();

  // ⚠ A confirmed rescue or refund write changes ownership, the pool, escrow,
  // and every count derived from them. Same invalidation the mint panel does,
  // for the same reason: these are cached reads all over the site and most of
  // them do not poll, so without this a delivered bull or a returned payment
  // does not show up until a reload.
  const onConfirmed = () => {
    open.refetch();
    unclaimedBulls.refetch();
    unclaimedRefund.refetch();
    pen.refetch();
    queryClient.invalidateQueries({ queryKey: ['readContract'] });
    queryClient.invalidateQueries({ queryKey: ['readContracts'] });
  };

  const writes = usePenWrites(onConfirmed);

  /**
   * ⚠ DISMISSAL IS RESOLVED HERE, NOT INSIDE EACH CARD, AND THAT IS A LAYOUT
   * FIX AS WELL AS A TIDY-UP. A card that decides for itself to render null
   * still leaves this wrapper mounted with its margin, so acknowledging the
   * last refund notice would leave a block of empty space where a banner used
   * to be. Filtering up here means the whole component genuinely disappears.
   */
  const { isDismissed, dismiss } = useDismissedRefunds(pen.penAddress);

  const shown = open.ids.filter(
    (id) => !isDismissed(id) && !excludeIds?.some((x) => x === id),
  );

  if (!pen.isPen || !address) return null;
  if (shown.length === 0 && unclaimedBulls.tokenIds.length === 0 && !unclaimedRefund.any) {
    return null;
  }

  return (
    <div className={className}>
      {/* ⚠ EVERY OPEN RESERVATION GETS ITS OWN CARD, AND A REFUNDED ONE GETS A
          DIFFERENT CARD ENTIRELY. `openReservationsOf` filters on `!settled`
          alone, and a refund never settles — so a reservation that ended in the
          buyer's money coming back stays in that list forever. That is what
          makes the refunded dialogue survive a reload and turn up on a second
          device, and it is also why nothing here may treat "in the list" as "on
          the way". `ReservationCard` reads the state and picks. */}
      <div className="space-y-4">
        {shown.map((id) => (
          <ReservationCard
            key={id.toString()}
            reservationId={id}
            writes={writes}
            onDismiss={() => dismiss(id)}
          />
        ))}
      </div>

      {(unclaimedBulls.tokenIds.length > 0 || unclaimedRefund.any) && (
        <div className="mt-4 rounded border border-bull-gold/40 bg-bull-panel p-4">
          {unclaimedRefund.any && address && (
            <div className="space-y-2">
              <p className="bull-header text-bull-gold">there is a refund waiting for you.</p>
              <p className="text-sm text-bull-text-dim">{PEN.refundDeferred}</p>
              <p className="font-mono text-sm text-bull-text">
                <EscrowAmount native={unclaimedRefund.native} token={unclaimedRefund.token} />
              </p>
              <button
                type="button"
                disabled={writes.isBusy}
                onClick={() => void writes.run('claimRefund', address)}
                className="rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-40"
              >
                {PEN.claimRefundCta}
              </button>
            </div>
          )}

          {unclaimedBulls.tokenIds.length > 0 && (
            <div
              className={`space-y-2 ${unclaimedRefund.any ? 'mt-4 border-t border-bull-border/60 pt-3' : ''}`}
            >
              <p className="text-sm text-bull-text-dim">{PEN.unclaimed}</p>
              <div className="flex flex-wrap gap-2">
                {unclaimedBulls.tokenIds.map((tokenId) => (
                  <button
                    key={tokenId}
                    type="button"
                    disabled={writes.isBusy}
                    onClick={() => void writes.run('claim', BigInt(tokenId))}
                    className="rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-40"
                  >
                    {PEN.claimCta} · bull #{tokenId}
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      <RevertNotice error={writes.error} className="mt-3" />
    </div>
  );
}

/**
 * One reservation, as its own card, because the two outcomes are two different
 * conversations: "your bulls are coming" and "your money came back" cannot
 * share a heading.
 */
function ReservationCard({
  reservationId,
  writes,
  onDismiss,
}: {
  reservationId: bigint;
  writes: ReturnType<typeof usePenWrites>;
  onDismiss: () => void;
}) {
  const res = useReservation(reservationId);

  /**
   * ⚠ THE CONFIRMED RECEIPT IS CHECKED ALONGSIDE THE POLLED STATE, AND IT IS
   * NOT BELT AND BRACES. `rescueState` is polled on an 8 second clock, so for a
   * few seconds after the refund transaction confirms the card would still be
   * showing "take my money back" over a refund that already happened. That gap
   * is the exact moment a nervous person presses the button a second time. The
   * receipt is the earlier and equally true source.
   *
   * ⚠ AND THE KEY IS MATCHED, because one `usePenWrites` is shared by every
   * card here. Without it, refunding one reservation would render every other
   * one of this buyer's reservations as refunded too.
   */
  const justRefunded =
    writes.lastDone?.what === 'refund' && writes.lastDone.key === reservationId.toString();
  const refunded = res.refunded || justRefunded;

  if (refunded) {
    // ⚠ DISMISSIBLE, BECAUSE A REFUNDED RESERVATION NEVER LEAVES
    // `openReservationsOf`. Without that, the dialogue would sit on the mint
    // page forever, and "your money has been returned" a month later reads as a
    // site that is stuck rather than one that told you the truth once.
    return <RefundedDialogue res={res} onDismiss={onDismiss} />;
  }

  return <OnTheWayCard res={res} writes={writes} />;
}

/**
 * THE DIALOGUE THE OWNER ASKED FOR, IN THE ORDER HE ASKED FOR IT:
 * what went wrong · your money is safe · it has been returned · mint again.
 *
 * ⚠ THE AMOUNT IS SHOWN ONLY WHEN THIS BROWSER ACTUALLY READ IT. `refund()`
 * zeroes `nativeEscrow` and `tokenEscrow`, so after the fact the figure is only
 * in the `Refunded` event, and this codebase has already written down why no
 * user-facing fact may depend on a `getLogs` scan against public BNB endpoints.
 * `useReservation` caches the last non-zero escrow it saw while the pen was
 * holding it; when there is no cached reading, the FACT of the refund is still
 * stated and the figure is replaced with "check the wallet that paid". Printing
 * a plausible number instead would be the worst possible lie to tell on this
 * particular screen.
 */
export function RefundedDialogue({
  res,
  onDismiss,
  onMintAgain,
}: {
  res: ReservationView;
  /** Hides the notice for this browser. Omitted inside the mint panel, where
   *  the panel's own reset does the job. */
  onDismiss?: () => void;
  /** When the caller can put the buyer straight back on a fresh mint form
   *  in place, "mint again" is a button rather than a link to the page they
   *  are already standing on. */
  onMintAgain?: () => void;
}) {
  const amount = res.lastKnownEscrow;
  /** Gifted TO them: they get the outcome, somebody else got the money back. */
  const isRecipientOnly = res.role === 'recipient';

  return (
    <div className="rounded border border-bull-gold/50 bg-bull-panel p-4">
      {/* 1 · what went wrong, in plain language */}
      <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
        the draw did not land
      </p>
      <p className="mt-1 text-sm text-bull-text-dim">{PEN.refundedWhat}</p>

      {/* 2 + 3 · safe, and returned.
          ⚠ THREE ROLES, THREE SECOND SENTENCES, AND ONLY ONE OF THEM IS ABOUT
          THE READER'S OWN MONEY. A gifter's first question is not "where is my
          money", it is "did they get it or not" — leaving that unanswered is how
          somebody double-buys a present. And a RECIPIENT never paid at all, so
          "your money has been returned" would have them hunting for a credit
          that is never arriving. */}
      <p className="bull-header mt-4 text-bull-gold">
        {isRecipientOnly ? PEN.refundedToYouHeading : PEN.refundedHeading}
      </p>
      <p className="mt-2 text-sm text-bull-text-dim">
        {isRecipientOnly
          ? PEN.refundedToYouBody
          : res.role === 'gifter'
            ? PEN.refundedGiftBody
            : PEN.refundedBody}
      </p>

      {/* ⚠ NO FIGURE FOR A RECIPIENT. The escrow is what the PAYER put in, so
          printing "0.0234 bnb back in your wallet" to somebody who never paid
          is a number that is both wrong and checkable-wrong. */}
      {isRecipientOnly ? null : amount ? (
        <p className="mt-3 font-mono text-lg text-bull-gold">
          <EscrowAmount native={amount.native} token={amount.token} />{' '}
          <span className="text-sm text-bull-text-dim">back in your wallet</span>
        </p>
      ) : (
        <p className="mt-3 text-sm text-bull-text-faint">{PEN.refundedAmountUnknown}</p>
      )}

      {/* 4 · mint again */}
      <p className="mt-4 text-sm text-bull-text-dim">{PEN.refundedAgain}</p>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        {onMintAgain ? (
          <button type="button" onClick={onMintAgain} className="bull-btn bull-btn-pulse">
            {PEN.refundedCta}
          </button>
        ) : (
          <Link href="/mint" onClick={onDismiss} className="bull-btn bull-btn-pulse">
            {PEN.refundedCta}
          </Link>
        )}
        {onDismiss && (
          <button
            type="button"
            onClick={onDismiss}
            className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
          >
            got it
          </button>
        )}
      </div>
    </div>
  );
}

/**
 * A reservation that is still going to become bulls, with whatever it is
 * waiting on and whatever the buyer can do about it.
 *
 * ⚠ THE HEADING IS PICKED OFF THE ROLE, BECAUSE ONE WALLET CAN BE ON EITHER
 * SIDE OF A GIFT AND THE TWO SENTENCES ARE OPPOSITES. `openReservationsOf` now
 * returns both the gifts you sent and the gifts you were sent, so a fixed "you
 * have bulls on the way" would send a gifter hunting through a wallet the bull
 * is never going to arrive in. The bull lands with the recipient; the refund
 * goes back to the payer; the heading has to name which one this is.
 */
function OnTheWayCard({
  res,
  writes,
}: {
  res: ReservationView;
  writes: ReturnType<typeof usePenWrites>;
}) {
  const heading =
    res.role === 'gifter'
      ? PEN.giftOutHeading
      : res.role === 'recipient'
        ? PEN.giftInHeading
        : PEN.onTheWay;

  return (
    <div className="rounded border border-bull-gold/40 bg-bull-panel p-4">
      <p className="bull-header text-bull-gold">{heading}</p>
      {res.role === 'gifter' && (
        <p className="mt-2 text-sm text-bull-text-dim">{PEN.giftOut}</p>
      )}
      {res.role === 'recipient' && (
        <p className="mt-2 text-sm text-bull-text-dim">{PEN.giftIn}</p>
      )}
      <p className="mt-2 text-sm text-bull-text-dim">{PEN.why}</p>
      <div className="mt-3">
        <ReservationRow reservationId={res.id!} writes={writes} />
      </div>
    </div>
  );
}

/**
 * One reservation's live state, the money the pen is holding for it, the
 * countdown to the refund window, and whatever button the current state is
 * asking for.
 *
 * ⚠ THE COUNT, THE ESCROW AND THE COUNTDOWN ARE READ, NEVER GUESSED. A
 * reservation whose reads have not landed shows nothing rather than "1 bull,
 * any second now" — the whole reason this exists is that a person is waiting on
 * something they paid for, and a confident wrong number is worse here than a
 * blank.
 */
export function ReservationRow({
  reservationId,
  writes,
  compact,
}: {
  reservationId: bigint;
  writes: ReturnType<typeof usePenWrites>;
  /** Inside the mint panel the surrounding copy already says what this is, so
   *  the "#N · 3 bulls" line would just repeat it. */
  compact?: boolean;
}) {
  const res = useReservation(reservationId);
  const { wrongNetwork } = useWrongNetwork();

  const action = actionFor(res.state);
  const busyThis = writes.pending?.key === reservationId.toString();

  // ⚠ `QueuedBehind` offers a button that unsticks SOMEBODY ELSE'S reservation,
  // and that is not a courtesy — settlement is strict FIFO, so the one in front
  // is genuinely the thing standing between this buyer and their bulls. The
  // write is permissionless, so they really can do it themselves.
  const blocker = res.state === RESCUE.QueuedBehind ? res.blockedBy : null;

  /**
   * ⚠ THE REFUND WINDOW IS STILL OPEN IN `ArmFallback` / `WaitFallback` /
   * `PinFallback`, NOT JUST IN `Refundable`. The enum stops SAYING `Refundable`
   * once the VRF timeout passes and the backup draw becomes available, but
   * `refund()` only ever cared that no seed exists — so it stays callable, and
   * keying the button on the enum alone would take the refund away from exactly
   * the buyer who has waited longest. `canRefund` mirrors the contract's own
   * preconditions instead.
   */
  const showRefund = res.canRefund;
  // ⚠ ONLY ONCE THE WINDOW IS ACTUALLY OPEN. Saying "the refund belongs to
  // another wallet" while no refund is available to anybody yet is noise on a
  // screen whose whole job is to be reassuring, and it would read as the
  // recipient being told off for something.
  const refundIsSomeoneElses =
    res.refundWindowOpen && !res.isPayer && res.payer !== null && !res.settled && !res.refunded;

  return (
    <div className="rounded border border-bull-border bg-bull-bg px-3 py-2">
      {!compact && (
        <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
          reservation #{reservationId.toString()}
          {res.count !== null ? ` · ${res.count} ${res.count === 1 ? 'bull' : 'bulls'}` : ''}
        </p>
      )}

      {/* ⚠ AN UNREADABLE RESERVATION IS NOT A STUCK ONE, AND IT MUST NOT SIT ON
          "checking…" forever. `useReservation` keeps the two apart, so this can
          say which one it is: a failed read is an rpc having a moment, and the
          bulls and the money are unaffected either way. Offering the retry is
          the point — without it the row is a spinner with no end. */}
      {res.unavailable ? (
        <>
          <p className="mt-1 text-sm text-bull-text-dim">
            couldn&apos;t read this reservation off the chain just now. that is an rpc having a
            moment, not your bulls or your money going anywhere.
          </p>
          <button
            type="button"
            onClick={res.refetch}
            className="mt-2 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </>
      ) : (
        <>
          <p className="mt-1 text-sm text-bull-text-dim">{stateCopy(res)}</p>

          {/* THE MONEY. Shown from the first block of the wait, not held back
              until something looks wrong. See `PEN.moneySafe`. */}
          <EscrowLine res={res} />

          {/* THE COUNTDOWN TO THE REFUND WINDOW. Only while a refund is still a
              possible outcome: once the draw is seeded the money is going to
              become bulls and a countdown would be offering a door that has
              already shut. */}
          {res.blocksUntilRefund !== null &&
            res.blocksUntilRefund > 0 &&
            !res.settled &&
            !res.refunded &&
            res.state !== RESCUE.Settle &&
            res.state !== RESCUE.QueuedBehind && (
              <p className="mt-1 text-sm text-bull-text-faint">
                {PEN.refundPromise}{' '}
                <span className="font-mono text-bull-text-dim">
                  about {res.blocksUntilRefund.toLocaleString('en-AU')} blocks to go
                </span>
                .
              </p>
            )}

          {refundIsSomeoneElses && (
            <p className="mt-1 text-sm text-bull-text-faint">{PEN.refundNotYours}</p>
          )}

          {showRefund && (
            <p className="mt-2 text-sm text-bull-text-faint">{PEN.refundKeeper}</p>
          )}

          <div className="mt-2 flex flex-wrap items-center gap-2">
            {/* ⚠ THE REFUND SITS NEXT TO THE DELIVERY BUTTON, NOT INSTEAD OF IT.
                Both are genuinely available in these states: anyone may still
                push the draw through to delivery, and the buyer may still walk
                away with their money. Hiding either one would be picking for
                them. */}
            {showRefund && (
              <button
                type="button"
                disabled={writes.isBusy || wrongNetwork}
                onClick={() => void writes.run('refund', reservationId)}
                className="rounded-full border border-bull-gold bg-bull-gold/10 px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-40"
              >
                {wrongNetwork
                  ? 'wrong network'
                  : busyThis && writes.pending?.what === 'refund'
                    ? 'sending…'
                    : PEN.refundCta}
              </button>
            )}

            {action && (
              <button
                type="button"
                disabled={writes.isBusy || wrongNetwork}
                onClick={() => void writes.run(action, reservationId)}
                className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
              >
                {wrongNetwork
                  ? 'wrong network'
                  : busyThis && writes.pending?.what !== 'refund'
                    ? 'sending…'
                    : action === 'armFallback'
                      ? PEN.armCta
                      : action === 'pinFallbackSeed'
                        ? PEN.pinCta
                        : PEN.settleCta}
              </button>
            )}

            {blocker !== null && (
              <button
                type="button"
                disabled={writes.isBusy || wrongNetwork}
                onClick={() => void writes.run('settle', blocker)}
                className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
              >
                {PEN.queuedCta} · #{blocker.toString()}
              </button>
            )}
          </div>
        </>
      )}
    </div>
  );
}

/** "the pen is holding 0.0234 bnb for you." The checkable version of "your
 *  funds are safe", and the reason this screen can make that claim at all. */
function EscrowLine({ res }: { res: ReservationView }) {
  const held = res.nativeEscrow ?? 0n;
  const heldToken = res.tokenEscrow ?? 0n;
  if (held === 0n && heldToken === 0n) return null;
  return (
    <p className="mt-2 text-sm text-bull-text-dim">
      {/* ⚠ "your money" ONLY WHEN IT IS. The recipient of a gift did not pay,
          and this is the one screen on the site where being loose about whose
          balance is whose would undo the whole point of showing the figure. */}
      {res.role === 'recipient' ? PEN.moneySafeGiftIn : PEN.moneySafe}{' '}
      <span className="font-mono text-bull-text">
        holding <EscrowAmount native={held} token={heldToken} />
      </span>
      .
    </p>
  );
}

/**
 * An escrowed or refunded amount, in whichever currencies it is actually in.
 *
 * ⚠ BNBULL'S DECIMALS ARE READ OFF THE TOKEN, NOT ASSUMED TO BE 18. Every other
 * amount on this site goes through `useTokenDecimals` for the same reason, and
 * a refund figure is the last number on the site worth getting wrong by three
 * orders of magnitude. BNB is native and is 18 on every EVM chain, which is an
 * assertion rather than a read because there is no contract to ask.
 */
function EscrowAmount({ native, token }: { native: bigint; token: bigint }) {
  const pen = usePen();
  const { data: bnbullAddress } = useReadContract({
    address: pen.penAddress ?? undefined,
    abi: BullPenAbi,
    functionName: 'bnbull',
    query: { enabled: !!pen.penAddress && token > 0n, staleTime: 600_000 },
  });
  const { decimals } = useTokenDecimals(bnbullAddress as `0x${string}` | undefined);

  const parts: string[] = [];
  if (native > 0n) parts.push(`${formatToken(native, NATIVE_BNB_DECIMALS)} bnb`);
  // ⚠ Nothing is printed for the token leg until its decimals have landed. A
  // raw-unit figure rendered as a whole-token one is off by 1e18.
  if (token > 0n && decimals !== undefined) {
    parts.push(`${formatToken(token, decimals)} ${TICKER.toLowerCase()}`);
  }
  return <>{parts.join(' · ')}</>;
}

function stateCopy(res: ReservationView): string {
  switch (res.state) {
    case RESCUE.Settled:
      return PEN.settled;
    case RESCUE.Refunded:
      return PEN.refundedHeading;
    case RESCUE.Refundable:
      return PEN.refundable;
    case RESCUE.WaitingForVrf:
      // ⚠ TWO SENTENCES FOR ONE ON-CHAIN STATE, and the split is a UI
      // judgement rather than a contract fact. "longer than most" is
      // observable; "something is broken" would be invented. See
      // `ReservationView.stalled`.
      return res.stalled ? PEN.stalled : PEN.waitingForVrf;
    case RESCUE.ArmFallback:
      return PEN.armFallback;
    case RESCUE.WaitFallback:
      return PEN.waitFallback;
    case RESCUE.PinFallback:
      return PEN.pinFallback;
    case RESCUE.Settle:
      return PEN.settle;
    case RESCUE.QueuedBehind:
      return PEN.queuedBehind;
    case RESCUE.Unknown:
      return PEN.unknown;
    default:
      // ⚠ Not "nothing is happening". The read has not landed, so this says the
      // only true thing available: we are still asking.
      return 'checking where your bulls are up to…';
  }
}

/**
 * "I have read this" for refunded reservations, in localStorage.
 *
 * ⚠ THE CHAIN STAYS THE SOURCE OF TRUTH AND THIS ONLY HIDES A NOTICE. A
 * refunded reservation is never settled, so it stays in `openReservationsOf`
 * forever — which is exactly what makes the dialogue survive a reload and reach
 * a second device, and also what would leave "your money has been returned"
 * pinned to the mint page months later. Dismissal is therefore per-browser on
 * purpose: clearing storage or opening the site somewhere else brings it back,
 * because the guarantee is that the fact is always FINDABLE, not that it is
 * always in your face.
 *
 * ⚠ AN ID BEING IN HERE IMPLIES IT WAS REFUNDED, because nothing else in this
 * component is dismissible. That is what lets the parent filter on dismissal
 * alone without having to know each reservation's state first.
 */
function useDismissedRefunds(penAddress: `0x${string}` | null): {
  isDismissed: (id: bigint) => boolean;
  dismiss: (id: bigint) => void;
} {
  const prefix = `bnbulls.refund-seen.${penAddress ?? 'none'}.`;
  const [seen, setSeen] = useState<ReadonlySet<string>>(() => new Set());

  // Read in an effect, never during render: `localStorage` does not exist on
  // the server, and this is mounted from statically rendered pages. Rendering
  // "not dismissed" for one frame and correcting is the safe direction to miss.
  useEffect(() => {
    try {
      const found = new Set<string>();
      for (let i = 0; i < window.localStorage.length; i++) {
        const k = window.localStorage.key(i);
        if (k && k.startsWith(prefix)) found.add(k.slice(prefix.length));
      }
      setSeen(found);
    } catch {
      /* private mode, or storage disabled. showing it again is the safe miss. */
    }
  }, [prefix]);

  const isDismissed = useCallback((id: bigint) => seen.has(id.toString()), [seen]);

  const dismiss = useCallback(
    (id: bigint) => {
      const key = id.toString();
      setSeen((prev) => new Set(prev).add(key));
      try {
        window.localStorage.setItem(prefix + key, '1');
      } catch {
        /* the notice still goes for this session */
      }
    },
    [prefix],
  );

  return { isDismissed, dismiss };
}
