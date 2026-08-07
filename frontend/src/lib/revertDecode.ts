import { decodeErrorResult, type Abi } from 'viem';
import {
  BullsAbi,
  DuelAbi,
  GraveyardAbi,
  MarketplaceAbi,
  MintDropAbi,
  YardsAbi,
} from '@/lib/abi';
import { PIT } from '@/lib/brand';

/**
 * TURN A FAILED TRANSACTION INTO A SENTENCE. NEVER SHOW THE NODE'S OWN WORDS.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ WHY THIS FILE EXISTS, IN ONE BUG.
 * ═══════════════════════════════════════════════════════════════════════
 * The owner tried a duel and was told **"gas limit too high"**. Nothing about
 * gas was wrong. The real chain was:
 *
 *   bull #16 was bought in a marketplace takeover
 *     -> `Yards` membership requires `enteredBy == the LIVE owner`, so the sale
 *        silently voided its entry — no event, nothing on the token
 *     -> `Duel.submitDuel` reverts `BullNotInYards(16)`
 *     -> viem estimates gas against a call that reverts, and gets garbage
 *     -> the rpc rejects THAT number, with a complaint about the number
 *
 * Four steps, and the only one the player ever saw was the last, which was the
 * one thing that was not true. Owner: "don't let this kind of thing happen."
 *
 * So: every custom error this product can produce gets a sentence here, and an
 * error we cannot name still gets a sentence — plus its selector as small
 * print, because a four-byte hex is a fact and the RPC's guess about gas is
 * not.
 *
 * ⚠ NEVER "FIX" A FAILED ESTIMATE BY SETTING A GAS LIMIT. It swaps a confusing
 * error for a transaction that reverts on chain and charges the player for it.
 * If the estimate failed, the call cannot succeed. Say why.
 *
 * ⚠ THE SELECTOR SURVIVES EVEN WHEN THE NAME DOES NOT. `decodeErrorResult`
 * needs the error in an ABI it was handed; a contract we do not ship an ABI for
 * (a router, a token, a future contract) will not decode. That is exactly when
 * "0x1a2b3c4d" is worth printing: it is greppable, and it is the difference
 * between a bug report we can act on and "it just says it failed".
 */

/** Every ABI we might be told about, merged once. Order is irrelevant: a
 *  4-byte selector collision across these would be a genuine coincidence, and
 *  `decodeErrorResult` takes the first match either way. */
const ALL_ABIS: Abi = [
  ...DuelAbi,
  ...YardsAbi,
  ...BullsAbi,
  ...MarketplaceAbi,
  ...GraveyardAbi,
  ...MintDropAbi,
] as unknown as Abi;

export type RevertKind =
  /** A real contract revert, decoded or not. Do not send the transaction. */
  | 'revert'
  /** The player pressed cancel. Not a failure. */
  | 'rejected'
  /** We could not reach a node. Says nothing about whether the call is valid. */
  | 'transport'
  /** Something else. Treated as blocking, because "we do not understand this"
   *  is not a reason to spend somebody's money. */
  | 'unknown';

export interface DecodedRevert {
  readonly kind: RevertKind;
  /** The sentence a player reads. Always plain english, never the rpc string. */
  readonly message: string;
  /** Small print under it: the selector, or the raw error name we had no
   *  sentence for. `null` when the message stands on its own. */
  readonly detail: string | null;
  /** The decoded custom error, when we got one — for logs and bug reports. */
  readonly errorName: string | null;
}

/* ─── finding the revert data ─────────────────────────────────────────
 *
 * ⚠ WALKS THE `cause` CHAIN BY SHAPE, NOT BY CLASS. viem wraps a revert in
 * several layers (`ContractFunctionExecutionError` -> `ContractFunctionRevertedError`
 * -> `RawContractError`) and which layer carries the data depends on whether it
 * came from `simulateContract`, `writeContract` or a bare `call`. Duck-typing
 * the properties survives all three, and survives a viem upgrade renaming a
 * class, which `instanceof` would not.
 */

