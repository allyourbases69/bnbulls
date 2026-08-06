'use client';

import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi';

function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Minimal wallet connect control. No contract reads happen here — this only
 * proves wagmi/viem is wired to chain 56 end to end. There is nothing to
 * mint or fight yet, so this deliberately does nothing beyond connect,
 * show the network, and disconnect.
 */
export function ConnectButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  if (isConnected && address) {
    const wrongChain = chainId !== 56;
    return (
      <div className="flex items-center gap-2">
        {wrongChain && (
          <button
            onClick={() => switchChain({ chainId: 56 })}
            className="rounded-full border border-bull-red px-3 py-1.5 text-xs font-medium text-bull-red hover:bg-bull-red/10"
          >
            wrong network, switch to bnb chain
          </button>
        )}
        <span className="rounded-full border border-bull-border bg-bull-panel px-3 py-1.5 font-mono text-xs text-bull-text-dim">
          {shortAddr(address)}
        </span>
        <button
          onClick={() => disconnect()}
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs text-bull-text-dim hover:text-bull-text"
        >
          disconnect
        </button>
      </div>
    );
  }

  const injectedConnector = connectors.find((c) => c.id === 'injected') ?? connectors[0];

  return (
    <button
      onClick={() => injectedConnector && connect({ connector: injectedConnector })}
      disabled={!injectedConnector || isPending}
      className="rounded-full border border-bull-border bg-bull-panel px-4 py-1.5 text-xs font-medium text-bull-text hover:border-bull-gold hover:text-bull-gold disabled:opacity-50"
    >
      {isPending ? 'connecting…' : 'connect wallet'}
    </button>
  );
}
