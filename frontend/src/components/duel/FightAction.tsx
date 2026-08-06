'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useAccount, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { DuelAbi } from '@/lib/abi';
import { formatToken } from '@/lib/format';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { useDuelSession } from '@/lib/hooks/useDuelSession';
import { explorerBaseUrl } from '@/lib/env';

/**
 * The fight button.
 *
 * Three steps, and they are deliberately visible rather than collapsed into one
 * "FIGHT" that does everything, because each one fails differently:
 *
 *   1. SIGN IN — one `personal_sign`, cached for a day. Not a transaction.
 *   2. ROLL — `POST /api/run-duel`. Returns a fully signed, submittable result
 *      with the winner already in it. Your wallet holds ONE of these at a time:
 *      asking again gives the same fight back until it settles, which is what
 *      stops anyone rolling until they find a win and dropping the rest.
 *   3. SETTLE — `Duel.submitDuel(result, signature)` from your own wallet,
 *      preceded by an ERC-20 approval when the stake is not being paid in raw
 *      BNB.
 *
 * ⚠ THE COUNTDOWN IS NOT DECORATION. The signed struct carries the EXACT amount
 * each side is charged, and on the BNB leg that number was converted from a
 * dollar sticker through the Chainlink feed at quote time. It stops tracking
 * the dollar the moment it is signed, which is why the expiry is short and why
 * this component refuses to submit a stale result instead of letting the wallet
 * discover `Expired()` for itself.
 */

interface DuelResultJson {
  tokenA: string;
  tokenB: string;
  winnerId: number;
  rounds: number;
  seed: string;
  newEloA: number;
  newEloB: number;
  assetA: `0x${string}`;
  assetB: `0x${string}`;
  stakeA: string;
  stakeB: string;
  seqA: string;
  seqB: string;
  nonce: string;
  expiry: string;
}

interface RunDuelJson {
  result: DuelResultJson;
  signature: `0x${string}`;
  winnerId: number | null;
  rounds: number;
  deltaA: number;
  deltaB: number;
  stakes: {
    assetA: `0x${string}`;
    assetB: `0x${string}`;
    symbolA: string;
    symbolB: string;
    decimalsA: number;
    decimalsB: number;
    amountA: string;
    amountB: string;
    oracleA: boolean;
    oracleB: boolean;
  };
  nativeValue?: string;
  ttlSeconds: number;
  standingFight?: { challengerTokenId: number; opponentTokenId: number; since: number };
}

const ZERO = '0x0000000000000000000000000000000000000000' as const;

