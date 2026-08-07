'use client';

import { getBull } from '@/lib/art/collection';
import { BullCardFace } from './BullCardFace';
import type { BullRecord } from './bullRecord';

export interface PickableBull {
  id: number;
  /** `null` while `Bulls.getBull` is in flight or if it failed. */
  record: BullRecord | null;
}

/**
 * Pick which of your bulls to sell, by looking at it.
 *
 * ⚠ THIS REPLACED A `<select>` OF BARE TOKEN IDS. Owner, verbatim: "that's not
 * how fefers is with that drop down box bullshit. we should be seeing real
 * nice browse filtering our bulls etc". A dropdown of "#37, #112, #290" asks a
 * seller to remember which number is which bull — and the whole product is
 * that they are not interchangeable. Same art, same tier colours and the same
 * record the rest of the site shows, so the thing you pick here looks exactly
 * like the thing that lands on the board.
 *
 * The mode selects on the form (`off` / `pegged` / `fixed`) are NOT this and
 * are deliberately left alone: those are three states of one setting, which is
 * what a select is actually for.
 */
export function BullPicker({
  bulls,
  selected,
  onSelect,
  recordsFailed,
}: {
  bulls: PickableBull[];
  selected: number | null;
  onSelect: (id: number) => void;
  recordsFailed?: boolean;
}) {
  // Past a screenful, scroll the picker rather than pushing the price field
  // and the list button below the fold.
  const scrolls = bulls.length > 8;

  return (
    <div
      className={
        scrolls
          ? 'max-h-[28rem] overflow-y-auto rounded border border-bull-border p-2'
          : undefined
      }
    >
      {/* Same column ladder as the listings grid, so the bull you pick here is
          laid out exactly like the card it turns into once it is on the board. */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
        {bulls.map(({ id, record }) => {
          const token = getBull(id);
          const isSelected = selected === id;
          return (
            <button
              key={id}
              type="button"
              onClick={() => onSelect(id)}
              aria-pressed={isSelected}
              className={`bull-card bull-card-hover p-3 text-left transition ${
                isSelected ? 'border-bull-gold ring-1 ring-bull-gold' : ''
              }`}
            >
              <BullCardFace token={token} record={record} recordFailed={recordsFailed} />
              <p
                className={`mt-2 text-center font-mono text-[11px] ${
                  isSelected ? 'text-bull-gold' : 'text-bull-text-faint'
                }`}
              >
                {isSelected ? 'selling this one' : 'select'}
              </p>
            </button>
          );
        })}
      </div>
    </div>
  );
}
