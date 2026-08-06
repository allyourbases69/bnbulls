import type { NextConfig } from 'next';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dirname = path.dirname(fileURLToPath(import.meta.url));

// bnbulls frontend scaffold. Deliberately minimal — no image domains, no
// rewrites, nothing that assumes a deployed contract. Add config here as
// real needs show up (token image API routes, etc), not speculatively.
const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Pins file tracing to this project. Without it, Next scans upward for the
  // nearest lockfile and can land on an unrelated one elsewhere on disk in a
  // multi-project machine, which is noisy and occasionally wrong.
  outputFileTracingRoot: dirname,
  eslint: {
    // lint is its own script (`npm run lint`) and its own CI gate. `next
    // build`'s type-checking step is the one that must stay strict; keeping
    // lint out of the build means a lint-only nit (unused var, hook dep)
    // can't block a build that is otherwise correct.
    ignoreDuringBuilds: true,
  },
  webpack(config, { webpack }) {
    // `wagmi/connectors` is a single barrel file that unconditionally
    // re-exports every connector, not just the two we use (`injected`,
    // `walletConnect`). Webpack has to resolve every import reachable from
    // that barrel before it can tree-shake unused exports, so three
    // optional, platform-specific peer deps that are genuinely dead code
    // for a browser-only dapp fail (or warn on) the build:
    //   - `@x402/*`                          — baseAccount → @coinbase/cdp-sdk's
    //                                           payment-protocol subpackages
    //   - `@react-native-async-storage/*`     — metaMask connector's React
    //                                           Native storage adapter
    //   - `pino-pretty`                       — walletConnect's dev-only
    //                                           pretty console logger
    // Telling webpack to treat these as empty modules is safe: nothing in
    // this app calls baseAccount() or the metaMask-SDK mobile deep link
    // path, and pino works fine without the pretty transport. Re-check
    // whether this is still needed next time wagmi/@wagmi/connectors bumps.
    config.plugins.push(
      new webpack.IgnorePlugin({
        resourceRegExp: /^(@x402\/|@react-native-async-storage\/async-storage$|pino-pretty$)/,
      }),
    );
    return config;
  },
};

export default nextConfig;
