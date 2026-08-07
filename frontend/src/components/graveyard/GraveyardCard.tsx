'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { BullsAbi, GraveyardAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID } from '@/lib/env';
import { formatToken, formatUsd1e18, formatDuration, shortAddr } from '@/lib/format';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';
import { withCushion } from '@/lib/constants';
import { BullSprite } from '@/components/BullSprite';
import { getBull } from '@/lib/art/collection';
import { CURRENCY, DEATH } from '@/lib/brand';

interface BullStruct {
  name: string;
}

/**
 * ⚠ TWO CURRENCIES (`DECISIONS.md §26`). `resurrectWithStable` and
 * `resurrectAndClaimWithStable` no longer exist, `quotePayment()` returns
 * THREE values instead of four, and `wires()` returns THREE addresses with no
 * stablecoin among them. Reading the old shapes shifted every column by one.
 */
type PayAsset = 'bnb' | 'bnbull';
type Lane = 'owner' | 'takeover';

export function GraveyardCard({ tokenId }: { tokenId: number }) {
  const graveyardAddress = contractAddress('graveyard');
  const bullsAddress = contractAddress('bullsNft');
  const { address: account } = useAccount();
  const token = getBull(tokenId);

  const { data: onChainBull } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'getBull',
    args: [BigInt(tokenId)],
    query: { enabled: !!bullsAddress },
  });
  const { data: owner } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'ownerOf',
    args: [BigInt(tokenId)],
    query: { enabled: !!bullsAddress },
  });
  const { data: quoteResurrect } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'quoteResurrect',
    args: [BigInt(tokenId)],
    query: { enabled: !!graveyardAddress },
  });
  const { data: maxResurrects } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'maxResurrects',
    query: { enabled: !!graveyardAddress },
  });
  const { data: bnbullAddr } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'bnbull',
    query: { enabled: !!graveyardAddress },
  });

  const [allowed, used, ownerUsd1e18, takeoverUsd1e18, takeoverOpensAt] =
    (quoteResurrect as readonly [boolean, bigint, bigint, bigint, bigint] | undefined) ?? [
      false,
      0n,
      0n,
      0n,
      0n,
    ];

  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);
  const takeoverOpen = takeoverOpensAt === 0n || now >= Number(takeoverOpensAt);
  const secondsUntilOpen = takeoverOpen ? 0 : Number(takeoverOpensAt) - now;

  const isMine = !!account && !!owner && (owner as string).toLowerCase() === account.toLowerCase();

  /**
   * ⚠ THE DEFAULT LANE HAS TO FOLLOW OWNERSHIP, AND `useState(isMine ? …)` DID
   * NOT. `ownerOf` is an async read, so on the first render `owner` is
   * undefined and `isMine` is false for everybody, holder included. A
   * `useState` initialiser runs once and never revisits, so the holder's card
   * settled on the TAKEOVER lane permanently: the dearer of the two ladders,
   * and — while the owner head-start is still running — `takeoverOpen` is false
   * so the card renders no action button at all. The holder saw a higher price
   * and no way to pay it, on his own bull.
   *
   * Deriving it instead means the default re-evaluates the moment the read
   * lands, and the override keeps a deliberate lane choice from being yanked
   * back by a refetch.
   */
  const [laneOverride, setLaneOverride] = useState<Lane | null>(null);
  const lane: Lane = laneOverride ?? (isMine ? 'owner' : 'takeover');
  const setLane = setLaneOverride;

  const [asset, setAsset] = useState<PayAsset>('bnb');
  const { wrongNetwork } = useWrongNetwork();

  const usdForLane = lane === 'owner' ? ownerUsd1e18 : takeoverUsd1e18;
  const { data: paymentQuote } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'quotePayment',
    args: [usdForLane],
    query: { enabled: !!graveyardAddress && allowed && usdForLane > 0n },
  });
  // `Graveyard.quotePayment(usd1e18)` -> (bnbDue, bnbullDue, bnbUsd1e18).
  const [bnbDue, bnbullDue] =
    (paymentQuote as readonly [bigint, bigint, bigint] | undefined) ?? [undefined, undefined];

  const { decimals: bnbullDecimals } = useTokenDecimals(bnbullAddr as `0x${string}` | undefined);

  const dueForAsset: Record<PayAsset, bigint | undefined> = { bnb: bnbDue, bnbull: bnbullDue };
  const decimalsForAsset: Record<PayAsset, number | undefined> = {
    bnb: NATIVE_BNB_DECIMALS,
    bnbull: bnbullDecimals,
  };
  // Zero is "not switched on yet", not an error — `DECISIONS.md §29`.
  const bnbullUnavailable = bnbullDue === undefined || bnbullDue === 0n;

  const approvalToken = asset === 'bnbull' ? (bnbullAddr as `0x${string}` | undefined) : undefined;
  const { needsApproval, approve, isApproving, refetchAllowance } = useErc20Approval(
    approvalToken,
    graveyardAddress ?? undefined,
    dueForAsset[asset],
  );

  const { writeContractAsync, isPending, data: txHash } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash: txHash });
  const { preflight, checking } = usePreflight();
  // ⚠ DECODED, NEVER `txError.message`. This card used to render the wallet's
  // own string, which is how "gas limit too high" reaches a player.
  const [revert, setRevert] = useState<DecodedRevert | null>(null);

  // ⚠ Every branch pins `chainId`. Without it wagmi hands viem `chain: null`,
  // viem skips `assertCurrentChain`, and the two BNB branches send `value` to
  // a codeless address on whatever chain the wallet is on. See
  // `useWrongNetwork`.
  /**
   * ⚠ THE SAME BUG CLASS AS THE FIGHT PAGE, AND THIS ONE SPENDS MORE MONEY.
   *
   * Every input to a revive is live chain state that can be invalidated
   * underneath the card without any event the browser could listen for:
   * somebody else revives the bull first (`NotDead`), the previous owner's head
   * start has not run out (`OwnerPriority`), the bull is out of lives
   * (`GoneForever`), the ladder rung moved (`CostTooHigh`), or the chainlink
   * feed went stale between the quote and the click (`OracleStale`). Each of
   * those has a precise, actionable sentence, and without a dry run the player
   * would get the rpc's opinion about gas instead.
   */
  async function handlePay() {
    if (!graveyardAddress || wrongNetwork) return;
    const id = BigInt(tokenId);
    setRevert(null);

    const fn =
      asset === 'bnb'
        ? lane === 'owner'
          ? 'resurrectWithBNB'
          : 'resurrectAndClaimWithBNB'
        : lane === 'owner'
          ? 'resurrectWithBNBULL'
          : 'resurrectAndClaimWithBNBULL';
    const preValue =
      asset === 'bnb' ? (bnbDue !== undefined ? withCushion(bnbDue) : 0n) : undefined;

    const pre = await preflight({
      address: graveyardAddress,
      abi: GraveyardAbi,
      functionName: fn,
      args: [id],
      value: preValue,
    });
    if (!pre.ok) {
      setRevert(pre.error);
      return;
    }

    try {
      await sendPay(id);
    } catch (e) {
      setRevert(decodeRevert(e));
    }
  }

  // Built as explicit branches rather than a function-name lookup table: a
  // payable call (BNB) and a non-payable one (BNBULL) have different `value`
  // shapes in the generated ABI's type union, so one generic call object
  // cannot type-check across all four functions at once.
  async function sendPay(id: bigint) {
    if (!graveyardAddress) return;
    if (asset === 'bnb') {
      const value = bnbDue !== undefined ? withCushion(bnbDue) : 0n;
      if (lane === 'owner') {
        await writeContractAsync({
          address: graveyardAddress,
          abi: GraveyardAbi,
          chainId: CHAIN_ID,
          functionName: 'resurrectWithBNB',
          args: [id],
          value,
        });
      } else {
        await writeContractAsync({
          address: graveyardAddress,
          abi: GraveyardAbi,
          chainId: CHAIN_ID,
          functionName: 'resurrectAndClaimWithBNB',
          args: [id],
          value,
        });
      }
    } else {
      if (lane === 'owner') {
        await writeContractAsync({
          address: graveyardAddress,
          abi: GraveyardAbi,
          chainId: CHAIN_ID,
          functionName: 'resurrectWithBNBULL',
          args: [id],
        });
      } else {
        await writeContractAsync({
          address: graveyardAddress,
          abi: GraveyardAbi,
          chainId: CHAIN_ID,
          functionName: 'resurrectAndClaimWithBNBULL',
          args: [id],
        });
      }
    }
  }

  const name = (onChainBull as BullStruct | undefined)?.name ?? token.name;

  return (
    <div className="rounded border border-bull-border bg-bull-panel p-4">
      <div className="flex gap-4">
        <BullSprite token={token} scale={2} />
        <div className="flex-1">
          <Link href={`/bull/${tokenId}`} className="font-semibold hover:text-bull-gold">
            #{tokenId} {name}
          </Link>
          <p className="mt-1 font-mono text-xs text-bull-text-faint">
            held by {owner ? shortAddr(owner as string) : '…'} · rung {String(used)} /{' '}
            {maxResurrects !== undefined ? String(maxResurrects) : '…'}
          </p>
        </div>
      </div>

      {!allowed ? (
        <p className="mt-4 text-sm text-bull-red">{DEATH.gone}</p>
      ) : (
        <div className="mt-4">
          <div className="flex gap-2">
            <button
              onClick={() => setLane('owner')}
              disabled={!isMine}
              className={`rounded-full border px-3 py-1 text-xs disabled:opacity-30 ${lane === 'owner' ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
            >
              revive · {formatUsd1e18(ownerUsd1e18)}
            </button>
            <button
              onClick={() => setLane('takeover')}
              disabled={!takeoverOpen}
              className={`rounded-full border px-3 py-1 text-xs disabled:opacity-30 ${lane === 'takeover' ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
            >
              takeover · {formatUsd1e18(takeoverUsd1e18)}
            </button>
          </div>
          {!isMine && !takeoverOpen && (
            <p className="mt-2 text-xs text-bull-text-faint">
              owner head-start · takeover opens in {formatDuration(secondsUntilOpen)}
            </p>
          )}
          {!isMine && takeoverOpen && (
            <p className="mt-2 text-xs text-bull-text-faint">
              takeover is open. you&apos;d claim this bull into your own wallet.
            </p>
          )}

          <div className="mt-3 flex gap-2">
            {(['bnb', 'bnbull'] as PayAsset[]).map((a) => (
              <button
                key={a}
                onClick={() => setAsset(a)}
                disabled={a === 'bnbull' && bnbullUnavailable}
                title={a === 'bnbull' && bnbullUnavailable ? CURRENCY.bnbullPending : undefined}
                className={`rounded-full border px-2.5 py-1 text-xs capitalize disabled:opacity-30 ${asset === a ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
              >
                {a}
              </button>
            ))}
          </div>
          {bnbullUnavailable && (
            <p className="mt-1.5 text-[11px] text-bull-text-faint">{CURRENCY.bnbullPending}</p>
          )}

          <p className="mt-2 font-mono text-sm text-bull-gold">
            {formatToken(dueForAsset[asset], decimalsForAsset[asset])} {asset}
          </p>

          <WrongNetworkNotice className="mt-3" />

          {!account ? (
            <p className="mt-2 text-xs text-bull-text-faint">connect a wallet.</p>
          ) : lane === 'owner' && !isMine ? (
            <p className="mt-2 text-xs text-bull-text-faint">only the holder can use this lane.</p>
          ) : lane === 'takeover' && !takeoverOpen ? null : asset !== 'bnb' && needsApproval ? (
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
              className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-50"
            >
              {isApproving ? 'approving…' : 'approve'}
            </button>
          ) : (
            <button
              onClick={handlePay}
              disabled={isPending || isConfirming || checking || wrongNetwork}
              className="mt-3 rounded-full border border-bull-gold bg-bull-gold px-3 py-1.5 text-xs font-semibold text-bull-gold-ink disabled:opacity-50"
            >
              {wrongNetwork
                ? 'wrong network'
                : isPending || isConfirming
                  ? 'sending…'
                  : checking
                    ? 'checking…'
                    : lane === 'owner'
                      ? 'revive'
                      : 'revive & claim'}
            </button>
          )}
          {confirmed && <p className="mt-2 text-xs text-bull-gold">done.</p>}
          <RevertNotice error={revert} className="mt-2" />
        </div>
      )}
    </div>
  );
}
