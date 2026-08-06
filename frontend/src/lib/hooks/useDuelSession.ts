'use client';

import { useCallback, useEffect, useState } from 'react';
import { useAccount, useSignMessage } from 'wagmi';
import { CHAIN_ID } from '@/lib/env';
import {
  buildSessionMessage,
  parseSessionMessage,
  SESSION_TTL_SECONDS,
} from '@/lib/duelSession';

/**
 * The duel session, client side.
 *
 * ⚠ THIS IS A `personal_sign`, NOT A TRANSACTION. Nothing is sent, spent or
 * approved. The message says so in plain English in the wallet prompt, and
 * `signMessageAsync` is the only wallet call this hook ever makes.
 *
 * ⚠ THE MESSAGE IS BUILT BY `lib/duelSession.ts`, THE SAME MODULE THE SERVER
 * VERIFIES WITH. Do not inline the text here "to save an import". The server
 * checks the signature over exactly the string it is handed and then re-reads
 * the terms out of that same string; one character of drift between the two
 * halves fails as `malformed`, which is reported as "sign in again" and reads
 * exactly like a bad signature.
 *
 * The signature is cached in localStorage so an honest player signs once a day
 * and then fights with a single tap. There is nothing sensitive in it — it is a
 * public signature over a public string, scoped to one wallet, one chain, one
 * host and 24 hours — but it is still stored per (wallet, chain) so switching
 * accounts never reuses somebody else's.
 */

export interface DuelSession {
  /** All THREE fields go in the POST body. Omitting `address` 401s. */
  address: `0x${string}`;
  message: string;
  signature: `0x${string}`;
}

const STORAGE_PREFIX = 'bnbulls.duelSession';

function storageKey(address: string, chainId: number): string {
  return `${STORAGE_PREFIX}.${chainId}.${address.toLowerCase()}`;
}

/** Re-signing a minute before the wallet's copy expires beats a mid-fight 401. */
const REFRESH_MARGIN_SECONDS = 120;

function readStored(address: string, chainId: number, host: string): DuelSession | null {
  try {
    const raw = window.localStorage.getItem(storageKey(address, chainId));
    if (!raw) return null;
    const parsed = JSON.parse(raw) as DuelSession;
    if (
      !parsed ||
      typeof parsed.message !== 'string' ||
      typeof parsed.signature !== 'string' ||
      typeof parsed.address !== 'string'
    ) {
      return null;
    }
    // Re-derive the terms from the stored STRING rather than trusting a stored
    // expiry field, so a hand-edited localStorage entry cannot extend a session.
    const fields = parseSessionMessage(parsed.message);
    if (!fields) return null;
    if (fields.wallet !== address.toLowerCase()) return null;
    if (fields.chainId !== chainId) return null;
    if (fields.domain !== host) return null;
    if (fields.expires - REFRESH_MARGIN_SECONDS <= Math.floor(Date.now() / 1000)) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function useDuelSession() {
  const { address } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const [session, setSession] = useState<DuelSession | null>(null);
  const [isSigning, setIsSigning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Rehydrate whenever the wallet changes. Runs client-side only: localStorage
  // and window.location do not exist during the server render.
  useEffect(() => {
    if (!address) {
      setSession(null);
      return;
    }
    setSession(readStored(address, CHAIN_ID, window.location.host));
  }, [address]);

  const ensureSession = useCallback(async (): Promise<DuelSession | null> => {
    if (!address) {
      setError('connect a wallet first.');
      return null;
    }
    const host = window.location.host;
    const existing = readStored(address, CHAIN_ID, host);
    if (existing) {
      setSession(existing);
      return existing;
    }

    setIsSigning(true);
    setError(null);
    try {
      const issued = Math.floor(Date.now() / 1000);
      const message = buildSessionMessage({
        wallet: address,
        chainId: CHAIN_ID,
        domain: host,
        issued,
        expires: issued + SESSION_TTL_SECONDS,
      });
      const signature = await signMessageAsync({ message });
      const next: DuelSession = { address, message, signature };
      try {
        window.localStorage.setItem(storageKey(address, CHAIN_ID), JSON.stringify(next));
      } catch {
        // Private browsing / quota. The session still works for this page view.
      }
      setSession(next);
      return next;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setError(
        /rejected|denied|User rejected/i.test(msg)
          ? 'you declined the session signature, so no fight was rolled.'
          : `could not sign the session: ${msg}`,
      );
      return null;
    } finally {
      setIsSigning(false);
    }
  }, [address, signMessageAsync]);

  const clear = useCallback(() => {
    if (address) {
      try {
        window.localStorage.removeItem(storageKey(address, CHAIN_ID));
      } catch {
        /* nothing to do */
      }
    }
    setSession(null);
  }, [address]);

  return { session, ensureSession, clear, isSigning, error, hasSession: session !== null };
}
