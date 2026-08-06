import Link from 'next/link';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { BullSprite } from '@/components/BullSprite';
import { getBull, isValidBullId, MAX_ID } from '@/lib/art/collection';
import { ACC_LABEL, BAND_INFO, KING_ID, WEAPON_KIND } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import { KING_FLAVOUR, TIER_FLAVOUR } from '@/lib/brand';
import { BullOnChainPanel } from '@/components/bull/BullOnChainPanel';

interface PageProps {
  params: Promise<{ id: string }>;
}

function parseId(raw: string): number | null {
  if (!/^\d+$/.test(raw)) return null;
  const id = Number(raw);
  return isValidBullId(id) ? id : null;
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { id: raw } = await params;
  const id = parseId(raw);
  if (id === null) return { title: 'bull not found' };
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
    </div>
  );
}
