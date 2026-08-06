/**
 * The honest pre-launch state, in one line.
 *
 * This is bnbulls' version of fefers' `AppGate` "warming up" notice: a slim
 * strip that says the game is not wired yet, so no surface has to lie and no
 * page has to be edited on deploy day. It renders NOTHING once the core
 * contracts have real addresses, so it disappears on its own.
 *
 * ⚠ It gates on the SET of contracts a game flow needs, never on one address
 * in isolation — a partial deploy would otherwise render a half-wired page
 * that looks live. See `contractsDeployed` in `lib/env.ts`.
 *
 * ⚠ NOT the same thing as `NotDeployed`. That one replaces a specific panel
 * ("the mint isn't deployed yet"); this one is the site-level statement.
 */
import { contractsDeployed } from '@/lib/env';

export function PreLaunchNotice() {
  if (contractsDeployed('bullsNft', 'mintDrop', 'duel')) return null;
  return (
    <p className="mx-auto max-w-xl rounded border border-bull-gold/30 bg-bull-panel px-4 py-3 text-left text-xs text-bull-text-dim">
      <span className="bull-header text-bull-gold">not live yet.</span> no contract has been
      deployed, so nothing on this site can be minted, fought or traded. every bull you can see
      is drawn in your browser by the same engine that will ship, and every address on the site
      is read from config, never invented.
    </p>
  );
}
