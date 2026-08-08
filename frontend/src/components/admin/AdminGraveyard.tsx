'use client';

/**
 * THE BUTCHER (Graveyard) — dead-bull revivals, live, plus every owner knob off
 * `frontend/src/lib/abi/Graveyard.ts`:
 *
 *   setLadders (the resurrection price ladders) · setBnbullPerUsd · setShares
 *   · setMaxResurrects · setOwnerPriorityWindow · setDiscountBps · setKeeper
 *   · setTreasury · setLpTreasury · setOraclePolicy · setMaxBnbullPegAge
 *   · pause/unpause · setSocials · rescueToken, plus the money movers
 *   (withdrawPending / sweepPending / withdrawLpUndelivered) and the timelocked
 *   wire flow.
 *
 * There is no single "resurrection cost" setter — the cost comes from the two
 * ladders (owner + takeover, in dollars) and `bnbullPerUsd`. Every write is
 * simulated before the wallet opens.
 */
import { useState } from 'react';
import { useReadContracts } from 'wagmi';
import { formatUnits, parseUnits } from 'viem';
import { GraveyardAbi } from '@/lib/abi';
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
  TwoField,
  TxStatus,
  WireRow,
  WriteButton,
  asAddr,
  asBig,
  asBool,
  asString,
  asWire,
  fmtBps,
  fmtDollars,
  fmtSeconds,
  isAddr,
  useAdminTx,
} from './adminUi';

const WIRE_SLOTS = [
  { slot: 0, label: 'duel (the fights)' },
  { slot: 1, label: 'mintdrop' },
  { slot: 2, label: 'price feed (chainlink)' },
] as const;

