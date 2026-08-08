'use client';

/**
 * THE FIGHTS — Duel economics, live, plus every owner knob off
 * `frontend/src/lib/abi/Duel.ts`:
 *
 *   pause / unpause · setAllowSelfDuel · setDefaultDevShareBps · setPotShareBps
 *   · setLossesToDie · setUsdFightPrice · setDevTreasury · setMarketplace
 *   · setSocials · resetStreak · rescueToken · addFightAsset, and per-asset:
 *   setFightCost · setDiscountBps · setDevShareBps · setMinTicketStake.
 *
 * Plus the timelocked wire flow (proposeWire/commitWire/cancelWire) over the
 * four wire slots, from the `wires()` order: graveyard, jackpotBnbull,
 * jackpotBnb, mintDrop.
 *
 * Every setter shows its current on-chain value, and every write is simulated
 * before the wallet opens.
 */
import { useReadContracts } from 'wagmi';
import { parseUnits } from 'viem';
import { DuelAbi, Erc20Abi } from '@/lib/abi';
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
  Toggle,
  WireRow,
  asAddr,
  asBig,
  asBool,
  asString,
  asWire,
  fmtAmount,
  fmtBps,
  fmtDollars,
  fmtSeconds,
  isAddr,
  useAdminTx,
  WriteButton,
  TxStatus,
} from './adminUi';
import { useState } from 'react';

const WIRE_SLOTS = [
  { slot: 0, label: 'graveyard (the butcher)' },
  { slot: 1, label: 'jackpot · $BNBULL pot' },
  { slot: 2, label: 'jackpot · BNB pot' },
  { slot: 3, label: 'mintdrop' },
] as const;

