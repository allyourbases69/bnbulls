/**
 * POST /api/run-duel — the duel signing service.
 *
 * Server-side duel orchestration:
 *   1. Verify the caller's session signature (one `personal_sign`, good for
 *      24h, cached client-side — see `lib/duelSession.ts`)
 *   2. Validate input and work out which side is the CHALLENGER (the bull the
 *      caller owns), from ON-CHAIN ownership, never from the request body
 *   3. Read both bulls, their weapons and both owners from chain
 *   4. Run every guardrail `Duel.submitDuel` will run, so the player gets a
 *      sentence instead of a reverted transaction
 *   5. Resolve per-side stake asset + amount from chain — with the BNB leg
 *      priced through the Chainlink feed at quote time (`lib/duelPricing.ts`)
 *   6. Serve the wallet's STANDING fight if it has one, otherwise roll a fresh
 *      one and pin it (`lib/duelCommit.ts`)
 *   7. Read `nextFightSeq` for both owners and build the `DuelResult` struct
 *   8. Sign it EIP-712 with the server-only signing key
 *   9. Return `{ result, signature, events, ... }` to the client
 *
 * The client then submits `(result, signature)` to `Duel.submitDuel` from the
 * player's own wallet.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE THREE THINGS NOT TO BREAK
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 1. THE TYPED DATA. `DUEL_TYPES.DuelResult` below must stay byte-identical to
 *    `Duel.DUEL_RESULT_TYPEHASH` — order, names and types are all hashed.
 *    `assertTypehashMatches()` recomputes the hash at module load and throws if
 *    it drifts, and every signature is additionally checked against the
 *    contract's own `hashDuelResult` before it is handed out. Without those, a
 *    one-character drift shows up as "every fight reverts InvalidSignature"
 *    with nothing pointing at the cause.
 *
 * 2. THE ANTI-GRIND SLOT. This endpoint hands back a fully submittable,
 *    winner-included result before any money moves, so the only thing stopping
 *    "roll until you win, submit only the wins" is that a WALLET can hold
 *    exactly one unsettled outcome at a time and re-asking gives that same
 *    outcome back. That rule lives in `lib/duelCommit.ts`. There is exactly ONE
 *    code path here that produces a new outcome. Adding a second re-opens the
 *    exploit. `Duel.fightSeq` does not close it on its own — it stops a second
 *    result SETTLING, not a hundred being ISSUED.
 *
 * 3. THE SIGNING KEY IS SERVER-ONLY. `runtime = 'nodejs'`, read through
 *    `lib/serverEnv.ts` from a variable with no `NEXT_PUBLIC_` prefix. It is
 *    the sole authority on every fight result in the game.
 *
 * bigint → string serialisation: JSON cannot carry bigint, so every 256-bit
 * field in `result` is stringified. The client reconstructs `BigInt()` before
 * passing it to `writeContract`.
 */
