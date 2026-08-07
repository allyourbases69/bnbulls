'use client';

/**
 * Pager — page-size selector + page navigation.
 *
 * Ported from fighting fefers' `components/Pager.tsx`: same three blocks in the
 * same order (showing x–y of z · per page · prev / page n of m / next), same
 * default of 20 with 50 and 100 available, same `min-height` tap floor on the
 * controls so a phone can actually hit them. Only the classes are bnbulls.
 *
 * ⚠ 2.75rem is Apple's 44px minimum tap target and is not negotiable on a
 * phone — it relaxes to a compact control at `sm` and up, which is exactly what
 * fefers does.
 */
interface PagerProps {
  /** 1-indexed. */
  page: number;
  pageSize: number;
  total: number;
  onPageChange: (page: number) => void;
  onPageSizeChange: (size: number) => void;
  pageSizes?: readonly number[];
}

const DEFAULT_PAGE_SIZES = [20, 50, 100] as const;

export function Pager({
  page,
  pageSize,
  total,
  onPageChange,
  onPageSizeChange,
  pageSizes = DEFAULT_PAGE_SIZES,
}: PagerProps) {
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const safePage = Math.min(Math.max(1, page), totalPages);
  const start = total === 0 ? 0 : (safePage - 1) * pageSize + 1;
  const end = Math.min(safePage * pageSize, total);
  const canPrev = safePage > 1;
  const canNext = safePage < totalPages;

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 py-3 text-sm">
      <div className="text-bull-text-dim">
        showing <span className="font-mono text-bull-text">{start}</span>–
        <span className="font-mono text-bull-text">{end}</span> of{' '}
        <span className="font-mono text-bull-text">{total}</span>
      </div>

      <label className="flex items-center gap-2">
        <span className="text-bull-text-dim">per page</span>
        <select
          className="min-h-[2.75rem] rounded border border-bull-border bg-bull-panel px-2 py-1 font-mono text-bull-text sm:min-h-0"
          value={pageSize}
          onChange={(e) => {
            onPageSizeChange(Number(e.target.value));
            onPageChange(1);
          }}
        >
          {pageSizes.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </label>

      <div className="flex items-center gap-2">
        <button
          type="button"
          className="min-h-[2.75rem] rounded-full border border-bull-border px-3 py-1 font-mono text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold disabled:opacity-30 disabled:hover:border-bull-border disabled:hover:text-bull-text-dim sm:min-h-0"
          disabled={!canPrev}
          onClick={() => onPageChange(safePage - 1)}
        >
          ← prev
        </button>
        <div className="font-mono text-bull-text-faint">
          page <span className="text-bull-text">{safePage}</span> / {totalPages}
        </div>
        <button
          type="button"
          className="min-h-[2.75rem] rounded-full border border-bull-border px-3 py-1 font-mono text-bull-text-dim transition hover:border-bull-gold hover:text-bull-gold disabled:opacity-30 disabled:hover:border-bull-border disabled:hover:text-bull-text-dim sm:min-h-0"
          disabled={!canNext}
          onClick={() => onPageChange(safePage + 1)}
        >
          next →
        </button>
      </div>
    </div>
  );
}
