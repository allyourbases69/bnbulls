'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  useAccount,
  useBlockNumber,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { BullPenAbi, MintDropAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID } from '@/lib/env';
import { usePreflight } from './usePreflight';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

/**
 * WHAT THE PEN IS SITTING ON — the one read that decides what "minted" means.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ THE COUNTING BUG THIS EXISTS TO CLOSE
 * ═══════════════════════════════════════════════════════════════════════════
 * `contracts/BullPen.sol` is stocked by TRANSFER: the owner mints the whole
 * remaining supply straight to the pen, which is what keeps `Bulls.sol` out of
 * the change entirely and lets every already-minted bull keep its id and so its
 * rarity. The cost is that after the pre-mint, `Bulls.nextTokenId()` reads 501
 * while several hundred of those bulls have never been sold and sit in the pen
 * waiting to be dealt.
 *
 * So the sentence this whole codebase was built on — "ids `1 .. nextTokenId-1`
 * are minted" — quietly stops meaning "somebody owns these". Every count that
 * walks `nextTokenId` is wrong by exactly the pen's holdings, and wrong in the
 * worst direction: it says the drop is sold out when it has barely started.
 *
 * The honest set is `existingIds MINUS penHeldIds`, and this hook is where
 * `penHeldIds` comes from. `poolIds()` hands the whole array back in ONE call
 * (it was added for precisely this; the alternative was 469 `poolAt` reads).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ WHY THE ENV VAR GATES THE READ, RATHER THAN THE CHAIN ANSWERING FOR ITSELF
 * ═══════════════════════════════════════════════════════════════════════════
 * `MintDrop.penContract()` looks like it could decide this on its own — it
 * returns an address, and zero is unambiguous. It cannot, and the reason is the
 * contract that is deployed RIGHT NOW: the live `MintDrop` predates the pen and
 * has no `penContract()` function at all, so the call does not return zero, it
 * FAILS. A failed read and "no pen wired" are the same shape from here, which
 * is the exact ambiguity `env.ts` refuses to guess at for `NATIVE_DUEL`.
 *
 * So `NEXT_PUBLIC_BULLPEN` is the told-not-sniffed switch: unset, this hook
 * issues no reads at all and reports `isPen: false` with an empty set, and
 * every surface downstream behaves byte-for-byte the way it does today. Set,
 * the chain still has the last word — `penContract()` reading zero means the
 * pen is deployed but not yet wired to the drop, which is a real state during
 * the timelocked cutover and is also just "legacy" as far as the UI goes.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ `unavailable` IS NOT "THE PEN HOLDS NOTHING", AND THE DIFFERENCE IS THE
 *   WHOLE POINT OF THE THREE STATES
 * ═══════════════════════════════════════════════════════════════════════════
 * If `poolIds()` does not answer and we publish an empty `heldIds`, every
 * unsold bull in the pen is presented as minted and owned — a browse grid full
 * of bulls nobody bought, a "sold out" mint, and a duel picker offering the pen
 * as an opponent. That is strictly worse than saying nothing. So the three
 * states are kept apart the same way every other hook here keeps them apart:
 *
 *   loading      → the reads are in flight, say nothing
 *   unavailable  → they settled with no answer, say THAT and offer a retry
 *   known        → `poolIds()` really came back, and it really is this set
 *
 * Callers must fold `unavailable` into their own, never treat it as empty.
 */
export interface PenView {
  /** The pen the DROP points at, or null when there is no pen in play. Read
   *  off `penContract()` rather than the env var, because that is the address
   *  a reservation is actually made against. */
  readonly penAddress: `0x${string}` | null;
  /** True only when a pen is both configured for this build and wired to the
   *  drop on chain. Everything pen-shaped in the UI hangs off this one flag. */
  readonly isPen: boolean;
  /** Every id the pen physically holds: minted, unsold, not in circulation.
   *  Empty when `isPen` is false — and ALSO empty when `unavailable`, which is
   *  why callers must check that flag rather than the size of this set. */
  readonly heldIds: ReadonlySet<number>;
  /** `poolSize()` — bulls held, open reservations included. Null until known. */
  readonly poolSize: number | null;
  /** `sellable()` — bulls that may still be reserved, i.e. poolSize minus what
   *  is already promised to reservations nobody has settled yet. Null until
   *  known. This, not `poolSize`, is what "left to buy" means. */
  readonly sellable: number | null;
  readonly loading: boolean;
  /** The pen is wired and its reads settled with no answer. NOT "empty pen". */
  readonly unavailable: boolean;
  readonly refetch: () => void;
}

const EMPTY_IDS: ReadonlySet<number> = new Set();

const INERT: PenView = {
  penAddress: null,
  isPen: false,
  heldIds: EMPTY_IDS,
  poolSize: null,
  sellable: null,
  loading: false,
  unavailable: false,
  refetch: () => {},
};

