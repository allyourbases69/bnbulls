'use client';

import { useState } from 'react';
import { formatUnits, parseUnits } from 'viem';
import { CURRENCY, READY } from '@/lib/brand';
import { BnbAmount, bnbLabel } from '@/components/duel/BnbAmount';
import type { FightBalance } from '@/lib/hooks/useFightBalance';

/** The default we offer for the passive ceiling, in FIGHTS. Small on purpose:
 *  it is the blast radius of a leaked signer key, and topping it up later is
 *  one cheap transaction while getting it back is not possible at all. */
const SUGGESTED_PASSIVE_FIGHTS = 5;

/** Priced off the LIVE per-fight cost, never a constant. See the note on the
 *  preset row below for why a hardcoded bnb ladder would be a bug. */
const TOP_UP_FIGHTS = [1, 5, 10, 25, 50] as const;
const BUDGET_FIGHTS = [1, 5, 10, 25] as const;

/**
 * THE FIGHT BALANCE CONTROL — the native-BNB replacement for `AllowanceRow`.
 *
 * ⚠ WHAT THIS IS FOR, IN ONE LINE: being challengeable while you are offline.
 * It is NOT the price of entry, and the layout has to keep saying so. The
 * previous shape of this idea — a gold "approve" button in the primary slot —
 * read as a prerequisite and got six real wallets on mainnet to sign for
 * permission none of them needed to start a fight. Starting fights takes
 * nothing set up, before or after this migration. Anything in here that begins
 * to look mandatory is a regression.
 *
 * ⚠ THE WITHDRAW IS NOT CONDITIONAL ON ANYTHING. `DuelNative.withdraw` sits
 * outside `whenNotPaused` on purpose — "a pause is for stopping fights, not for
 * trapping player money" — so this component must never gate taking money out
 * on the pit, the picked count, fight-readiness, or a paused game. If there is
 * a balance, the way out is on screen.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠⚠ EVERY BUTTON IN HERE CARRIES THE AMOUNT IT IS ABOUT TO SPEND.
 * ═══════════════════════════════════════════════════════════════════════
 * Owner, 2026-08-10, verbatim: *"cant see anywhere there easy it quotes HOW MUCH
 * bnb will be deposited."* He is right, and the reason it was invisible is worth
 * keeping: the panel had a bare text box and a button labelled "top up", so the
 * only place the figure ever appeared was the wallet confirmation — after the
 * decision, in wei-precision, next to a gas estimate. A player either overshot
 * or walked away.
 *
 * The rule now: NO CONTROL THAT MOVES BNB MAY BE LABELLED WITHOUT ITS FIGURE.
 * `bnbLabel` builds every one of them, so a button cannot be added that forgets,
 * and it returns a dash rather than a zero when the read has not landed.
 *
 * ⚠ AND THE EXIT IS STATED BEFORE THE ENTRY, NOT AFTER IT. "can i get it back
 * out" is the question a player has BEFORE depositing. `withdraw` is gated on
 * nothing at all, so the honest place for that sentence is above the box you
 * type an amount into. It used to sit under the controls, three blocks down,
 * which is fine print by another name.
 */
