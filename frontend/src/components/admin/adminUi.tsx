'use client';

/**
 * Shared plumbing for the /admin cockpit — ported from the fighting fefers
 * `adminUi`, rewired to bnbulls' own safety rails:
 *
 *   - `usePreflight` SIMULATES the exact call before the wallet ever opens, so
 *     a write that would revert is stopped with a decoded, human reason instead
 *     of a raw node error (`never offer what cannot succeed`).
 *   - `decodeRevert` / `RevertNotice` turn whatever the wallet throws into a
 *     sentence. No surface here ever renders `error.message`.
 *   - success is gated on `receipt.status === 'success'`. viem/wagmi resolve a
 *     receipt for REVERTED transactions too — "it mined" is not "it worked".
 *
 * Every write control uses `useAdminTx`, and every setter shows its current
 * on-chain value beside the input.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import type { Abi } from 'viem';
import { formatUnits } from 'viem';
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { CHAIN_ID } from '@/lib/env';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { formatBps as fmtBpsBase, formatUsd1e18 } from '@/lib/format';

// ─── The write hook ──────────────────────────────────────────────────────

export type AdminTxPhase = 'idle' | 'checking' | 'wallet' | 'mining' | 'success' | 'failed';

/** A contract write, in the shape both `usePreflight` and wagmi accept. */
export interface AdminWriteCall {
  readonly address: `0x${string}`;
  readonly abi: readonly unknown[];
  readonly functionName: string;
  readonly args?: readonly unknown[];
  readonly value?: bigint;
}

export interface AdminTx {
  /** Simulate then send. Blocks the send if the simulation reverts. */
  run: (call: AdminWriteCall, fallback?: string) => Promise<void>;
  phase: AdminTxPhase;
  error: DecodedRevert | null;
  hash: `0x${string}` | undefined;
  reset: () => void;
}

export function useAdminTx(onSuccess?: () => void): AdminTx {
  const { preflight, checking } = usePreflight();
  const { writeContractAsync, data: hash, isPending, reset: resetWrite } = useWriteContract();
  const { data: receipt } = useWaitForTransactionReceipt({ hash, chainId: CHAIN_ID });
  const [error, setError] = useState<DecodedRevert | null>(null);
  const [busy, setBusy] = useState(false);

  // The ONLY success condition: a mined receipt that says success.
  const settled = !!receipt && receipt.status === 'success';
  const reverted = !!receipt && receipt.status !== 'success';

  // A reverted receipt carries no reason here — the pre-send simulation is
  // where the real reason gets caught. If it still landed and reverted, say so
  // plainly rather than leaving a green tick on a failed write.
  useEffect(() => {
    if (reverted) {
      setError(
        decodeRevert(
          'execution reverted',
          'it mined and then reverted on chain, so nothing changed. something moved since you ' +
            'hit send. read the current value again and go once more.',
        ),
      );
    }
  }, [reverted]);

  const firedFor = useRef<string | null>(null);
  useEffect(() => {
    if (settled && hash && firedFor.current !== hash) {
      firedFor.current = hash;
      onSuccess?.();
    }
  }, [settled, hash, onSuccess]);

  const run = useCallback(
    async (call: AdminWriteCall, fallback?: string) => {
      setError(null);
      resetWrite();
      firedFor.current = null;

      // 1. Simulate as the connected wallet. A revert here never opens the
      //    wallet — it shows a decoded reason instead.
      const pre = await preflight(call, fallback);
      if (!pre.ok) {
        setError(pre.error);
        return;
      }

      // 2. Send. `chainId` is pinned so viem refuses to broadcast on the
      //    wrong chain rather than sending to an address with no code.
      setBusy(true);
      try {
        await writeContractAsync({
          address: call.address,
          abi: call.abi as Abi,
          functionName: call.functionName,
          args: call.args ? [...call.args] : undefined,
          value: call.value,
          chainId: CHAIN_ID,
        } as unknown as Parameters<typeof writeContractAsync>[0]);
      } catch (e) {
        setError(decodeRevert(e, fallback));
      } finally {
        setBusy(false);
      }
    },
    [preflight, writeContractAsync, resetWrite],
  );

  const phase: AdminTxPhase = settled
    ? 'success'
    : error || reverted
      ? 'failed'
      : busy || isPending
        ? 'wallet'
        : hash
          ? 'mining'
          : checking
            ? 'checking'
            : 'idle';

  const reset = useCallback(() => {
    setError(null);
    firedFor.current = null;
    resetWrite();
  }, [resetWrite]);

  return { run, phase, error, hash, reset };
}