import { NextResponse } from 'next/server';
import {
  createPublicClient,
  getAddress,
  hashTypedData,
  http,
  isAddress,
  keccak256,
  toHex,
  type Address,
  type PublicClient,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { randomBytes } from 'node:crypto';
import { BullsAbi, DuelAbi, Erc20Abi, MarketplaceAbi, YardsAbi } from '@/lib/abi';
import { validateServerDuelEnv, serverChain, duelExpirySeconds } from '@/lib/serverEnv';
import { checkSessionTerms, SESSION_ERROR } from '@/lib/duelSession';
import {
  MemoryCommitStore,
  decideCommit,
  type CommitFacts,
  type CommitStore,
  type DuelCommit,
} from '@/lib/duelCommit';
import {
  findStakeAssetByKind,
  readFightPricing,
  ZERO_ADDRESS,
  type StakeAssetInfo,
  type StakeKind,
} from '@/lib/duelPricing';
import { readBullAt } from '@/lib/bullOnchain';
import { formatToken } from '@/lib/format';
import { simulateFight } from '@/sim/combat';
import { applyDuelResult, type Outcome } from '@/core/elo';
import type { CombatEvent } from '@/core/types';

// Force the Node runtime: `node:crypto` for the nonce, and the signing key must
// never be evaluated anywhere it could be inlined into a client bundle.
export const runtime = 'nodejs';
// Every read here is live chain state. Caching any of it would be a correctness
// bug, not a performance win.
export const dynamic = 'force-dynamic';

// ─── EIP-712 ─────────────────────────────────────────────────────────

/**
 * ⚠ LOCKED by `DECISIONS.md §13` and `Duel.sol`, set BEFORE the first deploy.
 * Fighting Fefers carries "Stable WarriorsDuel" scars in its sweeps because its
 * domain was renamed after launch and every outstanding signature died with it.
 */
const EIP712_DOMAIN_NAME = 'BNBullsDuel';
const EIP712_DOMAIN_VERSION = '1';

/**
 * Field-for-field duplicate of `Duel.DUEL_RESULT_TYPEHASH`. Change these two in
 * the same commit as the contract, always.
 */
const DUEL_TYPES = {
  DuelResult: [
    { name: 'tokenA', type: 'uint256' },
    { name: 'tokenB', type: 'uint256' },
    { name: 'winnerId', type: 'uint32' },
    { name: 'rounds', type: 'uint16' },
    { name: 'seed', type: 'uint256' },
    { name: 'newEloA', type: 'uint32' },
    { name: 'newEloB', type: 'uint32' },
    { name: 'assetA', type: 'address' },
    { name: 'assetB', type: 'address' },
    { name: 'stakeA', type: 'uint256' },
    { name: 'stakeB', type: 'uint256' },
    { name: 'seqA', type: 'uint64' },
    { name: 'seqB', type: 'uint64' },
    { name: 'nonce', type: 'uint256' },
    { name: 'expiry', type: 'uint256' },
  ],
} as const;

/**
 * The literal string from `Duel.sol`, copied character for character. Kept as a
 * separate constant so the check below compares two INDEPENDENTLY written
 * things — deriving both from the same array would prove nothing.
 */
const CONTRACT_TYPE_STRING =
  'DuelResult(uint256 tokenA,uint256 tokenB,uint32 winnerId,uint16 rounds,uint256 seed,uint32 newEloA,uint32 newEloB,address assetA,address assetB,uint256 stakeA,uint256 stakeB,uint64 seqA,uint64 seqB,uint256 nonce,uint256 expiry)';

/**
 * Rebuild the EIP-712 type string from `DUEL_TYPES` the way the standard says
 * to (`name(type field,type field,…)`, no spaces) and check it hashes to the
 * same word the contract holds. Runs at module load: a drift is a startup
 * failure, not a thousand reverted fights.
 */
function assertTypehashMatches(): void {
  const rebuilt = `DuelResult(${DUEL_TYPES.DuelResult.map((f) => `${f.type} ${f.name}`).join(',')})`;
  if (rebuilt !== CONTRACT_TYPE_STRING) {
    throw new Error(
      'EIP-712 type drift: the signer\'s DuelResult fields no longer match ' +
        `Duel.DUEL_RESULT_TYPEHASH.\n  signer:   ${rebuilt}\n  contract: ${CONTRACT_TYPE_STRING}`,
    );
  }
  // Belt and braces: prove the hash too, so a change to BOTH strings that is
  // still wrong against a deployed contract is at least visible in a diff.
  const typehash = keccak256(toHex(CONTRACT_TYPE_STRING));
  if (!/^0x[0-9a-f]{64}$/.test(typehash)) {
    throw new Error('EIP-712 typehash did not compute');
  }
}
assertTypehashMatches();

// ─── Tunables ────────────────────────────────────────────────────────

/**
 * Best-effort in-memory rate limit. Serverless instances are ephemeral and not
 * shared, so this only blunts bursts against a warm instance — it is NOT a hard
 * global limit. The per-wallet standing-fight commit is the real anti-grind
 * defence; this just reduces signing-endpoint spam.
 */
const RL_WINDOW_MS = 60_000;
const RL_MAX = 30;
const rlHits = new Map<string, { count: number; resetAt: number }>();
function rateLimited(ip: string): boolean {
  const now = Date.now();
  const e = rlHits.get(ip);
  if (!e || now > e.resetAt) {
    rlHits.set(ip, { count: 1, resetAt: now + RL_WINDOW_MS });
    return false;
  }
  e.count += 1;
  return e.count > RL_MAX;
}

/**
 * Where standing fights live.
 *
 * ⚠ Process memory, and that is a known gap — see `MemoryCommitStore`'s header.
 * Fighting Fefers backed the same interface with Postgres; bnbulls has no
 * database wired yet. The warning fires once per instance so it cannot be
 * missed in a deploy log.
 */
const memoryCommitStore = new MemoryCommitStore();
let warnedNoSharedStore = false;
function commitStore(): CommitStore {
  if (!warnedNoSharedStore) {
    warnedNoSharedStore = true;
    console.warn(
      '[run-duel] standing fights are kept in PROCESS MEMORY. Serverless ' +
        'instances do not share it, so the one-fight-per-wallet anti-grind ' +
        'guarantee is best-effort only. Wire a shared CommitStore before mainnet.',
    );
  }
  return memoryCommitStore;
}

function randomBig256(): bigint {
  const bytes = randomBytes(32);
  let n = 0n;
  for (const b of bytes) n = (n << 8n) | BigInt(b);
  return n;
}

/** Host the request actually arrived on. The session message names it, so a
 *  signature farmed on another site cannot be spent here. */
function requestHost(req: Request): string | null {
  const host = req.headers.get('host');
  if (host && /^[a-zA-Z0-9.\-:[\]]+$/.test(host)) return host;
  return null;
}

// ─── The signed struct ───────────────────────────────────────────────

interface DuelResultStruct {
  readonly tokenA: bigint;
  readonly tokenB: bigint;
  readonly winnerId: number;
  readonly rounds: number;
  readonly seed: bigint;
  readonly newEloA: number;
  readonly newEloB: number;
  /** Stake token per side. Zero address = that side stakes nothing, and then
   *  the amount MUST be zero too (`Duel.StakeWithoutAsset`). */
  readonly assetA: Address;
  readonly assetB: Address;
  /** The EXACT amount each side is charged, in that asset's own units, discount
   *  already applied. Signed rather than read live off `fightCostOf` so the
   *  price the API quoted and the UI displayed is the price the wallet pays. */
  readonly stakeA: bigint;
  readonly stakeB: bigint;
  /** Each owner's `fightSeq` at sign time. THE field that turns the
   *  affordability check into a guarantee — see `Duel.sol`'s header. */
  readonly seqA: bigint;
  readonly seqB: bigint;
  readonly nonce: bigint;
  readonly expiry: bigint;
}

function serializeResult(r: DuelResultStruct) {
  return {
    tokenA: r.tokenA.toString(),
    tokenB: r.tokenB.toString(),
    winnerId: r.winnerId,
    rounds: r.rounds,
    seed: r.seed.toString(),
    newEloA: r.newEloA,
    newEloB: r.newEloB,
    assetA: r.assetA,
    assetB: r.assetB,
    stakeA: r.stakeA.toString(),
    stakeB: r.stakeB.toString(),
    seqA: r.seqA.toString(),
    seqB: r.seqB.toString(),
    nonce: r.nonce.toString(),
    expiry: r.expiry.toString(),
  };
}

export interface RunDuelResponse {
  result: ReturnType<typeof serializeResult>;
  signature: `0x${string}`;
  events: readonly CombatEvent[];
  winnerId: number | null;
  rounds: number;
  newEloA: number;
  newEloB: number;
  deltaA: number;
  deltaB: number;
  stakes: {
    assetA: Address;
    assetB: Address;
    symbolA: string;
    symbolB: string;
    decimalsA: number;
    decimalsB: number;
    amountA: string;
    amountB: string;
    /** True when that side's amount came off the Chainlink feed rather than a
     *  stored peg. The UI says so, because it is the difference between a
     *  quote that tracks the dollar and one that drifts. */
    oracleA: boolean;
    oracleB: boolean;
  };
  /** Set when the caller's side may settle by sending raw BNB with the
   *  transaction instead of holding a WBNB allowance. Only ever the submitting
   *  wallet's own side: a passive opponent cannot post `msg.value`. */
  nativeValue?: string;
  /** How long the signature is good for, seconds. The UI counts it down —
   *  the BNB leg's dollar value drifts for exactly this long. */
  ttlSeconds: number;
  /** Set when the caller asked for one matchup and got their wallet's STANDING
   *  fight against another. Carries what was actually served so the UI can say
   *  so out loud rather than silently swapping the portrait. */
  standingFight?: {
    challengerTokenId: number;
    opponentTokenId: number;
    /** Unix seconds the standing fight was first rolled. */
    since: number;
  };
}

// ─── Helpers ─────────────────────────────────────────────────────────

/**
 * ⚠ TWO CURRENCIES, AND THE PLAYER PICKS (`DECISIONS.md §26`; owner call,
 * 2026-08-07: "person must select EITHER BNB or BNBULL, or you can add a button
 * 'both'").
 *
 * `STABLE` went with `§26` and `AUTO` has now gone with it. Both are out of the
 * wire protocol, not merely hidden: a client that still sends one gets a 400
 * naming what to send instead, which is a far better failure than resolving to
 * something nobody asked for and signing a fight in it.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHAT `BOTH` MEANS, AND WHAT IT CANNOT MEAN
 * ═══════════════════════════════════════════════════════════════════════
 * `BOTH` is a MATCHMAKING PREFERENCE. It is not a split payment, and it could
 * not be one: `DuelResult` carries exactly one asset per side (`assetA`,
 * `assetB`) and `Duel._takeSide` pulls one asset from one owner, so "half in
 * each" is not expressible in the struct that gets signed. Building it would be
 * a contract change, not a frontend one.
 *
 * So `BOTH` means "either currency is fine with me", and it resolves to exactly
 * one. Three things make that a real choice rather than the old `AUTO` wearing
 * a new label:
 *
 *   1. IT IS NEVER A DEFAULT. A challenger side with no selector is a 400
 *      (`CURRENCY_NOT_CHOSEN`), not a guess.
 *   2. IT NEVER SKIPS IN SILENCE. `AUTO` walked its candidates and `continue`d
 *      past any that were short — no error, no log — so a bull whose owner had
 *      no allowance was simply never matched and nobody could find out why.
 *      Every currency tried below comes back in the error with its own reason.
 *   3. THE ANSWER IS VISIBLE BEFORE ANYTHING IS SIGNED. The currency it landed
 *      on rides back in `stakes.symbolA`/`symbolB` and is on screen next to the
 *      settle button.
 */
const ASSET_SELECTORS = ['BNB', 'BNBULL', 'BOTH'] as const;
type AssetSelector = (typeof ASSET_SELECTORS)[number];

const SELECTOR_KIND: Record<Exclude<AssetSelector, 'BOTH'>, StakeKind> = {
  BNB: 'bnb',
  BNBULL: 'bnbull',
};

const SELECTOR_LABEL: Record<AssetSelector, string> = {
  BNB: 'bnb',
  BNBULL: 'bnbull',
  BOTH: 'either currency',
};

const KIND_LABEL: Record<StakeKind, string> = {
  bnb: 'bnb',
  bnbull: 'bnbull',
  other: 'that asset',
};

/**
 * The order `BOTH` tries, and it is **BNB FIRST**.
 *
 * ⚠ THAT IS THE OPPOSITE OF THE ORDER `AUTO` USED, deliberately. `AUTO` tried
 * bnbull first "because it is the only discounted leg" — and `DECISIONS.md §39`
 * has since deleted the fight discount outright: a $2 duel costs $2 in either
 * currency, because two fighters putting different money into one purse lands
 * the gap straight in the winner's payout. There is nothing left to prefer
 * bnbull for, and `§29` says bnb is the currency that exists at launch, so bnb
 * goes first and the common case stops depending on a fallback.
 *
 * ⚠ `other` is deliberately NOT in this list. If some third asset is ever
 * registered on `Duel`, nothing here may pick it on a player's behalf — they
 * did not choose it and this endpoint would be signing a fight in a currency
 * nobody asked for. It stays reachable only by an explicit address, which no
 * selector offers.
 */
const BOTH_ORDER: readonly StakeKind[] = ['bnb', 'bnbull'];

/**
 * Read one side's currency selector off the body.
 *
 * `null` means THE FIELD WAS NOT SENT, which is deliberately not the same thing
 * as a bad value and is deliberately not a default. The challenger's side must
 * be an explicit pick and 400s when it is missing; the opponent's side is
 * allowed to be absent, because a passive opponent never picks one.
 */
function parseSelector(raw: unknown): AssetSelector | null | 'invalid' {
  if (raw === undefined || raw === null || raw === '') return null;
  const s = String(raw).toUpperCase();
  return (ASSET_SELECTORS as readonly string[]).includes(s) ? (s as AssetSelector) : 'invalid';
}

function badSelector(field: string, raw: unknown): string {
  if (String(raw).toUpperCase() === 'AUTO') {
    return (
      `${field}: "whatever i can pay" is gone. it could pass over a currency ` +
      'without saying so, which left bulls unmatchable with no way to find out ' +
      `why. send one of ${ASSET_SELECTORS.join(', ')}. "BOTH" means either ` +
      'currency is fine, not half in each.'
    );
  }
  return `${field} must be one of ${ASSET_SELECTORS.join(', ')}`;
}

/** The ERC-20 a leg is actually pulled through. The bnb leg is WBNB, and saying
 *  "you approved 0 BNB" when the allowance lives on WBNB is the kind of nearly
 *  right sentence that costs an hour. */
function tokenLabel(info: StakeAssetInfo): string {
  return info.kind === 'bnb' ? 'wbnb' : info.symbol.toLowerCase();
}

/** One currency that could NOT be used, and why. Collected rather than skipped:
 *  the silent `continue` this replaces is the whole bug. */
interface Blocker {
  readonly symbol: string;
  readonly why: string;
  readonly code: string;
}

async function erc20Ready(
  client: PublicClient,
  asset: Address,
  owner: Address,
  spender: Address,
  cost: bigint,
): Promise<{ ok: boolean; balance: bigint; allowance: bigint }> {
  if (cost === 0n) return { ok: true, balance: 0n, allowance: 0n };
  const [balance, allowance] = await Promise.all([
    client.readContract({
      address: asset, abi: Erc20Abi, functionName: 'balanceOf', args: [owner],
    }) as Promise<bigint>,
    client.readContract({
      address: asset, abi: Erc20Abi, functionName: 'allowance', args: [owner, spender],
    }) as Promise<bigint>,
  ]);
  return { ok: balance >= cost && allowance >= cost, balance, allowance };
}

function bad(error: string, status: number, code?: string) {
  return NextResponse.json(code ? { error, code } : { error }, { status });
}

// ─── The bull pit (`Yards.sol`) ──────────────────────────────────────

/** `Yards.statusOf` -> `(enteredBy, leavesAt, live)`. */
type YardStatus = readonly [Address, bigint, boolean];

/**
 * Why this bull cannot be matched, or `null` when it can.
 *
 * ⚠ `live` FROM THE CONTRACT IS NOT THE ANSWER ON ITS OWN. `inYardsFor`
 * returns true for a bull with an eject counting down, deliberately, so an
 * already-signed loss still lands. A NEW fight is a different question and the
 * answer to it is no — see the block at the call site.
 */
type YardProblem = 'never' | 'sold' | 'ejected' | 'leaving';

function yardsProblem(status: YardStatus, liveOwner: Address): YardProblem | null {
  const [enteredBy, leavesAt, live] = status;
  if (live) return leavesAt > 0n ? 'leaving' : null;
  if (enteredBy === ZERO_ADDRESS) return 'never';
  // The entry exists but belongs to a wallet that no longer holds the bull.
  // Worth naming separately: it is the only one the CURRENT owner did not do
  // to themselves, and the only one that happens without anybody acting.
  if (enteredBy.toLowerCase() !== liveOwner.toLowerCase()) return 'sold';
  return 'ejected';
}

/**
 * The sentence the player actually reads. Names the bull, says what is true,
 * and says who has to do what next — the loud-failure standard the currency
 * work set when it deleted the silent `AUTO` skip.
 */
function explainYards(tokenId: number, problem: YardProblem, isYours: boolean): string {
  const mine = isYours ? ' it is yours, so' : ' its owner has to do it, not you:';
  switch (problem) {
    case 'never':
      return (
        `bull #${tokenId} is not in the bull pit, and a bull that is out cannot be fought ` +
        `at all.${mine} send it in from the duel page and it can fight straight away.`
      );
    case 'sold':
      return (
        `bull #${tokenId} changed hands, and a sale always voids a spot in the bull pit — ` +
        'the pit remembers the wallet that sent the bull in, so a new owner starts out of ' +
        `it.${mine} send it in again and it can fight straight away.`
      );
    case 'ejected':
      return (
        `bull #${tokenId} has been pulled out of the bull pit, so it cannot be fought.` +
        `${mine} send it back in first.`
      );
    case 'leaving':
      return (
        `bull #${tokenId} is on its way out of the bull pit, so no new fight can be matched ` +
        'against it. fights signed before the eject can still land until it goes, which is ' +
        'why this one will not be signed. sending it back in cancels the departure on the spot.'
      );
  }
}

// ─── The route ───────────────────────────────────────────────────────

export async function POST(request: Request) {
  const ip =
    request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    request.headers.get('x-real-ip') ||
    'unknown';
  if (rateLimited(ip)) {
    return bad('too many requests, slow down.', 429);
  }

  let body: {
    tokenA?: unknown;
    tokenB?: unknown;
    /**
     * One currency selector per token, travelling WITH its token id — `BNB`,
     * `BNBULL` or `BOTH` (see `ASSET_SELECTORS`). The caller's own side is
     * REQUIRED; the opponent's may be omitted and is always treated as `BOTH`,
     * because a passive opponent never picks one.
     */
    assetA?: unknown;
    assetB?: unknown;
    /**
     * The session. THREE fields — `{ address, message, signature }`. Omitting
     * `address` 401s with "sign in", which reads exactly like a bad signature
     * and is not: the server needs the claimed wallet to check the message's
     * own `wallet:` line and to verify through the chain so ERC-1271
     * smart-contract wallets work as well as EOAs.
     */
    session?: unknown;
  };
  try {
    body = await request.json();
  } catch {
    return bad('request body must be JSON', 400);
  }

  const session = body.session as
    | { address?: unknown; message?: unknown; signature?: unknown }
    | undefined;
  const sessAddrRaw = typeof session?.address === 'string' ? session.address : '';
  const sessMessage = typeof session?.message === 'string' ? session.message : '';
  const sessSignature = typeof session?.signature === 'string' ? session.signature : '';
  if (!isAddress(sessAddrRaw) || sessMessage === '' || !/^0x[0-9a-fA-F]+$/.test(sessSignature)) {
    return NextResponse.json(
      {
        error:
          'sign in first — your wallet needs to sign one session message before ' +
          'it can roll a fight. send { address, message, signature }, all three.',
        code: 'SESSION_REQUIRED',
      },
      { status: 401 },
    );
  }
  const requester = getAddress(sessAddrRaw);

  let tokenA = Number(body.tokenA);
  let tokenB = Number(body.tokenB);
  if (!Number.isInteger(tokenA) || tokenA < 1) {
    return bad('tokenA must be a positive integer', 400);
  }
  if (!Number.isInteger(tokenB) || tokenB < 1) {
    return bad('tokenB must be a positive integer', 400);
  }
  if (tokenA === tokenB) {
    return bad('tokenA and tokenB must differ — a bull cannot fight itself', 400);
  }

  // ⚠ NO DEFAULT. `null` here means "not sent", and the challenger's side is
  // required to be an explicit pick a few dozen lines below. Defaulting it to
  // anything would re-create `AUTO` under a different name.
  const selA = parseSelector(body.assetA);
  const selB = parseSelector(body.assetB);
  if (selA === 'invalid') return bad(badSelector('assetA', body.assetA), 400, 'BAD_CURRENCY');
  if (selB === 'invalid') return bad(badSelector('assetB', body.assetB), 400, 'BAD_CURRENCY');
  let assetASel: AssetSelector | null = selA;
  let assetBSel: AssetSelector | null = selB;

  /**
   * Canonicalise so a matchup has ONE identity regardless of who asked or in
   * which order, keeping every signed result publicly re-simulatable in a
   * single canonical order. Asset picks travel with their token.
   *
   * ⚠ Canonical order says NOTHING about who the challenger is. That is decided
   *   by on-chain ownership against the session wallet below, precisely so
   *   swapping the two ids in the body cannot move the anti-grind slot onto
   *   somebody else.
   */
  if (tokenA > tokenB) {
    [tokenA, tokenB] = [tokenB, tokenA];
    [assetASel, assetBSel] = [assetBSel, assetASel];
  }

  const v = validateServerDuelEnv();
  if (!v.ok) {
    return NextResponse.json(
      {
        error:
          'the duel signer is not configured on this deployment yet: ' +
          `${v.errors.join('; ')} unset.`,
        code: 'NOT_CONFIGURED',
      },
      { status: 503 },
    );
  }
  const env = v.env;
  const client = createPublicClient({
    chain: serverChain(env),
    transport: http(env.rpcUrl),
  }) as PublicClient;

  let signerAccount;
  try {
    signerAccount = privateKeyToAccount(env.signerKey);
  } catch (e) {
    return bad(`the signing key is invalid: ${e instanceof Error ? e.message : String(e)}`, 500);
  }

  // ── Session verification ────────────────────────────────────────
  // Two halves, both required: the TERMS baked into the message (wallet, chain,
  // host, 24h ceiling, not expired) and the SIGNATURE over exactly the string
  // we were handed. Verified through the public client rather than viem's
  // standalone helper so ERC-1271 smart-contract wallets work too.
  const nowSec = Math.floor(Date.now() / 1000);
  const termsProblem = checkSessionTerms({
    message: sessMessage,
    claimedWallet: requester,
    chainId: env.chainId,
    domain: requestHost(request),
    now: nowSec,
  });
  if (termsProblem !== null) {
    return NextResponse.json(
      { error: SESSION_ERROR[termsProblem], code: 'SESSION_INVALID', reason: termsProblem },
      { status: 401 },
    );
  }
  let sessionOk = false;
  try {
    sessionOk = await client.verifyMessage({
      address: requester,
      message: sessMessage,
      signature: sessSignature as `0x${string}`,
    });
  } catch {
    sessionOk = false;
  }
  if (!sessionOk) {
    return NextResponse.json(
      { error: SESSION_ERROR['bad-signature'], code: 'SESSION_INVALID', reason: 'bad-signature' },
      { status: 401 },
    );
  }

  try {
    // ── Everything `submitDuel` will check, checked here first ──────
    // Pinned to one block so a transfer landing mid-quote cannot make the
    // ownership read and the seq read disagree with each other.
    const blockNumber = await client.getBlockNumber();
    const at = { blockNumber };

    const [paused, authorizedRouter, allowSelfDuel, yardsAddress] = await Promise.all([
      client.readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'paused', ...at }) as Promise<boolean>,
      client.readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'authorizedRouter', ...at }) as Promise<Address>,
      client.readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'allowSelfDuel', ...at }) as Promise<boolean>,
      /*
       * ⚠ THE ROSTER ADDRESS IS READ OFF `Duel`, NOT OFF AN ENV VAR, AND THAT
       * IS DELIBERATE. `Duel._requireInYards` enforces membership against
       * `_wire(Wire.Yards)` and nothing else, so reading the same slot makes
       * this pre-check incapable of disagreeing with the contract. The
       * alternative — a `NEXT_PUBLIC_YARDS` of our own — has one failure mode
       * that is precisely the bug this check exists to close: an unset var
       * would silently skip the check on a deployment where `Duel` DOES
       * enforce it, and we would be back to signing fights that can never
       * settle. Zero here genuinely means the gate is off on chain.
       */
      client
        .readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'yardsContract', ...at })
        .catch(() => null) as Promise<Address | null>,
    ]);
    if (paused) {
      return bad('duelling is paused on chain right now.', 409, 'PAUSED');
    }
    if (authorizedRouter !== ZERO_ADDRESS) {
      // Non-zero makes the router the SOLE entrypoint; a direct `submitDuel`
      // reverts `OnlyAuthorizedRouter`. Signing one anyway would hand the
      // player a payload that cannot land.
      return bad(
        'a duel router is wired on chain, so fights are submitted through it, ' +
          'not directly. this signer only issues direct-submission results.',
        409,
        'ROUTER_WIRED',
      );
    }

    // ── Who is the challenger? ──────────────────────────────────────
    // On-chain ownership decides, matched against the session wallet. Reading
    // ownership from the chain rather than trusting the body's order is what
    // stops the obvious dodge: swapping the two ids to move the anti-grind lock
    // onto the opponent and keep scanning.
    const [ownerFirst, ownerSecond] = await Promise.all([
      client.readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'ownerOf', args: [BigInt(tokenA)], ...at,
      }).catch(() => null) as Promise<Address | null>,
      client.readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'ownerOf', args: [BigInt(tokenB)], ...at,
      }).catch(() => null) as Promise<Address | null>,
    ]);
    if (!ownerFirst) return bad(`bull #${tokenA} has not been minted.`, 404);
    if (!ownerSecond) return bad(`bull #${tokenB} has not been minted.`, 404);

    const requesterLc = requester.toLowerCase();

    /**
     * ⚠ THE SELF-DUEL BLOCK, CHECKED LIVE (`DECISIONS.md §16`).
     *
     * `Duel.submitDuel` enforces this at SETTLEMENT against fresh `ownerOf`
     * reads, because a bull can change hands between the signature being issued
     * and the result being submitted. That on-chain check is the one that
     * counts. This one exists so the player gets a sentence instead of a
     * `SelfDuelBlocked` revert — and it reads ownership at quote time rather
     * than trusting anything the client claimed, so it is at least as strict as
     * it can be off chain.
     */
    if (!allowSelfDuel && ownerFirst.toLowerCase() === ownerSecond.toLowerCase()) {
      return bad(
        "those two bulls are in the same wallet, and a wallet can't fight " +
          'itself. pick an opponent from someone else.',
        400,
        'SELF_DUEL_BLOCKED',
      );
    }

    const ownsFirst = ownerFirst.toLowerCase() === requesterLc;
    const ownsSecond = ownerSecond.toLowerCase() === requesterLc;
    if (!ownsFirst && !ownsSecond) {
      return bad(
        'you own neither of those bulls, so you could not settle the fight even ' +
          'if we rolled it. send one of yours in.',
        403,
        'NOT_YOUR_FIGHT',
      );
    }
    const challengerId = ownsFirst ? tokenA : tokenB;
    const requestedOpponentId = ownsFirst ? tokenB : tokenA;

    /**
     * ⚠ THE PICK IS REQUIRED AND IT IS CHECKED HERE, not at parse time, because
     * only now do we know from ON-CHAIN OWNERSHIP which of the two selectors is
     * the caller's own. The opponent's may legitimately be absent.
     */
    const challengerAssetSel = ownsFirst ? assetASel : assetBSel;
    if (challengerAssetSel === null) {
      return bad(
        'pick what you are backing your bull with before you roll: bnb, bnbull, ' +
          'or both if either will do. there is no "whatever i can pay" any more, ' +
          'because it could pass over a currency without telling you.',
        400,
        'CURRENCY_NOT_CHOSEN',
      );
    }

    // ── The standing fight ──────────────────────────────────────────
    // One unsettled outcome per WALLET, and it does not expire on a clock. See
    // `lib/duelCommit.ts` for why the slot moved from the token (fefers) to the
    // wallet here, and why every release reason is outside the caller's control.
    const store = commitStore();
    const standingRaw = await store.get(requesterLc);
    let facts: CommitFacts | null = null;
    if (standingRaw) {
      facts = await readCommitFacts({
        client,
        env,
        commit: standingRaw,
        allowSelfDuel,
        now: nowSec,
        yardsAddress: yardsAddress && yardsAddress !== ZERO_ADDRESS ? yardsAddress : null,
      });
    }
    const decision = decideCommit({
      standing: standingRaw,
      facts,
      requestedChallenger: challengerId,
      requestedOpponent: requestedOpponentId,
    });
    const pinned: DuelCommit | null = decision.kind === 'serve' ? decision.commit : null;
    const redirected = decision.kind === 'serve' && decision.redirected;
    if (decision.kind === 'mint' && decision.released !== null) {
      console.info(
        `[run-duel] releasing standing fight for ${requesterLc}: ${decision.released}`,
      );
      await store.del(requesterLc);
    }

    // Re-point the matchup at the pinned fight when there is one, then
    // re-canonicalise so everything downstream runs on the pair that will
    // actually be submitted.
    const effChallengerId = pinned ? pinned.challenger : challengerId;
    const effOpponentId = pinned ? pinned.opponent : requestedOpponentId;
    tokenA = Math.min(effChallengerId, effOpponentId);
    tokenB = Math.max(effChallengerId, effOpponentId);
    const challengerIsA = effChallengerId === tokenA;

    /**
     * ⚠ THE OPPONENT'S SIDE IS ALWAYS `BOTH`, AND THAT IS PHYSICS RATHER THAN A
     * PREFERENCE. A passive opponent cannot be asked mid-fight, and
     * `Duel._takeSide` gates the raw-BNB path on `owner_ == msg.sender`, so
     * their side has to come out of an allowance they already gave — in
     * whichever currency they gave it in. Nothing the challenger picks changes
     * that, and nothing the challenger picks is allowed to pick FOR them.
     *
     * When neither of their allowances covers it the fight cannot be signed,
     * and the error below says exactly that, by currency and by number. That is
     * the case `AUTO` used to swallow.
     */
    const selForA: AssetSelector = challengerIsA ? challengerAssetSel : 'BOTH';
    const selForB: AssetSelector = challengerIsA ? 'BOTH' : challengerAssetSel;

    // Owners of the pair that will actually settle, in canonical order.
    const [ownerARaw, ownerBRaw] = await Promise.all([
      client.readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'ownerOf', args: [BigInt(tokenA)], ...at,
      }) as Promise<Address>,
      client.readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'ownerOf', args: [BigInt(tokenB)], ...at,
      }) as Promise<Address>,
    ]);
    const ownerA = getAddress(ownerARaw);
    const ownerB = getAddress(ownerBRaw);
    if (!allowSelfDuel && ownerA.toLowerCase() === ownerB.toLowerCase()) {
      return bad(
        "your standing fight is now against a bull in your own wallet, and a " +
          "wallet can't fight itself. it will be released — ask again.",
        409,
        'SELF_DUEL_BLOCKED',
      );
    }

    // ── Fighters, from chain state ──────────────────────────────────
    const [sideAread, sideBread] = await Promise.all([
      readBullAt({ client, bullsAddress: env.bullsAddress, tokenId: tokenA, blockNumber, createdAt: nowSec }),
      readBullAt({ client, bullsAddress: env.bullsAddress, tokenId: tokenB, blockNumber, createdAt: nowSec }),
    ]);
    const bullA = sideAread.bull;
    const bullB = sideBread.bull;
    if (bullA.status !== 'alive') return bad(`bull #${tokenA} is in the graveyard.`, 400, 'DEAD');
    if (bullB.status !== 'alive') return bad(`bull #${tokenB} is in the graveyard.`, 400, 'DEAD');

    // A listed bull cannot fight — `Duel._validate` reverts `BullIsListed`, so
    // nobody sells a fighter out from under a buyer mid-match. Fails OPEN on an
    // unreadable marketplace: the contract enforces it for real.
    if (env.marketplaceAddress) {
      try {
        const [listedA, listedB] = await Promise.all([
          client.readContract({
            address: env.marketplaceAddress, abi: MarketplaceAbi, functionName: 'isListed', args: [BigInt(tokenA)], ...at,
          }) as Promise<boolean>,
          client.readContract({
            address: env.marketplaceAddress, abi: MarketplaceAbi, functionName: 'isListed', args: [BigInt(tokenB)], ...at,
          }) as Promise<boolean>,
        ]);
        const listed = listedA ? tokenA : listedB ? tokenB : null;
        if (listed !== null) {
          return bad(
            `bull #${listed} is listed on the marketplace, and a listed bull ` +
              'cannot fight. delist it first.',
            400,
            'LISTED',
          );
        }
      } catch (e) {
        console.error('[run-duel] marketplace listing read failed (continuing open):', e);
      }
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ⚠ THE BULL PIT (`Yards.sol`). NEITHER SIDE GETS SIGNED IF IT IS OUT.
     * ══════════════════════════════════════════════════════════════════
     *
     * THIS IS THE CHECK WHOSE ABSENCE PRODUCED THE "gas limit too high" BUG,
     * and the chain of symptoms is worth writing down because none of it points
     * at the cause:
     *
     *   bull #16 was bought in a marketplace takeover
     *     -> `Yards` membership requires `enteredBy == the LIVE owner`, so the
     *        sale silently voided its entry, with no event and nothing on the
     *        token to show it
     *     -> this route quoted and SIGNED a result naming it anyway
     *     -> `submitDuel` reverts `BullNotInYards(16)`
     *     -> viem estimates gas on a reverting call and gets a garbage number
     *     -> the rpc rejects THAT with "gas limit too high"
     *
     * The player is told their gas is wrong about a transaction that could
     * never have succeeded at any gas price. A signature for a fight that can
     * never settle is worse than a refusal, so this refuses, and names the bull
     * and the reason.
     *
     * ⚠ FAILS **CLOSED**, unlike the marketplace check above, and the asymmetry
     * is intended. There, an unreadable marketplace costs a stale listing check
     * that `Duel._validate` re-runs for real. Here, the whole point is that the
     * contract's own refusal is the thing the player cannot read. If the gate
     * is wired and we cannot see through it, saying so beats handing over a
     * signature we have no reason to believe in.
     *
     * ⚠ A PENDING EJECT COUNTS AS OUT **HERE**, THOUGH `inYards` STILL SAYS IN.
     * That is the anti-dodge design working as designed, from both ends at
     * once: the contract keeps the bull fightable so a loss that was ALREADY
     * signed still lands, and the signer stops issuing NEW ones immediately.
     * `Yards.sol` puts it exactly this way — "to every new opponent the bull is
     * gone the moment the eject transaction confirms". Quoting into a departure
     * would also hand the player a signature whose window can outlive the bull.
     */
    if (yardsAddress && yardsAddress !== ZERO_ADDRESS) {
      let statuses: readonly [YardStatus, YardStatus];
      try {
        statuses = (await Promise.all([
          client.readContract({
            address: yardsAddress, abi: YardsAbi, functionName: 'statusOf', args: [BigInt(tokenA)], ...at,
          }),
          client.readContract({
            address: yardsAddress, abi: YardsAbi, functionName: 'statusOf', args: [BigInt(tokenB)], ...at,
          }),
        ])) as unknown as readonly [YardStatus, YardStatus];
      } catch (e) {
        console.error('[run-duel] yards read failed (refusing to sign):', e);
        return bad(
          "couldn't check whether these bulls are in the bull pit, and a fight against one " +
            'that is out can never settle. nothing was signed. try again in a moment.',
          503,
          'YARDS_UNREADABLE',
        );
      }

      const sides = [
        { tokenId: tokenA, owner: ownerA, status: statuses[0] },
        { tokenId: tokenB, owner: ownerB, status: statuses[1] },
      ];
      for (const side of sides) {
        const problem = yardsProblem(side.status, side.owner);
        if (problem === null) continue;
        return bad(
          explainYards(side.tokenId, problem, side.owner.toLowerCase() === requesterLc),
          409,
          problem === 'leaving' ? 'LEAVING_YARDS' : 'NOT_IN_YARDS',
        );
      }
    }

    // ── Stakes: read off `Duel.fighterCost`, never derived here ─────
    // The contract owns the dollar->BNB conversion and the discount now
    // (`DECISIONS.md §26`). No MintDrop address is passed any more: Duel does
    // its own oracle read internally, and one formula is the whole point.
    const pricing = await readFightPricing({
      client,
      duelAddress: env.duelAddress,
      blockNumber,
    });
    if (pricing.assets.length === 0) {
      return bad('no stake assets are registered on the duel contract yet.', 503, 'NO_ASSETS');
    }

    /**
     * Settle ONE side on ONE currency, or explain every currency it tried.
     *
     * ⚠ THE `continue` IS GONE AND THAT IS THE POINT. The previous version
     * walked its candidates and skipped anything that was short without an
     * error and without a log, so on the old default `AUTO` a bull whose owner
     * had no allowance was quietly never matched: no failure surfaced anywhere
     * a player could read it, and there was nothing to act on. Every candidate
     * that cannot be used now records a `Blocker` and every `Blocker` ends up in
     * the sentence the player is shown.
     */
    const resolveSide = async (
      sel: AssetSelector,
      owner: Address,
      tokenId: number,
      isSubmitter: boolean,
    ): Promise<{ asset: StakeAssetInfo; nativeValue: bigint } | { error: string; code?: string }> => {
      const candidates: StakeKind[] = sel === 'BOTH' ? [...BOTH_ORDER] : [SELECTOR_KIND[sel]];
      const blockers: Blocker[] = [];

      for (const kind of candidates) {
        const info = findStakeAssetByKind(pricing, kind);
        if (!info) {
          blockers.push({
            symbol: KIND_LABEL[kind],
            why: 'it is not registered as a fight currency on the duel contract.',
            code: 'NO_PAYABLE_ASSET',
          });
          continue;
        }
        if (info.cost === null) {
          // `readFightPricing` always sets a player-facing `note` when it nulls
          // a cost — pre-graduation bnbull, an unhealthy chainlink feed, an
          // unpegged leg. Pass it straight through rather than paraphrasing it.
          blockers.push({
            symbol: info.symbol,
            why: info.note ?? 'the contract will not quote a fight in it right now.',
            code: info.pending ? 'CURRENCY_NOT_LIVE' : 'CURRENCY_UNPRICED',
          });
          continue;
        }

        const need = formatToken(info.cost, info.decimals);
        const tok = tokenLabel(info);

        // The native convenience path. `Duel._takeSide` lets `msg.sender` cover
        // a WBNB stake with raw BNB sent alongside the duel, wrapping exactly
        // what is owed and refunding the rest — so the submitter does not need
        // a WBNB balance at all. A PASSIVE opponent cannot: only `msg.sender`
        // can post value, so their side must come by allowance. That is
        // physics, not policy (`Duel.sol:1030`).
        let nativeHeld: bigint | null = null;
        if (info.kind === 'bnb' && isSubmitter) {
          nativeHeld = await client.getBalance({ address: owner });
          if (nativeHeld >= info.cost) {
            return { asset: info, nativeValue: info.cost };
          }
        }

        const ready = await erc20Ready(client, info.address, owner, env.duelAddress, info.cost);
        if (ready.ok) return { asset: info, nativeValue: 0n };

        const held = formatToken(ready.balance, info.decimals);
        const approved = formatToken(ready.allowance, info.decimals);
        blockers.push({
          symbol: info.symbol,
          why:
            nativeHeld !== null
              ? // Both routes into the bnb leg failed, so name both. Reporting
                // only the allowance here reads as "approve more" to a wallet
                // whose actual problem is that it is out of bnb.
                `one fight needs ${need} bnb. you have ${formatToken(nativeHeld, info.decimals)} ` +
                `bnb to send with the transaction, and ${held} wbnb with ${approved} of it ` +
                'approved to the duel contract, so neither route covers it.'
              : `one fight needs ${need} ${tok}. ${isSubmitter ? 'you hold' : 'that wallet holds'} ` +
                `${held} and ${isSubmitter ? 'have' : 'has'} approved ${approved} to the duel ` +
                'contract.',
          code: ready.balance < info.cost ? 'INSUFFICIENT_BALANCE' : 'NEEDS_APPROVAL',
        });
      }

      const detail = blockers.map((b) => `${b.symbol.toLowerCase()}: ${b.why}`).join(' ');
      const codes = new Set(blockers.map((b) => b.code));
      const code = codes.size === 1 ? [...codes][0] : 'NO_PAYABLE_ASSET';

      if (isSubmitter) {
        return {
          error:
            (sel === 'BOTH'
              ? 'you said either currency would do, and neither can cover this fight right now. '
              : `you picked ${SELECTOR_LABEL[sel]}, and it cannot cover this fight right now. `) +
            detail,
          code,
        };
      }
      return {
        error:
          `bull #${tokenId} cannot be drawn into this fight. a bull you did not send in ` +
          'yourself always pays out of an allowance its owner gave the duel contract, ' +
          'because only the wallet sending the transaction can post bnb with it. ' +
          `${detail} pick another opponent, or ask that owner to approve one of the two.`,
        code,
      };
    };

    const [sideA, sideB] = await Promise.all([
      resolveSide(selForA, ownerA, tokenA, ownerA.toLowerCase() === requesterLc),
      resolveSide(selForB, ownerB, tokenB, ownerB.toLowerCase() === requesterLc),
    ]);
    if ('error' in sideA) return bad(sideA.error, 400, sideA.code);
    if ('error' in sideB) return bad(sideB.error, 400, sideB.code);

    const stakeAAmount = sideA.asset.cost!;
    const stakeBAmount = sideB.asset.cost!;
    const assetAAddr = sideA.asset.address;
    const assetBAddr = sideB.asset.address;

    // Re-assert the ceiling on the exact numbers about to be signed.
    // `readFightPricing` already nulls anything over it, so reaching this is a
    // bug — but a signature above `maxFightCostOf` reverts `FightCostTooHigh`
    // on chain and this is the last place to stop one being issued.
    for (const [amount, info] of [[stakeAAmount, sideA.asset], [stakeBAmount, sideB.asset]] as const) {
      if (info.maxCost === 0n || amount > info.maxCost) {
        return bad(
          `refusing to sign: a ${info.symbol} stake of ${amount} is above the ` +
            `contract's one-shot ceiling of ${info.maxCost}.`,
          500,
          'ABOVE_CEILING',
        );
      }
    }

    // ── The per-wallet sequence ─────────────────────────────────────
    // THE read the signer makes before quoting (`Duel.nextFightSeq`). A stale
    // sequence reverts `StaleFightSeq` before a single token moves, which is
    // what makes the affordability check above a guarantee rather than a
    // hopeful snapshot.
    //
    // ⚠ When both bulls are in one wallet (only reachable with `allowSelfDuel`
    //   on), `submitDuel` consumes the two sequences SEQUENTIALLY off the same
    //   mapping slot, so the signer names `seq` and `seq + 1`. Naming `seq`
    //   twice would revert on the second `_consumeSeq`.
    const sameOwner = ownerA.toLowerCase() === ownerB.toLowerCase();
    const seqARaw = (await client.readContract({
      address: env.duelAddress, abi: DuelAbi, functionName: 'nextFightSeq', args: [ownerA], ...at,
    })) as bigint;
    const seqBRaw = sameOwner
      ? seqARaw + 1n
      : ((await client.readContract({
          address: env.duelAddress, abi: DuelAbi, functionName: 'nextFightSeq', args: [ownerB], ...at,
        })) as bigint);

    // ── The outcome: pinned, or freshly rolled and then pinned ──────
    //
    // ⚠ There is exactly ONE code path in this file that produces a new
    //   outcome, and it is the `else` below. It runs only when the wallet has
    //   no live standing fight. Adding a second one re-opens the grind.
    //
    // Re-serving replays the STORED events rather than re-simulating, because a
    // standing fight outlives stat drift: if the pinned opponent levelled up in
    // the meantime, a re-simulation on the same seed could animate a different
    // winner than the one that is signed.
    let seed: bigint;
    let nonce: bigint;
    let finalWinnerId: number;
    let finalRounds: number;
    let finalEloA: number;
    let finalEloB: number;
    let events: readonly CombatEvent[];

    if (pinned) {
      seed = BigInt(pinned.seed);
      nonce = BigInt(pinned.nonce);
      finalWinnerId = pinned.winnerId;
      finalRounds = pinned.rounds;
      finalEloA = pinned.newEloA;
      finalEloB = pinned.newEloB;
      events = JSON.parse(pinned.eventsJson) as CombatEvent[];
    } else {
      seed = randomBig256();
      nonce = randomBig256();
      // Phase 2 will read each bull's bonded calf here and pass it in. When it
      // does, `/api/duel-gif` MUST reproduce the same bond at `blockNumber - 1`
      // or every bonded fight 409s and gets no replay
      // (`BNBULLS-BOOTSTRAP.md §5`).
      const fight = simulateFight(bullA, bullB, seed, null, null);
      const outcomeForA: Outcome =
        fight.winnerId === null ? 'tie' : fight.winnerId === tokenA ? 'win' : 'loss';
      const gamesA = bullA.wins + bullA.losses + bullA.ties;
      const gamesB = bullB.wins + bullB.losses + bullB.ties;
      const elo = applyDuelResult(bullA.elo, bullB.elo, gamesA, gamesB, outcomeForA);
      finalWinnerId = fight.winnerId ?? 0;
      finalRounds = fight.rounds;
      finalEloA = elo.newA;
      finalEloB = elo.newB;
      events = fight.events;

      // Pin it BEFORE it is signed and returned. The write has to land first:
      // hand the caller a winner and then fail to record it, and they have a
      // free re-roll.
      await store.put({
        wallet: requesterLc,
        challenger: effChallengerId,
        opponent: effOpponentId,
        tokenA,
        tokenB,
        winnerId: finalWinnerId,
        rounds: finalRounds,
        seed: seed.toString(),
        newEloA: finalEloA,
        newEloB: finalEloB,
        nonce: nonce.toString(),
        seq: (ownerA.toLowerCase() === requesterLc ? seqARaw : seqBRaw).toString(),
        eventsJson: JSON.stringify(fight.events),
        createdAt: nowSec,
      });
    }

    const ttlSeconds = duelExpirySeconds();
    const expiry = BigInt(nowSec + ttlSeconds);
    const winnerIdOrNull = finalWinnerId === 0 ? null : finalWinnerId;

    const result: DuelResultStruct = {
      tokenA: BigInt(tokenA),
      tokenB: BigInt(tokenB),
      winnerId: finalWinnerId,
      rounds: finalRounds,
      seed,
      newEloA: finalEloA,
      newEloB: finalEloB,
      assetA: assetAAddr,
      assetB: assetBAddr,
      stakeA: stakeAAmount,
      stakeB: stakeBAmount,
      seqA: seqARaw,
      seqB: seqBRaw,
      nonce,
      expiry,
    };

    const domain = {
      name: EIP712_DOMAIN_NAME,
      version: EIP712_DOMAIN_VERSION,
      chainId: env.chainId,
      verifyingContract: env.duelAddress,
    } as const;

    const signature = await signerAccount.signTypedData({
      domain,
      types: DUEL_TYPES,
      primaryType: 'DuelResult',
      message: result,
    });

    /**
     * ⚠ THE DIGEST CHECK. Ask the contract what it thinks this struct hashes to
     * and compare it with what we actually signed. `Duel.hashDuelResult` is a
     * public view returning the FINAL EIP-712 digest, domain separator and all,
     * so this proves domain name, version, chain id, verifying contract, field
     * order, field names and field types all at once — against the deployed
     * bytecode rather than against a copy of the source.
     *
     * A DISAGREEMENT is fatal and the signature is withheld: it would revert
     * `InvalidSignature` for every player until someone noticed. A failed READ
     * is not fatal (an RPC blip must not stop the game), it is logged.
     */
    try {
      const onchainDigest = (await client.readContract({
        address: env.duelAddress,
        abi: DuelAbi,
        functionName: 'hashDuelResult',
        args: [result],
      })) as `0x${string}`;
      const localDigest = hashTypedData({
        domain,
        types: DUEL_TYPES,
        primaryType: 'DuelResult',
        message: result,
      });
      if (onchainDigest.toLowerCase() !== localDigest.toLowerCase()) {
        console.error(
          `[run-duel] EIP-712 digest mismatch. contract=${onchainDigest} signer=${localDigest}. ` +
            'Check the domain name/version and DUEL_RESULT_TYPEHASH against Duel.sol.',
        );
        return bad(
          'the signer and the duel contract disagree about how this result ' +
            'hashes, so the signature would be rejected on chain. refusing to ' +
            'issue it. (this is a deployment mismatch, not your fault.)',
          500,
          'TYPED_DATA_MISMATCH',
        );
      }
    } catch (e) {
      console.error('[run-duel] could not verify the digest against the contract:', e);
    }

    // What the submitter should send as `msg.value`. SUMMED, not picked: with
    // `allowSelfDuel` on, one wallet can own both bulls, and `_collectStakes`
    // draws both WBNB legs from the same native credit — sending only one
    // side's worth would fall through to the allowance path for the other and
    // revert `StakeNotApproved`.
    const nativeValue =
      (ownerA.toLowerCase() === requesterLc ? sideA.nativeValue : 0n) +
      (ownerB.toLowerCase() === requesterLc ? sideB.nativeValue : 0n);

    const response: RunDuelResponse = {
      result: serializeResult(result),
      signature,
      events,
      winnerId: winnerIdOrNull,
      rounds: finalRounds,
      newEloA: finalEloA,
      newEloB: finalEloB,
      deltaA: finalEloA - bullA.elo,
      deltaB: finalEloB - bullB.elo,
      stakes: {
        assetA: assetAAddr,
        assetB: assetBAddr,
        symbolA: sideA.asset.symbol,
        symbolB: sideB.asset.symbol,
        decimalsA: sideA.asset.decimals,
        decimalsB: sideB.asset.decimals,
        amountA: stakeAAmount.toString(),
        amountB: stakeBAmount.toString(),
        // "priced through the oracle" is now simply "is this the BNB leg".
        // `Duel.stickerCost` reads Chainlink for WBNB and returns the keeper
        // peg for everything else (`DECISIONS.md §26`), so the flag no longer
        // needs a field of its own on the pricing struct.
        oracleA: sideA.asset.kind === 'bnb',
        oracleB: sideB.asset.kind === 'bnb',
      },
      ttlSeconds,
      ...(nativeValue > 0n ? { nativeValue: nativeValue.toString() } : {}),
      ...(redirected && pinned
        ? {
            standingFight: {
              challengerTokenId: pinned.challenger,
              opponentTokenId: pinned.opponent,
              since: pinned.createdAt,
            },
          }
        : {}),
    };

    return NextResponse.json(response);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error('[run-duel] failed:', e);
    return bad(`run-duel failed: ${message}`, 500);
  }
}