export function AdminFights() {
  const address = contractAddress('duel');

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { abi: DuelAbi, address, functionName: 'paused' }, // 0
          { abi: DuelAbi, address, functionName: 'owner' }, // 1
          { abi: DuelAbi, address, functionName: 'devTreasury' }, // 2
          { abi: DuelAbi, address, functionName: 'allowSelfDuel' }, // 3
          { abi: DuelAbi, address, functionName: 'potShareBps' }, // 4
          { abi: DuelAbi, address, functionName: 'lossesToDie' }, // 5
          { abi: DuelAbi, address, functionName: 'marketplace' }, // 6
          { abi: DuelAbi, address, functionName: 'defaultDevShareBps' }, // 7
          { abi: DuelAbi, address, functionName: 'usdFightPrice1e18' }, // 8
          { abi: DuelAbi, address, functionName: 'getFightAssets' }, // 9
          { abi: DuelAbi, address, functionName: 'wiringDelay' }, // 10
          { abi: DuelAbi, address, functionName: 'website' }, // 11
          { abi: DuelAbi, address, functionName: 'twitter' }, // 12
          { abi: DuelAbi, address, functionName: 'telegram' }, // 13
          { abi: DuelAbi, address, functionName: 'wireOf', args: [0] }, // 14
          { abi: DuelAbi, address, functionName: 'wireOf', args: [1] }, // 15
          { abi: DuelAbi, address, functionName: 'wireOf', args: [2] }, // 16
          { abi: DuelAbi, address, functionName: 'wireOf', args: [3] }, // 17
        ]
      : [],
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const paused = asBool(data?.[0]);
  const owner = asAddr(data?.[1]);
  const devTreasury = asAddr(data?.[2]);
  const allowSelfDuel = asBool(data?.[3]);
  const potShareBps = asBig(data?.[4]);
  const lossesToDie = asBig(data?.[5]);
  const marketplace = asAddr(data?.[6]);
  const defaultDevShareBps = asBig(data?.[7]);
  const usdFightPrice = asBig(data?.[8]);
  const fightAssets = data?.[9]?.status === 'success' ? (data[9].result as readonly `0x${string}`[]) : [];
  const wiringDelay = asBig(data?.[10]);
  const website = asString(data?.[11]);
  const twitter = asString(data?.[12]);
  const telegram = asString(data?.[13]);
  const wires = [asWire(data?.[14]), asWire(data?.[15]), asWire(data?.[16]), asWire(data?.[17])];

  // Per-asset detail: symbol, decimals, cost, cap, devShare, discount, minStake.
  const assetReads = useReadContracts({
    allowFailure: true,
    contracts: fightAssets.flatMap((a) => [
      { abi: Erc20Abi, address: a, functionName: 'symbol' as const },
      { abi: Erc20Abi, address: a, functionName: 'decimals' as const },
      { abi: DuelAbi, address: address!, functionName: 'fightCostOf' as const, args: [a] as const },
      { abi: DuelAbi, address: address!, functionName: 'maxFightCostOf' as const, args: [a] as const },
      { abi: DuelAbi, address: address!, functionName: 'devShareBpsOf' as const, args: [a] as const },
      { abi: DuelAbi, address: address!, functionName: 'discountBpsOf' as const, args: [a] as const },
      { abi: DuelAbi, address: address!, functionName: 'minTicketStakeOf' as const, args: [a] as const },
    ]),
    query: { enabled: !!address && fightAssets.length > 0, refetchInterval: 12_000 },
  });

  const assets = fightAssets.map((assetAddr, i) => {
    const base = i * 7;
    const r = assetReads.data;
    return {
      address: assetAddr,
      symbol: asString(r?.[base]) ?? '?',
      decimals: Number(asBig(r?.[base + 1]) ?? 18n),
      cost: asBig(r?.[base + 2]),
      max: asBig(r?.[base + 3]),
      devShare: asBig(r?.[base + 4]),
      discount: asBig(r?.[base + 5]),
      minStake: asBig(r?.[base + 6]),
    };
  });

  const doRefetch = () => {
    void refetch();
    void assetReads.refetch();
  };

  if (!address) {
    return (
      <AdminSection title="the fights">
        <AdminCard>
          <p className="text-sm text-bull-text-dim">the duel contract is not deployed yet (NEXT_PUBLIC_DUEL unset).</p>
        </AdminCard>
      </AdminSection>
    );
  }

  return (
    <AdminSection title="the fights" sub="duel economics: the dev cut, the pot slice, the death threshold and the per-asset fight costs.">
      <AdminCard>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <BigStat label="pot slice" value={fmtBps(potShareBps)} sub="of every fight" tone="gold" />
          <BigStat label="default dev cut" value={fmtBps(defaultDevShareBps)} />
          <BigStat label="losses to die" value={lossesToDie?.toString() ?? '—'} tone="plain" />
          <BigStat label="state" value={paused === undefined ? '—' : paused ? 'PAUSED' : 'live'} tone={paused ? 'red' : 'plain'} />
        </div>
        <div className="grid gap-x-6 gap-y-1 border-t border-bull-border/60 pt-1 md:grid-cols-2">
          <KV k="usd fight price" v={fmtDollars(usdFightPrice)} />
          <KV k="self-duel allowed" v={allowSelfDuel === undefined ? '—' : allowSelfDuel ? 'yes' : 'no'} />
          <KV k="dev treasury" v={<Addr addr={devTreasury} />} />
          <KV k="marketplace" v={<Addr addr={marketplace} />} />
          <KV k="wiring delay" v={fmtSeconds(wiringDelay)} />
          <KV k="owner" v={<Addr addr={owner} />} />
          <KV k="contract" v={<Addr addr={address} />} />
        </div>
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <AdminCard title="switches">
          <Toggle
            label="fights"
            on={paused}
            onWord="PAUSED"
            offWord="live"
            dangerWhenOff
            buildCall={(next) => ({ address, abi: DuelAbi, functionName: next ? 'pause' : 'unpause' })}
            onDone={doRefetch}
          />
          <Toggle
            label="self-duel"
            on={allowSelfDuel}
            onWord="allowed"
            offWord="blocked"
            buildCall={(next) => ({ address, abi: DuelAbi, functionName: 'setAllowSelfDuel', args: [next] })}
            hint="whether a wallet is allowed to fight its own two bulls."
            onDone={doRefetch}
          />
        </AdminCard>

        <AdminCard title="economics (bps + thresholds)">
          <Setter
            label="pot slice · bps"
            current={potShareBps?.toString() ?? '—'}
            placeholder="e.g. 3000"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: DuelAbi, functionName: 'setPotShareBps', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="default dev cut · bps"
            current={defaultDevShareBps?.toString() ?? '—'}
            placeholder="e.g. 1000"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: DuelAbi, functionName: 'setDefaultDevShareBps', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="losses to die"
            current={lossesToDie?.toString() ?? '—'}
            placeholder="e.g. 5"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: DuelAbi, functionName: 'setLossesToDie', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="usd fight price ($)"
            current={fmtDollars(usdFightPrice)}
            placeholder="dollars, e.g. 2"
            inputMode="decimal"
            hint="the flat dollar cost of a fight, converted to the paid asset at fight time."
            buildCall={(v) => {
              try {
                return { address, abi: DuelAbi, functionName: 'setUsdFightPrice', args: [parseUnits(v, 18)] };
              } catch {
                return null;
              }
            }}
            onDone={doRefetch}
          />
        </AdminCard>
      </div>

      <AdminCard title="addresses">
        <Setter
          label="dev treasury"
          current={<Addr addr={devTreasury} />}
          placeholder="0x…"
          buildCall={(v) => (isAddr(v) ? { address, abi: DuelAbi, functionName: 'setDevTreasury', args: [v as `0x${string}`] } : null)}
          onDone={doRefetch}
        />
        <Setter
          label="marketplace"
          current={<Addr addr={marketplace} />}
          placeholder="0x…"
          buildCall={(v) => (isAddr(v) ? { address, abi: DuelAbi, functionName: 'setMarketplace', args: [v as `0x${string}`] } : null)}
          onDone={doRefetch}
        />
        <Setter
          label="reset streak · tokenId"
          current="—"
          placeholder="bull id"
          inputMode="numeric"
          hint="clears a bull's consecutive-loss count. owner intervention only."
          buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: DuelAbi, functionName: 'resetStreak', args: [BigInt(v)] } : null)}
          onDone={doRefetch}
        />
      </AdminCard>

      <AdminCard title="fight assets + per-asset costs">
        {assets.length === 0 ? (
          <p className="text-sm text-bull-text-dim">no fight assets registered yet.</p>
        ) : (
          <div className="space-y-4">
            {assets.map((a) => (
              <AssetControls key={a.address} duel={address} asset={a} onDone={doRefetch} />
            ))}
          </div>
        )}
        <div className="border-t border-bull-border/60 pt-3">
          <AddFightAsset duel={address} onDone={doRefetch} />
        </div>
      </AdminCard>

      <AdminCard title="wires (timelocked)">
        <p className="text-[11px] text-bull-text-faint">
          each slot: propose a new target, wait out the {fmtSeconds(wiringDelay)} delay, then commit
          — or cancel a pending proposal.
        </p>
        {WIRE_SLOTS.map((w) => (
          <WireRow key={w.slot} abi={DuelAbi} address={address} slot={w.slot} slotLabel={w.label} wire={wires[w.slot]} onDone={doRefetch} />
        ))}
        <Setter
          label="wiring delay · seconds"
          current={fmtSeconds(wiringDelay)}
          placeholder="seconds"
          inputMode="numeric"
          buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: DuelAbi, functionName: 'setWiringDelay', args: [BigInt(v)] } : null)}
          onDone={doRefetch}
        />
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <SocialsControl
          key={`${website ?? ''}|${twitter ?? ''}|${telegram ?? ''}`}
          abi={DuelAbi}
          address={address}
          current={{ website, twitter, telegram }}
          onDone={doRefetch}
        />
        <RescueControl abi={DuelAbi} address={address} onDone={doRefetch} />
      </div>
    </AdminSection>
  );
}

