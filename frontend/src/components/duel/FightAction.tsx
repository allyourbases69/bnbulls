'use client';

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
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
 * The fight button. TWO PRESSES, and the second one is the wallet.
 *
 *   1. QUOTE — one press. Signs in if needed (`personal_sign`, cached for a
 *      day, not a transaction) and `POST /api/run-duel`. Returns a fully
 *      signed, submittable result. Your wallet holds ONE of these at a time:
 *      asking again gives the same fight back until it settles, which is what
 *      stops anyone rolling until they find a win and dropping the rest.
 *   2. FIGHT — one press, inside the arena gate. Opens the wallet, sends
 *      `Duel.submitDuel(result, signature)`, and the fight plays across the
 *      confirmation window.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THERE USED TO BE A THIRD SCREEN BETWEEN THEM. DO NOT PUT IT BACK.
 * ═══════════════════════════════════════════════════════════════════════
 * The quote used to land on a card with an "into the pit" button, which mounted
 * the arena, which had its OWN "put it in and fight" button, which opened the
 * wallet. Two presses for one decision. Owner, 2026-08-07: *"then into the pit
 * (but it already says the outcome above it??) then put it into a fight and
 * another approval."*
 *
 * The arena now mounts the moment the quote lands, gated, and the gate's button
 * is the only thing that opens the wallet. ⚠ THAT GATE IS NOT DECORATION AND IT
 * CANNOT BE AUTOMATED AWAY: a native wallet deep link only opens from inside a
 * user-gesture callback, so firing the write from an effect does nothing at all
 * on a phone. Exactly one gesture, and it has to be a real one.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE OUTCOME IS NOT ON THE PRE-FIGHT CARD, AND THAT IS THE POINT.
 * ═══════════════════════════════════════════════════════════════════════
 * The card used to print "bull #6 wins · 5 rounds" in the step BEFORE the
 * animation. The whole reason the fight plays live is so somebody can watch
 * their bull win or die, and printing the winner above the arena hands them the
 * ending first.
 *
 * ⚠ HIDDEN, NEVER DESTROYED. The signed result is the player's PROOF the fight
 * was real and the signer did not lie, and this project's rule is that the seed
 * is public so anyone can re-run it and catch a lying signer. So the winner,
 * the rounds, the seed, the signature, the nonce and the tx all live in
 * `FightProof` — a `details` disclosure that only exists AFTER the animation has
 * played, the way fefers does it. What stays on the pre-fight card is only what
 * a player needs before they sign: what they put in, in which currency, and how
 * long the quote is good for.
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
  onFightVisible,
}: {
  duelAddress: `0x${string}`;
  myTokenId: number | null;
  oppTokenId: number | null;
  /** Set when the page already knows this pair would revert. Disables step 2. */
  blockedReason: string | null;
  myAsset: PayAsset;
  /**
   * How many fights the approval should cover — the player's own "how many
   * fights are you up for" pick, handed down from the picker. The contract
   * settles one fight per wallet at a time, so this batches NOTHING on chain:
   * it sizes the single allowance so a run of N fights needs one approve
   * instead of N.
   */
  approveFights?: number;
  /** Fired once, when this pair's fight has actually settled on chain. */
  onSettled?: () => void;
  /**
   * There is an arena on screen, or there is not.
   *
   * ⚠ THIS IS HOW "A FIGHT OWNS THE SCREEN" IS DONE HERE. Fefers renders its
   * whole idle page only while `phase.kind === 'idle'`, so the roster and the
   * side panels are simply not there during a fight. Our fight state lives in
   * this component rather than on the page, so instead of unmounting anything,
   * the page folds its other sections away when this fires true. Nothing is
   * destroyed, which matters: an unmount here would orphan the receipt the
   * page is waiting on.
   */
  onFightVisible?: (visible: boolean) => void;
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
    // A re-quote on the SAME pair does not trip the pair effect below, so the
    // arena has to be un-hidden and the outcome re-hidden from here or a
    // second roll would open with the previous fight's ending on screen.
    setHidden(false);
    setWatched(false);
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
      /**
       * ⚠ THE PREVIOUS FIGHT'S RECEIPT HAS TO GO WITH THE NEW QUOTE.
       *
       * `useWaitForTransactionReceipt` keeps answering for whatever hash it was
       * last given, so a re-quote on the SAME pair would mount the arena in the
       * `settled` state, playing the NEW fight's events under the OLD fight's
       * transaction. That was survivable while a second button stood between
       * the quote and the arena; it is not now that the arena comes up with the
       * quote. The re-quote button is disabled while a transaction is actually
       * in flight, so this only ever drops a receipt that is already history.
       */
      setTxHash(null);
      setRevert(null);
      setQuote(json as RunDuelJson);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setRolling(false);
    }
  }, [myTokenId, oppTokenId, chosen, ensureSession, clear]);

  const { writeContractAsync, isPending: isSubmitting } = useWriteContract();
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);
  /**
   * The player pressed "hide the fight". The arena is otherwise up from the
   * moment a quote exists — there is no separate "into the pit" press any
   * more, so this is the ONLY reason it would not be on screen.
   */
  const [hidden, setHidden] = useState(false);
  /** The animation has played out. Only then is the outcome allowed on screen.
   *  ⚠ This is what keeps the ending off the pre-fight card. */
  const [watched, setWatched] = useState(false);
  const showFight = quote !== null && !hidden;

  // Tell the page whether there is an arena up. ⚠ THE CALLBACK GOES IN A REF for
  // the same reason `usePitWrites` does it: callers pass an inline arrow, so a
  // dependency on the callback itself would re-fire this every render, and the
  // page's handler collapses sections.
  const onFightVisibleRef = useRef(onFightVisible);
  onFightVisibleRef.current = onFightVisible;
  useEffect(() => {
    onFightVisibleRef.current?.(showFight);
  }, [showFight]);
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
    setHidden(false);
    setWatched(false);
  }, [myTokenId, oppTokenId, account]);

  // Changing the currency invalidates the quote but NOT a settled fight: the
  // numbers in the quote are per asset, the receipt is history.
  useEffect(() => {
    setQuote(null);
    setError(null);
    setRevert(null);
    setWatched(false);
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

  /**
   * The one button that opens the wallet, and every reason it might not be
   * able to, in the words for that reason.
   *
   * ⚠ `checking` IS NAMED OUT LOUD rather than left as a frozen button: the
   * dry run is what stops a doomed transaction reaching the wallet, and a
   * button that just goes dead for a second reads as broken.
   */
  const gateLabel = wrongNetwork
    ? 'wrong network'
    : settled
      ? 'settled'
      : expired
        ? 'expired, re-quote above'
        : needsErc20 && needsApproval
          ? `approve ${approveSymbol} first`
          : isConfirming
            ? 'settling…'
            : checking
              ? 'checking it will work…'
              : isSubmitting
                ? 'check your wallet…'
                : 'put it in and fight';

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

      {/* ═══════════════════════════════════════════════════════════════
          ⚠ EXACTLY ONE LOUD BUTTON ON THE STEP AT ANY MOMENT.
          ═══════════════════════════════════════════════════════════════
          Owner, 2026-08-07: *"the buttons and approvals it's all just a bloody
          mess."* His own screenshot has a gold "re-quote" sitting directly above
          a gold "into the pit", which is two primaries for two different
          decisions stacked on top of each other.

          Before a quote, THIS is the primary and it pulses. The moment a quote
          exists the arena is up and ITS gate is the button that opens the
          wallet, so this demotes itself to a quiet outline — it is a way back,
          not the next move. Same ranking fefers uses: one live primary per
          step, everything else bordered. */}
      <div className="flex flex-wrap items-center gap-3">
        <button
          type="button"
          onClick={roll}
          // ⚠ NOT WHILE A FIGHT IS ACTUALLY LANDING. Re-quoting mid-flight
          // would swap the events out from under the arena and orphan the
          // receipt the queue is waiting on.
          disabled={!canRoll || rolling || isSigning || isSubmitting || isConfirming}
          className={
            quote ? 'bull-btn bull-btn-secondary' : 'bull-btn bull-btn-pulse'
          }
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
      </div>

      {!hasSession && (
        <p className="text-[11px] text-bull-text-faint">
          one signature, good for 24 hours. not a transaction. nothing is sent, spent or
          approved.
        </p>
      )}

      {/* ⚠ THE PASSIVE-OPPONENT RULE, SAID OUT LOUD — BUT FOLDED. It is true and
          it matters (`Duel._takeSide` only lets raw bnb cover a side when
          `owner_ == msg.sender`, so what you pick here covers YOUR side on a
          fight YOU send in and nothing else), and it was four lines of prose
          standing between the player and the fight button. Step 2's allowance
          block is where that decision is actually made; this is the footnote. */}
      <details>
        <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint hover:text-bull-gold">
          what your pick does and does not cover
        </summary>
        <p className="mt-2 text-[11px] text-bull-text-faint">
          this covers your own side of a fight you start. somebody else picking one of your
          bulls draws on the allowance you gave the duel contract in step 2, in whichever
          currency you approved, because only the wallet sending the transaction can put raw
          bnb in with it.
        </p>
      </details>

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

          {/* ⚠ WHAT A PLAYER NEEDS BEFORE THEY SIGN, AND NOTHING ELSE. The
              outcome used to sit next to this and it is gone on purpose — see
              the header. What is left is the money, the currency and how long
              the number is good for. */}
          <dl className="mt-3 text-sm">
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
                  you said either would do · this one settles in {mySide.symbol.toLowerCase()}
                </div>
              )}
            </dd>
          </dl>

          <p className="mt-3 font-mono text-[11px] text-bull-text-faint">
            {expired
              ? 'this quote has expired. re-quote before submitting.'
              : `valid for ${secondsLeft}s`}
          </p>

          {/* ⚠ A TOP-UP, NOT A ROUTINE STEP. The standing approval in step 2 is
              sized for the whole run, so this only appears when the quoted
              amount has outgrown it — the chainlink number moves between the
              approval and the quote. It asks for the whole run again rather
              than this one fight, so it can never become a per-fight prompt. */}
          {needsErc20 && needsApproval && (
            <div className="mt-4">
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
                {isApproving ? 'approving…' : `top up your ${approveSymbol} approval`}
              </button>
              <p className="mt-1.5 text-[11px] text-bull-text-faint">
                your standing approval does not stretch to this one. this signs for the whole run
                again, so it is asked once and not again per fight.
              </p>
            </div>
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
              fight, that is the proof.

              ⚠ IT MOUNTS ON THE QUOTE, NOT ON A SECOND BUTTON. The gate is up
              until the wallet answers, so nothing is spoiled by it being on
              screen early, and the gate's own button is the single user gesture
              that opens the wallet. See the header. */}
          {showFight && (
            <div className="mt-4">
              <DuelAnimation
                aTokenId={Number(quote.result.tokenA)}
                bTokenId={Number(quote.result.tokenB)}
                events={quote.events}
                status={fightStatus}
                // The amount goes in the headline, the way fefers does it, so
                // the one thing a player checks before signing is on the button
                // they are about to press rather than in a card above it.
                signingMessage={
                  mySide
                    ? `put your ${formatToken(mySide.amount, mySide.decimals)} ${mySide.symbol} in the middle`
                    : 'put your half in the middle'
                }
                signingAction={{
                  label: gateLabel,
                  onTap: () => void submit(),
                  disabled:
                    isSubmitting ||
                    isConfirming ||
                    checking ||
                    settled ||
                    expired ||
                    wrongNetwork ||
                    (needsErc20 && needsApproval),
                }}
                onFinished={() => setWatched(true)}
                onClose={() => setHidden(true)}
                // ⚠ THE OUTCOME LIVES HERE AND ONLY HERE. `finishedOverlay`
                // renders inside the outcome panel, which the animation only
                // puts up once the last event has played.
                finishedOverlay={
                  <FightProof quote={quote} myTokenId={myTokenId} txHash={txHash} />
                }
              />
            </div>
          )}

          {/* "hide the fight" is `DuelAnimation`'s own control and it has no
              matching "show it again", so the way back lives here. Without it a
              player who hid the arena would have no button on screen that opens
              their wallet at all, and the quote would just sit there. */}
          {!showFight && (
            <button
              type="button"
              onClick={() => setHidden(false)}
              className="mt-4 font-mono text-xs text-bull-gold hover:underline"
            >
              {settled || reverted ? 'show the fight' : 'back to the fight'}
            </button>
          )}

          {/* Hidden the arena mid-fight? The proof does not go with it. */}
          {!showFight && (watched || settled || reverted) && (
            <div className="mt-3">
              <FightProof quote={quote} myTokenId={myTokenId} txHash={txHash} />
            </div>
          )}

          {txHash && !showFight && (
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

          {settled && txHash && <DuelReplayInline txHash={txHash} className="mt-3" />}
        </div>
      )}
    </div>
  );
}

