/**
 * Server-only env for the duel routes.
 *
 * ⚠ NOTHING IN HERE MAY REACH THE BROWSER. The signing key is the sole
 * authority on every fight result in the game: whoever holds it can mint a
 * signed win for any pair of bulls, up to each asset's `maxFightCostOf`. It is
 * read from `BNBULLS_SIGNER_KEY` — deliberately WITHOUT the `NEXT_PUBLIC_`
 * prefix, which is the only thing that decides whether Next inlines a variable
 * into the client bundle. `assertServerOnly()` below fails loudly if anyone
 * ever "fixes" that by adding the prefix, and this module is imported only by
 * route handlers under `app/api` that are pinned to `runtime = 'nodejs'`.
 *
 * Addresses come from the same `NEXT_PUBLIC_*` vars the browser reads
 * (`lib/env.ts`), because they are public facts and duplicating them would let
 * the two halves drift onto different deployments. **No address is invented
 * here**: an unset var yields `null` and the route answers with an honest
 * "not deployed" rather than pointing at a placeholder.
 */
import { defineChain, type Chain } from 'viem';
import { CHAIN_ID, contractAddress, rpcUrls } from './env';

/**
 * How long a signed result stays submittable.
 *
 * SHORT ON PURPOSE, and shorter than the ten minutes Fighting Fefers used. The
 * BNB leg of a fight is priced through the Chainlink BNB/USD feed at quote time
 * and then FROZEN into the signature (`Duel.DuelResult.stakeA/stakeB` are the
 * exact amounts charged — the contract never re-reads `fightCostOf`). On
 * Stable that was free, because the gas token was the dollar and never moved.
 * On BNB the number the player agreed to drifts away from the dollar it was
 * meant to be from the moment it is signed, so the window is the drift budget.
 * Three minutes is comfortably enough for a wallet to confirm, broadcast and
 * mine on BSC (~0.75s blocks) and short enough that ordinary volatility cannot
 * turn a $5 fight into a $6 one.
 *
 * Tunable through `DUEL_SIGNATURE_TTL_SECONDS` within a hard bound, per the
 * "player-facing numbers are bounded settings, never bare constants" rule in
 * `BNBULLS-BOOTSTRAP.md §0`.
 */
export const DEFAULT_DUEL_EXPIRY_SECONDS = 180;
export const MIN_DUEL_EXPIRY_SECONDS = 30;
/**
 * ⚠ THIS NUMBER IS HALF OF AN ON-CHAIN SAFETY PROPERTY. DO NOT RAISE IT ALONE.
 *
 * `Yards.MIN_EJECT_DELAY` — the floor on how long taking a bull out of the
 * yards takes to bite — is pinned to exactly this value, because an eject that
 * bit SOONER than a signature can expire would let a player cancel a fight they
 * could already see themselves losing in the mempool. The invariant is
 * `Yards.MIN_EJECT_DELAY >= MAX_DUEL_EXPIRY_SECONDS`, always.
 *
 * `MIN_EJECT_DELAY` is a Solidity `constant`, so raising this number is not a
 * config change — it requires REDEPLOYING AND REWIRING `Yards`, and the wire
 * into `Duel` is timelocked (24h). Raise the floor and get it live FIRST, then
 * raise this. `test/DuelYards.t.sol` reads this file and fails if the two
 * disagree, so `forge test` is the thing that catches the mistake.
 *
 * Was 900 at launch. Lowered to 300 with the matching `Yards` redeploy: the
 * ceiling was sized for a worst case nobody runs (the value actually in use is
 * the 180s default above), and the eject delay it forced was 5x longer than the
 * safety property needed.
 */
export const MAX_DUEL_EXPIRY_SECONDS = 300;

export function duelExpirySeconds(): number {
  const raw = process.env.DUEL_SIGNATURE_TTL_SECONDS?.trim();
  if (!raw || !/^\d+$/.test(raw)) return DEFAULT_DUEL_EXPIRY_SECONDS;
  const n = Number(raw);
  if (n < MIN_DUEL_EXPIRY_SECONDS || n > MAX_DUEL_EXPIRY_SECONDS) {
    return DEFAULT_DUEL_EXPIRY_SECONDS;
  }
  return n;
}

