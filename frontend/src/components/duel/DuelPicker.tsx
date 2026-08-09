'use client';

/**
 * THE DUEL PAGE, IN FEFERS' ORDER. THREE FOLDABLE SECTIONS, TOP TO BOTTOM.
 *
 *   your fight              the flow, three numbered steps, one active at a time
 *     1  your fighter       the dropdown. tick to send a bull in, click a name
 *                           to make it the one that fights next
 *     2  send them in       what is going in, then the money: pay-with, how many
 *                           fights, ONE primary button, and the standing
 *                           approvals kept quiet underneath. Folds itself to a
 *                           one-line summary the moment it is satisfied.
 *     3  fight              greyed until step 2 is done, then the two fighter
 *                           cards side by side and the fight button
 *   your herd in the pit    the way back out: per-bull and bulk enter/eject
 *   who is in the pit       the whole roster, everybody's, at the bottom
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS SHAPE IS FEFERS', NOT AN INVENTION. DO NOT FLATTEN IT BACK.
 * ═══════════════════════════════════════════════════════════════════════
 * Owner, 2026-08-07, third complaint about this page: *"i still hate the duel
 * page, it's not laid out like fefers. you could collapse each section in
 * fefers, and the roster of all of them waiting should be at bottom, and the
 * buttons and approvals it's all just a bloody mess."*
 *
 * The three things he named, and where each of them went:
 *
 *   · COLLAPSIBLE SECTIONS. `DuelSection` is fefers' `CollapsibleSection`: a
 *     header row you click, a body that folds, and the body stays MOUNTED so a
 *     fight in flight is never thrown away by a fold. State is remembered for
 *     the session.
 *
 *   · THE ROSTER AT THE BOTTOM. `PitRoster` used to render in the MIDDLE of
 *     step 2, inside `PitPanel`, between the money controls. It is the
 *     browse-the-field surface, not a step in the fight, so it is now the last
 *     section on the page — and it renders for a disconnected visitor too,
 *     because a stranger landing on /duel and seeing the field queued up is the
 *     shopfront. Fefers ranks `ArenaLineup` exactly this way.
 *
 *   · ONE OBVIOUS NEXT ACTION. Step 2 used to show, all at once and all equally
 *     loud: two pit bulk buttons, a button per bull, three currency tabs, five
 *     fight-count pills, a full-width approve, a revoke and two disclosures.
 *     Now it shows the FIRST outstanding thing and nothing else — send them in,
 *     or approve — and when neither is outstanding it shows no button at all and
 *     says so, which is fefers' `nothingWaiting`. The pit's own controls moved to
 *     their own section; the count moved from five pills to one select; the
 *     approvals sit quiet under a divider next to the control that creates them.
 *
 * ⚠ THE STEP LADDER IS RANKED BY WHAT ACTUALLY BLOCKS, and that ordering is the
 * whole point of the button. Sending a bull in blocks EVERYTHING (the contract
 * refuses outright), so it is always first. A first approval comes next, because
 * it is what lets your herd be picked while you are offline. Topping an existing
 * approval up is optional and never takes the primary slot — it is a quiet
 * button next to the allowance line, or it would be the fourth loud thing on the
 * step and we would be back where we started.
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
 * 3. ⚠⚠ **FIGHTING IN BNB NEEDS NO ALLOWANCE, NO WBNB AND NO WRAP.** This page
 *    spent a day teaching the opposite and it cost real players real
 *    signatures, so the true shape is written out in full. `Duel._takeSide`:
 *
 *        // The native convenience path: only ever for the wallet that sent
 *        // the BNB, because only `msg.sender` can post value. A passive
 *        // opponent stakes by allowance, always.
 *        if (asset == address(wbnb) && owner_ == msg.sender && credit >= stake)
 *
 *    `owner_ == msg.sender` is the whole story, and it cuts BOTH ways:
 *
 *      · YOU START A FIGHT → you are `msg.sender`, the branch hits, and
 *        `_collectStakes` wraps only what your side owed out of `msg.value` and
 *        REFUNDS THE REST. Nothing to approve. Nothing to hold. Nothing to wrap.
 *      · SOMEBODY ELSE PICKS YOUR BULL → you are the PASSIVE side, you are not
 *        signing, the branch fails, and settlement drops to the WBNB
 *        `balanceOf` + `allowance` path underneath. Native bnb has no allowance
 *        primitive on any EVM chain, so this is the only way a wallet that is
 *        not sending the transaction can be charged at all.
 *
 *    ⚠⚠ SO THE ALLOWANCE BUYS EXACTLY ONE THING: being challengeable while you
 *    are offline. It is OPTIONAL, it is not a step in fighting, and it must
 *    never take the primary slot on the bnb leg. It did, for one day, as a
 *    wrap-then-approve ladder — and six mainnet wallets signed approvals they
 *    did not need while three of them wrapped nothing at all, which left them
 *    approved-with-an-empty-balance and unfightable. The setup is real and
 *    worth offering; presenting it as the price of entry was the bug.
 *
 *    ⚠ BNBULL IS THE OTHER WAY ROUND and that asymmetry is the reason the
 *    ladder branches on currency rather than on a flag. Bnbull can ONLY move by
 *    allowance, so on that leg the approval genuinely does gate your own fight.
 *    See `approvalBlocksMyFight` and `moneyReady` — they are different questions
 *    and step 3's gate is the second one.
 */

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { DuelAbi, MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatToken, formatUsd1e18, formatBps } from '@/lib/format';
import { useRoster, type RosterBull } from '@/lib/hooks/useRoster';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useFightAllowance, type FightAllowance } from '@/lib/hooks/useFightAllowance';
import { useBnbullLocked } from '@/lib/hooks/useBnbullLocked';
import { useWrapBnb } from '@/lib/hooks/useWrapBnb';
import { useDismissOnOutside } from '@/lib/hooks/useDismissOnOutside';
import { rankOpponents, pickOpponent, ratingGap } from '@/lib/matchmaking';
import { usePitPool } from '@/lib/hooks/useYards';
import { QUOTE_REFRESH_MS } from '@/lib/constants';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { BullCard } from '@/components/bulls/BullCard';
import { FightAction, type PayChoice } from '@/components/duel/FightAction';
import { PitPanel, PitEntryButton } from '@/components/duel/PitPanel';
import { PitRoster } from '@/components/pit/PitRoster';
import { DuelSection, useDuelSectionState } from '@/components/duel/DuelSection';
import { DuelFlowStep, type DuelStepState } from '@/components/duel/DuelFlowStep';
import { CURRENCY, PIT } from '@/lib/brand';

const ZERO = '0x0000000000000000000000000000000000000000' as const;
const APPROVE_FIGHT_OPTIONS = [1, 5, 10, 25, 50] as const;

/**
 * The three foldable sections, and what each of them starts as.
 *
 * ⚠ THE DEFAULTS ARE A RANKING, NOT A PREFERENCE. Owner: *"the section a player
 * is acting in should be the one that is open."* The flow is where you act, so
 * it opens. The roster opens too, because it is at the bottom where it costs
 * nothing above the fold and a stranger has to be able to see the field without
 * hunting for a chevron. The herd panel is management — the way back out — so it
 * starts folded, exactly as fefers starts its "eject status" section folded.
 */
