'use client';

/**
 * WHO IS IN THE PIT — everything `DuelAnimation` needs to draw a fighter,
 * resolved without ever making the fight wait.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ⚠ THE ANIMATION MUST NEVER BLOCK ON AN RPC.
 * ═══════════════════════════════════════════════════════════════════════
 * The whole point of the live fight is that it starts the instant the wallet
 * signs. A component that held the first swing until a multicall came back
 * would put a spinner exactly where the drama is meant to be. So every field
 * below has an answer that costs nothing:
 *
 *   sprite, tier, weapon glyph, melee-or-ranged   →  computed locally, always
 *   name, starting hp, damage range               →  chain read, with a fallback
 *
 * The chain read is issued at mount (one multicall, four calls) and in practice
 * lands long before the gate lifts, because the gate is a human opening their
 * wallet. If it has not landed, the fight still plays — the bars just run off
 * hp derived from the fight's own events, and the numeric readout is withheld
 * rather than guessed.
 *
 * ⚠ NOTHING HERE IS A SECOND SOURCE OF TRUTH FOR THE FIGHT. The winner, the
 * damage and the round count all come from the signed `CombatEvent` list. The
 * only number this module contributes is the hp bar's DENOMINATOR, and even
 * that is `core/stats.startingHp` — the same function the simulator used.
 */
