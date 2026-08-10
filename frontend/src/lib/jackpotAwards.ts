/**
 * The shape of a jackpot's payout history — every time money has left a pot.
 *
 * ⚠ CLIENT-SAFE. No secret, no server-only import: the route handler in
 * `app/api/pot-awards` and `components/pots/PotCard` both read this file, so it
 * must stay importable from the browser bundle. The chain reading lives in
 * `lib/serverLogs.ts`, which does not.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THIS IS READ ON THE SERVER
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Because the browser cannot read this chain's history. The card used to sweep
 * `Awarded` through `useContractLogs`, and on bnb mainnet that sweep does not
 * fail — it HANGS. Every endpoint in the browser pool either 403s a window that
 * reaches past its retention or refuses `eth_getLogs` outright, and neither a
 * 403 nor a rate limit is a range-cap error, so the halving path never fires and
 * the chunks vanish silently. The card sat on "loading…" forever, on both pots,
 * for every visitor. The measurements are in `lib/serverLogs.ts`.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE THREE STATES, AND WHY AN EMPTY POT IS NOT A BROKEN ONE
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   real rows        somebody has hit this pot, here is the receipt trail
 *   honestly empty   nobody has hit it yet, which today is the true answer on
 *                    both pots (`totalAwarded` is 0 on each)
 *   could not read   our end failed, and it must never wear the empty face
 *
 * The empty state is the interesting one: a pot that has never paid out is the
 * NORMAL early state of this game, and rendering it as a spinner or a shrug
 * makes a working pot look broken. It gets a plain sentence of its own.
 */

export interface JackpotAwardRow {
  readonly winner: `0x${string}`;
  /** The bull that was holding the winning ticket. */
  readonly tokenId: number;
  /** Raw units of the pot's own asset, as a decimal string (JSON has no bigint). */
  readonly amount: string;
  readonly ticketId: string;
  readonly txHash: `0x${string}`;
  readonly blockNumber: number;
  /**
   * ⚠ CARRIED SO A ROW HAS A UNIQUE KEY, AND IT IS NOT DECORATION. One vrf
   * fulfilment settles every pending ticket in the queue, so a single
   * transaction can emit `Awarded` more than once — and two wins on the same
   * roll for the same bull, at the same amount, differ in nothing else. Keyed on
   * anything less, react collapses two real payouts into one and the card
   * under-reports what the pot has paid. Same hazard the deposit feed documents
   * on `Funded`.
   */
  readonly logIndex: number;
  /** Unix seconds. */
  readonly timestamp: number;
}

export interface JackpotAwardsPayload {
  readonly pot: 'jackpotBnbull' | 'jackpotBnb';
  readonly address: `0x${string}`;
  readonly chainId: number;
  /** Newest first. */
  readonly awards: readonly JackpotAwardRow[];
  /**
   * The pot's own `awardCount()`, or null if that read failed. It ticks exactly
   * once per `Awarded` (`Jackpot.sol:795`), so it is the authority this list
   * checks itself against.
   */
  readonly awardCount: number | null;
  /** The pot's own lifetime payout, raw units, or null if the read failed. */
  readonly totalAwarded: string | null;
  /** True when the log sweep stopped early. See `LogSweep.truncated`. */
  readonly truncated: boolean;
  readonly fetchedAt: number;
}

/**
 * Is this list the whole payout record?
 *
 * ⚠ THREE OUTCOMES, NOT TWO. `complete` means the rows match the pot's own
 * counter — which includes the case where both are zero, and that is a complete
 * record of nothing rather than a failure. `partial` means they do not match, so
 * the card must say the list is short instead of letting a visitor conclude the
 * pot pays less than it does. `unknown` means the counter itself did not read,
 * so no claim can honestly be made either way.
 */
export function awardCompleteness(p: JackpotAwardsPayload): 'complete' | 'partial' | 'unknown' {
  if (p.truncated) return 'partial';
  if (p.awardCount === null) return 'unknown';
  return p.awards.length === p.awardCount ? 'complete' : 'partial';
}
