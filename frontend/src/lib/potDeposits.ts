/**
 * The shape of a jackpot deposit feed, and the words for it.
 *
 * ⚠ CLIENT-SAFE. No secret, no server-only import — the route handler in
 * `app/api/pot-deposits` and the components under `components/pots` both read
 * this file, so it must stay importable from the browser bundle. The chain
 * reading itself lives in `lib/serverLogs.ts`, which does not.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHAT A DEPOSIT ACTUALLY IS, ON EACH POT
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Both pots emit `Funded(address indexed from, uint256 amount, string source)`
 * on every deposit, byte-identical across `Jackpot.sol` and `JackpotNative.sol`
 * even though the two contracts are otherwise different animals. That one event
 * is the whole feed: `amount` is how much, `from` is which part of the game
 * paid it, `source` is the leg inside that part, and etherscan hands back the
 * block timestamp with it.
 *
 * ⚠ THE `source` LABEL DOES NOT IDENTIFY THE ROUTE ON ITS OWN, AND ASSUMING IT
 * DOES WOULD MISLABEL THREE OF THE SIX ROUTES. `MintBnbullSplitter`,
 * `ReviveBuySplitter` and `MarketPotSplitter` all share `lib/PotSplitter.sol`,
 * so all three emit the same two strings, `"inline"` and `"deferred-sweep"`.
 * What separates a mint from a revive from a marketplace sale is the SENDER.
 * So the sender decides the route and the source decides the flavour, never the
 * other way round.
 *
 * ⚠ THE TWO POTS' EVENT SETS ARE NOT THE SAME, AND THIS IS WHERE IT SHOWS.
 * `JackpotNative` adds three events `Jackpot` does not have (`FundUnwrapped`,
 * `StrayWbnbAbsorbed`, `PrizeCredited`/`PrizeWithdrawn`), and exactly one of
 * them is a DEPOSIT the `Funded` sweep would miss:
 *
 *   `absorbStrayWbnb()` is permissionless, credits `totalFunded`, and emits
 *   `StrayWbnbAbsorbed(uint256)` — NOT `Funded`.
 *
 * So the native pot is swept on two topics and the erc-20 pot on one. It has
 * never fired on chain (0 of 226 logs on the bnb pot at the time of writing),
 * which is precisely why it is worth handling rather than assuming: the day it
 * does, the money is in the pot and this feed would otherwise have to report a
 * shortfall it could not explain. Note `StrayWbnbAbsorbed` carries no sender —
 * the address on that row is the pot's own, and the ui never prints it.
 *
 * ⚠ AND BOTH POTS STILL HAVE ONE GENUINELY UNLOGGED WAY IN. `JackpotNative`'s
 * `receive()` takes a bare BNB transfer as a donation and emits nothing at all;
 * a plain erc-20 `transfer` to `Jackpot` does the same, because `pool()` there
 * is just `balanceOf`. Neither touches `totalFunded` either, so they raise the
 * pot without raising anything this feed can see. That is why the feed compares
 * its own sum against the pot's `totalFunded()` and says plainly when the two
 * disagree, instead of presenting a total it cannot prove.
 */

/** Which part of the game paid, decided by the SENDER. See the header. */
export type DepositRouteKey =
  | 'duel'
  | 'mint'
  | 'bnbullMint'
  | 'revive'
  | 'market'
  | 'house'
  | 'stray'
  | 'unknown';

export interface DepositRouteCopy {
  /** Two or three words, for the chip on a row. */
  readonly chip: string;
  /** One line, for the breakdown above the feed. */
  readonly line: string;
}

/**
 * ⚠ VOICE: lowercase, plain, and the arena is THE BULL PIT. Never "the yards"
 * in anything a human reads — `Yards.sol` keeps the name in code only.
 */
export const DEPOSIT_ROUTES: Record<DepositRouteKey, DepositRouteCopy> = {
  duel: { chip: 'fight cut', line: "the house's cut of a scrap in the bull pit" },
  mint: { chip: 'mint', line: 'a slice of every bull minted' },
  bnbullMint: { chip: '$bnbull mint', line: 'a slice of every bull minted with $bnbull' },
  revive: { chip: 'revive', line: 'a slice of every bull dragged back out of the graveyard' },
  market: { chip: 'market sale', line: 'the pot fee on every sale in the marketplace' },
  house: { chip: 'house top-up', line: 'the house putting money in the middle by hand' },
  stray: {
    chip: 'stray wbnb',
    line: 'wbnb somebody sent to the pot by mistake, pushed into the pool for good',
  },
  unknown: { chip: 'other', line: 'a funder the site does not have a name for yet' },
};

