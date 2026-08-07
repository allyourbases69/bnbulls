'use client';

import Link from 'next/link';
import { useReadContract } from 'wagmi';
import { BullsAbi, MarketplaceAbi, YardsAbi } from '@/lib/abi';
import { contractAddress, explorerBaseUrl } from '@/lib/env';
import { shortAddr, formatUsd1e18 } from '@/lib/format';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { PIT } from '@/lib/brand';

interface BullStruct {
  strength: number;
  dexterity: number;
  constitution: number;
  intelligence: number;
  wisdom: number;
  charisma: number;
  weaponId: number;
  level: number;
  xp: number;
  elo: number;
  wins: number;
  losses: number;
  ties: number;
  isDead: boolean;
  name: string;
}

interface ListingStruct {
  seller: `0x${string}`;
  listedAt: bigint;
  bnbullMode: number;
  usdPrice: bigint;
  bnbullPrice: bigint;
}

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

/**
 * The live, on-chain half of a bull's page: owner, alive/dead, fight record,
 * ELO, and listing state. Everything here reads a real contract call and
 * renders an honest "not deployed" / "not minted yet" state rather than a
 * placeholder the moment any piece is missing — see the frontend package
 * brief's "no fake data anywhere" constraint.
 */
export function BullOnChainPanel({ tokenId, isKing }: { tokenId: number; isKing: boolean }) {
  const bullsAddress = contractAddress('bullsNft');
  const marketAddress = contractAddress('marketplace');
  const explorer = explorerBaseUrl();

  const {
    data: owner,
    isError: ownerError,
    isLoading: ownerLoading,
  } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'ownerOf',
    args: [BigInt(tokenId)],
    query: { enabled: !!bullsAddress },
  });

  const { data: bullData, isLoading: bullLoading } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'getBull',
    args: [BigInt(tokenId)],
    query: { enabled: !!bullsAddress && !ownerError },
  });

  const { data: listing } = useReadContract({
    address: marketAddress ?? undefined,
    abi: MarketplaceAbi,
    functionName: 'listingOf',
    args: [BigInt(tokenId)],
    query: { enabled: !!marketAddress && !ownerError },
  });

  /**
   * ⚠ ONE OF THE THREE FACTS THAT DECIDE WHETHER THIS BULL CAN FIGHT, and the
   * only one nothing else on the page carries. `Duel` reverts `BullNotInYards`
   * for a bull that is out, and the entry is stored against the wallet that
   * ENTERED it — so a sale voids it silently, with no event and nothing on the
   * token to show for it. This is the page somebody reads before they buy, so
   * it is the page that has to say it.
   */
  const yardsAddress = contractAddress('yards');
  const { data: pitStatus } = useReadContract({
    address: yardsAddress ?? undefined,
    abi: YardsAbi,
    functionName: 'statusOf',
    args: [BigInt(tokenId)],
    query: { enabled: !!yardsAddress && !ownerError },
  });
  const [, pitLeavesAt, pitLive] =
    (pitStatus as readonly [`0x${string}`, bigint, boolean] | undefined) ?? [
      undefined,
      undefined,
      undefined,
    ];

  if (!bullsAddress) {
    return <NotDeployed what="the bulls collection" />;
  }

  if (!ownerLoading && ownerError) {
    return (
      <div className="rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
        {isKing ? 'the king ' : 'this bull '}hasn&apos;t been minted yet. the contract is live,
        token #{tokenId} just doesn&apos;t exist on chain yet. this is a preview of exactly
        what it will look like the moment it does.
      </div>
    );
  }

  const b = bullData as unknown as BullStruct | undefined;
  const l = listing as unknown as ListingStruct | undefined;
  const isListed = !!l && l.seller && l.seller !== ZERO_ADDR;

  return (
    <div className="rounded border border-bull-border bg-bull-panel p-4">
      <dl className="grid grid-cols-2 gap-x-6 gap-y-4 text-sm sm:grid-cols-3">
        <div>
          <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">owner</dt>
          <dd className="mt-1">
            {ownerLoading || !owner ? (
              'loading…'
            ) : (
              <a
                href={`${explorer}/address/${owner}`}
                target="_blank"
                rel="noreferrer noopener"
                className="font-mono text-bull-gold hover:underline"
              >
                {shortAddr(owner as string)}
              </a>
            )}
          </dd>
        </div>
        <div>
          <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">status</dt>
          <dd className="mt-1">
            {bullLoading || !b ? (
              'loading…'
            ) : b.isDead ? (
              <span className="text-bull-red">dead 💀</span>
            ) : (
              <span className="text-bull-text">alive</span>
            )}
          </dd>
        </div>
        <div>
          <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">elo</dt>
          <dd className="mt-1 font-mono">{bullLoading || !b ? '—' : b.elo}</dd>
        </div>
        <div>
          <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
            fight record
          </dt>
          <dd className="mt-1 font-mono">
            {bullLoading || !b ? '—' : `${b.wins}W · ${b.losses}L · ${b.ties}T`}
          </dd>
        </div>
        <div>
          <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
            {PIT.label}
          </dt>
          <dd className="mt-1">
            {!yardsAddress ? (
              'not deployed yet'
            ) : pitLive === undefined ? (
              // ⚠ NEVER "out of the pit" off an unread call. That would tell a
              // prospective buyer this bull cannot fight when it may well be in.
              '—'
            ) : pitLive && pitLeavesAt !== undefined && pitLeavesAt > 0n ? (
              <span className="text-bull-gold">{PIT.leavingLabel}</span>
            ) : pitLive ? (
              <span className="text-bull-text">{PIT.inLabel}</span>
            ) : (
              <span className="text-bull-text-faint">{PIT.outLabel}</span>
            )}
          </dd>
        </div>
        <div className="col-span-2 sm:col-span-1">
          <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
            marketplace
          </dt>
          <dd className="mt-1">
            {!marketAddress ? (
              'not deployed yet'
            ) : isListed ? (
              <Link href="/market" className="text-bull-gold hover:underline">
                listed · {formatUsd1e18(l?.usdPrice)}
              </Link>
            ) : (
              'not listed'
            )}
          </dd>
        </div>
      </dl>
      {b?.isDead && (
        <p className="mt-4 text-sm text-bull-text-dim">
          this bull is in the graveyard.{' '}
          <Link href="/graveyard" className="text-bull-gold hover:underline">
            check the revive ladder →
          </Link>
        </p>
      )}
      {!b?.isDead && pitLive === false && (
        <p className="mt-4 text-sm text-bull-text-dim">
          {PIT.rule}{' '}
          <Link href="/duel" className="text-bull-gold hover:underline">
            {PIT.label} →
          </Link>
        </p>
      )}
      {!b?.isDead && pitLive === true && pitLeavesAt !== undefined && pitLeavesAt > 0n && (
        // ⚠ SAYS "STILL FIGHTABLE", not "leaving", because that is the fact
        // that costs money if you get it wrong. `inYardsFor` returns true until
        // `leavesAt` passes, on purpose, so a fight signed before the eject
        // still lands.
        // ⚠ BOTH HALVES, ALWAYS. `ejectPending` alone reads as "your bull can
        // still be dragged into fights for 15 minutes", which is false and is
        // the reading the owner arrived at. The bull is unmatchable the instant
        // the eject confirms; the countdown only covers fights already signed.
        // Printing the warning without the reassurance makes a safety property
        // look like a penalty.
        <div className="mt-4 space-y-1 text-sm text-bull-text-dim">
          <p>{PIT.ejectImmediate}</p>
          <p>{PIT.ejectPending}</p>
        </div>
      )}
    </div>
  );
}
