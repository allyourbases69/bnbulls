/**
 * Turn `Bulls.getBull` / `Bulls.getBullWeapon` reads into the `Bull` the
 * simulator eats.
 *
 * ⚠ ONE ASSEMBLER, TWO CALLERS. `/api/run-duel` (which signs) and
 * `lib/duelReplaySource.ts` (which re-simulates and 409s on a mismatch) MUST
 * resolve identical inputs from identical chain state, or every fight would
 * fail its own replay. `BNBULLS-BOOTSTRAP.md §5` calls that out by name as "the
 * real parity that matters". Keeping the conversion in one function is how that
 * parity is enforced rather than remembered.
 *
 * The fighter's stats come from CHAIN STATE, never from anything the client
 * sent. A client-supplied stat block would let anyone hand the signer a bull
 * with 18 strength and get a signed win for it.
 */
import type { Address, PublicClient } from 'viem';
import { BullsAbi } from '@/lib/abi';
import { findWeapon, WEAPON_TYPE_MAP } from '@/core/weapons';
import type { Bull, Weapon } from '@/core/types';

export interface OnchainBullView {
  readonly strength: number;
  readonly dexterity: number;
  readonly constitution: number;
  readonly intelligence: number;
  readonly wisdom: number;
  readonly charisma: number;
  readonly weaponId: number;
  readonly level: number;
  readonly xp: number;
  readonly elo: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly isDead: boolean;
  readonly name: string;
}

export interface OnchainWeaponView {
  readonly name: string;
  readonly damageMin: number;
  readonly damageMax: number;
  readonly speed: number;
  readonly weaponType: number;
  readonly weight: number;
}

/**
 * The catalog wins, the chain fills the gaps.
 *
 * `core/weapons.ts` mirrors `Bulls.sol::_initializeWeapons()` slot for slot, so
 * the lookup normally hits and the sim runs on the same table the contract
 * holds. The fallback exists for exactly one case: an owner adding a weapon to
 * a future Bulls deployment that this build has never heard of. Rather than
 * throw — which would strand every fight involving that bull — it builds a
 * Weapon straight out of the chain's own numbers. `weaponType` is the uint8
 * `Bulls.sol` stores: 0 blade, 1 blunt, 2 ranged.
 */
export function assembleWeapon(w: OnchainWeaponView): Weapon {
  const known = findWeapon(w.name);
  if (known) return known;
  return {
    name: w.name,
    damageMin: Number(w.damageMin),
    damageMax: Number(w.damageMax),
    speed: Number(w.speed),
    type: WEAPON_TYPE_MAP[Number(w.weaponType)] ?? 'blade',
    rarity: 'common',
    weight: Number(w.weight),
  };
}

export function assembleBull(
  tokenId: number,
  b: OnchainBullView,
  weapon: Weapon,
  opts: { createdAt?: number; forceAlive?: boolean } = {},
): Bull {
  return {
    tokenId,
    // Display only — the fight is decided by stats and the signed seed, never
    // by the string.
    name: b.name && b.name.length > 0 ? b.name : `bnbull #${tokenId}`,
    stats: {
      strength: Number(b.strength),
      dexterity: Number(b.dexterity),
      constitution: Number(b.constitution),
      intelligence: Number(b.intelligence),
      wisdom: Number(b.wisdom),
      charisma: Number(b.charisma),
    },
    weapon,
    level: Number(b.level),
    xp: Number(b.xp),
    elo: Number(b.elo),
    wins: Number(b.wins),
    losses: Number(b.losses),
    ties: Number(b.ties),
    // `forceAlive` is the replay path: the loser of a fatal fight IS dead by
    // the end of the settling transaction, and `simulateFight` refuses a dead
    // bull. Both were standing when the bell rang; that is the state being
    // replayed. See `duelReplaySource.ts`.
    status: opts.forceAlive ? 'alive' : b.isDead ? 'dead' : 'alive',
    createdAt: opts.createdAt ?? 0,
  };
}

/**
 * Read one bull and its weapon, optionally pinned to a block.
 *
 * ⚠ `blockNumber` is not an optimisation. `submitDuel` awards elo and can kill
 * the loser in the same transaction that emits `DuelCompleted`, so state AT the
 * fight's block is state AFTER the fight. `startingHp` reads `level`, so a bull
 * that levelled on this very win would replay with the wrong hp and the fight
 * would end on a different swing. Replays pass `blockNumber - 1`.
 */
export async function readBullAt(args: {
  client: PublicClient;
  bullsAddress: Address;
  tokenId: number;
  blockNumber?: bigint;
  forceAlive?: boolean;
  createdAt?: number;
}): Promise<{ bull: Bull; raw: OnchainBullView }> {
  const at = args.blockNumber === undefined ? {} : { blockNumber: args.blockNumber };
  const [raw, weaponRaw] = await Promise.all([
    args.client.readContract({
      address: args.bullsAddress,
      abi: BullsAbi,
      functionName: 'getBull',
      args: [BigInt(args.tokenId)],
      ...at,
    }) as Promise<OnchainBullView>,
    args.client.readContract({
      address: args.bullsAddress,
      abi: BullsAbi,
      functionName: 'getBullWeapon',
      args: [BigInt(args.tokenId)],
      ...at,
    }) as Promise<OnchainWeaponView>,
  ]);
  return {
    bull: assembleBull(args.tokenId, raw, assembleWeapon(weaponRaw), {
      forceAlive: args.forceAlive,
      createdAt: args.createdAt,
    }),
    raw,
  };
}
