'use client';

import { useMemo } from 'react';
import { useReadContracts } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useMintedBulls } from './useMintedBulls';

/**
 * Token ids currently sitting in the graveyard.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠⚠ THIS DELIBERATELY DOES NOT READ LOGS. IT USED TO, AND THE PAGE WAS EMPTY.
 * ═══════════════════════════════════════════════════════════════════════════
 * The old version scanned `Duel`'s `BullDied` event through `useContractLogs`
 * and re-checked each candidate's `isDead()`. On 2026-08-11 the butcher page
 * sat on "checking the yard..." forever with #24 and #26 genuinely dead on
 * chain, and the reason is that TWO OF THE FOUR CONFIGURED RPC ENDPOINTS HAVE
 * `eth_getLogs` TURNED OFF ENTIRELY:
 *
 *   bsc-dataseed1.defibit.io    HTTP 200, body {"error":{"code":-32005,
 *   bsc-dataseed.bnbchain.org                  "message":"limit exceeded"}}
 *
 * At EVERY range. A ten-block window is refused exactly like a five-thousand
 * block one, so it is not a range cap at all, it is "this node does not serve
 * logs". `useContractLogs.isRangeCapped()` matches on /exceed/ and therefore
 * reads it as "too wide", halves the chunk and retries, all the way down to
 * MIN_CHUNK. That is ~5 doomed attempts per chunk across 40 chunks, and the
 * resulting request storm got `bsc-rpc.publicnode.com` — the one endpoint that
 * DOES serve logs — to answer 403, while `bsc.drpc.org` answered 429. The tab
 * ground so hard the renderer stopped responding to CDP.
 *
 * ── the fix is to stop needing logs ───────────────────────────────────────
 * `useMintedBulls` already enumerates every circulating bull with PLAIN
 * CONTRACT READS (`nextTokenId` + `kingMinted`, minus `BullPen.poolIds()`),
 * which is why the leaders, ranks and browse pages all render fine on the same
 * RPC set that breaks this one. `eth_call` is served by every endpoint; only
 * `eth_getLogs` is not. So ask each circulating bull whether it is dead and
 * believe the answer.
 *
 * This is also simply MORE CORRECT than the log scan was, in three ways:
 *
 *   1. The old scan covered MAX_CHUNKS x CHUNK_SIZE = 200,000 blocks. BSC is
 *      at roughly 0.45s per block, so that window is about 25 hours — NOT the
 *      "roughly two days" the constant's comment assumes at 0.75s. A death
 *      older than that silently left the graveyard.
 *   2. It only ever watched the CURRENT `Duel`. The native migration replaced
 *      that contract, so every death on the retired one was invisible forever.
 *   3. `BullDied` is emitted by the Duel. `isDead` is the state the Graveyard
 *      actually charges against. Reading the state cannot disagree with itself.
 *
 * ⚠ DO NOT "OPTIMISE" THIS BACK ONTO EVENTS. A dead bull that does not show up
 * here is a bull nobody can revive, which is money the game silently refuses.
 */
export function useDeadBulls() {
  const bullsAddress = contractAddress('bullsNft');
  const minted = useMintedBulls();

  const {
    data: deadFlags,
    isLoading: loadingFlags,
  } = useReadContracts({
    contracts: minted.ids.map((id) => ({
      address: bullsAddress ?? undefined,
      abi: BullsAbi,
      functionName: 'isDead' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: !!bullsAddress && minted.ids.length > 0, refetchInterval: 30_000 },
  });

  const deadIds = useMemo(() => {
    if (!deadFlags) return [];
    return minted.ids.filter(
      (_, i) => deadFlags[i]?.status === 'success' && deadFlags[i]?.result === true,
    );
  }, [deadFlags, minted.ids]);

  /**
   * ⚠ `incomplete` IS KEPT, AND IT STILL MEANS SOMETHING. The panel prints a
   * "this list may be partial" caveat off it. It can no longer be true because
   * a log window was too short — that failure is gone — but it IS true when the
   * roster read itself did not land, because then `ids` is empty for a reason
   * that is not "nobody has died". Saying nothing there would present a failed
   * read as an empty graveyard, which is the exact bug this rewrite fixes.
   */
  const incomplete = minted.unavailable
    || (!!bullsAddress && minted.ids.length > 0 && !!deadFlags
      && deadFlags.some((f) => f?.status !== 'success'));

  return {
    deadIds,
    isLoading: !!bullsAddress && (minted.isLoading || (minted.ids.length > 0 && loadingFlags)),
    incomplete,
    deployed: !!bullsAddress && minted.deployed,
  };
}
