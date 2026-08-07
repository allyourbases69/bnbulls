'use client';

import { useCallback } from 'react';
import { useAccount, useSwitchChain } from 'wagmi';
import { CHAIN_ID, IS_TESTNET } from '@/lib/env';

/** How the target chain is named in player copy. */
export const CHAIN_LABEL = IS_TESTNET ? 'bnb testnet' : 'bnb chain';

/**
 * "Is the connected wallet on the chain this build talks to?"
 *
 * ⚠ THIS EXISTS BECAUSE A WRONG-CHAIN WRITE IS THE ONE WAY THIS SITE CAN BURN
 * A PLAYER'S MONEY UNRECOVERABLY, and nothing below the UI stops it.
 *
 * wagmi's `writeContract` resolves the chain from the wallet's own connection
 * and passes `chain: chainId ? { id: chainId } : null` down to viem. With
 * `chain: null` viem skips `assertCurrentChain` **entirely** — so a wallet that
 * declined the network switch still broadcasts, quite happily, to whatever
 * chain it happens to be sitting on. `MintDrop.mintWithBNB` and
 * `Duel.submitDuel` both carry native `value`, and our contract addresses hold
 * no code on any other chain, so that BNB leaves the wallet and does not come
 * back. Two defences, both required:
 *
 *   1. every write call passes `chainId: CHAIN_ID`, which restores viem's
 *      `assertCurrentChain` and turns a wrong-chain send into a thrown
 *      `ChainMismatchError` before anything is signed; and
 *   2. this hook, so the buttons are visibly OFF rather than throwing after
 *      the click. A guard that only fires at submit time reads as a broken
 *      site; a guard that greys the button reads as an instruction.
 *
 * ⚠ IT READS `useAccount().chainId`, NEVER `useChainId()`, AND THAT IS THE
 * WHOLE POINT. `useChainId()` returns `config.state.chainId`, and wagmi's
 * `syncConnectedChain` subscription refuses to move that value to a chain that
 * is not in `config.chains`:
 *
 *     if (!isChainConfigured) return;
 *
 * This config carries exactly one chain, so `useChainId()` is a constant equal
 * to `CHAIN_ID` and `useChainId() !== CHAIN_ID` can never be true. Written that
 * way the guard is a silent no-op that looks like a fix. `useAccount().chainId`
 * is the connection's real chain id, including chains we do not support, which
 * is exactly the case being guarded. `ConnectButton` already reads it correctly.
 */
export function useWrongNetwork() {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending } = useSwitchChain();

  const wrongNetwork = isConnected && chainId !== undefined && chainId !== CHAIN_ID;

  const switchToRightChain = useCallback(() => {
    switchChain({ chainId: CHAIN_ID });
  }, [switchChain]);

  return {
    /** True only when a wallet is connected AND it is on some other chain. */
    wrongNetwork,
    /** The chain the wallet is actually on, or undefined when disconnected. */
    walletChainId: chainId,
    switchToRightChain,
    isSwitching: isPending,
    chainLabel: CHAIN_LABEL,
  };
}
