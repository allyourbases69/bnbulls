'use client';

import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useAccount } from 'wagmi';
import { getBull } from '@/lib/art/collection';
import { BANDS, KING_ID, WEAPONS, ACC_LABEL, type Band } from '@/lib/art/bull';
import { useRoster, type RosterBull } from '@/lib/hooks/useRoster';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { BullCardLink } from '@/components/bulls/BullCard';
import { DEATH } from '@/lib/brand';

const PAGE_SIZE = 48;
const ACCESSORY_KEYS = ['ringnose', 'bandana', 'horncaps', 'shades', 'crown', 'boots'];

type TierFilter = 'all' | Band | 'king';
type OwnerFilter = 'all' | 'mine';
type LifeFilter = 'alive' | 'dead' | 'both';
type SortKey = 'id-asc' | 'id-desc' | 'elo-desc' | 'elo-asc' | 'wins-desc' | 'losses-desc';

/** Ported one for one from fefers' browse `SORT_OPTIONS`, in the same order. */
const SORT_OPTIONS: { value: SortKey; label: string }[] = [
  { value: 'id-asc', label: 'oldest first' },
  { value: 'id-desc', label: 'newest first' },
  { value: 'elo-desc', label: 'highest rating' },
  { value: 'elo-asc', label: 'lowest rating' },
  { value: 'wins-desc', label: 'most wins' },
  { value: 'losses-desc', label: 'most losses' },
];

function sortBulls(list: readonly RosterBull[], key: SortKey): RosterBull[] {
  const arr = [...list];
  switch (key) {
    case 'id-asc':
      return arr.sort((a, b) => a.id - b.id);
    case 'id-desc':
      return arr.sort((a, b) => b.id - a.id);
    case 'elo-desc':
      return arr.sort((a, b) => b.elo - a.elo || a.id - b.id);
    case 'elo-asc':
      return arr.sort((a, b) => a.elo - b.elo || a.id - b.id);
    case 'wins-desc':
      return arr.sort((a, b) => b.wins - a.wins || b.elo - a.elo);
    case 'losses-desc':
      return arr.sort((a, b) => b.losses - a.losses || a.elo - b.elo);
  }
}

/**
 * The browse grid, ported from fighting fefers' `app/browse/page.tsx`: the same
 * two filter groups (owner, then life), the same six sort keys in the same
 * order, and `OutlawCard`'s data on every card via `BullCard`.
 *
 * ⚠ BOUGHT ONLY. This grid used to roll all 501 tokens off the art engine and
 * render every one of them, so the entire drop — including every bull nobody
 * had bought yet — was browsable on day one. Owner call: that should not be on
 * the page. The pool is now the roster the chain reports. Fefers' own copy for
 * this page is "Every fefer minted to the stomping ground" — a record of what
 * has been bought, not a catalogue of the drop.
 *
 * ⚠ "BOUGHT", NOT "MINTED", AND THE TWO CAME APART WHEN `BullPen` LANDED. The
 * pen is stocked by minting the whole remaining supply straight to it, so after
 * the pre-mint several hundred bulls are minted, have real stats and have a
 * real `ownerOf` — and nobody has bought a single one of them. A grid keyed on
 * `nextTokenId` would therefore put the entire unsold drop back on the page,
 * which is precisely the thing the owner asked to have removed. `useRoster` →
 * `useMintedBulls` subtracts the pen's `poolIds()` for exactly this reason, and
 * every count on this page inherits it.
 *
 * ⚠ SAY WHAT IS TRUE ABOUT IT, AND NOTHING MORE. This is a UI change, not a
 * cryptographic one, and no copy on this page claims otherwise. The rarity
 * table is derived from a PUBLIC `masterSeed` and committed on chain as
 * `initialRarityHash` (`DECISIONS.md §27`); the same shuffle, the same name
 * dealer and the same art engine are ported into `lib/art/`, which ships to
 * every visitor's browser. Anybody who wants an unminted bull's tier, weapon,
 * name or sprite can compute it from the bundle. What this removes is the wall
 * of them sitting on the site by default.
 *
 * ⚠ The bnbulls-only filters (tier, weapon, gear) are KEPT on top of the
 * ported ones. They have no fefers equivalent because fefers has no trait
 * table to filter on, and dropping them would lose real browse power.
 */
