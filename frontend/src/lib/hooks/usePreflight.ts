'use client';

import { useCallback, useState } from 'react';
import { useAccount, usePublicClient } from 'wagmi';
import type { Abi } from 'viem';
import { CHAIN_ID } from '@/lib/env';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';

/**
 * SIMULATE THE EXACT CALL BEFORE THE WALLET EVER OPENS.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE RULE THIS ENFORCES: never send a transaction whose estimate failed,
 *   and never let a failed estimate turn into a gas number.
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Owner, after being shown "gas limit too high" for a fight that could never
 * have settled: "don't let this kind of thing happen." That message is what an
 * rpc says when it chokes on the garbage estimate a REVERTING call produces —
 * so by the time the player reads it, three layers of machinery have each
 * turned a precise fact (`BullNotInYards(16)`) into a vaguer one, ending on the
 * only detail that was actually false.
 *
 * `eth_call` against the same arguments returns the revert DATA instead, which
 * decodes to the custom error and its arguments. So the fix is to ask the
 * question that gets a real answer, and to ask it first.
 *
 * ── WHAT IT DOES AND DOES NOT BLOCK ─────────────────────────────────
 *
 * ⚠ A REVERT BLOCKS. An unreachable NODE DOES NOT. That distinction is the
 * whole reason `decodeRevert` classifies rather than just formats: a guard that
 * disabled every button on an rpc blip would be its own outage, and it would be
 * a confident one — the site would be telling players their transactions are
 * invalid when it simply could not see. `transport` therefore falls through and
 * lets the wallet try, with `decodeRevert` still standing behind it.
 *
 * ⚠ AN UNCLASSIFIABLE FAILURE **DOES** BLOCK, and that is deliberate. "We do
 * not understand this error" is not a reason to spend somebody's money on a
 * transaction we have reason to think will fail.
 *
 * ⚠ IT SIMULATES **AS THE CONNECTED WALLET** (`account`). Without that, an
 * ownership check, an allowance check and `msg.sender` all evaluate against the
 * zero address and the simulation answers a question nobody asked.
 *
 * ⚠ IT IS A GUARD, NOT THE ENFORCEMENT. Chain state can move between the
 * simulation and the confirmation, so every caller still decodes whatever the
 * wallet throws. Two layers, because one of them is a race by construction.
 */

export interface PreflightCall {
  readonly address: `0x${string}`;
  readonly abi: readonly unknown[];
  readonly functionName: string;
  readonly args?: readonly unknown[];
  /** Native value, for the calls that carry one. Omitting it on a payable call
   *  simulates a DIFFERENT transaction and can fail for the wrong reason. */
  readonly value?: bigint;
}

export type PreflightResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly error: DecodedRevert };

export function usePreflight() {
  const client = usePublicClient({ chainId: CHAIN_ID });
  const { address } = useAccount();
  const [checking, setChecking] = useState(false);

  const preflight = useCallback(
    async (call: PreflightCall, fallback?: string): Promise<PreflightResult> => {
      // No client or no wallet: there is nothing meaningful to simulate, and
      // refusing here would block the app on our own missing config rather
      // than on anything about the call. The caller's own guards already
      // require a connected account before this point.
      if (!client || !address) return { ok: true };
      setChecking(true);
      try {
        await client.simulateContract({
          address: call.address,
          abi: call.abi as Abi,
          functionName: call.functionName,
          args: call.args ? [...call.args] : undefined,
          value: call.value,
          account: address,
        });
        return { ok: true };
      } catch (e) {
        const decoded = decodeRevert(e, fallback);
        // See the header: a node we could not reach has told us nothing.
        if (decoded.kind === 'transport') return { ok: true };
        return { ok: false, error: decoded };
      } finally {
        setChecking(false);
      }
    },
    [client, address],
  );

  return { preflight, checking };
}
