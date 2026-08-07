'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { YardsAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID } from '@/lib/env';
import { QUOTE_REFRESH_MS } from '@/lib/constants';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';

/**
 * THE ARENA ROSTER — `contracts/Yards.sol`, which the site calls THE BULL PIT
 * (`brand.PIT`; the contract keeps its own name, same split as `/graveyard`
 * being labelled "the butcher").
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE THREE FACTS EVERY CALLER HAS TO CARRY. Getting any of them wrong
 *   produces a screen that contradicts the chain.
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 1. **A BULL THAT IS OUT CANNOT BE FOUGHT AT ALL.** Not "is discouraged from
 *    fighting" — `Duel._requireInYards` runs on EVERY duel, staked or free,
 *    before a sequence number is consumed, and reverts `BullNotInYards`. A UI
 *    that offers such a fight is offering a transaction that always fails.
 *    (That is exactly what bit us: a signed result naming an ejected bull made
 *    gas estimation return garbage, and the RPC's complaint about the *number*
 *    was the only thing the player ever saw.)
 *
 * 2. **EJECT IS DELAYED, ENTRY IS INSTANT, AND THE DELAY IS NOT CAUTION.**
 *    `eject` stamps `leavesAt = block.timestamp + ejectDelay` and the bull
 *    stays fightable until it passes (`inYardsFor`: `lv == 0 || now < lv`). A
 *    duel settles on a SIGNED result and BSC's mempool is public, so an instant
 *    eject would let the losing side front-run the submission and make the loss
 *    evaporate — an undefeatable-bull button. `MIN_EJECT_DELAY` is 15 minutes
 *    because that is `MAX_DUEL_EXPIRY_SECONDS`, the ceiling on how long a fight
 *    signature may live, so an eject cannot outrun a signature that already
 *    exists. **NEVER render a bull with a live `leavesAt` as already safe.**
 *
 * 3. **A TRANSFER VOIDS THE ENTRY, WITH NO EVENT AND NO HOOK.** The stored
 *    entry is `(enteredBy, leavesAt)` and membership requires `enteredBy ==
 *    the LIVE owner`, so a marketplace sale silently takes the bull out. The
 *    buyer holds something that looks fightable and is not, until they enter
 *    it themselves. This has already cost us a debugging session.
 *
 * ⚠ `ejectDelay` IS READ, NEVER ASSUMED. It is an owner-settable value inside
 * `[MIN_EJECT_DELAY, MAX_EJECT_DELAY]`. Hardcoding "15 minutes" in copy would
 * be a number this site invented, and it would be wrong the first time it moves.
 */

const ZERO_ADDR = '0x0000000000000000000000000000000000000000' as const;

/** Why a bull is not fightable, precise enough to tell the player what to do. */
export type PitReason =
  /** In, staying. */
  | 'in'
  /** In, but an eject is stamped and counting down. Still fightable. */
  | 'leaving'
  /** Never entered by anybody. */
  | 'never'
  /** Entered by a PREVIOUS owner — a sale or transfer voided it. */
  | 'sold'
  /** Entered by the live owner, but the eject has already bitten. */
  | 'ejected';

export interface PitStatus {
  readonly id: number;
  /** The wallet that sent it in. Zero when nobody ever did. */
  readonly enteredBy: `0x${string}`;
  /** Unix seconds the eject bites. 0 means staying. */
  readonly leavesAt: number;
  /** `Yards.inYards` — fightable RIGHT NOW. True during a countdown. */
  readonly inPit: boolean;
  /** In the pit with a departure stamped: the "leaving in 04:31" state. */
  readonly leaving: boolean;
  readonly reason: PitReason;
}

function statusFrom(
  id: number,
  enteredBy: `0x${string}`,
  leavesAt: number,
  inPit: boolean,
  liveOwner: string | null,
): PitStatus {
  const leaving = inPit && leavesAt > 0;
  let reason: PitReason;
  if (inPit) {
    reason = leaving ? 'leaving' : 'in';
  } else if (enteredBy === ZERO_ADDR) {
    reason = 'never';
  } else if (liveOwner !== null && enteredBy.toLowerCase() !== liveOwner.toLowerCase()) {
    // ⚠ The sale case, and it is the one worth naming separately: the entry is
    // there, it just belongs to somebody who no longer owns the bull.
    reason = 'sold';
  } else {
    reason = 'ejected';
  }
  return { id, enteredBy, leavesAt, inPit, leaving, reason };
}