export function usePen(): PenView {
  const configured = contractAddress('bullPen');
  const mintDropAddress = contractAddress('mintDrop');

  // ⚠ Only issued when the build has been TOLD there is a pen. On a legacy
  // build this never fires, so no page pays for a read that cannot answer.
  const {
    data: wired,
    isLoading: loadingWired,
    refetch: refetchWired,
  } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'penContract',
    query: { enabled: !!configured && !!mintDropAddress, refetchInterval: 60_000 },
  });

  const penAddress: `0x${string}` | null =
    typeof wired === 'string' && wired !== ZERO_ADDR ? (wired as `0x${string}`) : null;

  const {
    data: poolIds,
    isLoading: loadingPool,
    refetch: refetchPool,
  } = useReadContract({
    address: penAddress ?? undefined,
    abi: BullPenAbi,
    functionName: 'poolIds',
    query: { enabled: !!penAddress, refetchInterval: 30_000 },
  });

  const {
    data: sellableRaw,
    isLoading: loadingSellable,
    refetch: refetchSellable,
  } = useReadContract({
    address: penAddress ?? undefined,
    abi: BullPenAbi,
    functionName: 'sellable',
    query: { enabled: !!penAddress, refetchInterval: 30_000 },
  });

  const heldIds = useMemo<ReadonlySet<number>>(() => {
    const raw = poolIds as readonly number[] | undefined;
    if (!raw) return EMPTY_IDS;
    return new Set(raw.map((id) => Number(id)));
  }, [poolIds]);

  // ⚠ STABLE IDENTITY, for the same reason `useMintedBulls.refetch` is: this
  // ends up inside callers' `useCallback` deps and effects, and a fresh arrow
  // per render is an effect that re-runs forever.
  const refetch = useCallback(() => {
    void refetchWired();
    void refetchPool();
    void refetchSellable();
  }, [refetchWired, refetchPool, refetchSellable]);

  const result = useMemo<PenView>(() => {
    if (!configured || !mintDropAddress) return INERT;

    const loading = loadingWired || (!!penAddress && (loadingPool || loadingSellable));

    // The drop answered and named no pen: this is the legacy path, fully known,
    // nothing pending. Not an error and not a loading state.
    if (wired !== undefined && penAddress === null) {
      return { ...INERT, refetch };
    }

    const unavailable =
      !loading &&
      (wired === undefined || (penAddress !== null && (poolIds === undefined || sellableRaw === undefined)));

    return {
      penAddress,
      // ⚠ `isPen` stays FALSE while the wiring read is unresolved. A surface
      // that flipped to pen mode on a pending read would show pen copy for a
      // legacy drop and then flip back, and the mint panel would go looking for
      // a `BullsReserved` event that a legacy receipt never carries.
      isPen: penAddress !== null,
      // ⚠ `poolSize()` is deliberately NOT a fourth call: the contract returns
      // `_pool.length` for it and `_pool` for `poolIds()`, so the array's own
      // length IS that number, from the same block, with no chance of the two
      // disagreeing across a re-org or a mid-flight settle.
      heldIds,
      poolSize: poolIds === undefined ? null : heldIds.size,
      sellable: sellableRaw === undefined ? null : Number(sellableRaw as bigint),
      loading,
      unavailable,
      refetch,
    };
  }, [
    configured,
    mintDropAddress,
    wired,
    penAddress,
    poolIds,
    sellableRaw,
    heldIds,
    loadingWired,
    loadingPool,
    loadingSellable,
    refetch,
  ]);

  return result;
}

// ═════════════════════════════════════════════════════════════════════════════
//  RESERVATIONS — the gap between paying and being handed a bull
// ═════════════════════════════════════════════════════════════════════════════

/**
 * `BullPen.Rescue`, mirrored.
 *
 * ⚠ THESE NUMBERS CHANGED WHEN THE REFUND LANDED, AND THEY ARE POSITIONAL. Two
 * values were INSERTED at 2 and 3 rather than appended, so every state from
 * `WaitingForVrf` onwards shifted up by two. A stale mirror does not fail
 * loudly — it silently renders "the draw is being rolled" over a reservation
 * that is actually sitting refundable, which is the one screen where being
 * quietly wrong costs somebody money. Re-read the enum from
 * `contracts/BullPen.sol` before touching this.
 *
 * ⚠ ALMOST EVERY STATE NAMES AN ACTION **ANYONE** MAY TAKE, INCLUDING THE
 * BUYER. `armFallback`, `pinFallbackSeed` and `settle` are all permissionless
 * on purpose: a reservation that never settles is the one failure in this
 * design that costs a real player real money, and the escape must not need an
 * owner key, a keeper, or VRF to be alive.
 *
 * ⚠ `refund` IS THE ONE EXCEPTION AND IT IS PAYER-ONLY BY DESIGN, NOT BY
 * OVERSIGHT. Whether a stuck reservation refunds or settles changes what the
 * NEXT one draws, so a permissionless refund would hand the holder of a seeded
 * reservation a free choice between two computable outcomes. Payer-only makes
 * that choice cost an entire mint of their own. See `refund` in the contract.
 */
export const RESCUE = {
  Unknown: 0,
  Settled: 1,
  /** Terminal. The buyer took their money back and no bull is coming. */
  Refunded: 2,
  /** The window is open: the PAYER may take their money back. Anyone may still
   *  push it through to delivery instead. */
  Refundable: 3,
  WaitingForVrf: 4,
  ArmFallback: 5,
  WaitFallback: 6,
  PinFallback: 7,
  Settle: 8,
  QueuedBehind: 9,
} as const;

