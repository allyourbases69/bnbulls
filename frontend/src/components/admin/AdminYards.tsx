'use client';

/**
 * THE PIT (Yards) — the per-bull arena membership contract. Small owner
 * surface: the eject delay (how long a bull stays fightable after you pull it,
 * the anti-dodge bound) and the socials.
 *
 * Verified against `frontend/src/lib/abi/Yards.ts`:
 *   setEjectDelay(uint64 delaySeconds)   bounded by MIN_EJECT_DELAY..MAX_EJECT_DELAY
 *   setSocials(string w, string t, string g)
 */
import { useReadContracts } from 'wagmi';
import { YardsAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import {
  AdminCard,
  AdminSection,
  Addr,
  KV,
  Setter,
  SocialsControl,
  asAddr,
  asBig,
  asString,
  fmtSeconds,
} from './adminUi';

export function AdminYards() {
  const address = contractAddress('yards');

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { abi: YardsAbi, address, functionName: 'ejectDelay' },
          { abi: YardsAbi, address, functionName: 'MIN_EJECT_DELAY' },
          { abi: YardsAbi, address, functionName: 'MAX_EJECT_DELAY' },
          { abi: YardsAbi, address, functionName: 'owner' },
          { abi: YardsAbi, address, functionName: 'website' },
          { abi: YardsAbi, address, functionName: 'twitter' },
          { abi: YardsAbi, address, functionName: 'telegram' },
        ]
      : [],
    query: { enabled: !!address, refetchInterval: 15_000 },
  });

  if (!address) {
    return (
      <AdminSection title="the pit">
        <AdminCard>
          <p className="text-sm text-bull-text-dim">the yards contract is not deployed yet (NEXT_PUBLIC_YARDS unset).</p>
        </AdminCard>
      </AdminSection>
    );
  }

  const ejectDelay = asBig(data?.[0]);
  const minDelay = asBig(data?.[1]);
  const maxDelay = asBig(data?.[2]);
  const owner = asAddr(data?.[3]);
  const website = asString(data?.[4]);
  const twitter = asString(data?.[5]);
  const telegram = asString(data?.[6]);
  const doRefetch = () => void refetch();

  return (
    <AdminSection
      title="the pit"
      sub="arena membership. the eject delay is the anti-dodge bound: a pulled bull keeps fighting until it passes."
    >
      <AdminCard>
        <div className="grid gap-x-6 gap-y-1 md:grid-cols-2">
          <KV k="eject delay" v={fmtSeconds(ejectDelay)} />
          <KV k="allowed range" v={`${fmtSeconds(minDelay)} – ${fmtSeconds(maxDelay)}`} />
          <KV k="owner" v={<Addr addr={owner} />} />
          <KV k="contract" v={<Addr addr={address} />} />
        </div>
      </AdminCard>

      <AdminCard title="eject delay">
        <Setter
          label="eject delay · seconds"
          current={fmtSeconds(ejectDelay)}
          placeholder="seconds, e.g. 300"
          inputMode="numeric"
          hint="how long a bull stays fightable after you eject it. the contract enforces the min/max shown above."
          buildCall={(v) => {
            if (!/^\d+$/.test(v)) return null;
            return { address, abi: YardsAbi, functionName: 'setEjectDelay', args: [BigInt(v)] };
          }}
          onDone={doRefetch}
        />
      </AdminCard>

      <SocialsControl
        key={`${website ?? ''}|${twitter ?? ''}|${telegram ?? ''}`}
        abi={YardsAbi}
        address={address}
        current={{ website, twitter, telegram }}
        onDone={doRefetch}
      />
    </AdminSection>
  );
}
