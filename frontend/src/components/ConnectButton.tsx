'use client';

import { useCallback, useEffect, useRef } from 'react';
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi';
import { CHAIN_ID, IS_TESTNET } from '@/lib/env';

function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

const CHAIN_LABEL = IS_TESTNET ? 'bnb testnet' : 'bnb chain';

/**
 * Wallet connect control, with the network guard.
 *
 * ⚠ THE CHAIN COMES FROM `CHAIN_ID`, NEVER A LITERAL. This component used to
 * hardcode `56` in both the comparison and the switch call, which meant a
 * testnet build (`NEXT_PUBLIC_CHAIN_ID=97`) told a correctly-connected testnet
 * wallet it was on the "wrong network" and offered to move it to mainnet —
 * where none of the contracts it was about to talk to exist. The guard was
 * actively wrong in exactly the environment it was supposed to help.
 *
 * ⚠ AUTO-SWITCH IS MAINNET-ONLY, and that is deliberate (owner call,
 * 2026-08-07: *"check they're on the right network and if not connect them to
 * the right network — that's for BNB prod only, not needed for testnet"*).
 * On a testnet build the mismatch is still surfaced as a button, because a
 * tester on the wrong chain still needs a way across, but nothing is forced:
 * on testnet the person connecting is deliberately driving.
 */
export function ConnectButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChainAsync } = useSwitchChain();

  const wrongChain = isConnected && chainId !== undefined && chainId !== CHAIN_ID;

  // Only auto-prompt once per (account, chain) pair. Without this, a user who
  // declines the wallet's network dialog gets re-prompted on every render,
  // which is indistinguishable from a broken site.
  const promptedFor = useRef<string | null>(null);

  // ⚠ SWITCH, AND ADD IF THE WALLET DOESN'T HAVE BNB. `switchChainAsync` asks
  // the wallet to switch; because `bnbChain()` (chain.ts) carries the full
  // rpcUrls / nativeCurrency / blockExplorers, wagmi falls back to
  // `wallet_addEthereumChain` when the wallet returns 4902 (chain not present),
  // so a wallet with no BNB entry is prompted to add it. Works for every active
  // connector (injected, WalletConnect). On failure — the user rejected, or the
  // add was refused — we clear `promptedFor` so a later render can retry and the
  // manual button stays up, rather than silently giving up.
  const goToRightChain = useCallback(async () => {
    try {
      await switchChainAsync({ chainId: CHAIN_ID });
    } catch {
      promptedFor.current = null;
    }
  }, [switchChainAsync]);

  useEffect(() => {
    if (!wrongChain || IS_TESTNET) return;
    const key = `${address ?? ''}:${chainId ?? ''}`;
    if (promptedFor.current === key) return;
    promptedFor.current = key;
    goToRightChain();
  }, [wrongChain, address, chainId, goToRightChain]);

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-2">
        {wrongChain && (
          <button
            onClick={goToRightChain}
            className="rounded-full border border-bull-red px-3 py-1.5 text-xs font-medium text-bull-red hover:bg-bull-red/10"
          >
            wrong network, switch to {CHAIN_LABEL}
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
