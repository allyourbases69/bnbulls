'use client';

import { useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID } from '@/lib/env';
import { formatToken, formatUsd1e18, shortAddr } from '@/lib/format';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';
import { PitSaleNotice } from '@/components/duel/PitPanel';
import { withCushion, QUOTE_REFRESH_MS } from '@/lib/constants';
import { CURRENCY } from '@/lib/brand';
import type { Token } from '@/lib/art/bull';
import type { ActiveListing } from '@/lib/hooks/useActiveListings';
import { BullCardFace } from './BullCardFace';
import type { BullRecord } from './bullRecord';

/**
 * One listing on the board — a port of fighting fefers' `/market`
 * `ListingCard`: the id and rarity badge, the art, the name, the weapon, the
 * price, then rating and record, all clickable through to the bull's own page.
 *
 * ⚠ ONE DELIBERATE DIFFERENCE FROM FEFERS, AND IT IS NOT A DESIGN CHOICE.
 * On fefers the card is a bare `<Link>` with no buy button, because buying,
 * repricing and cancelling all live in `MarketplacePanel` on
 * `/warrior/[id]`. bnbulls has no such panel: the detail page is
 * `frontend/src/app/bull/[id]/page.tsx` + `components/bull/BullOnChainPanel.tsx`,
 * both OUTSIDE this task's assigned paths, and `BullOnChainPanel` only reports
 * "listed · $X" with a link back to `/market`. Porting the bare link exactly
 * would therefore have removed the only way to buy a bull anywhere on the
 * site. So the fefers card FACE is ported verbatim and the buy/unlist controls
 * stay appended below it, outside the anchor (an interactive control nested in
 * an `<a>` is invalid html and swallows the click).
 * The fix is to port `MarketplacePanel` onto the bull detail page; it needs an
 * owner of `components/bull/**`.
 *
 * ⚠ TWO CURRENCIES (`DECISIONS.md §26`). `buyWithStable` is gone,
 * `quote()` returns FOUR values instead of five, and `wires()` returns TWO
 * addresses `(priceFeed, bnbull)` instead of three with a stablecoin first —
 * so the old destructure was reading the PRICE FEED address as the token to
 * approve. Fefers' single `USDT0` leg has no counterpart here and its
 * `$${formatUnits(price, 6)}` price format is one of the sites
 * `DECISIONS.md §26` explicitly killed.
 *
 * ⚠ THE LISTING COMES IN AS A PROP, IT IS NOT RE-READ HERE. `useActiveListings`
 * already pulled every live `Listing` in one multicall, and the browse grid
 * cannot sort or filter on a price no component above the card has seen. The
 * sticker therefore renders instantly off stored state; only the BNB/BNBULL
 * conversion waits on the oracle, which is the one number that genuinely moves.
 */
type PayAsset = 'bnb' | 'bnbull';

