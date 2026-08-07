import Link from 'next/link';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { BullSprite } from '@/components/BullSprite';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { getBull, isValidBullId, MAX_ID } from '@/lib/art/collection';
import { ACC_LABEL, BAND_INFO, KING_ID, KING_NAME, SUPPLY, WEAPON_KIND } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import { KING_FLAVOUR, TIER_FLAVOUR } from '@/lib/brand';
import { contractsDeployed } from '@/lib/env';
import { BullOnChainPanel } from '@/components/bull/BullOnChainPanel';

/**
 * ⚠ BEFORE THE DROP OPENS, THIS ROUTE SHOWS THE KING AND NOBODY ELSE.
 *
 * `/bull/1` … `/bull/500` used to render every unminted bull's name, tier,
 * weapon, gear and sprite off the art engine, on a public url, with no chain
 * read involved. That is a browsable roster of the whole unsold drop — exactly
 * what the owner ruled out when `BullsGrid` was cut back to the minted set,
 * except this half was reachable by typing a number in the address bar.
 *
 * **#501 IS THE DELIBERATE EXCEPTION** (`DECISIONS.md §34`): Lord Wagyu is the
 * face of the project, he is on the favicon, the og card and the landing page,
 * and hiding him would hide the mark. He renders in full, always.
 *
 * ⚠ SAY WHAT THIS IS AND IS NOT, because overclaiming it would be worse than
 * not doing it. This is a UI decision, not a cryptographic one. The rarity
 * table comes from a PUBLIC `masterSeed` committed on chain as
 * `initialRarityHash` (`DECISIONS.md §27`), and the same shuffle, name dealer
 * and art engine ship to every browser in `lib/art/`. Anyone determined can
 * still compute an unminted bull. What this removes is the site handing the
 * whole table out on a plate. No copy anywhere claims otherwise.
 *
 * ⚠ THE GATE IS THE COLLECTION ADDRESS, so it lifts by itself on deploy day
 * and the testnet build is unaffected. Once bulls are actually minting, an
 * unminted id renders its preview again and `BullOnChainPanel` says plainly
 * that it does not exist on chain yet — which is the right answer during a
 * live drop, where "what is left" is part of the game.
 */

interface PageProps {
  params: Promise<{ id: string }>;
}

function parseId(raw: string): number | null {
  if (!/^\d+$/.test(raw)) return null;
  const id = Number(raw);
  return isValidBullId(id) ? id : null;
}

/** True when this id may be shown in full right now. Pre-launch that is the
 *  king alone; once the collection is deployed it is everyone, because the
 *  drop is running and the chain is the thing being previewed. */
function mayReveal(id: number): boolean {
  return id === KING_ID || contractsDeployed('bullsNft');
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { id: raw } = await params;
  const id = parseId(raw);
  if (id === null) {
    return {
      title: 'bull not found',
      description: 'no bull wears that number. the herd runs 1 to 501.',
    };
  }
  // ⚠ The title and description are a leak too. A hidden bull must not have
  // its name and tier read off a search result or a link preview.
  if (!mayReveal(id)) {
    return {
      title: `bull #${id}`,
      description: `bull #${id} has not been minted. the drop has not opened yet.`,
    };
  }
  const token = getBull(id);
  const flavour = id === KING_ID ? KING_FLAVOUR : TIER_FLAVOUR[token.band];
  return {
    title: `${token.name} · bnbull #${token.id}`,
    // ⚠ NO "gladiator", and no arena/roman framing anywhere in copy —
    // `DECISIONS.md §17` parked the whole vocabulary. The armour stays, the
    // word does not.
    description: `${token.band} tier · ${flavour.grade}. drawn live off the bnbulls art engine, exactly as the chain describes it.`,
  };
}