function AssetControls({
  duel,
  asset,
  onDone,
}: {
  duel: `0x${string}`;
  asset: {
    address: `0x${string}`;
    symbol: string;
    decimals: number;
    cost: bigint | undefined;
    max: bigint | undefined;
    devShare: bigint | undefined;
    discount: bigint | undefined;
    minStake: bigint | undefined;
  };
  onDone: () => void;
}) {
  return (
    <div className="space-y-1 rounded border border-bull-border/60 p-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="font-mono text-sm text-bull-text">{asset.symbol}</span>
        <span className="font-mono text-[11px] text-bull-text-faint">
          cap {fmtAmount(asset.max, asset.decimals)} · <Addr addr={asset.address} />
        </span>
      </div>
      <Setter
        label={`fight cost · ${asset.symbol}`}
        current={fmtAmount(asset.cost, asset.decimals)}
        placeholder="whole tokens"
        inputMode="decimal"
        buildCall={(v) => {
          try {
            return { address: duel, abi: DuelAbi, functionName: 'setFightCost', args: [asset.address, parseUnits(v, asset.decimals)] };
          } catch {
            return null;
          }
        }}
        onDone={onDone}
      />
      <Setter
        label="dev share · bps"
        current={asset.devShare?.toString() ?? '—'}
        placeholder="bps"
        inputMode="numeric"
        buildCall={(v) => (/^\d+$/.test(v) ? { address: duel, abi: DuelAbi, functionName: 'setDevShareBps', args: [asset.address, BigInt(v)] } : null)}
        onDone={onDone}
      />
      <Setter
        label="discount · bps"
        current={asset.discount?.toString() ?? '—'}
        placeholder="bps"
        inputMode="numeric"
        buildCall={(v) => (/^\d+$/.test(v) ? { address: duel, abi: DuelAbi, functionName: 'setDiscountBps', args: [asset.address, BigInt(v)] } : null)}
        onDone={onDone}
      />
      <Setter
        label={`min ticket stake · ${asset.symbol}`}
        current={fmtAmount(asset.minStake, asset.decimals)}
        placeholder="whole tokens"
        inputMode="decimal"
        buildCall={(v) => {
          try {
            return { address: duel, abi: DuelAbi, functionName: 'setMinTicketStake', args: [asset.address, parseUnits(v, asset.decimals)] };
          } catch {
            return null;
          }
        }}
        onDone={onDone}
      />
    </div>
  );
}