export type RescueState = (typeof RESCUE)[keyof typeof RESCUE];

/** The permissionless write a given state is asking for, or null when the only
 *  thing to do is wait (or unstick somebody else's reservation). ⚠ `refund` is
 *  deliberately NOT here: it is payer-only, so it is offered off
 *  `ReservationView.canRefund` rather than off the state alone. */
export function actionFor(state: RescueState | null): 'armFallback' | 'pinFallbackSeed' | 'settle' | null {
  if (state === RESCUE.ArmFallback) return 'armFallback';
  if (state === RESCUE.PinFallback) return 'pinFallbackSeed';
  if (state === RESCUE.Settle) return 'settle';
  return null;
}

export interface ReservationView {
  readonly id: bigint | null;
  /** `rescueState`'s enum, or null until it has actually been read. */
  readonly state: RescueState | null;
  /** The block at which `state`'s action becomes callable. Equal to the
   *  current block when it is callable now. */
  readonly actionAtBlock: bigint | null;
  /** For `QueuedBehind`, the EARLIER reservation that has to settle first.
   *  Null otherwise. Settlement is strict FIFO on purpose — it is what stops a
   *  caller shopping through orderings of the pool — so the only way past it is
   *  to unstick the one in front. */
  readonly blockedBy: bigint | null;
  /** How many bulls this reservation is for. Null until read. */
  readonly count: number | null;
  /** Who the bulls are for. The RECIPIENT, which is not necessarily the payer. */
  readonly to: `0x${string}` | null;
  /** Who paid, and so who a refund goes back to. ⚠ NOT `to` — a gifted mint
   *  refunds the gifter, who is the one out of pocket. */
  readonly payer: `0x${string}` | null;
  readonly settled: boolean;
  /** Terminal: the money went back and no bull is coming. */
  readonly refunded: boolean;
  /** The ids that were drawn, once it has settled. Empty before that — there is
   *  genuinely nothing to show, because nothing has been decided. */
  readonly tokenIds: readonly number[];
  /** Blocks until the current state's action can be taken. 0 = now, null =
   *  unknown. ⚠ WHICH action that is depends on the state — see
   *  `blocksUntilRefund` for the one the buyer actually cares about. */
  readonly blocksUntilAction: number | null;

  // ── the money ────────────────────────────────────────────────────────
  //
  // ⚠ THESE ARE READ FROM THE CONTRACT WHILE IT IS HOLDING THE MONEY, AND THAT
  // IS WHY THEY MATTER. "your funds are safe" is a promise; "the pen is holding
  // 0.0234 bnb of yours, here is the contract" is a fact anybody can check. The
  // second one is the only kind this site is allowed to make.

  /** BNB the pen is holding for this reservation. Null until read, 0 once it
   *  has been refunded or settled. */
  readonly nativeEscrow: bigint | null;
  /** BNBULL the pen is holding for this reservation. */
  readonly tokenEscrow: bigint | null;
  /** The escrow as last seen NON-ZERO, so the refunded dialogue can still name
   *  the figure after the contract has zeroed it. Null when this session never
   *  saw it. ⚠ Never a guess: it is a value this browser really read off the
   *  chain, cached for the length of the session and nothing more. */
  readonly lastKnownEscrow: { native: bigint; token: bigint } | null;

  // ── the refund ───────────────────────────────────────────────────────

  /** The block at which `refund` becomes callable. Null until read. */
  readonly refundAtBlock: bigint | null;
  /** Blocks until the refund window opens. 0 = open now, null = unknown. This
   *  is the countdown a waiting buyer is shown. */
  readonly blocksUntilRefund: number | null;
  /** The connected wallet is the payer, so the refund is theirs to take. */
  readonly isPayer: boolean;
  /** The connected wallet is the recipient, so the bull lands here. */
  readonly isRecipient: boolean;
  /**
   * WHICH SIDE OF THIS RESERVATION THE CONNECTED WALLET IS ON. Null until the
   * reservation has been read, or when the wallet is on neither side.
   *
   * ⚠ THE THREE ROLES WANT THREE DIFFERENT SCREENS, AND GETTING IT WRONG IS
   * WORSE THAN SAYING NOTHING. `BullPen` indexes both `_byOwner` and `_byPayer`,
   * so `openReservationsOf(you)` now returns gifts in BOTH directions — and the
   * two halves are opposites:
   *
   *   `self`      you paid, you get the bull. The ordinary case.
   *   `gifter`    you paid, SOMEBODY ELSE gets the bull. You hold the refund
   *               right and they hold the bull, so "you have bulls on the way"
   *               is false for you and the refund button is yours.
   *   `recipient` somebody else paid, you get the bull. The bull is yours and
   *               the refund is NOT — `refund` reverts `NotThePayer`, so
   *               offering the button here is offering a transaction that always
   *               fails.
   */
  readonly role: 'self' | 'gifter' | 'recipient' | null;
  /** The refund window has opened, for whoever the payer is. Separate from
   *  `canRefund` so a screen can tell "not yet" from "not yours". */
  readonly refundWindowOpen: boolean;
  /**
   * `refund(id)` would be accepted RIGHT NOW from the connected wallet.
   *
   * ⚠ DERIVED FROM THE CONTRACT'S OWN PRECONDITIONS, NOT FROM
   * `state === Refundable`. The enum only reports `Refundable` in the window
   * between `refundAfterBlocks` and `vrfTimeoutBlocks`; after that it moves on
   * to `ArmFallback` / `WaitFallback` / `PinFallback` while `refund` stays
   * perfectly callable, because the function only cares that no seed exists.
   * Keying the button on the enum would take the refund away from exactly the
   * buyer who has waited longest.
   */
  readonly canRefund: boolean;
  /**
   * Waiting, and waiting longer than most do.
   *
   * ⚠ A UI HEURISTIC, NOT A CONTRACT FACT, AND THE COPY IT DRIVES IS WORDED TO
   * SURVIVE THAT. It says "longer than usual", never "something is wrong":
   * there is no on-chain flag for a broken draw, and the measured first live
   * fulfilment took thousands of blocks, so any threshold here is a judgement
   * call. Half the refund window, so it scales if the owner moves that number
   * rather than rotting against a hardcoded wall clock.
   */
  readonly stalled: boolean;