export function FightBalanceRow({
  balance,
  decimals,
  fights,
  usdPerBnb,
}: {
  balance: FightBalance;
  /** BNB is 18dp; passed rather than assumed, same as `AllowanceRow`. */
  decimals: number | undefined;
  /** The one page-wide "how many fights are you up for" count. */
  fights: number;
  /** Live `bnbUsdPrice()`. `undefined` renders no dollars anywhere. */
  usdPerBnb: bigint | undefined;
}) {
  const [topUp, setTopUp] = useState('');
  const [takeOut, setTakeOut] = useState('');
  const [cap, setCap] = useState('');
  const dp = decimals ?? 18;

  /** ⚠ Parse defensively. A stray character must not throw inside a click
   *  handler and take the panel down with it — it just means "no amount yet". */
  const parse = (raw: string): bigint | null => {
    const t = raw.trim();
    if (!t) return null;
    try {
      const v = parseUnits(t, dp);
      return v > 0n ? v : null;
    } catch {
      return null;
    }
  };

  const topUpWei = parse(topUp);
  const takeOutWei = parse(takeOut);
  const capWei = parse(cap);

  /** N fights' worth, priced off the live cost. `undefined` while unread, which
   *  is what keeps a preset from ever offering "10 fights · 0.0000 bnb". */
  const forFights = (n: number): bigint | undefined =>
    balance.perFight === undefined || balance.perFight === 0n
      ? undefined
      : balance.perFight * BigInt(n);
  const suggestedCap = forFights(SUGGESTED_PASSIVE_FIGHTS);
  const overWithdraw =
    takeOutWei !== null && balance.credit !== undefined && takeOutWei > balance.credit;
  const priced = balance.perFight !== undefined && balance.perFight > 0n;

  /** How many fights an arbitrary typed amount buys, for the line under the
   *  primary button. Integer division: a part-fight buys no fights. */
  const fightsIn = (wei: bigint | null): number | undefined =>
    wei === null || !priced ? undefined : Number(wei / balance.perFight!);

  if (!balance.configured) {
    return (
      <p className="text-[11px] text-bull-text-faint">
        no bnb fight cost is registered on the duel contract yet.
      </p>
    );
  }

  const presetCls = (active: boolean) =>
    `rounded-full border px-2.5 py-1 font-mono text-[11px] transition ${
      active
        ? 'border-bull-gold bg-bull-gold/10 text-bull-gold'
        : 'border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-gold'
    }`;

  return (
    <div className="space-y-4 text-[11px]">
      {/* ══ WHAT IS IN THERE NOW ══════════════════════════════════════ */}
      <div className="rounded border border-bull-border bg-bull-bg p-3">
        <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <span className="font-mono uppercase tracking-wide text-bull-text-faint">
            fight balance
          </span>
          <BnbAmount
            wei={balance.credit}
            decimals={decimals}
            usdPerBnb={usdPerBnb}
            emphasis={balance.hasCredit}
            className="text-sm"
          />
        </div>
        {/* ⚠ Only claim a fight count off a read that LANDED. `fightsCovered`
            is already 0 when unread, so it is gated on the balance itself. */}
        {balance.credit !== undefined && (
          <p className="mt-1 text-bull-text-faint">
            covers {balance.fightsCovered} away fight
            {balance.fightsCovered === 1 ? '' : 's'} at today&apos;s price.
          </p>
        )}

        {balance.credit !== undefined && balance.cannotCoverOne && (
          <p className="mt-1 text-bull-text-faint">
            not enough in here for a fight, so nobody can pick your bulls while you are away. you
            can still start fights yourself.
          </p>
        )}
        {balance.credit !== undefined && !balance.cannotCoverOne && balance.shortForRun && (
          <p className="mt-1 text-bull-text-faint">
            enough for {balance.fightsCovered} of your {fights}. top up to cover the run.
          </p>
        )}
      </div>

      {/* ══ PUT MONEY IN ══════════════════════════════════════════════
          ⚠ THE EXIT GOES FIRST. See the file header: this is the question a
          player has before they type an amount, and `withdraw` is gated on
          nothing, so answering it here costs nothing and buys the decision. */}
      <div className="space-y-2">
        {/* ⚠ THE THREE BLOCKS ARE LABELLED THE SAME WAY ON PURPOSE — put money
            in, away budget, take it back out. This one had no heading at all,
            which left the panel reading as one long column of controls with two
            headings floating in it, and on a phone that is how somebody sets a
            budget when they meant to deposit. */}
        <span className="block font-mono uppercase tracking-wide text-bull-text-faint">
          put money in
        </span>
        <p className="text-bull-text-dim">{CURRENCY.withdrawFirst}</p>

        {/* ── how many fights, and EXACTLY what that costs ────────────────
            ⚠ THE PRICE IS SHOWN, NOT IMPLIED. A player putting money into a
            contract must see the exact BNB before they click, for the number of
            fights they actually want. A bare "top up" box asks somebody to fund
            custody against a figure they have to work out themselves, which is
            precisely when people either overshoot or walk away.

            ⚠ PRICED OFF THE LIVE `perFight`, NEVER A CONSTANT. The BNB stake is
            a USD sticker converted through chainlink, so it moves every block —
            a hardcoded ladder would drift and quietly under-fund. When the read
            has not landed the row is not rendered at all rather than showing a
            zero, because "1 fight · 0.0000 bnb" is a lie that costs money. */}
        {priced && (
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="text-bull-text-faint">cover</span>
            {TOP_UP_FIGHTS.map((n) => {
              const wei = forFights(n)!;
              return (
                <button
                  key={n}
                  type="button"
                  onClick={() => setTopUp(formatUnits(wei, dp))}
                  className={presetCls(topUpWei === wei)}
                >
                  {n} {n === 1 ? 'fight' : 'fights'}
                </button>
              );
            })}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <input
            type="text"
            inputMode="decimal"
            value={topUp}
            onChange={(e) => setTopUp(e.target.value)}
            placeholder={balance.suggested > 0n ? formatUnits(balance.suggested, dp) : '0.0'}
            aria-label="bnb to add to your fight balance"
            /* ⚠ THE PLACEHOLDER IS DIMMED EXPLICITLY. These boxes are
               pre-filled with a SUGGESTION as placeholder text, and at the
               browser default they render close enough to a real value that a
               player reads "0.01664" as an amount they have already entered —
               then presses a button that says it is waiting for one. Two
               different meanings must not share a colour on a control that
               moves money. */
            className="w-32 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-[11px] text-bull-text placeholder:text-bull-text-faint"
          />
          <span className="text-bull-text-faint">bnb</span>
          {balance.suggested > 0n && (
            <button
              type="button"
              onClick={() => setTopUp(formatUnits(balance.suggested, dp))}
              className="text-bull-text-faint underline hover:text-bull-gold"
            >
              {/* Deliberately the SUGGESTION, never the whole wallet: the hook
                  holds a gas reserve back, because depositing is never the last
                  transaction — the fights still have to be paid for. */}
              enough for {fights}
            </button>
          )}
        </div>

        {/* ⚠⚠ THE BUTTON IS THE QUOTE. Nothing else on this panel is allowed to
            be the only place the amount appears, because the button is the last
            thing read before a wallet opens. Disabled with no amount, and it
            says what it is waiting for rather than sitting there dead. */}
        <button
          type="button"
          onClick={() => topUpWei && void balance.deposit(topUpWei)}
          disabled={!topUpWei || balance.isBusy}
          className="w-full whitespace-normal rounded-full border-2 border-bull-gold px-3 py-2 text-center font-mono text-xs font-medium text-bull-gold transition hover:bg-bull-gold/10 disabled:cursor-not-allowed disabled:opacity-40"
        >
          {balance.isBusy
            ? 'working…'
            : topUpWei
              ? `put in ${bnbLabel(topUpWei, decimals, usdPerBnb)}`
              : 'pick an amount above'}
        </button>
        {topUpWei !== null && fightsIn(topUpWei) !== undefined && (
          <p className="text-bull-text-faint">
            that is {fightsIn(topUpWei)} away fight{fightsIn(topUpWei) === 1 ? '' : 's'} at
            today&apos;s price, and it is still yours the whole time it sits there.
          </p>
        )}
        {balance.fallsShort && (
          <p className="text-bull-text-faint">
            that is everything this wallet can spare and still keep gas back for the fights.
          </p>
        )}
      </div>

      {/* ══ THE AWAY BUDGET ═══════════════════════════════════════════
          ⚠ THIS IS THE APPROVAL CUSTODY DELETED, AND IT DEFAULTS TO ZERO.
          A wallet that has only topped up is STILL not challengeable, so this
          sits directly under the top-up rather than in a separate fold — the
          two are one job, and splitting them is how a player ends up with money
          parked for a feature that never switched on.

          ⚠⚠ IT SPENDS DOWN. `_takeSide` decrements it per passive fight, so the
          copy says "budget", never "limit": somebody who reads it as a standing
          per-fight cap will be quietly unchallengeable after five and think it
          broke. `CURRENCY.awayBudgetSpendsDown` is the plain-english version and
          it is not optional decoration. */}
      <div className="space-y-2 border-t border-bull-border pt-3">
        <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <span className="font-mono uppercase tracking-wide text-bull-text-faint">
            away budget
          </span>
          <BnbAmount
            wei={balance.passiveAllowance}
            decimals={decimals}
            usdPerBnb={usdPerBnb}
            emphasis={balance.challengeable}
            className="text-sm"
          />
        </div>
        {balance.passiveAllowance !== undefined && (
          <p className="text-bull-text-faint">
            {balance.passiveFightsLeft} away fight
            {balance.passiveFightsLeft === 1 ? '' : 's'} left in it.
          </p>
        )}

        <p className="text-bull-text-faint">{CURRENCY.awayBudgetSpendsDown}</p>

        {balance.allowanceUnset && balance.hasCredit && (
          <p className="rounded border border-bull-gold/40 bg-bull-gold/5 p-2 text-bull-gold">
            {READY.budgetTrap}
          </p>
        )}

        {priced && (
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="text-bull-text-faint">let away fights spend up to</span>
            {BUDGET_FIGHTS.map((n) => {
              const wei = forFights(n)!;
              return (
                <button
                  key={n}
                  type="button"
                  onClick={() => setCap(formatUnits(wei, dp))}
                  className={presetCls(capWei === wei)}
                >
                  {n} {n === 1 ? 'fight' : 'fights'}
                </button>
              );
            })}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <input
            type="text"
            inputMode="decimal"
            value={cap}
            onChange={(e) => setCap(e.target.value)}
            placeholder={suggestedCap !== undefined ? formatUnits(suggestedCap, dp) : '0.0'}
            aria-label="the most bnb fights you did not start may take, in total"
            /* ⚠ THE PLACEHOLDER IS DIMMED EXPLICITLY. These boxes are
               pre-filled with a SUGGESTION as placeholder text, and at the
               browser default they render close enough to a real value that a
               player reads "0.01664" as an amount they have already entered —
               then presses a button that says it is waiting for one. Two
               different meanings must not share a colour on a control that
               moves money. */
            className="w-32 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-[11px] text-bull-text placeholder:text-bull-text-faint"
          />
          <span className="text-bull-text-faint">bnb</span>
          {suggestedCap !== undefined && (
            <button
              type="button"
              onClick={() => setCap(formatUnits(suggestedCap, dp))}
              className="text-bull-text-faint underline hover:text-bull-gold"
            >
              suggest {SUGGESTED_PASSIVE_FIGHTS}
            </button>
          )}
        </div>

        {/* ⚠ SETTING A BUDGET SPENDS NO BNB, and the label must not imply that
            it does. It is a ceiling on money already in the balance, so it says
            "let away fights spend up to", never "pay". The figure is still on
            the button, because a number a player is stating is a number they
            should be able to read before they state it. */}
        <button
          type="button"
          onClick={() => capWei && void balance.setPassiveAllowance(capWei)}
          disabled={!capWei || balance.isBusy}
          className="w-full whitespace-normal rounded-full border-2 border-bull-gold px-3 py-2 text-center font-mono text-xs font-medium text-bull-gold transition hover:bg-bull-gold/10 disabled:cursor-not-allowed disabled:opacity-40"
        >
          {balance.isBusy
            ? 'working…'
            : capWei
              ? `set the budget to ${bnbLabel(capWei, decimals, usdPerBnb)}`
              : 'pick a budget above'}
        </button>
        {capWei !== null && fightsIn(capWei) !== undefined && (
          <p className="text-bull-text-faint">
            that is {fightsIn(capWei)} away fight{fightsIn(capWei) === 1 ? '' : 's'} before it runs
            out. nothing is spent now, and nothing above it can ever be touched.
          </p>
        )}

        {/* ⚠ ALWAYS REACHABLE, LIKE THE WITHDRAW. `setPassiveAllowance` is
            unpausable and unguarded on the contract so a player can always
            cut their exposure — gating this on anything would re-impose the
            lock the contract deliberately refuses to have. */}
        {balance.passiveAllowance !== undefined && balance.passiveAllowance > 0n && (
          <button
            type="button"
            onClick={() => void balance.setPassiveAllowance(0n)}
            disabled={balance.isBusy}
            className="rounded-full border border-bull-border px-3 py-1 text-bull-text-dim transition hover:border-bull-red hover:text-bull-red disabled:opacity-40"
          >
            switch away fights off
          </button>
        )}
        <p className="text-bull-text-faint">{CURRENCY.awayBudgetWhy}</p>
      </div>

      {/* ══ TAKE IT BACK OUT ══════════════════════════════════════════
          ⚠ ALWAYS RENDERED WHEN THERE IS A BALANCE. Never behind a fight
          gate, never behind a pause. See the file header. */}
      {balance.hasCredit && (
        <div className="space-y-2 border-t border-bull-border pt-3">
          <span className="block font-mono uppercase tracking-wide text-bull-text-faint">
            take it back out
          </span>
          <div className="flex flex-wrap items-center gap-2">
            <input
              type="text"
              inputMode="decimal"
              value={takeOut}
              onChange={(e) => setTakeOut(e.target.value)}
              placeholder="0.0"
              aria-label="bnb to take out of your fight balance"
              /* ⚠ THE PLACEHOLDER IS DIMMED EXPLICITLY. These boxes are
               pre-filled with a SUGGESTION as placeholder text, and at the
               browser default they render close enough to a real value that a
               player reads "0.01664" as an amount they have already entered —
               then presses a button that says it is waiting for one. Two
               different meanings must not share a colour on a control that
               moves money. */
            className="w-32 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-[11px] text-bull-text placeholder:text-bull-text-faint"
            />
            <span className="text-bull-text-faint">bnb</span>
            <button
              type="button"
              onClick={() => takeOutWei && !overWithdraw && void balance.withdraw(takeOutWei)}
              disabled={!takeOutWei || overWithdraw || balance.isBusy}
              className="rounded-full border border-bull-border px-3 py-1 text-bull-text transition hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
            >
              {takeOutWei && !overWithdraw
                ? `take out ${bnbLabel(takeOutWei, decimals, usdPerBnb)}`
                : 'take out'}
            </button>
            {overWithdraw && <span className="text-bull-red">more than you have in there.</span>}
          </div>
          {/* The one-tap exit. It names the whole balance, because "take it all"
              with no figure is the same missing quote as "top up" was. */}
          <button
            type="button"
            onClick={() => void balance.withdrawAll()}
            disabled={balance.isBusy}
            className="w-full whitespace-normal rounded-full border-2 border-bull-gold px-3 py-2 text-center font-mono text-xs font-medium text-bull-gold transition hover:bg-bull-gold/10 disabled:opacity-40"
          >
            {balance.isBusy
              ? 'working…'
              : `take it all back · ${bnbLabel(balance.credit, decimals, usdPerBnb)}`}
          </button>
        </div>
      )}
      <p className="text-bull-text-faint">{CURRENCY.withdrawAlways}</p>
    </div>
  );
}

/**
 * WINNINGS, WHERE THE PLAYER WILL ACTUALLY LOOK.
 *
 * ⚠ THIS IS THE MIGRATION'S BIGGEST UX RISK AND IT GETS ITS OWN COMPONENT.
 * `_distributePot` credits the winner instead of transferring to them, so a
 * player wins a fight, checks their wallet, sees no change, and concludes the
 * game kept their money. The fix is not a line of small print inside a folded
 * disclosure — it is a visible, unfoldable statement of where the money is with
 * the way out attached, shown whenever there is a balance at all.
 *
 * Rendered ABOVE the setup disclosures on purpose, so it is never something a
 * player has to go looking for.
 */
export function FightBalanceBanner({
  balance,
  decimals,
  usdPerBnb,
}: {
  balance: FightBalance;
  decimals: number | undefined;
  usdPerBnb: bigint | undefined;
}) {
  // ⚠ Off a read that LANDED, and never on an empty balance — a banner about
  // money that is not there would be noise, and noise is what people learn to
  // scroll past before the one time it matters.
  if (!balance.hasCredit) return null;

  return (
    <div className="rounded border border-bull-gold/40 bg-bull-panel px-3 py-2 text-[11px]">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="text-bull-text">
          <BnbAmount
            wei={balance.credit}
            decimals={decimals}
            usdPerBnb={usdPerBnb}
            emphasis
            className="text-sm"
          />{' '}
          sitting in your fight balance
        </span>
        <button
          type="button"
          onClick={() => void balance.withdrawAll()}
          disabled={balance.isBusy}
          className="rounded-full border border-bull-gold px-3 py-1 text-bull-gold hover:bg-bull-gold/10 disabled:opacity-40"
        >
          {balance.isBusy ? 'working…' : 'take it out'}
        </button>
      </div>
      <p className="mt-1 text-bull-text-faint">{CURRENCY.winningsHeld}</p>
    </div>
  );
}
