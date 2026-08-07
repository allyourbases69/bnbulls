/**
 * Env reads for the bnbulls frontend. Everything here is `NEXT_PUBLIC_*`
 * because it all needs to reach the browser bundle (chain config, contract
 * addresses for read calls, social links) — there is no server-only secret
 * in this scaffold yet.
 *
 * ⚠ Contract addresses are read, never invented. `BNB-CHAIN-FACTS.md` and the
 * package brief are explicit: nothing is deployed yet, so every address getter
 * below returns `null` on an unset/empty env var rather than a placeholder
 * string. A placeholder that later looks like a real address is exactly the
 * kind of real-money bug this file exists to prevent.
 */

/**
 * The chain this build targets. **56 (BNB mainnet) unless explicitly told
 * otherwise** — a missing or unparseable value falls back to mainnet, never
 * to a testnet, so a config slip can never quietly point real users at play
 * money.
 *
 * Only 56 and 97 are accepted. Anything else is a typo, and a typo here would
 * mean wallet prompts for a chain that does not exist.
 */
export const CHAIN_ID: 56 | 97 = (() => {
  const raw = process.env.NEXT_PUBLIC_CHAIN_ID?.trim();
  return raw === '97' ? 97 : 56;
})();

/** True when this build points at BSC testnet. Drives the site-wide banner:
 *  a testnet build that LOOKS like mainnet is how someone wastes real money
 *  trying to buy a bull that does not exist. */
export const IS_TESTNET = CHAIN_ID === 97;

function readList(value: string | undefined): string[] {
  if (!value) return [];
  return value
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/** RPC pool: env-configured primary + fallback first, de-duplicated. Never
 *  the bare dataseed as the sole entry — see BNB-CHAIN-FACTS.md §2. */
export function rpcUrls(): string[] {
  const primary = readList(process.env.NEXT_PUBLIC_RPC_URL);
  const fallback = readList(process.env.NEXT_PUBLIC_RPC_URL_FALLBACK);
  const defaults = ['https://bsc-rpc.publicnode.com', 'https://bsc.drpc.org'];
  const all = [...primary, ...fallback, ...defaults];
  return all.filter((u, i) => all.indexOf(u) === i);
}

export function explorerBaseUrl(): string {
  return process.env.NEXT_PUBLIC_EXPLORER_BASE_URL?.trim() || 'https://bscscan.com';
}

export function walletConnectProjectId(): string | null {
  const id = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim();
  return id ? id : null;
}

export function siteUrl(): string {
  return process.env.NEXT_PUBLIC_SITE_URL?.trim() || 'https://bnbulls.xyz';
}

export function xUrl(): string {
  return process.env.NEXT_PUBLIC_X_URL?.trim() || 'https://x.com/WeAreBNBulls';
}

export function telegramUrl(): string {
  return process.env.NEXT_PUBLIC_TELEGRAM_URL?.trim() || 'https://t.me/WeAreBNBulls';
}

/**
 * The source repo, or `null` to hide the link entirely.
 *
 * ⚠ THE REPO IS PRIVATE. A "read the code" link that 404s for everyone is
 * worse than no link at all — it reads as a broken promise on the one subject
 * where we are asking to be trusted. Set `NEXT_PUBLIC_GITHUB_URL=` (empty) to
 * hide it until the repo is public.
 */
export function githubUrl(): string | null {
  const raw = process.env.NEXT_PUBLIC_GITHUB_URL;
  if (raw !== undefined) return raw.trim() || null;
  return 'https://github.com/allyourbases69/bnbulls';
}

/** Block the game contracts deployed at, or `null` when unset. Used to bound
 *  `getLogs` scans (recent jackpot awards, the graveyard's dead-bull list) so
 *  they never have to walk from genesis on a public RPC that caps range —
 *  see `BNB-CHAIN-FACTS.md §2`. Absence means "scan from a short recent
 *  lookback window" rather than "scan everything", which is the safe default
 *  on an unbounded free-tier node. */
export function deployBlock(): bigint | null {
  const raw = process.env.NEXT_PUBLIC_DEPLOY_BLOCK?.trim();
  if (!raw || !/^\d+$/.test(raw)) return null;
  return BigInt(raw);
}

/**
 * Every contract this app reads from, mapped to its address.
 *
 * ⚠ EACH VALUE IS A LITERAL `process.env.NEXT_PUBLIC_X`, ONE PER LINE, AND THAT
 * IS LOAD-BEARING — DO NOT "TIDY" IT INTO A LOOKUP.
 *
 * Next.js inlines `process.env.NEXT_PUBLIC_*` into the client bundle at BUILD
 * time by literal textual substitution, so it can only replace references it
 * can actually see. This map used to hold the KEY NAMES and be read with
 * `process.env[CONTRACT_ENV_KEYS[name]]` — a dynamic lookup webpack cannot
 * substitute. The consequence was total and silent:
 *
 *   in EVERY production build, `process.env` is an empty object in the browser,
 *   so every address resolved to `null` and every panel rendered its calm
 *   "not deployed yet" state — mint, market, graveyard, pots, all of them.
 *
 * It worked perfectly under `next dev`, which populates `process.env` at
 * runtime, and that is exactly why it survived to a deployed site: the failure
 * exists only in a real build. `CHAIN_ID` and `explorerBaseUrl()` were fine
 * throughout because they read their vars statically, which is what made the
 * deployed site look correctly configured while every contract was missing.
 */
const CONTRACT_ADDRESSES: Record<string, string | undefined> = {
  bnbullToken: process.env.NEXT_PUBLIC_BNBULL_TOKEN,
  bullsNft: process.env.NEXT_PUBLIC_BULLS_NFT,
  mintDrop: process.env.NEXT_PUBLIC_MINTDROP,
  duel: process.env.NEXT_PUBLIC_DUEL,
  graveyard: process.env.NEXT_PUBLIC_GRAVEYARD,
  jackpotBnbull: process.env.NEXT_PUBLIC_JACKPOT_BNBULL,
  jackpotBnb: process.env.NEXT_PUBLIC_JACKPOT_BNB,
  marketplace: process.env.NEXT_PUBLIC_MARKETPLACE,
};

export type ContractName =
  | 'bnbullToken'
  | 'bullsNft'
  | 'mintDrop'
  | 'duel'
  | 'graveyard'
  | 'jackpotBnbull'
  | 'jackpotBnb'
  | 'marketplace';

/** A 0x-prefixed address, or null when the env var is unset/empty/malformed.
 *  Deliberately returns null rather than throwing — the whole app has to
 *  render a calm "not deployed yet" state, not crash on a page load before
 *  the contracts exist. */
export function contractAddress(name: ContractName): `0x${string}` | null {
  const raw = CONTRACT_ADDRESSES[name]?.trim();
  if (!raw) return null;
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) return null;
  return raw as `0x${string}`;
}

/** True once every contract this feature needs has a real address. Use this
 *  to gate a UI between "loading / coming" copy and the real thing — never
 *  branch on a single address in isolation, or a partial deploy renders a
 *  half-wired page. */
export function contractsDeployed(...names: ContractName[]): boolean {
  return names.every((n) => contractAddress(n) !== null);
}
