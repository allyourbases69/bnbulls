'use client';

import { useReadContract } from 'wagmi';
import { GraveyardAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import { formatUsd1e18, formatDuration } from '@/lib/format';
import { useDeadBulls } from '@/lib/hooks/useDeadBulls';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { GraveyardCard } from './GraveyardCard';
import { DEATH } from '@/lib/brand';

/**
 * ⚠ NOT INVENTED NUMBERS. These are `Graveyard`'s own CONSTRUCTOR values
 * (`_ownerLadder` / `_takeoverLadder`, in dollars), shown only while there is
 * no deployment to read from. The contract sets real economics at construction
 * rather than zeros waiting on a `setLadders` call, precisely so a zero rung
 * can never let somebody walk off with a dead bull for free. The live table
 * below replaces these the instant an address exists.
 */
const LAUNCH_OWNER_LADDER = [50, 200, 500];
const LAUNCH_TAKEOVER_LADDER = [200, 500, 1000];
/** `Graveyard.maxResurrects` and `ownerPriorityWindow` constructor defaults. */
const LAUNCH_MAX_RESURRECTS = 3;
const LAUNCH_PRIORITY_WINDOW_SECONDS = 24 * 60 * 60;

export function GraveyardPanel() {
  const graveyardAddress = contractAddress('graveyard');

  const { data: ownerLadder } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'ownerLadder',
    query: { enabled: !!graveyardAddress },
  });
  const { data: takeoverLadder } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'takeoverLadder',
    query: { enabled: !!graveyardAddress },
  });
  const { data: maxResurrects } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'maxResurrects',
    query: { enabled: !!graveyardAddress },
  });
  const { data: priorityWindow } = useReadContract({
    address: graveyardAddress ?? undefined,
    abi: GraveyardAbi,
    functionName: 'ownerPriorityWindow',
    query: { enabled: !!graveyardAddress },
  });

  const { deadIds, isLoading: loadingDead, incomplete } = useDeadBulls();

  const ownerRungs = (ownerLadder as readonly bigint[] | undefined)?.map((v) => v) ?? null;
  const takeoverRungs = (takeoverLadder as readonly bigint[] | undefined)?.map((v) => v) ?? null;

  return (
    <div>
      <section>
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          buying him back
        </h2>
        <p className="mt-3 max-w-2xl text-sm text-bull-text-dim">
          the holder can always take their own bull back off the truck, cheaper, on the owner
          ladder. after a{' '}
          {formatDuration(
            priorityWindow !== undefined
              ? Number(priorityWindow)
              : LAUNCH_PRIORITY_WINDOW_SECONDS,
          )}{' '}
          head start, anyone else can pay the dearer takeover ladder and walk that bull into
          their own wallet instead. both ladders spend the same pool of lives:{' '}
          {maxResurrects !== undefined ? String(maxResurrects) : LAUNCH_MAX_RESURRECTS} per bull,
          ever. after that, the next one is final.
        </p>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full min-w-[420px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                <th className="py-2 pr-4">rung</th>
                <th className="py-2 pr-4">owner revive</th>
                <th className="py-2 pr-4">takeover revive</th>
              </tr>
            </thead>
            <tbody>
              {Array.from({ length: ownerRungs?.length ?? LAUNCH_OWNER_LADDER.length }, (_, i) => (
                <tr key={i} className="border-b border-bull-border/60">
                  <td className="py-2 pr-4 font-mono">{i + 1}</td>
                  <td className="py-2 pr-4 font-mono text-bull-gold">
                    {ownerRungs ? formatUsd1e18(ownerRungs[i]) : `$${LAUNCH_OWNER_LADDER[i]}`}
                  </td>
                  <td className="py-2 pr-4 font-mono text-bull-text-dim">
                    {takeoverRungs ? formatUsd1e18(takeoverRungs[i]) : `$${LAUNCH_TAKEOVER_LADDER[i]}`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="mt-12">
        <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
          {DEATH.listHeading}
        </h2>
        {!graveyardAddress ? (
          <NotDeployed what={DEATH.label} className="mt-3" />
        ) : loadingDead ? (
          <p className="mt-3 text-sm text-bull-text-dim">{DEATH.listLoading}</p>
        ) : deadIds.length === 0 ? (
          <p className="mt-3 text-sm text-bull-text-dim">{DEATH.empty}</p>
        ) : (
          <>
            {incomplete && (
              <p className="mt-2 text-xs text-bull-text-faint">
                this list is built from event history and may not cover the full lifetime of
                the game yet. set a deploy block to widen the scan.
              </p>
            )}
            <div className="mt-4 grid gap-4 sm:grid-cols-2">
              {deadIds.map((id) => (
                <GraveyardCard key={id} tokenId={id} />
              ))}
            </div>
          </>
        )}
      </section>
    </div>
  );
}
