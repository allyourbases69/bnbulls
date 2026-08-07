'use client';

import { useMemo, useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { parseUnits } from 'viem';
import { BullsAbi, MarketplaceAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID } from '@/lib/env';
import { useMyBulls } from '@/lib/hooks/useMyBulls';
import { useTokenDecimals } from '@/lib/hooks/useTokenDecimals';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { BullPicker, type PickableBull } from './BullPicker';
import { decodeBull } from './bullRecord';

const BNBULL_MODE = { off: 0, pegged: 1, fixed: 2 } as const;

export function ListBullForm({ listedIds }: { listedIds: number[] }) {
  const marketAddress = contractAddress('marketplace');
  const bullsAddress = contractAddress('bullsNft');
  const { address: account } = useAccount();
  const { myIds, isLoading: loadingMine } = useMyBulls();
  const { wrongNetwork } = useWrongNetwork();

  const listable = useMemo(
    () => myIds.filter((id) => !listedIds.includes(id)),
    [myIds, listedIds],
  );
  const {
    data: myBullData,
    isLoading: loadingBulls,
    isError: bullsFailed,
  } = useReadContracts({
    contracts: listable.map((id) => ({
      address: bullsAddress ?? undefined,
      abi: BullsAbi,
      functionName: 'getBull' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: listable.length > 0 },
  });
  // A dead bull cannot be listed (`Marketplace.list` reverts `BullIsDead`), so
  // it is not offered. Everything else the wallet holds is fair game.
  const alive: PickableBull[] = useMemo(
    () =>
      listable
        .map((id, i) => ({ id, record: decodeBull(myBullData?.[i]) }))
        .filter((x): x is PickableBull => x.record !== null && !x.record.isDead),
    [listable, myBullData],
  );

  const [tokenId, setTokenId] = useState<number | null>(null);
  const [usd, setUsd] = useState('');
  const [bnbullMode, setBnbullMode] = useState<keyof typeof BNBULL_MODE>('off');
  const [bnbullAmount, setBnbullAmount] = useState('');

  // ⚠ Fall back to the first card whenever the held id is no longer listable —
  // it just sold, it just got listed, or it died. Without the membership check
  // the form would keep pointing at a bull that is not on screen and `list`
  // would revert.
  const selected =
    tokenId !== null && alive.some((b) => b.id === tokenId) ? tokenId : (alive[0]?.id ?? null);

  const { data: wires } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'wires',
    query: { enabled: !!marketAddress },
  });
  // ⚠ `Marketplace.wires()` is now `(priceFeed, bnbull)` — TWO addresses.
  // It used to be three with the stablecoin first (`DECISIONS.md §26`), so
  // index 2 was BNBULL. Reading the old index here would have handed the
  // BNBULL price field, and the approval target, the PRICE FEED address.
  const [, bnbullAddr] =
    (wires as readonly [`0x${string}`, `0x${string}`] | undefined) ?? [undefined, undefined];
  const { decimals: bnbullDecimals } = useTokenDecimals(bnbullAddr);

  const { data: isApproved, refetch: refetchApproval } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'isApprovedForMarketplace',
    args: selected !== null && account ? [BigInt(selected), account] : undefined,
    query: { enabled: !!marketAddress && selected !== null && !!account },
  });

  const { writeContractAsync, isPending, data: txHash, error: txError } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash: txHash });

  // ⚠ Both writes pin `chainId`. Neither carries native value, but an
  // `approve` broadcast on the wrong chain still hands a real NFT approval to
  // whatever contract sits at that address over there. See `useWrongNetwork`.
  async function handleApprove() {
    if (!bullsAddress || !marketAddress || selected === null || wrongNetwork) return;
    await writeContractAsync({
      address: bullsAddress,
      abi: BullsAbi,
      chainId: CHAIN_ID,
      functionName: 'approve',
      args: [marketAddress, BigInt(selected)],
    });
    refetchApproval();
  }

  async function handleList() {
    if (!marketAddress || selected === null || !usd || wrongNetwork) return;
    const usdPrice1e18 = parseUnits(usd, 18);
    const bnbullPrice =
      bnbullMode === 'fixed' && bnbullAmount && bnbullDecimals !== undefined
        ? parseUnits(bnbullAmount, bnbullDecimals)
        : 0n;
    await writeContractAsync({
      address: marketAddress,
      abi: MarketplaceAbi,
      chainId: CHAIN_ID,
      functionName: 'list',
      args: [BigInt(selected), usdPrice1e18, BNBULL_MODE[bnbullMode], bnbullPrice],
    });
  }

  if (!marketAddress) return null;
  if (!account) {
    return <p className="text-sm text-bull-text-dim">connect a wallet to list a bull.</p>;
  }
  if (loadingMine || (listable.length > 0 && loadingBulls)) {
    return <p className="text-sm text-bull-text-dim">looking through your wallet…</p>;
  }
  if (bullsFailed && listable.length > 0) {
    return (
      <p className="text-sm text-bull-text-dim">
        we found bulls in your wallet but couldn&apos;t read them off the chain, so there is
        nothing safe to show you here yet. give it a moment and reload.
      </p>
    );
  }
  if (alive.length === 0) {
    return <p className="text-sm text-bull-text-dim">nothing in this wallet is free to list.</p>;
  }

  const selectedName = selected !== null ? `#${selected}` : '';

  return (
    <div className="rounded border border-bull-border bg-bull-panel p-4">
      <p className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
        pick the one you&apos;re selling
      </p>
      <div className="mt-3">
        <BullPicker
          bulls={alive}
          selected={selected}
          onSelect={setTokenId}
          recordsFailed={bullsFailed}
        />
      </div>

      <div className="mt-5 flex flex-wrap items-end gap-4">
        <label className="text-xs">
          <span className="block font-mono uppercase tracking-wide text-bull-text-faint">
            price {selectedName && <span className="normal-case">for {selectedName}</span>}
          </span>
          <span className="mt-1 flex items-center gap-2">
            <span className="text-bull-text-faint">$</span>
            <input
              type="text"
              inputMode="decimal"
              value={usd}
              onChange={(e) => setUsd(e.target.value.replace(/[^\d.]/g, ''))}
              placeholder="price"
              className="w-28 rounded border border-bull-border bg-bull-bg px-3 py-2 text-sm"
            />
          </span>
        </label>

        <label className="text-xs">
          <span className="block font-mono uppercase tracking-wide text-bull-text-faint">
            bnbull leg
          </span>
          <select
            value={bnbullMode}
            onChange={(e) => setBnbullMode(e.target.value as keyof typeof BNBULL_MODE)}
            className="mt-1 rounded border border-bull-border bg-bull-bg px-2 py-2 text-sm"
          >
            <option value="off">off</option>
            <option value="pegged">pegged to the sticker</option>
            <option value="fixed">fixed amount</option>
          </select>
        </label>

        {bnbullMode === 'fixed' && (
          <label className="text-xs">
            <span className="block font-mono uppercase tracking-wide text-bull-text-faint">
              bnbull amount
            </span>
            <input
              type="text"
              inputMode="decimal"
              value={bnbullAmount}
              onChange={(e) => setBnbullAmount(e.target.value.replace(/[^\d.]/g, ''))}
              placeholder="bnbull amount"
              className="mt-1 w-32 rounded border border-bull-border bg-bull-bg px-2 py-2 text-sm"
            />
          </label>
        )}
      </div>

      <WrongNetworkNotice className="mt-4" />

      {!isApproved ? (
        <button
          onClick={handleApprove}
          disabled={isPending || isConfirming || !usd || wrongNetwork}
          className="mt-4 rounded-full border border-bull-gold px-4 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-50"
        >
          {wrongNetwork
            ? 'wrong network'
            : isPending || isConfirming
              ? 'approving…'
              : 'approve this bull'}
        </button>
      ) : (
        <button
          onClick={handleList}
          disabled={isPending || isConfirming || !usd || wrongNetwork}
          className="mt-4 rounded-full border border-bull-gold bg-bull-gold px-4 py-1.5 text-xs font-semibold text-bull-gold-ink disabled:opacity-50"
        >
          {wrongNetwork ? 'wrong network' : isPending || isConfirming ? 'listing…' : 'list'}
        </button>
      )}
      {confirmed && <p className="mt-2 text-xs text-bull-gold">done.</p>}
      {txError && <p className="mt-2 break-words text-xs text-bull-red">{txError.message}</p>}
      <p className="mt-3 text-xs text-bull-text-faint">
        approval-based, not escrow. the bull stays in your wallet right up until it sells.
      </p>
    </div>
  );
}
