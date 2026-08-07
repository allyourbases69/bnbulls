'use client';

import { useMemo } from 'react';
import { useAccount, useReadContracts } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useMintedBulls } from './useMintedBulls';

/**
 * Every minted bull, with the facts the duel page needs to match a fight:
 * owner, rating, record and whether it is still breathing.
 *
 * ⚠ ONE BATCH, TWO ANSWERS. The picker needs "my living bulls" AND "everyone
 * else's living bulls" off the SAME reads — asking twice would double a
 * multicall that is already the biggest read on the site. `mine` and `others`
 * below are two views of one fetch, not two fetches.
 *
 * `Bulls` has no `Enumerable` extension and this app has no indexer, so the
 * honest approach on a fixed 501-token collection is to read every minted id
 * and filter client-side; `useReadContracts` folds that into a handful of
 * multicall3 aggregates. This does NOT scale past a small fixed collection.
 */
export interface RosterBull {
  readonly id: number;
  readonly owner: `0x${string}`;
  /** The name the CONTRACT holds. The art table deals the same names
   *  (`npm run verify:rarity` pins that), but the chain is the source. */
  readonly name: string;
  readonly elo: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly isDead: boolean;
}

interface BullStruct {
  readonly elo: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly isDead: boolean;
  readonly name: string;
}

export interface Roster {
  readonly all: readonly RosterBull[];
  /** Alive bulls in the connected wallet — who can actually be sent in. */
  readonly mine: readonly RosterBull[];
  /** Everything in the connected wallet, dead ones included. Browse's "mine"
   *  filter needs this: the alive/dead filter is a SEPARATE control there, the
   *  same way fefers splits its owner and life filter groups, so folding the
   *  two together would make "mine + on the truck" impossible to ask for. */
  readonly mineIncludingDead: readonly RosterBull[];
  /** Alive bulls held by anyone else — the opponent pool. */
  readonly others: readonly RosterBull[];
  readonly deployed: boolean;
  readonly isLoading: boolean;
  readonly unavailable: boolean;
  readonly refetch: () => void;
}

export function useRoster(enabled = true): Roster {
  const bullsAddress = contractAddress('bullsNft');
  const { address } = useAccount();
  const minted = useMintedBulls();

  const on = enabled && !!bullsAddress && minted.ids.length > 0;

  const {
    data,
    isLoading: loadingRows,
    refetch: refetchRows,
  } = useReadContracts({
    contracts: minted.ids.flatMap((id) => [
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBull' as const,
        args: [BigInt(id)] as const,
      },
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'ownerOf' as const,
        args: [BigInt(id)] as const,
      },
    ]),
    query: { enabled: on },
  });

  const all = useMemo<RosterBull[]>(() => {
    if (!data) return [];
    const out: RosterBull[] = [];
    minted.ids.forEach((id, i) => {
      const bullRes = data[i * 2];
      const ownerRes = data[i * 2 + 1];
      // A partial failure drops that one bull rather than tanking the roster —
      // an unreadable token is not a token that stops existing, but it also
      // must not be rendered with holes in it.
      if (bullRes?.status !== 'success' || ownerRes?.status !== 'success') return;
      const b = bullRes.result as unknown as BullStruct;
      out.push({
        id,
        owner: ownerRes.result as `0x${string}`,
        name: b.name,
        elo: Number(b.elo),
        wins: Number(b.wins),
        losses: Number(b.losses),
        ties: Number(b.ties),
        isDead: b.isDead,
      });
    });
    return out;
  }, [data, minted.ids]);

  const lower = address?.toLowerCase() ?? null;
  const mineIncludingDead = useMemo(
    () => (lower ? all.filter((b) => b.owner.toLowerCase() === lower) : []),
    [all, lower],
  );
  const mine = useMemo(
    () => mineIncludingDead.filter((b) => !b.isDead),
    [mineIncludingDead],
  );
  const others = useMemo(
    () => all.filter((b) => !b.isDead && (!lower || b.owner.toLowerCase() !== lower)),
    [all, lower],
  );

  return {
    all,
    mine,
    mineIncludingDead,
    others,
    deployed: minted.deployed,
    isLoading: minted.isLoading || (on && loadingRows),
    unavailable: minted.unavailable,
    refetch: () => {
      minted.refetch();
      void refetchRows();
    },
  };
}