export function BullsGrid() {
  const { isConnected } = useAccount();
  const roster = useRoster();

  const [ownerFilter, setOwnerFilter] = useState<OwnerFilter>('all');
  const [lifeFilter, setLifeFilter] = useState<LifeFilter>('alive');
  const [sortKey, setSortKey] = useState<SortKey>('id-asc');
  const [tier, setTier] = useState<TierFilter>('all');
  const [weapon, setWeapon] = useState<string>('all');
  const [accessory, setAccessory] = useState<string>('all');
  const [page, setPage] = useState(0);

  // `/bulls?filter=mine`, the deep link the post-mint reveal points at — the
  // same one fefers' mint success panel uses (`/browse?filter=mine`). Read off
  // `window.location` in an effect rather than `useSearchParams` so this page
  // needs no Suspense boundary and can still be prerendered.
  useEffect(() => {
    if (new URLSearchParams(window.location.search).get('filter') === 'mine') {
      setOwnerFilter('mine');
    }
  }, []);

  const mineCount = roster.mineIncludingDead.length;

  const filtered = useMemo(() => {
    let out: readonly RosterBull[] = roster.all;
    if (ownerFilter === 'mine') out = roster.mineIncludingDead;
    if (lifeFilter === 'alive') out = out.filter((b) => !b.isDead);
    else if (lifeFilter === 'dead') out = out.filter((b) => b.isDead);
    out = out.filter((b) => {
      const t = getBull(b.id);
      // ⚠ The king carries `band: 'legendary'` so his armour and cape come off
      // the legendary tables (`lib/art/collection.ts`), but he is his OWN tier
      // on the ladder — so the tier filters treat him separately.
      if (tier === 'king' && b.id !== KING_ID) return false;
      if (tier !== 'all' && tier !== 'king' && (b.id === KING_ID || t.band !== tier)) return false;
      if (weapon !== 'all' && t.weapon !== weapon) return false;
      if (accessory === 'clean' && t.accessories.length > 0) return false;
      if (accessory !== 'all' && accessory !== 'clean' && !t.accessories.includes(accessory)) {
        return false;
      }
      return true;
    });
    return sortBulls(out, sortKey);
  }, [roster.all, roster.mineIncludingDead, ownerFilter, lifeFilter, tier, weapon, accessory, sortKey]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const clampedPage = Math.min(page, pageCount - 1);
  const pageItems = filtered.slice(clampedPage * PAGE_SIZE, clampedPage * PAGE_SIZE + PAGE_SIZE);

  function updateFilter<T>(setter: (v: T) => void, value: T) {
    setter(value);
    setPage(0);
  }

  const aliveCount = roster.all.filter((b) => !b.isDead).length;
  const deadCount = roster.all.length - aliveCount;

  return (
    <div>
      {/* ── control row, ported from fefers' browse ──────────────── */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <FilterTab
            label={`all (${roster.all.length})`}
            active={ownerFilter === 'all'}
            onClick={() => updateFilter(setOwnerFilter, 'all')}
          />
          <FilterTab
            label={isConnected ? `mine (${mineCount})` : 'mine'}
            active={ownerFilter === 'mine'}
            disabled={!isConnected}
            disabledTitle="connect a wallet to see your herd"
            onClick={() => updateFilter(setOwnerFilter, 'mine')}
          />
        </div>

        <div className="mx-1 h-6 w-px bg-bull-border" />

        {/* ⚠ THE LIFE FILTER IS LABELLED BY `DEATH`, NOT BY `PIT`, AND THAT IS
            A CORRECTION RATHER THAN A RESKIN. It filters on `isDead`, so what
            it actually counts is bulls that are not on the truck. It used to
            read "in the yards", which was a harmless synonym while nothing on
            the site read the arena roster — and is a lie now that it does. An
            alive bull nobody has entered is NOT in the bull pit and cannot be
            fought by anyone. */}
        <div className="flex flex-wrap items-center gap-2">
          <FilterTab
            label={DEATH.standing}
            active={lifeFilter === 'alive'}
            onClick={() => updateFilter(setLifeFilter, 'alive')}
          />
          <FilterTab
            label={DEATH.listHeading}
            active={lifeFilter === 'dead'}
            onClick={() => updateFilter(setLifeFilter, 'dead')}
          />
          <FilterTab
            label="both"
            active={lifeFilter === 'both'}
            onClick={() => updateFilter(setLifeFilter, 'both')}
          />
        </div>

        <div className="grow" />

        <label className="flex items-center gap-2 text-xs">
          <span className="font-mono uppercase tracking-wide text-bull-text-faint">sort</span>
          <select
            value={sortKey}
            onChange={(e) => updateFilter(setSortKey, e.target.value as SortKey)}
            className="rounded border border-bull-border bg-bull-panel px-2 py-1 text-bull-text"
          >
            {SORT_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      {/* ── the trait filters, bnbulls only ──────────────────────── */}
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <FilterSelect
          label="tier"
          value={tier}
          onChange={(v) => updateFilter(setTier, v as TierFilter)}
          options={[
            { value: 'all', label: 'all tiers' },
            ...BANDS.map((b) => ({ value: b, label: b })),
            { value: 'king', label: 'king (1/1)' },
          ]}
        />
        <FilterSelect
          label="weapon"
          value={weapon}
          onChange={(v) => updateFilter(setWeapon, v)}
          options={[{ value: 'all', label: 'all weapons' }, ...WEAPONS.map((w) => ({ value: w, label: w }))]}
        />
        <FilterSelect
          label="gear"
          value={accessory}
          onChange={(v) => updateFilter(setAccessory, v)}
          options={[
            { value: 'all', label: 'all bulls' },
            { value: 'clean', label: 'clean (none)' },
            ...ACCESSORY_KEYS.map((a) => ({ value: a, label: ACC_LABEL[a] ?? a })),
          ]}
        />
        {/* ⚠ `aliveCount` AND `deadCount` ARE COUNTED OVER `roster.all`, WHICH
            IS THE BOUGHT HERD. Under the pen that matters: the several hundred
            unsold bulls sitting in it are all technically alive, and folding
            them in here would print a "still standing" number several times the
            size of anything actually on the page. */}
        <span className="ml-auto font-mono text-xs text-bull-text-faint">
          {filtered.length} shown · {aliveCount} {DEATH.standing}
          {deadCount > 0 ? ` · ${deadCount} ${DEATH.listHeading}` : ''}
        </span>
      </div>

      {/* ⚠ THREE STATES, AND ONLY ONE OF THEM MAY SAY "NOTHING IS MINTED".
          A read that never answered is not an empty collection — the same
          split the mint panel makes between loading, unavailable and sold
          out. */}
      {!roster.deployed ? (
        <NotDeployed what="the bulls collection" className="mt-6" />
      ) : roster.isLoading ? (
        <p className="mt-6 text-sm text-bull-text-dim">reading the herd off the chain…</p>
      ) : roster.unavailable ? (
        <div className="mt-6 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          <p>
            couldn&apos;t read the herd off the chain just now. that is this page failing to
            reach an rpc, so nothing here claims to know how many have been minted.
          </p>
          <button
            type="button"
            onClick={roster.refetch}
            className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </div>
      ) : roster.all.length === 0 ? (
        <p className="mt-6 text-sm text-bull-text-dim">
          nobody has bought one yet, so there is no herd to look at.{' '}
          <Link href="/mint" className="text-bull-gold hover:underline">
            bring the first one into the world
          </Link>
          .
        </p>
      ) : filtered.length === 0 ? (
        <div className="mt-8 rounded border border-bull-border bg-bull-panel px-4 py-6 text-center">
          <p className="text-sm text-bull-text-dim">
            {ownerFilter === 'mine'
              ? 'nothing in your herd matches that.'
              : 'nothing in the herd matches that.'}
          </p>
          <p className="mt-2 text-sm text-bull-text-faint">
            try a different filter, or{' '}
            <Link href="/mint" className="text-bull-gold hover:underline">
              mint one
            </Link>
            .
          </p>
        </div>
      ) : null}

      <div className="mt-6 grid grid-cols-2 gap-4 empty:hidden sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
        {pageItems.map((b) => (
          <BullCardLink
            key={b.id}
            id={b.id}
            facts={{
              name: b.name,
              elo: b.elo,
              wins: b.wins,
              losses: b.losses,
              ties: b.ties,
              isDead: b.isDead,
            }}
          />
        ))}
      </div>

      {pageCount > 1 && (
        <div className="mt-8 flex items-center justify-center gap-4 font-mono text-sm">
          <button
            onClick={() => setPage((p) => Math.max(0, p - 1))}
            disabled={clampedPage === 0}
            className="rounded-full border border-bull-border px-3 py-1 text-bull-text-dim hover:border-bull-gold hover:text-bull-gold disabled:opacity-30"
          >
            ← prev
          </button>
          <span className="text-bull-text-faint">
            page {clampedPage + 1} / {pageCount}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(pageCount - 1, p + 1))}
            disabled={clampedPage >= pageCount - 1}
            className="rounded-full border border-bull-border px-3 py-1 text-bull-text-dim hover:border-bull-gold hover:text-bull-gold disabled:opacity-30"
          >
            next →
          </button>
        </div>
      )}
    </div>
  );
}

/** Fefers' browse `FilterTab`, reskinned. */
function FilterTab({
  label,
  active,
  disabled,
  disabledTitle,
  onClick,
}: {
  label: string;
  active: boolean;
  disabled?: boolean;
  disabledTitle?: string;
  onClick: () => void;
}) {
  const base = 'rounded-full border px-3 py-1.5 text-xs font-medium transition';
  const cls = disabled
    ? `${base} cursor-not-allowed border-bull-border text-bull-text-faint`
    : active
      ? `${base} border-bull-gold text-bull-gold`
      : `${base} border-bull-border text-bull-text-dim hover:border-bull-gold hover:text-bull-text`;
  return (
    <button
      type="button"
      className={cls}
      disabled={disabled}
      title={disabled ? disabledTitle : undefined}
      onClick={onClick}
    >
      {label}
    </button>
  );
}

function FilterSelect<T extends string>({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: T;
  onChange: (v: T) => void;
  options: Array<{ value: string; label: string }>;
}) {
  return (
    <label className="flex items-center gap-2 text-xs">
      <span className="font-mono uppercase tracking-wide text-bull-text-faint">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value as T)}
        className="rounded border border-bull-border bg-bull-panel px-2 py-1 capitalize text-bull-text"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value} className="capitalize">
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}
