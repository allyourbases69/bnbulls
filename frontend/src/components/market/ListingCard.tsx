'use client';

import { useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatToken, formatUsd1e18, shortAddr } from '@/lib/format';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { withCushion, QUOTE_REFRESH_MS } from '@/lib/constants';
import { BullSprite } from '@/components/BullSprite';
import { getBull } from '@/lib/art/collection';
import { CURRENCY } from '@/lib/brand';

/**
 * ⚠ TWO CURRENCIES (`DECISIONS.md §26`). `buyWithStable` is gone,
 * `quote()` returns FOUR values instead of five, and `wires()` returns TWO
 * addresses `(priceFeed, bnbull)` instead of three with a stablecoin first —
 * so the old destructure was reading the PRICE FEED address as the token to
 * approve.
 */
type PayAsset = 'bnb' | 'bnbull';

export function ListingCard({ tokenId }: { tokenId: number }) {
  const marketAddress = contractAddress('marketplace');
  const { address: account } = useAccount();
  const token = getBull(tokenId);
  const [asset, setAsset] = useState<PayAsset>('bnb');

  const { data: listing } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'listingOf',
    args: [BigInt(tokenId)],
    query: { enabled: !!marketAddress },
  });
  const { data: quote } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'quote',
    args: [BigInt(tokenId)],
    query: { enabled: !!marketAddress, refetchInterval: QUOTE_REFRESH_MS },
  });
  const { data: wires } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'wires',
    query: { enabled: !!marketAddress },
  });

  const seller = (listing as { seller: `0x${string}` } | undefined)?.seller;
  // `Marketplace.quote(tokenId)` -> (usdPrice1e18, bnbDue, bnbullDue, bnbUsd1e18).
  const [usdPrice, bnbDue, bnbullDue] =
    (quote as readonly [bigint, bigint, bigint, bigint] | undefined) ?? [
      undefined,
      undefined,
      undefined,
    ];
  // `Marketplace.wires()` -> (priceFeed, bnbull).
  const [, bnbullAddr] =
    (wires as readonly [`0x${string}`, `0x${string}`] | undefined) ?? [undefined, undefined];
  const { decimals: bnbullDecimals } = useTokenDecimals(bnbullAddr);

  const dueForAsset: Record<PayAsset, bigint | undefined> = { bnb: bnbDue, bnbull: bnbullDue };
  const decimalsForAsset: Record<PayAsset, number | undefined> = {
    bnb: NATIVE_BNB_DECIMALS,
    bnbull: bnbullDecimals,
  };
  // A zero leg is "the seller did not price it in that currency", or for
  // BNBULL simply `DECISIONS.md §29` — the token cannot move yet.
  const availableForAsset: Record<PayAsset, boolean> = {
    bnb: bnbDue !== undefined && bnbDue > 0n,
    bnbull: bnbullDue !== undefined && bnbullDue > 0n,
  };

  const approvalToken = asset === 'bnbull' ? bnbullAddr : undefined;
  const { needsApproval, approve, isApproving, refetchAllowance } = useErc20Approval(
    approvalToken,
    marketAddress ?? undefined,
    dueForAsset[asset],
  );

  const { writeContractAsync, isPending, data: txHash, error: txError } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash: txHash });

  const isMine = !!account && !!seller && seller.toLowerCase() === account.toLowerCase();

  async function handleBuy() {
    if (!marketAddress) return;
    const id = BigInt(tokenId);
    if (asset === 'bnb') {
      await writeContractAsync({
        address: marketAddress,
        abi: MarketplaceAbi,
        functionName: 'buyWithBNB',
        args: [id],
        value: bnbDue !== undefined ? withCushion(bnbDue) : 0n,
      });
    } else {
      await writeContractAsync({
        address: marketAddress,
        abi: MarketplaceAbi,
        functionName: 'buyWithBNBULL',
        args: [id],
      });
    }
  }

  async function handleCancel() {
    if (!marketAddress) return;
    await writeContractAsync({
      address: marketAddress,
      abi: MarketplaceAbi,
      functionName: 'cancel',
      args: [BigInt(tokenId)],
    });
  }

  return (
    <div className="rounded border border-bull-border bg-bull-panel p-4">
      <div className="flex gap-4">
        <BullSprite token={token} scale={2} />
        <div className="flex-1">
          <Link href={`/bull/${tokenId}`} className="font-semibold hover:text-bull-gold">
            #{tokenId} {token.name}
          </Link>
          <p className="mt-1 font-mono text-xs text-bull-text-faint">
            seller {seller ? shortAddr(seller) : '…'}
          </p>
          <p className="mt-1 font-mono text-lg text-bull-gold">{formatUsd1e18(usdPrice)}</p>
        </div>
      </div>

      {isMine ? (
        <button
          onClick={handleCancel}
          disabled={isPending || isConfirming}
          className="mt-3 w-full rounded-full border border-bull-border px-3 py-1.5 text-xs text-bull-text-dim hover:border-bull-red hover:text-bull-red disabled:opacity-50"
        >
          {isPending || isConfirming ? 'sending…' : 'unlist'}
        </button>
      ) : (
        <div className="mt-3">
          <div className="flex gap-2">
            {(['bnb', 'bnbull'] as PayAsset[]).map((a) => (
              <button
                key={a}
                onClick={() => setAsset(a)}
                disabled={!availableForAsset[a]}
                title={a === 'bnbull' && !availableForAsset.bnbull ? CURRENCY.bnbullPending : undefined}
                className={`rounded-full border px-2.5 py-1 text-xs capitalize disabled:opacity-30 ${asset === a ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
              >
                {a}
              </button>
            ))}
          </div>
          <p className="mt-2 font-mono text-sm text-bull-gold">
            {formatToken(dueForAsset[asset], decimalsForAsset[asset])} {asset}
          </p>
          {!account ? (
            <p className="mt-2 text-xs text-bull-text-faint">connect a wallet to buy.</p>
          ) : !availableForAsset[asset] ? (
            <p className="mt-2 text-xs text-bull-text-faint">this leg isn&apos;t priced right now.</p>
          ) : asset !== 'bnb' && needsApproval ? (
            <button
              onClick={async () => {
                await approve();
                refetchAllowance();
              }}
              disabled={isApproving}
              className="mt-2 w-full rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-50"
            >
              {isApproving ? 'approving…' : 'approve'}
            </button>
          ) : (
            <button
              onClick={handleBuy}
              disabled={isPending || isConfirming}
              className="mt-2 w-full rounded-full border border-bull-gold bg-bull-gold px-3 py-1.5 text-xs font-semibold text-bull-gold-ink disabled:opacity-50"
            >
              {isPending || isConfirming ? 'buying…' : 'buy'}
            </button>
          )}
        </div>
      )}
      {confirmed && <p className="mt-2 text-xs text-bull-gold">done.</p>}
      {txError && <p className="mt-2 text-xs text-bull-red">{txError.message}</p>}
    </div>
  );
}
