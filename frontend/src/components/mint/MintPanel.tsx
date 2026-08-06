'use client';

import { useMemo, useState } from 'react';
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { MintDropAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatUsd1e18, formatToken, formatBps } from '@/lib/format';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { withCushion, QUOTE_REFRESH_MS } from '@/lib/constants';
import { CURRENCY } from '@/lib/brand';

const STATIC_LADDER = [
  { upToSold: 100, usd: 10 },
  { upToSold: 200, usd: 20 },
  { upToSold: 300, usd: 35 },
  { upToSold: 400, usd: 50 },
  { upToSold: 500, usd: 75 },
];

/**
 * ⚠ TWO CURRENCIES (`DECISIONS.md §26`). The stablecoin leg is gone from the
 * contract, so `mintWithStable` no longer exists, `wires()` no longer returns
 * a stablecoin address, and `quote()` returns FOUR values instead of five.
 * Reading the old 5-tuple silently shifted every column by one and would have
 * shown the BNBULL amount where the BNB amount belongs.
 */
type PayAsset = 'bnb' | 'bnbull';

export function MintPanel() {
  const mintDropAddress = contractAddress('mintDrop');
  const { address: account } = useAccount();
  const [count, setCount] = useState(1);
  const [asset, setAsset] = useState<PayAsset>('bnb');

  const { data: totalSold, isLoading: loadingSold } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'totalSold',
    query: { enabled: !!mintDropAddress, refetchInterval: 15_000 },
  });
  const { data: maxMint, isLoading: loadingMax } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'MAX_MINT',
    query: { enabled: !!mintDropAddress },
  });
  const { data: tierCount } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'priceTierCount',
    query: { enabled: !!mintDropAddress },
  });
  const { data: bnbullAddress } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'bnbull',
    query: { enabled: !!mintDropAddress },
  });

  const tierIndices = useMemo(
    () => Array.from({ length: tierCount ? Number(tierCount) : 0 }, (_, i) => i),
    [tierCount],
  );
  const { data: tierRows } = useReadContracts({
    contracts: tierIndices.map((i) => ({
      address: mintDropAddress ?? undefined,
      abi: MintDropAbi,
      functionName: 'priceTierAt' as const,
      args: [BigInt(i)] as const,
    })),
    query: { enabled: !!mintDropAddress && tierIndices.length > 0 },
  });

  const supplyLoading = loadingSold || loadingMax;
  const sold = totalSold !== undefined ? Number(totalSold) : 0;
  const supply = maxMint !== undefined ? Number(maxMint) : 0;
  const remaining = Math.max(0, supply - sold);
  const maxCount = Math.max(1, Math.min(20, remaining || 1));

  // Short TTL, shown — the BNB leg converts through Chainlink at PAY time
  // (DECISIONS.md §1), so a quote sitting stale on screen is a failed tx
  // waiting to happen. Refetch on a clock and surface the age.
  const { data: quote, dataUpdatedAt: quoteUpdatedAt } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'quote',
    args: [BigInt(count)],
    query: { enabled: !!mintDropAddress && remaining > 0, refetchInterval: QUOTE_REFRESH_MS },
  });
  const quoteAgeSeconds = quoteUpdatedAt ? Math.max(0, Math.round((Date.now() - quoteUpdatedAt) / 1000)) : undefined;
  // `MintDrop.quote(count)` -> (usdTotal1e18, bnbDue, bnbullDue, bnbUsd1e18).
  // FOUR values since `DECISIONS.md §26` dropped the stablecoin leg.
  const [usdTotal, bnbDue, bnbullDue] = (quote as
    | readonly [bigint, bigint, bigint, bigint]
    | undefined) ?? [undefined, undefined, undefined, undefined];

  const { decimals: bnbullDecimals } = useTokenDecimals(bnbullAddress as `0x${string}` | undefined);

  const { data: bnbullDiscountBps } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'discountBpsOf',
    args: bnbullAddress ? [bnbullAddress as `0x${string}`] : undefined,
    query: { enabled: !!mintDropAddress && !!bnbullAddress },
  });

  // Tier status derived from live `totalSold`, not guessed — a tier is
  // "live" once the previous tier's cap is met and this one's isn't yet.
  // Every integer field decodes as `bigint` regardless of its solidity
  // width (uint16 included) — never assume `number` off a contract read.
  const tierStatus = useMemo(() => {
    const rows = (tierRows ?? [])
      .map((r) => r.result as { upToSold: bigint; usdPrice: bigint } | undefined)
      .filter((t): t is { upToSold: bigint; usdPrice: bigint } => !!t);
    let prevCap = 0;
    return rows.map((tier) => {
      const cap = Number(tier.upToSold);
      const status: 'sold out' | 'live' | 'upcoming' =
        sold >= cap ? 'sold out' : sold >= prevCap ? 'live' : 'upcoming';
      prevCap = cap;
      return { tier, status };
    });
  }, [tierRows, sold]);

  const dueForAsset: Record<PayAsset, bigint | undefined> = {
    bnb: bnbDue,
    bnbull: bnbullDue,
  };
  const decimalsForAsset: Record<PayAsset, number | undefined> = {
    bnb: NATIVE_BNB_DECIMALS,
    bnbull: bnbullDecimals,
  };
  // A zero BNBULL quote is not an error, it is `DECISIONS.md §29`: four.meme
  // holds the token transfer-locked until its curve fills, so the leg is
  // present in the contract and simply not switched on. Say so, do not error.
  const bnbullUnavailable = bnbullDue === undefined || bnbullDue === 0n;

  const approvalToken = asset === 'bnbull' ? (bnbullAddress as `0x${string}` | undefined) : undefined;
  const approvalRequired = asset === 'bnbull' ? bnbullDue : undefined;
  const { needsApproval, approve, isApproving, refetchAllowance } = useErc20Approval(
    approvalToken,
    mintDropAddress ?? undefined,
    approvalRequired,
  );

  const { writeContractAsync, isPending: isMinting, data: mintHash, error: mintError } = useWriteContract();
  const { isLoading: isConfirmingMint, isSuccess: mintConfirmed } = useWaitForTransactionReceipt({
    hash: mintHash,
  });

  async function handleMint() {
    if (!mintDropAddress || !account) return;
    if (asset === 'bnb' && bnbDue !== undefined) {
      await writeContractAsync({
        address: mintDropAddress,
        abi: MintDropAbi,
        functionName: 'mintWithBNB',
        args: [account, BigInt(count)],
        value: withCushion(bnbDue),
      });
    } else if (asset === 'bnbull') {
      await writeContractAsync({
        address: mintDropAddress,
        abi: MintDropAbi,
        functionName: 'mintWithBNBULL',
        args: [account, BigInt(count)],
      });
    }
  }

  if (!mintDropAddress) {
    return (
      <div>
        <NotDeployed what="the mint" className="mb-8" />
        <h3 className="bull-header text-lg">the ladder</h3>
        <p className="mt-2 max-w-2xl text-bull-text-dim">
          the shape is locked. the numbers below come straight off the contract the moment
          there is one.
        </p>
        <div className="mt-6 overflow-x-auto">
          <table className="w-full min-w-[420px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                <th className="py-2 pr-4">up to sold</th>
                <th className="py-2 pr-4">price</th>
                <th className="py-2 pr-4">bnbull leg (−10%)</th>
              </tr>
            </thead>
            <tbody>
              {STATIC_LADDER.map((row) => (
                <tr key={row.upToSold} className="border-b border-bull-border/60">
                  <td className="py-2 pr-4 font-mono">{row.upToSold}</td>
                  <td className="py-2 pr-4 font-mono text-bull-gold">${row.usd}</td>
                  <td className="py-2 pr-4 font-mono text-bull-text-dim">${(row.usd * 0.9).toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    );
  }

  return (
    <div>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="font-mono text-sm text-bull-text-dim">
          {supplyLoading ? (
            'loading…'
          ) : (
            <>
              <span className="text-bull-gold">{sold}</span> / {supply} minted
            </>
          )}
        </p>
        <p className="font-mono text-sm text-bull-text-faint">
          {supplyLoading ? '' : `${remaining} left`}
        </p>
      </div>
      <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-bull-panel">
        <div
          className="h-full bg-bull-gold transition-all"
          style={{ width: supplyLoading || !supply ? '0%' : `${Math.min(100, (sold / supply) * 100)}%` }}
        />
      </div>

      <div className="mt-8 overflow-x-auto">
        <table className="w-full min-w-[520px] border-collapse text-sm">
          <thead>
            <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
              <th className="py-2 pr-4">up to sold</th>
              <th className="py-2 pr-4">price</th>
              <th className="py-2 pr-4">status</th>
            </tr>
          </thead>
          <tbody>
            {tierStatus.map(({ tier, status }) => (
              <tr key={String(tier.upToSold)} className="border-b border-bull-border/60">
                <td className="py-2 pr-4 font-mono">{Number(tier.upToSold)}</td>
                <td className="py-2 pr-4 font-mono text-bull-gold">{formatUsd1e18(tier.usdPrice)}</td>
                <td
                  className={`py-2 pr-4 font-mono text-xs uppercase ${
                    status === 'live'
                      ? 'text-bull-gold'
                      : status === 'sold out'
                        ? 'text-bull-text-faint'
                        : 'text-bull-text-dim'
                  }`}
                >
                  {status}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {supplyLoading ? (
        <p className="mt-8 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          loading the live drop state…
        </p>
      ) : remaining === 0 ? (
        <p className="mt-8 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          the drop is sold out.
        </p>
      ) : (
        <div className="mt-8 rounded border border-bull-border bg-bull-panel p-4">
          <div className="flex items-center gap-3">
            <label className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
              count
            </label>
            <input
              type="number"
              min={1}
              max={maxCount}
              value={count}
              onChange={(e) => setCount(Math.max(1, Math.min(maxCount, Number(e.target.value) || 1)))}
              className="w-20 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-sm"
            />
            <span className="text-xs text-bull-text-faint">max {maxCount} per tx</span>
          </div>

          <p className="mt-4 font-mono text-sm text-bull-text-dim">
            total sticker: <span className="text-bull-text">{formatUsd1e18(usdTotal)}</span>
          </p>

          <div className="mt-4 flex gap-2">
            <button
              onClick={() => setAsset('bnb')}
              className={`rounded-full border px-3 py-1.5 text-xs font-medium ${asset === 'bnb' ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
            >
              bnb
            </button>
            <button
              onClick={() => setAsset('bnbull')}
              disabled={bnbullUnavailable}
              title={bnbullUnavailable ? CURRENCY.bnbullPending : undefined}
              className={`rounded-full border px-3 py-1.5 text-xs font-medium disabled:opacity-40 ${asset === 'bnbull' ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
            >
              bnbull{bnbullDiscountBps ? ` (−${formatBps(bnbullDiscountBps)})` : ''}
            </button>
          </div>

          {bnbullUnavailable && (
            <p className="mt-2 text-[11px] text-bull-text-faint">{CURRENCY.bnbullPending}</p>
          )}

          <p className="mt-4 font-mono text-lg text-bull-gold">
            {formatToken(dueForAsset[asset], decimalsForAsset[asset])}{' '}
            <span className="text-sm text-bull-text-dim">{asset}</span>
          </p>
          <p className="mt-1 font-mono text-[11px] text-bull-text-faint">
            {quoteAgeSeconds !== undefined ? `quoted ${quoteAgeSeconds}s ago` : 'quoting…'} · refreshes
            every {QUOTE_REFRESH_MS / 1000}s · send a small cushion, the surplus is refunded
          </p>

          {!account ? (
            <p className="mt-4 text-sm text-bull-text-faint">connect a wallet to mint.</p>
          ) : asset !== 'bnb' && needsApproval ? (
            <button
              onClick={async () => {
                await approve();
                refetchAllowance();
              }}
              disabled={isApproving}
              className="bull-btn mt-4 w-full"
            >
              {isApproving ? 'approving…' : 'approve bnbull'}
            </button>
          ) : (
            <button
              onClick={handleMint}
              disabled={isMinting || isConfirmingMint}
              className="bull-btn bull-btn-pulse mt-4 w-full"
            >
              {isMinting || isConfirmingMint ? 'minting…' : `mint ${count}`}
            </button>
          )}
          {mintConfirmed && (
            <p className="mt-3 text-sm text-bull-gold">minted. check your wallet.</p>
          )}
          {mintError && (
            <p className="mt-3 text-sm text-bull-red">{mintError.message}</p>
          )}
        </div>
      )}
    </div>
  );
}