/** How long an eject takes to bite, in seconds. `undefined` until it is read —
 *  callers print nothing rather than a guess. */
export function useEjectDelay(): { seconds: number | undefined; deployed: boolean } {
  const yardsAddress = contractAddress('yards');
  const { data } = useReadContract({
    address: yardsAddress ?? undefined,
    abi: YardsAbi,
    functionName: 'ejectDelay',
    query: { enabled: !!yardsAddress },
  });
  return {
    seconds: data === undefined ? undefined : Number(data as bigint),
    deployed: !!yardsAddress,
  };
}

/**
 * WHO IS IN THE PIT, across a whole list of bulls, in ONE call.
 *
 * `Yards.inYardsMany` is a single view that resolves each bull's live owner
 * itself, so the opponent pool costs one read rather than one per bull. That
 * matters: this runs over every minted bull on the duel page.
 *
 * ⚠ `unavailable` IS NOT "EVERYBODY IS OUT". `inYardsMany` walks `ownerOf` and
 * reverts whole if any id is unreadable, so a failed read tells us nothing at
 * all. Callers must NOT filter an opponent pool down to nothing off a failure —
 * that turns an rpc hiccup into "there is nobody to fight", which is the
 * silent-wrong-answer failure this codebase keeps having to design out.
 */
export function usePitMembership(ids: readonly number[]) {
  const yardsAddress = contractAddress('yards');
  const args = useMemo(() => ids.map((id) => BigInt(id)), [ids]);

  /**
   * ⚠ POLLED, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A NICETY.
   *
   * `inYardsMany` resolves each bull's LIVE owner inside the contract, so its
   * answer already folds in ownership — which is the only way to see a
   * membership that a transfer voided. Nothing emits "your pit membership just
   * died": there is no event, because there is no write. So ANY list built
   * earlier in the session is stale by construction, and the only defence is to
   * keep asking. A marketplace buy, a takeover or a plain wallet-to-wallet send
   * all land inside one refresh window.
   *
   * `refetchOnWindowFocus` covers the specific shape this bug had: a player
   * buys a bull in another tab and comes back to a duel page that still thinks
   * it is in the pit.
   */
  const { data, isLoading, isError, refetch } = useReadContract({
    address: yardsAddress ?? undefined,
    abi: YardsAbi,
    functionName: 'inYardsMany',
    args: [args],
    query: {
      enabled: !!yardsAddress && ids.length > 0,
      refetchInterval: QUOTE_REFRESH_MS,
      refetchOnWindowFocus: true,
      staleTime: 0,
    },
  });

  const inPit = useMemo(() => {
    const set = new Set<number>();
    const flags = data as readonly boolean[] | undefined;
    if (!flags) return set;
    ids.forEach((id, i) => {
      if (flags[i]) set.add(id);
    });
    return set;
  }, [data, ids]);

  return {
    /** Ids that are fightable right now. Empty while loading or unavailable. */
    inPit,
    /** True once the read has actually landed — the only time `inPit` means
     *  anything. */
    known: !!yardsAddress && data !== undefined,
    /** No `NEXT_PUBLIC_YARDS`. The gate is not wired for this build. */
    deployed: !!yardsAddress,
    isLoading: !!yardsAddress && ids.length > 0 && isLoading,
    unavailable: !!yardsAddress && ids.length > 0 && isError,
    refetch,
  };
}

/**
 * FULL STATUS for a short list of bulls — the connected wallet's own herd.
 *
 * `statusOf` returns `(enteredBy, leavesAt, live)`, which is everything needed
 * to tell "never entered" from "sold out from under its entry" from "leaving in
 * 04:31". One call per bull, batched through multicall, which is why this is
 * for YOUR bulls and `usePitMembership` is for the 500.
 *
 * `owners` maps id -> live owner so a voided entry can be named as a SALE
 * rather than a generic "out". Optional: without it, `sold` collapses into
 * `ejected`, which is a vaguer answer, never a wrong one.
 */
