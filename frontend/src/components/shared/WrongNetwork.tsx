'use client';

import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';

/**
 * The wrong-network state, shown wherever a button that spends money lives.
 *
 * Renders nothing when the wallet is on the right chain, so it can be dropped
 * into any panel unconditionally. It says WHY the buttons are off, because
 * "nothing happens when I click" is the failure this is here to prevent, and a
 * disabled button with no explanation is only a quieter version of it.
 *
 * See `useWrongNetwork` for what wagmi does without this.
 */
export function WrongNetworkNotice({ className }: { className?: string }) {
  const { wrongNetwork, switchToRightChain, isSwitching, chainLabel } = useWrongNetwork();
  if (!wrongNetwork) return null;

  return (
    <div
      className={`rounded border border-bull-red/40 bg-bull-red/10 px-4 py-3 text-sm text-bull-text-dim ${className ?? ''}`}
    >
      <p>
        <strong className="text-bull-red">wrong network.</strong> your wallet is on another
        chain, so everything here is switched off until it moves to {chainLabel}. none of these
        contracts exist over there, and money sent to an address with no code on it does not
        come back.
      </p>
      <button
        type="button"
        onClick={switchToRightChain}
        disabled={isSwitching}
        className="mt-3 rounded-full border border-bull-red px-3 py-1.5 text-xs font-medium text-bull-red hover:bg-bull-red/10 disabled:opacity-50"
      >
        {isSwitching ? 'switching…' : `switch to ${chainLabel}`}
      </button>
    </div>
  );
}
