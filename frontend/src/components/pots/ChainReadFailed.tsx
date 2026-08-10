'use client';

/**
 * "WE COULD NOT READ THE CHAIN" — the one sentence a pot surface is allowed to
 * show when its own read failed.
 *
 * ⚠ THIS IS NOT "nothing has happened yet", AND IT MUST NEVER READ LIKE IT. A
 * read that failed and a pot that is empty are completely different facts, and
 * the only one of them that is ever an accusation is the one we would be making
 * by accident. Both pots really have paid out nothing so far, so the empty
 * sentence is TRUE today — which is exactly why the failure needs words of its
 * own instead of borrowing them.
 *
 * Shared by the deposit feed and the award list on `PotCard` so the two cannot
 * drift into telling the same story two ways.
 */
export function ChainReadFailed({
  message,
  onRetry,
  className = 'mt-4',
}: {
  /** The route's own reason, if it gave one. Shown in brackets, never instead
   *  of the plain sentence. */
  message?: string | null;
  onRetry: () => void;
  className?: string;
}) {
  return (
    <div className={`${className} rounded border border-bull-border bg-black/20 p-3`}>
      <p className="text-sm text-bull-text">we could not read the chain just now.</p>
      <p className="mt-1 text-xs text-bull-text-faint">
        this is a problem at our end, not an empty pot. it is all still on chain.
        {message ? ` (${message})` : ''}
      </p>
      <button
        type="button"
        onClick={onRetry}
        className="mt-2 rounded-full border border-bull-gold px-3 py-1 font-mono text-[11px] uppercase tracking-wide text-bull-gold hover:bg-bull-gold/10"
      >
        try again
      </button>
    </div>
  );
}