/**
 * Guard against the one configuration mistake that would be catastrophic and
 * silent: exposing the signing key to the bundle by renaming the variable.
 */
function assertServerOnly(): void {
  for (const key of Object.keys(process.env)) {
    if (key.startsWith('NEXT_PUBLIC_') && /SIGNER_KEY|PRIVATE_KEY/i.test(key)) {
      throw new Error(
        `${key} is prefixed NEXT_PUBLIC_, which ships it to every browser that ` +
          'loads the site. The duel signing key is server-only. Rename it to ' +
          'BNBULLS_SIGNER_KEY and rotate the exposed key immediately.',
      );
    }
  }
}

export interface ServerDuelEnv {
  readonly chainId: number;
  readonly rpcUrl: string;
  readonly bullsAddress: `0x${string}`;
  readonly duelAddress: `0x${string}`;
  /* ⚠ NO `mintDropAddress` HERE ANY MORE. The signer used to read
   * `MintDrop.bnbUsdPrice()` itself, because `Duel` had no oracle and the BNB
   * fight price had to be reconstructed off chain from the stablecoin's dollar
   * anchor. `DECISIONS.md §26` deleted the stablecoin and moved the whole
   * conversion into `Duel.stickerCost()`, so the signer now reads
   * `Duel.fighterCost()` and nothing else. Carrying a nullable address nobody
   * reads, under a comment describing behaviour that no longer exists, is how
   * the next person gets misled. */
  /** Null disables the listing pre-check. `Duel._validate` enforces it anyway. */
  readonly marketplaceAddress: `0x${string}` | null;
  readonly signerKey: `0x${string}`;
}

export type ServerDuelEnvResult =
  | { readonly ok: true; readonly env: ServerDuelEnv }
  | { readonly ok: false; readonly errors: readonly string[] };

/**
 * Validate everything the signer needs. Returns a list of what is missing
 * rather than throwing, so a route can answer with a 500 naming the gap instead
 * of a stack trace — pre-deploy that list is the honest state of the world, not
 * a bug.
 */
export function validateServerDuelEnv(): ServerDuelEnvResult {
  assertServerOnly();

  const errors: string[] = [];

  const urls = rpcUrls();
  const rpcUrl = urls[0];
  if (!rpcUrl) errors.push('NEXT_PUBLIC_RPC_URL (no usable rpc endpoint)');

  const bullsAddress = contractAddress('bullsNft');
  if (!bullsAddress) errors.push('NEXT_PUBLIC_BULLS_NFT');

  const duelAddress = contractAddress('duel');
  if (!duelAddress) errors.push('NEXT_PUBLIC_DUEL');

  // Chain-scoped first, matching the address convention: each deployment has
  // its own `Duel.trustedSigner`, and signing an anvil duel with the mainnet
  // key produces a signature the contract rejects.
  const rawKey =
    process.env[`BNBULLS_SIGNER_KEY_${CHAIN_ID}`]?.trim() ||
    process.env.BNBULLS_SIGNER_KEY?.trim();
  if (!rawKey) errors.push(`BNBULLS_SIGNER_KEY_${CHAIN_ID} (or BNBULLS_SIGNER_KEY)`);

  if (errors.length > 0) return { ok: false, errors };

  const prefixed = (rawKey!.startsWith('0x') ? rawKey! : `0x${rawKey!}`) as `0x${string}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(prefixed)) {
    return { ok: false, errors: ['BNBULLS_SIGNER_KEY is not a 32-byte hex private key'] };
  }

  return {
    ok: true,
    env: {
      chainId: CHAIN_ID,
      rpcUrl: rpcUrl!,
      bullsAddress: bullsAddress!,
      duelAddress: duelAddress!,
      marketplaceAddress: contractAddress('marketplace'),
      signerKey: prefixed,
    },
  };
}

/** The chain the server talks to. Mirrors `lib/chain.ts` but takes the single
 *  primary rpc, because a server route has no wallet to fall back through. */
export function serverChain(env: ServerDuelEnv): Chain {
  return defineChain({
    id: env.chainId,
    name: 'BNB Smart Chain',
    nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
    rpcUrls: { default: { http: rpcUrls() } },
    testnet: false,
  });
}
