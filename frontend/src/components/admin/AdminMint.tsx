'use client';

/**
 * THE MINT — MintDrop, live, plus every owner knob off
 * `frontend/src/lib/abi/MintDrop.ts`:
 *
 *   setPriceTiers · setPotShares · setLpShare · setDiscountBps · setAirdropPerMint
 *   · setInlineSlippageBps · setMinPoolLiquidity(+Alt) · setOraclePolicy
 *   · setKeeper · setTreasury · setLpTreasury · setBnbullPaymentSellPolicy
 *   · pause/unpause · setSocials · rescueToken, plus the money tools
 *   (sweepBnbPot / sweepBnbullPot / withdrawPendingForManualBuy /
 *   withdrawLpUndelivered / donatePotNative / donatePotToken) and the
 *   timelocked wire flow.
 *
 * Prices are the protocol's fixed 1e18 dollar scale; BNBULL amounts are 18dp.
 * Every write is simulated before the wallet opens.
 */
import { useState } from 'react';
import { useReadContracts } from 'wagmi';
import { formatUnits, parseUnits } from 'viem';
import { BullPenAbi, MintDropAbi } from '@/lib/abi';
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
  fmtAmount,
  fmtBps,
  fmtSeconds,
  isAddr,
  useAdminTx,
} from './adminUi';

const BNBULL_DECIMALS = 18;

/**
 * ⚠ SLOT NUMBERS ARE THE `MintDrop.Wire` ENUM AND THEY ARE POSITIONAL. Slot 4
 * (`SwapIntermediate`) is the dormant one and is expected to stay zero forever;
 * slot 5 is the pen.
 *
 * ⚠ SLOT 5 IS DELIBERATELY NOT IN THIS LIST. It gets its own card
 * (`PenCard`) because wiring it is the one entry here that changes what a MINT
 * DOES rather than where money goes, and it needs the pen's own readiness
 * checks next to the button. The `WireRow` it renders is the same component
 * with the same slot number, so there is no second code path.
 */
const WIRE_SLOTS = [
  { slot: 0, label: 'price feed (chainlink)' },
  { slot: 1, label: 'router (dex)' },
  { slot: 2, label: 'jackpot · $BNBULL pot' },
  { slot: 3, label: 'jackpot · BNB pot' },
  { slot: 4, label: 'swap intermediate (dormant, expected zero)' },
] as const;

/** `MintDrop.Wire.Pen`. */
const PEN_WIRE_SLOT = 5;

interface TierRow {
  upToSold: string;
  usd: string; // dollars
  bnbull: string; // whole BNBULL
}

