'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  useAccount,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { DuelAbi } from '@/lib/abi';
import { formatToken } from '@/lib/format';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { useDuelSession } from '@/lib/hooks/useDuelSession';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { DuelReplayInline } from '@/components/duel/DuelReplay';
import { DuelAnimation, type DuelChainStatus } from '@/components/duel/DuelAnimation';
import type { CombatEvent } from '@/core/types';
import { explorerBaseUrl, CHAIN_ID } from '@/lib/env';
import { CURRENCY } from '@/lib/brand';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';

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
  /** The beat-by-beat fight. Already on the client the moment the signer
   *  answers, which is what lets the animation play LIVE across the
   *  confirmation window instead of after the receipt lands. */
  events: readonly CombatEvent[];
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

/**
 * WHAT YOU BACK YOUR BULL WITH. One of three, and one of them has to be picked.
 *
 * Owner call, 2026-08-07: *"get rid of the 'whatever I can pay' feature. person
 * must select EITHER BNB or BNBULL, or you can add a button 'both'."*
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ `BOTH` IS A PREFERENCE, NOT A SPLIT. READ THIS BEFORE CHANGING IT.
 * ═══════════════════════════════════════════════════════════════════════
 * `DuelResult` carries ONE asset per side (`assetA`, `assetB`) and
 * `Duel._takeSide` pulls one asset from one owner, so a side that paid half in
 * bnb and half in bnbull cannot be written into the struct that gets signed.
 * Half-and-half is a contract change, not a button.
 *
 * `BOTH` therefore means "either currency is fine with me". The signer resolves
 * it to exactly one, bnb first (`DECISIONS.md §29`, and `§39` deleted the
 * fight discount that used to make bnbull worth trying first), and says which
 * one in the quote below before anything is signed. When neither works it names
 * both currencies with the reason for each, which is what the old `AUTO` never
 * did: it skipped a currency it could not use in silence.
 *
 * ⚠ YOUR PICK COVERS YOUR OWN SIDE ONLY. The opponent's side is always resolved
 * from what THEY have already approved, because `Duel._takeSide` gates the raw
 * bnb path on `owner_ == msg.sender` — a passive opponent stakes by allowance,
 * always. That cuts both ways and the card says so: it is also what decides
 * whether somebody else can pick YOUR bulls.
 */
export type PayChoice = 'BNB' | 'BNBULL' | 'BOTH';

/**
 * ⚠ `'AUTO'` IS DEAD. IT IS IN THIS UNION FOR ONE REASON ONLY.
 *
 * It was "whatever i can pay" and the owner removed it. `DuelPicker.tsx` still
 * renders a tab that sets it and that file is owned by another agent right now,
 * so narrowing the union would break its build rather than its behaviour.
 *
 * NOTHING ACTS ON IT. This component treats it as NO CHOICE MADE and asks for
 * one, and `/api/run-duel` 400s on it. Delete the member the moment the tab
 * goes, along with `needsChoice` and the picker it renders.
 */
export type PayAsset = PayChoice | 'AUTO';

const PAY_CHOICES: readonly PayChoice[] = ['BNB', 'BNBULL', 'BOTH'];

function isPayChoice(v: PayAsset): v is PayChoice {
  return (PAY_CHOICES as readonly string[]).includes(v);
}

const CHOICE_LABEL: Record<PayChoice, string> = {
  BNB: 'bnb',
  BNBULL: 'bnbull',
  BOTH: 'both',
};

