/**
 * TestnetBanner — a site-wide strip whenever this build points at chain 97.
 *
 * ⚠ WHY THIS IS NOT OPTIONAL. A testnet build that looks exactly like mainnet
 * is how somebody spends real money trying to buy a bull that does not exist,
 * or believes a jackpot figure that is play money. The bulls are real, the
 * pots hold real balances, every number on the page is live — it is just live
 * on the wrong chain, and nothing else on the page says so.
 *
 * It renders nothing on mainnet, and `CHAIN_ID` in `env.ts` never falls back
 * to a testnet, so this can only appear when someone set
 * `NEXT_PUBLIC_CHAIN_ID=97` on purpose.
 *
 * Sticky rather than scroll-away on purpose: someone who lands mid-page on a
 * shared link must see it too.
 */
import { IS_TESTNET } from '@/lib/env';

export function TestnetBanner() {
  if (!IS_TESTNET) return null;
  return (
    <div
      role="status"
      className="sticky top-0 z-[70] border-b border-amber-400/40 bg-amber-400 px-4 py-1.5 text-center text-xs font-semibold text-black"
    >
      testnet build · bsc chain 97 · everything here is play money and gets wiped before launch
    </div>
  );
}
