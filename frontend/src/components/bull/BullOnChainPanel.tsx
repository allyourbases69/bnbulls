'use client';

import Link from 'next/link';
import { useReadContract } from 'wagmi';
import { BullsAbi, MarketplaceAbi, YardsAbi } from '@/lib/abi';
import { contractAddress, explorerBaseUrl } from '@/lib/env';
import { shortAddr, formatUsd1e18 } from '@/lib/format';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { PIT } from '@/lib/brand';
import { usePen } from '@/lib/hooks/usePen';

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

  /**
   * ⚠ "IS THIS MINTED" IS ANSWERED BY A CALL THAT SUCCEEDS, NOT BY ONE THAT
   * REVERTS. `ownerOf` reverts for an unminted token, so this panel used to
   * read "not minted" off `ownerError` alone — which is wrong in BOTH
   * directions. A rate-limited or failed rpc raises the same flag, so a live
   * bull whose owner call bounced was told to the world as "hasn't been
   * minted", and while the query sat retrying, the table underneath printed
   * `loading…` with nothing to ever resolve it (the owner hit exactly this on
   * /bull/11, still spinning after nine seconds).
   *
   * `nextTokenId` and `kingMinted` always return, so they decide the question
   * on their own: ids `1 .. nextTokenId-1` EXIST, and the king exists when he
   * says he does. `ownerError` is then only ever used to explain a FAILURE,
   * never to invent a fact.
   *
   * ⚠ EXISTING IS NO LONGER THE SAME AS BEING SOLD — see the pen check below.
   */
  const {
    data: nextTokenId,
    isError: supplyError,
  } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'nextTokenId',
    query: { enabled: !!bullsAddress && !isKing },
  });

  const {
    data: kingIsMinted,
    isError: kingError,
  } = useReadContract({
    address: bullsAddress ?? undefined,
    abi: BullsAbi,
    functionName: 'kingMinted',
    query: { enabled: !!bullsAddress && isKing },
  });

  /** The token EXISTS on chain. true / false when the chain has told us;
   *  undefined while it has not. */
  const exists: boolean | undefined = isKing
    ? (kingIsMinted as boolean | undefined)
    : nextTokenId === undefined
      ? undefined
      : tokenId < Number(nextTokenId);
  const supplyUnreadable = isKing ? kingError : supplyError;

  /**
   * ⚠ "EXISTS" AND "SOLD" ARE TWO DIFFERENT QUESTIONS NOW, AND THIS PANEL HAS
   * TO ANSWER BOTH.
   *
   * `BullPen` is stocked by minting the whole remaining supply straight to it,
   * so after the pre-mint there are several hundred bulls that exist, have real
   * stats, have a real `ownerOf` — and that nobody has bought. Judging "minted"
   * off `nextTokenId` alone would put every one of them into the ordinary panel
   * below, whose owner row would then link the PEN CONTRACT as if a person held
   * it. A visitor reading that concludes the bull is taken.
   *
   * ⚠ THE OWNER COMPARISON IS THE PRIMARY TEST, NOT `poolIds()`. This page has
   * already read `ownerOf` for its own sake, and `owner == the pen` is a direct
   * fact about THIS token that stays true even if the pool read never lands.
   * `heldIds` is kept as the second source only because it can answer before
   * `ownerOf` does, so the page does not flash a pen address and then correct
   * itself.
   */
  const pen = usePen();
  const penAddr = pen.penAddress?.toLowerCase() ?? null;
  const ownerIsPen =
    !!penAddr && typeof owner === 'string' && (owner as string).toLowerCase() === penAddr;
  const penHeld = ownerIsPen || (pen.isPen && pen.heldIds.has(tokenId));

  // "Minted" in the player-facing sense — in circulation — is now
  // `exists && !penHeld`, and it is expressed as the ORDER OF THE BRANCHES
  // below rather than as a boolean, because the two halves need different
  // screens: `exists === false` is "this token was never minted", `penHeld` is
  // "minted, real, and nobody has bought it". A single flag would have to pick
  // one of those sentences for both cases, and either choice is a lie about the
  // other.

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

  // ⚠ Hoisted above the early returns: the pen branch below shows real stats
  // too, and reading them there off a second cast would be the same fact
  // decoded twice with two chances to drift.
  const b = bullData as unknown as BullStruct | undefined;
  const l = listing as unknown as ListingStruct | undefined;
  const isListed = !!l && l.seller && l.seller !== ZERO_ADDR;

  if (!bullsAddress) {
    return <NotDeployed what="the bulls collection" />;
  }

  // The chain says plainly that this token does not exist at all.
  // ⚠ GATED ON `exists`, NOT ON `minted`. A pen-held bull is `minted === false`
  // by the definition above and it very much DOES exist — sending it down here
  // would tell a visitor that a bull with live stats and a live owner has never
  // been minted, and offer them a mint that cannot produce it.
  if (exists === false) {
    return (
      <div className="rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
        {isKing ? 'the king ' : 'this bull '}hasn&apos;t been minted yet. the contract is live,
        token #{tokenId} just doesn&apos;t exist on chain yet. this is a preview of exactly
        what it will look like the moment it does.{' '}
        <Link href="/mint" className="text-bull-gold hover:underline">
          mint one →
        </Link>
      </div>
    );
  }

  /**
   * IN THE PEN: he exists, his papers are real, and nobody has bought him.
   *
   * ⚠ NO OWNER ROW, AND THAT IS THE WHOLE REASON THIS BRANCH EXISTS. The pen is
   * the registered `ownerOf` this token, so the ordinary panel would print a
   * contract address under "owner" and link it to the explorer — which reads,
   * to anybody who is not holding the source, as "somebody already has this
   * one". The honest answer is that he is unsold and up for grabs.
   *
   * ⚠ AND NO CLAIM ABOUT ODDS. The pool is public (`poolIds()` is a deliberate
   * view — knowing what is left tells you the odds, which is the honest thing to
   * publish) but WHICH bull a buyer is dealt is decided by a seed that does not
   * exist when they pay. So this says "you cannot ask for him", plainly, rather
   * than dressing the mint up as a way to get this particular bull.
   */
  if (penHeld) {
    return (
      <div className="rounded border border-bull-gold/40 bg-bull-panel p-4">
        <p className="bull-header text-bull-gold">nobody owns this one yet.</p>
        <p className="mt-2 text-sm text-bull-text-dim">
          {isKing ? 'the king is' : 'he is'} minted and sitting in the pen with the rest of the
          unsold bulls. everything on this page is real: the art, the stats, the weapon, the
          name. he just has not been bought.
        </p>
        <p className="mt-2 text-sm text-bull-text-dim">
          you cannot pick him. the pen deals a bull at random when you mint, off a seed that does
          not exist yet when you pay, so nobody can wait for the good ones and nobody can aim at
          this one.{' '}
          {pen.poolSize !== null && (
            <>
              <span className="font-mono text-bull-text">{pen.poolSize}</span> bulls are in there
              right now
              {pen.sellable !== null && pen.sellable !== pen.poolSize ? (
                <>
                  , <span className="font-mono text-bull-text">{pen.sellable}</span> of them still
                  up for grabs
                </>
              ) : null}
              .{' '}
            </>
          )}
        </p>
        <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-4 border-t border-bull-border/60 pt-4 text-sm sm:grid-cols-3">
          <div>
            <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
              owner
            </dt>
            <dd className="mt-1 text-bull-text-faint">nobody · still in the pen</dd>
          </div>
          <div>
            <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">elo</dt>
            <dd className="mt-1 font-mono">{bullLoading || !b ? '—' : b.elo}</dd>
          </div>
          {/* ⚠ READ, NOT ASSUMED TO BE ZERO. An unsold bull has never fought,
              so the honest answer is almost always 0/0/0 — but "almost always"
              is not a licence to print a number this page did not read, and the
              record is live chain state either way. */}
          <div>
            <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
              fight record
            </dt>
            <dd className="mt-1 font-mono">
              {bullLoading || !b ? '—' : `${b.wins}W · ${b.losses}L · ${b.ties}T`}
            </dd>
          </div>
        </dl>
        <p className="mt-4">
          <Link href="/mint" className="text-bull-gold hover:underline">
            take a bull out of the pen →
          </Link>
        </p>
      </div>
    );
  }

  // ⚠ A FAILED READ IS A FAILED READ. It is minted (or we could not even ask),
  // and the owner call bounced — say so and offer a reload, rather than
  // printing `loading…` forever or claiming the bull does not exist.
  if (ownerError && (exists === true || supplyUnreadable)) {
    return (
      <div className="rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
        couldn&apos;t read this bull off the chain just now. that is an rpc having a moment,
        not a missing bull. give it a second and reload.
      </div>
    );
  }

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
        // still be dragged into fights until the countdown ends", which is false and is
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