  readonly isLoading: boolean;
  readonly unavailable: boolean;
  readonly refetch: () => void;
}

const NO_IDS: readonly number[] = [];

const NO_RESERVATION: ReservationView = {
  id: null,
  state: null,
  actionAtBlock: null,
  blockedBy: null,
  count: null,
  to: null,
  payer: null,
  settled: false,
  refunded: false,
  tokenIds: NO_IDS,
  blocksUntilAction: null,
  nativeEscrow: null,
  tokenEscrow: null,
  lastKnownEscrow: null,
  refundAtBlock: null,
  blocksUntilRefund: null,
  isPayer: false,
  isRecipient: false,
  role: null,
  refundWindowOpen: false,
  canRefund: false,
  stalled: false,
  isLoading: false,
  unavailable: false,
  refetch: () => {},
};

/**
 * ESCROW AMOUNTS THIS SESSION HAS ACTUALLY SEEN, keyed `pen:reservationId`.
 *
 * ⚠ THIS EXISTS BECAUSE `refund()` ZEROES `nativeEscrow` AND `tokenEscrow`, SO
 * THE FIGURE IS UNREADABLE THE MOMENT IT MATTERS MOST. The owner's ask is a
 * dialogue that says the money "has been returned" — and a number makes that
 * land in a way a sentence does not. The amount is in the `Refunded` event, but
 * reading it back means a `getLogs` scan, and this codebase has already written
 * down what public BNB endpoints do to those (range caps, rate limits,
 * retention windows) and why no user-facing fact may depend on one.
 *
 * So: while the pen is holding the money the escrow is live and polled anyway,
 * and the last non-zero reading is kept here. Nothing is ever invented — a
 * reload with no cached reading shows the FACT of the refund without a figure,
 * because at that point the honest answer is "check the wallet that paid".
 *
 * Module level rather than a ref so it survives navigating /mint → /bulls,
 * which is exactly the trip somebody makes while wondering where their bull is.
 * Same precedent as `useRanks`' module-level table cache.
 */
const ESCROW_SEEN = new Map<string, { native: bigint; token: bigint }>();

/**
 * ONE RESERVATION, AND WHAT IS HOLDING IT UP.
 *
 * ⚠ POLLED HARD, AND SHORT. Everything this reports moves without any
 * transaction from the person watching it: VRF answers, the reservation in
 * front settles, a fallback window opens. A screen that only refreshes on a
 * click would leave a buyer staring at "the draw is being rolled" long after
 * their bulls landed in their wallet.
 */