export function FightAction({
  duelAddress,
  myTokenId,
  oppTokenId,
  blockedReason,
}: {
  duelAddress: `0x${string}`;
  myTokenId: number | null;
  oppTokenId: number | null;
  /** Set when the page already knows this pair would revert. Disables step 2. */
  blockedReason: string | null;
}) {
  const { address: account } = useAccount();
  const { ensureSession, isSigning, error: sessionError, hasSession, clear } = useDuelSession();

  const [rolling, setRolling] = useState(false);
  const [quote, setQuote] = useState<RunDuelJson | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  // Which currency YOU stake. The opponent's side is always AUTO — a passive
  // opponent cannot be asked mid-match, so the signer resolves theirs from what
  // they can actually pay.
  // ⚠ TWO CURRENCIES (`DECISIONS.md §26`). 'STABLE' is gone from the wire
  // protocol too, so a stale client sending it gets a 400 naming the two that
  // exist rather than being quietly resolved into some other asset.
  const [myAsset, setMyAsset] = useState<'AUTO' | 'BNBULL' | 'BNB'>('AUTO');

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  // A new pair invalidates the quote on screen — the numbers in it belong to
  // the old matchup.
  useEffect(() => {
    setQuote(null);
    setError(null);
  }, [myTokenId, oppTokenId, account]);

  const mySide = useMemo(() => {
    if (!quote || myTokenId === null) return null;
    const isA = Number(quote.result.tokenA) === myTokenId;
    return {
      asset: isA ? quote.stakes.assetA : quote.stakes.assetB,
      symbol: isA ? quote.stakes.symbolA : quote.stakes.symbolB,
      decimals: isA ? quote.stakes.decimalsA : quote.stakes.decimalsB,
      amount: BigInt(isA ? quote.stakes.amountA : quote.stakes.amountB),
      oracle: isA ? quote.stakes.oracleA : quote.stakes.oracleB,
    };
  }, [quote, myTokenId]);

  const nativeValue = quote?.nativeValue ? BigInt(quote.nativeValue) : 0n;
  const needsErc20 = mySide !== null && nativeValue === 0n && mySide.asset !== ZERO;

  const {
    needsApproval,
    approve,
    isApproving,
    refetchAllowance,
  } = useErc20Approval(
    needsErc20 ? mySide!.asset : undefined,
    duelAddress,
    needsErc20 ? mySide!.amount : undefined,
  );

  const expiry = quote ? Number(quote.result.expiry) : 0;
  const secondsLeft = quote ? Math.max(0, expiry - now) : 0;
  const expired = quote !== null && secondsLeft === 0;

  const roll = useCallback(async () => {
    if (myTokenId === null || oppTokenId === null) return;
    setError(null);
    const session = await ensureSession();
    if (!session) return;
    setRolling(true);
    try {
      const res = await fetch('/api/run-duel', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        // ⚠ THREE fields in `session`. Omitting `address` 401s with "sign in",
        // which reads exactly like a bad signature and is not.
        // The API canonicalises the pair itself and works out which side is
        // yours from ON-CHAIN ownership, so the asset pick travels with your
        // token id and the order here is not load-bearing.
        body: JSON.stringify({
          tokenA: myTokenId,
          tokenB: oppTokenId,
          assetA: myAsset,
          assetB: 'AUTO',
          session: {
            address: session.address,
            message: session.message,
            signature: session.signature,
          },
        }),
      });
      const json = await res.json();
      if (!res.ok) {
        // A dead session is the one failure worth self-healing: drop the cached
        // signature so the next attempt re-signs instead of looping on a 401.
        if (res.status === 401) clear();
        setError(typeof json?.error === 'string' ? json.error : `run-duel failed (${res.status})`);
        return;
      }
      setQuote(json as RunDuelJson);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setRolling(false);
    }
  }, [myTokenId, oppTokenId, myAsset, ensureSession, clear]);

  const { writeContractAsync, isPending: isSubmitting } = useWriteContract();
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);
  const { isLoading: isConfirming, isSuccess: settled } = useWaitForTransactionReceipt({
    hash: txHash ?? undefined,
  });

  const submit = useCallback(async () => {
    if (!quote) return;
    setError(null);
    try {
      const r = quote.result;
      const hash = await writeContractAsync({
        address: duelAddress,
        abi: DuelAbi,
        functionName: 'submitDuel',
        args: [
          {
            tokenA: BigInt(r.tokenA),
            tokenB: BigInt(r.tokenB),
            winnerId: r.winnerId,
            rounds: r.rounds,
            seed: BigInt(r.seed),
            newEloA: r.newEloA,
            newEloB: r.newEloB,
            assetA: r.assetA,
            assetB: r.assetB,
            stakeA: BigInt(r.stakeA),
            stakeB: BigInt(r.stakeB),
            seqA: BigInt(r.seqA),
            seqB: BigInt(r.seqB),
            nonce: BigInt(r.nonce),
            expiry: BigInt(r.expiry),
          },
          quote.signature,
        ],
        // The native convenience path: `Duel._takeSide` wraps exactly what this
        // side owes into WBNB and refunds the rest, so a BNB stake never needs
        // the player to wrap anything themselves.
        value: nativeValue,
      });
      setTxHash(hash);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setError(explainRevert(msg));
    }
  }, [quote, duelAddress, writeContractAsync, nativeValue]);

  if (!account) {
    return (
      <p className="text-sm text-bull-text-dim">connect a wallet to roll a fight.</p>
    );
  }

  const canRoll = myTokenId !== null && oppTokenId !== null && !blockedReason;

  return (
    <div className="space-y-4">
      <label className="flex flex-wrap items-center gap-2 text-sm">
        <span className="font-mono text-xs text-bull-text-faint">you put in</span>
        <select
          value={myAsset}
          onChange={(e) => {
            setMyAsset(e.target.value as typeof myAsset);
            setQuote(null);
          }}
          className="rounded border border-bull-border bg-bull-panel px-3 py-1.5 text-sm"
        >
          <option value="AUTO">whatever i can pay</option>
          <option value="BNB">bnb</option>
          <option value="BNBULL">bnbull · the only discounted leg</option>
        </select>
      </label>

      <div className="flex flex-wrap items-center gap-3">
        <button
          type="button"
          onClick={roll}
          disabled={!canRoll || rolling || isSigning}
          className="bull-btn"
        >
          {isSigning
            ? 'waiting on your signature…'
            : rolling
              ? 'rolling…'
              : quote
                ? 're-quote'
                : hasSession
                  ? 'roll the fight'
                  : 'sign in & roll the fight'}
        </button>
        {!hasSession && (
          <span className="text-xs text-bull-text-faint">
            one signature, good for 24 hours. not a transaction. nothing is sent, spent or
            approved.
          </span>
        )}
      </div>

      {blockedReason && (
        <p className="text-sm text-bull-red">{blockedReason}</p>
      )}
      {sessionError && <p className="text-sm text-bull-red">{sessionError}</p>}
      {error && (
        <p className="rounded border border-bull-red/40 bg-bull-red/10 px-4 py-3 text-sm text-bull-red">
          {error}
        </p>
      )}

      {quote && (
        <div className="rounded border border-bull-border bg-bull-panel px-4 py-4">
          <h3 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
            your signed fight
          </h3>

          {quote.standingFight && (
            <p className="mt-3 rounded border border-bull-gold/40 bg-bull-gold/10 px-3 py-2 text-xs text-bull-text-dim">
              you asked for a different matchup, but your wallet already has a standing fight:
              bull #{quote.standingFight.challengerTokenId} against #
              {quote.standingFight.opponentTokenId}. one unsettled fight per wallet. settle
              this one, win or lose, and the next roll is free to be anything.
            </p>
          )}

          <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
            <div>
              <dt className="font-mono text-xs text-bull-text-faint">outcome</dt>
              <dd>
                {quote.winnerId === null
                  ? 'draw'
                  : quote.winnerId === myTokenId
                    ? `your bull #${quote.winnerId} wins`
                    : `bull #${quote.winnerId} wins`}{' '}
                <span className="text-bull-text-faint">
                  · {quote.rounds} round{quote.rounds === 1 ? '' : 's'}
                </span>
              </dd>
            </div>
            <div>
              <dt className="font-mono text-xs text-bull-text-faint">you put in</dt>
              <dd className="font-mono text-bull-gold">
                {mySide ? `${formatToken(mySide.amount, mySide.decimals)} ${mySide.symbol}` : '—'}
                {mySide?.oracle && (
                  <span className="ml-1 font-sans text-[11px] font-normal text-bull-text-faint">
                    (priced off the chainlink feed at quote time)
                  </span>
                )}
              </dd>
            </div>
          </dl>

          <p className="mt-3 font-mono text-[11px] text-bull-text-faint">
            {expired
              ? 'this quote has expired. re-quote before submitting.'
              : `valid for ${secondsLeft}s`}
          </p>

          <div className="mt-4 flex flex-wrap items-center gap-3">
            {needsErc20 && needsApproval && (
              <button
                type="button"
                onClick={async () => {
                  try {
                    await approve();
                    await refetchAllowance();
                  } catch (e) {
                    setError(e instanceof Error ? e.message : String(e));
                  }
                }}
                disabled={isApproving}
                className="rounded border border-bull-gold px-4 py-2 text-sm font-semibold text-bull-gold transition hover:bg-bull-gold/10 disabled:opacity-40"
              >
                {isApproving ? 'approving…' : `approve ${mySide?.symbol}`}
              </button>
            )}
            <button
              type="button"
              onClick={submit}
              disabled={
                expired || isSubmitting || isConfirming || (needsErc20 && needsApproval) || settled
              }
              className="rounded bg-bull-gold px-4 py-2 text-sm font-semibold text-bull-gold-ink transition hover:bg-bull-gold-hover disabled:cursor-not-allowed disabled:opacity-40"
            >
              {settled
                ? 'settled'
                : isConfirming
                  ? 'settling…'
                  : isSubmitting
                    ? 'confirm in your wallet…'
                    : nativeValue > 0n
                      ? 'settle (pays in BNB)'
                      : 'settle the fight'}
            </button>
          </div>

          {txHash && (
            <p className="mt-3 text-xs">
              <a
                href={`${explorerBaseUrl()}/tx/${txHash}`}
                target="_blank"
                rel="noreferrer"
                className="text-bull-gold hover:underline"
              >
                view the transaction
              </a>
              {settled && (
                <>
                  {' · '}
                  <a
                    href={`/api/duel-gif?tx=${txHash}`}
                    target="_blank"
                    rel="noreferrer"
                    className="text-bull-gold hover:underline"
                  >
                    watch the replay
                  </a>
                </>
              )}
            </p>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Turn the contract's custom errors into sentences. Every one of these is a
 * guardrail the page already displays, so seeing one here means the world moved
 * between the quote and the confirmation — which is exactly what these errors
 * exist to catch.
 */
function explainRevert(message: string): string {
  if (/StaleFightSeq/.test(message)) {
    return (
      'another signed fight naming one of these wallets settled first, so this ' +
      'one is void. re-quote, nothing was charged.'
    );
  }
  if (/SelfDuelBlocked/.test(message)) {
    return "both bulls are now in the same wallet, and a wallet can't fight itself.";
  }
  if (/Expired/.test(message)) {
    return 'the signature ran out before the transaction landed. re-quote.';
  }
  if (/NonceAlreadyUsed/.test(message)) {
    return 'this fight has already settled.';
  }
  if (/StakeNotApproved/.test(message)) {
    return 'the duel contract is not approved for that amount. approve it and try again.';
  }
  if (/StakeUnaffordable/.test(message)) {
    return 'your balance moved and no longer covers your half of the purse.';
  }
  if (/BullIsListed/.test(message)) {
    return 'one of the bulls is listed on the marketplace. delist it first.';
  }
  if (/BullNotAlive/.test(message)) {
    return 'one of the bulls died before this fight could settle.';
  }
  if (/FightCostTooHigh/.test(message)) {
    return "that amount is above the asset's on-chain ceiling. re-quote.";
  }
  if (/InvalidSignature/.test(message)) {
    return (
      'the duel contract rejected the signature. the signer configured for this ' +
      'site does not match the contract\'s trustedSigner. that is a deployment ' +
      'problem, not yours.'
    );
  }
  if (/User rejected|rejected the request|denied/i.test(message)) {
    return 'you rejected the transaction, so nothing was settled.';
  }
  return message;
}
