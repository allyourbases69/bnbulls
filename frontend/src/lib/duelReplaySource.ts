/**
 * duelReplaySource.ts — rebuild a settled fight from the chain, exactly.
 *
 * A duel is deterministic from its seed, and the seed is in the `DuelCompleted`
 * event, so any past fight can be replayed with no database, no cache and
 * nothing kept from when it happened. That matters because the only place the
 * event list is ever stored is the standing-fight slot, which holds ONE row per
 * wallet and is cleared the moment the fight settles — there is no archive of
 * fights to read, and there was never meant to be one.
 *
 * ⚠ TWO THINGS THAT WILL SILENTLY GIVE YOU THE WRONG FIGHT.
 *
 *   1. READ THE FIGHTERS AT `blockNumber - 1`, NOT AT `blockNumber`.
 *      `submitDuel` awards elo and can kill the loser in the same transaction
 *      that emits the event, so state AT the fight's block is state AFTER the
 *      fight. `startingHp` reads `level`, so a bull that levelled on this very
 *      win would replay with the wrong hp and the fight would end on a
 *      different swing. This is the specific mistake called out in the package
 *      brief, and it is the one that looks like it works.
 *
 *   2. FORCE BOTH FIGHTERS ALIVE. `simulateFight` refuses a dead bull, and the
 *      loser of a fatal streak IS dead by the end of the tx. They were both
 *      alive when the bell rang; that is the state being replayed.
 *
 * And because a replay that contradicts the chain is worse than no replay, the
 * result is VERIFIED: the re-simulated winner and round count must match what
 * the event recorded, or this returns a refusal that `/api/duel-gif` turns into
 * a **409**. The usual cause is an RPC that cannot serve state that far back
 * (public BSC endpoints keep a rolling window), in which case the honest answer
 * is "no replay for this one", not a fight that never happened.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THIS ROUTE NEEDS THINGS THE REST OF THE SITE DOES NOT. READ serverEnv.
 * ═══════════════════════════════════════════════════════════════════════
 * It is the ONLY caller of `eth_getTransactionReceipt` in the codebase, and
 * the only one that ever asks for state at an OLD block. Those are exactly the
 * two things free BSC endpoints differ on, and they differ silently: on
 * 2026-08-10 every replay on the live site failed because the server was built
 * on `NEXT_PUBLIC_RPC_URL` entry [0] (publicnode), which serves `eth_getLogs`
 * beautifully for the browser and 403s every single receipt. Fights were being
 * signed, settled and listed the whole time. Nothing else asks for a receipt,
 * so nothing else noticed.
 *
 * Build the client with `serverTransport(env.rpcUrls)` and never with a single
 * `http()`. That table of what each endpoint actually answers lives in
 * `lib/serverEnv.ts` next to the pool order it justifies.
 */
import { createPublicClient, parseEventLogs, type Address, type PublicClient } from 'viem';
import { BullsAbi, DuelAbi } from '@/lib/abi';
import {
  validateServerDuelEnv,
  serverChain,
  serverTransport,
  hasPrivateRpc,
} from '@/lib/serverEnv';
import { readBullAt } from '@/lib/bullOnchain';
import { simulateFight } from '@/sim/combat';
import { startingHp } from '@/core/stats';
import { isValidBullId } from '@/lib/art/collection';
import type { Band } from '@/lib/art/bull';
import type { Bull } from '@/core/types';
import type { ReplayInput, ReplayFighter } from './duelReplay';

/**
 * `Bulls.rarityOf` uint8 → the band name the art engine speaks.
 *
 * Order is `Bulls.sol`'s own: 0 common, 1 uncommon, 2 rare, 3 epic,
 * 4 legendary, 5 king. The king has no band of its own in the art engine
 * (`lib/art/collection.ts` renders #501 under a legendary override), so it maps
 * there too — matching what every other surface on the site already shows.
 */
const TIER_BANDS: readonly Band[] = [
  'common',
  'uncommon',
  'rare',
  'epic',
  'legendary',
  'legendary', // king
];

export interface ReplaySourceRequest {
  readonly txHash: `0x${string}`;
  /** Disambiguates a transaction that settled more than one duel. */
  readonly logIndex?: number | null;
}

export interface ReplayMeta {
  readonly chainId: number;
  readonly txHash: string;
  readonly logIndex: number;
  readonly blockNumber: number;
  readonly tokenA: number;
  readonly tokenB: number;
  readonly winnerId: number | null;
  readonly rounds: number;
  readonly seed: string;
  /** Whether fighter state came from the pre-fight block or fell back to head. */
  readonly statePinned: boolean;
}

