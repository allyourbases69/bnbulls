/**
 * The shape of the fight record — every duel ever settled on chain.
 *
 * ⚠ CLIENT-SAFE. No secret, no server-only import: the route handler in
 * `app/api/duel-history` and `lib/hooks/useDuelHistory` both read this file, so
 * it must stay importable from the browser bundle. The chain reading lives in
 * `lib/serverLogs.ts`, which does not.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE EVENT IS THE ONLY ARCHIVE
 * ═══════════════════════════════════════════════════════════════════════
 *
 * `Duel` keeps no list of past fights — the standing-fight slot holds ONE row
 * per wallet and is cleared the moment the fight settles — so `DuelCompleted` is
 * the whole record. It is also why a replay needs nothing but a tx hash: the
 * seed rides in the event and the fight is deterministic from it
 * (`lib/duelReplaySource.ts`).
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THE BROWSER STOPPED BEING ALLOWED TO READ IT
 * ═══════════════════════════════════════════════════════════════════════
 *
 * `/history` used to sweep this event through `useContractLogs`, and on bnb
 * mainnet that sweep silently lost most of it: publicnode 403s any window
 * reaching past its retention (~7,300 blocks), drpc 400s, both dataseeds refuse
 * even a 500-block window with `-32005`. Neither a 403 nor a rate limit is a
 * range-cap error, so the scanner's halving path never fired and the refused
 * chunks vanished without a trace. The page showed the last couple of hours of
 * fights, called itself incomplete, and got shorter every day the contract
 * lived. Measured 2026-08-10: 31 of the 35 fights on chain.
 *
 * The etherscan v2 multichain api answers the same query for the whole range in
 * one request. The measurements are in `lib/serverLogs.ts`.
 */

export interface DuelRecordRow {
  readonly tokenA: number;
  readonly tokenB: number;
  /** The winning token id. **0 means a draw** (`Duel._updateStreaksAndCheckDeaths`). */
  readonly winnerId: number;
  readonly rounds: number;
  /** Rating AFTER this fight, as the chain recorded it. Not a live read: this is
   *  what the bull was worth on the day, which is what a history row means. */
  readonly newEloA: number;
  readonly newEloB: number;
  readonly txHash: `0x${string}`;
  readonly blockNumber: number;
  /**
   * ⚠ CARRIED, NOT DROPPED, AND IT IS LOAD-BEARING TWICE OVER. One transaction
   * can settle more than one duel, so it is half of a row's unique key — keyed
   * on the hash alone, react collapses two real fights into one row. It is also
   * what `/api/duel-gif?…&log=` uses to pick WHICH fight in the transaction to
   * replay; without it every replay from such a tx plays the first one.
   */
  readonly logIndex: number;
  /** Unix seconds, straight off the log. */
  readonly timestamp: number;
}

export interface DuelRecordPayload {
  readonly chainId: number;
  readonly address: `0x${string}`;
  /** Newest first. */
  readonly fights: readonly DuelRecordRow[];
  /** How many the sweep found, before the row cap below trimmed anything. */
  readonly total: number;
  /**
   * True when `fights` is NOT the whole record — either the log sweep stopped
   * early (see `LogSweep.truncated`) or more fights exist than one page may
   * carry. Either way the page must say so out loud: a partial record shown as
   * a whole one is the quiet version of being wrong.
   */
  readonly truncated: boolean;
  readonly fetchedAt: number;
}
