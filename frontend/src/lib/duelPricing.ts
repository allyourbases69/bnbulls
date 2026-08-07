/**
 * What a fighter pays, read STRAIGHT OFF THE CONTRACT.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS FILE USED TO DERIVE THE PRICE ITSELF. IT NO LONGER DOES.
 * ═══════════════════════════════════════════════════════════════════════
 * The old version existed because `Duel` had no oracle: `fightCostOf[wbnb]`
 * was a flat keeper-written peg, so the BNB leg was reconstructed here from
 * "the registered fight asset that is neither BNBULL nor WBNB" (i.e. the
 * stablecoin) as a dollar anchor, converted through `MintDrop.bnbUsdPrice()`.
 *
 * `DECISIONS.md §26` deleted the stablecoin, which deleted that anchor, and
 * `§26`'s "ONE REAL CONSEQUENCE" is exactly this: dollar pricing had to move
 * to a stored dollar figure plus the Chainlink feed, on chain. It did.
 * `Duel.stickerCost()` now converts `usdFightPrice1e18` through the feed
 * itself, and `Duel.fighterCost()` applies the discount to the RESULT.
 *
 * So the whole derivation is gone and this module is a reader. That matters
 * beyond tidiness: a UI that computes a price it then asks you to sign is a UI
 * that can disagree with the contract. Two implementations of one formula
 * always drift, and `DECISIONS.md §27` is what that costs.
 *
 * ⚠ STICKER FIRST, DISCOUNT SECOND — and we do neither. Both come off chain
 * (`stickerCost` for the undiscounted figure, `fighterCost` for what is
 * actually charged) precisely so the double-discount trap documented on
 * `Duel.fighterCost` cannot be re-introduced from this side.
 *
 * ⚠ A REVERT IS A DESIGNED ANSWER, NOT A BUG. `Duel.stickerCost` reverts on
 * the BNB leg when the oracle is unwired, stale, or outside its sanity band.
 * That is fail-CLOSED on purpose: refusing to quote is recoverable in one
 * transaction, quoting off a stale price is not. Every read below catches it
 * and turns it into "this leg is unavailable, and here is why", never into a
 * guessed number.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * TWO CURRENCIES. BNB AND BNBULL. (`DECISIONS.md §26`)
 * ═══════════════════════════════════════════════════════════════════════
 * There is no stablecoin leg to select, price, or name. If some third asset is
 * ever registered on chain it is classified `other`, labelled by its OWN
 * `symbol()`, and never auto-selected — it is not guessed at and it is
 * certainly not called a stablecoin.
 *
 * ⚠ AND BNBULL IS NOT USABLE AT LAUNCH (`§28.1`, `§29`). four.meme holds the
 * token in a transfer-locked custodial phase until its curve fills, so the
 * leg reads "not available yet" rather than erroring. That is the NORMAL
 * launch state, not a fault.
 */
import type { Abi, Address, PublicClient } from 'viem';
import { DuelAbi, Erc20Abi } from '@/lib/abi';
import { CURRENCY } from '@/lib/brand';
import { decodeRevert } from '@/lib/revertDecode';

/**
 * Run a read and keep BOTH outcomes. A bare `.catch(() => null)` throws away
 * the one fact that decides what to tell the player: whether the contract
 * refused, or whether we never managed to ask it.
 */
async function attempt<T>(p: Promise<T>): Promise<{ value: T | null; error: unknown }> {
  try {
    return { value: await p, error: null };
  } catch (e) {
    return { value: null, error: e };
  }
}

/**
 * ⚠ WIDENED FROM THE `as const` ABI ON PURPOSE. The helper below calls
 * `readContract` with a `functionName` typed as `string`, and viem's inference
 * over a 166-entry const ABI with a non-literal name blows the compiler's
 * instantiation depth ("Type instantiation is excessively deep"). Widening to
 * `Abi` for these reads costs nothing here — every return value is explicitly
 * typed at the call site and every one of them is a plain scalar — and the
 * generated ABI is still the single source of the shapes.
 */
const DUEL_ABI = DuelAbi as unknown as Abi;

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const;

export type StakeKind = 'bnbull' | 'bnb' | 'other';

export interface StakeAssetInfo {
  readonly address: Address;
  readonly kind: StakeKind;
  readonly symbol: string;
  readonly decimals: number;
  /** `Duel.stickerCost` — the FULL undiscounted figure. Null when the read
   *  reverted (an unhealthy oracle on the BNB leg). */
  readonly sticker: bigint | null;
  readonly discountBps: number;
  /** One-shot ceiling. A signature above this reverts `FightCostTooHigh`. */
  readonly maxCost: bigint;
  /** `Duel.fighterCost` — what one side is actually charged. Null when this
   *  asset cannot be used right now. */
  readonly cost: bigint | null;
  /** Why `cost` is null. Player-facing, always set when `cost` is null. */
  readonly note: string | null;
  /** True when the leg is merely not switched on yet (BNBULL pre-graduation,
   *  or an unpegged asset) rather than broken. Lets the UI say "not available
   *  yet" instead of showing an error. */
  readonly pending: boolean;
}

export interface FightPricing {
  readonly bnbull: Address | null;
  readonly wbnb: Address | null;
  readonly assets: readonly StakeAssetInfo[];
  /** The dollar sticker one fighter pays, 1e18, straight off
   *  `Duel.usdFightPrice1e18`. Zero before the owner sets it. */
  readonly usdFightPrice1e18: bigint | null;
}

const KNOWN_SYMBOL: Record<Exclude<StakeKind, 'other'>, string> = {
  bnbull: 'BNBULL',
  bnb: 'BNB',
};

