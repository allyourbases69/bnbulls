'use client';

/**
 * THE POTS — both Jackpot deployments (the $BNBULL pot and the BNB/WBNB pot),
 * live reads plus the two things the owner actually drives on chain:
 *
 *   1. FILLING THE POOL. The headline of this page. The pool is the prize
 *      token's own balance held by the contract — WBNB for the BNB pot, $BNBULL
 *      for the bnbull pot. Adding to it is an ERC20 approve followed by a pull:
 *      `topUp(amount)` if you own the pot, `fund(amount, source)` if the owner
 *      has made this wallet a funder. Both pull with safeTransferFrom, so it is
 *      always two transactions. There is no withdraw — the only way money leaves
 *      a pool is a winner taking it — so this is spelled out before you sign.
 *
 *   2. THE PAYOUT PARAMS (odds · payout bps · min pool). Timelocked:
 *      `proposePayoutParams` then, after the wiring delay, `commitPayoutParams`
 *      (or `cancelPayoutParams`). The very first set, before anything is
 *      configured, goes through the one-shot `bootstrapPayoutParams`.
 *
 * Verified against `frontend/src/lib/abi/Jackpot.ts`:
 *   fund(uint256 amount, string source)   gated on isFunder[msg.sender]
 *   topUp(uint256 amount)                  onlyOwner
 * `pool()` is the live prize-token balance; `payoutParamsBootstrapped()` tells
 * the two payout-param paths apart.
 */
import { useState } from 'react';
import { useAccount, useBalance, useReadContract, useReadContracts } from 'wagmi';
import { formatUnits, parseUnits } from 'viem';
import { JackpotAbi, JackpotNativeAbi, Erc20Abi } from '@/lib/abi';
import {
  CHAIN_ID,
  contractAddress,
  isNativePot,
  NATIVE_POT_DECIMALS,
  NATIVE_POT_SYMBOL,
} from '@/lib/env';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { useTokenDecimals, useTokenSymbol } from '@/lib/hooks/useTokenDecimals';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';
import { POTS } from '@/lib/brand';
import {
  AdminCard,
  AdminInput,
  AdminSection,
  Addr,
  BigStat,
  KV,
  TxStatus,
  WriteButton,
  asAddr,
  asBig,
  asBool,
  fmtAmount,
  fmtBps,
  useAdminTx,
} from './adminUi';

const ZERO = '0x0000000000000000000000000000000000000000' as const;

// WBNB is an ERC20 (Erc20Abi covers approve/allowance/balanceOf) PLUS the
// canonical native-wrap entrypoint, which the generated Erc20Abi doesn't carry.
const WbnbAbi = [
  { type: 'function', name: 'deposit', stateMutability: 'payable', inputs: [], outputs: [] },
] as const;

interface PotEntry {
  /** Which pot, so `isNativePot` can decide the ABI and the funding door. */
  name: 'jackpotBnbull' | 'jackpotBnb';
  label: string;
  address: `0x${string}` | null;
  fallbackSym: string;
  /** The BNB pot is WBNB-backed, so it can offer a native-BNB auto-wrap fill.
   *  Meaningless once that pot settles natively — see `isNativePot`. */
  isWbnb: boolean;
}