import { useMemo, type CSSProperties } from 'react';
import { useReadContracts } from 'wagmi';
import { BullsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { startingHp } from '@/core/stats';
import type { CombatEvent, Weapon } from '@/core/types';
import {
  assembleWeapon,
  type OnchainBullView,
  type OnchainWeaponView,
} from '@/lib/bullOnchain';
import { WEAPON_KIND, type Token } from '@/lib/art/bull';
import { getBull as bullArt, isValidBullId } from '@/lib/art/collection';
import { tierOf, type RankTier } from '@/lib/rarity';

// ─── tier ink ─────────────────────────────────────────────────────────

/**
 * Tier → the CSS custom property holding that tier's colour.
 *
 * ⚠ THE NAME OF A VARIABLE, NEVER A COLOUR. Fefers hardcodes six rgba values
 * in its animation and they have drifted from the rest of its site. Here the
 * portrait glow points at the SAME `--rarity-*` triplets `globals.css` hands to
 * `lib/tierColour.ts`, so a fighter in the pit glows the colour /ranks and the
 * browse grid already print it in, and a reskin moves all three at once.
 *
 * The king takes brand gold, matching `tierTextClass`.
 */
const TIER_INK: Record<RankTier, string> = {
  common: '--rarity-common',
  uncommon: '--rarity-uncommon',
  rare: '--rarity-rare',
  epic: '--rarity-epic',
  legendary: '--rarity-legendary',
  king: '--bull-gold',
};

/** Glow radius, growing with the ladder so a legendary reads as an event and a
 *  common reads as a bull. Fefers' 6→16px ramp, unchanged. */
const TIER_GLOW: Record<RankTier, string> = {
  common: '6px',
  uncommon: '8px',
  rare: '10px',
  epic: '12px',
  legendary: '14px',
  king: '16px',
};

/** The two inline custom properties `.duel-portrait` reads. Spread onto the
 *  fighter frame's `style`; no colour ever reaches the TSX. */
export function tierInkStyle(tier: RankTier): CSSProperties {
  return {
    ['--tier-ink' as string]: `var(${TIER_INK[tier]})`,
    ['--tier-glow' as string]: TIER_GLOW[tier],
  } as CSSProperties;
}

// ─── weapons ──────────────────────────────────────────────────────────

/**
 * Weapon kind → a glyph.
 *
 * Keyed off `lib/art/bull.ts`'s `WEAPON_KIND` rather than sniffed out of the
 * weapon's NAME, which is what fefers does. Name sniffing is why fefers has a
 * comment apologising for the golden-weapon special case: a rename breaks it
 * silently. `WEAPON_KIND` is the art engine's own classification of the same
 * twelve slots, so a rename cannot desync it.
 *
 * Emoji is a stand-in, exactly as it is in fefers — the pixel-art weapon is
 * already drawn INTO the sprite by `lib/art/bull.ts`, and this is the little
 * one that swings out front on an attack.
 */
const KIND_GLYPH: Record<string, string> = {
  dagger: '🗡️',
  sword: '⚔️',
  axe: '🪓',
  club: '🔨',
  flail: '🔨',
  scythe: '⚔️',
  trident: '🔱',
  spear: '🔱',
  bow: '🏹',
  crossbow: '🏹',
  boomerang: '🪃',
  kingpike: '👑',
};

/**
 * The kinds that throw something instead of closing the distance.
 *
 * ⚠ THIS SET MATCHES `core/weapons.ts` EXACTLY, and it is checked below rather
 * than trusted. The five `type: 'ranged'` slots are Hornbow (bow), Bolter
 * (crossbow), Ring (boomerang), Pike (spear) and Gilded Pike (kingpike) — note
 * that "spear" is a ranged slot and "trident" (Pitchfork, blunt) is not, which
 * is exactly the pair a reader would get backwards.
 */
const RANGED_KINDS: ReadonlySet<string> = new Set([
  'bow',
  'crossbow',
  'boomerang',
  'spear',
  'kingpike',
]);

/** What the projectile looks like. Everything else throws a plain shaft. */
export type ShotKind = 'arrow' | 'bolt' | 'ring';

function shotKindOf(kind: string): ShotKind {
  if (kind === 'crossbow') return 'bolt';
  if (kind === 'boomerang') return 'ring';
  return 'arrow';
}

// ─── a fighter ────────────────────────────────────────────────────────

export interface DuelFighter {
  readonly tokenId: number;
  /** Lowercase, because every label on this site is (`VOICE-AND-BRAND.md §1`). */
  readonly name: string;
  readonly tier: RankTier;
  /**
   * The deterministic sprite, straight off the art engine. Never a round trip.
   *
   * Null only for an id outside 1..501, which nothing on the duel path can
   * produce. The frame renders empty rather than borrowing another bull's
   * picture — a fighter drawn as the wrong bull is the one mistake in here
   * that a player would screenshot.
   */
  readonly art: Token | null;
  /** Weapon label, lowercase. The art engine's slug until the chain answers,
   *  and the chain's own name after — the two agree ("hornbow"). */
  readonly weaponLabel: string;
  readonly glyph: string;
  readonly ranged: boolean;
  readonly shot: ShotKind;
  /** Present only once the chain has answered. Drives the "dmg 11-16" line,
   *  which is simply not rendered before then rather than invented. */
  readonly weapon: Weapon | null;
  /** The hp bar's denominator. */
  readonly maxHp: number;
  /** False while `maxHp` is a guess. The numbers beside the bar are withheld
   *  in that window; the bar itself still reads correctly, because a bull
   *  nobody has hit yet is at 100% of whatever its maximum turns out to be. */
  readonly maxHpKnown: boolean;
  /**
   * The rating this bull is carrying INTO the fight, off `getBull().elo`.
   *
   * ⚠ BEFORE, NEVER AFTER. The read is issued at mount, which is before the
   * transaction is sent, so it cannot have moved yet. The rating AFTER is
   * `newEloA` / `newEloB` on the signed result and it is the SIGNER's
   * arithmetic — `core/elo.ts` explains why nothing may recompute it. Null
   * until the read lands, and the victory card prints no rating at all in that
   * window rather than a stand-in.
   */
  readonly elo: number | null;
}

/**
 * A bull's starting hp, read back out of the fight itself.
 *
 * The FIRST hit on a defender is the only one that can say this: before it the
 * defender was at full, so `hpAfter + damage` IS the maximum. Later hits cannot,
 * because by then the bar has already moved.
 *
 * Returns null for a bull that never gets touched — and that is the case where
 * it does not matter, since its bar sits at 100% either way.
 */
function maxHpFromEvents(events: readonly CombatEvent[], tokenId: number): number | null {
  for (const ev of events) {
    if (ev.type === 'attack_hit' && ev.defenderId === tokenId) {
      return ev.defenderHpAfter + ev.damage;
    }
    // Calves do not exist yet (`core/types.ts`), so a bnbulls fight never emits
    // this. Handled anyway because a chip is also a first hit.
    if (ev.type === 'sidekick_chip' && ev.targetId === tokenId) {
      return ev.defenderHpAfter + ev.damage;
    }
  }
  return null;
}

/**
 * Read both fighters.
 *
 * One multicall, four reads: `getBull` + `getBullWeapon` per side, the same
 * pair `lib/bullOnchain.ts` assembles for the signer. `allowFailure` is on
 * because a half-answer is still worth having: a side whose read failed falls
 * back on its own, without taking the other side down with it.
 */
export function useDuelFighters(
  aTokenId: number,
  bTokenId: number,
  events: readonly CombatEvent[],
): { a: DuelFighter; b: DuelFighter } {
  const bullsAddress = contractAddress('bullsNft');
  const readable = !!bullsAddress && isValidBullId(aTokenId) && isValidBullId(bTokenId);

  const { data } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBull' as const,
        args: [BigInt(aTokenId)] as const,
      },
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBullWeapon' as const,
        args: [BigInt(aTokenId)] as const,
      },
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBull' as const,
        args: [BigInt(bTokenId)] as const,
      },
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBullWeapon' as const,
        args: [BigInt(bTokenId)] as const,
      },
    ],
    // ⚠ Pinned for the life of the fight. A refetch mid-animation would rebuild
    // both fighter objects for no new information, and everything downstream of
    // them would rerun for it. Stats and weapon cannot change during a fight
    // anyway: `Bulls` only writes them when a duel settles, which is the moment
    // this component is on its way out.
    query: { enabled: readable, staleTime: 60_000, refetchOnWindowFocus: false },
  });

  return useMemo(() => {
    const build = (tokenId: number, offset: number): DuelFighter => {
      const art = isValidBullId(tokenId) ? bullArt(tokenId) : null;
      const tier: RankTier = isValidBullId(tokenId) ? tierOf(tokenId) : 'common';
      const slug = art?.weapon ?? '';
      const kind = WEAPON_KIND[slug] ?? '';

      const bullRes = data?.[offset];
      const weaponRes = data?.[offset + 1];
      const onchain =
        bullRes?.status === 'success' ? (bullRes.result as unknown as OnchainBullView) : null;
      const weapon =
        weaponRes?.status === 'success'
          ? assembleWeapon(weaponRes.result as unknown as OnchainWeaponView)
          : null;

      // The chain's stat block is the right answer; the fight's own first hit
      // is the standby; a bull nobody hits never needs either.
      const chainHp = onchain
        ? startingHp(
            {
              strength: Number(onchain.strength),
              dexterity: Number(onchain.dexterity),
              constitution: Number(onchain.constitution),
              intelligence: Number(onchain.intelligence),
              wisdom: Number(onchain.wisdom),
              charisma: Number(onchain.charisma),
            },
            Number(onchain.level),
          )
        : null;
      const eventHp = chainHp === null ? maxHpFromEvents(events, tokenId) : null;
      const resolvedHp = chainHp ?? eventHp;

      const name =
        onchain && onchain.name.length > 0
          ? onchain.name.toLowerCase()
          : (art?.name ?? `bnbull #${tokenId}`).toLowerCase();

      return {
        tokenId,
        name,
        tier,
        art,
        weaponLabel: (weapon?.name ?? slug).toLowerCase(),
        glyph: KIND_GLYPH[kind] ?? '⚔️',
        // The chain's own `type` wins once it lands; the art engine's kind
        // gives the same answer for all twelve slots before it does.
        ranged: weapon ? weapon.type === 'ranged' : RANGED_KINDS.has(kind),
        shot: shotKindOf(kind),
        weapon,
        maxHp: resolvedHp ?? 1,
        maxHpKnown: resolvedHp !== null,
        elo: onchain ? Number(onchain.elo) : null,
      };
    };

    return { a: build(aTokenId, 0), b: build(bTokenId, 2) };
  }, [aTokenId, bTokenId, data, events]);
}