export function useReservation(reservationId: bigint | null): ReservationView {
  const pen = usePen();
  const { address: account } = useAccount();
  const penAddress = pen.penAddress;
  const on = !!penAddress && reservationId !== null;

  const { data: blockNumber } = useBlockNumber({
    chainId: CHAIN_ID,
    query: { enabled: on, refetchInterval: 12_000 },
  });

  /**
   * ⚠ THE REFUND DEADLINE IS READ, NEVER ASSUMED. `refundAfterBlocks` is
   * owner-settable, and the countdown this drives is a promise about somebody's
   * money — a hardcoded 7,200 would be wrong the first time it moves and would
   * be wrong in the direction of promising a refund earlier than the contract
   * will give one. Its own query, because it is the same answer for every
   * reservation and changes about never.
   */
  const { data: refundAfterBlocks } = useReadContract({
    address: penAddress ?? undefined,
    abi: BullPenAbi,
    functionName: 'refundAfterBlocks',
    query: { enabled: !!penAddress, staleTime: 600_000 },
  });

  const {
    data,
    isLoading,
    refetch: refetchRows,
  } = useReadContracts({
    allowFailure: true,
    contracts: on
      ? [
          {
            address: penAddress,
            abi: BullPenAbi,
            functionName: 'rescueState' as const,
            args: [reservationId] as const,
          },
          {
            address: penAddress,
            abi: BullPenAbi,
            functionName: 'reservationOf' as const,
            args: [reservationId] as const,
          },
          {
            address: penAddress,
            abi: BullPenAbi,
            functionName: 'drawnIds' as const,
            args: [reservationId] as const,
          },
        ]
      : [],
    query: { enabled: on, refetchInterval: 8_000 },
  });

  const refetch = useCallback(() => {
    void refetchRows();
  }, [refetchRows]);

  return useMemo<ReservationView>(() => {
    if (!on) return NO_RESERVATION;

    const rescue = data?.[0];
    const reservation = data?.[1];
    const drawn = data?.[2];

    const rescueRow =
      rescue?.status === 'success'
        ? (rescue.result as unknown as readonly [number, bigint, bigint])
        : undefined;
    const resRow =
      reservation?.status === 'success'
        ? (reservation.result as unknown as {
            to: `0x${string}`;
            count: number;
            settled: boolean;
            refunded: boolean;
            seeded: boolean;
            reservedAtBlock: bigint;
            payer: `0x${string}`;
            nativeEscrow: bigint;
            tokenEscrow: bigint;
          })
        : undefined;
    const drawnRow =
      drawn?.status === 'success' ? (drawn.result as unknown as readonly number[]) : undefined;

    const state = rescueRow ? (rescueRow[0] as RescueState) : null;
    const actionAtBlock = rescueRow ? rescueRow[1] : null;
    const blockedByRaw = rescueRow ? rescueRow[2] : null;

    const blocksUntilAction =
      actionAtBlock === null || blockNumber === undefined
        ? null
        : actionAtBlock > blockNumber
          ? Number(actionAtBlock - blockNumber)
          : 0;

    // Cache the escrow while the pen is still holding it. See `ESCROW_SEEN`.
    const key = `${penAddress}:${reservationId}`;
    if (resRow && (resRow.nativeEscrow > 0n || resRow.tokenEscrow > 0n)) {
      ESCROW_SEEN.set(key, { native: resRow.nativeEscrow, token: resRow.tokenEscrow });
    }
    const lastKnownEscrow = ESCROW_SEEN.get(key) ?? null;

    const refundAtBlock =
      resRow && refundAfterBlocks !== undefined
        ? resRow.reservedAtBlock + (refundAfterBlocks as bigint)
        : null;
    const blocksUntilRefund =
      refundAtBlock === null || blockNumber === undefined
        ? null
        : refundAtBlock > blockNumber
          ? Number(refundAtBlock - blockNumber)
          : 0;

    const isPayer =
      !!resRow && !!account && resRow.payer.toLowerCase() === account.toLowerCase();
    const isRecipient =
      !!resRow && !!account && resRow.to.toLowerCase() === account.toLowerCase();
    // ⚠ Null rather than a default when the wallet is on neither side. That
    // should be unreachable (the id came from `openReservationsOf(account)`),
    // and inventing a role for it would put somebody else's gift copy on screen.
    const role: 'self' | 'gifter' | 'recipient' | null = !resRow
      ? null
      : isPayer && isRecipient
        ? 'self'
        : isPayer
          ? 'gifter'
          : isRecipient
            ? 'recipient'
            : null;

    /**
     * ⚠ THE WINDOW IS TAKEN FROM THE CONTRACT'S OWN VERDICT FIRST, AND FROM OUR
     * BLOCK ARITHMETIC ONLY AS A SECOND OPINION.
     *
     * `rescueState` reporting any of these four means the pen has already
     * decided the refund window is open: `refundAfterBlocks` is enforced to be
     * strictly less than `vrfTimeoutBlocks` (`setVrfTimeoutBlocks` reverts
     * otherwise), so by the time the fallback states are reachable the refund
     * has been available for a while. Trusting that first matters because the
     * arithmetic needs `useBlockNumber` to have landed, and a head read that
     * did not answer would otherwise HIDE the refund button from the one buyer
     * who has waited longest. A hidden refund is the failure that costs money.
     */
    const windowOpenByChain =
      state === RESCUE.Refundable ||
      state === RESCUE.ArmFallback ||
      state === RESCUE.WaitFallback ||
      state === RESCUE.PinFallback;

    const refundWindowOpen = windowOpenByChain || blocksUntilRefund === 0;

    // The contract's own preconditions, in the same order it checks them.
    const canRefund =
      !!resRow &&
      isPayer &&
      !resRow.settled &&
      !resRow.refunded &&
      !resRow.seeded &&
      refundWindowOpen;

    const elapsed =
      resRow && blockNumber !== undefined && blockNumber > resRow.reservedAtBlock
        ? blockNumber - resRow.reservedAtBlock
        : 0n;
    const stalled =
      !!resRow &&
      !resRow.settled &&
      !resRow.refunded &&
      !resRow.seeded &&
      refundAfterBlocks !== undefined &&
      elapsed >= (refundAfterBlocks as bigint) / 2n;

    return {
      id: reservationId,
      state,
      actionAtBlock,
      blockedBy: blockedByRaw && blockedByRaw > 0n ? blockedByRaw : null,
      count: resRow ? Number(resRow.count) : null,
      to: resRow ? resRow.to : null,
      payer: resRow ? resRow.payer : null,
      settled: state === RESCUE.Settled,
      refunded: state === RESCUE.Refunded,
      tokenIds: drawnRow ? drawnRow.map((id) => Number(id)) : NO_IDS,
      blocksUntilAction,
      nativeEscrow: resRow ? resRow.nativeEscrow : null,
      tokenEscrow: resRow ? resRow.tokenEscrow : null,
      lastKnownEscrow,
      refundAtBlock,
      blocksUntilRefund,
      isPayer,
      isRecipient,
      role,
      refundWindowOpen,
      canRefund,
      stalled,
      isLoading: isLoading && !rescueRow,
      // ⚠ A reservation that reads `Unknown` is NOT unavailable — the contract
      // says that for an id it has never issued, which is a real answer.
      unavailable: !isLoading && !rescueRow,
      refetch,
    };
  }, [
    on,
    data,
    reservationId,
    penAddress,
    blockNumber,
    isLoading,
    refetch,
    refundAfterBlocks,
    account,
  ]);
}