export function usePitStatus(
  ids: readonly number[],
  owners?: ReadonlyMap<number, string>,
) {
  const yardsAddress = contractAddress('yards');

  // Polled for the same reason as `usePitMembership`, plus one of its own: a
  // countdown that is only correct at page load is not a countdown, and a
  // departure that has already bitten must stop reading "leaving".
  const { data, isLoading, isError, refetch } = useReadContracts({
    allowFailure: true,
    contracts: ids.map((id) => ({
      address: yardsAddress ?? undefined,
      abi: YardsAbi,
      functionName: 'statusOf' as const,
      args: [BigInt(id)] as const,
    })),
    query: {
      enabled: !!yardsAddress && ids.length > 0,
      refetchInterval: QUOTE_REFRESH_MS,
      refetchOnWindowFocus: true,
      staleTime: 0,
    },
  });

  const byId = useMemo(() => {
    const m = new Map<number, PitStatus>();
    if (!data) return m;
    ids.forEach((id, i) => {
      const r = data[i];
      if (r?.status !== 'success') return;
      const [enteredBy, leavesAt, live] = r.result as readonly [`0x${string}`, bigint, boolean];
      m.set(id, statusFrom(id, enteredBy, Number(leavesAt), live, owners?.get(id) ?? null));
    });
    return m;
  }, [data, ids, owners]);

  return {
    byId,
    /** Ids in the pit right now, countdown or not. */
    inIds: useMemo(() => ids.filter((id) => byId.get(id)?.inPit), [ids, byId]),
    /** Ids that cannot fight at all. */
    outIds: useMemo(() => ids.filter((id) => byId.get(id) && !byId.get(id)!.inPit), [ids, byId]),
    /** Ids with a departure stamped and still counting down. */
    leavingIds: useMemo(() => ids.filter((id) => byId.get(id)?.leaving), [ids, byId]),
    deployed: !!yardsAddress,
    isLoading: !!yardsAddress && ids.length > 0 && isLoading,
    unavailable: !!yardsAddress && ids.length > 0 && isError,
    refetch,
  };
}

/**
 * THE MATCHABLE POOL: everything that could actually be fought right now.
 *
 * Two rounds, and the shape is the point. `inYardsMany` costs ONE call over the
 * whole collection and throws out the overwhelming majority; `statusOf` then
 * runs only over what came back IN, because `leavesAt` cannot matter for a bull
 * that is already out. So the expensive per-bull read is bounded by the size of
 * the pit rather than by the size of the drop.
 *
 * ⚠ A BULL WITH AN EJECT COUNTING DOWN IS STILL `inYards` AND IS STILL
 * REMOVED HERE. That is not a contradiction, it is the two halves of the
 * anti-dodge design doing their separate jobs: the CONTRACT keeps it fightable
 * so an already-signed loss lands, and the MATCHMAKER drops it immediately so
 * no new fight is ever offered against it. `Yards.sol` says exactly this — "to
 * every new opponent the bull is gone the moment the eject transaction
 * confirms".
 *
 * ⚠ `matchable` IS `null` UNTIL BOTH READS LAND. Callers pass it straight to
 * `rankOpponents`, which treats null as "no filter". An empty Set would mean
 * "nobody in the game can fight", which is a very different claim and not one a
 * pending read is entitled to make.
 */
export function usePitPool(ids: readonly number[]) {
  const membership = usePitMembership(ids);

  // Sorted for a stable identity, so the second read is not re-issued every
  // time the Set is rebuilt in a different order.
  const inIds = useMemo(
    () => ids.filter((id) => membership.inPit.has(id)),
    [ids, membership.inPit],
  );

  const status = usePitStatus(inIds);
  const membershipRefetch = membership.refetch;
  const statusRefetch = status.refetch;

  const matchable = useMemo(() => {
    if (!membership.known) return null;
    // The status round has not answered yet: hold `null` rather than publishing
    // a pool that is about to shrink. A pool that flickers wide then narrow is
    // how a player picks an opponent that vanishes under them.
    if (inIds.length > 0 && status.byId.size === 0) return null;
    const set = new Set<number>();
    for (const id of inIds) {
      const s = status.byId.get(id);
      // Unread status is treated as matchable: membership already said IN, and
      // demoting on a missing read would shrink the pool on rpc noise.
      if (!s || !s.leaving) set.add(id);
    }
    return set as ReadonlySet<number>;
  }, [membership.known, inIds, status.byId]);

  return {
    /** Ids that are in the yards AND not on their way out. `null` = unknown. */
    matchable,
    /** In the yards, countdown or not. */
    inPit: membership.inPit,
    deployed: membership.deployed,
    isLoading: membership.isLoading || status.isLoading,
    unavailable: membership.unavailable,
    // ⚠ Depends on the two `refetch` FUNCTIONS, not on the hook results. The
    // result objects are rebuilt every render, so depending on them would give
    // this callback a new identity every render — and callers pass it straight
    // into effects.
    refetch: useCallback(() => {
      void membershipRefetch();
      void statusRefetch();
    }, [membershipRefetch, statusRefetch]),
  };
}