interface FoundRevert {
  name?: string;
  args?: readonly unknown[];
  raw?: `0x${string}`;
}

function isHexData(v: unknown): v is `0x${string}` {
  return typeof v === 'string' && /^0x[0-9a-fA-F]{8}([0-9a-fA-F]{2})*$/.test(v) && v.length >= 10;
}

function findRevert(err: unknown, depth = 0): FoundRevert | null {
  if (!err || typeof err !== 'object' || depth > 12) return null;
  const node = err as Record<string, unknown>;

  // Already decoded by viem, because the ABI it was given contained the error.
  const data = node.data;
  if (data && typeof data === 'object') {
    const d = data as Record<string, unknown>;
    if (typeof d.errorName === 'string') {
      return { name: d.errorName, args: Array.isArray(d.args) ? d.args : undefined };
    }
  }
  // Undecoded revert bytes, under any of the three names viem uses.
  if (isHexData(data)) return { raw: data };
  if (isHexData(node.raw)) return { raw: node.raw };
  if (isHexData(node.signature)) return { raw: node.signature };

  return findRevert(node.cause, depth + 1);
}

function classify(err: unknown): RevertKind {
  const text = errText(err);
  if (/user rejected|rejected the request|user denied|denied transaction/i.test(text)) {
    return 'rejected';
  }
  if (findRevert(err)) return 'revert';
  /*
   * ⚠ THE RPC's GAS COMPLAINT IS A REVERT WEARING A DISGUISE. BSC answers a
   * failed estimate with "gas limit too high" (custom code 0x61) and viem
   * surfaces "gas required exceeds allowance". Both mean the call would fail,
   * and neither is fixable by changing a gas number.
   */
  if (
    /execution reverted|gas limit too high|gas required exceeds|intrinsic gas|exceeds block gas limit|always failing transaction|cannot estimate gas/i.test(
      text,
    )
  ) {
    return 'revert';
  }
  /*
   * A node we could not reach says NOTHING about whether the call is valid, so
   * this must stay distinguishable from a revert. Blocking every button on an
   * rpc blip would be its own outage.
   */
  if (
    /fetch failed|failed to fetch|network ?error|timeout|timed out|ECONNREFUSED|ENOTFOUND|socket hang up|HTTP request failed|Internal error|service unavailable/i.test(
      text,
    )
  ) {
    return 'transport';
  }
  return 'unknown';
}

function errText(err: unknown): string {
  if (err instanceof Error) {
    // viem stacks the useful part in `details`/`shortMessage`/`metaMessages`,
    // and the constructor message is often the least specific of the four.
    const e = err as Error & {
      details?: unknown;
      shortMessage?: unknown;
      metaMessages?: unknown;
    };
    return [
      err.message,
      typeof e.shortMessage === 'string' ? e.shortMessage : '',
      typeof e.details === 'string' ? e.details : '',
      Array.isArray(e.metaMessages) ? e.metaMessages.join(' ') : '',
    ].join(' \n');
  }
  return String(err);
}

/* ─── the table ───────────────────────────────────────────────────── */

function tokenArg(args: readonly unknown[] | undefined, i = 0): string {
  const v = args?.[i];
  return typeof v === 'bigint' || typeof v === 'number' ? `#${v}` : 'one of the bulls';
}

/**
 * One sentence per custom error, in the player's language.
 *
 * ⚠ EVERY SENTENCE SAYS WHAT TO DO NEXT where there is something to do. "It
 * failed" is the thing this file was written to stop. Anything not listed falls
 * through to `null` and the caller prints the generic line plus the selector,
 * which is still strictly better than the node's opinion about gas.
 */
