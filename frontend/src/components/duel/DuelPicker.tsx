'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { DuelAbi, BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatToken, formatUsd1e18, formatBps } from '@/lib/format';
import { useMyBulls } from '@/lib/hooks/useMyBulls';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { QUOTE_REFRESH_MS } from '@/lib/constants';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { FightAction } from '@/components/duel/FightAction';
import { CURRENCY } from '@/lib/brand';

interface BullStruct {
  name: string;
  elo: number;
  isDead: boolean;
}

const ZERO = '0x0000000000000000000000000000000000000000' as const;

export function DuelPicker() {
  const duelAddress = contractAddress('duel');
  const { address: account } = useAccount();

  const { myIds, isLoading: loadingMine } = useMyBulls();
  const { data: myBullData } = useReadContracts({
    contracts: myIds.map((id) => ({
      address: contractAddress('bullsNft') ?? undefined,
      abi: BullsAbi,
      functionName: 'getBull' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: myIds.length > 0 },
  });
  const myAliveBulls = useMemo(
    () =>
      myIds
        .map((id, i) => ({ id, bull: myBullData?.[i]?.result as BullStruct | undefined }))
        .filter((x) => x.bull && !x.bull.isDead),
    [myIds, myBullData],
  );

  const [myTokenId, setMyTokenId] = useState<number | null>(null);
  const [oppInput, setOppInput] = useState('');
  const oppTokenId = /^\d+$/.test(oppInput) ? Number(oppInput) : null;

  const selectedMine = myTokenId ?? myAliveBulls[0]?.id ?? null;

  const { data: oppOwner, isError: oppOwnerError } = useReadContract({
    address: contractAddress('bullsNft') ?? undefined,
    abi: BullsAbi,
    functionName: 'ownerOf',
    args: oppTokenId !== null ? [BigInt(oppTokenId)] : undefined,
    query: { enabled: !!contractAddress('bullsNft') && oppTokenId !== null },
  });
  const { data: oppBull } = useReadContract({
    address: contractAddress('bullsNft') ?? undefined,
    abi: BullsAbi,
    functionName: 'getBull',
    args: oppTokenId !== null ? [BigInt(oppTokenId)] : undefined,
    query: { enabled: !!contractAddress('bullsNft') && oppTokenId !== null && !oppOwnerError },
  });

  const { data: allowSelfDuel } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'allowSelfDuel',
    query: { enabled: !!duelAddress },
  });
  const { data: lossesToDie } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'lossesToDie',
    query: { enabled: !!duelAddress },
  });

  const { data: mySeq } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'nextFightSeq',
    args: account ? [account] : undefined,
    query: { enabled: !!duelAddress && !!account },
  });
  const { data: oppSeq } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'nextFightSeq',
    args: oppOwner ? [oppOwner as `0x${string}`] : undefined,
    query: { enabled: !!duelAddress && !!oppOwner },
  });

  const { data: fightAssets } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'getFightAssets',
    query: { enabled: !!duelAddress },
  });
  const { data: bnbullAddr } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'bnbull',
    query: { enabled: !!duelAddress },
  });
  const { data: wbnbAddr } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'wbnb',
    query: { enabled: !!duelAddress },
  });

  const assetList = (fightAssets as readonly `0x${string}`[] | undefined) ?? [];

  /*
   * ⚠ THE PRICE IS READ, NEVER DERIVED HERE (`DECISIONS.md §26`).
   *
   * This used to reconstruct the BNB amount from "whichever registered asset
   * is neither BNBULL nor WBNB" (the stablecoin) as a dollar anchor, converted
   * through `MintDrop.bnbUsdPrice()`, because `Duel` had no oracle of its own
   * and `fightCostOf[wbnb]` was a flat keeper peg with no freshness guarantee.
   *
   * Dropping the stablecoin removed that anchor, so the conversion moved ON
   * CHAIN: `Duel.stickerCost()` converts the stored dollar figure through
   * Chainlink itself and `Duel.fighterCost()` takes the discount off the
   * result. Both are read below. A UI that recomputes a number it then asks
   * you to sign is a UI that can disagree with the contract, and two
   * implementations of one formula always drift.
   *
   * A REVERT IS AN ANSWER: `stickerCost` reverts on the BNB leg when the feed
   * is stale or out of band, by design. `allowFailure` turns that into "this
   * leg cannot be priced right now" rather than a blank page or a guess.
   */
  const {
    data: costsData,
    dataUpdatedAt: costsUpdatedAt,
  } = useReadContracts({
    allowFailure: true,
    contracts: assetList.flatMap((a) => [
      {
        address: duelAddress ?? undefined,
        abi: DuelAbi,
        functionName: 'fighterCost' as const,
        args: [a] as const,
      },
      {
        address: duelAddress ?? undefined,
        abi: DuelAbi,
        functionName: 'stickerCost' as const,
        args: [a] as const,
      },
      {
        address: duelAddress ?? undefined,
        abi: DuelAbi,
        functionName: 'discountBpsOf' as const,
        args: [a] as const,
      },
    ]),
    query: { enabled: !!duelAddress && assetList.length > 0, refetchInterval: QUOTE_REFRESH_MS },
  });

  /** The dollar sticker one fighter pays, straight off the contract. */
  const { data: usdFightPrice } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'usdFightPrice1e18',
    query: { enabled: !!duelAddress },
  });

  const quoteAge = costsUpdatedAt
    ? Math.max(0, Math.round((Date.now() - costsUpdatedAt) / 1000))
    : undefined;

  const isSelfDuel = !!account && !!oppOwner && (oppOwner as string).toLowerCase() === account.toLowerCase();
  const selfDuelBlocked = isSelfDuel && !allowSelfDuel;

  // Everything the page already knows would make `submitDuel` revert, collapsed
  // into one sentence for the fight button. The signer re-checks every one of
  // these against live chain state and the contract enforces them for real —
  // this is the polite version, not the enforcement.
  const oppIsDead = (oppBull as BullStruct | undefined)?.isDead === true;
  const fightBlockedReason: string | null = selfDuelBlocked
    ? "both bulls are in your wallet, and a wallet can't fight itself."
    : oppTokenId === null
      ? 'name an opponent by token id first.'
      : oppOwnerError
        ? `token #${oppTokenId} hasn't been minted.`
        : oppIsDead
          ? `bull #${oppTokenId} is in the graveyard and can't fight.`
          : selectedMine === null
            ? 'pick one of your living bulls first.'
            : null;

  if (!duelAddress) {
    return (
      <div>
        <NotDeployed what="the duel contract" className="mb-6" />
        <p className="text-sm text-bull-text-dim">
          once it&apos;s live: pick one of your bulls, name an opponent by token id, and this
          page will show exactly what each side puts in, straight off the contract. read, never
          recomputed here.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-8">
      <section>
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          1 · your bull
        </h2>
        {!account ? (
          <p className="mt-3 text-sm text-bull-text-dim">connect a wallet to see your herd.</p>
        ) : loadingMine ? (
          <p className="mt-3 text-sm text-bull-text-dim">loading your bulls…</p>
        ) : myAliveBulls.length === 0 ? (
          <p className="mt-3 text-sm text-bull-text-dim">
            no living bulls in this wallet.{' '}
            <Link href="/mint" className="text-bull-gold hover:underline">
              mint one
            </Link>{' '}
            first.
          </p>
        ) : (
          <select
            value={selectedMine ?? ''}
            onChange={(e) => setMyTokenId(Number(e.target.value))}
            className="mt-3 rounded border border-bull-border bg-bull-panel px-3 py-2 text-sm"
          >
            {myAliveBulls.map(({ id, bull }) => (
              <option key={id} value={id}>
                #{id} {bull?.name} · elo {bull?.elo}
              </option>
            ))}
          </select>
        )}
      </section>

      <section>
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          2 · opponent
        </h2>
        <div className="mt-3 flex items-center gap-2">
          <span className="text-bull-text-faint">#</span>
          <input
            type="text"
            inputMode="numeric"
            value={oppInput}
            onChange={(e) => setOppInput(e.target.value.replace(/[^\d]/g, ''))}
            placeholder="token id"
            className="w-28 rounded border border-bull-border bg-bull-panel px-3 py-2 text-sm"
          />
        </div>
        {oppTokenId !== null && (
          <div className="mt-3 text-sm">
            {oppOwnerError ? (
              <p className="text-bull-text-dim">token #{oppTokenId} hasn&apos;t been minted.</p>
            ) : !oppOwner ? (
              <p className="text-bull-text-dim">looking it up…</p>
            ) : (
              <p className="text-bull-text-dim">
                {(oppBull as BullStruct | undefined)?.name ?? '…'} · elo{' '}
                {(oppBull as BullStruct | undefined)?.elo ?? '—'} ·{' '}
                {(oppBull as BullStruct | undefined)?.isDead ? (
                  <span className="text-bull-red">dead, can&apos;t fight</span>
                ) : (
                  'alive'
                )}
              </p>
            )}
          </div>
        )}
      </section>

      {selfDuelBlocked && (
        <div className="rounded border border-bull-red/40 bg-bull-red/10 px-4 py-3 text-sm text-bull-red">
          a wallet can&apos;t fight itself. this bull and #{oppTokenId} are both held by the
          connected wallet, and self-duels are switched off. submitting this pair would
          revert on chain, not just get rejected here.
        </div>
      )}

      <section>
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          the one-fight-in-flight rule
        </h2>
        <p className="mt-3 max-w-xl text-sm text-bull-text-dim">
          each wallet can have exactly one signed fight in flight at a time. a fresh fight
          has to name your wallet&apos;s CURRENT sequence number, and settling bumps it, so a
          second signed result naming the same number can never land.
        </p>
        <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:w-80">
          <div>
            <dt className="font-mono text-xs text-bull-text-faint">your wallet&apos;s seq</dt>
            <dd className="font-mono">{account ? (mySeq !== undefined ? String(mySeq) : '…') : '—'}</dd>
          </div>
          <div>
            <dt className="font-mono text-xs text-bull-text-faint">opponent&apos;s seq</dt>
            <dd className="font-mono">{oppOwner ? (oppSeq !== undefined ? String(oppSeq) : '…') : '—'}</dd>
          </div>
        </dl>
      </section>

      <section>
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          fight cost, per asset
        </h2>
        <p className="mt-2 text-sm text-bull-text-dim">
          {lossesToDie !== undefined ? Number(lossesToDie) : 'five'} losses in a row, no win and
          no tie in between, and a bull is on the truck to market. both sides put up the same
          amount, in whichever currency each of them picks.
          {usdFightPrice !== undefined && (usdFightPrice as bigint) > 0n && (
            <>
              {' '}
              the sticker is{' '}
              <span className="text-bull-text">{formatUsd1e18(usdFightPrice as bigint)}</span> a
              side.
            </>
          )}
        </p>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full min-w-[420px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                <th className="py-2 pr-4">currency</th>
                <th className="py-2 pr-4">what each side puts in</th>
              </tr>
            </thead>
            <tbody>
              {assetList.map((a, i) => {
                // Three reads per asset, in order, from the flatMap above.
                const at = <T,>(off: number): T | undefined =>
                  costsData?.[i * 3 + off]?.status === 'success'
                    ? (costsData[i * 3 + off].result as T)
                    : undefined;
                return (
                  <AssetCostRow
                    key={a}
                    asset={a}
                    cost={at<bigint>(0)}
                    sticker={at<bigint>(1)}
                    discountBps={at<number>(2)}
                    bnbullAddr={bnbullAddr as `0x${string}` | undefined}
                    wbnbAddr={wbnbAddr as `0x${string}` | undefined}
                  />
                );
              })}
              {assetList.length === 0 && (
                <tr>
                  <td colSpan={2} className="py-3 text-bull-text-faint">
                    no fight currencies are registered yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {assetList.length > 0 && (
          <p className="mt-2 font-mono text-[11px] text-bull-text-faint">
            {quoteAge !== undefined ? `quoted ${quoteAge}s ago` : 'quoting…'} · refreshes every{' '}
            {QUOTE_REFRESH_MS / 1000}s
          </p>
        )}
      </section>

      <section>
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          3 · fight
        </h2>
        <p className="mt-2 max-w-xl text-sm text-bull-text-dim">
          the fight is simulated off chain from a random seed and the result is signed. the
          contract verifies the signature, it never re-runs the fight. the seed is public, so
          anyone can re-run it and catch a lying signer. that is what{' '}
          <span className="font-mono">/api/duel-gif</span> does before it will draw a replay.
        </p>
        <div className="mt-4">
          <FightAction
            duelAddress={duelAddress}
            myTokenId={selectedMine}
            oppTokenId={oppTokenId}
            blockedReason={fightBlockedReason}
          />
        </div>
      </section>
    </div>
  );
}

/**
 * One currency, one row. Everything shown here is a contract read:
 * `fighterCost` (what is charged), `stickerCost` (the undiscounted figure)
 * and `discountBpsOf`. Nothing on this row is computed by the browser, which
 * is exactly why the double-discount trap on `Duel.fighterCost` cannot be
 * re-created from this side.
 */
function AssetCostRow({
  asset,
  cost,
  sticker,
  discountBps,
  bnbullAddr,
  wbnbAddr,
}: {
  asset: `0x${string}`;
  cost: bigint | undefined;
  sticker: bigint | undefined;
  discountBps: number | undefined;
  bnbullAddr: `0x${string}` | undefined;
  wbnbAddr: `0x${string}` | undefined;
}) {
  const isBnbull = !!bnbullAddr && asset.toLowerCase() === bnbullAddr.toLowerCase();
  const isBnb = !!wbnbAddr && asset.toLowerCase() === wbnbAddr.toLowerCase();
  // ⚠ NEVER call an unrecognised asset "the stablecoin". There isn't one any
  // more (`DECISIONS.md §26`). If something else is ever registered on chain,
  // show its address, not a label we made up.
  const label = isBnbull ? 'bnbull' : isBnb ? 'bnb' : `${asset.slice(0, 6)}…${asset.slice(-4)}`;
  const { decimals } = useTokenDecimals(isBnb ? undefined : asset);
  const effectiveDecimals = isBnb ? NATIVE_BNB_DECIMALS : decimals;

  // A read that failed means the contract refused to quote. On the BNB leg
  // that is the designed answer to an unhealthy oracle; never fill it in.
  const unpriced = cost === undefined;
  // Zero is different again: nobody has pegged this leg yet, which is the
  // launch state for BNBULL (`DECISIONS.md §29`).
  const notYet = cost === 0n;
  const discounted = discountBps !== undefined && discountBps > 0;

  return (
    <tr className="border-b border-bull-border/60 align-top">
      <td className="py-2 pr-4 lowercase">{label}</td>
      <td className="py-2 pr-4 font-mono text-bull-gold">
        {asset === ZERO || unpriced || notYet ? (
          <span className="text-bull-text-faint">not available</span>
        ) : (
          <>
            {formatToken(cost, effectiveDecimals)} {label}
          </>
        )}
        {notYet && isBnbull && (
          <div className="mt-1 font-sans text-[11px] font-normal normal-case text-bull-text-faint">
            {CURRENCY.bnbullPending}
          </div>
        )}
        {unpriced && isBnb && (
          <div className="mt-1 font-sans text-[11px] font-normal normal-case text-bull-red">
            the chainlink feed is stale or out of band, so the contract will not quote a bnb
            fight right now. it refuses to guess and so does this page.
          </div>
        )}
        {!unpriced && !notYet && discounted && sticker !== undefined && (
          <div className="mt-1 font-sans text-[11px] font-normal normal-case text-bull-text-faint">
            {formatToken(sticker, effectiveDecimals)} before the {formatBps(discountBps)} discount
          </div>
        )}
      </td>
    </tr>
  );
}