export function AdminMint() {
  const address = contractAddress('mintDrop');

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { abi: MintDropAbi, address, functionName: 'totalSold' }, // 0
          { abi: MintDropAbi, address, functionName: 'MAX_MINT' }, // 1
          { abi: MintDropAbi, address, functionName: 'paused' }, // 2
          { abi: MintDropAbi, address, functionName: 'owner' }, // 3
          { abi: MintDropAbi, address, functionName: 'treasury' }, // 4
          { abi: MintDropAbi, address, functionName: 'lpTreasury' }, // 5
          { abi: MintDropAbi, address, functionName: 'keeper' }, // 6
          { abi: MintDropAbi, address, functionName: 'bnbullShareBps' }, // 7
          { abi: MintDropAbi, address, functionName: 'bnbShareBps' }, // 8
          { abi: MintDropAbi, address, functionName: 'lpShareBps' }, // 9
          { abi: MintDropAbi, address, functionName: 'airdropPerMint' }, // 10
          { abi: MintDropAbi, address, functionName: 'inlineSlippageBps' }, // 11
          { abi: MintDropAbi, address, functionName: 'minPoolLiquidity' }, // 12
          { abi: MintDropAbi, address, functionName: 'minPoolLiquidityAlt' }, // 13
          { abi: MintDropAbi, address, functionName: 'maxOracleAge' }, // 14
          { abi: MintDropAbi, address, functionName: 'minBnbUsd' }, // 15
          { abi: MintDropAbi, address, functionName: 'maxBnbUsd' }, // 16
          { abi: MintDropAbi, address, functionName: 'bnbullPaymentSellsForBnbLeg' }, // 17
          { abi: MintDropAbi, address, functionName: 'bnbull' }, // 18
          { abi: MintDropAbi, address, functionName: 'priceTierCount' }, // 19
          { abi: MintDropAbi, address, functionName: 'lpUndelivered' }, // 20
          { abi: MintDropAbi, address, functionName: 'wiringDelay' }, // 21
          { abi: MintDropAbi, address, functionName: 'website' }, // 22
          { abi: MintDropAbi, address, functionName: 'twitter' }, // 23
          { abi: MintDropAbi, address, functionName: 'telegram' }, // 24
          { abi: MintDropAbi, address, functionName: 'wireOf', args: [0] }, // 25
          { abi: MintDropAbi, address, functionName: 'wireOf', args: [1] }, // 26
          { abi: MintDropAbi, address, functionName: 'wireOf', args: [2] }, // 27
          { abi: MintDropAbi, address, functionName: 'wireOf', args: [3] }, // 28
          // ⚠ THE PEN IS NOW AN ORDINARY `Wire` SLOT (5), AND ITS FOUR BESPOKE
          // ADMIN CALLS ARE GONE. `bootstrapPen` / `proposePen` / `commitPen` /
          // `cancelPen` / `penWire()` were folded into the shared wire flow to
          // buy back EIP-170 headroom, so the whole thing goes through
          // `wireOf(5)` and `proposeWire(5, …)` like every other slot.
          // `penContract()` survives as the one-call read of the live address.
          { abi: MintDropAbi, address, functionName: 'wireOf', args: [4] }, // 29
          { abi: MintDropAbi, address, functionName: 'wireOf', args: [PEN_WIRE_SLOT] }, // 30
          { abi: MintDropAbi, address, functionName: 'penContract' }, // 31
        ]
      : [],
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const totalSold = asBig(data?.[0]);
  const maxMint = asBig(data?.[1]);
  const paused = asBool(data?.[2]);
  const owner = asAddr(data?.[3]);
  const treasury = asAddr(data?.[4]);
  const lpTreasury = asAddr(data?.[5]);
  const keeper = asAddr(data?.[6]);
  const bnbullShareBps = asBig(data?.[7]);
  const bnbShareBps = asBig(data?.[8]);
  const lpShareBps = asBig(data?.[9]);
  const airdropPerMint = asBig(data?.[10]);
  const inlineSlippageBps = asBig(data?.[11]);
  const minPoolLiquidity = asBig(data?.[12]);
  const minPoolLiquidityAlt = asBig(data?.[13]);
  const maxOracleAge = asBig(data?.[14]);
  const minBnbUsd = asBig(data?.[15]);
  const maxBnbUsd = asBig(data?.[16]);
  const sellsForBnbLeg = asBool(data?.[17]);
  const bnbull = asAddr(data?.[18]);
  const tierCount = asBig(data?.[19]) ?? 0n;
  const lpUndelivered = asBig(data?.[20]);
  const wiringDelay = asBig(data?.[21]);
  const website = asString(data?.[22]);
  const twitter = asString(data?.[23]);
  const telegram = asString(data?.[24]);
  const wires = [
    asWire(data?.[25]),
    asWire(data?.[26]),
    asWire(data?.[27]),
    asWire(data?.[28]),
    asWire(data?.[29]),
    asWire(data?.[30]),
  ];
  const penContract = asAddr(data?.[31]);

  // Bnbull discount lives per-asset; read it for the bnbull token specifically.
  const { data: discData } = useReadContracts({
    allowFailure: true,
    contracts: address && bnbull ? [{ abi: MintDropAbi, address, functionName: 'discountBpsOf', args: [bnbull] }] : [],
    query: { enabled: !!address && !!bnbull },
  });
  const bnbullDiscountBps = asBig(discData?.[0]);

  const tierReads = useReadContracts({
    allowFailure: true,
    contracts: Array.from({ length: Number(tierCount) }, (_, i) => ({
      abi: MintDropAbi,
      address: address!,
      functionName: 'priceTierAt' as const,
      args: [BigInt(i)] as const,
    })),
    query: { enabled: !!address && tierCount > 0n },
  });
  const tiers = (tierReads.data ?? [])
    .map((r) => (r.status === 'success' ? (r.result as { upToSold: number; usdPrice: bigint; bnbullPrice: bigint }) : null))
    .filter((t): t is NonNullable<typeof t> => t !== null);

  const doRefetch = () => {
    void refetch();
    void tierReads.refetch();
  };

  if (!address) {
    return (
      <AdminSection title="the mint">
        <AdminCard>
          <p className="text-sm text-bull-text-dim">the mintdrop contract is not deployed yet (NEXT_PUBLIC_MINTDROP unset).</p>
        </AdminCard>
      </AdminSection>
    );
  }

  const soldOut = totalSold !== undefined && maxMint !== undefined && totalSold >= maxMint;

  return (
    <AdminSection title="the mint" sub="the price ladder, the pot shares, the airdrop and the treasuries.">
      <AdminCard>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <BigStat
            label="sold"
            value={`${totalSold?.toLocaleString('en-AU') ?? '—'} / ${maxMint?.toLocaleString('en-AU') ?? '—'}`}
            sub={soldOut ? 'sold out' : 'still going'}
          />
          <BigStat label="pot share (bnbull)" value={fmtBps(bnbullShareBps)} tone="gold" />
          <BigStat label="pot share (bnb)" value={fmtBps(bnbShareBps)} tone="gold" />
          <BigStat label="state" value={paused === undefined ? '—' : paused ? 'PAUSED' : 'live'} tone={paused ? 'red' : 'plain'} />
        </div>
        <div className="grid gap-x-6 gap-y-1 border-t border-bull-border/60 pt-1 md:grid-cols-2">
          <KV k="lp share" v={fmtBps(lpShareBps)} />
          <KV k="airdrop per mint" v={`${fmtAmount(airdropPerMint, BNBULL_DECIMALS)} BNBULL`} />
          <KV k="bnbull discount" v={fmtBps(bnbullDiscountBps)} />
          <KV k="inline slippage" v={fmtBps(inlineSlippageBps)} />
          <KV k="bnbull sells for bnb leg" v={sellsForBnbLeg === undefined ? '—' : sellsForBnbLeg ? 'yes' : 'no (never-sell)'} />
          <KV k="lp undelivered" v={fmtAmount(lpUndelivered, 18)} />
          <KV k="treasury" v={<Addr addr={treasury} />} />
          <KV k="lp treasury" v={<Addr addr={lpTreasury} />} />
          <KV k="keeper" v={<Addr addr={keeper} />} />
          <KV k="bnbull token" v={<Addr addr={bnbull} />} />
          <KV k="owner" v={<Addr addr={owner} />} />
          <KV k="contract" v={<Addr addr={address} />} />
        </div>
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <AdminCard title="switches">
          <Toggle
            label="mint"
            on={paused}
            onWord="PAUSED"
            offWord="live"
            dangerWhenOff
            buildCall={(next) => ({ address, abi: MintDropAbi, functionName: next ? 'pause' : 'unpause' })}
            onDone={doRefetch}
          />
          <Toggle
            label="bnbull → bnb leg"
            on={sellsForBnbLeg}
            onWord="sells"
            offWord="never-sell"
            buildCall={(next) => ({ address, abi: MintDropAbi, functionName: 'setBnbullPaymentSellPolicy', args: [next] })}
            hint="whether a bnbull-paid mint sells part into bnb for the bnb pot leg. off = the whole pot slice stays bnbull."
            onDone={doRefetch}
          />
        </AdminCard>

        <AdminCard title="shares + airdrop (bps / amounts)">
          <TwoField
            label="pot shares · bnbull, bnb (bps)"
            aPlaceholder={bnbullShareBps?.toString() ?? 'bnbull bps'}
            bPlaceholder={bnbShareBps?.toString() ?? 'bnb bps'}
            build={(a, b) =>
              /^\d+$/.test(a) && /^\d+$/.test(b)
                ? { address, abi: MintDropAbi, functionName: 'setPotShares', args: [BigInt(a), BigInt(b)] }
                : null
            }
            onDone={doRefetch}
          />
          <Setter
            label="lp share · bps"
            current={lpShareBps?.toString() ?? '—'}
            placeholder="bps"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MintDropAbi, functionName: 'setLpShare', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="airdrop per mint · BNBULL"
            current={fmtAmount(airdropPerMint, BNBULL_DECIMALS)}
            placeholder="whole BNBULL"
            inputMode="decimal"
            buildCall={(v) => {
              try {
                return { address, abi: MintDropAbi, functionName: 'setAirdropPerMint', args: [parseUnits(v, BNBULL_DECIMALS)] };
              } catch {
                return null;
              }
            }}
            onDone={doRefetch}
          />
          <Setter
            label="bnbull discount · bps"
            current={bnbullDiscountBps?.toString() ?? '—'}
            placeholder="bps"
            inputMode="numeric"
            hint="the mint discount for paying in bnbull. applies to the bnbull token only."
            buildCall={(v) =>
              /^\d+$/.test(v) && bnbull
                ? { address, abi: MintDropAbi, functionName: 'setDiscountBps', args: [bnbull, BigInt(v)] }
                : null
            }
            onDone={doRefetch}
          />
        </AdminCard>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <AdminCard title="oracle + liquidity guards">
          <Setter
            label="inline slippage · bps"
            current={inlineSlippageBps?.toString() ?? '—'}
            placeholder="bps"
            inputMode="numeric"
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MintDropAbi, functionName: 'setInlineSlippageBps', args: [BigInt(v)] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="min pool liquidity · WBNB"
            current={fmtAmount(minPoolLiquidity, 18)}
            placeholder="whole WBNB"
            inputMode="decimal"
            buildCall={(v) => {
              try {
                return { address, abi: MintDropAbi, functionName: 'setMinPoolLiquidity', args: [parseUnits(v, 18)] };
              } catch {
                return null;
              }
            }}
            onDone={doRefetch}
          />
          <Setter
            label="min pool liquidity alt · raw"
            current={minPoolLiquidityAlt?.toString() ?? '—'}
            placeholder="raw quote units"
            inputMode="numeric"
            hint="the alt (quote-token) reserve floor, in that token's raw base units."
            buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MintDropAbi, functionName: 'setMinPoolLiquidityAlt', args: [BigInt(v)] } : null)}
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
                ? {
                    address,
                    abi: MintDropAbi,
                    functionName: 'setOraclePolicy',
                    args: [BigInt(vals[0]!), BigInt(vals[1]!), BigInt(vals[2]!)],
                  }
                : null
            }
            hint="max feed age (seconds) and the min/max accepted BNB/USD price, both at 1e18 scale."
            onDone={doRefetch}
          />
        </AdminCard>

        <AdminCard title="addresses">
          <Setter
            label="treasury"
            current={<Addr addr={treasury} />}
            placeholder="0x…"
            buildCall={(v) => (isAddr(v) ? { address, abi: MintDropAbi, functionName: 'setTreasury', args: [v as `0x${string}`] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="lp treasury"
            current={<Addr addr={lpTreasury} />}
            placeholder="0x…"
            buildCall={(v) => (isAddr(v) ? { address, abi: MintDropAbi, functionName: 'setLpTreasury', args: [v as `0x${string}`] } : null)}
            onDone={doRefetch}
          />
          <Setter
            label="keeper"
            current={<Addr addr={keeper} />}
            placeholder="0x…"
            buildCall={(v) => (isAddr(v) ? { address, abi: MintDropAbi, functionName: 'setKeeper', args: [v as `0x${string}`] } : null)}
            onDone={doRefetch}
          />
        </AdminCard>
      </div>

      <PenCard
        address={address}
        penContract={penContract}
        wire={wires[PEN_WIRE_SLOT]}
        onDone={doRefetch}
      />

      <TierEditor address={address} tiers={tiers} maxMint={maxMint} onDone={doRefetch} />

      <MoneyTools address={address} lpUndelivered={lpUndelivered} onDone={doRefetch} />

      <AdminCard title="wires (timelocked)">
        <p className="text-[11px] text-bull-text-faint">
          each slot: propose, wait out the {fmtSeconds(wiringDelay)} delay, then commit — or cancel.
        </p>
        {WIRE_SLOTS.map((w) => (
          <WireRow key={w.slot} abi={MintDropAbi} address={address} slot={w.slot} slotLabel={w.label} wire={wires[w.slot]} onDone={doRefetch} />
        ))}
        <Setter
          label="wiring delay · seconds"
          current={fmtSeconds(wiringDelay)}
          placeholder="seconds"
          inputMode="numeric"
          buildCall={(v) => (/^\d+$/.test(v) ? { address, abi: MintDropAbi, functionName: 'setWiringDelay', args: [BigInt(v)] } : null)}
          onDone={doRefetch}
        />
      </AdminCard>

      <div className="grid gap-4 lg:grid-cols-2">
        <SocialsControl
          key={`${website ?? ''}|${twitter ?? ''}|${telegram ?? ''}`}
          abi={MintDropAbi}
          address={address}
          current={{ website, twitter, telegram }}
          onDone={doRefetch}
        />
        <RescueControl abi={MintDropAbi} address={address} onDone={doRefetch} />
      </div>
    </AdminSection>
  );
}

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

/**
 * THE PEN — `contracts/BullPen.sol`, and the switch that turns the whole mint
 * from one transaction into two.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ WIRING THIS IS THE MOST CONSEQUENTIAL BUTTON ON THIS PAGE, SO IT SHOWS THE
 *   THINGS THAT DECIDE WHETHER IT WILL WORK, NOT JUST THE ADDRESS.
 * ═══════════════════════════════════════════════════════════════════════════
 * Once `penContract()` is non-zero, `mintWithBNB` stops minting and starts
 * RESERVING: it calls `BullPen.reserve`, emits `BullsReserved` instead of
 * `BullSold`, and returns no ids. Three things have to be true on the other
 * side or every mint from that moment reverts and the drop is dead until the
 * timelock lets it be undone:
 *
 *   `seller()`   must already be this MintDrop. `reserve` is seller-only and
 *                reverts `NotSeller` otherwise, so wiring the drop to the pen
 *                without wiring the pen to the drop breaks minting one-way.
 *   `poolSize()` must be > 0. `reserve` reverts `PoolTooSmall` against an empty
 *                pen, so wiring before the pre-mint lands is the same failure.
 *   VRF         must be configured — `reserve` reverts `VrfNotConfigured` on a
 *                zero keyHash or subscription id.
 *
 * All three are read below rather than assumed, because every one of them fails
 * as "the mint is broken" with nothing on the buyer's screen to explain it.
 *
 * ⚠ AND THE FRONTEND NEEDS `NEXT_PUBLIC_BULLPEN` SET IN THE SAME BREATH. The
 * site refuses to sniff the pen off chain (the live MintDrop has no
 * `penContract()` at all, so the call FAILS rather than returning zero, and a
 * failed read must never be read as "wired"). Wiring on chain without the env
 * var leaves the site counting the unsold bulls as sold and offering no way to
 * settle a reservation.
 */
function PenCard({
  address,
  penContract,
  wire,
  onDone,
}: {
  address: `0x${string}`;
  penContract: `0x${string}` | undefined;
  wire: { current?: `0x${string}`; pending?: `0x${string}`; eta?: bigint } | undefined;
  onDone: () => void;
}) {
  const live = penContract && penContract !== ZERO_ADDR ? penContract : undefined;

  const { data: penData } = useReadContracts({
    allowFailure: true,
    contracts: live
      ? [
          { abi: BullPenAbi, address: live, functionName: 'poolSize' }, // 0
          { abi: BullPenAbi, address: live, functionName: 'sellable' }, // 1
          { abi: BullPenAbi, address: live, functionName: 'seller' }, // 2
          { abi: BullPenAbi, address: live, functionName: 'nextReservationId' }, // 3
          { abi: BullPenAbi, address: live, functionName: 'nextToSettle' }, // 4
          { abi: BullPenAbi, address: live, functionName: 'keyHash' }, // 5
          { abi: BullPenAbi, address: live, functionName: 'subscriptionId' }, // 6
          { abi: BullPenAbi, address: live, functionName: 'refundAfterBlocks' }, // 7
          { abi: BullPenAbi, address: live, functionName: 'vrfTimeoutBlocks' }, // 8
        ]
      : [],
    query: { enabled: !!live, refetchInterval: 12_000 },
  });

  const poolSize = asBig(penData?.[0]);
  const sellable = asBig(penData?.[1]);
  const seller = asAddr(penData?.[2]);
  const nextReservationId = asBig(penData?.[3]);
  const nextToSettle = asBig(penData?.[4]);
  const keyHash = asString(penData?.[5]);
  const subscriptionId = asBig(penData?.[6]);
  const refundAfterBlocks = asBig(penData?.[7]);
  const vrfTimeoutBlocks = asBig(penData?.[8]);

  const sellerOk = !!seller && !!address && seller.toLowerCase() === address.toLowerCase();
  const vrfOk = !!keyHash && !/^0x0{64}$/i.test(keyHash) && !!subscriptionId && subscriptionId > 0n;
  // Reservations issued minus reservations settled: how many buyers are
  // currently holding a receipt and no bull.
  const openCount =
    nextReservationId !== undefined && nextToSettle !== undefined
      ? Number(nextReservationId - nextToSettle)
      : undefined;

  return (
    <AdminCard title="the pen (random delivery)">
      <p className="text-[11px] text-bull-text-faint">
        wired, a mint reserves instead of minting, the payment is escrowed in the pen and the ids
        are drawn in a second transaction. unwired (zero), the drop mints sequentially exactly as
        it always has.
      </p>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <BigStat
          label="state"
          value={live ? 'WIRED' : 'legacy'}
          tone={live ? 'gold' : 'plain'}
          sub={live ? 'mints reserve' : 'mints deliver inline'}
        />
        <BigStat label="pool size" value={poolSize?.toLocaleString('en-AU') ?? '—'} sub="bulls held" />
        <BigStat
          label="sellable"
          value={sellable?.toLocaleString('en-AU') ?? '—'}
          sub="pool minus open reservations"
        />
        {/* ⚠ THE ONE NUMBER ON THIS PAGE THAT COUNTS PEOPLE RATHER THAN TOKENS.
            Every unit of it is a buyer who has paid and is holding nothing, with
            their money escrowed in the pen. If it stops going back to zero, the
            keeper is down and real players are on the refund path. */}
        <BigStat
          label="open reservations"
          value={openCount === undefined ? '—' : String(openCount)}
          tone={openCount && openCount > 0 ? 'gold' : 'plain'}
          sub={openCount && openCount > 0 ? 'paid, not delivered' : 'all delivered'}
        />
      </div>

      <div className="grid gap-x-6 gap-y-1 border-t border-bull-border/60 pt-1 md:grid-cols-2">
        <KV k="pen" v={<Addr addr={live} />} />
        <KV
          k="pen's seller"
          v={
            <span className={live && !sellerOk ? 'text-bull-red' : undefined}>
              <Addr addr={seller} />
              {live ? (sellerOk ? ' ✓ this drop' : ' ✗ NOT this drop') : ''}
            </span>
          }
        />
        <KV
          k="pen vrf"
          v={live ? (vrfOk ? 'configured' : '✗ not configured — reserve will revert') : '—'}
        />
        {/* ⚠ THE REFUND WINDOW OPENS BEFORE THE FALLBACK DRAW DOES, ON PURPOSE:
            the buyer gets the choice to leave before the system starts forcing
            an outcome onto them. If these two ever invert, a buyer's money is
            committed to a draw they never got the chance to walk away from. */}
        <KV
          k="refund window opens"
          v={refundAfterBlocks !== undefined ? `${refundAfterBlocks.toLocaleString('en-AU')} blocks` : '—'}
        />
        <KV
          k="backup draw armable"
          v={
            vrfTimeoutBlocks !== undefined ? (
              <span
                className={
                  refundAfterBlocks !== undefined && vrfTimeoutBlocks <= refundAfterBlocks
                    ? 'text-bull-red'
                    : undefined
                }
              >
                {vrfTimeoutBlocks.toLocaleString('en-AU')} blocks
                {refundAfterBlocks !== undefined && vrfTimeoutBlocks <= refundAfterBlocks
                  ? ' ✗ opens before the refund does'
                  : ''}
              </span>
            ) : (
              '—'
            )
          }
        />
        <KV k="next reservation id" v={nextReservationId?.toString() ?? '—'} />
        <KV k="next to settle" v={nextToSettle?.toString() ?? '—'} />
      </div>

      {/* ⚠ THE SAME `WireRow` EVERY OTHER SLOT USES, POINTED AT SLOT 5. The pen
          used to carry four bespoke admin calls and its own wire slot; they were
          folded into the shared `Wire` enum to buy back EIP-170 headroom, so
          there is no pen-specific wiring code left to keep in sync. */}
      <WireRow
        abi={MintDropAbi}
        address={address}
        slot={PEN_WIRE_SLOT}
        slotLabel="the pen"
        wire={wire}
        onDone={onDone}
      />
    </AdminCard>
  );
}

function TierEditor({
  address,
  tiers,
  maxMint,
  onDone,
}: {
  address: `0x${string}`;
  tiers: readonly { upToSold: number; usdPrice: bigint; bnbullPrice: bigint }[];
  maxMint: bigint | undefined;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  // Keyed remount off the on-chain tiers so a load / refetch resets the draft.
  const [rows, setRows] = useState<TierRow[]>(() =>
    tiers.map((t) => ({
      upToSold: String(t.upToSold),
      usd: formatUnits(t.usdPrice, 18),
      bnbull: formatUnits(t.bnbullPrice, 18),
    })),
  );
  const [localErr, setLocalErr] = useState<string | null>(null);

  const setCell = (i: number, key: keyof TierRow, v: string) =>
    setRows((r) => r.map((row, j) => (j === i ? { ...row, [key]: v } : row)));

  const submit = () => {
    setLocalErr(null);
    try {
      const parsed = rows.map((r) => ({
        upToSold: Number(r.upToSold),
        usdPrice: parseUnits(r.usd || '0', 18),
        bnbullPrice: parseUnits(r.bnbull || '0', 18),
      }));
      for (let i = 1; i < parsed.length; i++) {
        if ((parsed[i]?.upToSold ?? 0) <= (parsed[i - 1]?.upToSold ?? 0)) {
          throw new Error('tiers must ascend by "up to #"');
        }
      }
      void tx.run({ address, abi: MintDropAbi, functionName: 'setPriceTiers', args: [parsed] });
    } catch (e) {
      setLocalErr(e instanceof Error ? e.message : 'bad tier input');
    }
  };

  return (
    <AdminCard title="price ladder (replaces the whole table in one tx)">
      <p className="text-[11px] text-bull-text-faint">
        ascending &ldquo;up to #&rdquo;, ending at {maxMint?.toString() ?? 'MAX_MINT'}. price is in
        dollars, bnbull leg in whole BNBULL. an empty table = flat pricing only.
      </p>
      <div className="space-y-2">
        {rows.map((r, i) => (
          <div key={i} className="flex flex-wrap items-center gap-1.5">
            <AdminInput value={r.upToSold} onChange={(e) => setCell(i, 'upToSold', e.target.value)} placeholder="up to #" className="w-20" inputMode="numeric" />
            <AdminInput value={r.usd} onChange={(e) => setCell(i, 'usd', e.target.value)} placeholder="usd $" className="w-24" inputMode="decimal" />
            <AdminInput value={r.bnbull} onChange={(e) => setCell(i, 'bnbull', e.target.value)} placeholder="bnbull" className="w-28" inputMode="decimal" />
            <button type="button" onClick={() => setRows((rs) => rs.filter((_, j) => j !== i))} className="px-1 text-xs text-bull-red" aria-label={`remove tier ${i + 1}`}>
              ✕
            </button>
          </div>
        ))}
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setRows((rs) => [...rs, { upToSold: maxMint?.toString() ?? '500', usd: '0', bnbull: '0' }])}
            className="bull-btn bull-btn-secondary min-h-0 px-3 py-1.5 text-xs"
          >
            + row
          </button>
          <WriteButton tx={tx} onClick={submit}>
            write ladder
          </WriteButton>
        </div>
        {localErr && <p className="font-mono text-xs text-bull-red">✗ {localErr}</p>}
        <TxStatus tx={tx} />
      </div>
    </AdminCard>
  );
}

/**
 * The money movers. All raw-input + strongly captioned, and every one is
 * simulated first — a wrong pot-source enum or an over-amount is caught and
 * decoded before the wallet opens.
 */
function MoneyTools({
  address,
  lpUndelivered,
  onDone,
}: {
  address: `0x${string}`;
  lpUndelivered: bigint | undefined;
  onDone: () => void;
}) {
  const donateNativeTx = useAdminTx(onDone);
  const donateTokenTx = useAdminTx(onDone);
  const lpTx = useAdminTx(onDone);
  const [donateN, setDonateN] = useState('');
  const [donateTokenAddr, setDonateTokenAddr] = useState('');
  const [donateTokenAmt, setDonateTokenAmt] = useState('');
  const [lpTo, setLpTo] = useState('');

  return (
    <AdminCard title="money tools">
      <p className="text-[11px] text-bull-text-faint">
        these move value. every one is simulated first, so a wrong amount or a pot-source that
        would revert is stopped with a reason before you sign.
      </p>

      <div className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-40 shrink-0 text-xs text-bull-text-faint">donate to pot · BNB</span>
          <AdminInput value={donateN} onChange={(e) => setDonateN(e.target.value)} placeholder="whole BNB" inputMode="decimal" className="w-32" />
          <WriteButton
            tx={donateNativeTx}
            disabled={!donateN.trim()}
            onClick={() => {
              try {
                void donateNativeTx.run({ address, abi: MintDropAbi, functionName: 'donatePotNative', value: parseUnits(donateN.trim(), 18) });
              } catch {
                /* bad number */
              }
            }}
          >
            donate bnb
          </WriteButton>
        </div>
        <TxStatus tx={donateNativeTx} />
      </div>

      <div className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-40 shrink-0 text-xs text-bull-text-faint">donate to pot · token (raw)</span>
          <AdminInput value={donateTokenAddr} onChange={(e) => setDonateTokenAddr(e.target.value)} placeholder="token 0x…" className="w-56" />
          <AdminInput value={donateTokenAmt} onChange={(e) => setDonateTokenAmt(e.target.value)} placeholder="amount (raw)" inputMode="numeric" className="w-32" />
          <WriteButton
            tx={donateTokenTx}
            disabled={!isAddr(donateTokenAddr) || !/^\d+$/.test(donateTokenAmt.trim())}
            onClick={() =>
              void donateTokenTx.run({
                address,
                abi: MintDropAbi,
                functionName: 'donatePotToken',
                args: [donateTokenAddr.trim() as `0x${string}`, BigInt(donateTokenAmt.trim())],
              })
            }
          >
            donate token
          </WriteButton>
        </div>
        <p className="text-[11px] text-bull-text-faint">needs an approval for the token first if the contract pulls it.</p>
        <TxStatus tx={donateTokenTx} />
      </div>

      <div className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-40 shrink-0 text-xs text-bull-text-faint">
            withdraw lp undelivered ({fmtAmount(lpUndelivered, 18)})
          </span>
          <AdminInput value={lpTo} onChange={(e) => setLpTo(e.target.value)} placeholder="to 0x…" className="w-56" />
          <WriteButton
            tx={lpTx}
            disabled={!isAddr(lpTo)}
            onClick={() => void lpTx.run({ address, abi: MintDropAbi, functionName: 'withdrawLpUndelivered', args: [lpTo.trim() as `0x${string}`] })}
          >
            withdraw
          </WriteButton>
        </div>
        <TxStatus tx={lpTx} />
      </div>

      <SweepAndManual address={address} onDone={onDone} />
    </AdminCard>
  );
}

/**
 * The pot-source sweeps and the manual-buy withdrawal. `src` is a
 * MintDrop.PotSource enum index and `bnbullPot` picks which pot the manual-buy
 * withdrawal drains. Raw inputs, simulated before send — a BadSource just gets
 * decoded and shown.
 */
function SweepAndManual({ address, onDone }: { address: `0x${string}`; onDone: () => void }) {
  const bnbTx = useAdminTx(onDone);
  const bnbullTx = useAdminTx(onDone);
  const manualTx = useAdminTx(onDone);
  const [bnbSrc, setBnbSrc] = useState('');
  const [bnbAmt, setBnbAmt] = useState('');
  const [bnbMin, setBnbMin] = useState('');
  const [bullSrc, setBullSrc] = useState('');
  const [bullAmt, setBullAmt] = useState('');
  const [bullMin, setBullMin] = useState('');
  const [mBnbullPot, setMBnbullPot] = useState(false);
  const [mSrc, setMSrc] = useState('');
  const [mTo, setMTo] = useState('');
  const [mAmt, setMAmt] = useState('');

  const int = (v: string) => /^\d+$/.test(v.trim());

  return (
    <div className="space-y-3 border-t border-bull-border/60 pt-3">
      <div className="space-y-1">
        <span className="text-xs text-bull-text-faint">sweep BNB pot · src, amountIn, minOut (raw)</span>
        <div className="flex flex-wrap items-center gap-2">
          <AdminInput value={bnbSrc} onChange={(e) => setBnbSrc(e.target.value)} placeholder="src #" inputMode="numeric" className="w-20" />
          <AdminInput value={bnbAmt} onChange={(e) => setBnbAmt(e.target.value)} placeholder="amountIn" inputMode="numeric" className="w-32" />
          <AdminInput value={bnbMin} onChange={(e) => setBnbMin(e.target.value)} placeholder="minOut" inputMode="numeric" className="w-32" />
          <WriteButton
            tx={bnbTx}
            disabled={!int(bnbSrc) || !int(bnbAmt) || !int(bnbMin)}
            onClick={() => void bnbTx.run({ address, abi: MintDropAbi, functionName: 'sweepBnbPot', args: [BigInt(bnbSrc), BigInt(bnbAmt), BigInt(bnbMin)] })}
          >
            sweep
          </WriteButton>
        </div>
        <TxStatus tx={bnbTx} />
      </div>

      <div className="space-y-1">
        <span className="text-xs text-bull-text-faint">sweep $BNBULL pot · src, amountIn, minOut (raw)</span>
        <div className="flex flex-wrap items-center gap-2">
          <AdminInput value={bullSrc} onChange={(e) => setBullSrc(e.target.value)} placeholder="src #" inputMode="numeric" className="w-20" />
          <AdminInput value={bullAmt} onChange={(e) => setBullAmt(e.target.value)} placeholder="amountIn" inputMode="numeric" className="w-32" />
          <AdminInput value={bullMin} onChange={(e) => setBullMin(e.target.value)} placeholder="minOut" inputMode="numeric" className="w-32" />
          <WriteButton
            tx={bnbullTx}
            disabled={!int(bullSrc) || !int(bullAmt) || !int(bullMin)}
            onClick={() => void bnbullTx.run({ address, abi: MintDropAbi, functionName: 'sweepBnbullPot', args: [BigInt(bullSrc), BigInt(bullAmt), BigInt(bullMin)] })}
          >
            sweep
          </WriteButton>
        </div>
        <TxStatus tx={bnbullTx} />
      </div>

      <div className="space-y-1">
        <span className="text-xs text-bull-text-faint">withdraw pending for manual buy · pot, src, to, amount</span>
        <div className="flex flex-wrap items-center gap-2">
          <label className="flex items-center gap-1 text-xs text-bull-text-dim">
            <input type="checkbox" checked={mBnbullPot} onChange={(e) => setMBnbullPot(e.target.checked)} /> bnbull pot
          </label>
          <AdminInput value={mSrc} onChange={(e) => setMSrc(e.target.value)} placeholder="src #" inputMode="numeric" className="w-20" />
          <AdminInput value={mTo} onChange={(e) => setMTo(e.target.value)} placeholder="to 0x…" className="w-52" />
          <AdminInput value={mAmt} onChange={(e) => setMAmt(e.target.value)} placeholder="amount (raw)" inputMode="numeric" className="w-32" />
          <WriteButton
            tx={manualTx}
            disabled={!int(mSrc) || !isAddr(mTo) || !int(mAmt)}
            onClick={() =>
              void manualTx.run({
                address,
                abi: MintDropAbi,
                functionName: 'withdrawPendingForManualBuy',
                args: [mBnbullPot, BigInt(mSrc), mTo.trim() as `0x${string}`, BigInt(mAmt)],
              })
            }
          >
            withdraw
          </WriteButton>
        </div>
        <TxStatus tx={manualTx} />
      </div>
    </div>
  );
}
