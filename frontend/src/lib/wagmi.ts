/**
 * wagmi v2 config, chain 56 only.
 *
 * RPC transport shape (timeout + retryCount 0 on both the http child and the
 * fallback wrapper) is carried over from the fighting fefers frontend, where
 * it was tuned against real sick-endpoint measurements: a dead endpoint that
 * gets retried before failover can turn one bad RPC into a multi-minute
 * hang. Each endpoint here gets exactly one attempt; the pool gets exactly
 * one sweep. Retrying belongs to react-query, on its own backoff clock.
 */
import { createConfig, http, fallback } from 'wagmi';
import { injected, walletConnect } from 'wagmi/connectors';
import type { CreateConnectorFn } from 'wagmi';
import { bnbChain } from './chain';
import { rpcUrls, siteUrl, walletConnectProjectId } from './env';

const RPC_TIMEOUT_MS = 8_000;

let cached: ReturnType<typeof createConfig> | null = null;

export function getWagmiConfig() {
  if (cached) return cached;

  const chain = bnbChain();
  const urls = rpcUrls();

  const transport = fallback(
    urls.map((u) => http(u, { timeout: RPC_TIMEOUT_MS, retryCount: 0 })),
    { rank: false, retryCount: 0 },
  );

  const connectors: CreateConnectorFn[] = [
    // Covers legacy `window.ethereum` and is the fallback for wallets that
    // don't yet announce via EIP-6963 (MetaMask, Rabby, Binance Wallet, etc
    // that DO announce show up automatically through wagmi's discovery).
    injected({ shimDisconnect: true }),
  ];
  const wcProjectId = walletConnectProjectId();
  if (wcProjectId) {
    connectors.push(
      walletConnect({
        projectId: wcProjectId,
        metadata: {
          name: 'BNBulls',
          description: 'Bull gladiator PvP on BNB Chain',
          url: siteUrl(),
          icons: [`${siteUrl()}/icon.png`],
        },
        showQrModal: true,
      }),
    );
  }

  cached = createConfig({
    chains: [chain],
    connectors,
    transports: { [chain.id]: transport },
    // Defers localStorage rehydrate to a post-mount effect so the server
    // render and the first client render agree on "disconnected" — avoids a
    // hydration mismatch for a returning, already-connected visitor.
    ssr: true,
  });

  return cached;
}