function AddFightAsset({ duel, onDone }: { duel: `0x${string}`; onDone: () => void }) {
  const tx = useAdminTx(onDone);
  const [asset, setAsset] = useState('');
  const [maxCost, setMaxCost] = useState('');
  const [devBps, setDevBps] = useState('');
  const ok = isAddr(asset) && /^\d+$/.test(maxCost.trim()) && /^\d+$/.test(devBps.trim());

  return (
    <div className="space-y-2">
      <div className="bull-header text-sm text-bull-text">add a fight asset</div>
      <p className="text-[11px] text-bull-text-faint">
        max cost is in the asset&rsquo;s own raw base units and is fixed forever once added — it is
        the ceiling a re-price can never exceed. dev bps is the per-asset dev cut.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <AdminInput value={asset} onChange={(e) => setAsset(e.target.value)} placeholder="asset 0x…" className="w-64" />
        <AdminInput value={maxCost} onChange={(e) => setMaxCost(e.target.value)} placeholder="max cost (raw units)" inputMode="numeric" className="w-44" />
        <AdminInput value={devBps} onChange={(e) => setDevBps(e.target.value)} placeholder="dev bps" inputMode="numeric" className="w-24" />
        <WriteButton
          tx={tx}
          disabled={!ok}
          onClick={() =>
            ok &&
            void tx.run({
              address: duel,
              abi: DuelAbi,
              functionName: 'addFightAsset',
              args: [asset.trim() as `0x${string}`, BigInt(maxCost.trim()), BigInt(devBps.trim())],
            })
          }
        >
          add asset
        </WriteButton>
      </div>
      <TxStatus tx={tx} />
    </div>
  );
}