export function AdminPots() {
  const candidates: PotEntry[] = [
    { name: 'jackpotBnbull' as const, label: POTS.bnbull.label, address: contractAddress('jackpotBnbull'), fallbackSym: POTS.bnbull.symbolFallback, isWbnb: false },
    { name: 'jackpotBnb' as const, label: POTS.bnb.label, address: contractAddress('jackpotBnb'), fallbackSym: POTS.bnb.symbolFallback, isWbnb: true },
  ];
  const pots = candidates.filter(
    (p): p is PotEntry & { address: `0x${string}` } => p.address !== null,
  );

  if (pots.length === 0) {
    return (
      <AdminSection title="the pots">
        <AdminCard>
          <p className="text-sm text-bull-text-dim">
            no jackpot pools are deployed on this chain yet (NEXT_PUBLIC_JACKPOT_BNBULL and
            NEXT_PUBLIC_JACKPOT_BNB are unset).
          </p>
        </AdminCard>
      </AdminSection>
    );
  }

  return (
    <AdminSection
      title="the pots"
      sub="both jackpot pools, straight off the chain. filling a pool only ever goes one way — the only exit is a win — so fund with that in mind."
    >
      <p className="text-xs text-bull-text-dim">{POTS.grow}</p>
      <div className="grid gap-4 lg:grid-cols-2">
        {pots.map((p) => (
          <PotPanel key={p.address} name={p.name} label={p.label} address={p.address} fallbackSym={p.fallbackSym} isWbnb={p.isWbnb} />
        ))}
      </div>
    </AdminSection>
  );
}

function PotPanel({
  name,
  label,
  address,
  fallbackSym,
  isWbnb,
}: {
  name: 'jackpotBnbull' | 'jackpotBnb';
  label: string;
  address: `0x${string}`;
  fallbackSym: string;
  isWbnb: boolean;
}) {
  // ⚠ Only the BNB pot flips. $BNBULL keeps its `prizeToken()` forever.
  const native = isNativePot(name);
  const c = { abi: native ? JackpotNativeAbi : JackpotAbi, address } as const;
  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: [
      { ...c, functionName: 'pool' }, // 0
      { ...c, functionName: 'pendingPayout' }, // 1
      { ...c, functionName: 'oddsOneIn' }, // 2
      { ...c, functionName: 'payoutBps' }, // 3
      { ...c, functionName: 'minPoolToFire' }, // 4
      { ...c, functionName: 'totalAwarded' }, // 5
      { ...c, functionName: 'awardCount' }, // 6
      { ...c, functionName: 'totalFunded' }, // 7
      { ...c, functionName: 'owner' }, // 8
      { ...c, functionName: 'payoutParamsBootstrapped' }, // 9
      { ...c, functionName: 'proposedOdds' }, // 10
      { ...c, functionName: 'proposedPayoutBps' }, // 11
      { ...c, functionName: 'proposedMinPool' }, // 12
      { ...c, functionName: 'payoutParamsEta' }, // 13
      { ...c, functionName: 'wiringDelay' }, // 14
    ],
    query: { refetchInterval: 12_000 },
  });

  const pool = asBig(data?.[0]);
  const pendingPayout = asBig(data?.[1]);
  const oddsOneIn = asBig(data?.[2]);
  const payoutBps = asBig(data?.[3]);
  const minPoolToFire = asBig(data?.[4]);
  const totalAwarded = asBig(data?.[5]);
  const awardCount = asBig(data?.[6]);
  const totalFunded = asBig(data?.[7]);
  const owner = asAddr(data?.[8]);
  const bootstrapped = asBool(data?.[9]);
  const proposedOdds = asBig(data?.[10]);
  const proposedPayoutBps = asBig(data?.[11]);
  const proposedMinPool = asBig(data?.[12]);
  const eta = asBig(data?.[13]);
  const wiringDelay = asBig(data?.[14]);

  // ⚠ ITS OWN READ, AND ONLY ON THE ERC-20 FLAVOUR. A native pot has no
  // `prizeToken()` at all, and asking anyway was quietly fatal here: the call
  // failed, so the wallet's token BALANCE could never be read, so `needWrap`
  // stayed pinned true and `readyToFund` could never become true in EITHER
  // mode — the owner simply could not seed the new pot from this panel.
  // Kept out of the multicall above so the flavour cannot shift any index.
  const { data: prizeTokenRaw } = useReadContract({
    address,
    abi: JackpotAbi,
    functionName: 'prizeToken',
    query: { enabled: !native },
  });
  const prizeToken = native ? undefined : (prizeTokenRaw as `0x${string}` | undefined);

  // Asserted on a native pot: there is no token contract to ask, so nothing
  // could disagree. Read live everywhere else, as before.
  const { symbol: liveSym } = useTokenSymbol(prizeToken);
  const { decimals: tokenDecimals } = useTokenDecimals(prizeToken);
  const decimals = native ? NATIVE_POT_DECIMALS : tokenDecimals;
  const sym = native ? NATIVE_POT_SYMBOL : (liveSym ?? fallbackSym);

  const doRefetch = () => void refetch();

  return (
    <AdminCard title={label}>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <BigStat label="pool" value={fmtAmount(pool, decimals ?? 18)} sub={sym} />
        <BigStat label="next payout" value={fmtAmount(pendingPayout, decimals ?? 18)} sub={sym} tone="gold" />
        <BigStat
          label="odds"
          value={oddsOneIn !== undefined ? `1 in ${oddsOneIn.toLocaleString('en-AU')}` : '—'}
          sub="fights"
          tone="plain"
        />
        <BigStat label="fired" value={awardCount?.toLocaleString('en-AU') ?? '—'} sub="times" tone="plain" />
      </div>

      <div className="grid gap-x-6 gap-y-1 border-t border-bull-border/60 pt-1 md:grid-cols-2">
        <KV k="payout share" v={fmtBps(payoutBps)} />
        <KV k="min pool to fire" v={`${fmtAmount(minPoolToFire, decimals ?? 18)} ${sym}`} />
        <KV k="all-time funded" v={`${fmtAmount(totalFunded, decimals ?? 18)} ${sym}`} />
        <KV k="all-time awarded" v={`${fmtAmount(totalAwarded, decimals ?? 18)} ${sym}`} />
        <KV
          k="prize"
          v={native ? <span className="font-mono">native BNB</span> : <Addr addr={prizeToken} />}
        />
        <KV k="owner" v={<Addr addr={owner} />} />
        <KV k="contract" v={<Addr addr={address} />} />
      </div>

      <FundControl
        potAddress={address}
        prizeToken={prizeToken}
        decimals={decimals}
        symbol={sym}
        owner={owner}
        isWbnbPot={isWbnb && !native}
        nativePot={native}
        onDone={doRefetch}
      />

      <PayoutParamsPanel
        potAddress={address}
        decimals={decimals}
        symbol={sym}
        bootstrapped={bootstrapped}
        oddsOneIn={oddsOneIn}
        payoutBps={payoutBps}
        minPoolToFire={minPoolToFire}
        proposedOdds={proposedOdds}
        proposedPayoutBps={proposedPayoutBps}
        proposedMinPool={proposedMinPool}
        eta={eta}
        wiringDelay={wiringDelay}
        onDone={doRefetch}
      />
    </AdminCard>
  );
}

