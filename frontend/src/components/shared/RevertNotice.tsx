'use client';

import type { DecodedRevert } from '@/lib/revertDecode';

/**
 * THE ONE PLACE A FAILED TRANSACTION IS RENDERED.
 *
 * ⚠ IT TAKES A `DecodedRevert`, NOT A STRING, AND THAT IS THE POINT. Every
 * surface that used to print `error.message` was one `{txError.message}` away
 * from putting "gas limit too high" in front of a player about a fight that
 * reverted `BullNotInYards`. Taking the decoded shape means a caller cannot
 * accidentally pass the raw thing: there is nowhere to put it.
 *
 * The selector or undecoded error name renders as SMALL PRINT rather than being
 * dropped. It is a fact, it is greppable, and it is what turns "it just says it
 * failed" into a bug report worth having.
 */
export function RevertNotice({
  error,
  className,
}: {
  error: DecodedRevert | null;
  className?: string;
}) {
  if (!error) return null;
  // A cancelled transaction is not a failure and does not get a red box.
  if (error.kind === 'rejected') {
    return (
      <p className={`text-xs text-bull-text-faint ${className ?? ''}`}>{error.message}</p>
    );
  }
  return (
    <div
      className={`rounded border border-bull-red/40 bg-bull-red/10 px-3 py-2 ${className ?? ''}`}
    >
      <p className="text-xs text-bull-red">{error.message}</p>
      {error.detail && (
        <p className="mt-1 font-mono text-[10px] text-bull-text-faint">{error.detail}</p>
      )}
    </div>
  );
}
