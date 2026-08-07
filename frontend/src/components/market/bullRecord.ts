/**
 * The on-chain half of a bull, decoded once and shared by every market
 * surface — the listing grid and the "which one am I selling" picker both need
 * the same record and neither may invent it.
 *
 * ⚠ NO NUMBER IN HERE IS DERIVED, GUESSED OR DEFAULTED. `Bulls.getBull` either
 * answered or it did not: a failed read returns `null` and the caller renders
 * a dash, exactly like `BullOnChainPanel`. A zero-filled placeholder would
 * render "0W · 0L" for a bull with a real record, which is worse than blank.
 *
 * Combat stats (str/dex/con/int/wis/cha, weaponId, level, xp) are deliberately
 * NOT surfaced here. The market cares about the fight record; the sim owns the
 * stats.
 */
export interface BullRecord {
  /** `Bulls.Bull.elo`, uint32. */
  elo: number;
  wins: number;
  losses: number;
  ties: number;
  isDead: boolean;
  /** The dealt name as the contract stores it. */
  name: string;
}

interface RawBull {
  elo: number;
  wins: number;
  losses: number;
  ties: number;
  isDead: boolean;
  name: string;
}

/** Decode one `useReadContracts` entry for `Bulls.getBull`. `null` when the
 *  read has not landed or came back a failure. */
export function decodeBull(
  entry: { status: 'success' | 'failure'; result?: unknown } | undefined,
): BullRecord | null {
  if (!entry || entry.status !== 'success') return null;
  const b = entry.result as unknown as RawBull | undefined;
  if (!b || typeof b.isDead !== 'boolean') return null;
  return {
    elo: Number(b.elo),
    wins: Number(b.wins),
    losses: Number(b.losses),
    ties: Number(b.ties),
    isDead: b.isDead,
    name: b.name,
  };
}

/** "12W · 3L · 1T", or a dash while the chain has not answered. Never "0W" on
 *  a missing read. */
export function recordLabel(record: BullRecord | null): string {
  if (!record) return '—';
  return `${record.wins}W · ${record.losses}L · ${record.ties}T`;
}
