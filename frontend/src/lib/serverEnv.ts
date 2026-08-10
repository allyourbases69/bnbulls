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
import { defineChain, fallback, http, type Chain, type Transport } from 'viem';
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

/**
 * Endpoints only the SERVER may talk to, best first.
 *
 * ⚠ DELIBERATELY **NOT** `NEXT_PUBLIC_`. A keyed archive url is a credential:
 * anything with the `NEXT_PUBLIC_` prefix is inlined into the client bundle at
 * build time (`lib/env.ts` explains the mechanism), so putting the key there
 * would hand it to every visitor and the bill would arrive by morning. This is
 * read at REQUEST time inside a `runtime = 'nodejs'` route and never leaves the
 * server.
 *
 * Comma-separated, so a spare can be listed behind the primary. Unset is a
 * supported state: the public pool below still answers, it just cannot serve
 * pre-fight state (see `hasPrivateRpc`).
 */
function privateRpcUrls(): string[] {
  const raw =
    process.env[`BNBULLS_RPC_URL_${CHAIN_ID}`]?.trim() ||
    process.env.BNBULLS_RPC_URL?.trim() ||
    '';
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/**
 * True when a private endpoint is configured, which is the only realistic way
 * to read state at an OLD block. Every free public BSC endpoint refuses:
 * measured 2026-08-10, the dataseeds answer `-32000 missing trie node` and
 * publicnode answers `403 Archive requests require a personal token`.
 *
 * The replay path uses this to decide whether attempting a pinned read is worth
 * it at all. Without it the attempt is not merely slow, it is 4 reads x 4 dead
 * endpoints x viem's retries before it can give up and fall back to head state,
 * on a route a player is sitting and waiting on.
 */
export function hasPrivateRpc(): boolean {
  return privateRpcUrls().length > 0;
}

/**
 * ⚠ THE SERVER'S RPC POOL IS NOT THE BROWSER'S, AND THAT IS THE WHOLE BUG THIS
 * FUNCTION EXISTS TO FIX.
 *
 * Both halves used to share `rpcUrls()` from `lib/env.ts` and both took entry
 * [0] — `https://bsc-rpc.publicnode.com`. That endpoint is genuinely the best
 * of the free four **for what the browser does**: it is the only one that will
 * serve a wide `eth_getLogs`, which is what `/history`, the graveyard and the
 * pots need, and it was picked for exactly that reason on launch day.
 *
 * But it classifies `eth_getTransactionReceipt` as an ARCHIVE request and 403s
 * it, unconditionally, even for a transaction in the head block. Measured
 * 2026-08-10 against a real duel:
 *
 *   endpoint                    getLogs(wide)   getTransactionReceipt   call@old
 *   bsc-rpc.publicnode.com      ok (~7k back)   403 archive-token       403
 *   bsc.drpc.org                ok when calm    429 public rate limit   500
 *   bsc-dataseed1.defibit.io    -32005          ok                      -32000
 *   bsc-dataseed.bnbchain.org   -32005          ok                      -32000
 *   private/archive (below)     (key-capped)    ok                      ok
 *
 * `getTransactionReceipt` is used in exactly ONE place in this codebase —
 * `lib/duelReplaySource.ts`, the first thing a replay does — so publicnode's
 * one gap took out the replay of every fight ever, on a site where 100% of
 * fights were being signed and settled perfectly. Nothing else noticed,
 * because nothing else asks for a receipt.
 *
 * So the order here is the MEASURED order for what the server actually does,
 * not a copy of the browser's:
 *   1. the private endpoint, if configured — the only one that can do both
 *   2. the two dataseeds — they serve receipts, and that is what a replay needs
 *   3. publicnode — a working head-state read if the dataseeds go down
 *   4. drpc — last, it spends most of the day rate-limited
 *
 * `serverTransport` wraps this in viem's `fallback`, so a refusal at one entry
 * steps to the next instead of ending the request. A single `http()` cannot do
 * that, and a single `http()` is what shipped.
 */
export function serverRpcUrls(): string[] {
  const all = [
    ...privateRpcUrls(),
    'https://bsc-dataseed1.defibit.io',
    'https://bsc-dataseed.bnbchain.org',
    ...rpcUrls(),
  ];
  return all.filter((u, i) => all.indexOf(u) === i);
}

/**
 * One client transport over the whole pool.
 *
 * ⚠ `fallback` ADVANCES ON A REFUSAL, WHICH IS THE POINT. viem only rethrows
 * immediately for a rejected transaction or a rejected wallet prompt; a 403, a
 * 429 or a `-32005` walks to the next endpoint. That is what turns "publicnode
 * will not serve receipts" from an outage into a shrug.
 *
 * `retryCount: 1` because this pool already has four ways to be right. The
 * default of 3 re-walks the ENTIRE list three more times when every entry
 * fails, which on a player-facing route is a minute of nothing.
 */
export function serverTransport(urls: readonly string[] = serverRpcUrls()): Transport {
  return fallback(
    urls.map((u) => http(u)),
    { retryCount: 1 },
  );
}

export interface ServerDuelEnv {
  readonly chainId: number;
  /** The pool, best first. Build a client with `serverTransport(env.rpcUrls)` —
   *  never `http(urls[0])`, which is the single point of failure that broke
   *  every replay on 2026-08-10. */
  readonly rpcUrls: readonly string[];
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

  const urls = serverRpcUrls();
  if (urls.length === 0) errors.push('NEXT_PUBLIC_RPC_URL (no usable rpc endpoint)');

  const bullsAddress = contractAddress('bullsNft');
  if (!bullsAddress) errors.push('NEXT_PUBLIC_BULLS_NFT');

  const duelAddress = contractAddress('duel');
  if (!duelAddress) errors.push('NEXT_PUBLIC_DUEL');

  // Chain-scoped first, matching the address convention: each deployment has
  // its own `Duel.trustedSigner`, and signing an anvil duel with the mainnet
  // key produces a signature the contract rejects.
  const rawKey =
    process.env[`BNBULLS_SIGNER_KEY_${CHAIN_ID}`]?.trim() ||
    process.env.BNBULLS_SIGNER_KEY?.trim() ||
    // launch hotfix (2026-08-09): the SAME trusted signer (0xe9c4..5536) serves
    // both chains, and only BNBULLS_SIGNER_KEY_97 was set in prod. Fall back to it
    // so chain-56 duels can be signed. TODO: set BNBULLS_SIGNER_KEY_56 in Vercel
    // and drop this fallback.
    process.env.BNBULLS_SIGNER_KEY_97?.trim();
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
      rpcUrls: urls,
      bullsAddress: bullsAddress!,
      duelAddress: duelAddress!,
      marketplaceAddress: contractAddress('marketplace'),
      signerKey: prefixed,
    },
  };
}

/**
 * The chain the server talks to. Mirrors `lib/chain.ts`, but carries the
 * SERVER pool rather than the browser one — see `serverRpcUrls` for why the two
 * are ordered differently.
 *
 * ⚠ The url list on a `Chain` is only a default for a client built without an
 * explicit transport. It is NOT a fallback: a client built with `http(one_url)`
 * talks to that one url and nothing else, no matter what this says. Pair it
 * with `serverTransport()`.
 */
export function serverChain(env: ServerDuelEnv): Chain {
  return defineChain({
    id: env.chainId,
    name: 'BNB Smart Chain',
    nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
    rpcUrls: { default: { http: [...env.rpcUrls] } },
    testnet: false,
  });
}
