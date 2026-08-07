'use client';

/**
 * THE VICTORY CARD — the first place anybody learns who won.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE OUTCOME IS A SURPRISE NOW, AND THIS CARD IS THE REVEAL.
 * ═══════════════════════════════════════════════════════════════════════
 * The pre-fight card used to print "bull #6 wins · 5 rounds" above the arena,
 * which handed the player the ending before the animation had swung once. That
 * line is gone. So this is the moment: the fight freezes on a lit winner and a
 * grey loser, a beat passes (`duelPacing.ts` finalFreezeMs), and then this
 * lands on top of it.
 *
 * ⚠ AND IT STILL MAY NEVER CONTRADICT THE CHAIN. `state` is the chain's
 * verdict, not the fight's:
 *
 *   inflight → the winner stands, plainly marked as still landing
 *   settled  → the winner stands, "payment confirmed on chain"
 *   failed   → THE VICTORY COMES DOWN. Red, no winner, no money, no flavour.
 *              A revert must never leave a win on screen.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ EVERY MONEY FIGURE IS OPTIONAL, AND THAT IS THE POINT.
 * ═══════════════════════════════════════════════════════════════════════
 * This component owns the LAYOUT of the money, never the arithmetic. Each row
 * renders only when its already-formatted figure is handed in, and a row with
 * nothing behind it is simply absent — no dash, no zero, no placeholder that
 * could be read as "your balance is nothing". The call site is the one place
 * that knows which currency was played and what the signer charged, and that
 * is where those numbers are computed once.
 *
 * `extra` is the same escape hatch the animation has always had: whatever else
 * the flow wants under the money, including the signed-result proof.
 */
import { useMemo, type ReactNode } from 'react';
import { EMOJI } from '@/lib/brand';
import { DRAW_FLAVOUR, VICTORY, victoryFlavour } from '@/components/duel/duelCopy';

/** One side's rating, before and (if the signer told us) after. */
export interface DuelRating {
  /** Read off `getBull().elo` at mount, so it is the rating going IN. */
  readonly before: number | null;
  /**
   * `newEloA` / `newEloB` off the signed result.
   *
   * ⚠ NEVER COMPUTED HERE. `core/elo.ts` says it plainly: the signer signs its
   * own arithmetic because a re-implementation would diverge on rounding "from
   * the very numbers the UI showed the player". A second implementation in a
   * card is exactly that bug. No value means no arrow and no delta.
   */
  readonly after?: number | null;
}

/** Already formatted, already tickered. Strings, never bigints. */
export interface DuelPayout {
  /** What this fight dropped into the pot. */
  readonly potSlice?: { readonly amount: string; readonly symbol: string };
  /** The money in the middle, and what each side put in. */
  readonly purse?: {
    readonly total: string;
    readonly each?: string;
    readonly symbol: string;
    /** The winner's share. Printed only when handed in, because a percentage
     *  copied into a component is a percentage that drifts from the contract. */
    readonly winnerPct?: number;
  };
  /** The player's balance now. */
  readonly balance?: { readonly amount: string; readonly symbol: string };
}

export interface DuelVictoryCardProps {
  /** Null means a draw: both still standing when the round cap hit. */
  readonly winnerName: string | null;
  readonly winnerTokenId: number | null;
  readonly rounds: number;
  readonly sideA: { readonly name: string; readonly rating: DuelRating };
  readonly sideB: { readonly name: string; readonly rating: DuelRating };
  /** The chain's verdict. Not the fight's. */
  readonly state: 'inflight' | 'settled' | 'failed';
  readonly failHeadline?: string;
  readonly failMessage?: string;
  readonly payout?: DuelPayout;
  readonly onFightAgain?: (() => void) | null;
  readonly extra?: ReactNode;
}