/**
 * The flavour inside a route, straight off the contracts. `"deferred-sweep"` is
 * the only one worth explaining: a leg that could not trade at the time parks
 * the money and a keeper pushes it in later, so the deposit lands well after
 * the fight or mint that earned it.
 */
export function sourceNote(source: string): string | null {
  if (source === 'deferred-sweep') return 'held back at the time, swept in later';
  return null;
}

export interface PotDeposit {
  /** Raw units of the pot's own asset, as a decimal string (JSON has no bigint). */
  readonly amount: string;
  /** The `source` string exactly as the contract emitted it. Never rewritten. */
  readonly source: string;
  readonly from: `0x${string}`;
  readonly route: DepositRouteKey;
  readonly txHash: `0x${string}`;
  readonly blockNumber: number;
  /**
   * ⚠ CARRIED SO A ROW HAS A UNIQUE KEY, AND IT IS NOT DECORATION. One duel
   * transaction emits `Funded` TWICE — the house takes its cut from each side
   * of the fight — and when both bulls put up the same money in the middle the
   * two rows are identical in every other field including the amount. Keyed on
   * anything less, react collapses two real deposits into one and the feed
   * under-reports the pot. Measured on chain: 31 of 34 funding transactions.
   */
  readonly logIndex: number;
  /** Unix seconds. */
  readonly timestamp: number;
}

export interface PotDepositsPayload {
  readonly pot: 'jackpotBnbull' | 'jackpotBnb';
  readonly address: `0x${string}`;
  readonly symbol: string;
  readonly decimals: number;
  readonly chainId: number;
  /** Newest first. */
  readonly deposits: readonly PotDeposit[];
  /** Sum of `deposits`, raw units. */
  readonly shownTotal: string;
  /** The pot's own lifetime counter, raw units, or null if the read failed. */
  readonly totalFunded: string | null;
  /** What is sitting in the pot right now, raw units, or null if unread. */
  readonly pool: string | null;
  /** Lifetime paid out to winners, raw units, or null if unread. */
  readonly totalAwarded: string | null;
  /** BNB/USD at 1e18, for the native pot only. Null means "do not show usd". */
  readonly bnbUsd1e18: string | null;
  /** True when the log sweep stopped early. See `LogSweep.truncated`. */
  readonly truncated: boolean;
  readonly fetchedAt: number;
}

/**
 * Is what we are showing the whole story?
 *
 * ⚠ THREE OUTCOMES, NOT TWO, AND THEY MUST LOOK DIFFERENT ON THE PAGE.
 * `complete` means the rows add up to the pot's own counter. `partial` means
 * they do not, which is a real possibility (a truncated sweep, or an unlogged
 * native donation through `receive()`), and the page has to say so rather than
 * imply the pot is smaller than it is. `unknown` means the counter itself did
 * not read, so we cannot claim either way and must not pretend to.
 */
export function completeness(p: PotDepositsPayload): 'complete' | 'partial' | 'unknown' {
  if (p.truncated) return 'partial';
  if (p.totalFunded === null) return 'unknown';
  return BigInt(p.shownTotal) === BigInt(p.totalFunded) ? 'complete' : 'partial';
}

/** Totals per route, biggest first. Raw units, so the caller formats once. */
export function byRoute(
  deposits: readonly PotDeposit[],
): { route: DepositRouteKey; total: bigint; count: number }[] {
  const acc = new Map<DepositRouteKey, { total: bigint; count: number }>();
  for (const d of deposits) {
    const row = acc.get(d.route) ?? { total: 0n, count: 0 };
    row.total += BigInt(d.amount);
    row.count += 1;
    acc.set(d.route, row);
  }
  return [...acc.entries()]
    .map(([route, v]) => ({ route, ...v }))
    .sort((a, b) => (a.total > b.total ? -1 : a.total < b.total ? 1 : 0));
}