function sentenceFor(name: string, args: readonly unknown[] | undefined): string | null {
  switch (name) {
    // ── the bull pit (`Yards`) ────────────────────────────────────
    case 'BullNotInYards':
      return (
        `bull ${tokenArg(args)} is not in ${PIT.label}, so it cannot be fought at all. the ` +
        'usual cause is a sale: the pit remembers the wallet that sent the bull in, so ' +
        'changing hands voids it. put it back in the pit and it can fight straight away.'
      );
    case 'NotTokenOwner':
      return "one of those bulls isn't in this wallet any more, so this wallet can't speak for it.";
    case 'EmptyBatch':
      return 'nothing was selected.';
    case 'EjectDelayOutOfRange':
      return 'that eject delay is outside what the contract allows.';

    // ── the fight (`Duel`) ────────────────────────────────────────
    case 'BullIsListed':
      return `bull ${tokenArg(args)} is listed on the marketplace, and a listed bull cannot fight. delist it first.`;
    case 'BullNotAlive':
      return `bull ${tokenArg(args)} died before this fight could settle.`;
    case 'SelfDuelBlocked':
      return "both bulls are in the same wallet now, and a wallet can't fight itself.";
    case 'SelfFight':
      return 'that is the same bull on both sides.';
    case 'StaleFightSeq':
      return 'another signed fight naming one of these wallets settled first, so this one is void. re-quote, nothing was charged.';
    case 'Expired':
      return 'the signature ran out before the transaction landed. re-quote.';
    case 'NonceAlreadyUsed':
      return 'this fight has already settled.';
    case 'InvalidSignature':
      return (
        "the duel contract rejected the signature. the signer configured for this site does not " +
        "match the contract's trustedSigner. that is a deployment problem, not yours."
      );
    case 'InvalidWinnerId':
      return 'the signed result names a winner that is not one of these two bulls. re-quote.';
    case 'NotOwnerOfEither':
      return 'you have to own one of the two bulls to submit their fight.';
    case 'OnlyAuthorizedRouter':
      return 'fights are submitted through a router on this deployment, not directly.';
    case 'FightCostTooHigh':
      return "that amount is above the asset's on-chain ceiling. re-quote.";
    case 'StakeNotApproved':
      return 'the duel contract is not approved for that amount. approve it and try again.';
    case 'StakeUnaffordable':
    case 'StakeShortfall':
      return 'a balance moved and no longer covers that half of the purse.';
    case 'StakeWithoutAsset':
      return 'the signed result puts money up without naming a currency. re-quote.';

    // ── the marketplace ───────────────────────────────────────────
    case 'AlreadyListed':
      return 'that bull is already listed.';
    case 'NotListed':
      return 'that bull is not listed any more. somebody may have just bought it.';
    case 'NotSeller':
      return 'only the wallet that listed a bull can change or cancel that listing.';
    case 'NotApproved':
      return 'the marketplace is not approved to move that bull yet. approve it first.';
    case 'BullIsDead':
      return `bull ${tokenArg(args)} is on the truck, and a dead bull cannot be listed.`;
    case 'InsufficientBNB':
    case 'PaymentShortfall':
      return 'the amount sent no longer covers the price. the quote moved, so try again.';
    case 'BnbullNotAccepted':
      return 'the seller did not price this one in bnbull.';
    case 'BnbullNotWired':
    case 'BnbullPathNotPriced':
    case 'BnbullPegUnavailable':
    case 'BnbullPegStale':
      return 'the bnbull leg is not priced right now, so that currency is off. bnb still works.';
    case 'DirectNativeNotAccepted':
      return 'that contract does not take a plain bnb transfer.';
    case 'ZeroPrice':
      return 'a listing needs a price.';

    // ── the butcher (`Graveyard`) ─────────────────────────────────
    case 'NotDead':
      return `bull ${tokenArg(args)} is alive, so there is nothing to buy back.`;
    case 'AlreadyOwner':
      return 'you already own that one.';
    case 'GoneForever':
      return 'that bull is out of lives. it cannot come back off the truck.';
    case 'OwnerPriority':
      return 'the previous owner still has their head start on this one. it opens to everyone when that runs out.';
    case 'CostTooHigh':
      return 'the price moved above the ceiling you agreed to. re-quote.';

    // ── oracle, shared across mint / market / butcher ─────────────
    case 'OracleStale':
    case 'OracleBadRound':
    case 'OracleBadAnswer':
    case 'OracleOutOfBand':
      return (
        'the chainlink price feed is stale or out of band, so the contract refuses to quote a ' +
        'bnb figure rather than guess at one. this clears itself when the feed updates.'
      );
    case 'OracleNotWired':
      return 'no price feed is wired on that contract yet.';

    // ── plumbing a player can still hit ───────────────────────────
    case 'EnforcedPause':
      return 'that contract is paused on chain right now.';
    case 'SupplyExhausted':
      return 'they are all minted.';
    case 'InvalidCount':
      return 'that is not a mint count the contract will take.';
    case 'ERC721InsufficientApproval':
      return 'that contract is not approved to move this bull. approve it first.';
    case 'ERC721NonexistentToken':
    case 'BullDoesNotExist':
      return `bull ${tokenArg(args)} does not exist on chain yet.`;
    case 'ERC721IncorrectOwner':
      return 'that bull is not in the wallet the transaction says it is.';
    case 'OwnableUnauthorizedAccount':
      return 'that action is owner-only, and this wallet is not the owner.';
    case 'ReentrancyGuardReentrantCall':
      return 'the contract refused a re-entrant call. try it on its own.';
    case 'RefundFailed':
    case 'RefundFailure':
      return 'the refund leg failed, so the whole transaction was rolled back. nothing was charged.';
    case 'ZeroAddress':
      return 'that call was given a zero address.';
    default:
      return null;
  }
}

