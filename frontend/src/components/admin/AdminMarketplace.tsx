'use client';

/**
 * THE MARKETPLACE — secondary-sale settings, live, plus every owner knob off
 * `frontend/src/lib/abi/Marketplace.ts`:
 *
 *   setFee · setFeeTreasury · setJackpotFeeBps · setKeeper · setBlocksDeadListings
 *   · setDiscountBps · setOraclePolicy · setMaxBnbullPegAge · pause/unpause
 *   · setSocials · rescueToken · sweepPotFee, and the timelocked wire flow.
 *
 * `setFee` writes the SALE fee (bps); `feeBps` reads it back. Every write is
 * simulated before the wallet opens.
 */
import { useState } from 'react';
import { useReadContracts } from 'wagmi';
import { MarketplaceAbi } from '@/lib/abi';
import { contractAddress } from '@/lib/env';
import {
  AdminCard,
  AdminInput,
  AdminSection,
  Addr,
  BigStat,
  KV,
  RescueControl,
  Setter,
  SocialsControl,
  ThreeField,
  Toggle,
  TxStatus,
  WireRow,
  WriteButton,
  asAddr,
  asBig,
  asBool,
  asString,
  asWire,
  fmtBps,
  fmtSeconds,
  isAddr,
  useAdminTx,
} from './adminUi';

const WIRE_SLOTS = [
  { slot: 0, label: 'price feed (chainlink)' },
  { slot: 1, label: '$bnbull token' },
] as const;