/** One status line under a control. Renders nothing while idle. */
export function TxStatus({ tx }: { tx: AdminTx }) {
  if (tx.phase === 'idle') return null;
  if (tx.phase === 'checking') {
    return <p className="mt-1 font-mono text-xs text-bull-text-faint">checking it will go through…</p>;
  }
  if (tx.phase === 'wallet') {
    return <p className="mt-1 font-mono text-xs text-bull-gold">check your wallet…</p>;
  }
  if (tx.phase === 'mining') {
    return (
      <p className="mt-1 font-mono text-xs text-bull-text-dim">
        mining{tx.hash ? ` · ${tx.hash.slice(0, 10)}…` : ''}
      </p>
    );
  }
  if (tx.phase === 'success') {
    return (
      <p className="mt-1 font-mono text-xs text-bull-gold">
        ✓ landed{tx.hash ? ` · ${tx.hash.slice(0, 10)}…` : ''}
      </p>
    );
  }
  return <RevertNotice error={tx.error} className="mt-1" />;
}

// ─── Display atoms ───────────────────────────────────────────────────────

export function AdminSection({
  title,
  sub,
  children,
}: {
  title: string;
  sub?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="space-y-4">
      <div>
        <h2 className="bull-header text-lg text-bull-gold md:text-xl">{title}</h2>
        {sub && <p className="text-sm text-bull-text-dim">{sub}</p>}
      </div>
      {children}
    </section>
  );
}

export function AdminCard({
  title,
  children,
  className,
}: {
  title?: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={`bull-card space-y-3 p-4 ${className ?? ''}`}>
      {title && <div className="bull-header text-sm text-bull-text">{title}</div>}
      {children}
    </div>
  );
}

/** Big headline number. Mono + tabular so columns of them line up. */
export function BigStat({
  label,
  value,
  sub,
  tone,
}: {
  label: string;
  value: string;
  sub?: string;
  tone?: 'gold' | 'red' | 'plain';
}) {
  const color = tone === 'red' ? 'text-bull-red' : tone === 'plain' ? 'text-bull-text' : 'text-bull-gold';
  return (
    <div className="space-y-0.5">
      <div className="text-xs text-bull-text-faint">{label}</div>
      <div className={`bull-header font-mono text-xl tabular-nums md:text-2xl ${color}`}>{value}</div>
      {sub && <div className="font-mono text-xs tabular-nums text-bull-text-dim">{sub}</div>}
    </div>
  );
}

/** Small label → value row for detail tables. */
export function KV({ k, v, mono = true }: { k: string; v: React.ReactNode; mono?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3 text-sm">
      <span className="shrink-0 text-bull-text-faint">{k}</span>
      <span className={`break-all text-right text-bull-text ${mono ? 'font-mono tabular-nums' : ''}`}>
        {v}
      </span>
    </div>
  );
}

/** Shortened address with the full thing on hover + click-to-copy. */
export function Addr({ addr }: { addr: string | undefined | null }) {
  const [copied, setCopied] = useState(false);
  if (!addr) return <span className="text-bull-text-faint">—</span>;
  if (/^0x0{40}$/i.test(addr)) return <span className="text-bull-text-faint">not set (0x0)</span>;
  const short = `${addr.slice(0, 6)}…${addr.slice(-4)}`;
  return (
    <button
      type="button"
      title={addr}
      onClick={() => {
        void navigator.clipboard?.writeText(addr).then(() => {
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1200);
        });
      }}
      className="font-mono text-bull-text hover:text-bull-gold"
    >
      {copied ? '✓ copied' : short}
    </button>
  );
}

export type InputMode = 'numeric' | 'decimal' | 'text';

/** Standard admin numeric/text input. */
export function AdminInput(props: React.InputHTMLAttributes<HTMLInputElement>) {
  const { className, ...rest } = props;
  return (
    <input
      {...rest}
      className={`bull-input min-h-0 py-1.5 font-mono text-sm tabular-nums ${className ?? ''}`}
    />
  );
}

/** The write button beside an input. Disabled while a tx is in flight. */
export function WriteButton({
  tx,
  onClick,
  children,
  danger,
  disabled,
}: {
  tx: AdminTx;
  onClick: () => void;
  children: React.ReactNode;
  danger?: boolean;
  disabled?: boolean;
}) {
  const busy = tx.phase === 'checking' || tx.phase === 'wallet' || tx.phase === 'mining';
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={busy || disabled}
      className={`bull-btn ${danger ? 'bull-btn-danger' : 'bull-btn-secondary'} min-h-0 shrink-0 px-3 py-1.5 text-xs disabled:opacity-50`}
    >
      {busy ? 'sending…' : children}
    </button>
  );
}