export default async function BullPage({ params }: PageProps) {
  const { id: raw } = await params;
  const id = parseId(raw);
  if (id === null) notFound();

  if (!mayReveal(id)) return <UnrevealedBull id={id} />;

  const token = getBull(id);
  const isKing = id === KING_ID;
  const info = BAND_INFO[token.band];
  const flavour = isKing ? KING_FLAVOUR : TIER_FLAVOUR[token.band];
  const prevId = id > 1 ? id - 1 : null;
  const nextId = id < MAX_ID ? id + 1 : null;

  return (
    <div className="mx-auto max-w-4xl px-4 py-8 md:px-8">
        <nav className="flex items-center justify-between text-sm text-bull-text-dim">
          <Link href="/bulls" className="hover:text-bull-gold">
            ← back to the herd
          </Link>
          <div className="flex items-center gap-4 font-mono">
            {prevId ? (
              <Link href={`/bull/${prevId}`} className="hover:text-bull-gold">
                #{prevId}
              </Link>
            ) : (
              <span className="text-bull-text-faint">#{id}</span>
            )}
            <span className="text-bull-text-faint">/</span>
            {nextId ? (
              <Link href={`/bull/${nextId}`} className="hover:text-bull-gold">
                #{nextId}
              </Link>
            ) : (
              <span className="text-bull-text-faint">#{id}</span>
            )}
          </div>
        </nav>

        <div className="mt-8 grid gap-10 sm:grid-cols-[auto_1fr]">
          <div className="mx-auto rounded border border-bull-border bg-bull-panel p-4 sm:mx-0">
            <BullSprite token={token} scale={6} />
          </div>

          <div>
            <p className="font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
              bnbull #{token.id}
              {isKing ? ' · the 1/1' : ''}
            </p>
            <h1 className="mt-2 text-3xl font-bold sm:text-4xl">{token.name}</h1>
            <p className={`mt-2 text-lg font-semibold capitalize ${TIER_COLOUR[token.band]}`}>
              {isKing ? 'king' : token.band}{' '}
              <span className="text-bull-text-faint">· {flavour.grade}</span>
            </p>
            <p className="mt-1 text-sm text-bull-text-dim">{flavour.line}</p>
            <p className="mt-1 text-sm text-bull-text-faint">
              {info.family} hide family · {info.note}
            </p>

            <div className="mt-8">
              <BullOnChainPanel tokenId={id} isKing={isKing} />
            </div>

            <dl className="mt-8 grid grid-cols-2 gap-x-6 gap-y-4 text-sm">
              <div>
                <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                  hide
                </dt>
                <dd className="mt-1">{token.skin[0]}</dd>
              </div>
              <div>
                <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                  eyes
                </dt>
                <dd className="mt-1">{token.eye[0]}</dd>
              </div>
              <div>
                <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                  horns
                </dt>
                <dd className="mt-1">{token.horn[0]}</dd>
              </div>
              <div>
                <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                  weapon
                </dt>
                <dd className="mt-1 capitalize">
                  {token.weapon}
                  <span className="text-bull-text-faint"> · {WEAPON_KIND[token.weapon]}</span>
                </dd>
              </div>
              <div className="col-span-2">
                <dt className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                  accessories
                </dt>
                <dd className="mt-1">
                  {token.accessories.length
                    ? token.accessories.map((a) => ACC_LABEL[a] ?? a).join(', ')
                    : 'clean, no accessories'}
                </dd>
              </div>
            </dl>
          </div>
        </div>

        {/* The site-level statement, so a stranger who landed straight on a
            bull page knows where the game is up to without going hunting. */}
        <PreLaunchNotice className="mt-12" />
    </div>
  );
}

/**
 * A bull that exists in the tables but has not been minted and is not the
 * king. Says so plainly, shows nothing about him, and points at the two things
 * that ARE worth looking at.
 */
function UnrevealedBull({ id }: { id: number }) {
  return (
    <div className="mx-auto max-w-2xl px-4 py-8 md:px-8">
      <nav className="text-sm text-bull-text-dim">
        <Link href="/bulls" className="hover:text-bull-gold">
          ← back to the herd
        </Link>
      </nav>

      <p className="mt-8 font-mono text-xs uppercase tracking-[0.2em] text-bull-text-faint">
        bnbull #{id}
      </p>
      <h1 className="bull-header mt-2 text-3xl sm:text-4xl">nobody has minted this one</h1>
      <p className="mt-4 text-bull-text-dim">
        #{id} is one of the {SUPPLY}, and the drop has not opened, so there is nothing to show
        you. its hide, horns, weapon and name are already fixed by the rarity table the
        contract commits to at deploy. you find out which when somebody mints it.
      </p>
      <p className="mt-3 text-bull-text-dim">
        one bull is the exception, because he is the mark on the front of everything:{' '}
        <Link href={`/bull/${KING_ID}`} className="text-bull-gold hover:underline">
          {KING_NAME.toLowerCase()}
        </Link>
        , the 1/1 at #{KING_ID}.
      </p>

      <PreLaunchNotice className="mt-10" />
    </div>
  );
}
