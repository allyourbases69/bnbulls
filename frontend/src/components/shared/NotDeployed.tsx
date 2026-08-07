/**
 * The honest disconnected state. Every page that reads a contract renders
 * this in place of live data when the relevant `NEXT_PUBLIC_*` address is
 * unset — see `env.ts` and the frontend package brief's hard constraints:
 * "no fake data anywhere... nothing may claim to be live."
 *
 * ⚠ THIS SENTENCE CANNOT CARRY THE WHOLE PRE-LAUNCH STORY, AND MUST NOT TRY.
 * It appears up to eight times on a page, so it stays one line. The deliberate
 * "here is what we are waiting for and why" statement is `PreLaunchNotice`,
 * which sits once at the top of every route. Both exist because either on its
 * own is misread: this alone looks like a config gap, and the notice alone
 * leaves the empty panels unexplained where they stand.
 */
export function NotDeployed({ what, className }: { what: string; className?: string }) {
  return (
    <div
      className={`rounded border border-bull-gold/30 bg-bull-panel px-4 py-3 text-sm text-bull-text-dim ${className ?? ''}`}
    >
      {what} is not live yet. there is no contract to read, so this panel is empty rather
      than filled in with a guess. it fills itself the moment there is a real address.
    </div>
  );
}
