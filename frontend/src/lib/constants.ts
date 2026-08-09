/**
 * A dollar-denominated price converts to a BNB amount at PAY time through the
 * Chainlink feed (`DECISIONS.md §1`), not at quote time — so the wallet's
 * quoted BNB amount can drift a little before the tx lands. Every contract
 * that takes a BNB payment accepts `msg.value >= due` and refunds the
 * surplus, by design (not sloppiness — see `MintDrop._mintWithBNB`'s
 * header). This cushion absorbs ordinary drift so an honest payment doesn't
 * bounce; the excess always comes back.
 */
export const BNB_QUOTE_CUSHION_BPS = 150n; // 1.5%

export function withCushion(due: bigint): bigint {
  return due + (due * BNB_QUOTE_CUSHION_BPS) / 10_000n;
}

/** How often an on-chain price quote (mint, duel fight cost, a marketplace
 *  listing) refetches, and the number shown to the user as its TTL — same
 *  reasoning as the cushion above: the oracle moves, so a stale quote on
 *  screen is a failed transaction waiting to happen. */
export const QUOTE_REFRESH_MS = 20_000;

/**
 * Native BNB held back when judging whether a wallet can afford a mint.
 *
 * ⚠ COST ALONE IS NOT ENOUGH TO PAY. A wallet holding exactly the mint price
 * still cannot buy the block space, so a bare `balance < cost` check passes and
 * the transaction then fails as `OutOfFunds` — which carries no revert data and
 * so reads as the generic "something has moved, reload and try again". That is
 * the single most confusing near-miss on the mint page.
 *
 * 0.002 BNB is roughly 40x a mint's gas at BSC's 0.05 gwei floor, so it stays
 * honest if gas spikes without ever refusing a wallet that could clearly pay.
 * Deliberately generous: refusing one affordable mint is a worse outcome than
 * nudging somebody to hold a fraction of a cent more.
 */
export const MINT_GAS_HEADROOM_WEI = 2_000_000_000_000_000n; // 0.002 BNB

/**
 * Native BNB left behind when offering to wrap into WBNB.
 *
 * ⚠ BIGGER THAN THE MINT HEADROOM ON PURPOSE. Wrapping is never the last
 * transaction a player makes: after it they still have to APPROVE the duel
 * contract, and then pay gas on every fight they start themselves. A wallet
 * that wrapped its way down to the mint headroom would be approved, funded,
 * fightable, and unable to buy the block space to do any of it — the same
 * unhelpful `OutOfFunds` dead end, one step further along.
 *
 * 0.005 BNB is a fraction of a cent at BSC's 0.05 gwei floor and covers an
 * approve plus a long run of fights.
 */
export const WRAP_GAS_RESERVE_WEI = 5_000_000_000_000_000n; // 0.005 BNB
