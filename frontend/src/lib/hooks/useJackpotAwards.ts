'use client';

import { useMemo } from 'react';
import { JackpotAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { useContractLogs } from './useContractLogs';

export interface JackpotAward {
  winner: `0x${string}`;
  tokenId: bigint;
  amount: bigint;
  ticketId: bigint;
  blockNumber: bigint;
  txHash: `0x${string}`;
}

/** Every `Awarded` payout a jackpot has ever made — the receipt trail. This
 *  is the concrete half of "no withdraw function, for anyone, including us":
 *  the only way money has ever left either pot is a logged, on-chain win. */
export function useJackpotAwards(name: 'jackpotBnbull' | 'jackpotBnb') {
  const address = contractAddress(name);

  const { data: logsResult, isLoading } = useContractLogs({
    address,
    abi: JackpotAbi,
    eventName: 'Awarded',
    enabled: !!address,
  });

  const awards = useMemo<JackpotAward[]>(() => {
    if (!logsResult) return [];
    const out = logsResult.logs
      .map((log) => {
        const l = log as {
          args?: { winner?: `0x${string}`; tokenId?: bigint; amount?: bigint; ticketId?: bigint };
          blockNumber?: bigint;
          transactionHash?: `0x${string}`;
        };
        if (!l.args?.winner || l.args.tokenId === undefined || l.args.amount === undefined) return null;
        return {
          winner: l.args.winner,
          tokenId: l.args.tokenId,
          amount: l.args.amount,
          ticketId: l.args.ticketId ?? 0n,
          blockNumber: l.blockNumber ?? 0n,
          txHash: l.transactionHash ?? ('0x' as `0x${string}`),
        };
      })
      .filter((x): x is JackpotAward => x !== null);
    out.sort((a, b) => (a.blockNumber > b.blockNumber ? -1 : a.blockNumber < b.blockNumber ? 1 : 0));
    return out;
  }, [logsResult]);

  return {
    awards,
    isLoading: !!address && isLoading,
    incomplete: logsResult?.incomplete ?? false,
    deployed: !!address,
  };
}
