'use client';

import { useMemo, useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { parseUnits } from 'viem';
import { BullsAbi, MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useMyBulls } from '@/lib/hooks/useMyBulls';
import { useTokenDecimals } from '@/lib/hooks/useTokenDecimals';

interface BullStruct {
  name: string;
  isDead: boolean;
}

const BNBULL_MODE = { off: 0, pegged: 1, fixed: 2 } as const;

export function ListBullForm({ listedIds }: { listedIds: number[] }) {
  const marketAddress = contractAddress('marketplace');
  const bullsAddress = contractAddress('bullsNft');
  const { address: account } = useAccount();
  const { myIds } = useMyBulls();

  const listable = useMemo(
    () => myIds.filter((id) => !listedIds.includes(id)),
    [myIds, listedIds],
  );
  const { data: myBullData } = useReadContracts({
    contracts: listable.map((id) => ({
      address: bullsAddress ?? undefined,
      abi: BullsAbi,
      functionName: 'getBull' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: listable.length > 0 },
  });
  const alive = useMemo(
    () =>
      listable
        .map((id, i) => ({ id, bull: myBullData?.[i]?.result as BullStruct | undefined }))
        .filter((x) => x.bull && !x.bull.isDead),
    [listable, myBullData],
  );

  const [tokenId, setTokenId] = useState<number | null>(null);
  const [usd, setUsd] = useState('');
  const [bnbullMode, setBnbullMode] = useState<keyof typeof BNBULL_MODE>('off');
  const [bnbullAmount, setBnbullAmount] = useState('');

  const selected = tokenId ?? alive[0]?.id ?? null;

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

  async function handleApprove() {
    if (!bullsAddress || !marketAddress || selected === null) return;
    await writeContractAsync({
      address: bullsAddress,
      abi: BullsAbi,
      functionName: 'approve',
      args: [marketAddress, BigInt(selected)],
    });
    refetchApproval();
  }

  async function handleList() {
    if (!marketAddress || selected === null || !usd) return;
    const usdPrice1e18 = parseUnits(usd, 18);
    const bnbullPrice =
      bnbullMode === 'fixed' && bnbullAmount && bnbullDecimals !== undefined
        ? parseUnits(bnbullAmount, bnbullDecimals)
        : 0n;
    await writeContractAsync({
      address: marketAddress,
      abi: MarketplaceAbi,
      functionName: 'list',
      args: [BigInt(selected), usdPrice1e18, BNBULL_MODE[bnbullMode], bnbullPrice],
    });
  }

  if (!marketAddress) return null;
  if (!account) {
    return <p className="text-sm text-bull-text-dim">connect a wallet to list a bull.</p>;
  }
  if (alive.length === 0) {
    return <p className="text-sm text-bull-text-dim">nothing in this wallet is free to list.</p>;
  }

  return (
    <div className="rounded border border-bull-border bg-bull-panel p-4">
      <div className="flex flex-wrap items-center gap-3">
        <select
          value={selected ?? ''}
          onChange={(e) => setTokenId(Number(e.target.value))}
          className="rounded border border-bull-border bg-bull-bg px-3 py-2 text-sm"
        >
          {alive.map(({ id, bull }) => (
            <option key={id} value={id}>
              #{id} {bull?.name}
            </option>
          ))}
        </select>
        <div className="flex items-center gap-2">
          <span className="text-bull-text-faint">$</span>
          <input
            type="text"
            inputMode="decimal"
            value={usd}
            onChange={(e) => setUsd(e.target.value.replace(/[^\d.]/g, ''))}
            placeholder="price"
            className="w-24 rounded border border-bull-border bg-bull-bg px-3 py-2 text-sm"
          />
        </div>
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-2 text-xs">
          <span className="font-mono uppercase tracking-wide text-bull-text-faint">bnbull leg</span>
          <select
            value={bnbullMode}
            onChange={(e) => setBnbullMode(e.target.value as keyof typeof BNBULL_MODE)}
            className="rounded border border-bull-border bg-bull-bg px-2 py-1 text-sm"
          >
            <option value="off">off</option>
            <option value="pegged">pegged to the sticker</option>
            <option value="fixed">fixed amount</option>
          </select>
        </label>
        {bnbullMode === 'fixed' && (
          <input
            type="text"
            inputMode="decimal"
            value={bnbullAmount}
            onChange={(e) => setBnbullAmount(e.target.value.replace(/[^\d.]/g, ''))}
            placeholder="bnbull amount"
            className="w-32 rounded border border-bull-border bg-bull-bg px-2 py-1 text-sm"
          />
        )}
      </div>

      {!isApproved ? (
        <button
          onClick={handleApprove}
          disabled={isPending || isConfirming || !usd}
          className="mt-4 rounded-full border border-bull-gold px-4 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-50"
        >
          {isPending || isConfirming ? 'approving…' : 'approve this bull'}
        </button>
      ) : (
        <button
          onClick={handleList}
          disabled={isPending || isConfirming || !usd}
          className="mt-4 rounded-full border border-bull-gold bg-bull-gold px-4 py-1.5 text-xs font-semibold text-bull-gold-ink disabled:opacity-50"
        >
          {isPending || isConfirming ? 'listing…' : 'list'}
        </button>
      )}
      {confirmed && <p className="mt-2 text-xs text-bull-gold">done.</p>}
      {txError && <p className="mt-2 text-xs text-bull-red">{txError.message}</p>}
      <p className="mt-3 text-xs text-bull-text-faint">
        approval-based, not escrow. the bull stays in your wallet right up until it sells.
      </p>
    </div>
  );
}