type DuelSectionId = 'your-fight' | 'your-herd' | 'pit-roster';
const SECTION_DEFAULTS: Readonly<Record<DuelSectionId, boolean>> = {
  'your-fight': true,
  'your-herd': false,
  'pit-roster': true,
};
const SECTION_STORAGE_KEY = 'bnbulls.duel.sections';

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
  const [myAsset, setMyAsset] = useState<PayChoice>('BNB');
  /**
   * ⚠ ONE COUNT FOR THE WHOLE PAGE. Owner, 2026-08-07: *"they just need to say
   * how many fights they are keen for."*
   *
   * It used to be one picked count per currency, on the reasoning that the two
   * allowances are separate on chain. They are, but the QUESTION is not: "how
   * many fights am i up for" has one answer, and asking it twice is how a
   * player ended up signing an approve for bnb and then another for bnbull
   * before a single fight had happened. One number, applied to whichever
   * currency is actually being approved, and it sizes the approve that
   * `FightAction` would otherwise have to top up mid-fight.
   *
   * Ten by default: the approve is the leg people trip on, so it is bought
   * down once and every fight after it is a single confirm.
   */
  const [fightsWanted, setFightsWanted] = useState<number>(10);
  const [open, setOpen] = useState(false);
  const autoPicked = useRef(false);
  const fightsSelectId = useId();

  /**
   * The player asked step 2 back open after it had folded itself away. `false`
   * means "follow the flow": open while there is setup outstanding, folded to a
   * summary line the instant there is not. Straight off fefers' `openStep`.
   */
  const [openStep2, setOpenStep2] = useState(false);

  const { open: sections, setSection } = useDuelSectionState<DuelSectionId>(
    SECTION_STORAGE_KEY,
    SECTION_DEFAULTS,
  );

  /**
   * A FIGHT ON SCREEN OWNS THE SCREEN.
   *
   * Fefers gets this by rendering the whole idle page only while `phase.kind ===
   * 'idle'`, so the roster and the side panels are simply not there during a
   * fight. Our fight state lives inside `FightAction`, one level down, and
   * hoisting it would be a rewrite of the flow rather than of the layout — so
   * this does the same job through the fold instead: the moment an arena is up,
   * everything below it folds and the flow stays open.
   *
   * ⚠ ONE DIRECTION ONLY. It never re-opens anything when the fight goes away,
   * because by then the player has had a chance to fold things themselves and
   * un-folding under them would throw that away.
   */
  const handleFightVisible = useCallback(
    (visible: boolean) => {
      if (!visible) return;
      setSection('your-fight', true);
      setSection('your-herd', false);
      setSection('pit-roster', false);
    },
    [setSection],
  );

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
    fightsWanted,
  );
  const bnbullAllowance = useFightAllowance(
    bnbullAddr as `0x${string}` | undefined,
    duelAddress ?? undefined,
    bnbullCost,
    fightsWanted,
  );

  /**
   * ⚠ IS THE BNBULL LEG USABLE AT ALL RIGHT NOW?
   *
   * Every OTHER bnbull leg on the site (mint, marketplace, graveyard) can ask
   * this with a zero-price test, because those contracts treat an unpriced leg
   * as disabled. `Duel` does the opposite — `Duel.sol:536` makes a zero cost a
   * FREE fight, and a free fight still opens a jackpot ticket — so the duel's
   * bnbull cost is deliberately a real number and cannot double as the switch.
   * The token's own transfer lock is the honest signal, and it flips itself at
   * graduation. See `useBnbullLocked`.
   *
   * ⚠ `bnbullCost === 0n` IS STILL CHECKED ALONGSIDE IT. The two say different
   * things: the lock is "the token cannot move", the zero is "no price is
   * registered". Either one makes the leg unusable, and dropping the old test
   * would re-open the free-fight reading.
   */
  const { locked: bnbullLocked } = useBnbullLocked(bnbullAddr as `0x${string}` | undefined);
  const bnbullUnusable = bnbullLocked === true || bnbullCost === undefined || bnbullCost === 0n;

  /**
   * THE ONE CURRENCY THIS PLAYER IS ASKED TO SIGN FOR.
   *
   * `BOTH` lands on bnb because that is what `/api/run-duel` resolves it to
   * first (`DECISIONS.md §29`, and `§39` deleted the fight discount that used
   * to make bnbull worth trying first), so the primary approval matches the
   * currency the fight will actually settle in. The other one is still
   * reachable, one disclosure down, and nothing on the page requires it.
   *
   * ⚠ DERIVED, NOT AN EFFECT. `ListBullForm` does the same thing for its pegged
   * mode and for the same reason: if the leg goes unusable while a player is
   * sitting on the page with `BNBULL` already picked, a held state could still
   * reach the fight. Deriving it means the unusable currency can never be the
   * one that settles, whatever was clicked before the read landed.
   */
  const effectiveAsset: PayChoice = bnbullUnusable && myAsset === 'BNBULL' ? 'BNB' : myAsset;
  const primaryIsBnbull = effectiveAsset === 'BNBULL';

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
  const moneyReady = effectiveAsset === 'BNBULL' ? bnbullAllowance.fightsAllowed >= 1 : true;
  const step1Done = pending.length > 0;
  // ⚠ Step 2 is only done when BOTH its legs are: the bull is in the pit AND
  // the money can move. The pit leg is the harder gate of the two, because it
  // is the one the contract refuses outright rather than merely reverting on
  // payment. `null` (unread) does not mark the step done, and does not block
  // it either — `blockedReason` above owns the actual refusal.
  const pitReady = challengerInPit === true;
  const fightReady = step1Done && pitReady && moneyReady && !blockedReason;

  // ── STEP 2'S ONE BUTTON, AND THE LADDER BEHIND IT ────────────────
  //
  // ⚠ `matchable` IS THREE-VALUED AND AN UNREAD PIT OFFERS NOTHING. `null`
  // means the reads have not landed, and a button that said "send 4 into the
  // pit" off an unread membership would be asking for a transaction that does
  // nothing for bulls that are already in.
  /** Ticked, still to fight, and the pit will not match them right now. Includes
   *  a bull with an eject counting down: `Yards.enter` writes `leavesAt: 0`, so
   *  sending it back in cancels the departure on the spot. */
  const sendInIds = useMemo(() => {
    const m = pit.matchable;
    if (!m) return [] as number[];
    return pending.filter((id) => !m.has(id));
  }, [pending, pit.matchable]);
  /** The membership reads have not answered. ⚠ NOT the same as "nothing to
   *  send", and step 2 must not say the second when it means the first — an
   *  empty `sendInIds` is produced by both, so the check has to be explicit. */
  const pitUnread = pit.matchable === null;

  /** Yours that are in the pit right now, for step 2's folded summary line. */
  const myInPitCount = useMemo(
    () => roster.mine.filter((b) => pit.inPit.has(b.id)).length,
    [roster.mine, pit.inPit],
  );

  // The currency the player is actually being asked to sign for. `BOTH` lands on
  // bnb, same as `/api/run-duel` resolves it — see `primaryIsBnbull`.
  const primaryAllowance = primaryIsBnbull ? bnbullAllowance : bnbAllowance;
  const primaryDecimals = primaryIsBnbull ? bnbullDecimals : wbnbDecimals;
  /** What the wallet will actually approve. The bnb leg's ERC-20 is WBNB and
   *  the button has to say so, or somebody goes looking for the wrong token. */
  const primaryTokenLabel = primaryIsBnbull ? 'bnbull' : 'wbnb';
  const primaryCurrencyLabel = primaryIsBnbull ? 'bnbull' : 'bnb';

  /**
   * NOTHING APPROVED YET IN THE CURRENCY YOU PICKED.
   *
   * ⚠ THIS IS A FACT, NOT A BLOCKER — read `approvalBlocksMyFight` below before
   * wiring it to anything. On bnbull an empty allowance really does stop you
   * fighting. On bnb it stops NOTHING you are trying to do here: your own side
   * rides in as `msg.value`. All it changes on the bnb leg is whether somebody
   * else can pick your bulls while you are offline.
   *
   * ⚠ AND IT IS NOT ASKED FOR WHEN IT WOULD CHANGE NOTHING. When the BALANCE is
   * the binding constraint, approving more buys zero extra fights, so the ladder
   * skips it and the allowance row says why.
   */
  const needsFirstApproval =
    primaryAllowance.configured &&
    primaryAllowance.fightsAllowed < 1 &&
    !primaryAllowance.limitedByBalance;

  /**
   * ⚠⚠ THE ONE QUESTION THE STEP-2 LADDER IS ALLOWED TO ASK: does this stop the
   * player fighting RIGHT NOW?
   *
   * Only on bnbull, because bnbull can only ever move by allowance. On bnb the
   * answer is always no — `Duel._takeSide` takes your side out of `msg.value`
   * and `_collectStakes` refunds the remainder.
   *
   * This distinction is the whole fix. The ladder used to ask "is there an
   * allowance?" and put a gold button in front of every bnb player who did not
   * have one, which taught six mainnet wallets that wbnb was the price of entry.
   * Three of them approved ~0.1655 wbnb (fifty fights' worth) while holding
   * ZERO, so `fightsAllowed` floored to 0 with `limitedByBalance` true, step 2
   * declared itself done, and step 3 could never work. The setup was never the
   * problem; presenting it as a prerequisite was.
   */
  const approvalBlocksMyFight = primaryIsBnbull && needsFirstApproval;

  /**
   * THE OPTIONAL SETUP: wrapping bnb so your bulls can be CHALLENGED offline.
   *
   * ⚠ IT IS NEVER THE PRIMARY BUTTON AND IT NEVER HOLDS STEP 2 OPEN. Wrapping
   * buys exactly one thing — being pickable while you are not at the keyboard —
   * and a player who only ever starts their own fights never needs a single wei
   * of it. It lives under the divider, behind a disclosure that says what it is
   * for, and `AllowanceRow` owns the control and its own `useWrapBnb` sizing.
   *
   * ⚠ THE STEP DELIBERATELY DOES NOT CALL `useWrapBnb` ITSELF ANY MORE. It did,
   * to drive a primary wrap button, and that button is exactly what this change
   * removes — a second copy of the sizing up here would only invite it back.
   */
  /** Has this wallet opted into being challenged at all? Drives the disclosure's
   *  summary line, so it reads as a state rather than a chore. */
  const challengeable = !primaryIsBnbull && primaryAllowance.fightsAllowed > 0;
  /** ⚠ THERE IS DELIBERATELY NO `wantsTopUp` GATE HERE, and no wrap gate either.
   *  The only signature step 2 will ever hold itself open for is one that blocks
   *  the fight in front of the player. Everything else is offered, not demanded. */
  const nothingOutstanding = sendInIds.length === 0 && !approvalBlocksMyFight;

  // ── STEP STATE ───────────────────────────────────────────────────
  const step2Done = step1Done && pitReady && moneyReady && nothingOutstanding;
  /** Open while there is setup outstanding, or when the player asked for it
   *  back. Never for a wallet with nothing in it: there is nothing in it for
   *  them. */
  const step2Open = !!account && roster.mine.length > 0 && (!step2Done || openStep2);
  const step1State: DuelStepState = step1Done ? 'done' : 'active';
  const step2State: DuelStepState = !account ? 'waiting' : step2Done ? 'done' : 'active';
  const step3State: DuelStepState = fightReady ? 'active' : 'waiting';

  // Step 2 folds itself back the moment it is satisfied. Without this, opening
  // it by hand to top up an approval leaves it sitting open with nothing to do
  // once the approval lands. Fefers does exactly this.
  const step2DoneRef = useRef(step2Done);
  useEffect(() => {
    if (step2Done && !step2DoneRef.current) setOpenStep2(false);
    step2DoneRef.current = step2Done;
  }, [step2Done]);

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

  /** "lord wagyu #501", for the lists that read better as names than counts. */
  const nameOf = (id: number) => {
    const b = roster.mine.find((x) => x.id === id);
    return b ? `${b.name.toLowerCase()} #${id}` : `bull #${id}`;
  };

  return (
    <div className="space-y-4">
      {/* ═══════════════════════════════════════════════════════════
          SECTION 1 · YOUR FIGHT — the three-step flow, folded as one.
          Fefers wraps its whole stepper in a single "stomping ground"
          collapsible and this is the same wrapper. The steps inside are
          UNCHANGED in what they do; only their ranking moved.
          ═══════════════════════════════════════════════════════════ */}
      <DuelSection
        id="your-fight"
        title="your fight"
        meta={challenger ? `${challenger.name.toLowerCase()} #${challenger.id}` : undefined}
        open={sections['your-fight']}
        onOpenChange={(v) => setSection('your-fight', v)}
      >
        <div className="divide-y divide-bull-border rounded border border-bull-border bg-bull-panel">
          {/* ─── STEP 1 ─────────────────────────────────────────── */}
          <DuelFlowStep
            n={1}
            title="your fighter"
            state={step1State}
            status={account ? `${roster.mine.length} alive in your herd` : undefined}
          >
            {!account ? (
              <p className="text-sm text-bull-text-dim">connect a wallet to see your herd.</p>
            ) : roster.isLoading ? (
              <p className="text-sm text-bull-text-dim">reading your herd off the chain…</p>
            ) : roster.unavailable ? (
              <div className="text-sm text-bull-text-dim">
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
              <p className="text-sm text-bull-text-dim">
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
                <div className="space-y-1 text-[11px] text-bull-text-faint">
                  {/* ⚠ "12 in the pit" NEXT TO A MOSTLY-BENCHED LIST READS AS A
                      BUG, and the owner read it as one: "it says 12 of yours in
                      the pit but when picking my fighters it shows only 3
                      queued, 1 fighting next and the rest benched — something
                      is up there?" Nothing was up: ticks start empty and the
                      queue is exactly what you tick. This button closes the gap
                      between the advertised herd and the default queue in one
                      press instead of twelve. */}
                  {pit.matchable !== null &&
                    roster.mine.filter(
                      (b) => pit.matchable?.has(b.id) && !ticked.includes(b.id),
                    ).length > 0 && (
                      <button
                        type="button"
                        onClick={() =>
                          setTicked((prev) => {
                            const add = roster.mine
                              .map((b) => b.id)
                              .filter((id) => pit.matchable?.has(id) && !prev.includes(id));
                            return [...prev, ...add];
                          })
                        }
                        className="rounded-full border border-bull-border px-3 py-1 font-mono text-[11px] text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold"
                      >
                        queue everyone in the pit (
                        {
                          roster.mine.filter(
                            (b) => pit.matchable?.has(b.id) && !ticked.includes(b.id),
                          ).length
                        }
                        )
                      </button>
                    )}
                  <p>
                    {alive.length > roster.mine.length
                      ? `${alive.length - roster.mine.length} more alive in the full herd. `
                      : ''}
                    tick any of yours to send them in alongside it. they fight one after another.
                    a benched bull is just an unticked one.
                  </p>
                  {/* ⚠ SAID HERE AS WELL AS IN STEP 2, because this is the list
                      where somebody picks a bull, and picking one that is out is
                      how the whole "gas limit too high" mess started. */}
                  <p>{PIT.rule}</p>
                </div>
              </>
            )}
          </DuelFlowStep>

          {/* ─── STEP 2 ─────────────────────────────────────────────
              ⚠ THE STEP THE OWNER CALLED A MESS. Read the ladder note at the
              top of this file before adding a control here. In order: what is
              about to happen, the money, ONE button, then everything else quiet
              under a divider. Nothing else goes above the button. */}
          <DuelFlowStep
            n={2}
            title="send them in"
            state={step2State}
            status={!account ? 'connect a wallet' : step2Done ? 'sorted' : undefined}
          >
            {!account ? (
              <p className="text-sm text-bull-text-dim">
                connect your wallet and this is where you back your bull.
              </p>
            ) : roster.mine.length === 0 ? (
              <p className="text-sm text-bull-text-dim">{PIT.emptyWallet}</p>
            ) : !step2Open ? (
              /* SATISFIED, SO IT FOLDS TO ONE LINE. The two facts a player
                 actually checks stay readable; they just stop being controls. */
              <div className="flex flex-wrap items-start justify-between gap-3">
                {/* ⚠ CURRENCY-AWARE, BECAUSE "0 fights allowed in bnb" IS A LIE
                    BY OMISSION. On the bnb leg the allowance has nothing to do
                    with whether the player can fight — it only decides whether
                    OTHERS can pick their bulls — so a bare zero here read as a
                    broken wallet on the one line step 2 leaves behind. The
                    bnbull leg keeps the figure, because there it is the gate. */}
                <p className="min-w-0 font-mono text-sm text-bull-text-dim">
                  <span className="text-bull-gold">{myInPitCount}</span> of yours in {PIT.short}
                  {primaryIsBnbull ? (
                    <>
                      {' '}
                      · <span className="text-bull-text">{primaryAllowance.fightsAllowed}</span>{' '}
                      fight{primaryAllowance.fightsAllowed === 1 ? '' : 's'} allowed in{' '}
                      {primaryCurrencyLabel}
                    </>
                  ) : (
                    <>
                      {' '}
                      · paying in <span className="text-bull-text">bnb</span>
                      {challengeable ? ' · challengeable while away' : ''}
                    </>
                  )}
                </p>
                <button
                  type="button"
                  onClick={() => setOpenStep2(true)}
                  className="shrink-0 py-1 font-mono text-xs text-bull-gold hover:underline"
                >
                  change
                </button>
              </div>
            ) : (
              <div className="space-y-3">
                {/* WHAT IS ABOUT TO HAPPEN, IN NAMES. "we are sending these
                    three in" reads better than a count, wherever the list is
                    short enough to read. */}
                <div className="space-y-1 font-mono text-sm">
                  {pitUnread ? (
                    <p className="text-bull-text-dim">{PIT.loading}</p>
                  ) : sendInIds.length > 0 ? (
                    <p className="break-words text-bull-text">
                      <span className="text-bull-gold">sending {sendInIds.length} in:</span>{' '}
                      {sendInIds.map(nameOf).join(', ')}
                    </p>
                  ) : (
                    <p className="text-bull-text-dim">
                      <span className="text-bull-gold">{myInPitCount}</span> of yours already in{' '}
                      {PIT.short}, nothing new to send
                    </p>
                  )}
                  {pending.length > 1 && (
                    <p className="text-[11px] text-bull-text-faint">
                      {pending.length} ticked. they fight one after another, because the contract
                      settles one signed fight per wallet at a time.
                    </p>
                  )}
                </div>

                {/* ─── THE MONEY ───────────────────────────────────
                    ⚠ ONE APPROVAL, IN THE CURRENCY YOU PICKED. This block used
                    to render TWO live approve buttons side by side, one per
                    currency, and the owner signed both before his first fight.
                    It is one now, sized by the count below, and the second
                    currency is a disclosure.

                    ⚠ WHAT AN ALLOWANCE IS ACTUALLY FOR, BECAUSE IT IS NOT
                    REDUNDANT. `Duel._takeSide` only lets raw `msg.value` cover a
                    WBNB stake when `owner_ == msg.sender`, so it covers YOUR
                    side on a fight YOU submit and nothing else. When somebody
                    else picks one of your bulls you are the PASSIVE side and
                    settlement needs a WBNB allowance or it reverts
                    `StakeNotApproved` — native bnb cannot be pulled out of your
                    wallet by another player's transaction. So this is what lets
                    your herd be challenged while you are offline. Deleting it
                    would quietly make everybody's bulls unpickable.

                    ⚠ THE COUNT IS A SELECT, NOT FIVE PILLS. Fefers uses a
                    dropdown here for the same reason: five equally loud pills
                    next to three currency pills is eight competing controls
                    above the one button that matters. */}
                <div className="space-y-3 border-t border-bull-border pt-3">
                  <div className="flex flex-wrap items-baseline gap-x-3 gap-y-2">
                    <span className="w-[5.5rem] shrink-0 font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
                      pay with
                    </span>
                    <div className="flex flex-wrap gap-2">
                      <PayTab
                        label="bnb"
                        active={effectiveAsset === 'BNB'}
                        onClick={() => setMyAsset('BNB')}
                      />
                      {/* ⚠ THE LABEL ITSELF SAYS "not yet", the same as the mint
                          panel's bnbull tab. A greyed tab with an unchanged
                          label reads as a bug in the page; one that says why
                          reads as a state of the game. */}
                      <PayTab
                        label={bnbullUnusable ? 'bnbull (not yet)' : 'bnbull'}
                        active={effectiveAsset === 'BNBULL'}
                        onClick={() => setMyAsset('BNBULL')}
                        disabled={bnbullUnusable}
                        disabledTitle={CURRENCY.bnbullPending}
                      />
                      {/* ⚠ "both" IS A MATCHMAKING PREFERENCE, NOT A SPLIT
                          PAYMENT, AND IT CANNOT BE ONE. `Duel.DuelResult`
                          carries exactly one asset per side (`assetA`/`assetB`)
                          and `_takeSide` pulls ONE asset from ONE owner, so
                          "half in each" is not expressible in the struct that
                          gets signed. It would be a contract change, not a
                          button.

                          This replaced "whatever i can pay", which was the
                          `AUTO` selector. AUTO did not just guess, it FAILED
                          SILENTLY: `run-duel`'s `resolveSide` hit a side that
                          could not pay and simply `continue`d, so the bull was
                          never matched and the player had no way to find out
                          why. Every currency that cannot be used now reports a
                          named blocker instead. */}
                      <PayTab
                        label="both"
                        active={effectiveAsset === 'BOTH'}
                        onClick={() => setMyAsset('BOTH')}
                      />
                    </div>
                  </div>

                  {/* Said out loud, not just as a tooltip on a greyed tab: a
                      title attribute is invisible on a phone, which is where
                      most of this page is read. */}
                  {bnbullUnusable && (
                    <p className="text-[11px] text-bull-text-faint">{CURRENCY.bnbullPending}</p>
                  )}

                  <div className="flex flex-wrap items-baseline gap-x-3 gap-y-2">
                    <label
                      htmlFor={fightsSelectId}
                      className="w-[5.5rem] shrink-0 font-mono text-[11px] uppercase tracking-wide text-bull-text-faint"
                    >
                      fights
                    </label>
                    {/* ⚠ NO `text-sm` ON THIS SELECT. `.bull-input` sets 16px on
                        purpose: anything smaller and iOS Safari zooms the whole
                        page the moment it is focused. */}
                    <select
                      id={fightsSelectId}
                      value={String(fightsWanted)}
                      onChange={(e) => setFightsWanted(Number(e.target.value))}
                      className="bull-input w-auto min-w-[8rem]"
                    >
                      {APPROVE_FIGHT_OPTIONS.map((n) => (
                        <option key={n} value={n}>
                          {n} fight{n === 1 ? '' : 's'}
                        </option>
                      ))}
                    </select>
                    <span className="min-w-0 break-words font-mono text-sm">
                      {/* Only quote a number somebody is actually about to sign
                          for. An allowance that already reaches the count reads
                          "already covered", not a figure nobody is being asked
                          for.

                          ⚠ AND ON THE BNB LEG NOBODY IS BEING ASKED FOR ONE AT
                          ALL, so no token figure belongs here. It used to read
                          "= 0.169560 wbnb" next to the fight count, which is the
                          single most direct way this page told a bnb player that
                          wbnb was what a run of fights costs. It is not: it is
                          what the OPTIONAL challenge setup would approve, and
                          that number belongs next to that control, which is
                          where `AllowanceRow` puts it. */}
                      {!primaryIsBnbull ? null : primaryAllowance.covers ? (
                        <span className="text-bull-gold">already covered</span>
                      ) : primaryAllowance.approvalTotal !== undefined ? (
                        <>
                          ={' '}
                          <span className="text-bull-gold">
                            {formatToken(primaryAllowance.approvalTotal, primaryDecimals)}{' '}
                            {primaryTokenLabel}
                          </span>
                        </>
                      ) : (
                        '…'
                      )}
                    </span>
                  </div>

                  <p className="text-[11px] text-bull-text-faint">
                    {primaryIsBnbull
                      ? 'one signature, sized for that many. the chain remembers it, so every fight after it is a single confirm until the run is used up. it is one shared pool and not a budget per bull, so the first fight by any of them draws on the lot.'
                      : 'how many you are up for in one sitting. it sizes the optional setup below, and a top-up if the price moves mid-run. paying for your own fights needs no signature at all.'}
                  </p>
                </div>

                {/* ═══ THE ONE BUTTON ═══════════════════════════════
                    The first outstanding thing, and nothing else. When there is
                    nothing outstanding there is NO button here, because a
                    full-width primary reading "nothing waiting" is the loudest
                    thing on the step and the least use. */}
                {pitUnread ? (
                  /* ⚠ NO BUTTON OFF AN UNREAD PIT. "nothing to sign here" would
                     be a claim about membership we have not read yet, and it is
                     the one that sends somebody to the fight button with a bull
                     the contract will refuse. */
                  <p className="font-mono text-sm text-bull-text-dim">{PIT.loading}</p>
                ) : sendInIds.length > 0 ? (
                  <PitEntryButton
                    ids={sendInIds}
                    label={`send ${sendInIds.length} into ${PIT.short}`}
                    note={PIT.enterInstant}
                    onChanged={pit.refetch}
                  />
                ) : approvalBlocksMyFight ? (
                  /* ⚠ BNBULL ONLY. This is the one currency where an empty
                     allowance genuinely stops the player fighting, because
                     bnbull can only ever move by `transferFrom`. The bnb leg
                     never reaches this branch — its own side comes out of
                     `msg.value` — and putting it here is exactly what taught six
                     wallets that wbnb was the price of entry. */
                  <div>
                    <button
                      type="button"
                      // ⚠ `whitespace-normal` OVERRIDES `.bull-btn`'s nowrap.
                      // This label carries a count AND an amount ("approve 50
                      // fights · 12,500,000 bnbull"), which is well past what a
                      // 390px phone fits on one line.
                      className="bull-btn w-full whitespace-normal text-center"
                      disabled={
                        primaryAllowance.isApproving ||
                        primaryAllowance.approvalTotal === undefined
                      }
                      onClick={async () => {
                        await primaryAllowance.approve();
                        primaryAllowance.refetch();
                      }}
                    >
                      {primaryAllowance.isApproving
                        ? 'approving…'
                        : `approve ${fightsWanted} fight${fightsWanted === 1 ? '' : 's'} · ${
                            primaryAllowance.approvalTotal !== undefined
                              ? formatToken(primaryAllowance.approvalTotal, primaryDecimals)
                              : '—'
                          } ${primaryTokenLabel}`}
                    </button>
                    <p className="mt-1.5 text-[11px] text-bull-text-faint">
                      bnbull can only ever move by allowance, so this covers your own side and
                      lets somebody else pick your bulls.
                    </p>
                  </div>
                ) : (
                  /* ⚠ THE BNB PLAYER LANDS HERE WITH NOTHING TO SIGN, AND THAT IS
                     THE CORRECT ANSWER — not a gap to fill with a wrap button. */
                  <div className="font-mono text-sm text-bull-text-dim">
                    <p>nothing to sign here. step 3 is your move.</p>
                    {!primaryIsBnbull && (
                      <p className="mt-1.5 font-sans text-[11px] text-bull-text-faint">
                        {CURRENCY.fightNeedsNothing}
                      </p>
                    )}
                  </div>
                )}

                {/* ═══ QUIET, UNDER A DIVIDER ═══════════════════════
                    Live approvals, the way out of them, and the reference
                    material. Kept next to the control that creates them and
                    never louder than the button above. */}
                <div className="space-y-3 border-t border-bull-border pt-3">
                  {primaryIsBnbull ? (
                    <AllowanceRow
                      label="bnbull"
                      tokenLabel="bnbull"
                      allowance={bnbullAllowance}
                      decimals={bnbullDecimals}
                      fights={fightsWanted}
                      packSize={pending.length}
                      nativeSelfPay={false}
                      hideApprove={approvalBlocksMyFight}
                      unavailable={bnbullUnusable}
                      unavailableNote={CURRENCY.bnbullPending}
                    />
                  ) : (
                    /* ═══ OPT-IN, AND FOLDED BY DEFAULT ═══════════════
                       ⚠ THE WHOLE BNB SETUP LIVES BEHIND THIS DISCLOSURE, and
                       that placement IS the fix. It was a gold button in the
                       primary slot yesterday, which read as the price of entry
                       and got six wallets to sign for something none of them
                       needed to fight. What it actually buys is one thing —
                       your bulls being pickable while you are not here — so it
                       is offered as that, by name, and nothing above it depends
                       on it. Deliberately NOT deleted: async challenge is the
                       point of the bull pit, and the owner said keep it. */
                    <details>
                      <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
                        let others fight your bulls while you are away
                        {challengeable ? ' · on' : ' · off'}
                      </summary>
                      <p className="mt-2 text-[11px] text-bull-text-faint">
                        {CURRENCY.challengeSetup}
                      </p>
                      <p className="mt-1 text-[11px] text-bull-text-faint">
                        you never need this to start fights yourself.
                      </p>
                      <div className="mt-2">
                        <AllowanceRow
                          label="bnb"
                          tokenLabel="wbnb"
                          allowance={bnbAllowance}
                          decimals={wbnbDecimals}
                          fights={fightsWanted}
                          packSize={pending.length}
                          nativeSelfPay
                          wrappable
                          unavailableNote="no bnb fight cost is registered on the duel contract yet."
                        />
                      </div>
                    </details>
                  )}

                  <details>
                    <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
                      also let people challenge you in {primaryIsBnbull ? 'bnb' : 'bnbull'}
                    </summary>
                    <p className="mt-2 text-[11px] text-bull-text-faint">
                      you do not need this to fight. it only widens which currency somebody else
                      can pick your bulls in, and it is a second signature, so it is down here
                      rather than in front of you.
                    </p>
                    <div className="mt-2">
                      {primaryIsBnbull ? (
                        <AllowanceRow
                          label="bnb"
                          tokenLabel="wbnb"
                          allowance={bnbAllowance}
                          decimals={wbnbDecimals}
                          fights={fightsWanted}
                          packSize={pending.length}
                          nativeSelfPay
                          wrappable
                          unavailableNote="no bnb fight cost is registered on the duel contract yet."
                        />
                      ) : (
                        <AllowanceRow
                          label="bnbull"
                          tokenLabel="bnbull"
                          allowance={bnbullAllowance}
                          decimals={bnbullDecimals}
                          fights={fightsWanted}
                          packSize={pending.length}
                          nativeSelfPay={false}
                          // ⚠ AN APPROVE WOULD SUCCEED AND STILL BE USELESS.
                          // `approve` is not a transfer, so the token's lock
                          // does not stop it — the wallet signs, the allowance
                          // lands, and the fight still reverts later on
                          // `transferFrom`. So the row has to be shut off here
                          // rather than left to fail at settlement.
                          unavailable={bnbullUnusable}
                          unavailableNote={CURRENCY.bnbullPending}
                        />
                      )}
                    </div>
                  </details>

                  <details>
                    <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
                      what a fight costs, per currency
                    </summary>
                    <p className="mt-2 text-[11px] text-bull-text-faint">
                      {lossesToDie !== undefined ? Number(lossesToDie) : 'five'} losses in a row,
                      no win and no tie in between, and a bull is on the truck to market. both
                      sides put up the same amount, in whichever currency each of them picks.
                      {usdFightPrice !== undefined && (usdFightPrice as bigint) > 0n && (
                        <>
                          {' '}
                          the sticker is{' '}
                          <span className="text-bull-text-dim">
                            {formatUsd1e18(usdFightPrice as bigint)}
                          </span>{' '}
                          a side.
                        </>
                      )}
                    </p>
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
                            // Three reads per asset, in order, from the flatMap
                            // above.
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
                        {quoteAge !== undefined ? `quoted ${quoteAge}s ago` : 'quoting…'} ·
                        refreshes every {QUOTE_REFRESH_MS / 1000}s
                      </p>
                    )}
                  </details>
                </div>
              </div>
            )}
          </DuelFlowStep>

          {/* ─── STEP 3 ─────────────────────────────────────────── */}
          <DuelFlowStep
            n={3}
            title="fight"
            state={step3State}
            status={!fightReady ? (step1Done ? 'step 2 first' : 'step 1 first') : undefined}
          >
            {challenger && opponent ? (
              <>
                <div className="grid gap-3 sm:grid-cols-[1fr_auto_1fr] sm:items-center">
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
                {/* The reroll is a QUIET pill next to the matchup facts, not a
                    second primary. Fefers hangs the same control off its
                    matchup line for the same reason: one loud button per step. */}
                <div className="flex flex-wrap items-center gap-3">
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
                    {pit.matchable ? ` · ${pit.matchable.size} waiting in ${PIT.short}` : ''}
                  </span>
                </div>
              </>
            ) : (
              <p className="text-sm text-bull-text-dim">{blockedReason ?? 'no match yet.'}</p>
            )}

            <FightAction
              duelAddress={duelAddress}
              myTokenId={currentId}
              oppTokenId={opponent?.id ?? null}
              blockedReason={blockedReason}
              // ⚠ THE EFFECTIVE ONE, NEVER THE RAW PICK. A held `BNBULL` from
              // before the lock read landed must not reach a signature.
              myAsset={effectiveAsset}
              // ⚠ THE SAME COUNT THE PLAYER PICKED, not the queue length. If the
              // fight in front of them ever does need a top-up (the oracle moved
              // between the standing approval and the quote), it is sized for the
              // whole run so it is asked ONCE, not once per fight.
              approveFights={fightsWanted}
              onSettled={onSettled}
              // A fight on screen folds everything below it away. See
              // `handleFightVisible`.
              onFightVisible={handleFightVisible}
            />

            {/* The rules that are true but are not a control. Folded, because
                every line of prose next to the fight button is a line between
                the player and the fight. */}
            <details>
              <summary className="cursor-pointer font-mono text-[11px] uppercase tracking-wide text-bull-text-faint">
                how the fight is decided
              </summary>
              <p className="mt-2 text-[11px] text-bull-text-faint">
                the fight is simulated off chain from a random seed and the result is signed. the
                contract verifies the signature, it never re-runs the fight. the seed is public,
                so anyone can re-run it and catch a lying signer.
              </p>
              <p className="mt-2 text-[11px] text-bull-text-faint">
                a wallet cannot fight itself, and each wallet carries one signed fight at a time.
                both are enforced on chain at settlement, not just checked here.
              </p>
            </details>

            {queue.length > 1 && (
              <div className="border-t border-bull-border pt-3">
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
                  one at a time, because the contract allows one signed fight per wallet. settle
                  the one on screen and the next steps up.
                </p>
              </div>
            )}
          </DuelFlowStep>
        </div>
      </DuelSection>

      {/* ═══════════════════════════════════════════════════════════
          SECTION 2 · YOUR HERD IN THE PIT — the way back out.
          ⚠ THIS USED TO LIVE INSIDE STEP 2, and that is the single biggest
          reason the step read as a mess: a per-bull management table with two
          bulk buttons and a button per row, sitting between the currency tabs
          and the approve. Fefers ranks the same panel the same way this now
          does — its own section, under the flow, folded by default, because it
          is the only control on the page that does not need a fight set up to
          be useful. Hidden entirely for a wallet with nothing in it.
          ═══════════════════════════════════════════════════════════ */}
      <DuelSection
        id="your-herd"
        title={`your herd in ${PIT.label}`}
        open={sections['your-herd']}
        onOpenChange={(v) => setSection('your-herd', v)}
        hidden={!account || roster.mine.length === 0}
      >
        <div className="rounded border border-bull-border bg-bull-panel p-4">
          <PitPanel bulls={roster.mine} onChanged={pit.refetch} />
        </div>
      </DuelSection>

      {/* ═══════════════════════════════════════════════════════════
          SECTION 3 · THE WHOLE ROSTER — everybody waiting, at the bottom.
          ⚠ OWNER CALL, 2026-08-07: *"the roster of all of them waiting should be
          at bottom."* It was mid-page, buried inside `PitPanel` inside step 2.
          It is the browse-the-field surface, not a step in the fight.
          ⚠ NO WALLET GATE. A stranger landing on /duel and seeing the field
          queued up is the shopfront, and fefers does not gate its lineup on a
          connection either.
          ═══════════════════════════════════════════════════════════ */}
      <DuelSection
        id="pit-roster"
        title={`who is in ${PIT.short}`}
        open={sections['pit-roster']}
        onOpenChange={(v) => setSection('pit-roster', v)}
      >
        <div className="rounded border border-bull-border bg-bull-panel p-4">
          <PitRoster />
        </div>
      </DuelSection>
    </div>
  );
}