export function AdminGraveyard() {
  const address = contractAddress('graveyard');

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { abi: GraveyardAbi, address, functionName: 'paused' }, // 0
          { abi: GraveyardAbi, address, functionName: 'owner' }, // 1
          { abi: GraveyardAbi, address, functionName: 'treasury' }, // 2
          { abi: GraveyardAbi, address, functionName: 'lpTreasury' }, // 3
          { abi: GraveyardAbi, address, functionName: 'keeper' }, // 4
          { abi: GraveyardAbi, address, functionName: 'potShareBps' }, // 5
          { abi: GraveyardAbi, address, functionName: 'lpShareBps' }, // 6
          { abi: GraveyardAbi, address, functionName: 'ownerPriorityWindow' }, // 7
          { abi: GraveyardAbi, address, functionName: 'maxResurrects' }, // 8
          { abi: GraveyardAbi, address, functionName: 'bnbullPerUsd' }, // 9
          { abi: GraveyardAbi, address, functionName: 'ownerLadder' }, // 10
          { abi: GraveyardAbi, address, functionName: 'takeoverLadder' }, // 11
          { abi: GraveyardAbi, address, functionName: 'maxOracleAge' }, // 12
          { abi: GraveyardAbi, address, functionName: 'minBnbUsd' }, // 13
          { abi: GraveyardAbi, address, functionName: 'maxBnbUsd' }, // 14
          { abi: GraveyardAbi, address, functionName: 'maxBnbullPegAge' }, // 15
          { abi: GraveyardAbi, address, functionName: 'lpUndelivered' }, // 16
          { abi: GraveyardAbi, address, functionName: 'wiringDelay' }, // 17
          { abi: GraveyardAbi, address, functionName: 'bnbull' }, // 18
          { abi: GraveyardAbi, address, functionName: 'website' }, // 19
          { abi: GraveyardAbi, address, functionName: 'twitter' }, // 20
          { abi: GraveyardAbi, address, functionName: 'telegram' }, // 21
          { abi: GraveyardAbi, address, functionName: 'wireOf', args: [0] }, // 22
          { abi: GraveyardAbi, address, functionName: 'wireOf', args: [1] }, // 23
          { abi: GraveyardAbi, address, functionName: 'wireOf', args: [2] }, // 24
        ]
      : [],
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const paused = asBool(data?.[0]);
  const owner = asAddr(data?.[1]);
  const treasury = asAddr(data?.[2]);
  const lpTreasury = asAddr(data?.[3]);
  const keeper = asAddr(data?.[4]);
  const potShareBps = asBig(data?.[5]);
  const lpShareBps = asBig(data?.[6]);
  const ownerPriorityWindow = asBig(data?.[7]);
  const maxResurrects = asBig(data?.[8]);
  const bnbullPerUsd = asBig(data?.[9]);
  const ownerLadder = data?.[10]?.status === 'success' ? (data[10].result as readonly bigint[]) : undefined;
  const takeoverLadder = data?.[11]?.status === 'success' ? (data[11].result as readonly bigint[]) : undefined;
  const maxOracleAge = asBig(data?.[12]);
  const minBnbUsd = asBig(data?.[13]);
  const maxBnbUsd = asBig(data?.[14]);
  const maxBnbullPegAge = asBig(data?.[15]);
  const lpUndelivered = asBig(data?.[16]);
  const wiringDelay = asBig(data?.[17]);
  const bnbull = asAddr(data?.[18]);
  const website = asString(data?.[19]);
  const twitter = asString(data?.[20]);
  const telegram = asString(data?.[21]);
  const wires = [asWire(data?.[22]), asWire(data?.[23]), asWire(data?.[24])];

  const doRefetch = () => void refetch();

  if (!address) {
    return (
      <AdminSection title="the butcher">
        <AdminCard>
          <p className="text-sm text-bull-text-dim">the graveyard contract is not deployed yet (NEXT_PUBLIC_GRAVEYARD unset).</p>
        </AdminCard>
      </AdminSection>
    );
  }

  return (
    <AdminSection title="the butcher" sub="dead-bull revivals: the price ladders, the fee split, the holder priority window and the death cap.">
      <AdminCard>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <BigStat label="pot share" value={fmtBps(potShareBps)} sub="of every revive" tone="gold" />
          <BigStat label="lp share" value={fmtBps(lpShareBps)} />
          <BigStat label="max revives" value={maxResurrects?.toString() ?? '—'} tone="plain" />
          <BigStat label="state" value={paused === undefined ? '—' : paused ? 'PAUSED' : 'open'} tone={paused ? 'red' : 'plain'} />
        </div>
        <div className="grid gap-x-6 gap-y-1 border-t border-bull-border/60 pt-1 md:grid-cols-2">
          <KV k="owner ladder ($)" v={ladderText(ownerLadder)} />
          <KV k="takeover ladder ($)" v={ladderText(takeoverLadder)} />
          <KV k="holder priority window" v={fmtSeconds(ownerPriorityWindow)} />
          <KV k="bnbull per usd" v={bnbullPerUsd?.toString() ?? '—'} />
          <KV k="lp undelivered" v={bnbullPerUsd === undefined ? '—' : (lpUndelivered?.toString() ?? '—')} />
          <KV k="treasury" v={<Addr addr={treasury} />} />
          <KV k="lp treasury" v={<Addr addr={lpTreasury} />} />
          <KV k="keeper" v={<Addr addr={keeper} />} />
          <KV k="owner" v={<Addr addr={owner} />} />
          <KV k="contract" v={<Addr addr={address} />} />
        </div>
      </AdminCard>

      <LadderEditor address={address} ownerLadder={ownerLadder} takeoverLadder={takeoverLadder} onDone={doRefetch} />

      <div className="grid gap-4 lg:grid-cols-2">
        <AdminCard title="switches + thresholds">
          <Toggle
            label="revives"
            on={paused}
            onWord="PAUSED"
            offWord="open"
            dangerWhenOff
            buildCall={(next) => ({ address, abi: GraveyardAbi, functionName: next ? 'pause' : 'unpause' })}
            onDone={doRefetch}
          />
          <Setter
            label="max revives per bull"
            current={maxResurrects?.toString() ?? '—'}
            placeholder="e.g. 5"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: GraveyardAbi, functionName: 'setMaxResurrects', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="holder priority · hours"
            current={fmtSeconds(ownerPriorityWindow)}
            placeholder="hours, e.g. 24"
            inputMode="decimal"
            hint="how long the previous owner keeps the cheaper claim before takeovers open. set in hours; written as seconds."
            buildCall={(v) => {
              const h = Number(v);
              if (!Number.isFinite(h) || h < 0) return null;
              return { address, abi: GraveyardAbi, functionName: 'setOwnerPriorityWindow', args: [BigInt(Math.round(h * 3600))] };
            }}
            onDone={doRefetch}
          />
          <Setter
            label="bnbull per usd · raw"
            current={bnbullPerUsd?.toString() ?? '—'}
            placeholder="raw units"
            inputMode="numeric"
            hint="the fixed bnbull/usd rate used to price a bnbull-paid revive."
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: GraveyardAbi, functionName: 'setBnbullPerUsd', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
        </AdminCard>

        <AdminCard title="shares + oracle">
          <TwoField
            label="shares · pot, lp (bps)"
            aPlaceholder={potShareBps?.toString() ?? 'pot bps'}
            bPlaceholder={lpShareBps?.toString() ?? 'lp bps'}
            build={(a, b) =>
              /^\d+$/.test(a) && /^\d+$/.test(b) ? { address, abi: GraveyardAbi, functionName: 'setShares', args: [BigInt(a), BigInt(b)] } : null
            }
            hint="the rest of every revive lands with the dev treasury."
            onDone={doRefetch}
          />
          <ThreeField
            label="oracle policy"
            fields={[
              { placeholder: `max age s (${maxOracleAge?.toString() ?? '—'})` },
              { placeholder: `min bnb/usd 1e18 (${minBnbUsd?.toString() ?? '—'})` },
              { placeholder: `max bnb/usd 1e18 (${maxBnbUsd?.toString() ?? '—'})` },
            ]}
            build={(vals) =>
              vals.every((v) => /^\d+$/.test(v))
                ? { address, abi: GraveyardAbi, functionName: 'setOraclePolicy', args: [BigInt(vals[0]!), BigInt(vals[1]!), BigInt(vals[2]!)] }
                : null
            }
            onDone={doRefetch}
          />
          <Setter
            label="max bnbull peg age · s"
            current={maxBnbullPegAge?.toString() ?? '—'}
            placeholder="seconds"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: GraveyardAbi, functionName: 'setMaxBnbullPegAge', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
        </AdminCard>
      </div>

      <AdminCard title="addresses + discount">
        <Setter
          label="treasury"
          current={<Addr addr={treasury} />}
          placeholder="0x…"
          buildCall={(v) => (isAddr(v) ? { address, abi: GraveyardAbi, functionName: 'setTreasury', args: [v as `0x${string}`] } : null)}
          onDone={doRefetch}
        />
        <Setter
          label="lp treasury"
          current={<Addr addr={lpTreasury} />}
          placeholder="0x…"
          buildCall={(v) => (isAddr(v) ? { address, abi: GraveyardAbi, functionName: 'setLpTreasury', args: [v as `0x${string}`] } : null)}
          onDone={doRefetch}
        />
        <Setter
          label="keeper"
          current={<Addr addr={keeper} />}
          placeholder="0x…"
          buildCall={(v) => (isAddr(v) ? { address, abi: GraveyardAbi, functionName: 'setKeeper', args: [v as `0x${string}`] } : null)}
          onDone={doRefetch}
        />
        <Setter
          label="bnbull discount · bps"
          current="—"
          placeholder="bps"
          inputMode="numeric"
          hint="the revive discount for paying in bnbull. applies to the bnbull token."
          buildCall={(v) =>
            /^\d+$/.test(v) && bnbull ? { address, abi: GraveyardAbi, functionName: 'setDiscountBps', args: [bnbull, BigInt(v)] } : null
          }
          onDone={doRefetch}
        />
      </AdminCard>

      <GraveyardMoneyTools address={address} lpUndelivered={lpUndelivered} onDone={doRefetch} />

      <AdminCard title="wires (timelocked)">
        <p className="text-[11px] text-bull-text-faint">
          each slot: propose, wait out the {fmtSeconds(wiringDelay)} delay, then commit — or cancel.
        </p>
        {WIRE_SLOTS.map((w) => (
          <WireRow key={w.slot} abi={GraveyardAbi} address={address} slot={w.slot} slotLabel={w.label} wire={wires[w.slot]} onDone={doRefetch} />
        ))}
        <Setter
          label="wiring delay · seconds"
          current={fmtSeconds(wiringDelay)}
          placeholder="seconds"
          inputMode="numeric"
          buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: GraveyardAbi, functionName: 'setWiringDelay', args: [BigInt(v)] } : null)}
          onDone={doRefetch}
        />
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <SocialsControl
          key={`${website ?? ''}|${twitter ?? ''}|${telegram ?? ''}`}
          abi={GraveyardAbi}
          address={address}
          current={{ website, twitter, telegram }}
          onDone={doRefetch}
        />
        <RescueControl abi={GraveyardAbi} address={address} onDone={doRefetch} />
      </div>
    </AdminSection>
  );
}