function classify(asset: Address, bnbull: Address | null, wbnb: Address | null): StakeKind {
  const a = asset.toLowerCase();
  if (bnbull && a === bnbull.toLowerCase()) return 'bnbull';
  if (wbnb && a === wbnb.toLowerCase()) return 'bnb';
  return 'other';
}

/**
 * Read everything needed to quote a fight, in one pass.
 *
 * `blockNumber` pins every read to one block, so a keeper repeg or an oracle
 * tick landing mid-quote cannot produce a half-old, half-new price table.
 */
export async function readFightPricing(args: {
  client: PublicClient;
  duelAddress: Address;
  blockNumber?: bigint;
}): Promise<FightPricing> {
  const { client, duelAddress } = args;
  const at = args.blockNumber === undefined ? {} : { blockNumber: args.blockNumber };
  const read = <T,>(functionName: string, callArgs?: readonly unknown[]) =>
    client.readContract({
      address: duelAddress,
      abi: DUEL_ABI,
      functionName,
      ...(callArgs ? { args: callArgs } : {}),
      ...at,
    }) as Promise<T>;

  const [assetList, bnbullRaw, wbnbRaw, usdPrice] = await Promise.all([
    read<readonly Address[]>('getFightAssets'),
    read<Address>('bnbull').catch(() => null),
    read<Address>('wbnb').catch(() => null),
    read<bigint>('usdFightPrice1e18').catch(() => null),
  ]);

  const assets = await Promise.all(
    assetList.map(async (address): Promise<StakeAssetInfo> => {
      const kind = classify(address, bnbullRaw, wbnbRaw);
      const [stickerTry, costTry, discountBps, maxCost, decimals, symbol] = await Promise.all([
        // Both of these revert together on an unhealthy oracle (BNB leg).
        //
        // ⚠ THE ERROR IS KEPT, NOT SWALLOWED. These used to be
        // `.catch(() => null)`, which collapsed "the contract refused to quote"
        // and "we could not reach the node" into the same value — so an RPC
        // timeout, a rate limit or a dropped connection all printed a confident
        // "the chainlink bnb/usd feed is unavailable, stale, or outside its
        // sanity band" about a feed that was answering fine. Diagnosing a
        // healthy oracle as broken sends the player away from a game that works.
        attempt(read<bigint>('stickerCost', [address])),
        attempt(read<bigint>('fighterCost', [address])),
        read<number>('discountBpsOf', [address]).then(Number).catch(() => 0),
        read<bigint>('maxFightCostOf', [address]).catch(() => 0n),
        client
          .readContract({ address, abi: Erc20Abi, functionName: 'decimals', ...at })
          .then((d) => Number(d))
          // ⚠ 18 is the LAST RESORT, and only for an asset whose `decimals()`
          // is unreadable. BNBULL's is always read, never assumed — four.meme
          // is expected to issue 18dp but expecting is not knowing
          // (`DECISIONS.md §26`).
          .catch(() => 18),
        kind === 'other'
          ? (client
              .readContract({ address, abi: Erc20Abi, functionName: 'symbol', ...at })
              .catch(() => 'UNKNOWN') as Promise<string>)
          : Promise.resolve(KNOWN_SYMBOL[kind]),
      ]);

      const sticker = stickerTry.value;
      const cost = costTry.value;
      let resolved = cost;
      let note: string | null = null;
      let pending = false;

      if (resolved === null) {
        // Transport is NOT a verdict. The node not answering says nothing about
        // the oracle, so say the true thing and let them try again.
        note =
          decodeRevert(costTry.error).kind === 'transport'
            ? `the node did not answer, so a ${symbol} fight could not be priced. ` +
              'that is the connection, not the fight. reload and it should quote.'
            : kind === 'bnb'
              ? 'the chainlink bnb/usd feed is unavailable, stale, or outside its sanity ' +
                'band, so a bnb fight cannot be priced right now. the contract refuses to ' +
                'guess and so does this page.'
              : `the contract would not quote a ${symbol} fight right now.`;
      } else if (resolved === 0n) {
        // Zero is not an error. It is "nobody has priced this leg yet", which
        // is precisely the launch state for BNBULL (`DECISIONS.md §29`).
        resolved = null;
        pending = true;
        note =
          kind === 'bnbull'
            ? CURRENCY.bnbullPending
            : `no fight price is set for ${symbol} yet.`;
      } else if (maxCost === 0n) {
        // `getFightAssets` should make this impossible. Treat it as unusable
        // rather than as "no limit" — an unregistered asset with no ceiling is
        // the shape of a bug, not a feature.
        resolved = null;
        note = `${symbol} has no registered ceiling on the duel contract, so it cannot be used.`;
      } else if (resolved > maxCost) {
        resolved = null;
        note =
          `the quoted ${symbol} amount is above the contract's one-shot ceiling ` +
          `(${cost} > ${maxCost}). a signature over it would revert FightCostTooHigh, ` +
          'so it will not be signed.';
      }

      return {
        address,
        kind,
        symbol,
        decimals,
        sticker,
        discountBps,
        maxCost,
        cost: resolved,
        note,
        pending,
      };
    }),
  );

  return {
    bnbull: bnbullRaw,
    wbnb: wbnbRaw,
    assets,
    usdFightPrice1e18: usdPrice,
  };
}

/** Find one asset by address, case-insensitively. */
export function findStakeAsset(
  pricing: FightPricing,
  address: Address,
): StakeAssetInfo | undefined {
  return pricing.assets.find((a) => a.address.toLowerCase() === address.toLowerCase());
}

/** Find one asset by kind. Used for `AUTO` resolution and the UI's default. */
export function findStakeAssetByKind(
  pricing: FightPricing,
  kind: StakeKind,
): StakeAssetInfo | undefined {
  return pricing.assets.find((a) => a.kind === kind);
}