export type ReplaySource =
  | { readonly ok: true; readonly input: ReplayInput; readonly meta: ReplayMeta }
  | {
      readonly ok: false;
      /**
       * ⚠ `mismatch` AND `unverifiable` ARE NOT THE SAME ACCUSATION.
       *
       * `mismatch` means both bulls were read as they stood BEFORE the bell and
       * the re-run still landed somewhere else. That is a real disagreement
       * with the chain and it deserves the loud sentence.
       *
       * `unverifiable` means the re-run disagreed but the fighters had to be
       * read as they stand NOW, because no endpoint here would serve their
       * state at the fight block. A bull that has levelled since fights with
       * different hp, so the re-run swings differently and lands somewhere
       * else, and the fight it is "disagreeing" with is perfectly sound.
       * Calling that "this one does not add up" is telling a player their money
       * might be fake because our reader is on a free rpc. Still no picture,
       * because an unproven replay is not worth showing — but a different
       * sentence, and one that blames the right party.
       */
      readonly reason: 'config' | 'not-found' | 'no-duel' | 'rpc' | 'mismatch' | 'unverifiable';
      readonly detail: string;
    };

/**
 * Fetch, re-simulate and verify. Never throws on a chain or input problem —
 * callers turn a refusal into a 404/409, and a thrown stack in a route that a
 * Telegram bot polls is just an outage with extra steps.
 */