/**
 * One currency's standing allowance: how many fights the WHOLE PACK is still
 * allowed in it, ONE approve control sized by the count above, and the revoke.
 *
 * ⚠ THE APPROVE BUTTON DISAPPEARS ONCE THE CHAIN COVERS THE RUN. That is the
 * owner's actual request ("sign ONCE and onchain will remember"), and a button
 * that stayed up would be inviting a second signature for permission that is
 * already recorded. `covers` is computed off the live allowance read, and an
 * unread allowance is deliberately NOT treated as covered.
 *
 * ⚠ AND IT IS QUIET, NEVER THE LOUDEST THING ON THE STEP. `hideApprove` is set
 * when step 2's own primary button is already the first approval in this
 * currency — two buttons asking for the same signature, one gold and one
 * bordered, is exactly the clutter the restructure exists to remove. What is
 * left here is a TOP-UP: an allowance that already covers a fight but not the
 * whole run, which is optional and is styled like it.
 *
 * ⚠ THE COUNT IS LIMITED BY BALANCE AS WELL AS BY APPROVAL, because
 * `Duel._takeSide` checks both before it will pull a passive stake
 * (`StakeUnaffordable` then `StakeNotApproved`). A wallet that approved fifty
 * fights but holds two fights' worth can be drawn into two, so "50 approved"
 * would be exactly the kind of confident wrong number this page exists to
 * avoid. When the balance is the binding constraint it says so, because
 * approving more would change nothing.
 *
 * ⚠ `nativeSelfPay` IS NOT COSMETIC. On the bnb leg a short allowance does NOT
 * stop you fighting: your own side rides in as `msg.value`. It stops OTHER
 * people picking your bulls. On the bnbull leg it stops both. Saying "N of them
 * cannot fight" on the bnb row would be false, and false in the direction that
 * makes somebody sign a transaction they did not need.
 */