/**
 * The one entry point. Hand it whatever was thrown — by `simulateContract`, by
 * `writeContract`, by a wallet — and get something safe to render.
 */
export function decodeRevert(err: unknown, fallback?: string): DecodedRevert {
  const kind = classify(err);

  if (kind === 'rejected') {
    return {
      kind,
      message: 'you rejected the transaction, so nothing changed.',
      detail: null,
      errorName: null,
    };
  }

  if (kind === 'transport') {
    return {
      kind,
      message:
        "couldn't reach the chain just now, so this got no further than your browser. nothing " +
        'was sent and nothing was charged. try again in a moment.',
      detail: null,
      errorName: null,
    };
  }

  const found = findRevert(err);
  let name: string | null = found?.name ?? null;
  let args = found?.args;
  let selector: string | null = null;

  if (!name && found?.raw) {
    selector = found.raw.slice(0, 10);
    try {
      const decoded = decodeErrorResult({ abi: ALL_ABIS, data: found.raw });
      name = decoded.errorName;
      args = decoded.args as readonly unknown[] | undefined;
    } catch {
      // Not one of ours. The selector still goes on screen — see the header.
      name = null;
    }
  }

  if (name) {
    const sentence = sentenceFor(name, args);
    if (sentence) {
      return { kind: 'revert', message: sentence, detail: null, errorName: name };
    }
    // Named but untranslated. The name IS the useful small print here, and it
    // is far more actionable than a selector.
    return {
      kind: 'revert',
      message: fallback ?? GENERIC,
      detail: name,
      errorName: name,
    };
  }

  return {
    kind: kind === 'unknown' ? 'unknown' : 'revert',
    message: fallback ?? GENERIC,
    detail: selector,
    errorName: null,
  };
}

/** ⚠ THE FLOOR. Whatever happens, a player gets at least this — never a node
 *  error, and never a number they are invited to "fix". */
const GENERIC =
  'that transaction would fail on chain, so it was stopped before your wallet opened. ' +
  'nothing was sent and nothing was charged. something has moved since this screen loaded, so ' +
  'reload and try again.';

export const GENERIC_REVERT_MESSAGE = GENERIC;