/**
 * "YOU HAVE PAID FOR THESE AND HAVE NOT RECEIVED THEM."
 *
 * ⚠ THIS IS THE READ THAT MAKES A PENDING RESERVATION SURVIVE A RELOAD, AND IT
 * IS DERIVED FROM NOTHING BUT THE CONNECTED ADDRESS.
 *
 * Delivery is asynchronous, so between paying and receiving there is a window
 * in which the buyer owns nothing an ERC-721 wallet can show them. If the only
 * handle on that window were a `reservationId` this page happened to keep in
 * memory, a refresh, a closed tab or a second device would lose it — and the
 * buyer would be left with "I paid and nothing happened", which is
 * indistinguishable, from where they are standing, from being robbed.
 *
 * ⚠ IT COVERS BOTH SIDES OF A GIFT, AND THAT CLOSED A REAL HOLE IN THE
 * GUARANTEE. `BullPen` indexes `_byOwner` (recipient) AND `_byPayer` (payer,
 * written only when the two differ, so a self-mint is never double-listed).
 * Before the payer index existed, a gifter whose gift stalled could not
 * discover it from chain state at all — and they are the one holding the refund
 * right, because `refund` is payer-only. So the person with the money on the
 * line had no screen. Now one address finds everything it has an interest in,
 * in either direction.
 *
 * That means an id in here can be any of three things, and they are not
 * interchangeable — see `ReservationView.role`. "you have bulls on the way" is
 * simply false for a gifter.
 *
 * ⚠ A REFUNDED RESERVATION IS STILL IN HERE, AND THAT IS DELIBERATE RATHER THAN
 * A BUG. The filter is `!settled`, not `!settled && !refunded`, and a refund
 * never settles — so a reservation that ended in the buyer's money coming back
 * stays in this list. That is exactly what makes the "your money has been
 * returned" dialogue survive a reload and turn up on a second device instead of
 * vanishing the moment it becomes true. It does mean callers must split the
 * list on `refunded` before saying anything: an id in here is "not delivered",
 * which is NOT the same as "on the way".
 */
export function useOpenReservations(): {
  readonly ids: readonly bigint[];
  readonly isLoading: boolean;
  readonly unavailable: boolean;
  readonly refetch: () => void;
} {
  const pen = usePen();
  const { address } = useAccount();
  const on = !!pen.penAddress && !!address;

  const { data, isLoading, refetch } = useReadContract({
    address: pen.penAddress ?? undefined,
    abi: BullPenAbi,
    functionName: 'openReservationsOf',
    args: address ? [address] : undefined,
    query: { enabled: on, refetchInterval: 15_000 },
  });

  const ids = useMemo(() => (data as readonly bigint[] | undefined) ?? [], [data]);
  const stableRefetch = useCallback(() => {
    void refetch();
  }, [refetch]);

  return {
    ids,
    isLoading: on && isLoading,
    // ⚠ An empty array is a real answer ("nothing outstanding"). Only a read
    // that never landed is unavailable, and a banner must never be rendered
    // from one — "you have bulls on the way" is not a thing to guess at.
    unavailable: on && !isLoading && data === undefined,
    refetch: stableRefetch,
  };
}

/**
 * BULLS THAT WERE DRAWN FOR YOU AND COULD NOT BE HANDED OVER.
 *
 * `settle` pushes each token with `safeTransferFrom` and, if the receiver
 * reverts, parks it in `unclaimedOwner[tokenId]` rather than letting one bad
 * receiver wedge the FIFO queue for everybody behind it. The token is already
 * yours in every sense that matters; `claim` only moves it.
 *
 * ⚠ RARE, AND STILL WORTH READING FOR. A plain wallet cannot hit this — it
 * needs a contract recipient that rejects ERC-721s. But the whole point of the
 * pull fallback is that the bull is not lost, and a bull nobody can find is
 * lost in every way the holder cares about.
 *
 * Walked from `reservationIdsOf(you)` because there is no reverse index from an
 * address to its unclaimed tokens, and inventing one on chain would have cost
 * every buyer gas for a case almost none of them will ever hit.
 */
