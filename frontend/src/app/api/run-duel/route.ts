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
import { BullsAbi, DuelAbi, Erc20Abi, MarketplaceAbi } from '@/lib/abi';
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
 * ⚠ TWO CURRENCIES ONLY (`DECISIONS.md §26`). `STABLE` is gone from the wire
 * protocol, not merely hidden: a client that still sends it now gets a 400
 * naming the two that exist, which is a far better failure than silently
 * resolving to some third registered asset and signing a fight in it.
 */
const ASSET_SELECTORS = ['BNBULL', 'BNB', 'AUTO'] as const;
type AssetSelector = (typeof ASSET_SELECTORS)[number];

const SELECTOR_KIND: Record<Exclude<AssetSelector, 'AUTO'>, StakeKind> = {
  BNBULL: 'bnbull',
  BNB: 'bnb',
};

/**
 * `AUTO` order: BNBULL first because it is the only discounted leg
 * (`DECISIONS.md §2`), then BNB.
 *
 * ⚠ `other` is deliberately NOT in this list. If some third asset is ever
 * registered on `Duel`, AUTO must never pick it on a player's behalf — they
 * did not choose it and this endpoint would be signing a fight in a currency
 * nobody asked for. It stays reachable only by an explicit address, which no
 * selector currently offers.
 *
 * ⚠ At launch BNBULL resolves to "unavailable" (`§29`), so AUTO lands on BNB
 * for everybody. That is the expected state, not a fallback bug.
 */
const AUTO_ORDER: readonly StakeKind[] = ['bnbull', 'bnb'];

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

  const assetAStr = String(body.assetA ?? 'AUTO').toUpperCase();
  const assetBStr = String(body.assetB ?? 'AUTO').toUpperCase();
  if (!ASSET_SELECTORS.includes(assetAStr as AssetSelector)) {
    return bad(`assetA must be one of ${ASSET_SELECTORS.join(', ')}`, 400);
  }
  if (!ASSET_SELECTORS.includes(assetBStr as AssetSelector)) {
    return bad(`assetB must be one of ${ASSET_SELECTORS.join(', ')}`, 400);
  }
  let assetASel = assetAStr as AssetSelector;
  let assetBSel = assetBStr as AssetSelector;

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

    const [paused, authorizedRouter, allowSelfDuel] = await Promise.all([
      client.readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'paused', ...at }) as Promise<boolean>,
      client.readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'authorizedRouter', ...at }) as Promise<Address>,
      client.readContract({ address: env.duelAddress, abi: DuelAbi, functionName: 'allowSelfDuel', ...at }) as Promise<boolean>,
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
    const challengerAssetSel = ownsFirst ? assetASel : assetBSel;

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
    assetASel = challengerIsA ? challengerAssetSel : 'AUTO';
    assetBSel = challengerIsA ? 'AUTO' : challengerAssetSel;

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

    const resolveSide = async (
      sel: AssetSelector,
      owner: Address,
      label: string,
      isSubmitter: boolean,
    ): Promise<{ asset: StakeAssetInfo; nativeValue: bigint } | { error: string; code?: string }> => {
      const candidates: StakeKind[] =
        sel === 'AUTO' ? [...AUTO_ORDER] : [SELECTOR_KIND[sel]];
      let lastNote: string | null = null;
      for (const kind of candidates) {
        const info = findStakeAssetByKind(pricing, kind);
        if (!info) continue;
        if (info.cost === null) {
          lastNote = info.note;
          if (sel !== 'AUTO') {
            return { error: `${label} cannot pay in ${info.symbol}: ${info.note ?? 'unavailable'}` };
          }
          continue;
        }
        // The native convenience path. `Duel._takeSide` lets `msg.sender` cover
        // a WBNB stake with raw BNB sent alongside the duel, wrapping exactly
        // what is owed and refunding the rest — so the submitter does not need
        // a WBNB balance at all. A PASSIVE opponent cannot: only `msg.sender`
        // can post value, so their side must come by allowance. That is
        // physics, not policy (`Duel.sol`).
        if (info.kind === 'bnb' && isSubmitter) {
          const nativeBalance = await client.getBalance({ address: owner });
          if (nativeBalance >= info.cost) {
            return { asset: info, nativeValue: info.cost };
          }
        }
        const ready = await erc20Ready(client, info.address, owner, env.duelAddress, info.cost);
        if (ready.ok) return { asset: info, nativeValue: 0n };
        if (sel !== 'AUTO') {
          return {
            error:
              `${label} can't pay in ${info.symbol}: needs ${info.cost} (has ` +
              `${ready.balance}, approved ${ready.allowance} to the duel contract).`,
            code: ready.balance < info.cost ? 'INSUFFICIENT_BALANCE' : 'NEEDS_APPROVAL',
          };
        }
      }
      return {
        error:
          `${label} has no currency it can pay with. send bnb, or approve ` +
          `bnbull to the duel contract once it is tradeable.` +
          (lastNote ? ` (${lastNote})` : ''),
        code: 'NO_PAYABLE_ASSET',
      };
    };

    const [sideA, sideB] = await Promise.all([
      resolveSide(assetASel, ownerA, `bull #${tokenA}'s owner`, ownerA.toLowerCase() === requesterLc),
      resolveSide(assetBSel, ownerB, `bull #${tokenB}'s owner`, ownerB.toLowerCase() === requesterLc),
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

  return {
    now: args.now,
    liveSeq,
    opponentEligible: oppAlive && !oppListed,
    challengerAlive: chalAlive,
    opponentOwner: oppOwner,
    allowSelfDuel: args.allowSelfDuel,
  };
}