export async function replayInputFromChain(req: ReplaySourceRequest): Promise<ReplaySource> {
  const v = validateServerDuelEnv();
  if (!v.ok) {
    return { ok: false, reason: 'config', detail: v.errors.join('; ') };
  }
  const env = v.env;
  // ⚠ THE WHOLE POOL, NOT `http(env.rpcUrls[0])`. Entry [0] used to be
  // publicnode, which 403s EVERY `eth_getTransactionReceipt` as an "archive
  // request" — so the very first line of every replay failed and the site
  // answered "the chain did not answer" for fights that were plainly on chain
  // and plainly settling fine. See `serverEnv.serverRpcUrls`.
  const client = createPublicClient({
    chain: serverChain(env),
    transport: serverTransport(env.rpcUrls),
  }) as PublicClient;

  // ── the event ──
  let logs;
  try {
    const receipt = await client.getTransactionReceipt({ hash: req.txHash });
    logs = parseEventLogs({
      abi: DuelAbi,
      eventName: 'DuelCompleted',
      logs: receipt.logs.filter(
        (l) => l.address.toLowerCase() === env.duelAddress.toLowerCase(),
      ),
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // viem uses the same error shape for "no such transaction" as for a dead
    // endpoint, so the message is the only thing separating them.
    if (/not be found|not found/i.test(msg)) {
      return {
        ok: false,
        reason: 'not-found',
        detail:
          'no node has that transaction on bnb chain yet. if the fight only just ' +
          'landed, give it a second and go again.',
      };
    }
    return { ok: false, reason: 'rpc', detail: msg };
  }

  if (!logs.length) {
    return {
      ok: false,
      reason: 'no-duel',
      detail: 'that transaction is on chain, but no fight was settled in it.',
    };
  }
  const chosen =
    req.logIndex === null || req.logIndex === undefined
      ? logs[0]!
      : logs.find((l) => l.logIndex === req.logIndex);
  if (!chosen) {
    return {
      ok: false,
      reason: 'no-duel',
      detail: `that transaction settled a fight, but not one at log ${req.logIndex}.`,
    };
  }

  const tokenA = Number(chosen.args.tokenA);
  const tokenB = Number(chosen.args.tokenB);
  const loggedWinner = Number(chosen.args.winnerId);
  const loggedRounds = Number(chosen.args.rounds);
  const seed = chosen.args.seed as bigint;
  const blockNumber = chosen.blockNumber;

  if (!isValidBullId(tokenA) || !isValidBullId(tokenB)) {
    return {
      ok: false,
      reason: 'no-duel',
      detail:
        `that fight names bulls outside the collection (${tokenA}, ${tokenB}), so it ` +
        'is not one of ours.',
    };
  }

  // ── the fighters, as they stood BEFORE the bell ──
  const readAt = async (pin: bigint | undefined) =>
    Promise.all([
      readBullAt({
        client, bullsAddress: env.bullsAddress, tokenId: tokenA, blockNumber: pin, forceAlive: true,
      }),
      readBullAt({
        client, bullsAddress: env.bullsAddress, tokenId: tokenB, blockNumber: pin, forceAlive: true,
      }),
      client.readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'rarityOf', args: [BigInt(tokenA)],
        ...(pin === undefined ? {} : { blockNumber: pin }),
      }) as Promise<number>,
      client.readContract({
        address: env.bullsAddress, abi: BullsAbi, functionName: 'rarityOf', args: [BigInt(tokenB)],
        ...(pin === undefined ? {} : { blockNumber: pin }),
      }) as Promise<number>,
    ]);

  // ⚠ ONLY ASK FOR PINNED STATE IF SOMETHING CAN ACTUALLY SERVE IT. Not one
  // free public BSC endpoint can (`serverEnv.hasPrivateRpc` lists what each
  // one answers instead), so without a private archive url this attempt is a
  // guaranteed loss of four reads across four endpoints, with viem's retries
  // on top, while a player watches a spinner. Skipping straight to head state
  // is the same ANSWER, several seconds sooner — and `statePinned: false` says
  // out loud that it was the fallback, which the mismatch sentence below then
  // uses to explain itself.
  let reads;
  let statePinned = hasPrivateRpc();
  if (statePinned) {
    try {
      reads = await readAt(blockNumber - 1n);
    } catch {
      // Past this endpoint's state window after all. Head state usually still
      // replays correctly (stats never change and levels move slowly), and the
      // verification below is what decides whether it actually did.
      statePinned = false;
    }
  }
  if (!reads) {
    try {
      reads = await readAt(undefined);
    } catch (e) {
      return { ok: false, reason: 'rpc', detail: e instanceof Error ? e.message : String(e) };
    }
  }

  const [readA, readB, tierA, tierB] = reads;
  const a = readA.bull;
  const b = readB.bull;

  // ── replay ──
  // Phase 2: when calves land, each bull's BOND has to be read at the same pin
  // and passed in here. `BNBULLS-BOOTSTRAP.md §5` is explicit — anything that
  // changes the sim outcome MUST be reproduced at replay time, or the fight
  // 409s below and gets no replay at all.
  let fight;
  try {
    fight = simulateFight(a, b, seed, null, null);
  } catch (e) {
    return { ok: false, reason: 'mismatch', detail: e instanceof Error ? e.message : String(e) };
  }

  // winnerId 0 on chain is a draw (`Duel._updateStreaksAndCheckDeaths`).
  const expectWinner = loggedWinner === 0 ? null : loggedWinner;
  if (fight.winnerId !== expectWinner || fight.rounds !== loggedRounds) {
    return {
      ok: false,
      // See the union above: only a PINNED re-run may accuse the chain.
      reason: statePinned ? 'mismatch' : 'unverifiable',
      detail: statePinned
        ? `re-run gives winner ${fight.winnerId ?? 'draw'} in ${fight.rounds} round(s), ` +
          `the chain recorded ${expectWinner ?? 'draw'} in ${loggedRounds}. both bulls were ` +
          'read as they stood before the bell, so this is a real disagreement.'
        : 'no node here would serve these bulls as they stood at the fight block, so the ' +
          're-run had to use them as they stand now, and it landed somewhere else. the fight ' +
          'itself is on chain and settled. we just cannot prove this one back to you, and we ' +
          'will not draw a fight we cannot prove.',
    };
  }

  const fighter = (o: Bull, tier: number): ReplayFighter => ({
    tokenId: o.tokenId,
    name: o.name,
    weaponName: o.weapon.name,
    tier: TIER_BANDS[Number(tier)] ?? 'common',
    maxHp: startingHp(o.stats, o.level),
  });

  return {
    ok: true,
    input: {
      a: fighter(a, tierA),
      b: fighter(b, tierB),
      events: fight.events,
      winnerId: expectWinner,
      rounds: loggedRounds,
    },
    meta: {
      chainId: env.chainId,
      txHash: req.txHash,
      logIndex: chosen.logIndex ?? 0,
      blockNumber: Number(blockNumber),
      tokenA,
      tokenB,
      winnerId: expectWinner,
      rounds: loggedRounds,
      seed: seed.toString(),
      statePinned,
    },
  };
}

/** Re-export so a caller can name the address that must be an Address. */
export type { Address };