export function useUnclaimedBulls(): {
  readonly tokenIds: readonly number[];
  readonly isLoading: boolean;
  readonly refetch: () => void;
} {
  const pen = usePen();
  const { address } = useAccount();
  const on = !!pen.penAddress && !!address;

  const { data: allIds, refetch: refetchAll } = useReadContract({
    address: pen.penAddress ?? undefined,
    abi: BullPenAbi,
    functionName: 'reservationIdsOf',
    args: address ? [address] : undefined,
    query: { enabled: on, refetchInterval: 60_000 },
  });

  const reservationIds = useMemo(() => (allIds as readonly bigint[] | undefined) ?? [], [allIds]);

  const { data: drawnRows, refetch: refetchDrawn } = useReadContracts({
    allowFailure: true,
    contracts: reservationIds.map((id) => ({
      address: pen.penAddress ?? undefined,
      abi: BullPenAbi,
      functionName: 'drawnIds' as const,
      args: [id] as const,
    })),
    query: { enabled: on && reservationIds.length > 0 },
  });

  const drawnTokenIds = useMemo(() => {
    const out: number[] = [];
    (drawnRows ?? []).forEach((r) => {
      if (r.status !== 'success') return;
      (r.result as unknown as readonly number[]).forEach((id) => out.push(Number(id)));
    });
    return out;
  }, [drawnRows]);

  const {
    data: ownerRows,
    isLoading: loadingOwners,
    refetch: refetchOwners,
  } = useReadContracts({
    allowFailure: true,
    contracts: drawnTokenIds.map((id) => ({
      address: pen.penAddress ?? undefined,
      abi: BullPenAbi,
      functionName: 'unclaimedOwner' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: on && drawnTokenIds.length > 0, refetchInterval: 30_000 },
  });

  const tokenIds = useMemo(() => {
    if (!ownerRows || !address) return NO_IDS;
    const lower = address.toLowerCase();
    const out: number[] = [];
    drawnTokenIds.forEach((id, i) => {
      const row = ownerRows[i];
      if (row?.status !== 'success') return;
      const owed = row.result as `0x${string}`;
      if (owed && owed.toLowerCase() === lower) out.push(id);
    });
    return out;
  }, [ownerRows, drawnTokenIds, address]);

  const refetch = useCallback(() => {
    void refetchAll();
    void refetchDrawn();
    void refetchOwners();
  }, [refetchAll, refetchDrawn, refetchOwners]);

  return {
    tokenIds,
    isLoading: on && drawnTokenIds.length > 0 && loadingOwners,
    refetch,
  };
}

/**
 * MONEY THE PEN OWES THE CONNECTED WALLET BECAUSE A PUSH BOUNCED.
 *
 * `refund` never reverts on the transfer: a refund that can revert is a refund
 * a hostile contract can use to wedge the FIFO queue, so a failed push parks
 * the amount under the payer's name and emits `RefundDeferred`. Same pull
 * fallback as `unclaimedOwner` for a deferred bull, same reason.
 *
 * ⚠ AND THE SAME "RARE IS NOT NEVER" ARGUMENT. A plain wallet cannot hit this;
 * it needs a payer contract that rejects a plain BNB transfer. But money that
 * is owed and invisible is money the owner believes is gone, and that is the
 * single worst screen this product can produce.
 */
export function useUnclaimedRefund(): {
  readonly native: bigint;
  readonly token: bigint;
  readonly any: boolean;
  readonly refetch: () => void;
} {
  const pen = usePen();
  const { address } = useAccount();
  const on = !!pen.penAddress && !!address;

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: on
      ? [
          {
            address: pen.penAddress!,
            abi: BullPenAbi,
            functionName: 'unclaimedRefundNative' as const,
            args: [address!] as const,
          },
          {
            address: pen.penAddress!,
            abi: BullPenAbi,
            functionName: 'unclaimedRefundToken' as const,
            args: [address!] as const,
          },
        ]
      : [],
    query: { enabled: on, refetchInterval: 30_000 },
  });

  const native = data?.[0]?.status === 'success' ? (data[0].result as bigint) : 0n;
  const token = data?.[1]?.status === 'success' ? (data[1].result as bigint) : 0n;

  const stableRefetch = useCallback(() => {
    void refetch();
  }, [refetch]);

  return { native, token, any: native > 0n || token > 0n, refetch: stableRefetch };
}

export type PenWriteName =
  | 'armFallback'
  | 'pinFallbackSeed'
  | 'settle'
  | 'claim'
  | 'refund'
  | 'claimRefund';

