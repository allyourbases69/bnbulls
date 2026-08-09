'use client';

import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';

/**
 * Site-wide wrong-network banner.
 *
 * `WrongNetworkNotice` lives INSIDE a money panel, so it only warns you once you
 * are already looking at /mint, /duel, etc. This sits at the very top of EVERY
 * page (it is mounted in `providers.tsx`, inside the wagmi context), so a wallet
 * connected to the wrong chain is impossible to miss wherever you land -
 * including /admin, where the owner hit exactly this. Before this the only
 * global signal was a small "switch" pill in the header, which read as
 * decoration and got missed.
 *
 * Renders nothing when the wallet is on the right chain (or is disconnected),
 * so it is safe to mount unconditionally. Detection + the switch/add-chain
 * behaviour both come from `useWrongNetwork` - this is presentation only.
 */
export function WrongNetworkBanner() {
  const { wrongNetwork, walletChainId, switchToRightChain, isSwitching, chainLabel } =
    useWrongNetwork();
  if (!wrongNetwork) return null;

  return (
    <div
      role="alert"
      className="sticky top-0 z-50 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 border-b border-bull-red bg-bull-red px-4 py-2 text-center text-sm font-medium text-white"
    >
      <span>
        <strong className="font-semibold">wrong network{walletChainId ? ` (chain ${walletChainId})` : ''}.</strong>{' '}
        bnbulls runs on {chainLabel} - switch, or your wallet is talking to contracts that do not
        exist and money sent there does not come back.
      </span>
      <button
        type="button"
        onClick={switchToRightChain}
        disabled={isSwitching}
        className="shrink-0 rounded-full border border-white px-3 py-1 text-xs font-semibold text-white hover:bg-white/15 disabled:opacity-50"
      >
        {isSwitching ? 'switching…' : `switch to ${chainLabel}`}
      </button>
    </div>
  );
}