export function FightAction({
  duelAddress,
  myTokenId,
  oppTokenId,
  blockedReason,
  myAsset,
  approveFights = 1,
  onSettled,
}: {
  duelAddress: `0x${string}`;
  myTokenId: number | null;
  oppTokenId: number | null;
  /** Set when the page already knows this pair would revert. Disables step 2. */
  blockedReason: string | null;
  myAsset: PayAsset;
  /**
   * How many fights the approval should cover. The contract settles one fight
   * per wallet at a time, so this batches NOTHING on chain — it just sizes the
   * single allowance so a queue of N fights needs one approve instead of N.
   */
  approveFights?: number;
  /** Fired once, when this pair's fight has actually settled on chain. */
  onSettled?: () => void;
}) {
  const { address: account } = useAccount();
  const { ensureSession, isSigning, error: sessionError, hasSession, clear } = useDuelSession();
  const { wrongNetwork } = useWrongNetwork();

  const { preflight, checking } = usePreflight();

  const [rolling, setRolling] = useState(false);
  const [quote, setQuote] = useState<RunDuelJson | null>(null);
  /** Errors from the signer / the session. Already sentences when they arrive. */
  const [error, setError] = useState<string | null>(null);
  /**
   * ⚠ ANYTHING THE CHAIN THREW GOES HERE, NEVER IN `error`, AND NEVER AS A
   * RAW STRING. `RevertNotice` only accepts a decoded shape, so there is
   * nowhere in this component to put "gas limit too high" even by accident.
   */
  const [revert, setRevert] = useState<DecodedRevert | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  /**
   * THE CURRENCY, AND IT CANNOT BE SKIPPED.
   *
   * Normally the page above has already made the pick and it rides in as
   * `myAsset`, so there is still exactly ONE currency control on screen. The
   * fallback below exists for one case: a picker that hands down the dead
   * `'AUTO'`. Rather than dead-ending on a button that no longer does anything,
   * this asks for a real choice and explains why the old one went.
   */
  const [ownChoice, setOwnChoice] = useState<PayChoice | null>(null);
  const needsChoice = !isPayChoice(myAsset);
  const chosen: PayChoice | null = isPayChoice(myAsset) ? myAsset : ownChoice;

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  /**
   * Is the bnbull leg switched on yet? `Duel.fighterCost` returns ZERO for a
   * leg nobody has priced, which is precisely the launch state
   * (`DECISIONS.md §29`): four.meme holds the token transfer-locked until its
   * curve fills. Read so the picker can say WHY bnbull is off rather than
   * hiding it or quietly landing everyone on bnb.
   */
  const { data: bnbullAddr } = useReadContract({
    address: duelAddress,
    abi: DuelAbi,
    functionName: 'bnbull',
    query: { enabled: needsChoice },
  });
  const { data: bnbullCost } = useReadContract({
    address: duelAddress,
    abi: DuelAbi,
    functionName: 'fighterCost',
    args: bnbullAddr ? [bnbullAddr as `0x${string}`] : undefined,
    query: { enabled: needsChoice && !!bnbullAddr },
  });
  const bnbullLive = typeof bnbullCost === 'bigint' && bnbullCost > 0n;

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

  /**
   * ⚠ THE BNB LEG'S ERC-20 IS **WBNB**, and the approve button has to say so.
   *
   * `stakes.oracleA/B` is exactly "is this the bnb leg" (the API says as much
   * where it sets it), so an approval on that side is a WBNB approval. It is
   * reachable: pick bnb, be short of raw bnb, and the signer falls through to
   * the wbnb allowance route rather than refusing. A button reading "approve
   * BNB" would then send somebody looking for a token that is not the one their
   * wallet is about to approve.
   */
  const approveSymbol = mySide === null ? '' : mySide.oracle ? 'wbnb' : mySide.symbol.toLowerCase();

  const {
    needsApproval,
    approve,
    isApproving,
    refetchAllowance,
  } = useErc20Approval(
    needsErc20 ? mySide!.asset : undefined,
    duelAddress,
    needsErc20 ? mySide!.amount : undefined,
    // Size the approve for the whole queue. `needsApproval` is still measured
    // against THIS fight's amount, so a wallet that already has enough is not
    // asked to approve again just because it did not pre-pay for the rest.
    needsErc20 ? mySide!.amount * BigInt(Math.max(1, approveFights)) : undefined,
  );

  const expiry = quote ? Number(quote.result.expiry) : 0;
  const secondsLeft = quote ? Math.max(0, expiry - now) : 0;
  const expired = quote !== null && secondsLeft === 0;

  const roll = useCallback(async () => {
    if (myTokenId === null || oppTokenId === null || chosen === null) return;
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
        //
        // ⚠ `assetB` IS 'BOTH' BECAUSE THE OPPONENT NEVER PICKED. They cannot
        // be asked mid-fight and `Duel._takeSide` will only take their side out
        // of an allowance they already gave, so the signer tries both of theirs
        // and, when neither is there, says so by currency and by number instead
        // of quietly leaving that bull unmatchable.
        body: JSON.stringify({
          tokenA: myTokenId,
          tokenB: oppTokenId,
          assetA: chosen,
          assetB: 'BOTH',
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
  }, [myTokenId, oppTokenId, chosen, ensureSession, clear]);

  const { writeContractAsync, isPending: isSubmitting } = useWriteContract();
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);
  /** True from the moment the player commits to settling. The arena mounts
   *  gated, and its own button is what actually opens the wallet — a native
   *  wallet deep link only opens from inside a user gesture, so firing the
   *  write from an effect silently does nothing on a phone. */
  const [showFight, setShowFight] = useState(false);
  /**
   * ⚠ `isSuccess` MEANS "A RECEIPT ARRIVED", NOT "IT WORKED". viem resolves this
   * hook for a REVERTED transaction too — it does not throw. Read on its own,
   * `isSuccess` made the button say "settled" and fired `onSettled()` for a
   * fight the contract had rejected, which is the same lie as showing a winner
   * for a revert. `receipt.status` is the chain's actual verdict.
   */
  const {
    data: receipt,
    isLoading: isConfirming,
    isSuccess: mined,
  } = useWaitForTransactionReceipt({ hash: txHash ?? undefined });
  const reverted = mined && receipt?.status === 'reverted';
  const settled = mined && receipt?.status === 'success';

  /**
   * A new pair invalidates everything on screen — the quote's numbers belong to
   * the old matchup.
   *
   * ⚠ `txHash` HAS TO GO WITH IT, and that is a queue bug, not tidiness. Left
   * standing, `useWaitForTransactionReceipt` keeps reporting the PREVIOUS
   * fight's receipt, so `settled` stays true, the button reads "settled" and
   * the second bull in a queue can never be sent in.
   */
  useEffect(() => {
    setQuote(null);
    setError(null);
    setRevert(null);
    setTxHash(null);
    setShowFight(false);
  }, [myTokenId, oppTokenId, account]);

  // Changing the currency invalidates the quote but NOT a settled fight: the
  // numbers in the quote are per asset, the receipt is history.
  useEffect(() => {
    setQuote(null);
    setError(null);
    setRevert(null);
  }, [chosen]);

  // Tell the page once, when this fight is genuinely on chain. The ref is what
  // stops a re-render firing it again and skipping a bull in the queue.
  /**
   * ⚠ THE CHAIN'S VERDICT, NOT THE ROLL'S. The events say who won the fight;
   * this says whether the fight COUNTED. `DuelAnimation` takes the winner back
   * down off screen on `failed`, so a revert can never leave a victory standing
   * — the animation is proof the fight was real, and proof that lies is worse
   * than no animation at all.
   */
  const fightStatus: DuelChainStatus = useMemo(() => {
    if (revert) {
      return {
        kind: 'failed',
        message: revert.message,
        headline: revert.kind === 'rejected' ? 'you called it off' : undefined,
        ...(txHash ? { txHash } : {}),
      };
    }
    if (reverted && txHash) {
      return {
        kind: 'failed',
        message: 'the transaction ran but the contract rejected it, so nothing settled.',
        txHash,
      };
    }
    if (settled && txHash) return { kind: 'settled', txHash };
    if (txHash) return { kind: 'inflight', txHash };
    return { kind: 'signing' };
  }, [revert, reverted, settled, txHash]);

  const settledFor = useRef<string | null>(null);
  useEffect(() => {
    if (!settled || !txHash) return;
    if (settledFor.current === txHash) return;
    settledFor.current = txHash;
    onSettled?.();
  }, [settled, txHash, onSettled]);

  const submit = useCallback(async () => {
    if (!quote || wrongNetwork) return;
    setError(null);
    setRevert(null);

    const r = quote.result;
    const args = [
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
    ] as const;

    /**
     * ⚠ SIMULATE FIRST. THIS IS THE LINE THE "gas limit too high" BUG CROSSED.
     *
     * `submitDuel` re-checks the whole world at settlement — both bulls in the
     * pit under their LIVE owners, both alive, neither listed, the sequence
     * numbers, the signature, both balances and both allowances. Any one of
     * them can have moved since the quote, and a marketplace sale moves the pit
     * check WITHOUT ANY EVENT AT ALL. When one has, `eth_estimateGas` returns
     * garbage and the rpc's complaint about that number is the only thing the
     * player would otherwise see.
     *
     * `eth_call` on the identical arguments returns the revert DATA instead,
     * which decodes to `BullNotInYards(16)` and a sentence that names the bull
     * and says what to do. Same call, same value, same account, asked in the
     * way that gets an answer.
     */
    const pre = await preflight({
      address: duelAddress,
      abi: DuelAbi,
      functionName: 'submitDuel',
      args,
      value: nativeValue,
    });
    if (!pre.ok) {
      setRevert(pre.error);
      return;
    }

    try {
      const hash = await writeContractAsync({
        address: duelAddress,
        abi: DuelAbi,
        // ⚠ PIN THE CHAIN. This call carries native `value` on the BNB leg, and
        // without `chainId` wagmi passes viem `chain: null`, which skips
        // `assertCurrentChain` entirely — a wallet that declined the network
        // switch would broadcast anyway and pay a codeless address. See
        // `useWrongNetwork`.
        chainId: CHAIN_ID,
        functionName: 'submitDuel',
        args,
        // The native convenience path: `Duel._takeSide` wraps exactly what this
        // side owes into WBNB and refunds the rest, so a BNB stake never needs
        // the player to wrap anything themselves.
        value: nativeValue,
      });
      setTxHash(hash);
    } catch (e) {
      // The second layer. State can move between the simulation and the
      // confirmation, so this path is a race by construction and gets the same
      // decoder rather than the wallet's own words.
      setRevert(decodeRevert(e));
    }
  }, [quote, duelAddress, writeContractAsync, nativeValue, wrongNetwork, preflight]);

  if (!account) {
    return (
      <p className="text-sm text-bull-text-dim">connect a wallet to roll a fight.</p>
    );
  }

  // Rolling spends no money, but it does burn a `personal_sign` and hand back a
  // quote that could never be settled from the chain the wallet is on. Block it
  // at the same line as the settle, so the whole panel has one story.
  //
  // ⚠ `chosen !== null` IS PART OF THE GATE. There is no default currency any
  // more, here or in the signer, so an unpicked side never reaches the wallet.
  const canRoll =
    myTokenId !== null &&
    oppTokenId !== null &&
    chosen !== null &&
    !blockedReason &&
    !wrongNetwork;

  return (
    <div className="space-y-4">
      {needsChoice && (
        <div className="rounded border border-bull-gold/40 bg-bull-gold/5 px-4 py-3">
          <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
            what are you backing your bull with?
          </p>
          <p className="mt-1 text-xs text-bull-text-dim">
            {'pick one. "whatever i can pay" is gone: it could pass over a currency ' +
              'without saying so, and a bull it passed over just sat there with nothing ' +
              'on screen to explain why.'}
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            {PAY_CHOICES.map((c) => {
              const off = c === 'BNBULL' && !bnbullLive;
              const active = ownChoice === c;
              return (
                <button
                  key={c}
                  type="button"
                  disabled={off}
                  title={off ? CURRENCY.bnbullPending : undefined}
                  onClick={() => setOwnChoice(c)}
                  className={`rounded-full border px-3 py-1.5 text-xs font-medium transition ${
                    off
                      ? 'cursor-not-allowed border-bull-border text-bull-text-faint opacity-50'
                      : active
                        ? 'border-bull-gold text-bull-gold'
                        : 'border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-text'
                  }`}
                >
                  {CHOICE_LABEL[c]}
                </button>
              );
            })}
          </div>
          <p className="mt-2 text-[11px] text-bull-text-faint">
            {'"both" means either one is fine with you, not half in each: your side of the ' +
              'money in the middle is always one currency. ' +
              (bnbullLive ? 'it tries bnb first.' : 'right now that lands on bnb.')}
          </p>
          {!bnbullLive && (
            <p className="mt-1 text-[11px] text-bull-text-faint">{CURRENCY.bnbullPending}</p>
          )}
        </div>
      )}

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
                  ? 'start the slaughter'
                  : 'sign in & start the slaughter'}
        </button>
        {chosen !== null && (
          <span className="font-mono text-[11px] text-bull-text-faint">
            backing your bull with {CHOICE_LABEL[chosen]}
            {chosen === 'BOTH' ? ' · whichever one covers it' : ''}
          </span>
        )}
        {!hasSession && (
          <span className="text-xs text-bull-text-faint">
            one signature, good for 24 hours. not a transaction. nothing is sent, spent or
            approved.
          </span>
        )}
      </div>

      {/* ⚠ THE PASSIVE-OPPONENT RULE, SAID OUT LOUD. `Duel._takeSide` only lets
          raw bnb cover a side when `owner_ == msg.sender`, so what you pick
          here covers YOUR side on a fight YOU send in, and nothing else. The
          other half — whether anybody can pick your bulls, and in which
          currency — is the standing allowance in step 2. */}
      <p className="text-[11px] text-bull-text-faint">
        this covers your own side of a fight you start. somebody else picking one of your
        bulls draws on the allowance you gave the duel contract in step 2, in whichever
        currency you approved, because only the wallet sending the transaction can put raw
        bnb in with it.
      </p>

      <WrongNetworkNotice />

      {blockedReason && (
        <p className="text-sm text-bull-red">{blockedReason}</p>
      )}
      {sessionError && <p className="text-sm text-bull-red">{sessionError}</p>}
      {error && (
        <p className="rounded border border-bull-red/40 bg-bull-red/10 px-4 py-3 text-sm text-bull-red">
          {error}
        </p>
      )}
      <RevertNotice error={revert} />

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
                {/* ⚠ A `BOTH` pick resolves to ONE currency and the player has to
                    see WHICH before they sign, or "both" is just the old silent
                    AUTO with a friendlier button. */}
                {chosen === 'BOTH' && mySide && (
                  <div className="mt-1 font-sans text-[11px] font-normal text-bull-text-faint">
                    you said either would do · this one settles in{' '}
                    {mySide.symbol.toLowerCase()}
                  </div>
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
                    // Decoded, not raw. A rejected approval and a token that
                    // refuses one are different facts, and the wallet's own
                    // string distinguishes neither.
                    setRevert(decodeRevert(e));
                  }
                }}
                disabled={isApproving || wrongNetwork}
                className="rounded border border-bull-gold px-4 py-2 text-sm font-semibold text-bull-gold transition hover:bg-bull-gold/10 disabled:opacity-40"
              >
                {isApproving ? 'approving…' : `approve ${approveSymbol}`}
              </button>
            )}
            <button
              type="button"
              onClick={() => setShowFight(true)}
              disabled={
                expired ||
                isSubmitting ||
                isConfirming ||
                checking ||
                (needsErc20 && needsApproval) ||
                settled ||
                wrongNetwork
              }
              className="rounded bg-bull-gold px-4 py-2 text-sm font-semibold text-bull-gold-ink transition hover:bg-bull-gold-hover disabled:cursor-not-allowed disabled:opacity-40"
            >
              {wrongNetwork
                ? 'wrong network'
                : settled
                  ? 'settled'
                  : isConfirming
                    ? 'settling…'
                    : isSubmitting
                      ? 'confirm in your wallet…'
                      : // The dry run. Named out loud rather than left as a
                        // frozen button, because it is the step that stops a
                        // doomed transaction reaching the wallet.
                        checking
                        ? 'checking it will work…'
                        : // ⚠ THIS BUTTON OPENS THE ARENA, NOT THE WALLET. The
                          // gate inside it is what fires the write, so a label
                          // promising to settle would be describing the step
                          // after the one it actually does.
                          nativeValue > 0n
                          ? 'into the pit (pays in BNB)'
                          : 'into the pit'}
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
            </p>
          )}

          {/* ⚠ THE REPLAY PLAYS HERE, IT IS NOT A DOWNLOAD LINK. This used to be
              an <a href="/api/duel-gif?tx="> that made you leave the page to see
              your own fight. The replay re-simulates from the signed seed and
              409s on any winner/rounds mismatch, so it is the PROOF the fight
              was real, not decoration. `DuelReplayInline` renders that refusal
              in words rather than quietly falling back to a picture. */}
          {/* ⚠ THE FIGHT PLAYS HERE, LIVE, WHILE THE TX IS IN FLIGHT. The signed
              events are already on the client, so nothing is fetched and nothing
              waits on a receipt. Playing it on the ROLL would spoil the outcome
              before any money moved; playing it on the RECEIPT is the GIF, which
              is a highlight reel rather than watching your bull win or die.
              `DuelReplayInline` below is the RECEIPT and stays put — this is the
              fight, that is the proof. */}
          {showFight && (
            <DuelAnimation
              aTokenId={Number(quote.result.tokenA)}
              bTokenId={Number(quote.result.tokenB)}
              events={quote.events}
              status={fightStatus}
              signingMessage="put your half in the middle"
              signingAction={{
                label: isSubmitting ? 'check your wallet…' : 'put it in and fight',
                onTap: () => void submit(),
                disabled:
                  isSubmitting || expired || wrongNetwork || (needsErc20 && needsApproval),
              }}
              onClose={() => setShowFight(false)}
            />
          )}

          {settled && txHash && <DuelReplayInline txHash={txHash} className="mt-3" />}
        </div>
      )}
    </div>
  );
}

/*
 * ⚠ `explainRevert` USED TO LIVE HERE AND IT IS GONE ON PURPOSE.
 *
 * It matched contract error NAMES against the error's MESSAGE STRING with
 * regexes, which meant it only ever worked when viem had already decoded the
 * revert and put the name in the text. Every other path fell through to
 * `return message` — and the most common of those paths was the one that
 * mattered: a reverting call makes gas estimation return garbage, the rpc
 * rejects the number, and the message the player got was "gas limit too high"
 * about a fight that reverted `BullNotInYards`.
 *
 * `lib/revertDecode.ts` replaces it and works the other way round: it pulls the
 * revert DATA off the error chain and decodes it against the real ABIs, so an
 * error is named from its four bytes rather than from prose. Anything it cannot
 * name still gets a sentence plus the selector, and a raw node string can no
 * longer reach a player from here — `RevertNotice` will not render one.
 */