/**
 * THE OUTCOME, AND THE PROOF IT WAS REAL. AFTER THE FIGHT, NEVER BEFORE IT.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS IS WHERE THE SPOILER WENT. IT WAS NOT DELETED.
 * ═══════════════════════════════════════════════════════════════════════
 * The pre-fight card used to print the winner and the round count above the
 * arena, which handed the player the ending before they had watched a single
 * swing. It is all still here, one disclosure down, and it now carries MORE
 * than it did: the seed and the signature as well as the winner.
 *
 * That matters, because the seed being public is the whole trust story on this
 * project — `/api/run-duel` simulates the fight off chain and signs the result,
 * the contract verifies the signature and never re-runs the fight, so the only
 * thing standing between a player and a lying signer is that anybody can take
 * the seed and re-run it themselves. A player who cannot copy the seed out of
 * the page cannot check that, and "trust us" is not the deal.
 *
 * Collapsed by default and titled plainly, the way fefers tucks everything
 * behind one `details` under its victory panel: one primary out, everything
 * else folded away.
 */
function FightProof({
  quote,
  myTokenId,
  txHash,
}: {
  quote: RunDuelJson;
  myTokenId: number | null;
  txHash: `0x${string}` | null;
}) {
  const r = quote.result;
  const outcome =
    quote.winnerId === null
      ? 'a draw'
      : quote.winnerId === myTokenId
        ? `your bull #${quote.winnerId} won it`
        : `bull #${quote.winnerId} won it`;

  return (
    <details className="text-left">
      <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint hover:text-bull-gold">
        details
      </summary>
      {/* The overlay this sits in is an absolute panel over the arena from md
          up, so an expanded block has to scroll inside itself rather than
          spill out of a container with `overflow-hidden` on it. */}
      <div className="mt-2 max-h-56 overflow-y-auto">
        <dl className="space-y-1.5 font-mono text-[11px]">
          <ProofRow label="outcome">
            {outcome} · {quote.rounds} round{quote.rounds === 1 ? '' : 's'}
          </ProofRow>
          <ProofRow label="seed">
            <span className="break-all">{r.seed}</span>
          </ProofRow>
          <ProofRow label="signature">
            <span className="break-all">{quote.signature}</span>
          </ProofRow>
          <ProofRow label="nonce">{r.nonce}</ProofRow>
          {txHash && (
            <ProofRow label="tx">
              <a
                href={`${explorerBaseUrl()}/tx/${txHash}`}
                target="_blank"
                rel="noreferrer"
                className="break-all text-bull-gold hover:underline"
              >
                {txHash}
              </a>
            </ProofRow>
          )}
        </dl>
        <p className="mt-2 text-[11px] leading-relaxed text-bull-text-faint">
          the fight ran off chain from that seed and the signer signed the result. the contract
          checks the signature, it never re-runs the fight. the seed is public, so anyone can
          re-run it and catch a lying signer.
        </p>
      </div>
    </details>
  );
}

function ProofRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[4.5rem_1fr] gap-2">
      <dt className="text-bull-text-faint">{label}</dt>
      <dd className="min-w-0 text-bull-text-dim">{children}</dd>
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
