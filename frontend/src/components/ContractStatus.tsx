import { contractAddress, explorerBaseUrl, type ContractName } from '@/lib/env';

const CONTRACTS: Array<{ name: ContractName; label: string }> = [
  { name: 'bnbullToken', label: '$BNBULL token' },
  { name: 'bullsNft', label: 'bulls (nft)' },
  { name: 'mintDrop', label: 'mint drop' },
  // The pen holds every bull nobody has bought yet, so it is the one address a
  // sceptic wants when they go looking for "where did the unsold ones go".
  { name: 'bullPen', label: 'the pen (unsold bulls)' },
  { name: 'duel', label: 'duel' },
  { name: 'graveyard', label: 'graveyard' },
  { name: 'jackpotBnbull', label: 'jackpot · $BNBULL' },
  { name: 'jackpotBnb', label: 'jackpot · BNB' },
  { name: 'marketplace', label: 'marketplace' },
];

/**
 * Honest, live-read contract status. Every address here comes straight from
 * `NEXT_PUBLIC_*` env vars — nothing is hardcoded, nothing is invented. Until
 * a real deploy sets the env var, every row reads "not deployed yet". See
 * the frontend package brief's hard constraints: an invented address that
 * later ships for real is a real-money bug.
 */
export function ContractStatus() {
  const explorer = explorerBaseUrl();
  return (
    <ul className="grid gap-2 sm:grid-cols-2">
      {CONTRACTS.map(({ name, label }) => {
        const addr = contractAddress(name);
        return (
          <li
            key={name}
            className="flex items-center justify-between gap-3 rounded border border-bull-border bg-bull-panel px-3 py-2 text-sm"
          >
            <span className="text-bull-text-dim">{label}</span>
            {addr ? (
              <a
                href={`${explorer}/address/${addr}`}
                target="_blank"
                rel="noreferrer noopener"
                className="font-mono text-xs text-bull-gold hover:underline"
              >
                {addr.slice(0, 6)}…{addr.slice(-4)}
              </a>
            ) : (
              <span className="rounded-full border border-bull-border px-2 py-0.5 text-[11px] uppercase tracking-wide text-bull-text-faint">
                not deployed yet
              </span>
            )}
          </li>
        );
      })}
    </ul>
  );
}
