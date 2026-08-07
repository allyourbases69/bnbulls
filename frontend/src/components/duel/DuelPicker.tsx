'use client';

/**
 * THE DUEL FLOW. THREE NUMBERED STEPS, STACKED, ONE ACTIVE AT A TIME.
 *
 *   1  your fighter   the dropdown. tick to send a bull in, click a name to
 *                     make it the one that fights next
 *   2  send them in   pay-with toggle, approve a run of fights, and the
 *                     standing approval with its revoke
 *   3  fight          greyed until step 2 is done, then the two fighter cards
 *                     side by side and the fight button
 *
 * ⚠ PORTED FROM THE LIVE FEFERS DUEL PAGE, off the owner's own screenshots, not
 * reinterpreted. The step bubbles, the numbering, the right-aligned "N alive in
 * your herd", the dropdown's instruction line, the per-row `benched` /
 * `fighting next` status, the inline one-line explanations under the buttons
 * and the "step 2 first" gate on step 3 are all the fefers shapes.
 *
 * ⚠ THE CHECKBOXES LIVE INSIDE THE DROPDOWN. Owner, 2026-08-07: "i should be
 * able to select multiple bulls to send in for battle so add check boxes next
 * to them". On fefers that control is not a separate panel — it is the fighter
 * dropdown itself, with one ticked row per fefer you own. A tick sends that one
 * in; clicking the NAME makes it the one that fights next. Same here.
 *
 * ⚠ THE OPPONENT IS FOUND FOR YOU. There is no token-id entry anywhere on this
 * page any more. Owner: "what is step #2 token id bullshit… you are supposed to
 * match fighters as close as possible based on their rating and also allow
 * rerolls". Step 3 matches on rating and rerolls to the next-closest.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHERE THE CONTRACT LAYER DIFFERS FROM FEFERS — READ BEFORE EDITING
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 1. STEP 2 HAS TWO LEGS, AND IT NOW BUILDS BOTH. The arena-entry transaction
 *    (`Yards.enter`, fefers' `ArenaOptOut.setChoiceBatch`) and the ERC-20
 *    approval. `contracts/Yards.sol` is the bnbulls arena roster — THE BULL PIT
 *    in player copy (`brand.PIT`) — and `PitPanel` is the entry leg.
 *
 *    ⚠ THIS LEG IS NOT OPTIONAL AND ITS ABSENCE WAS AN OUTAGE.
 *    `Duel._requireInYards` runs on EVERY duel, staked or free, and reverts
 *    `BullNotInYards`. While this page had no pit control and the matchmaker
 *    had no pit filter, it happily offered fights against bulls that were out —
 *    and the way that surfaced was unreadable: gas estimation on a reverting
 *    call returns a garbage number, so the wallet reported "gas limit too high"
 *    about a transaction whose gas was never the problem.
 *
 *    ⚠ AND MEMBERSHIP LAPSES ON ITS OWN. Entry is `(enteredBy, leavesAt)` and
 *    requires `enteredBy == the live owner`, so a MARKETPLACE SALE voids it
 *    with no event. A bull bought here is out of the pit until its new owner
 *    sends it in, which is exactly how the bug above got made.
 *
 * 2. THE QUEUE IS SEQUENTIAL AND THE CONTRACT IS WHY. `Duel.sol`'s header:
 *    "at most one signed result naming a given wallet can ever settle… a holder
 *    with twenty bulls fights them in sequence, not in parallel." So ticking
 *    five bulls runs five fights back to back. It is not a batch submit and
 *    nothing here pretends it is.
 *
 * 3. ⚠⚠ **BNB NEEDS AN ALLOWANCE TOO.** This was reported the other way round
 *    once and it is the most expensive thing on this page to get wrong, so it
 *    is written out in full. `Duel._takeSide`:
 *
 *        // The native convenience path: only ever for the wallet that sent
 *        // the BNB, because only `msg.sender` can post value. A passive
 *        // opponent stakes by allowance, always.
 *        if (asset == address(wbnb) && owner_ == msg.sender && credit >= stake)
 *
 *    `owner_ == msg.sender` is the whole story. Raw `msg.value` covers YOUR
 *    side on a fight YOU submit. The instant somebody else picks one of your
 *    bulls you are the PASSIVE side, that branch fails, and settlement drops
 *    to the WBNB `balanceOf` + `allowance` path underneath it — reverting
 *    `StakeNotApproved` with no allowance.
 *
 *    ⚠ IT USED TO FAIL SILENTLY. `/api/run-duel`'s `resolveSide` `continue`d
 *    past a side that was not `erc20Ready`, so on the old AUTO pick those bulls
 *    were never matched, never errored and never explained themselves. AUTO is
 *    gone and every unusable currency now reports a named blocker, but the
 *    underlying fact is unchanged: a player told "bnb needs no approval" still
 *    ends up with bulls nobody can pick.
 *
 *    So step 2 carries an allowance block for BOTH currencies, and the gate on
 *    step 3 is deliberately NOT the same thing — see `moneyReady`.
 */