function ladderText(ladder: readonly bigint[] | undefined): string {
  if (!ladder || ladder.length === 0) return '—';
  return ladder.map((v) => fmtDollars(v)).join(' → ');
}

/** Two dollar ladders, both written in one setLadders(owner_[], takeover_[]) tx. */
function LadderEditor({
  address,
  ownerLadder,
  takeoverLadder,
  onDone,
}: {
  address: `0x${string}`;
  ownerLadder: readonly bigint[] | undefined;
  takeoverLadder: readonly bigint[] | undefined;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [ownerStr, setOwnerStr] = useState('');
  const [takeoverStr, setTakeoverStr] = useState('');
  const [localErr, setLocalErr] = useState<string | null>(null);

  const ownerNow = ownerLadder?.map((v) => formatUnits(v, 18)).join(', ') ?? '';
  const takeoverNow = takeoverLadder?.map((v) => formatUnits(v, 18)).join(', ') ?? '';

  function parseList(s: string): bigint[] | null {
    const parts = s.split(',').map((p) => p.trim()).filter((p) => p.length > 0);
    try {
      return parts.map((p) => parseUnits(p, 18));
    } catch {
      return null;
    }
  }

  const submit = () => {
    setLocalErr(null);
    const o = parseList(ownerStr || ownerNow);
    const t = parseList(takeoverStr || takeoverNow);
    if (!o || !t) {
      setLocalErr('both ladders must be comma-separated dollar amounts');
      return;
    }
    void tx.run({ address, abi: GraveyardAbi, functionName: 'setLadders', args: [o, t] });
  };

  return (
    <AdminCard title="revive price ladders (dollars, one tx)">
      <p className="text-[11px] text-bull-text-faint">
        comma-separated dollar amounts, one rung per revive. the owner ladder is what the previous
        holder pays; the takeover ladder is what a stranger pays to revive and claim. leave a field
        blank to keep that ladder as it is.
      </p>
      <label className="space-y-1 text-xs text-bull-text-faint">
        <span>owner ladder · now {ownerNow || '—'}</span>
        <AdminInput value={ownerStr} onChange={(e) => setOwnerStr(e.target.value)} placeholder="e.g. 25, 50, 100" className="w-full" />
      </label>
      <label className="space-y-1 text-xs text-bull-text-faint">
        <span>takeover ladder · now {takeoverNow || '—'}</span>
        <AdminInput value={takeoverStr} onChange={(e) => setTakeoverStr(e.target.value)} placeholder="e.g. 40, 80, 160" className="w-full" />
      </label>
      <WriteButton tx={tx} onClick={submit}>
        write ladders
      </WriteButton>
      {localErr && <p className="font-mono text-xs text-bull-red">✗ {localErr}</p>}
      <TxStatus tx={tx} />
    </AdminCard>
  );
}

/** withdrawLpUndelivered / withdrawPending / sweepPending. Raw, simulated. */
function GraveyardMoneyTools({
  address,
  lpUndelivered,
  onDone,
}: {
  address: `0x${string}`;
  lpUndelivered: bigint | undefined;
  onDone: () => void;
}) {
  const lpTx = useAdminTx(onDone);
  const wpTx = useAdminTx(onDone);
  const spTx = useAdminTx(onDone);
  const [lpTo, setLpTo] = useState('');
  const [wpSrc, setWpSrc] = useState('');
  const [wpTo, setWpTo] = useState('');
  const [wpAmt, setWpAmt] = useState('');
  const [spSrc, setSpSrc] = useState('');
  const [spAmt, setSpAmt] = useState('');
  const int = (v: string) => /^\d+$/.test(v.trim());

  return (
    <AdminCard title="money tools">
      <p className="text-[11px] text-bull-text-faint">
        `src` is a PotSource enum index. every one of these is simulated first, so a wrong index or
        amount is stopped with a reason before you sign.
      </p>

      <div className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-40 shrink-0 text-xs text-bull-text-faint">
            withdraw lp undelivered ({lpUndelivered?.toString() ?? '—'})
          </span>
          <AdminInput value={lpTo} onChange={(e) => setLpTo(e.target.value)} placeholder="to 0x…" className="w-52" />
          <WriteButton
            tx={lpTx}
            disabled={!isAddr(lpTo)}
            onClick={() => void lpTx.run({ address, abi: GraveyardAbi, functionName: 'withdrawLpUndelivered', args: [lpTo.trim() as `0x${string}`] })}
          >
            withdraw
          </WriteButton>
        </div>
        <TxStatus tx={lpTx} />
      </div>

      <div className="space-y-1">
        <span className="text-xs text-bull-text-faint">withdraw pending · src, to, amount (raw)</span>
        <div className="flex flex-wrap items-center gap-2">
          <AdminInput value={wpSrc} onChange={(e) => setWpSrc(e.target.value)} placeholder="src #" inputMode="numeric" className="w-20" />
          <AdminInput value={wpTo} onChange={(e) => setWpTo(e.target.value)} placeholder="to 0x…" className="w-52" />
          <AdminInput value={wpAmt} onChange={(e) => setWpAmt(e.target.value)} placeholder="amount (raw)" inputMode="numeric" className="w-32" />
          <WriteButton
            tx={wpTx}
            disabled={!int(wpSrc) || !isAddr(wpTo) || !int(wpAmt)}
            onClick={() =>
              void wpTx.run({ address, abi: GraveyardAbi, functionName: 'withdrawPending', args: [BigInt(wpSrc), wpTo.trim() as `0x${string}`, BigInt(wpAmt)] })
            }
          >
            withdraw
          </WriteButton>
        </div>
        <TxStatus tx={wpTx} />
      </div>

      <div className="space-y-1">
        <span className="text-xs text-bull-text-faint">sweep pending (route into the pot) · src, amount (raw)</span>
        <div className="flex flex-wrap items-center gap-2">
          <AdminInput value={spSrc} onChange={(e) => setSpSrc(e.target.value)} placeholder="src #" inputMode="numeric" className="w-20" />
          <AdminInput value={spAmt} onChange={(e) => setSpAmt(e.target.value)} placeholder="amount (raw)" inputMode="numeric" className="w-32" />
          <WriteButton
            tx={spTx}
            disabled={!int(spSrc) || !int(spAmt)}
            onClick={() => void spTx.run({ address, abi: GraveyardAbi, functionName: 'sweepPending', args: [BigInt(spSrc), BigInt(spAmt)] })}
          >
            sweep
          </WriteButton>
        </div>
        <TxStatus tx={spTx} />
      </div>
    </AdminCard>
  );
}
