'use client';

import { useState } from 'react';
import { formatUnits, parseUnits } from 'viem';
import { CURRENCY } from '@/lib/brand';
import type { FightBalance } from '@/lib/hooks/useFightBalance';

/** The default we offer for the passive ceiling, in FIGHTS. Small on purpose:
 *  it is the blast radius of a leaked signer key, and topping it up later is
 *  one cheap transaction while getting it back is not possible at all. */
const SUGGESTED_PASSIVE_FIGHTS = 5;

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
 */
export function FightBalanceRow({
  balance,
  decimals,
  fights,
}: {
  balance: FightBalance;
  /** BNB is 18dp; passed rather than assumed, same as `AllowanceRow`. */
  decimals: number | undefined;
  /** The one page-wide "how many fights are you up for" count. */
  fights: number;
}) {
  const [topUp, setTopUp] = useState('');
  const [takeOut, setTakeOut] = useState('');
  const [cap, setCap] = useState('');
  const dp = decimals ?? 18;

  const fmt = (v: bigint | undefined) =>
    v === undefined ? '—' : Number(formatUnits(v, dp)).toFixed(6);

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

  /** A sensible default expressed the way a player thinks: a NUMBER OF FIGHTS,
   *  priced off the live cost. Nobody should be asked to pick a raw wei figure
   *  for a security control — the whole point is that they actually set it. */
  const capFor = (n: number): bigint | undefined =>
    balance.perFight === undefined ? undefined : balance.perFight * BigInt(n);
  const suggestedCap = capFor(SUGGESTED_PASSIVE_FIGHTS);
  const overWithdraw =
    takeOutWei !== null && balance.credit !== undefined && takeOutWei > balance.credit;

  if (!balance.configured) {
    return (
      <p className="text-[11px] text-bull-text-faint">
        no bnb fight cost is registered on the duel contract yet.
      </p>
    );
  }

  return (
    <div className="space-y-2 text-[11px]">
      <div className="flex flex-wrap items-baseline gap-x-2 text-bull-text-dim">
        <span className="font-mono uppercase tracking-wide text-bull-text-faint">
          fight balance
        </span>
        <span className="font-mono text-bull-text">{fmt(balance.credit)} bnb</span>
        {/* ⚠ Only claim a fight count off a read that LANDED. `fightsCovered`
            is already 0 when unread, so it is gated on the balance itself. */}
        {balance.credit !== undefined && (
          <span className="text-bull-text-faint">
            covers {balance.fightsCovered} {balance.fightsCovered === 1 ? 'fight' : 'fights'}
          </span>
        )}
      </div>

      {balance.credit !== undefined && balance.cannotCoverOne && (
        <p className="text-bull-text-faint">
          not enough in here for a fight, so nobody can pick your bulls while you are away. you
          can still start fights yourself.
        </p>
      )}
      {balance.credit !== undefined && !balance.cannotCoverOne && balance.shortForRun && (
        <p className="text-bull-text-faint">
          enough for {balance.fightsCovered} of your {fights}. top up to cover the run.
        </p>
      )}

      {/* ── how many fights, and EXACTLY what that costs ────────────────
          ⚠ THE PRICE IS SHOWN, NOT IMPLIED. Owner call 2026-08-10: a player
          putting money into a contract must see the exact BNB before they
          click, for the number of fights they actually want. A bare "top up"
          box asks someone to fund custody against a figure they have to work
          out themselves, which is precisely when people either overshoot or
          walk away.

          ⚠ PRICED OFF THE LIVE `perFight`, NEVER A CONSTANT. The BNB stake is
          a USD sticker converted through chainlink, so it moves every block —
          a hardcoded ladder would drift and quietly under-fund. When the read
          has not landed, the row is not rendered at all rather than showing a
          zero, because "1 fight · 0.0000 bnb" is a lie that costs money. */}
      {balance.perFight !== undefined && balance.perFight > 0n && (
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-bull-text-faint">put in for</span>
          {[1, 5, 10, 25, 50].map((n) => {
            const wei = balance.perFight! * BigInt(n);
            return (
              <button
                key={n}
                type="button"
                onClick={() => setTopUp(formatUnits(wei, dp))}
                className="rounded-full border border-bull-border px-2 py-0.5 font-mono text-[11px] text-bull-text hover:border-bull-gold hover:text-bull-gold"
              >
                {n} {n === 1 ? 'fight' : 'fights'}
                <span className="ml-1 text-bull-text-faint">{fmt(wei)}</span>
              </button>
            );
          })}
          <span className="text-bull-text-faint">
            one fight is {fmt(balance.perFight)} bnb right now
          </span>
        </div>
      )}

      {/* ── top up ─────────────────────────────────────────────────── */}
      <div className="flex flex-wrap items-center gap-2">
        <input
          type="text"
          inputMode="decimal"
          value={topUp}
          onChange={(e) => setTopUp(e.target.value)}
          placeholder={balance.suggested > 0n ? fmt(balance.suggested) : '0.0'}
          aria-label="bnb to add to your fight balance"
          className="w-28 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-[11px] text-bull-text"
        />
        <button
          type="button"
          onClick={() => topUpWei && void balance.deposit(topUpWei)}
          disabled={!topUpWei || balance.isBusy}
          className="rounded-full border border-bull-border px-3 py-1 text-[11px] text-bull-text hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
        >
          {balance.isBusy ? 'working…' : 'top up'}
        </button>
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
      {balance.fallsShort && (
        <p className="text-bull-text-faint">
          that is everything this wallet can spare and still keep gas back for the fights.
        </p>
      )}

      {/* ── step 2: the ceiling ─────────────────────────────────────────
          ⚠ THIS IS THE APPROVAL CUSTODY DELETED, AND IT DEFAULTS TO ZERO.
          A wallet that has only topped up is STILL not challengeable, so this
          sits directly under the top-up rather than in a separate fold — the
          two are one job, and splitting them is how a player ends up with money
          parked for a feature that never switched on.

          ⚠⚠ IT SPENDS DOWN. `_takeSide` decrements it per passive fight, so the
          copy says "budget", never "limit": somebody who reads it as a standing
          per-fight cap will be quietly unchallengeable after five and think it
          broke. */}
      <div className="space-y-2 border-t border-bull-border pt-2">
        <div className="flex flex-wrap items-baseline gap-x-2 text-bull-text-dim">
          <span className="font-mono uppercase tracking-wide text-bull-text-faint">
            away budget
          </span>
          <span className="font-mono text-bull-text">{fmt(balance.passiveAllowance)} bnb</span>
          {balance.passiveAllowance !== undefined && (
            <span className="text-bull-text-faint">
              {balance.passiveFightsLeft} {balance.passiveFightsLeft === 1 ? 'fight' : 'fights'} left
            </span>
          )}
        </div>

        <p className="text-bull-text-faint">
          the most fights you did not start can take out of your balance in total. it counts down
          as they happen, so top it back up when it runs out. set it to zero any time to switch
          offline fights off.
        </p>

        {balance.allowanceUnset && balance.hasCredit && (
          <p className="text-bull-gold">
            you have money in here but no away budget, so nobody can pick your bulls yet. set one
            below and they are in.
          </p>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <input
            type="text"
            inputMode="decimal"
            value={cap}
            onChange={(e) => setCap(e.target.value)}
            placeholder={suggestedCap !== undefined ? fmt(suggestedCap) : '0.0'}
            aria-label="the most bnb fights you did not start may take, in total"
            className="w-28 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-[11px] text-bull-text"
          />
          <button
            type="button"
            onClick={() => capWei && void balance.setPassiveAllowance(capWei)}
            disabled={!capWei || balance.isBusy}
            className="rounded-full border border-bull-border px-3 py-1 text-[11px] text-bull-text hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
          >
            {balance.isBusy ? 'working…' : 'set budget'}
          </button>
          {suggestedCap !== undefined && (
            <button
              type="button"
              onClick={() => setCap(formatUnits(suggestedCap, dp))}
              className="text-bull-text-faint underline hover:text-bull-gold"
            >
              {SUGGESTED_PASSIVE_FIGHTS} fights
            </button>
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
              className="rounded-full border border-bull-border px-3 py-1 text-[11px] text-bull-text-dim hover:border-bull-red hover:text-bull-red disabled:opacity-40"
            >
              switch off
            </button>
          )}
        </div>
        <p className="text-bull-text-faint">{CURRENCY.awayBudgetWhy}</p>
      </div>

      {/* ── take it out ────────────────────────────────────────────────
          ⚠ ALWAYS RENDERED WHEN THERE IS A BALANCE. Never behind a fight
          gate, never behind a pause. See the file header. */}
      {balance.hasCredit && (
        <div className="flex flex-wrap items-center gap-2 border-t border-bull-border pt-2">
          {/* ⚠ SAY THE EXIT OUT LOUD, ABOVE THE CONTROLS. Owner call
              2026-08-10. This is real BNB sitting in a contract, and the one
              question a player has before putting it there is whether they can
              get it back. `withdraw` is gated on NOTHING — no cooldown, no
              pause, no in-fight lock — so the honest thing is to state that
              where the decision is made, not in fine print underneath it. */}
          <span className="w-full text-bull-text-faint">
            didn&apos;t fight, or done? take it back any time — there is no lock and no waiting.
          </span>
          <input
            type="text"
            inputMode="decimal"
            value={takeOut}
            onChange={(e) => setTakeOut(e.target.value)}
            placeholder="0.0"
            aria-label="bnb to take out of your fight balance"
            className="w-28 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-[11px] text-bull-text"
          />
          <button
            type="button"
            onClick={() => takeOutWei && !overWithdraw && void balance.withdraw(takeOutWei)}
            disabled={!takeOutWei || overWithdraw || balance.isBusy}
            className="rounded-full border border-bull-border px-3 py-1 text-[11px] text-bull-text hover:border-bull-gold hover:text-bull-gold disabled:opacity-40"
          >
            take out
          </button>
          <button
            type="button"
            onClick={() => void balance.withdrawAll()}
            disabled={balance.isBusy}
            className="rounded-full border border-bull-gold px-3 py-1 text-[11px] text-bull-gold hover:bg-bull-gold/10 disabled:opacity-40"
          >
            take it all
          </button>
          {overWithdraw && (
            <span className="text-bull-red">more than you have in there.</span>
          )}
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
}: {
  balance: FightBalance;
  decimals: number | undefined;
}) {
  // ⚠ Off a read that LANDED, and never on an empty balance — a banner about
  // money that is not there would be noise, and noise is what people learn to
  // scroll past before the one time it matters.
  if (!balance.hasCredit) return null;
  const dp = decimals ?? 18;
  const amount = Number(formatUnits(balance.credit ?? 0n, dp)).toFixed(6);

  return (
    <div className="rounded border border-bull-gold/40 bg-bull-panel px-3 py-2 text-[11px]">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="text-bull-text">
          <strong className="bull-header text-bull-gold">{amount} bnb</strong> sitting in your
          fight balance
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