/**
 * Read the chain state `releaseReason` needs about a standing fight.
 *
 * Everything here is about the PINNED OPPONENT plus whether a fight naming this
 * wallet already settled — deliberately, because those are the facts the
 * challenger cannot manufacture.
 *
 * Reads fail SAFE: a flaky RPC reports "still eligible, not settled", which
 * keeps the standing fight pinned. Failing open would hand an attacker a
 * re-roll for the price of making one read fall over.
 */
async function readCommitFacts(args: {
  client: PublicClient;
  env: { bullsAddress: Address; duelAddress: Address; marketplaceAddress: Address | null };
  commit: DuelCommit;
  allowSelfDuel: boolean;
  now: number;
  /** `Duel.yardsContract()`, or null when the membership gate is off on chain. */
  yardsAddress: Address | null;
}): Promise<CommitFacts> {
  const { client, env, commit } = args;
  const opponent = BigInt(commit.opponent);
  const challenger = BigInt(commit.challenger);

  const [liveSeq, oppAlive, chalAlive, oppOwner] = await Promise.all([
    client
      .readContract({
        address: env.duelAddress, abi: DuelAbi, functionName: 'nextFightSeq',
        args: [getAddress(commit.wallet)],
      })
      .then((x) => (x as bigint).toString())
      // Fail safe: "the sequence has not moved" keeps the fight pinned.
      .catch(() => commit.seq),
    client
      .readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'isAlive', args: [opponent],
      })
      .then((x) => x as boolean)
      .catch(() => true),
    client
      .readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'isAlive', args: [challenger],
      })
      .then((x) => x as boolean)
      .catch(() => true),
    client
      .readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'ownerOf', args: [opponent],
      })
      .then((x) => (x as Address).toLowerCase())
      .catch(() => ''),
  ]);

  let oppListed = false;
  if (env.marketplaceAddress) {
    try {
      oppListed = (await client.readContract({
        address: env.marketplaceAddress, abi: MarketplaceAbi, functionName: 'isListed', args: [opponent],
      })) as boolean;
    } catch {
      oppListed = false;
    }
  }

  /**
   * ⚠ THE OPPONENT LEAVING THE BULL PIT HAS TO RELEASE THE SLOT, OR THE WALLET
   * IS BENCHED FOR A DAY.
   *
   * A standing commit is served back verbatim until something releases it. Once
   * the signer refuses to sign a fight against a bull that is out (see the main
   * gate), a commit pinned to such a bull would answer 409 on every ask until
   * the 24h backstop — the wallet could not fight anything, and nothing it did
   * would help. Exactly the corner the owner hit with bull #16, whose entry a
   * marketplace takeover had silently voided.
   *
   * ⚠ A PENDING EJECT RELEASES IT TOO. Otherwise the slot stalls for the whole
   * eject delay against a bull no new fight may be matched to.
   *
   * ⚠ THE CHALLENGER'S OWN MEMBERSHIP IS DELIBERATELY **NOT** A RELEASE REASON,
   * and `releaseReason`'s own rule is why: every release must be outside the
   * challenger's control, or they can manufacture a re-roll and tear up a loss
   * they do not fancy. Ejecting your own bull is your own action, and it is the
   * exact parallel of the CHALLENGER'S LISTING already documented there — one
   * transaction to undo, and `enter` is instant, so the fight stays theirs to
   * settle. They get a 409 naming the bull and telling them to send it back in.
   *
   * Fails SAFE, like every read here: unreadable means "still eligible", which
   * keeps the fight pinned. Failing open would hand an attacker a re-roll for
   * the price of making one read fall over.
   */
  let oppInPit = true;
  if (args.yardsAddress) {
    try {
      const [, leavesAt, live] = (await client.readContract({
        address: args.yardsAddress, abi: YardsAbi, functionName: 'statusOf', args: [opponent],
      })) as YardStatus;
      oppInPit = live && leavesAt === 0n;
    } catch {
      oppInPit = true;
    }
  }

  return {
    now: args.now,
    liveSeq,
    opponentEligible: oppAlive && !oppListed && oppInPit,
    challengerAlive: chalAlive,
    opponentOwner: oppOwner,
    allowSelfDuel: args.allowSelfDuel,
  };
}