/**
 * THE PERMISSIONLESS WRITES, in the shape every other write on this site takes:
 * simulated first, decoded on failure, pinned to `CHAIN_ID`, never rendering a
 * raw node error.
 *
 * ⚠ THE SIMULATION MATTERS MORE HERE THAN ANYWHERE, because every one of these
 * is a button offered to somebody who is already anxious. `settle` reverts
 * `NotNextToSettle` the instant somebody else's reservation slips in front,
 * `pinFallbackSeed` reverts `FallbackExpired` once the 256-block blockhash
 * window closes, and `armFallback` reverts `VrfTimeoutNotElapsed` if the poll
 * that offered the button was one block early. All three are races by
 * construction, and all three decode to a sentence rather than to the rpc's
 * complaint about a gas number.
 *
 * ⚠ AND THE RESCUE WRITES ARE ALL SAFE TO LOSE. `armFallback`,
 * `pinFallbackSeed` and `settle` decide nothing: the ids are a pure function of
 * a seed that is already written, so if somebody else's transaction lands
 * first, the outcome is identical and the bulls still arrive. A failed press
 * costs gas and nothing else.
 *
 * ⚠ `refund` IS THE ONE THAT IS NOT. It is terminal and it is a fork: taking
 * the money back means the bulls are NOT coming, and the same reservation can
 * never be settled afterwards. It is also payer-only, and it reverts
 * `RefundWindowNotOpen` right up until the block the window opens — which is
 * why it is simulated like everything else and why the button only appears off
 * `ReservationView.canRefund`, which mirrors the contract's own preconditions
 * rather than guessing from the state enum.
 */
export function usePenWrites(onConfirmed?: () => void) {
  const pen = usePen();
  const { address: account } = useAccount();
  const { preflight, checking } = usePreflight();
  const [pending, setPending] = useState<{ what: PenWriteName; key: string } | null>(null);
  const [error, setError] = useState<DecodedRevert | null>(null);

  const { writeContractAsync, data: txHash, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({
    hash: txHash,
  });
  /**
   * The last write that CONFIRMED, and what it was aimed at.
   *
   * ⚠ THE ARGUMENT IS PART OF THE ANSWER, NOT DECORATION. One `usePenWrites` is
   * shared by every reservation card on the page, so `lastDone === 'refund'`
   * alone would make EVERY card render as refunded the moment one of them was —
   * telling a buyer with two reservations that both their payments came back
   * when only one did. The key is what keeps the answer attached to the row it
   * is true of.
   */
  const [lastDone, setLastDone] = useState<{ what: PenWriteName; key: string } | null>(null);

  // ⚠ THE CALLBACK GOES IN A REF. Callers pass an inline arrow, so its identity
  // changes every render; with it in the dependency array the effect re-runs for
  // as long as `confirmed` stays true and the panel hammers the rpc forever.
  // Same trap, same fix, as `usePitWrites`.
  const onConfirmedRef = useRef(onConfirmed);
  onConfirmedRef.current = onConfirmed;
  const pendingRef = useRef<{ what: PenWriteName; key: string } | null>(null);
  useEffect(() => {
    if (!confirmed) return;
    setPending(null);
    setLastDone(pendingRef.current);
    onConfirmedRef.current?.();
  }, [confirmed]);

  /**
   * ⚠ THE ARGUMENT IS NOT ALWAYS A RESERVATION ID. `armFallback`,
   * `pinFallbackSeed`, `settle` and `refund` take a `uint256` reservation id;
   * `claim` takes a `uint256` TOKEN id; `claimRefund` takes an ADDRESS. They
   * share this one path because they share the whole discipline around it
   * (simulate, decode, pin the chain, one in flight at a time), so the argument
   * is passed through as-is and `pending.key` is a display string rather than a
   * number that would mean three different things.
   */
  const send = useCallback(
    async (what: PenWriteName, arg: bigint | `0x${string}`) => {
      const penAddress = pen.penAddress;
      if (!penAddress || !account) return;
      setError(null);
      pendingRef.current = { what, key: arg.toString() };
      setPending({ what, key: arg.toString() });

      const call = {
        address: penAddress,
        abi: BullPenAbi,
        functionName: what,
        args: [arg] as const,
      };

      const pre = await preflight(call);
      if (!pre.ok) {
        setPending(null);
        setError(pre.error);
        return;
      }

      try {
        await writeContractAsync({ ...call, chainId: CHAIN_ID });
      } catch (e) {
        setPending(null);
        setError(decodeRevert(e));
      }
    },
    [pen.penAddress, account, preflight, writeContractAsync],
  );

  return {
    run: send,
    /** What is in flight, so one row can spin without the whole banner going
     *  busy. `key` is the stringified argument, not necessarily an id. */
    pending,
    /** The last write that CONFIRMED, and its argument. Lets a panel say
     *  "refunded" the instant the transaction lands, before the polled
     *  `rescueState` has caught up — the one place in this flow where a couple
     *  of seconds of "nothing happened" would be read as the refund having
     *  failed. ⚠ Always match the `key` too; see the state's own note. */
    lastDone,
    isBusy: pending !== null || isConfirming || checking,
    checking,
    confirmed,
    txHash,
    /** ⚠ A DECODED SHAPE, NOT A STRING. `RevertNotice` is the only renderer. */
    error,
    clearError: useCallback(() => setError(null), []),
    reset,
    deployed: !!pen.penAddress,
  };
}