export function DuelVictoryCard({
  winnerName,
  winnerTokenId,
  rounds,
  sideA,
  sideB,
  state,
  failHeadline,
  failMessage,
  payout,
  onFightAgain,
  extra,
}: DuelVictoryCardProps) {
  const failed = state === 'failed';
  const draw = winnerName === null;

  const flavour = useMemo(() => {
    if (draw) return DRAW_FLAVOUR;
    return victoryFlavour(winnerTokenId ?? 0, rounds);
  }, [draw, winnerTokenId, rounds]);

  return (
    <div
      className={
        'duel-victory-card w-full space-y-3 rounded border-2 p-4 text-center md:p-5 ' +
        (failed ? 'border-bull-red' : 'border-bull-gold')
      }
    >
      {failed ? (
        <>
          {/* ⚠ THE VICTORY COMES DOWN. The fight rolled a winner and the chain
              would not take it, so there is no winner to show. Showing one
              anyway would be a lie about money. */}
          <p className="bull-header text-lg text-bull-red">
            {failHeadline ?? 'the chain knocked it back'}
          </p>
          <p className="text-sm leading-relaxed text-bull-text-dim">
            nothing moved. nobody was charged, nobody got paid, and this one is not on the record.
            what you just watched was the roll, not a result.
          </p>
          {failMessage && (
            <p className="break-words font-mono text-xs text-bull-text-faint">{failMessage}</p>
          )}
        </>
      ) : (
        <>
          <p className="bull-header text-[0.62rem] uppercase tracking-[0.26em] text-bull-text-faint">
            {draw ? VICTORY.drawEyebrow : VICTORY.eyebrow}
          </p>
          <p
            className={
              'bull-header break-words text-2xl leading-tight md:text-3xl ' +
              (draw ? 'text-bull-text-dim' : 'animate-victory-name text-bull-gold')
            }
          >
            {draw ? VICTORY.drawHeadline : `${winnerName} ${VICTORY.winsSuffix}`}
          </p>
          <p className="text-sm text-bull-text-dim">{flavour}</p>
          <p className="font-mono text-xs text-bull-text-faint">{VICTORY.rounds(rounds)}</p>

          {payout?.potSlice && (
            <div className="space-y-0.5">
              <p className="font-mono text-xs text-bull-text-dim">
                <span aria-hidden className="mr-1">
                  {EMOJI.pot}
                </span>
                {VICTORY.potSlice}{' '}
                <span className="text-bull-gold">
                  {payout.potSlice.amount} {payout.potSlice.symbol}
                </span>
              </p>
              <p className="font-mono text-[0.65rem] text-bull-text-faint">
                {VICTORY.potSliceWhere}
              </p>
            </div>
          )}

          <RatingRow sideA={sideA} sideB={sideB} />

          {(payout?.purse || payout?.balance) && (
            <div className="space-y-1 border border-bull-border bg-bull-bg/60 p-3 text-left font-mono text-xs">
              {payout.purse && (
                <p className="text-bull-text-dim">
                  <span className="text-bull-text-faint">{VICTORY.purse} </span>
                  <span className="text-bull-text">
                    {payout.purse.total} {payout.purse.symbol}
                  </span>
                  {payout.purse.each && (
                    <span className="text-bull-text-faint">
                      {' '}
                      · {VICTORY.purseEach} {payout.purse.each}
                    </span>
                  )}
                  {payout.purse.winnerPct !== undefined && (
                    <span className="text-bull-text-faint">
                      {' '}
                      · winner takes {payout.purse.winnerPct}%
                    </span>
                  )}
                </p>
              )}
              {payout.balance && (
                <p className="text-bull-text-dim">
                  <span className="text-bull-text-faint">{VICTORY.balance} </span>
                  <span className="text-bull-text">
                    {payout.balance.amount} {payout.balance.symbol}
                  </span>
                </p>
              )}
            </div>
          )}

          <p
            className={
              'font-mono text-xs ' +
              (state === 'settled' ? 'text-bull-gold' : 'text-bull-text-faint')
            }
          >
            {state === 'settled' ? `✓ ${VICTORY.confirmed}` : VICTORY.pending}
          </p>
        </>
      )}

      {onFightAgain && (
        <button type="button" className="bull-btn w-full" onClick={onFightAgain}>
          {VICTORY.fightAgain}
        </button>
      )}

      {/* The flow's own slot: the money it computes, and the signed-result
          proof disclosure. Kept a slot so no money copy is written twice.
          ⚠ THE TX LINK LIVES IN THERE, NOT HERE. This card used to print its
          own "view the transaction" under the slot, which put the same link on
          the card twice — once in prose, once in the proof's tx row. The proof
          is the receipt, so the proof is where the transaction lives. */}
      {extra}
    </div>
  );
}

/**
 * Both ratings, side by side, the way the reference lays them out.
 *
 * Prints whatever it actually has: a rating with no "after" gets no arrow and
 * no delta rather than a computed one, and a side whose chain read has not
 * landed prints nothing at all. An invented rating is worse than a missing one
 * — the leaderboard would disagree with it within the minute.
 */
function RatingRow({
  sideA,
  sideB,
}: {
  sideA: DuelVictoryCardProps['sideA'];
  sideB: DuelVictoryCardProps['sideB'];
}) {
  if (sideA.rating.before === null && sideB.rating.before === null) return null;
  return (
    <div className="flex items-center justify-center gap-3 font-mono text-xs">
      <RatingCell name={sideA.name} rating={sideA.rating} align="right" />
      <span className="bull-header shrink-0 text-bull-text-faint">vs</span>
      <RatingCell name={sideB.name} rating={sideB.rating} align="left" />
    </div>
  );
}

function RatingCell({
  name,
  rating,
  align,
}: {
  name: string;
  rating: DuelRating;
  align: 'left' | 'right';
}) {
  const { before, after } = rating;
  const delta = before !== null && after !== null && after !== undefined ? after - before : null;
  return (
    <div className={`min-w-0 flex-1 ${align === 'right' ? 'text-right' : 'text-left'}`}>
      <p className="truncate text-bull-text-dim" title={name}>
        {name}
      </p>
      <p className="text-bull-text-faint" style={{ fontVariantNumeric: 'tabular-nums' }}>
        {before === null ? (
          <span>{VICTORY.ratingLabel}</span>
        ) : (
          <>
            <span className="mr-1">{VICTORY.ratingLabel}</span>
            <span className="text-bull-text">{before}</span>
            {after !== null && after !== undefined && (
              <>
                <span aria-hidden> → </span>
                <span className="text-bull-text">{after}</span>
              </>
            )}
            {delta !== null && delta !== 0 && (
              <span className={delta > 0 ? 'ml-1 text-bull-gold' : 'ml-1 text-bull-red'}>
                ({delta > 0 ? '+' : ''}
                {delta})
              </span>
            )}
          </>
        )}
      </p>
    </div>
  );
}
