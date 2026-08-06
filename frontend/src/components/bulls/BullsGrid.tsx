'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useReadContracts } from 'wagmi';
import { BullSprite } from '@/components/BullSprite';
import { BullsAbi } from '@/lib/abi';
import { contractAddress, explorerBaseUrl } from '@/lib/env';
import { shortAddr } from '@/lib/format';
import { getBull, MIN_ID } from '@/lib/art/collection';
import { BANDS, KING_ID, WEAPONS, ACC_LABEL, type Band, type Token } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';

const PAGE_SIZE = 48;
const ACCESSORY_KEYS = ['ringnose', 'bandana', 'horncaps', 'shades', 'crown', 'boots'];

type TierFilter = 'all' | Band | 'king';

// Full roll is deterministic and pure — computed once, module scope, exactly
// like the homepage showcase. 500 + the king, not the whole supply repeated
// per render.
const ALL_TOKENS: Token[] = Array.from({ length: KING_ID - MIN_ID }, (_, i) => getBull(i + 1));
const KING_TOKEN = getBull(KING_ID);

export function BullsGrid() {
  const [tier, setTier] = useState<TierFilter>('all');
  const [weapon, setWeapon] = useState<string>('all');
  const [accessory, setAccessory] = useState<string>('all');
  const [page, setPage] = useState(0);

  const filtered = useMemo(() => {
    const pool = tier === 'king' ? [KING_TOKEN] : tier === 'all' ? [...ALL_TOKENS, KING_TOKEN] : ALL_TOKENS;
    return pool.filter((t) => {
      if (tier !== 'all' && tier !== 'king' && t.band !== tier) return false;
      if (weapon !== 'all' && t.weapon !== weapon) return false;
      if (accessory === 'clean' && t.accessories.length > 0) return false;
      if (accessory !== 'all' && accessory !== 'clean' && !t.accessories.includes(accessory)) return false;
      return true;
    });
  }, [tier, weapon, accessory]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const clampedPage = Math.min(page, pageCount - 1);
  const pageItems = filtered.slice(clampedPage * PAGE_SIZE, clampedPage * PAGE_SIZE + PAGE_SIZE);

  function updateFilter<T>(setter: (v: T) => void, value: T) {
    setter(value);
    setPage(0);
  }

  const bullsAddress = contractAddress('bullsNft');
  const { data: onChain } = useReadContracts({
    contracts: pageItems.flatMap((t) => [
      { address: bullsAddress ?? undefined, abi: BullsAbi, functionName: 'ownerOf' as const, args: [BigInt(t.id)] as const },
      { address: bullsAddress ?? undefined, abi: BullsAbi, functionName: 'isDead' as const, args: [BigInt(t.id)] as const },
    ]),
    query: { enabled: !!bullsAddress && pageItems.length > 0 },
  });
  const explorer = explorerBaseUrl();

  return (
    <div>
      <div className="flex flex-wrap items-center gap-3">
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
          label="accessory"
          value={accessory}
          onChange={(v) => updateFilter(setAccessory, v)}
          options={[
            { value: 'all', label: 'all bulls' },
            { value: 'clean', label: 'clean (none)' },
            ...ACCESSORY_KEYS.map((a) => ({ value: a, label: ACC_LABEL[a] ?? a })),
          ]}
        />
        <span className="ml-auto font-mono text-xs text-bull-text-faint">
          {filtered.length} bull{filtered.length === 1 ? '' : 's'}
        </span>
      </div>

      {!bullsAddress && (
        <p className="mt-4 text-xs text-bull-text-faint">
          the collection isn&apos;t minted yet. every sprite below is a live preview off the
          art engine. owner and alive/dead status will appear here once it is.
        </p>
      )}

      <div className="mt-6 grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6">
        {pageItems.map((token, i) => {
          const owner = onChain?.[i * 2]?.status === 'success' ? (onChain[i * 2].result as `0x${string}`) : undefined;
          const isDead = onChain?.[i * 2 + 1]?.status === 'success' ? (onChain[i * 2 + 1].result as boolean) : undefined;
          const isKing = token.id === KING_ID;
          return (
            <Link
              key={token.id}
              href={`/bull/${token.id}`}
              className={`group rounded border bg-bull-panel p-2 transition hover:border-bull-gold ${
                isKing ? 'border-bull-gold/40' : 'border-bull-border'
              }`}
            >
              <BullSprite token={token} scale={2} className="mx-auto" />
              <p
                className={`mt-2 truncate text-center font-mono text-[11px] group-hover:text-bull-gold ${TIER_COLOUR[token.band]}`}
              >
                #{token.id}
              </p>
              {isDead && <p className="text-center text-[10px] text-bull-red">dead 💀</p>}
              {owner && (
                <p className="truncate text-center font-mono text-[10px] text-bull-text-faint">
                  {shortAddr(owner)}
                </p>
              )}
            </Link>
          );
        })}
      </div>

      {filtered.length === 0 && (
        <p className="mt-8 text-center text-sm text-bull-text-dim">no bulls match those filters.</p>
      )}

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
      {bullsAddress && (
        <p className="mt-6 text-center font-mono text-[11px] text-bull-text-faint">
          owner + status read live from{' '}
          <a href={`${explorer}/address/${bullsAddress}`} target="_blank" rel="noreferrer noopener" className="hover:text-bull-gold">
            {shortAddr(bullsAddress)}
          </a>
        </p>
      )}
    </div>
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
        className="rounded border border-bull-border bg-bull-panel px-2 py-1 text-bull-text capitalize"
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