// ─── Generic controls ────────────────────────────────────────────────────

/**
 * A single-field owner setter. Shows the current value beside the input, and
 * only fires when `buildCall` returns a call (i.e. the input parsed). The call
 * is simulated first, so a value the contract would reject never reaches the
 * wallet.
 */
export function Setter({
  label,
  current,
  placeholder,
  inputMode = 'text',
  hint,
  danger,
  cta = 'set',
  buildCall,
  onDone,
}: {
  label: string;
  current: React.ReactNode;
  placeholder?: string;
  inputMode?: InputMode;
  hint?: string;
  danger?: boolean;
  cta?: string;
  buildCall: (v: string) => AdminWriteCall | null;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [val, setVal] = useState('');
  const trimmed = val.trim();
  const call = trimmed ? buildCall(trimmed) : null;

  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-2">
        <span className="w-40 shrink-0 text-xs text-bull-text-faint">{label}</span>
        <span className="font-mono text-xs tabular-nums text-bull-text-dim">now {current}</span>
        <AdminInput
          value={val}
          onChange={(e) => setVal(e.target.value)}
          placeholder={placeholder}
          inputMode={inputMode}
          className="w-32"
          aria-label={label}
        />
        <WriteButton tx={tx} danger={danger} disabled={!call} onClick={() => call && void tx.run(call)}>
          {cta}
        </WriteButton>
      </div>
      {hint && <p className="text-[11px] text-bull-text-faint">{hint}</p>}
      <TxStatus tx={tx} />
    </div>
  );
}

/** A boolean toggle (pause/unpause, allow/disallow). `on` may be undefined
 *  while the read is loading — the button is disabled until it settles. */
export function Toggle({
  label,
  on,
  onWord,
  offWord,
  buildCall,
  dangerWhenOff,
  hint,
  onDone,
}: {
  label: string;
  on: boolean | undefined;
  /** word shown + the button target when the flag is TRUE. */
  onWord: string;
  offWord: string;
  /** desired next value → the call that sets it. */
  buildCall: (next: boolean) => AdminWriteCall;
  /** colour the button as dangerous when the flag is currently off (e.g. pause). */
  dangerWhenOff?: boolean;
  hint?: string;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-3">
        <span className="w-40 shrink-0 text-xs text-bull-text-faint">{label}</span>
        <span className={`font-mono text-sm ${on ? 'text-bull-red' : 'text-bull-gold'}`}>
          {on === undefined ? '—' : on ? onWord : offWord}
        </span>
        <WriteButton
          tx={tx}
          danger={dangerWhenOff && !on}
          disabled={on === undefined}
          onClick={() => on !== undefined && void tx.run(buildCall(!on))}
        >
          {on === undefined ? '—' : on ? `→ ${offWord}` : `→ ${onWord}`}
        </WriteButton>
      </div>
      {hint && <p className="text-[11px] text-bull-text-faint">{hint}</p>}
      <TxStatus tx={tx} />
    </div>
  );
}