export function ListingCard({
  listing,
  token,
  record,
  recordFailed,
}: {
  listing: ActiveListing;
  token: Token;
  record: BullRecord | null;
  recordFailed?: boolean;
}) {
  const tokenId = listing.tokenId;
  const marketAddress = contractAddress('marketplace');
  const { address: account } = useAccount();
  const [asset, setAsset] = useState<PayAsset>('bnb');
  const { wrongNetwork } = useWrongNetwork();

  const {
    data: quote,
    isError: quoteError,
    isLoading: quoteLoading,
  } = useReadContract({
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

  // `Marketplace.quote(tokenId)` -> (usdPrice1e18, bnbDue, bnbullDue, bnbUsd1e18).
  const [, bnbDue, bnbullDue] =
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

  const { writeContractAsync, isPending, data: txHash } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash: txHash });
  const { preflight, checking } = usePreflight();
  // ⚠ DECODED, NEVER `txError.message`. A listing is the most race-prone thing
  // on the site: it can be bought, cancelled or repriced by somebody else
  // between this card rendering and the click landing, and every one of those
  // has a real sentence (`NotListed`, `PaymentShortfall`, `OracleStale`).
  const [revert, setRevert] = useState<DecodedRevert | null>(null);

  const isMine = !!account && listing.seller.toLowerCase() === account.toLowerCase();

  // ⚠ Every branch pins `chainId`. Without it wagmi hands viem `chain: null`,
  // viem skips `assertCurrentChain`, and `buyWithBNB` pays a codeless address
  // on whatever chain the wallet is on. See `useWrongNetwork`.
  //
  // ⚠ AND EVERY BRANCH IS SIMULATED FIRST. The listing shown on this card came
  // out of a batched read that is seconds old by the time anybody clicks, so
  // "somebody else bought it" is the NORMAL failure here, not an exotic one.
  async function handleBuy() {
    if (!marketAddress || wrongNetwork) return;
    setRevert(null);
    const id = BigInt(tokenId);
    const value = asset === 'bnb' && bnbDue !== undefined ? withCushion(bnbDue) : undefined;
    const fn = asset === 'bnb' ? 'buyWithBNB' : 'buyWithBNBULL';

    const pre = await preflight({
      address: marketAddress,
      abi: MarketplaceAbi,
      functionName: fn,
      args: [id],
      value: asset === 'bnb' ? (value ?? 0n) : undefined,
    });
    if (!pre.ok) {
      setRevert(pre.error);
      return;
    }

    try {
      if (asset === 'bnb') {
        await writeContractAsync({
          address: marketAddress,
          abi: MarketplaceAbi,
          chainId: CHAIN_ID,
          functionName: 'buyWithBNB',
          args: [id],
          value: value ?? 0n,
        });
      } else {
        await writeContractAsync({
          address: marketAddress,
          abi: MarketplaceAbi,
          chainId: CHAIN_ID,
          functionName: 'buyWithBNBULL',
          args: [id],
        });
      }
    } catch (e) {
      setRevert(decodeRevert(e));
    }
  }

  async function handleCancel() {
    if (!marketAddress || wrongNetwork) return;
    setRevert(null);
    const call = {
      address: marketAddress,
      abi: MarketplaceAbi,
      functionName: 'cancel' as const,
      args: [BigInt(tokenId)] as const,
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

  return (
    <div className="bull-card bull-card-hover flex flex-col p-3">
      <Link href={`/bull/${tokenId}`} className="group block">
        <BullCardFace token={token} record={record} recordFailed={recordFailed} />
      </Link>

      {/* Price. Fefers puts this on its own bordered row at the foot of the
          card and so does this. */}
      <div className="mt-2 flex items-baseline justify-between border-t border-bull-border pt-1 font-mono text-sm">
        <span className="text-bull-text-faint">price</span>
        <span className="text-sm font-bold text-bull-gold">{formatUsd1e18(listing.usdPrice)}</span>
      </div>
      <div className="font-mono text-xs text-bull-text-faint">
        seller {isMine ? 'you' : shortAddr(listing.seller)}
      </div>

      <WrongNetworkNotice className="mt-3" />

      {isMine ? (
        <button
          onClick={handleCancel}
          disabled={isPending || isConfirming || checking || wrongNetwork}
          className="mt-3 w-full rounded-full border border-bull-border px-3 py-1.5 text-xs text-bull-text-dim hover:border-bull-red hover:text-bull-red disabled:opacity-50"
        >
          {wrongNetwork ? 'wrong network' : checking ? 'checking…' : isPending || isConfirming ? 'sending…' : 'unlist'}
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
          ) : quoteError ? (
            // `quote()` reverts on a stale or non-positive feed rather than
            // clamping (`DECISIONS.md §1`), so there is no bnb figure to show.
            <p className="mt-2 text-xs text-bull-text-faint">
              the price feed didn&apos;t answer, so there is no live bnb figure. the sticker
              above is the seller&apos;s and hasn&apos;t moved.
            </p>
          ) : quoteLoading ? (
            <p className="mt-2 text-xs text-bull-text-faint">pricing…</p>
          ) : !availableForAsset[asset] ? (
            <p className="mt-2 text-xs text-bull-text-faint">this leg isn&apos;t priced right now.</p>
          ) : asset !== 'bnb' && needsApproval ? (
            <button
              onClick={async () => {
                // ⚠ CAUGHT. This used to be a bare `await approve()`, so a
                // rejected or failing approval threw into an unhandled promise
                // rejection and the player saw NOTHING AT ALL — the silent end
                // of the same bug class as "gas limit too high".
                try {
                  await approve();
                  refetchAllowance();
                } catch (e) {
                  setRevert(decodeRevert(e));
                }
              }}
              disabled={isApproving || wrongNetwork}
              className="mt-2 w-full rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-50"
            >
              {isApproving ? 'approving…' : 'approve'}
            </button>
          ) : (
            <button
              onClick={handleBuy}
              disabled={isPending || isConfirming || checking || wrongNetwork}
              className="mt-2 w-full rounded-full border border-bull-gold bg-bull-gold px-3 py-1.5 text-xs font-semibold text-bull-gold-ink disabled:opacity-50"
            >
              {wrongNetwork ? 'wrong network' : checking ? 'checking…' : isPending || isConfirming ? 'buying…' : 'buy'}
            </button>
          )}
        </div>
      )}
      {confirmed && (
        <>
          <p className="mt-2 text-xs text-bull-gold">done.</p>
          {/* ⚠ THE MOMENT A BUYER MOST NEEDS THIS. `Yards` membership is stored
              against the wallet that entered the bull, so the purchase that
              just landed VOIDED it: they now hold a bull nobody can fight until
              they send it in themselves, with no event and nothing on the token
              to show it. Not telling them here is how bull #16 turned into a
              "gas limit too high" bug report. */}
          {!isMine && <PitSaleNotice className="mt-2" />}
        </>
      )}
      <RevertNotice error={revert} className="mt-2" />
    </div>
  );
}