export type PitAction = { kind: 'enter' | 'eject'; ids: readonly number[] };

/**
 * The two writes. Both take an ARRAY, so "this one" is a one-element call and
 * "all of mine" is the whole list in a single transaction — the contract was
 * built that way on purpose (`Yards.sol`: "a holder with twenty bulls sends ONE
 * transaction, not twenty").
 *
 * ⚠ BOTH PIN `chainId: CHAIN_ID` and both refuse to fire on the wrong network,
 * matching every other write on this site. Neither carries value, but an
 * `enter` broadcast on another chain still signs a transaction against whatever
 * contract happens to sit at that address over there. See `useWrongNetwork`.
 *
 * ⚠ `eject` REVERTS `NotTokenOwner` on the first id you do not own, and skips
 * ids that are simply not in the pit. So "pull them all out" is safe to point
 * at your whole herd, but must never be pointed at somebody else's.
 */
export function usePitWrites(onConfirmed?: () => void) {
  const yardsAddress = contractAddress('yards');
  const { address: account } = useAccount();
  const { wrongNetwork } = useWrongNetwork();
  const { preflight, checking } = usePreflight();
  const [action, setAction] = useState<PitAction | null>(null);
  const [error, setError] = useState<DecodedRevert | null>(null);

  const { writeContractAsync, isPending, data: txHash, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  /**
   * ⚠ THE CALLBACK GOES IN A REF, AND THAT IS NOT TIDINESS — IT IS AN INFINITE
   * LOOP OTHERWISE.
   *
   * Callers pass an inline arrow (`usePitWrites(() => pit.refetch())`), so its
   * identity changes on every render. With `onConfirmed` in the dependency
   * array, the effect re-runs on every render for as long as `confirmed` stays
   * true — each run refetches, each refetch re-renders, and the panel hammers
   * the rpc forever after a successful enter or eject. Depending on `confirmed`
   * alone fires it exactly once per confirmed transaction, which is what "tell
   * the page when this lands" means.
   */
  const onConfirmedRef = useRef(onConfirmed);
  onConfirmedRef.current = onConfirmed;
  useEffect(() => {
    if (!confirmed) return;
    setAction(null);
    onConfirmedRef.current?.();
  }, [confirmed]);

  const send = useCallback(
    async (kind: 'enter' | 'eject', ids: readonly number[]) => {
      if (!yardsAddress || !account || wrongNetwork || ids.length === 0) return;
      setError(null);
      setAction({ kind, ids });

      const call = {
        address: yardsAddress,
        abi: YardsAbi,
        functionName: kind,
        args: [ids.map((id) => BigInt(id))] as const,
      };

      /**
       * ⚠ SIMULATED FIRST, like every other write on this site.
       *
       * `enter` and `eject` BOTH revert `NotTokenOwner` on the first id the
       * caller does not own, and a batch reverts WHOLE. So a herd list that
       * went stale — one bull sold in another tab a minute ago — turns a
       * "pull them all out" into a failed transaction that pulls out nothing
       * and explains nothing. The dry run names the bull instead.
       */
      const pre = await preflight(call);
      if (!pre.ok) {
        setAction(null);
        setError(pre.error);
        return;
      }

      try {
        await writeContractAsync({ ...call, chainId: CHAIN_ID });
      } catch (e) {
        setAction(null);
        setError(decodeRevert(e));
      }
    },
    [yardsAddress, account, wrongNetwork, writeContractAsync, preflight],
  );

  return {
    enter: useCallback((ids: readonly number[]) => send('enter', ids), [send]),
    eject: useCallback((ids: readonly number[]) => send('eject', ids), [send]),
    /** What is in flight, so a row can show its own spinner rather than the
     *  whole panel going busy when one bull is being pulled out. */
    action,
    isBusy: isPending || isConfirming || checking,
    isPending,
    isConfirming,
    /** True while the dry run is out. Named separately so a button can say
     *  "checking" rather than sitting frozen. */
    checking,
    confirmed,
    txHash,
    /** ⚠ A DECODED SHAPE, NOT A STRING. `RevertNotice` is the only renderer,
     *  and it will not take a raw node error, which is the whole point. */
    error,
    clearError: useCallback(() => setError(null), []),
    reset,
    deployed: !!yardsAddress,
  };
}

/** A once-a-second clock for the eject countdowns. One interval per component,
 *  not one per row. */
export function useNowSeconds(active: boolean): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, [active]);
  return now;
}
