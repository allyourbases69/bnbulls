'use client';

import { useState, type ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { getWagmiConfig } from '@/lib/wagmi';
import { WrongNetworkBanner } from '@/components/shared/WrongNetworkBanner';

export function Providers({ children }: { children: ReactNode }) {
  // One QueryClient per browser session, not per render — react-query owns
  // caching/retry for RPC reads. `retry: 1` on its own backoff clock, never
  // a raw fixed sleep an angry RPC could stretch out (see wagmi.ts).
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: { retry: 1, refetchOnWindowFocus: false },
        },
      }),
  );
  const [config] = useState(() => getWagmiConfig());

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <WrongNetworkBanner />
        {children}
      </QueryClientProvider>
    </WagmiProvider>
  );
}
