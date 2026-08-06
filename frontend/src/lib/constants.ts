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