function AllowanceRow({
  label,
  tokenLabel,
  allowance,
  decimals,
  fights,
  packSize,
  nativeSelfPay,
  hideApprove = false,
  unavailable = false,
  unavailableNote,
  wrappable = false,
}: {
  label: string;
  tokenLabel: string;
  allowance: FightAllowance;
  decimals: number | undefined;
  /** The one page-wide "how many fights are you up for" count. */
  fights: number;
  /** Bulls currently ticked and still to fight. */
  packSize: number;
  /** Can this currency cover YOUR OWN side with raw bnb and no allowance? */
  nativeSelfPay: boolean;
  /** Step 2's primary button is already asking for this exact signature. */
  hideApprove?: boolean;
  /**
   * The leg cannot settle at all right now, whatever the allowance says.
   *
   * ⚠ NOT THE SAME AS `!configured`, and it has to be its own flag. A cost IS
   * registered for bnbull and the allowance reads fine, so `configured` is
   * true — but $BNBULL is transfer-locked until four.meme's curve fills, and
   * `approve` is not a transfer, so the wallet would happily sign an allowance
   * that can only ever revert at settlement. Only pass a DEFINITIVE read.
   */
  unavailable?: boolean;
  unavailableNote: string;
  /**
   * This currency is WBNB, so a wallet holding native bnb can top the balance
   * up here instead of leaving for a DEX. Only the bnb row passes it.
   */
  wrappable?: boolean;
}) {
  const {
    configured,
    fightsAllowed,
    limitedByBalance,
    approvalTotal,
    isApproving,
    covers,
    hasAny,
    balance,
    perFight,
    token,
  } = allowance;

  const {
    nativeBalance,
    cannotCoverOne,
    shortForRun,
    amount: wrapAmount,
    canWrap,
    fallsShort: wrapWouldFallShort,
    wrap,
    isWrapping,
    refetch: refetchNative,
  } = useWrapBnb(wrappable ? token : undefined, { balance, perFight, fights });

  if (!configured || unavailable) {
    return (
      <div className="rounded border border-bull-border bg-bull-bg p-3">
        <p className="font-mono text-xs text-bull-text-dim">{label}</p>
        <p className="mt-2 text-[11px] text-bull-text-faint">{unavailableNote}</p>
      </div>
    );
  }

  // ⚠ THE WARNING THE OWNER ASKED FOR BY NAME: "10 bulls in, 1 fight
  // approved" means nine of them cannot be drawn into a fight, and nothing
  // else on the page would ever tell you that.
  const short = packSize > 0 && fightsAllowed < packSize;

  return (
    <div
      className={`rounded border bg-bull-bg p-3 ${
        covers ? 'border-bull-gold/40' : 'border-bull-border'
      }`}
    >
      <p className="flex flex-wrap items-center justify-between gap-2 font-mono text-xs">
        {fightsAllowed > 0 ? (
          <span className="text-bull-gold">
            ✓ {label}: {fightsAllowed} fight{fightsAllowed === 1 ? '' : 's'} allowed
          </span>
        ) : hasAny && cannotCoverOne ? (
          // ⚠ "NOTHING APPROVED YET" IS A LIE IN THIS EXACT STATE, AND IT IS THE
          // STATE A REAL WALLET GOT STUCK IN. `0xbafb…e331` had approved 0.165514
          // wbnb - about fifty fights - and held none of it, so `fightsAllowed`
          // floored to zero and this line told them to go and approve the thing
          // they had already approved. The approval is not the problem; the empty
          // balance is, and they are different jobs with different buttons.
          //
          // ⚠ RED ONLY WHERE SOMETHING IS ACTUALLY BROKEN. On the bnb leg this
          // state costs the player nothing they were trying to do — they can
          // still fight all day — so alarm colours here would be crying wolf
          // about an optional feature that is simply switched off.
          <span className={nativeSelfPay ? 'text-bull-text-faint' : 'text-bull-red'}>
            {label}: approved, but no wbnb behind it
          </span>
        ) : (
          // ⚠ THIS IS AN ALLOWANCE, NOT A BAN. It read "no fights allowed
          // yet", which sounds like the game is shut - and on the bnb leg it is
          // flatly wrong, because your own side rides in as `msg.value` with no
          // allowance at all (see `nativeSelfPay` above). All a zero here means
          // is that nothing is approved in this currency yet.
          <span className="text-bull-text-faint">{label}: nothing approved yet</span>
        )}
        {hasAny && (
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

      {/* ═══ WRAP ═══════════════════════════════════════════════════════
          ⚠ THIS COMES BEFORE THE APPROVE, AND THAT ORDER IS THE WHOLE POINT.
          An approval over an empty balance is a signature that buys nothing:
          `Duel._takeSide` checks `balanceOf` as well as `allowance`, so a
          wallet with fifty fights approved and no wbnb can be drawn into
          exactly none. Offering "approve" first is what let a live wallet sign
          permission it could never use, and then leave thinking it was done.

          ⚠ THIS IS THE ONLY PLACE THE WRAP IS OFFERED NOW. It briefly also had
          a gold twin in step 2's primary slot; that twin taught every bnb
          player that wrapping was how you start fighting, which is false, and
          it is gone. `hideWrap` went with it — there is no longer a second
          control for this row to defer to. */}
      {wrappable && shortForRun && (
        <div
          className={`mt-2 rounded border p-2.5 ${
            cannotCoverOne && !nativeSelfPay
              ? 'border-bull-red/50 bg-bull-red/5'
              : 'border-bull-border'
          }`}
        >
          <p className="text-[11px] text-bull-text-dim">
            {cannotCoverOne ? (
              <>
                {/* ⚠ "no wbnb to FIGHT with" WAS FLATLY WRONG ON THE BNB LEG and
                    it is the sentence that sold the whole misunderstanding: this
                    wallet can fight perfectly well, it just cannot be picked by
                    anyone else yet. Say the thing it actually blocks. */}
                <strong className={nativeSelfPay ? 'text-bull-text' : 'text-bull-red'}>
                  {nativeSelfPay ? 'not set up yet.' : 'no wbnb to fight with.'}
                </strong>{' '}
                {nativeSelfPay ? 'being picked by someone else needs ' : 'one fight needs '}
                {perFight !== undefined ? formatToken(perFight, decimals) : '—'} wbnb a fight and
                this wallet holds {balance !== undefined ? formatToken(balance, decimals) : '—'}.
              </>
            ) : (
              <>
                enough wbnb for {fightsAllowed} of your {fights} fight
                {fights === 1 ? '' : 's'}. wrap a bit more to cover the run.
              </>
            )}
          </p>
          <button
            type="button"
            disabled={!canWrap || isWrapping}
            onClick={async () => {
              await wrap(wrapAmount);
              refetchNative();
              allowance.refetch();
            }}
            className="mt-2 w-full whitespace-normal rounded-full border border-bull-gold px-3 py-1.5 text-center text-xs font-medium text-bull-gold transition hover:bg-bull-gold/10 disabled:opacity-40"
          >
            {isWrapping
              ? 'wrapping…'
              : canWrap
                ? `wrap ${formatToken(wrapAmount, NATIVE_BNB_DECIMALS)} bnb → wbnb`
                : // ⚠ AN UNREAD BALANCE IS NOT AN EMPTY ONE. Saying "not enough
                  // bnb" off a read that has not answered is the same lie the
                  // headline above was just fixed for.
                  nativeBalance === undefined
                  ? 'checking your bnb…'
                  : 'not enough bnb to wrap'}
          </button>
          <p className="mt-1.5 text-[11px] text-bull-text-faint">
            {canWrap || nativeBalance === undefined
              ? 'wbnb is bnb, one for one, and unwraps the same way. somebody else picking your bull pays out of an allowance, and only wrapped bnb can be pulled like that, so this is what makes your bulls challengeable while you are offline.'
              : 'this wallet needs a little more bnb first. some is always left behind for gas, because the approve and the fights after it still have to be paid for.'}
          </p>
          {wrapWouldFallShort && canWrap && (
            <p className="mt-1 text-[11px] text-bull-text-faint">
              this wraps what the wallet can spare, which is short of the full run. top up the
              bnb and wrap again to cover the rest.
            </p>
          )}
        </div>
      )}

      {short &&
        (nativeSelfPay ? (
          <p className="mt-1.5 text-[11px] text-bull-text-faint">
            {packSize} bull{packSize === 1 ? '' : 's'} in, {fightsAllowed} covered by this
            approval. you can still start fights yourself in bnb, the amount rides with the
            transaction. this is what lets somebody else pick the other{' '}
            {packSize - fightsAllowed}.
          </p>
        ) : (
          <p className="mt-1.5 text-[11px] text-bull-red">
            {packSize} bull{packSize === 1 ? '' : 's'} sent in but only {fightsAllowed} fight
            {fightsAllowed === 1 ? '' : 's'} allowed in {label}, so {packSize - fightsAllowed} of
            them cannot fight in it until you top this up.
          </p>
        ))}

      {covers ? (
        <p className="mt-2 text-[11px] text-bull-text-faint">
          signed and remembered by the chain. nothing more to approve in {label} until this run
          is spent.
        </p>
      ) : hideApprove ? (
        <p className="mt-2 text-[11px] text-bull-text-faint">
          the button above signs this one.
        </p>
      ) : (
        <button
          type="button"
          onClick={async () => {
            await allowance.approve();
            allowance.refetch();
          }}
          disabled={isApproving || approvalTotal === undefined}
          className="mt-2 rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
        >
          {isApproving
            ? 'approving…'
            : `${fightsAllowed > 0 ? 'top up to' : 'approve'} ${fights} fight${
                fights === 1 ? '' : 's'
              } · ${
                approvalTotal !== undefined ? formatToken(approvalTotal, decimals) : '—'
              } ${tokenLabel}`}
        </button>
      )}

      <p className="mt-1.5 text-[11px] text-bull-text-faint">
        {nativeSelfPay
          ? 'paying for your own fight in bnb never needs this: the amount rides with the transaction and the contract wraps what is owed and refunds the rest. only the wallet sending a transaction can put raw bnb in with it, so this is the bit that lets anyone else pick your bulls.'
          : 'this covers your own side and lets somebody else pick your bulls, because bnbull can only ever move by allowance.'}
      </p>
      <p className="mt-1 text-[11px] text-bull-text-faint">
        revoking sets it to zero for the whole wallet, so it pulls every bull you have sent in
        out of {label} at once.
      </p>
    </div>
  );
}


/*
 * ⚠ `StepHeading` LIVED HERE AND IS GONE ON PURPOSE. It was a bare title row,
 * so every step had to hand-roll its own status text, its own dimming and its
 * own layout — which is how step 3 ended up the only dimmed step on the page.
 * `DuelFlowStep` is fefers' version of the same thing and owns all four states
 * (`todo` / `active` / `done` / `waiting`) in one place.
 */

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
                  {/* ⚠ NOT BARE "benched" — that read as a state the game
                      imposed. It is simply an unticked box, and the label
                      says the action that changes it. */}
                  {isNext
                    ? 'fighting next'
                    : isSettled
                      ? 'fought'
                      : isTicked
                        ? 'queued'
                        : 'benched · tick to queue'}
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