/**
 * FILL THE POOL. approve → topUp / fund. The headline control.
 */
function FundControl({
  potAddress,
  prizeToken,
  decimals,
  symbol,
  owner,
  isWbnbPot,
  nativePot,
  onDone,
}: {
  potAddress: `0x${string}`;
  prizeToken: `0x${string}` | undefined;
  decimals: number | undefined;
  symbol: string;
  owner: `0x${string}` | undefined;
  isWbnbPot: boolean;
  /** ⚠ The pot itself settles in native BNB: `topUp()` is PAYABLE and takes no
   *  argument, so there is no token to hold, wrap or approve. The whole
   *  three-step dance below collapses to one send. */
  nativePot: boolean;
  onDone: () => void;
}) {
  const { address: wallet } = useAccount();
  const [val, setVal] = useState('');
  const [approveErr, setApproveErr] = useState<DecodedRevert | null>(null);
  // For the WBNB-backed pot, default to the native-BNB path so an owner holding
  // only native BNB is not stuck at "no WBNB" — the UI wraps for them. WBNB
  // direct stays one click away. The BNBULL pot has no wrap: token-direct only.
  const [mode, setMode] = useState<'native' | 'wbnb'>(isWbnbPot ? 'native' : 'wbnb');

  // Is this wallet allowed to fund this pot, and by which door?
  const { data: gate } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        abi: nativePot ? JackpotNativeAbi : JackpotAbi,
        address: potAddress,
        functionName: 'isFunder',
        args: [wallet ?? ZERO],
      },
    ],
    query: { enabled: !!wallet, refetchInterval: 15_000 },
  });
  const isFunder = asBool(gate?.[0]) === true;
  const isOwner = !!wallet && !!owner && wallet.toLowerCase() === owner.toLowerCase();
  // topUp beats fund when you are both: it is the owner door and cannot be shut.
  const route: 'topUp' | 'fund' | null = isOwner ? 'topUp' : isFunder ? 'fund' : null;

  // Balance of the prize token (WBNB / BNBULL) in the connected wallet.
  const { data: balanceRaw, refetch: refetchBalance } = useReadContract({
    address: prizeToken,
    abi: Erc20Abi,
    functionName: 'balanceOf',
    args: wallet ? [wallet] : undefined,
    query: { enabled: !!prizeToken && !!wallet, refetchInterval: 15_000 },
  });
  const balance = typeof balanceRaw === 'bigint' ? balanceRaw : undefined;

  // Native BNB balance — the source for the wrap step (native mode only), and
  // the ONLY balance that matters on a natively-settled pot.
  const { data: nativeBal, refetch: refetchNative } = useBalance({
    address: wallet,
    chainId: CHAIN_ID,
    query: { enabled: (nativePot || mode === 'native') && !!wallet, refetchInterval: 15_000 },
  });
  const nativeValue = nativeBal?.value;

  // Parse the typed amount at the prize token's own decimals. WBNB and native
  // BNB are both 18-dp, so the same figure is the wrap value AND the topUp amount.
  let amount: bigint | null = null;
  let parseErr = false;
  const raw = val.trim();
  if (raw && decimals !== undefined) {
    try {
      const parsed = parseUnits(raw, decimals);
      amount = parsed > 0n ? parsed : null;
      parseErr = parsed <= 0n;
    } catch {
      parseErr = true;
    }
  }

  const { needsApproval, approve, isApproving, refetchAllowance, allowance } = useErc20Approval(
    prizeToken,
    potAddress,
    amount ?? undefined,
  );

  // Native mode step 1: wrap BNB -> WBNB by sending value to WBNB.deposit().
  const wrapTx = useAdminTx(() => {
    refetchBalance();
    refetchNative();
    refetchAllowance();
  });

  const fundTx = useAdminTx(() => {
    setVal('');
    refetchAllowance();
    refetchBalance();
    refetchNative();
    onDone();
  });

  // In native mode the wrap step is "done" once the wallet holds enough WBNB to
  // cover the amount (from this wrap, or WBNB it already had).
  //
  // ⚠ A NATIVELY-SETTLED POT SKIPS BOTH GATES ENTIRELY. There is no token to
  // hold, so `balance` is permanently undefined, so `haveWbnbForAmount` is
  // permanently false — which pinned `needWrap` true and made `readyToFund`
  // unreachable in both modes. The owner could not seed the pot at all.
  const haveWbnbForAmount = amount !== null && balance !== undefined && balance >= amount;
  const needWrap = !nativePot && mode === 'native' && !haveWbnbForAmount;

  // Affordability: native BNB gates the wrap; WBNB gates a direct WBNB send.
  // On a native pot the send itself is `msg.value`, so native BNB gates it.
  const overWbnb =
    !nativePot && mode === 'wbnb' && amount !== null && balance !== undefined && amount > balance;
  const overNative =
    (nativePot || (mode === 'native' && needWrap)) &&
    amount !== null &&
    nativeValue !== undefined &&
    amount > nativeValue;
  const overBalance = overWbnb || overNative;
  // Post-wrap the send draws on WBNB (already held), so native balance no longer
  // gates it — only the WBNB-direct path is balance-gated at send time.
  const readyToFund = nativePot
    ? amount !== null && route !== null && !overNative
    : amount !== null && !needWrap && !needsApproval && route !== null && !overWbnb;

  return (
    <div className="space-y-2 border-t border-bull-border/60 pt-3">
      <div className="flex items-baseline justify-between gap-3">
        <div className="bull-header text-sm text-bull-gold">fill the pool</div>
        <div className="font-mono text-xs text-bull-text-faint">
          {nativePot ? (
            <>{symbol} · native</>
          ) : prizeToken ? (
            <>
              {symbol} · <Addr addr={prizeToken} />
            </>
          ) : (
            'reading the prize token…'
          )}
        </div>
      </div>

      {isWbnbPot && (
        <div className="flex items-center gap-2 text-xs">
          <span className="text-bull-text-faint">pay with</span>
          <div className="inline-flex overflow-hidden rounded border border-bull-border">
            <button
              type="button"
              onClick={() => setMode('native')}
              className={`px-2 py-1 ${mode === 'native' ? 'bg-bull-gold/20 text-bull-gold' : 'text-bull-text-dim hover:text-bull-text'}`}
            >
              native BNB (auto-wrap)
            </button>
            <button
              type="button"
              onClick={() => setMode('wbnb')}
              className={`px-2 py-1 ${mode === 'wbnb' ? 'bg-bull-gold/20 text-bull-gold' : 'text-bull-text-dim hover:text-bull-text'}`}
            >
              WBNB direct
            </button>
          </div>
        </div>
      )}

      <p className="text-xs text-bull-red">
        this only goes one way. once it is in the pool nobody can pull it back out — not you, not
        anyone. there is no withdraw on this contract. the only way money leaves a pool is a winner
        taking it.
      </p>

      {!wallet ? (
        <p className="text-xs text-bull-text-dim">connect the wallet you want to fund from.</p>
      ) : route === null ? (
        <div className="space-y-1 rounded border border-bull-red/50 p-2 text-xs">
          <div className="text-bull-red">this wallet cannot fund this pool, so nothing here would land.</div>
          <div className="text-bull-text-dim">
            <span className="font-mono">topUp()</span> only works for the owner (
            <Addr addr={owner} />
            ), and <span className="font-mono">fund()</span> only for a wallet the owner has made a
            funder. switch to the owner wallet, or have the owner run{' '}
            <span className="font-mono">setFunder(this wallet, true)</span> on this pot.
          </div>
        </div>
      ) : (
        <>
          <p className="text-xs text-bull-text-dim">
            {route === 'topUp' ? (
              <>
                you own this pot, so this goes through{' '}
                <span className="font-mono text-bull-text">topUp()</span>.
              </>
            ) : (
              <>
                this wallet is a funder, so this goes through{' '}
                <span className="font-mono text-bull-text">fund()</span>.
              </>
            )}{' '}
            {nativePot
              ? 'one transaction. this pot holds native bnb, so there is nothing to wrap and nothing to approve.'
              : mode === 'native'
                ? 'three transactions: wrap your BNB to WBNB, approve the pot, then send it in.'
                : 'two transactions: the pot pulls the WBNB off you, so you approve it first, then send.'}
          </p>

          {(() => {
            const unit = nativePot || mode === 'native' ? 'BNB' : symbol;
            const held = nativePot || mode === 'native' ? nativeValue : balance;
            return (
              <div className="flex flex-wrap items-center gap-2">
                <span className="w-28 shrink-0 text-xs text-bull-text-faint">amount · {unit}</span>
                <AdminInput
                  value={val}
                  onChange={(e) => setVal(e.target.value)}
                  placeholder={mode === 'native' ? 'e.g. 0.05' : 'e.g. 1000'}
                  inputMode="decimal"
                  className="w-40"
                  aria-label={`amount of ${unit} to add to the pool`}
                />
                <span className="text-xs text-bull-text-faint">
                  you hold{' '}
                  <button
                    type="button"
                    className="font-mono tabular-nums text-bull-text hover:text-bull-gold"
                    title={mode === 'native' ? 'use it all, less a little for gas' : 'use the lot'}
                    onClick={() => {
                      if (held === undefined || decimals === undefined) return;
                      if (mode === 'native') {
                        // leave a little native BNB for gas across wrap/approve/send.
                        const reserve = 5_000_000_000_000_000n; // 0.005 BNB
                        setVal(formatUnits(held > reserve ? held - reserve : 0n, decimals));
                      } else {
                        setVal(formatUnits(held, decimals));
                      }
                    }}
                  >
                    {fmtAmount(held, decimals ?? 18)}
                  </button>{' '}
                  {unit}
                </span>
              </div>
            );
          })()}

          {parseErr && (
            <p className="font-mono text-xs text-bull-red">✗ that is not an amount. e.g. 1000 or 12.5.</p>
          )}
          {overBalance && (
            <p className="font-mono text-xs text-bull-red">
              ✗ that is more {nativePot || mode === 'native' ? 'BNB' : symbol} than this wallet holds.
            </p>
          )}

          {!nativePot && mode === 'native' && (
            <div className="flex flex-wrap items-center gap-2">
              <span className={`w-28 shrink-0 text-xs ${needWrap ? 'text-bull-gold' : 'text-bull-text-faint'}`}>
                1 · wrap
              </span>
              <WriteButton
                tx={wrapTx}
                disabled={amount === null || overNative || !needWrap}
                onClick={() => {
                  if (amount === null || !prizeToken) return;
                  void wrapTx.run({ address: prizeToken, abi: WbnbAbi, functionName: 'deposit', value: amount });
                }}
              >
                wrap BNB → WBNB
              </WriteButton>
              <span className="font-mono text-xs text-bull-text-faint">
                {amount === null
                  ? '—'
                  : needWrap
                    ? `wraps ${fmtAmount(amount, decimals ?? 18)} BNB`
                    : `✓ you hold ${fmtAmount(balance, decimals ?? 18)} WBNB`}
              </span>
            </div>
          )}
          {!nativePot && mode === 'native' && <TxStatus tx={wrapTx} />}

          {!nativePot && (
          <div className="flex flex-wrap items-center gap-2">
            <span className={`w-28 shrink-0 text-xs ${needsApproval && !needWrap ? 'text-bull-gold' : 'text-bull-text-faint'}`}>
              {mode === 'native' ? '2 · approve' : '1 · approve'}
            </span>
            <button
              type="button"
              disabled={amount === null || overBalance || needWrap || !needsApproval || isApproving}
              onClick={async () => {
                setApproveErr(null);
                try {
                  await approve();
                  refetchAllowance();
                } catch (e) {
                  setApproveErr(decodeRevert(e));
                }
              }}
              className="bull-btn bull-btn-secondary min-h-0 shrink-0 px-3 py-1.5 text-xs disabled:opacity-50"
            >
              {isApproving ? 'approving…' : `approve ${symbol}`}
            </button>
            <span className="font-mono text-xs text-bull-text-faint">
              {allowance === undefined
                ? '—'
                : amount !== null && !needsApproval
                  ? '✓ approved for this much'
                  : `approved: ${fmtAmount(allowance, decimals ?? 18)} ${symbol}`}
            </span>
          </div>
          )}
          {!nativePot && <RevertNotice error={approveErr} />}

          <div className="flex flex-wrap items-center gap-2">
            <span className={`w-28 shrink-0 text-xs ${readyToFund ? 'text-bull-gold' : 'text-bull-text-faint'}`}>
              {nativePot ? 'send it in' : mode === 'native' ? '3 · send it in' : '2 · send it in'}
            </span>
            <WriteButton
              tx={fundTx}
              danger
              disabled={!readyToFund}
              onClick={() => {
                if (!readyToFund || amount === null) return;
                // ⚠ THE NATIVE POT'S DOORS TAKE `msg.value`, NOT AN ARGUMENT.
                // `topUp()` is payable with no args and `fundNative(string)`
                // takes only the source label — sending the old
                // `topUp(uint256)` shape would not even match a selector.
                if (nativePot) {
                  if (route === 'topUp') {
                    void fundTx.run({
                      address: potAddress,
                      abi: JackpotNativeAbi,
                      functionName: 'topUp',
                      value: amount,
                    });
                  } else {
                    void fundTx.run({
                      address: potAddress,
                      abi: JackpotNativeAbi,
                      functionName: 'fundNative',
                      args: ['admin-fund'],
                      value: amount,
                    });
                  }
                  return;
                }
                if (route === 'topUp') {
                  void fundTx.run({ address: potAddress, abi: JackpotAbi, functionName: 'topUp', args: [amount] });
                } else {
                  void fundTx.run({
                    address: potAddress,
                    abi: JackpotAbi,
                    functionName: 'fund',
                    args: [amount, 'admin-fund'],
                  });
                }
              }}
            >
              {route === 'topUp' ? 'topUp' : 'fund'} the pool
            </WriteButton>
            <span className="text-xs text-bull-text-faint">
              {amount === null
                ? 'put an amount in first.'
                : nativePot
                  ? 'one transaction. the bnb rides along with it.'
                  : needWrap
                    ? 'wrap to WBNB first.'
                    : needsApproval
                      ? 'approve first, this pulls the WBNB off you.'
                      : 'no take-backs after this one lands.'}
            </span>
          </div>
          <TxStatus tx={fundTx} />
        </>
      )}
    </div>
  );
}

