/**
 * BNB Smart Chain. **Mainnet (56) by default**, testnet (97) only when
 * `NEXT_PUBLIC_CHAIN_ID=97` is set explicitly — see `CHAIN_ID` in `env.ts`,
 * which never falls back to a testnet.
 *
 * Native currency is BNB, 18 decimals, volatile — NOT a dollar. Do not carry
 * over any "native == dollar" assumption from the fighting fefers "stable"
 * fork (BNB-CHAIN-FACTS.md §1, DECISIONS.md §3). Dollar-denominated prices on
 * this site are display-only estimates unless/until they're read from the
 * chainlink BNB/USD feed by a deployed contract.
 */
import { defineChain, type Chain } from 'viem';
import { CHAIN_ID, IS_TESTNET, explorerBaseUrl, rpcUrls } from './env';

export const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11' as const;

export function bnbChain(): Chain {
  const urls = rpcUrls();
  return defineChain({
    id: CHAIN_ID,
    name: IS_TESTNET ? 'BNB Smart Chain Testnet' : 'BNB Smart Chain',
    nativeCurrency: {
      name: 'BNB',
      symbol: 'BNB',
      decimals: 18,
    },
    rpcUrls: {
      default: { http: urls },
    },
    blockExplorers: {
      default: { name: IS_TESTNET ? 'BscScan Testnet' : 'BscScan', url: explorerBaseUrl() },
    },
    contracts: {
      multicall3: {
        address: MULTICALL3_ADDRESS,
        blockCreated: 0,
      },
    },
    testnet: IS_TESTNET,
  });
}
