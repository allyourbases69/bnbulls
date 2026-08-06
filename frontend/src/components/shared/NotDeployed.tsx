/**
 * The honest disconnected state. Every page that reads a contract renders
 * this in place of live data when the relevant `NEXT_PUBLIC_*` address is
 * unset — see `env.ts` and the frontend package brief's hard constraints:
 * "no fake data anywhere... nothing may claim to be live."
 */
export function NotDeployed({ what, className }: { what: string; className?: string }) {
  return (
    <div
      className={`rounded border border-bull-gold/30 bg-bull-panel px-4 py-3 text-sm text-bull-text-dim ${className ?? ''}`}
    >
      {what} isn&apos;t deployed yet. nothing here is invented or estimated, this panel
      goes live the moment a real contract address is wired in.
    </div>
  );
}