export function AdminMarketplace() {
  const address = contractAddress('marketplace');

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { abi: MarketplaceAbi, address, functionName: 'paused' }, // 0
          { abi: MarketplaceAbi, address, functionName: 'owner' }, // 1
          { abi: MarketplaceAbi, address, functionName: 'feeBps' }, // 2
          { abi: MarketplaceAbi, address, functionName: 'feeTreasury' }, // 3
          { abi: MarketplaceAbi, address, functionName: 'keeper' }, // 4
          { abi: MarketplaceAbi, address, functionName: 'jackpotFeeBps' }, // 5
          { abi: MarketplaceAbi, address, functionName: 'jackpotSink' }, // 6
          { abi: MarketplaceAbi, address, functionName: 'blocksDeadListings' }, // 7
          { abi: MarketplaceAbi, address, functionName: 'maxOracleAge' }, // 8
          { abi: MarketplaceAbi, address, functionName: 'minBnbUsd' }, // 9
          { abi: MarketplaceAbi, address, functionName: 'maxBnbUsd' }, // 10
          { abi: MarketplaceAbi, address, functionName: 'maxBnbullPegAge' }, // 11
          { abi: MarketplaceAbi, address, functionName: 'potFeeUndelivered' }, // 12
          { abi: MarketplaceAbi, address, functionName: 'wiringDelay' }, // 13
          { abi: MarketplaceAbi, address, functionName: 'website' }, // 14
          { abi: MarketplaceAbi, address, functionName: 'twitter' }, // 15
          { abi: MarketplaceAbi, address, functionName: 'telegram' }, // 16
          { abi: MarketplaceAbi, address, functionName: 'wires' }, // 17
          { abi: MarketplaceAbi, address, functionName: 'wireOf', args: [0] }, // 18
          { abi: MarketplaceAbi, address, functionName: 'wireOf', args: [1] }, // 19
        ]
      : [],
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const paused = asBool(data?.[0]);
  const owner = asAddr(data?.[1]);
  const feeBps = asBig(data?.[2]);
  const feeTreasury = asAddr(data?.[3]);
  const keeper = asAddr(data?.[4]);
  const jackpotFeeBps = asBig(data?.[5]);
  const jackpotSink = asAddr(data?.[6]);
  const blocksDead = asBool(data?.[7]);
  const maxOracleAge = asBig(data?.[8]);
  const minBnbUsd = asBig(data?.[9]);
  const maxBnbUsd = asBig(data?.[10]);
  const maxBnbullPegAge = asBig(data?.[11]);
  const potFeeUndelivered = asBig(data?.[12]);
  const wiringDelay = asBig(data?.[13]);
  const website = asString(data?.[14]);
  const twitter = asString(data?.[15]);
  const telegram = asString(data?.[16]);
  const wiresTuple = data?.[17]?.status === 'success' ? (data[17].result as readonly [`0x${string}`, `0x${string}`]) : undefined;
  const bnbull = wiresTuple?.[1];
  const wires = [asWire(data?.[18]), asWire(data?.[19])];

  const doRefetch = () => void refetch();

  if (!address) {
    return (
      <AdminSection title="marketplace">
        <AdminCard>
          <p className="text-sm text-bull-text-dim">the marketplace contract is not deployed yet (NEXT_PUBLIC_MARKETPLACE unset).</p>
        </AdminCard>
      </AdminSection>
    );
  }

  return (
    <AdminSection title="marketplace" sub="secondary sales: the sale fee, the jackpot fee slice, and the dead-listing policy.">
      <AdminCard>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <BigStat label="sale fee" value={fmtBps(feeBps)} tone="gold" />
          <BigStat label="jackpot fee slice" value={fmtBps(jackpotFeeBps)} tone="gold" />
          <BigStat label="blocks dead listings" value={blocksDead === undefined ? '—' : blocksDead ? 'yes' : 'no'} tone="plain" />
          <BigStat label="state" value={paused === undefined ? '—' : paused ? 'PAUSED' : 'open'} tone={paused ? 'red' : 'plain'} />
        </div>
        <div className="grid gap-x-6 gap-y-1 border-t border-bull-border/60 pt-1 md:grid-cols-2">
          <KV k="pot fee undelivered" v={potFeeUndelivered?.toString() ?? '—'} />
          <KV k="fee treasury" v={<Addr addr={feeTreasury} />} />
          <KV k="jackpot sink" v={<Addr addr={jackpotSink} />} />
          <KV k="keeper" v={<Addr addr={keeper} />} />
          <KV k="bnbull token" v={<Addr addr={bnbull} />} />
          <KV k="owner" v={<Addr addr={owner} />} />
          <KV k="contract" v={<Addr addr={address} />} />
        </div>
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <AdminCard title="switches">
          <Toggle
            label="marketplace"
            on={paused}
            onWord="PAUSED"
            offWord="open"
            dangerWhenOff
            buildCall={(next) => ({ address, abi: MarketplaceAbi, functionName: next ? 'pause' : 'unpause' })}
            onDone={doRefetch}
          />
          <Toggle
            label="block dead listings"
            on={blocksDead}
            onWord="blocked"
            offWord="allowed"
            buildCall={(next) => ({ address, abi: MarketplaceAbi, functionName: 'setBlocksDeadListings', args: [next] })}
            hint="whether a bull that has died can stay listed."
            onDone={doRefetch}
          />
        </AdminCard>

        <AdminCard title="fees (bps)">
          <Setter
            label="sale fee · bps"
            current={feeBps?.toString() ?? '—'}
            placeholder="bps"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MarketplaceAbi, functionName: 'setFee', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="jackpot fee · bps"
            current={jackpotFeeBps?.toString() ?? '—'}
            placeholder="bps"
            inputMode="numeric"
            hint="the slice of the sale fee that routes into the pots."
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MarketplaceAbi, functionName: 'setJackpotFeeBps', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="bnbull discount · bps"
            current="—"
            placeholder="bps"
            inputMode="numeric"
            hint="the buy discount for paying in bnbull."
            buildCall={(v) =>
              /^\d+$/.test(v) && bnbull ? { address, abi: MarketplaceAbi, functionName: 'setDiscountBps', args: [bnbull, BigInt(v)] } : null
            }
            onDone={doRefetch}
          />
        </AdminCard>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <AdminCard title="addresses">
          <Setter
            label="fee treasury"
            current={<Addr addr={feeTreasury} />}
            placeholder="0x…"
            buildCall={(v) => (isAddr(v) ? { address, abi: MarketplaceAbi, functionName: 'setFeeTreasury', args: [v as `0x${string}`] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="keeper"
            current={<Addr addr={keeper} />}
            placeholder="0x…"
            buildCall={(v) => (isAddr(v) ? { address, abi: MarketplaceAbi, functionName: 'setKeeper', args: [v as `0x${string}`] } : null)}
            onDone={doRefetch}
          />
        </AdminCard>

        <AdminCard title="oracle">
          <ThreeField
            label="oracle policy"
            fields={[
              { placeholder: `max age s (${maxOracleAge?.toString() ?? '—'})` },
              { placeholder: `min bnb/usd 1e18 (${minBnbUsd?.toString() ?? '—'})` },
              { placeholder: `max bnb/usd 1e18 (${maxBnbUsd?.toString() ?? '—'})` },
            ]}
            build={(vals) =>
              vals.every((v) => /^\d+$/.test(v))
                ? { address, abi: MarketplaceAbi, functionName: 'setOraclePolicy', args: [BigInt(vals[0]!), BigInt(vals[1]!), BigInt(vals[2]!)] }
                : null
            }
            onDone={doRefetch}
          />
          <Setter
            label="max bnbull peg age · s"
            current={maxBnbullPegAge?.toString() ?? '—'}
            placeholder="seconds"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MarketplaceAbi, functionName: 'setMaxBnbullPegAge', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
        </AdminCard>
      </div>

      <SweepPotFee address={address} potFeeUndelivered={potFeeUndelivered} onDone={doRefetch} />

      <AdminCard title="wires (timelocked)">
        <p className="text-[11px] text-bull-text-faint">
          each slot: propose, wait out the {fmtSeconds(wiringDelay)} delay, then commit — or cancel.
        </p>
        {WIRE_SLOTS.map((w) => (
          <WireRow key={w.slot} abi={MarketplaceAbi} address={address} slot={w.slot} slotLabel={w.label} wire={wires[w.slot]} onDone={doRefetch} />
        ))}
        <Setter
          label="wiring delay · seconds"
          current={fmtSeconds(wiringDelay)}
          placeholder="seconds"
          inputMode="numeric"
          buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MarketplaceAbi, functionName: 'setWiringDelay', args: [BigInt(v)] } : null)}
          onDone={doRefetch}
        />
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <SocialsControl
          key={`${website ?? ''}|${twitter ?? ''}|${telegram ?? ''}`}
          abi={MarketplaceAbi}
          address={address}
          current={{ website, twitter, telegram }}
          onDone={doRefetch}
        />
        <RescueControl abi={MarketplaceAbi} address={address} onDone={doRefetch} />
      </div>
    </AdminSection>
  );
}