/** The website/twitter/telegram triple every ownable contract here carries. */
export function SocialsControl({
  abi,
  address,
  current,
  onDone,
}: {
  abi: readonly unknown[];
  address: `0x${string}`;
  current: { website?: string; twitter?: string; telegram?: string };
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [w, setW] = useState(current.website ?? '');
  const [t, setT] = useState(current.twitter ?? '');
  const [g, setG] = useState(current.telegram ?? '');

  return (
    <AdminCard title="socials (website · twitter · telegram)">
      <div className="space-y-2">
        <AdminInput value={w} onChange={(e) => setW(e.target.value)} placeholder="website" className="w-full" />
        <AdminInput value={t} onChange={(e) => setT(e.target.value)} placeholder="twitter" className="w-full" />
        <AdminInput value={g} onChange={(e) => setG(e.target.value)} placeholder="telegram" className="w-full" />
        <WriteButton
          tx={tx}
          onClick={() =>
            void tx.run({ address, abi, functionName: 'setSocials', args: [w.trim(), t.trim(), g.trim()] })
          }
        >
          set socials
        </WriteButton>
        <TxStatus tx={tx} />
      </div>
    </AdminCard>
  );
}

/** rescueToken(token, to, amount) — the shared owner sweep of a stray ERC20. */
export function RescueControl({
  abi,
  address,
  onDone,
}: {
  abi: readonly unknown[];
  address: `0x${string}`;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [token, setToken] = useState('');
  const [to, setTo] = useState('');
  const [amt, setAmt] = useState('');
  const ok = isAddr(token) && isAddr(to) && /^\d+$/.test(amt.trim());

  return (
    <AdminCard title="rescue a stray token (raw units)">
      <p className="text-[11px] text-bull-text-faint">
        pulls an unrelated ERC20 that landed on this contract out to an address. amount is in raw
        base units. the prize/pot assets are not sweepable, the contract refuses those.
      </p>
      <div className="space-y-2">
        <AdminInput value={token} onChange={(e) => setToken(e.target.value)} placeholder="token 0x…" className="w-full" />
        <AdminInput value={to} onChange={(e) => setTo(e.target.value)} placeholder="to 0x…" className="w-full" />
        <AdminInput value={amt} onChange={(e) => setAmt(e.target.value)} placeholder="amount (raw units)" inputMode="numeric" className="w-full" />
        <WriteButton
          tx={tx}
          danger
          disabled={!ok}
          onClick={() =>
            ok &&
            void tx.run({
              address,
              abi,
              functionName: 'rescueToken',
              args: [token.trim() as `0x${string}`, to.trim() as `0x${string}`, BigInt(amt.trim())],
            })
          }
        >
          rescue
        </WriteButton>
        <TxStatus tx={tx} />
      </div>
    </AdminCard>
  );
}

/**
 * A generic timelocked wire slot: propose a new target, wait out the delay,
 * then commit — or cancel a pending proposal. Reads come from `wireOf(slot)`.
 */
export function WireRow({
  abi,
  address,
  slot,
  slotLabel,
  wire,
  onDone,
}: {
  abi: readonly unknown[];
  address: `0x${string}`;
  slot: number;
  slotLabel: string;
  wire: { current?: `0x${string}`; pending?: `0x${string}`; eta?: bigint } | undefined;
  onDone: () => void;
}) {
  const proposeTx = useAdminTx(onDone);
  const commitTx = useAdminTx(onDone);
  const cancelTx = useAdminTx(onDone);
  const [target, setTarget] = useState('');

  const pending = wire?.pending;
  const hasPending = !!pending && !/^0x0{40}$/i.test(pending);
  const eta = wire?.eta ?? 0n;
  const now = BigInt(Math.floor(Date.now() / 1000));
  const ready = hasPending && eta > 0n && now >= eta;

  return (
    <div className="space-y-2 border-t border-bull-border/60 pt-2">
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-sm text-bull-text">{slotLabel}</span>
        <span className="font-mono text-xs text-bull-text-dim">
          <Addr addr={wire?.current} />
        </span>
      </div>

      {hasPending && (
        <p className="font-mono text-xs text-bull-gold">
          pending → <Addr addr={pending} /> · eta {new Date(Number(eta) * 1000).toLocaleString()}{' '}
          {ready ? '· ready to commit' : '· still timelocked'}
        </p>
      )}

      <div className="flex flex-wrap items-center gap-2">
        <AdminInput
          value={target}
          onChange={(e) => setTarget(e.target.value)}
          placeholder="new target 0x…"
          className="w-64"
        />
        <WriteButton
          tx={proposeTx}
          disabled={!isAddr(target)}
          onClick={() =>
            isAddr(target) &&
            void proposeTx.run({
              address,
              abi,
              functionName: 'proposeWire',
              args: [slot, target.trim() as `0x${string}`],
            })
          }
        >
          propose
        </WriteButton>
        <WriteButton
          tx={commitTx}
          disabled={!ready}
          onClick={() => void commitTx.run({ address, abi, functionName: 'commitWire', args: [slot] })}
        >
          commit
        </WriteButton>
        <WriteButton
          tx={cancelTx}
          danger
          disabled={!hasPending}
          onClick={() => void cancelTx.run({ address, abi, functionName: 'cancelWire', args: [slot] })}
        >
          cancel
        </WriteButton>
      </div>
      <TxStatus tx={proposeTx} />
      <TxStatus tx={commitTx} />
      <TxStatus tx={cancelTx} />
    </div>
  );
}

/** Two integer fields, one write. */
export function TwoField({
  label,
  aPlaceholder,
  bPlaceholder,
  build,
  hint,
  onDone,
}: {
  label: string;
  aPlaceholder: string;
  bPlaceholder: string;
  build: (a: string, b: string) => AdminWriteCall | null;
  hint?: string;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [a, setA] = useState('');
  const [b, setB] = useState('');
  const call = build(a.trim(), b.trim());
  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-2">
        <span className="w-40 shrink-0 text-xs text-bull-text-faint">{label}</span>
        <AdminInput value={a} onChange={(e) => setA(e.target.value)} placeholder={aPlaceholder} inputMode="numeric" className="w-24" />
        <AdminInput value={b} onChange={(e) => setB(e.target.value)} placeholder={bPlaceholder} inputMode="numeric" className="w-24" />
        <WriteButton tx={tx} disabled={!call} onClick={() => call && void tx.run(call)}>
          set
        </WriteButton>
      </div>
      {hint && <p className="text-[11px] text-bull-text-faint">{hint}</p>}
      <TxStatus tx={tx} />
    </div>
  );
}

/** Three integer fields, one write. */
export function ThreeField({
  label,
  fields,
  build,
  hint,
  onDone,
}: {
  label: string;
  fields: { placeholder: string }[];
  build: (vals: string[]) => AdminWriteCall | null;
  hint?: string;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const [vals, setVals] = useState(['', '', '']);
  const call = build(vals.map((v) => v.trim()));
  return (
    <div className="space-y-1">
      <span className="text-xs text-bull-text-faint">{label}</span>
      <div className="flex flex-wrap items-center gap-2">
        {fields.map((f, i) => (
          <AdminInput
            key={i}
            value={vals[i]}
            onChange={(e) => setVals((vs) => vs.map((x, j) => (j === i ? e.target.value : x)))}
            placeholder={f.placeholder}
            inputMode="numeric"
            className="w-44"
          />
        ))}
        <WriteButton tx={tx} disabled={!call} onClick={() => call && void tx.run(call)}>
          set
        </WriteButton>
      </div>
      {hint && <p className="text-[11px] text-bull-text-faint">{hint}</p>}
      <TxStatus tx={tx} />
    </div>
  );
}

// ─── Formatters ──────────────────────────────────────────────────────────

export { formatUsd1e18 as fmtUsd, formatBps as fmtBpsRaw } from '@/lib/format';

/** basis points (bigint | number) → percent. */
export function fmtBps(bps: bigint | number | undefined): string {
  if (bps === undefined) return '—';
  return fmtBpsBase(bps);
}

/** usd1e18 dollar figure. */
export function fmtDollars(v: bigint | undefined): string {
  return formatUsd1e18(v);
}

/** A token amount at a known number of decimals, grouped for readability. */
export function fmtAmount(wei: bigint | undefined, decimals = 18): string {
  if (wei === undefined) return '—';
  const n = Number(formatUnits(wei, decimals));
  if (!Number.isFinite(n)) return '0';
  const dp = n === 0 ? 0 : n >= 100 ? 0 : n >= 1 ? 2 : 4;
  return n.toLocaleString('en-AU', { minimumFractionDigits: 0, maximumFractionDigits: dp });
}

export function fmtSeconds(s: bigint | undefined): string {
  if (s === undefined) return '—';
  const n = Number(s);
  if (n === 0) return '0 (instant)';
  if (n % 86400 === 0) return `${n / 86400}d`;
  if (n % 3600 === 0) return `${n / 3600}h`;
  if (n % 60 === 0) return `${n / 60}m`;
  return `${n}s`;
}

export function isAddr(v: string): v is `0x${string}` {
  return /^0x[0-9a-fA-F]{40}$/.test(v.trim());
}

// ─── Read-result converters (undefined = revert / not loaded) ─────────────

interface ReadResult {
  status: string;
  result?: unknown;
}

export function asBig(r: ReadResult | undefined): bigint | undefined {
  if (r?.status !== 'success') return undefined;
  if (typeof r.result === 'bigint') return r.result;
  if (typeof r.result === 'number') return BigInt(r.result);
  return undefined;
}
export function asNum(r: ReadResult | undefined): number | undefined {
  if (r?.status !== 'success') return undefined;
  if (typeof r.result === 'number') return r.result;
  if (typeof r.result === 'bigint') return Number(r.result);
  return undefined;
}
export function asAddr(r: ReadResult | undefined): `0x${string}` | undefined {
  return r?.status === 'success' && typeof r.result === 'string' ? (r.result as `0x${string}`) : undefined;
}
export function asBool(r: ReadResult | undefined): boolean | undefined {
  return r?.status === 'success' && typeof r.result === 'boolean' ? r.result : undefined;
}
export function asString(r: ReadResult | undefined): string | undefined {
  return r?.status === 'success' && typeof r.result === 'string' ? r.result : undefined;
}
/** A `wireOf`/`coordinatorWire` tuple → {current, pending, eta}. */
export function asWire(
  r: ReadResult | undefined,
): { current?: `0x${string}`; pending?: `0x${string}`; eta?: bigint } | undefined {
  if (r?.status !== 'success' || !Array.isArray(r.result)) return undefined;
  const [current, pending, eta] = r.result as [`0x${string}`, `0x${string}`, bigint];
  return { current, pending, eta };
}