/**
 * odds · payout bps · min pool. One-shot bootstrap before anything is set, then
 * a timelocked propose/commit/cancel after.
 */
function PayoutParamsPanel({
  potAddress,
  decimals,
  symbol,
  bootstrapped,
  oddsOneIn,
  payoutBps,
  minPoolToFire,
  proposedOdds,
  proposedPayoutBps,
  proposedMinPool,
  eta,
  wiringDelay,
  onDone,
}: {
  potAddress: `0x${string}`;
  decimals: number | undefined;
  symbol: string;
  bootstrapped: boolean | undefined;
  oddsOneIn: bigint | undefined;
  payoutBps: bigint | undefined;
  minPoolToFire: bigint | undefined;
  proposedOdds: bigint | undefined;
  proposedPayoutBps: bigint | undefined;
  proposedMinPool: bigint | undefined;
  eta: bigint | undefined;
  wiringDelay: bigint | undefined;
  onDone: () => void;
}) {
  const tx = useAdminTx(onDone);
  const commitTx = useAdminTx(onDone);
  const cancelTx = useAdminTx(onDone);
  const [odds, setOdds] = useState('');
  const [bps, setBps] = useState('');
  const [minPool, setMinPool] = useState('');

  const dec = decimals ?? 18;
  const hasPending = eta !== undefined && eta > 0n;
  const now = BigInt(Math.floor(Date.now() / 1000));
  const ready = hasPending && eta !== undefined && now >= eta;

  function build(): { odds: bigint; bps: bigint; minPool: bigint } | null {
    try {
      const o = BigInt(odds || '0');
      const b = BigInt(bps || '0');
      const m = parseUnits(minPool || '0', dec);
      if (o <= 0n || b <= 0n || b > 10_000n) return null;
      return { odds: o, bps: b, minPool: m };
    } catch {
      return null;
    }
  }
  const parsed = build();

  return (
    <div className="space-y-3 border-t border-bull-border/60 pt-3">
      <div className="flex items-baseline justify-between">
        <div className="bull-header text-sm text-bull-text">payout params</div>
        <div className="font-mono text-xs text-bull-text-faint">
          delay {wiringDelay !== undefined ? `${Number(wiringDelay)}s` : '—'}
        </div>
      </div>

      <div className="grid gap-x-6 gap-y-1 md:grid-cols-3">
        <KV k="odds (1 in N)" v={oddsOneIn?.toString() ?? '—'} />
        <KV k="payout bps" v={payoutBps?.toString() ?? '—'} />
        <KV k="min pool" v={`${fmtAmount(minPoolToFire, dec)} ${symbol}`} />
      </div>

      {hasPending && (
        <div className="rounded border border-bull-gold/40 bg-bull-gold/5 p-2 text-xs">
          <div className="font-mono text-bull-gold">
            proposed → odds {proposedOdds?.toString() ?? '—'} · payout {proposedPayoutBps?.toString() ?? '—'} bps ·
            min {fmtAmount(proposedMinPool, dec)} {symbol}
          </div>
          <div className="mt-1 text-bull-text-dim">
            eta {eta !== undefined ? new Date(Number(eta) * 1000).toLocaleString() : '—'} ·{' '}
            {ready ? 'ready to commit' : 'still timelocked'}
          </div>
        </div>
      )}

      <div className="grid grid-cols-3 gap-2">
        <label className="space-y-1 text-xs text-bull-text-faint">
          <span>odds (1 in N)</span>
          <AdminInput value={odds} onChange={(e) => setOdds(e.target.value)} inputMode="numeric" placeholder={oddsOneIn?.toString() ?? '150'} className="w-full" />
        </label>
        <label className="space-y-1 text-xs text-bull-text-faint">
          <span>payout bps (≤10000)</span>
          <AdminInput value={bps} onChange={(e) => setBps(e.target.value)} inputMode="numeric" placeholder={payoutBps?.toString() ?? '10000'} className="w-full" />
        </label>
        <label className="space-y-1 text-xs text-bull-text-faint">
          <span>min pool ({symbol})</span>
          <AdminInput value={minPool} onChange={(e) => setMinPool(e.target.value)} inputMode="decimal" placeholder={fmtAmount(minPoolToFire, dec)} className="w-full" />
        </label>
      </div>

      {bootstrapped === false ? (
        <div className="space-y-1">
          <WriteButton
            tx={tx}
            disabled={!parsed}
            onClick={() =>
              parsed &&
              void tx.run({
                address: potAddress,
                abi: JackpotAbi,
                functionName: 'bootstrapPayoutParams',
                args: [parsed.odds, parsed.bps, parsed.minPool],
              })
            }
          >
            bootstrap payout params
          </WriteButton>
          <p className="text-[11px] text-bull-text-faint">
            one-shot, no timelock — this pot has not been configured yet. after this, changes go
            through the propose/commit flow below.
          </p>
          <TxStatus tx={tx} />
        </div>
      ) : (
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <WriteButton
              tx={tx}
              disabled={!parsed}
              onClick={() =>
                parsed &&
                void tx.run({
                  address: potAddress,
                  abi: JackpotAbi,
                  functionName: 'proposePayoutParams',
                  args: [parsed.odds, parsed.bps, parsed.minPool],
                })
              }
            >
              propose
            </WriteButton>
            <WriteButton
              tx={commitTx}
              disabled={!ready}
              onClick={() => void commitTx.run({ address: potAddress, abi: JackpotAbi, functionName: 'commitPayoutParams' })}
            >
              commit
            </WriteButton>
            <WriteButton
              tx={cancelTx}
              danger
              disabled={!hasPending}
              onClick={() => void cancelTx.run({ address: potAddress, abi: JackpotAbi, functionName: 'cancelPayoutParams' })}
            >
              cancel
            </WriteButton>
          </div>
          <p className="text-[11px] text-bull-text-faint">
            two steps: propose the new numbers, wait out the delay, then commit. cancel drops a
            pending proposal.
          </p>
          <TxStatus tx={tx} />
          <TxStatus tx={commitTx} />
          <TxStatus tx={cancelTx} />
        </div>
      )}
    </div>
  );
}