/** sweepPotFee(asset, to) — pushes the accrued pot-fee balance for an asset out. */
function SweepPotFee({
  address,
  potFeeUndelivered,
  onDone,
}: {
  address: `0x${string}`;
  potFeeUndelivered: bigint | undefined;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [asset, setAsset] = useState('');
  const [to, setTo] = useState('');

  return (
    <AdminCard title="money tools">
      <p className="text-[11px] text-bull-text-faint">
        native pot fee undelivered right now: {potFeeUndelivered?.toString() ?? '—'} (raw). sweep
        pushes the accrued pot fee for an asset to a destination. simulated before you sign.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <span className="w-40 shrink-0 text-xs text-bull-text-faint">sweep pot fee · asset, to</span>
        <AdminInput value={asset} onChange={(e) => setAsset(e.target.value)} placeholder="asset 0x… (or 0x0 for native)" className="w-64" />
        <AdminInput value={to} onChange={(e) => setTo(e.target.value)} placeholder="to 0x…" className="w-52" />
        <WriteButton
          tx={tx}
          disabled={!isAddr(asset) || !isAddr(to)}
          onClick={() => void tx.run({ address, abi: MarketplaceAbi, functionName: 'sweepPotFee', args: [asset.trim() as `0x${string}`, to.trim() as `0x${string}`] })}
        >
          sweep
        </WriteButton>
      </div>
      <TxStatus tx={tx} />
    </AdminCard>
  );
}