import { useEffect, useId, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { DuelAbi, MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatToken, formatUsd1e18, formatBps } from '@/lib/format';
import { useRoster, type RosterBull } from '@/lib/hooks/useRoster';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useFightAllowance, type FightAllowance } from '@/lib/hooks/useFightAllowance';
import { useDismissOnOutside } from '@/lib/hooks/useDismissOnOutside';
import { rankOpponents, pickOpponent, ratingGap } from '@/lib/matchmaking';
import { usePitPool } from '@/lib/hooks/useYards';
import { QUOTE_REFRESH_MS } from '@/lib/constants';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { BullCard } from '@/components/bulls/BullCard';
import { FightAction, type PayAsset } from '@/components/duel/FightAction';
import { PitPanel } from '@/components/duel/PitPanel';
import { CURRENCY, PIT } from '@/lib/brand';

const ZERO = '0x0000000000000000000000000000000000000000' as const;
const APPROVE_FIGHT_OPTIONS = [1, 5, 10, 25, 50] as const;

export function DuelPicker() {
  const duelAddress = contractAddress('duel');
  const marketAddress = contractAddress('marketplace');
  const { address: account } = useAccount();

  const roster = useRoster();

  // ── selection + the client-side queue ────────────────────────────
  const [ticked, setTicked] = useState<number[]>([]);
  const [nextId, setNextId] = useState<number | null>(null);
  const [settled, setSettled] = useState<number[]>([]);
  const [rerolls, setRerolls] = useState(0);
  const [myAsset, setMyAsset] = useState<PayAsset>('BNB');
  // One picked count PER CURRENCY — the allowances are separate on chain, so
  // the controls are separate here.
  const [approveFightsBnb, setApproveFightsBnb] = useState<number>(5);
  const [approveFightsBnbull, setApproveFightsBnbull] = useState<number>(5);
  const [open, setOpen] = useState(false);
  const autoPicked = useRef(false);

  // Tick the first living bull once, so a one-bull wallet never has to click
  // anything before it can fight. After that the player owns the selection.
  useEffect(() => {
    if (autoPicked.current) return;
    const first = roster.mine[0];
    if (!first) return;
    autoPicked.current = true;
    setTicked([first.id]);
    setNextId(first.id);
  }, [roster.mine]);

  const queue = useMemo(() => [...ticked].sort((a, b) => a - b), [ticked]);
  const pending = useMemo(() => queue.filter((id) => !settled.includes(id)), [queue, settled]);
  // "Fights next" is the player's explicit pick when it is still pending,
  // otherwise the head of the queue. Same rule fefers uses when the chosen
  // fefer stops being eligible.
  const currentId =
    nextId !== null && pending.includes(nextId) ? nextId : (pending[0] ?? null);
  const challenger = useMemo(
    () => roster.mine.find((b) => b.id === currentId) ?? null,
    [roster.mine, currentId],
  );

  function toggle(id: number) {
    setTicked((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }
  function makeNext(id: number) {
    setTicked((prev) => (prev.includes(id) ? prev : [...prev, id]));
    setNextId(id);
    setRerolls(0);
    setOpen(false);
  }

  // ── contract reads ───────────────────────────────────────────────
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
  const { data: usdFightPrice } = useReadContract({
    address: duelAddress ?? undefined,
    abi: DuelAbi,
    functionName: 'usdFightPrice1e18',
    query: { enabled: !!duelAddress },
  });

  const assetList = (fightAssets as readonly `0x${string}`[] | undefined) ?? [];

  /*
   * ⚠ THE PRICE IS READ, NEVER DERIVED HERE (`DECISIONS.md §26`).
   *
   * `Duel.stickerCost()` converts the stored dollar figure through Chainlink
   * itself and `Duel.fighterCost()` takes the discount off the result. Both are
   * read below. A UI that recomputes a number it then asks you to sign is a UI
   * that can disagree with the contract, and two implementations of one formula
   * always drift.
   *
   * A REVERT IS AN ANSWER: `stickerCost` reverts on the BNB leg when the feed
   * is stale or out of band, by design. `allowFailure` turns that into "this
   * leg cannot be priced right now" rather than a blank page or a guess.
   */
  const { data: costsData, dataUpdatedAt: costsUpdatedAt } = useReadContracts({
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

  const quoteAge = costsUpdatedAt
    ? Math.max(0, Math.round((Date.now() - costsUpdatedAt) / 1000))
    : undefined;

  /** `fighterCost` per leg — what ONE fight costs in each currency. */
  function costOf(addr: `0x${string}` | undefined): bigint | undefined {
    if (!addr) return undefined;
    const i = assetList.findIndex((a) => a.toLowerCase() === addr.toLowerCase());
    if (i < 0) return undefined;
    return costsData?.[i * 3]?.status === 'success' ? (costsData[i * 3].result as bigint) : undefined;
  }
  const bnbullCost = costOf(bnbullAddr as `0x${string}` | undefined);
  const wbnbCost = costOf(wbnbAddr as `0x${string}` | undefined);
  const { decimals: bnbullDecimals } = useTokenDecimals(bnbullAddr as `0x${string}` | undefined);
  const { decimals: wbnbDecimals } = useTokenDecimals(wbnbAddr as `0x${string}` | undefined);

  /**
   * ⚠ AN ALLOWANCE PER CURRENCY, AND **BNB NEEDS ONE TOO**.
   *
   * `Duel._takeSide` only lets raw `msg.value` cover a WBNB stake when
   * `owner_ == msg.sender` — i.e. your own side, on a fight YOU submit. When
   * somebody else picks one of your bulls you are the PASSIVE side and
   * settlement drops to the WBNB `balanceOf` + `allowance` path, reverting
   * `StakeNotApproved` without one. `/api/run-duel` used to skip such a side
   * silently on `AUTO`; it now names the blocker instead. See
   * `useFightAllowance` for the full note.
   */
  const bnbAllowance = useFightAllowance(
    wbnbAddr as `0x${string}` | undefined,
    duelAddress ?? undefined,
    wbnbCost,
    approveFightsBnb,
  );
  const bnbullAllowance = useFightAllowance(
    bnbullAddr as `0x${string}` | undefined,
    duelAddress ?? undefined,
    bnbullCost,
    approveFightsBnbull,
  );

  // ── matchmaking ──────────────────────────────────────────────────
  //
  // The pool is every LIVING bull. `rankOpponents` does the owner exclusion
  // itself off `allowSelfDuel`, so this must hand it the unfiltered list —
  // pre-filtering here would silently double-apply a rule that is settable on
  // chain.
  const alive = useMemo(() => roster.all.filter((b) => !b.isDead), [roster.all]);

  /**
   * ⚠ THE PIT FILTER. Without it this page offers fights that cannot settle.
   *
   * `usePitPool` costs one `inYardsMany` over the whole living roster, then
   * `statusOf` only over what came back IN — so the per-bull read is bounded by
   * the size of the pit, not the size of the drop. It returns `null` until both
   * reads land, and `rankOpponents` treats null as "no filter": an rpc hiccup
   * must never be allowed to say "there is nobody left to fight".
   */
  const aliveIds = useMemo(() => alive.map((b) => b.id), [alive]);
  const pit = usePitPool(aliveIds);

  const ranked = useMemo(
    () =>
      challenger
        ? rankOpponents({
            challenger,
            pool: alive,
            myAddress: account?.toLowerCase() ?? null,
            allowSelfDuel: allowSelfDuel === true,
            exclude: queue,
            matchable: pit.matchable,
          })
        : [],
    [challenger, alive, account, allowSelfDuel, queue, pit.matchable],
  );
  const opponent = pickOpponent(ranked, rerolls);

  // A listed bull cannot fight — `Duel._validate` reverts `BullIsListed`. Only
  // the MATCHED opponent is checked, not all 500: one read, and a hit is a
  // reroll rather than a dead end.
  const { data: oppListed } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'isListed',
    args: opponent ? [BigInt(opponent.id)] : undefined,
    query: { enabled: !!marketAddress && !!opponent },
  });

  /**
   * IS THE BULL THAT FIGHTS NEXT ACTUALLY IN THE PIT?
   *
   * `null` means the reads have not landed — deliberately not `false`, because
   * "we do not know yet" and "it is out" are different facts and only one of
   * them is worth blocking a button over.
   *
   * ⚠ `matchable` EXCLUDES A BULL WITH AN EJECT COUNTING DOWN, and that is the
   * right gate even for your OWN fighter. On chain it is still `inYards` so an
   * already-signed loss lands, but `/api/run-duel` will not issue a NEW
   * signature naming it, so a fight button that stayed lit would dead-end on a
   * refusal. Sending it back in cancels the departure instantly.
   */
  const challengerInPit: boolean | null =
    currentId === null || pit.matchable === null ? null : pit.matchable.has(currentId);
  const challengerLeaving = currentId !== null && pit.inPit.has(currentId) && challengerInPit === false;

  // Everything the page already knows would make `submitDuel` revert, collapsed
  // into one sentence. The signer re-checks every one of these against live
  // chain state and the contract enforces them for real — this is the polite
  // version, not the enforcement.
  const blockedReason: string | null = !account
    ? 'connect a wallet to fight.'
    : roster.mine.length === 0
      ? PIT.emptyWallet
      : pending.length === 0
        ? 'tick a bull in step 1 to send it in.'
        : !challenger
          ? 'that bull is no longer available to fight.'
          : challengerInPit === false
            ? challengerLeaving
              ? `#${currentId} is on its way out of ${PIT.label}, so no new fight can be matched for it. send it back in to cancel the departure.`
              : `#${currentId} is not in ${PIT.label}, and a bull that is out cannot be fought at all. send it in above.`
            : ranked.length === 0
              ? allowSelfDuel === true
                ? `there is nobody in ${PIT.label} to fight yet.`
                : `every other bull in ${PIT.label} is in your own wallet, and a wallet cannot fight itself.`
              : oppListed === true
                ? `#${opponent?.id} just got listed on the marketplace and cannot fight. reroll.`
                : null;

  // Step 2 is "done" once the money can actually move: BNB always can (it rides
  // with the transaction), BNBULL needs an allowance covering at least one
  // fight. Step 3 stays greyed until then, exactly like fefers' "step 2 first".
  // ⚠ THIS GATE IS ABOUT **YOUR OWN** SUBMITTED LEG ONLY, which is why BNB
  // passes it for free: `_takeSide`'s native path covers `msg.sender`. The
  // allowance blocks in step 2 are the OTHER half — what lets your bulls be
  // picked by someone else — and they are deliberately not a gate here,
  // because you can start a bnb fight without one.
  const moneyReady = myAsset === 'BNBULL' ? bnbullAllowance.fightsAllowed >= 1 : true;
  const step1Done = pending.length > 0;
  // ⚠ Step 2 is only done when BOTH its legs are: the bull is in the pit AND
  // the money can move. The pit leg is the harder gate of the two, because it
  // is the one the contract refuses outright rather than merely reverting on
  // payment. `null` (unread) does not mark the step done, and does not block
  // it either — `blockedReason` above owns the actual refusal.
  const pitReady = challengerInPit === true;
  const fightReady = step1Done && pitReady && moneyReady && !blockedReason;

  function onSettled() {
    if (currentId === null) return;
    setSettled((prev) => (prev.includes(currentId) ? prev : [...prev, currentId]));
    setRerolls(0);
  }

  if (!duelAddress) {
    return (
      <div>
        <NotDeployed what="the duel contract" className="mb-6" />
        <p className="text-sm text-bull-text-dim">
          once it&apos;s live: pick your bull and hit fight, and we find you an opponent on
          rating. every figure on this page is read off the contract, never recomputed here.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* ─── STEP 1 ─────────────────────────────────────────────── */}
      <section className="rounded border border-bull-border bg-bull-panel p-4">
        <div className="flex items-baseline justify-between gap-3">
          <StepHeading n={1} title="your fighter" done={step1Done} />
          <span className="font-mono text-[11px] text-bull-text-faint">
            {roster.mine.length} alive in your herd
          </span>
        </div>

        {!account ? (
          <p className="mt-3 text-sm text-bull-text-dim">connect a wallet to see your herd.</p>
        ) : roster.isLoading ? (
          <p className="mt-3 text-sm text-bull-text-dim">reading your herd off the chain…</p>
        ) : roster.unavailable ? (
          <div className="mt-3 text-sm text-bull-text-dim">
            <p>
              couldn&apos;t read the herd off the chain just now. that is this page failing to
              reach an rpc, not an empty wallet.
            </p>
            <button
              type="button"
              onClick={roster.refetch}
              className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
            >
              try again
            </button>
          </div>
        ) : roster.mine.length === 0 ? (
          <p className="mt-3 text-sm text-bull-text-dim">
            no living bulls in this wallet.{' '}
            <Link href="/mint" className="text-bull-gold hover:underline">
              mint one
            </Link>{' '}
            first.
          </p>
        ) : (
          <>
            <FighterDropdown
              bulls={roster.mine}
              ticked={ticked}
              currentId={currentId}
              settledIds={settled}
              inPit={pit.inPit}
              matchable={pit.matchable}
              open={open}
              onOpenChange={setOpen}
              onToggle={toggle}
              onMakeNext={makeNext}
            />
            <p className="mt-2 text-[11px] text-bull-text-faint">
              {alive.length > roster.mine.length
                ? `${alive.length - roster.mine.length} more alive in the full herd. `
                : ''}
              tick any of yours to send them in alongside it. they fight one after another.
            </p>
            {/* ⚠ SAID HERE AS WELL AS IN STEP 2, because this is the list where
                somebody picks a bull, and picking one that is out is how the
                whole "gas limit too high" mess started. */}
            <p className="mt-1 text-[11px] text-bull-text-faint">{PIT.rule}</p>
          </>
        )}
      </section>

      {/* ─── STEP 2 ─────────────────────────────────────────────── */}
      <section className="rounded border border-bull-border bg-bull-panel p-4">
        <StepHeading n={2} title="send them in" done={pitReady && moneyReady && step1Done} />

        <p className="mt-2 text-sm text-bull-text-dim">
          {challenger ? (
            <>
              sending one in:{' '}
              <span className="text-bull-text">
                {challenger.name.toLowerCase()} #{challenger.id}
              </span>
              .
            </>
          ) : (
            'tick a bull in step 1 first.'
          )}
          {pending.length > 1 && (
            <>
              {' '}
              {pending.length - 1} more ticked behind it.
            </>
          )}
        </p>

        {/* ─── LEG ONE: THE BULL PIT ────────────────────────────────
            The on-chain roster. `Duel` refuses a fight naming a bull that is
            not in it, so this is not a preference panel — it is the gate. The
            eject side of it is deliberately DELAYED and says so in words; see
            `PitPanel` and `Yards.sol`'s anti-dodge section. */}
        {account && roster.mine.length > 0 && (
          <div className="mt-4 border-t border-bull-border pt-4">
            <PitPanel bulls={roster.mine} onChanged={pit.refetch} />
          </div>
        )}

        <p className="mt-3 text-sm text-bull-text-dim">
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

        <div className="mt-4">
          <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
            pay with
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            <PayTab label="bnb" active={myAsset === 'BNB'} onClick={() => setMyAsset('BNB')} />
            <PayTab
              label="bnbull"
              active={myAsset === 'BNBULL'}
              onClick={() => setMyAsset('BNBULL')}
              disabled={bnbullCost === undefined || bnbullCost === 0n}
              disabledTitle={CURRENCY.bnbullPending}
            />
            {/* ⚠ "both" IS A MATCHMAKING PREFERENCE, NOT A SPLIT PAYMENT, AND IT
                CANNOT BE ONE. `Duel.DuelResult` carries exactly one asset per
                side (`assetA`/`assetB`) and `_takeSide` pulls ONE asset from ONE
                owner, so "half in each" is not expressible in the struct that
                gets signed. It would be a contract change, not a button.

                This replaced "whatever i can pay", which was the `AUTO` selector.
                AUTO did not just guess, it FAILED SILENTLY: `run-duel`'s
                `resolveSide` hit a side that could not pay and simply
                `continue`d, so the bull was never matched and the player had no
                way to find out why. Every currency that cannot be used now
                reports a named blocker instead. */}
            <PayTab
              label="both"
              active={myAsset === 'BOTH'}
              onClick={() => setMyAsset('BOTH')}
            />
          </div>
        </div>

        {/* ─── HOW MANY FIGHTS THE PACK IS ALLOWED ────────────────
            ⚠ BOTH CURRENCIES GET ONE, INCLUDING BNB. `Duel._takeSide` only
            lets raw `msg.value` cover a WBNB stake when `owner_ ==
            msg.sender`, so it covers YOUR side on a fight YOU submit and
            nothing else. When somebody else picks one of your bulls you are
            the passive side and settlement needs a WBNB allowance or it
            reverts `StakeNotApproved`. `/api/run-duel` used to skip such a side
            silently; it now says so. Telling a player "bnb needs no approval"
            is still what makes that unfixable from their side of the screen. */}
        <div className="mt-5 border-t border-bull-border pt-4">
          <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
            how many fights your pack is allowed
          </p>
          <p className="mt-2 text-sm text-bull-text-dim">
            approvals are per wallet and per currency: one covers every bull you send in, and
            each duel takes one fight&apos;s worth. you stop when the approval or the balance
            runs dry, or when a bull dies.
          </p>

          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <AllowanceBlock
              label="bnb"
              tokenLabel="wbnb"
              allowance={bnbAllowance}
              decimals={wbnbDecimals}
              fights={approveFightsBnb}
              setFights={setApproveFightsBnb}
              packSize={pending.length}
              unavailableNote="no bnb fight cost is registered on the duel contract yet."
            />
            <AllowanceBlock
              label="bnbull"
              tokenLabel="bnbull"
              allowance={bnbullAllowance}
              decimals={bnbullDecimals}
              fights={approveFightsBnbull}
              setFights={setApproveFightsBnbull}
              packSize={pending.length}
              unavailableNote={CURRENCY.bnbullPending}
            />
          </div>

          <p className="mt-3 text-[11px] text-bull-text-faint">
            it is one shared pool, not a budget per bull. send ten in and allow one fight, and
            the first fight by any one of them uses the lot — the other nine cannot fight until
            you top it up.
          </p>
          <p className="mt-1 text-[11px] text-bull-text-faint">
            paying for your OWN fight in bnb still needs no approval: the amount rides with the
            transaction and the contract wraps exactly what is owed and refunds the rest. the
            allowance above is what lets somebody else pick your bulls.
          </p>
        </div>

        <details className="mt-4">
          <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
            what a fight costs, per currency
          </summary>
          <div className="mt-3 overflow-x-auto">
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
        </details>
      </section>

      {/* ─── STEP 3 ─────────────────────────────────────────────── */}
      <section
        className={`rounded border bg-bull-panel p-4 transition ${
          fightReady ? 'border-bull-gold/40' : 'border-bull-border opacity-60'
        }`}
      >
        <div className="flex items-baseline justify-between gap-3">
          <StepHeading n={3} title="fight" done={false} />
          {!fightReady && (
            <span className="font-mono text-[11px] text-bull-text-faint">
              {step1Done ? 'step 2 first' : 'step 1 first'}
            </span>
          )}
        </div>

        {challenger && opponent ? (
          <>
            <div className="mt-4 grid gap-3 sm:grid-cols-[1fr_auto_1fr] sm:items-center">
              <Link
                href={`/bull/${challenger.id}`}
                className="bull-card block rounded border border-bull-border p-3 transition hover:border-bull-gold"
              >
                <BullCard
                  id={challenger.id}
                  facts={{
                    name: challenger.name,
                    elo: challenger.elo,
                    wins: challenger.wins,
                    losses: challenger.losses,
                    ties: challenger.ties,
                  }}
                />
              </Link>
              <p className="bull-header text-center text-sm text-bull-text-faint">vs</p>
              <Link
                href={`/bull/${opponent.id}`}
                className="bull-card block rounded border border-bull-border p-3 transition hover:border-bull-gold"
              >
                <BullCard
                  id={opponent.id}
                  facts={{
                    name: opponent.name,
                    elo: opponent.elo,
                    wins: opponent.wins,
                    losses: opponent.losses,
                    ties: opponent.ties,
                  }}
                />
              </Link>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-3">
              <button
                type="button"
                onClick={() => setRerolls((n) => n + 1)}
                disabled={ranked.length < 2}
                className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
              >
                find another opponent
              </button>
              <span className="font-mono text-[11px] text-bull-text-faint">
                {ratingGap(challenger, opponent) === 0
                  ? 'dead level on rating'
                  : `${ratingGap(challenger, opponent)} rating apart`}{' '}
                · closest of {ranked.length} available
              </span>
            </div>
          </>
        ) : (
          <p className="mt-4 text-sm text-bull-text-dim">{blockedReason ?? 'no match yet.'}</p>
        )}

        <div className="mt-4">
          <FightAction
            duelAddress={duelAddress}
            myTokenId={currentId}
            oppTokenId={opponent?.id ?? null}
            blockedReason={blockedReason}
            myAsset={myAsset}
            approveFights={Math.max(1, pending.length)}
            onSettled={onSettled}
          />
        </div>

        <p className="mt-4 text-[11px] text-bull-text-faint">
          the fight is simulated off chain from a random seed and the result is signed. the
          contract verifies the signature, it never re-runs the fight. the seed is public, so
          anyone can re-run it and catch a lying signer.
        </p>

        {queue.length > 1 && (
          <div className="mt-4 border-t border-bull-border pt-3">
            <p className="font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
              the queue
            </p>
            <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 font-mono text-xs">
              {queue.map((id) => (
                <li
                  key={id}
                  className={
                    settled.includes(id)
                      ? 'text-bull-text-faint'
                      : id === currentId
                        ? 'text-bull-gold'
                        : 'text-bull-text-dim'
                  }
                >
                  {settled.includes(id) ? '✓' : id === currentId ? '●' : '○'} #{id}
                </li>
              ))}
            </ul>
            <p className="mt-2 text-[11px] text-bull-text-faint">
              one at a time, because the contract allows one signed fight per wallet. settle the
              one on screen and the next steps up.
            </p>
          </div>
        )}
      </section>
    </div>
  );
}

/**
 * One currency's standing allowance: how many fights the WHOLE PACK is still
 * allowed in it, the approve control, and the revoke.
 *
 * ⚠ THE COUNT IS LIMITED BY BALANCE AS WELL AS BY APPROVAL, because
 * `Duel._takeSide` checks both before it will pull a passive stake
 * (`StakeUnaffordable` then `StakeNotApproved`). A wallet that approved fifty
 * fights but holds two fights' worth can be drawn into two, so "50 approved"
 * would be exactly the kind of confident wrong number this page exists to
 * avoid. When the balance is the binding constraint it says so, because
 * approving more would change nothing.
 */
function AllowanceBlock({
  label,
  tokenLabel,
  allowance,
  decimals,
  fights,
  setFights,
  packSize,
  unavailableNote,
}: {
  label: string;
  tokenLabel: string;
  allowance: FightAllowance;
  decimals: number | undefined;
  fights: number;
  setFights: (n: number) => void;
  /** Bulls currently ticked and still to fight. */
  packSize: number;
  unavailableNote: string;
}) {
  const { configured, fightsAllowed, limitedByBalance, approvalTotal, isApproving } = allowance;

  if (!configured) {
    return (
      <div className="rounded border border-bull-border bg-bull-bg p-3">
        <p className="font-mono text-xs text-bull-text-dim">{label}</p>
        <p className="mt-2 text-[11px] text-bull-text-faint">{unavailableNote}</p>
      </div>
    );
  }

  // ⚠ THE WARNING THE OWNER ASKED FOR BY NAME: "10 bulls in, 1 fight
  // approved" means nine of them cannot fight, and nothing else on the page
  // would ever tell you that.
  const short = packSize > 0 && fightsAllowed < packSize;

  return (
    <div
      className={`rounded border bg-bull-bg p-3 ${
        fightsAllowed > 0 ? 'border-bull-border' : 'border-bull-gold/40'
      }`}
    >
      <p className="flex flex-wrap items-center justify-between gap-2 font-mono text-xs">
        {fightsAllowed > 0 ? (
          <span className="text-bull-gold">
            ✓ {label}: {fightsAllowed} fight{fightsAllowed === 1 ? '' : 's'} allowed
          </span>
        ) : (
          <span className="text-bull-text-faint">{label}: no fights allowed yet</span>
        )}
        {(allowance.allowance ?? 0n) > 0n && (
          <button
            type="button"
            onClick={async () => {
              await allowance.revoke();
              allowance.refetch();
            }}
            className="rounded-full border border-bull-border px-2 py-0.5 text-[11px] text-bull-text-dim hover:border-bull-red hover:text-bull-red"
          >
            revoke
          </button>
        )}
      </p>

      {limitedByBalance && (
        <p className="mt-1.5 text-[11px] text-bull-text-faint">
          your {tokenLabel} balance is what caps this, not the approval. approving more would
          not change it.
        </p>
      )}

      {short && (
        <p className="mt-1.5 text-[11px] text-bull-red">
          {packSize} bull{packSize === 1 ? '' : 's'} sent in but only {fightsAllowed} fight
          {fightsAllowed === 1 ? '' : 's'} allowed in {label}, so{' '}
          {packSize - fightsAllowed} of them cannot fight in it until you top this up.
        </p>
      )}

      <div className="mt-2 flex flex-wrap items-center gap-2 text-sm">
        <span className="text-bull-text-dim">allow</span>
        <select
          value={fights}
          onChange={(e) => setFights(Number(e.target.value))}
          className="rounded border border-bull-border bg-bull-panel px-2 py-1 font-mono text-sm"
        >
          {APPROVE_FIGHT_OPTIONS.map((n) => (
            <option key={n} value={n}>
              {n} fight{n === 1 ? '' : 's'}
            </option>
          ))}
        </select>
        <span className="font-mono text-xs text-bull-gold">
          = {approvalTotal !== undefined ? formatToken(approvalTotal, decimals) : '—'} {tokenLabel}
        </span>
      </div>

      <button
        type="button"
        onClick={async () => {
          await allowance.approve();
          allowance.refetch();
        }}
        disabled={isApproving || approvalTotal === undefined}
        className="mt-2 w-full rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold disabled:opacity-40"
      >
        {isApproving ? 'approving…' : `approve ${fights} fight${fights === 1 ? '' : 's'} of ${tokenLabel}`}
      </button>

      <p className="mt-1.5 text-[11px] text-bull-text-faint">
        revoking sets it to zero for the whole wallet, so it pulls every bull you have sent in
        out of {label} at once.
      </p>
    </div>
  );
}


/** Fefers' numbered step bubble: a ✓ once the step is satisfied, the number
 *  otherwise. */
function StepHeading({ n, title, done }: { n: number; title: string; done: boolean }) {
  return (
    <h2 className="flex items-center gap-2">
      <span
        className={`inline-flex h-5 w-5 items-center justify-center rounded-full border font-mono text-[11px] ${
          done ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-faint'
        }`}
      >
        {done ? '✓' : n}
      </span>
      <span className="bull-header text-sm lowercase text-bull-text">{title}</span>
    </h2>
  );
}

function PayTab({
  label,
  active,
  onClick,
  disabled,
  disabledTitle,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
  disabled?: boolean;
  disabledTitle?: string;
}) {
  const base = 'rounded-full border px-3 py-1.5 text-xs font-medium transition';
  const cls = disabled
    ? `${base} cursor-not-allowed border-bull-border text-bull-text-faint opacity-50`
    : active
      ? `${base} border-bull-gold text-bull-gold`
      : `${base} border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-text`;
  return (
    <button
      type="button"
      className={cls}
      disabled={disabled}
      title={disabled ? disabledTitle : undefined}
      onClick={onClick}
    >
      {label}
    </button>
  );
}

/**
 * THE FIGHTER DROPDOWN. Closed it reads `#501 lord wagyu`. Open it is the list
 * of every living bull you own, one row each:
 *
 *   ☐ #1  sid calverley   rating 1000            benched
 *   ☑ #501 lord wagyu     rating 1000     [fighting next]
 *
 * A TICK sends that bull in. CLICKING THE NAME makes it the one that fights
 * next. Straight off the fefers screenshot, including the instruction line at
 * the top of the panel.
 *
 * ⚠ IT CLOSES ON A CLICK IN BLANK SPACE AND ON ESCAPE, AND THE "INSIDE" TEST IS
 * LOAD-BEARING. Owner, 2026-08-07: "i should be able to click anywhere in blank
 * space and the drop down goes away". `useDismissOnOutside` does it on a
 * document `pointerdown` — but this panel is a MULTI-SELECT, so a handler that
 * closed on any document click would kill the ticking that the checkboxes exist
 * for: one tick and the list is gone. Hence `root.contains(target)`, and hence
 * the ref sits on the wrapper around BOTH the trigger and the panel — that way
 * pressing the trigger reads as an inside press and its own `onClick` is the
 * only thing that toggles, instead of the two fighting and cancelling out.
 *
 * The one inside-click that DOES close it is clicking a NAME, because that is
 * "this one fights next" — a decision, not a selection. See `makeNext`.
 */
function FighterDropdown({
  bulls,
  ticked,
  currentId,
  settledIds,
  inPit,
  matchable,
  open,
  onOpenChange,
  onToggle,
  onMakeNext,
}: {
  bulls: readonly RosterBull[];
  ticked: readonly number[];
  currentId: number | null;
  settledIds: readonly number[];
  /** In the yards right now, countdown or not. */
  inPit: ReadonlySet<number>;
  /** In the yards AND not leaving. `null` until the reads land — a row must
   *  not be branded "out" off a read that has not answered. */
  matchable: ReadonlySet<number> | null;
  open: boolean;
  onOpenChange: (v: boolean) => void;
  onToggle: (id: number) => void;
  onMakeNext: (id: number) => void;
}) {
  const current = bulls.find((b) => b.id === currentId) ?? null;
  const panelId = useId();
  const triggerRef = useRef<HTMLButtonElement>(null);

  // The ref goes on the WRAPPER, so the trigger counts as inside — see the
  // header note. Escape hands focus back to the trigger, because a keyboard
  // player who dismisses the panel has to be left somewhere they can carry on
  // from; a pointer dismissal leaves focus wherever the pointer put it.
  const rootRef = useDismissOnOutside<HTMLDivElement>(open, (reason) => {
    onOpenChange(false);
    if (reason === 'escape') triggerRef.current?.focus();
  });

  return (
    <div ref={rootRef} className="relative mt-3">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => onOpenChange(!open)}
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        className="flex w-full items-center justify-between rounded border border-bull-border bg-bull-bg px-3 py-2 text-left font-mono text-sm hover:border-bull-gold"
      >
        <span>
          {current ? (
            <>
              #{current.id} <span className="text-bull-text">{current.name.toLowerCase()}</span>
            </>
          ) : (
            'pick a bull'
          )}
        </span>
        <span className="text-bull-text-faint">{open ? '▲' : '▼'}</span>
      </button>

      {open && (
        <div
          id={panelId}
          role="group"
          aria-label="your living bulls"
          className="absolute left-0 right-0 z-20 mt-1 max-h-80 overflow-y-auto rounded border border-bull-gold/50 bg-bull-bg shadow-lg"
        >
          <p className="border-b border-bull-border px-3 py-2 text-[11px] text-bull-text-faint">
            {PIT.pickerHint}
          </p>
          {bulls.map((b) => {
            const isNext = b.id === currentId;
            const isTicked = ticked.includes(b.id);
            const isSettled = settledIds.includes(b.id);
            // ⚠ THREE-VALUED ON PURPOSE. `null` while the pit reads are in
            // flight, so a row never says "out of the pit" off a read that has
            // not answered — that would send somebody to enter a bull that is
            // already in.
            const pitState: 'in' | 'leaving' | 'out' | null =
              matchable === null
                ? null
                : matchable.has(b.id)
                  ? 'in'
                  : inPit.has(b.id)
                    ? 'leaving'
                    : 'out';
            return (
              <div
                key={b.id}
                className={`flex items-center gap-3 px-3 py-2 ${isNext ? 'bg-bull-gold/10' : ''}`}
              >
                <input
                  type="checkbox"
                  checked={isTicked}
                  onChange={() => onToggle(b.id)}
                  className="h-4 w-4 shrink-0 accent-bull-gold"
                  aria-label={`send #${b.id} ${b.name} in`}
                />
                <button
                  type="button"
                  onClick={() => onMakeNext(b.id)}
                  className="flex min-w-0 flex-1 items-baseline gap-2 text-left font-mono text-xs hover:text-bull-gold"
                >
                  <span className="text-bull-text-faint">#{b.id}</span>
                  <span className="truncate text-bull-text">{b.name.toLowerCase()}</span>
                  <span className="shrink-0 text-bull-text-faint">rating {b.elo}</span>
                  <span className="shrink-0 text-bull-text-faint">
                    {b.wins}w / {b.losses}l / {b.ties}t
                  </span>
                </button>
                {pitState !== null && pitState !== 'in' && (
                  <span
                    className={`shrink-0 font-mono text-[10px] ${
                      pitState === 'leaving' ? 'text-bull-gold' : 'text-bull-red'
                    }`}
                  >
                    {pitState === 'leaving' ? PIT.leavingLabel : PIT.outLabel}
                  </span>
                )}
                <span
                  className={`shrink-0 rounded-full px-2 py-0.5 font-mono text-[10px] ${
                    isNext
                      ? 'bg-bull-gold text-bull-gold-ink'
                      : isSettled
                        ? 'text-bull-text-faint'
                        : 'text-bull-text-faint'
                  }`}
                >
                  {isNext ? 'fighting next' : isSettled ? 'fought' : isTicked ? 'queued' : 'benched'}
                </span>
              </div>
            );
          })}
        </div>
      )}
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
