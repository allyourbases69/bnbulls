'use client';

import { useMemo, useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { parseUnits } from 'viem';
import { BullsAbi, MarketplaceAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID } from '@/lib/env';
import { useMyBulls } from '@/lib/hooks/useMyBulls';
import { useTokenDecimals } from '@/lib/hooks/useTokenDecimals';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';
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

  /**
   * ⚠ PEGGED IS A TRAP WHENEVER THE PEG IS NOT FRESH, AND `list` WILL NOT STOP
   * YOU. `Marketplace.list` only runs `_validateBnbullTerms`, which never looks
   * at the peg — so a Pegged listing is accepted happily and then `buy` reverts
   * `BnbullPegUnavailable` (Marketplace.sol:796) for every buyer who tries to
   * pay in BNBULL. The seller is left with a leg nobody can take and no
   * indication why.
   *
   * This mirrors the contract's own rule EXACTLY (`_bnbullPegFresh`,
   * Marketplace.sol:1217) off live reads, so it re-enables itself the moment
   * the price-keeper publishes a real peg at graduation. No hardcoded flag, no
   * date to remember.
   */
  const { data: pegPrice, isError: pegPriceFailed } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'bnbullUsd1e18',
    query: { enabled: !!marketAddress },
  });
  const { data: pegAt, isError: pegAtFailed } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'bnbullUsdUpdatedAt',
    query: { enabled: !!marketAddress },
  });
  const { data: pegMaxAge, isError: pegMaxAgeFailed } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'maxBnbullPegAge',
    query: { enabled: !!marketAddress },
  });

  /** true / false once all three reads land; undefined while they have not. */
  const pegFresh: boolean | undefined = useMemo(() => {
    if (pegPriceFailed || pegAtFailed || pegMaxAgeFailed) return undefined;
    if (pegPrice === undefined || pegAt === undefined || pegMaxAge === undefined) return undefined;
    const price = pegPrice as bigint;
    const at = BigInt(pegAt as bigint | number);
    const maxAge = pegMaxAge as bigint;
    if (price === 0n || at === 0n) return false;
    return BigInt(Math.floor(Date.now() / 1000)) <= at + maxAge;
  }, [pegPrice, pegAt, pegMaxAge, pegPriceFailed, pegAtFailed, pegMaxAgeFailed]);

  // ⚠ ONLY a definitive `false` closes the door. An unread peg leaves the
  // option alone — the same rule the bull page follows for the pit: never
  // tell somebody they cannot do a thing off a call that did not come back.
  const pegUnusable = pegFresh === false;

  // ⚠ DERIVED, NOT AN EFFECT. If the peg goes stale while this form is open,
  // held state may still say `pegged`; every read of the mode from here down
  // goes through this, so a dead peg can never reach `list` even then.
  const effectiveMode: keyof typeof BNBULL_MODE =
    pegUnusable && bnbullMode === 'pegged' ? 'off' : bnbullMode;

  const { data: isApproved, refetch: refetchApproval } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'isApprovedForMarketplace',
    args: selected !== null && account ? [BigInt(selected), account] : undefined,
    query: { enabled: !!marketAddress && selected !== null && !!account },
  });

  const { writeContractAsync, isPending, data: txHash } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash: txHash });
  const { preflight, checking } = usePreflight();
  // ⚠ DECODED, NEVER `txError.message`. `list` reverts `BullIsDead` if the bull
  // died since this form loaded, `NotTokenOwner` if it was sold or sent in
  // another tab, `AlreadyListed` if it was listed elsewhere, and `NotApproved`
  // if the approval was revoked. Every one of those is state that goes stale
  // under a form nobody re-read.
  const [revert, setRevert] = useState<DecodedRevert | null>(null);

  // ⚠ Both writes pin `chainId`. Neither carries native value, but an
  // `approve` broadcast on the wrong chain still hands a real NFT approval to
  // whatever contract sits at that address over there. See `useWrongNetwork`.
  async function handleApprove() {
    if (!bullsAddress || !marketAddress || selected === null || wrongNetwork) return;
    setRevert(null);
    const call = {
      address: bullsAddress,
      abi: BullsAbi,
      functionName: 'approve' as const,
      args: [marketAddress, BigInt(selected)] as const,
    };
    const pre = await preflight(call);
    if (!pre.ok) {
      setRevert(pre.error);
      return;
    }
    try {
      await writeContractAsync({ ...call, chainId: CHAIN_ID });
      refetchApproval();
    } catch (e) {
      setRevert(decodeRevert(e));
    }
  }

  async function handleList() {
    if (!marketAddress || selected === null || !usd || wrongNetwork) return;
    setRevert(null);
    const usdPrice1e18 = parseUnits(usd, 18);
    const bnbullPrice =
      effectiveMode === 'fixed' && bnbullAmount && bnbullDecimals !== undefined
        ? parseUnits(bnbullAmount, bnbullDecimals)
        : 0n;
    const call = {
      address: marketAddress,
      abi: MarketplaceAbi,
      functionName: 'list' as const,
      args: [BigInt(selected), usdPrice1e18, BNBULL_MODE[effectiveMode], bnbullPrice] as const,
    };
    const pre = await preflight(call);
    if (!pre.ok) {
      setRevert(pre.error);
      return;
    }
    try {
      await writeContractAsync({ ...call, chainId: CHAIN_ID });
    } catch (e) {
      setRevert(decodeRevert(e));
    }
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
            value={effectiveMode}
            onChange={(e) => setBnbullMode(e.target.value as keyof typeof BNBULL_MODE)}
            className="mt-1 rounded border border-bull-border bg-bull-bg px-2 py-2 text-sm"
          >
            <option value="off">off</option>
            <option value="pegged" disabled={pegUnusable}>
              pegged to the sticker{pegUnusable ? ' (not available yet)' : ''}
            </option>
            <option value="fixed">fixed amount</option>
          </select>
        </label>

        {effectiveMode === 'fixed' && (
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

      {pegUnusable && (
        <p className="mt-3 text-xs text-bull-text-faint">
          there is no live bnbull price published right now, so a pegged listing could not be
          paid in bnbull and would just sit there. take the sticker price in bnb instead. this
          switches itself back on the moment the price keeper publishes a peg.
        </p>
      )}

      <WrongNetworkNotice className="mt-4" />

      {!isApproved ? (
        <button
          onClick={handleApprove}
          disabled={isPending || isConfirming || checking || !usd || wrongNetwork}
          className="mt-4 rounded-full border border-bull-gold px-4 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-50"
        >
          {wrongNetwork
            ? 'wrong network'
            : checking
              ? 'checking…'
              : isPending || isConfirming
                ? 'approving…'
                : 'approve this bull'}
        </button>
      ) : (
        <button
          onClick={handleList}
          disabled={isPending || isConfirming || checking || !usd || wrongNetwork}
          className="mt-4 rounded-full border border-bull-gold bg-bull-gold px-4 py-1.5 text-xs font-semibold text-bull-gold-ink disabled:opacity-50"
        >
          {wrongNetwork
            ? 'wrong network'
            : checking
              ? 'checking…'
              : isPending || isConfirming
                ? 'listing…'
                : 'list'}
        </button>
      )}
      {confirmed && <p className="mt-2 text-xs text-bull-gold">done.</p>}
      <RevertNotice error={revert} className="mt-2" />
      <p className="mt-3 text-xs text-bull-text-faint">
        approval-based, not escrow. the bull stays in your wallet right up until it sells.
      </p>
    </div>
  );
}
