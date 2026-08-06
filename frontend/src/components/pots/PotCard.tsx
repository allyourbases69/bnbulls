'use client';

import { useReadContract } from 'wagmi';
import { JackpotAbi } from '@/lib/abi';
import { contractAddress, explorerBaseUrl } from '@/lib/env';
import { formatToken, shortAddr } from '@/lib/format';
import { tickerToPrint, useTokenDecimals, useTokenSymbol } from '@/lib/hooks/useTokenDecimals';
import { useJackpotAwards } from '@/lib/hooks/useJackpotAwards';
import { QUOTE_REFRESH_MS } from '@/lib/constants';
import { NotDeployed } from '@/components/shared/NotDeployed';

export function PotCard({
  name,
  label,
  symbolFallback,
  tone,
}: {
  name: 'jackpotBnbull' | 'jackpotBnb';
  label: string;
  /** ⚠ A FALLBACK, NOT THE TICKER. The real one comes off this pot's own
   *  `prizeToken().symbol()` below; this is only reached once that read has
   *  settled with no answer. See `POTS` in `brand.ts`. */
  symbolFallback: string;
  /** Which ink this pot wears. Gold is $BNBULL, steel is BNB, and it is the
   *  same vocabulary the ticker strip and the standing panels use so all three
   *  surfaces read as the same two pots. */
  tone: 'bnbull' | 'bnb';
}) {
  const address = contractAddress(name);
  const explorer = explorerBaseUrl();

  const { data: pool } = useReadContract({
    address: address ?? undefined,
    abi: JackpotAbi,
    functionName: 'pool',
    query: { enabled: !!address, refetchInterval: QUOTE_REFRESH_MS },
  });
  const { data: oddsOneIn } = useReadContract({
    address: address ?? undefined,
    abi: JackpotAbi,
    functionName: 'oddsOneIn',
    query: { enabled: !!address },
  });
  const { data: totalAwarded } = useReadContract({
    address: address ?? undefined,
    abi: JackpotAbi,
    functionName: 'totalAwarded',
    query: { enabled: !!address },
  });
  const { data: awardCount } = useReadContract({
    address: address ?? undefined,
    abi: JackpotAbi,
    functionName: 'awardCount',
    query: { enabled: !!address },
  });
  const { data: prizeToken, isError: prizeTokenError } = useReadContract({
    address: address ?? undefined,
    abi: JackpotAbi,
    functionName: 'prizeToken',
    query: { enabled: !!address },
  });
  // Both of the prize token's own facts come off the prize token: the decimals
  // decide the number, the symbol decides what it is called. Reading one live
  // and hardcoding the other renders the right amount with the wrong ticker.
  const { decimals } = useTokenDecimals(prizeToken as `0x${string}` | undefined);
  const { symbol: liveSymbol, isError: symbolError } = useTokenSymbol(
    prizeToken as `0x${string}` | undefined,
  );
  const symbol = tickerToPrint(liveSymbol, !prizeTokenError && !symbolError, symbolFallback);
  /** Pre-spaced, so a still-loading ticker leaves no orphan gap after the
   *  number. Empty is the correct render while we are still asking. */
  const unit = symbol ? ` ${symbol}` : '';

  const { awards, isLoading: loadingAwards, incomplete } = useJackpotAwards(name);

  if (!address) {
    return <NotDeployed what={`the ${label}`} />;
  }

  return (
    <div
      className={`pot-card bull-card ${tone === 'bnbull' ? 'pot-bnbull' : 'pot-bnb'} rounded p-5`}
    >
      <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">{label}</p>
      <p className="pot-figure bull-header mt-2 font-mono">
        {formatToken(pool as bigint | undefined, decimals)}{' '}
        <span className="text-base font-normal">{symbol}</span>
      </p>
      <p className="mt-1 text-sm text-bull-text-dim">
        1-in-{oddsOneIn !== undefined ? String(oddsOneIn) : '…'} on every decisive fight, own pool,
        own roll.
      </p>
      <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
        <div>
          <dt className="font-mono text-xs text-bull-text-faint">ever paid out</dt>
          <dd className="font-mono">
            {formatToken(totalAwarded as bigint | undefined, decimals)}
            {unit}
          </dd>
        </div>
        <div>
          <dt className="font-mono text-xs text-bull-text-faint">wins</dt>
          <dd className="font-mono">{awardCount !== undefined ? String(awardCount) : '—'}</dd>
        </div>
      </dl>

      <p className="mt-4 font-mono text-xs uppercase tracking-wide text-bull-text-faint">
        recent awards
      </p>
      {loadingAwards ? (
        <p className="mt-2 text-sm text-bull-text-dim">loading…</p>
      ) : awards.length === 0 ? (
        <p className="mt-2 text-sm text-bull-text-dim">none yet.</p>
      ) : (
        <ul className="mt-2 space-y-1.5 text-sm">
          {awards.slice(0, 8).map((a) => (
            <li key={`${a.txHash}-${a.ticketId}`} className="flex items-center justify-between gap-2">
              <a
                href={`${explorer}/tx/${a.txHash}`}
                target="_blank"
                rel="noreferrer noopener"
                className="font-mono text-xs text-bull-text-dim hover:text-bull-gold"
              >
                bull #{String(a.tokenId)} → {shortAddr(a.winner)}
              </a>
              <span className="font-mono text-xs text-bull-gold">
                {formatToken(a.amount, decimals)}
                {unit}
              </span>
            </li>
          ))}
        </ul>
      )}
      {incomplete && (
        <p className="mt-2 text-[11px] text-bull-text-faint">
          history shown is bounded by log range. see the deploy block config.
        </p>
      )}
    </div>
  );
}
