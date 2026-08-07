import type { Metadata } from 'next';
import Link from 'next/link';
import { ContractStatus } from '@/components/ContractStatus';
import { PreLaunchNotice } from '@/components/PreLaunchNotice';
import { BANDS, BAND_COUNTS, BAND_INFO, KING_ID, KING_NAME, SUPPLY } from '@/lib/art/bull';
import { TIER_COLOUR } from '@/lib/tierColour';
import { CURRENCY, DEAL, DEATH, KING_FLAVOUR, POTS, TICKER, TIER_FLAVOUR } from '@/lib/brand';

/**
 * THE HANDBOOK. Fefers calls it "How to Play" and links it from the landing
 * page's "first time here?" line and from the footer; this is the same page in
 * the same slot (`DECISIONS.md §33`), rewritten through the bull lens per
 * `VOICE-AND-BRAND.md §4`.
 *
 * ⚠ THE DISCLOSURE RULE, inherited and binding: state the pot flows clearly
 * everywhere money is mentioned, and never highlight the dev remainder.
 *
 * ⚠ NO INVENTED NUMBERS. Every figure below is one the owner has actually
 * decided in `DECISIONS.md`. Where a number is still owner-pending (the middle
 * rungs of the mint ladder, the revive ladder) this page says what the SHAPE
 * is and points at the live contract read instead of guessing.
 */

// ══════════════════════════════════════════════════════════════════════
//  THE WORKED EXAMPLES · every figure DERIVED, none typed in
// ══════════════════════════════════════════════════════════════════════
//
// ⚠ The table below is computed from three contract parameters and nothing
// else, so the arithmetic on the page cannot drift from the shape the contract
// implements, and a retune is one constant here rather than nine numbers in
// prose. Each is named after the on-chain variable it mirrors.
//
// ⚠ WHICH POT FILLS IS NOT A SPLIT, AND THIS IS THE EASY THING TO GET WRONG.
// `Duel._payDevCut` takes `potShareBps` of the cut and hands it to
// `Duel.routePotSliceInline(asset, slice)`, which sends a BNBULL slice WHOLE to
// the BNBULL pot and a WBNB slice WHOLE to the BNB pot. There is no swap, no
// second hop and no weighting anywhere on that path — the code says so in as
// many words, and `DECISIONS.md §26` is why (dropping the third currency
// deleted the only case that ever needed one).
//
// `§13`'s 20/10/70, 2:1-toward-BNBULL split is the MINT, revive and marketplace
// rule, which runs through `PotSplitter`/`MintDrop`, not through `Duel`.
// `DECISIONS.md §23`'s "BNBULL pot 2% / BNB pot 1%" table describes a fight
// that way and the deployed `Duel` does not do it. The contract is the source
// of truth here; the doc is stale.
//
// ⚠ ILLUSTRATIVE, NEVER A QUOTE. The live sticker is
// `Duel.usdFightPrice1e18` converted through Chainlink and discounted in
// `Duel.fighterCost`; the duel page reads it. This is a handbook example at a
// round number.

const BPS = 10_000;

/** `Duel.devShareBpsOf[asset]`. Launch value `DUEL_DEFAULT_DEV_BPS = 1000` on
 *  both currencies, hard-capped by `Duel.MAX_DEV_BPS = 2000`. The rake, taken
 *  per side in that side's own asset by `Duel._distributePot`. */
const DEV_SHARE_BPS = 1_000;

/** `Duel.potShareBps`. The share OF THE RAKE that reaches the pots, so 30% of
 *  10% = 3% of the money in the middle. It comes out of the protocol's slice;
 *  the winner's 90% is never touched by it. */
const POT_SHARE_BPS = 3_000;

/**
 * `Duel.discountBpsOf[bnbull]`.
 *
 * ⚠ ZERO since `DECISIONS.md §39` — owner call: "a $2 duel costs $2, whether
 * it is paid in BNB or in BNBULL." The `Duel` constructor no longer sets any
 * launch discount, and `Verify.s.sol` asserts it is zero so a stray
 * `setDiscountBps` before launch fails the preflight.
 *
 * `§2`'s "the discount is ALWAYS BNBULL" still holds — it belongs to MINTING.
 * A duel is a bet between two players, and discounting one side's entry means
 * they put DIFFERENT money into the same purse. `_distributePot` settles each
 * side in its own asset, so that asymmetry does not average out: it lands
 * directly in the winner's payout.
 *
 * The setter is still live, so if it is ever turned on, change this one
 * constant and every figure on the page follows.
 *
 * ⚠ AND SO DOES THE PROSE, NOW. The table below was already derived from this
 * constant, but three lines of copy around it still told players a BNBULL
 * fight was cheaper — which contradicted both this file's own constant and the
 * contract. Every claim about a fight discount is gated on `> 0` rather than
 * written out, so the words cannot drift from the number again.
 *
 * The `: number` annotation is load-bearing: without it TypeScript infers the
 * literal type `0`, and `BNBULL_DISCOUNT_BPS > 0` becomes a comparison the
 * compiler knows the answer to.
 */
const BNBULL_DISCOUNT_BPS: number = 0;

/** $2 a side, in millionths of a dollar so every division below is integer
 *  division exactly like the contract's, with no float dust in the cents. */
const EXAMPLE_STICKER = 2_000_000;

type Leg = 'bnb' | 'bnbull';

interface SideMoney {
  readonly leg: Leg;
  /** `Duel.fighterCost` — the sticker less this leg's discount. ⚠ THIS IS THE
   *  AMOUNT THAT GOES IN THE MIDDLE, which is why a discounted fight has a
   *  smaller purse rather than a bigger prize for less money. */
  readonly paid: number;
  /** `shareA`/`shareB` in `Duel._distributePot`, paid to the winner IN THIS
   *  SIDE'S OWN ASSET. */
  readonly toWinner: number;
  /** `slice` in `Duel._payDevCut`, which lands in the pot this leg names. */
  readonly toPot: number;
  readonly toDev: number;
}

function oneSide(leg: Leg): SideMoney {
  const discountBps = leg === 'bnbull' ? BNBULL_DISCOUNT_BPS : 0;
  const paid = Math.floor((EXAMPLE_STICKER * (BPS - discountBps)) / BPS);
  const devCut = Math.floor((paid * DEV_SHARE_BPS) / BPS);
  const toPot = Math.floor((devCut * POT_SHARE_BPS) / BPS);
  return { leg, paid, toWinner: paid - devCut, toPot, toDev: devCut - toPot };
}

interface Fight {
  readonly key: string;
  readonly title: string;
  readonly sides: readonly [SideMoney, SideMoney];
}

const FIGHTS: readonly Fight[] = [
  { key: 'bnbull', title: 'bnbull v bnbull', sides: [oneSide('bnbull'), oneSide('bnbull')] },
  { key: 'bnb', title: 'bnb v bnb', sides: [oneSide('bnb'), oneSide('bnb')] },
  { key: 'mixed', title: 'bnb v bnbull', sides: [oneSide('bnb'), oneSide('bnbull')] },
];

const total = (f: Fight, pick: (s: SideMoney) => number) =>
  f.sides.reduce((t, s) => t + pick(s), 0);

const legTotal = (f: Fight, leg: Leg, pick: (s: SideMoney) => number) =>
  f.sides.reduce((t, s) => (s.leg === leg ? t + pick(s) : t), 0);

const isMixed = (f: Fight) => f.sides[0].leg !== f.sides[1].leg;

/** Millionths of a dollar to "$1.80" / "$0.054". Two decimals minimum, three
 *  when the third is not a zero: the pot slices are genuine fractions of a
 *  cent and rounding them off would break the addition, which is the one thing
 *  this table exists to let a reader do. */
function usd(micro: number): string {
  return `$${(micro / 1_000_000).toFixed(3).replace(/0$/, '')}`;
}

export const metadata: Metadata = {
  title: 'how to play',
  description:
    'the bnbulls handbook: the mint ladder, the two pots, permadeath, the marketplace, the roadmap, and what is enforced by bytecode rather than promised.',
};

export default function AboutPage() {
  return (
    <div className="mx-auto max-w-4xl space-y-10 px-4 py-8 md:px-8">
      <header className="border-b border-bull-border pb-5">
        <h1 className="bull-header mb-3 text-3xl text-bull-gold md:text-4xl">how to play</h1>
        <p className="bull-header mb-3 text-base text-bull-text md:text-lg">
          mint a bull, fight someone else&apos;s for real money, and keep him off the truck.
        </p>
        <p className="text-base leading-relaxed text-bull-text-dim md:text-lg">
          {SUPPLY} bulls, plus{' '}
          <strong className="text-bull-text">{KING_NAME.toLowerCase()}</strong>, the 1/1 at token
          #{KING_ID}. every one of them is drawn by a deterministic engine from its token id, so
          the bull you see on this site is the bull the chain describes, forever. it runs on{' '}
          <strong className="text-bull-text">bnb chain</strong>.
        </p>
      </header>

      {/* Everything below describes a game that is not open yet, so it says so
          once, up front, rather than letting a reader work it out from the
          contract table at the bottom. */}
      <PreLaunchNotice />

      {/* ── the loop ─────────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">the loop</h2>
        <ol className="list-none space-y-3 pl-0 text-bull-text-dim">
          <Step n={1}>
            <Link href="/mint" className="text-bull-gold hover:underline">
              mint a bull
            </Link>
            . the price climbs by how many have sold, not by token id.
          </Step>
          <Step n={2}>
            <Link href="/duel" className="text-bull-gold hover:underline">
              send it in
            </Link>{' '}
            against someone else&apos;s. both sides put up the same dollar sticker and{' '}
            <strong className="text-bull-text">the winner takes 90% of the money in the middle</strong>
            .
          </Step>
          <Step n={3}>{POTS.rule}</Step>
          <Step n={4}>
            lose five on the trot and your bull is on the back of the truck to{' '}
            <Link href="/graveyard" className="text-bull-red hover:underline">
              {DEATH.label}
            </Link>
            . you can buy him back. not for free.
          </Step>
        </ol>
        <p className="text-sm italic text-bull-text-faint">{DEATH.philosophy}</p>

        {/* "The deal" used to sit on the landing page, the way fefers stacks
            it. The owner cut the front page down to the picture and one line,
            so it lives here now: this is the page somebody opens when they
            want the detail. */}
        <div className="max-w-2xl space-y-2 border-y border-bull-border py-4">
          <p className="bull-header text-[10px] uppercase tracking-[0.22em] text-bull-gold">
            {DEAL.eyebrow}
          </p>
          <p className="text-sm leading-relaxed text-bull-text-dim md:text-base">{DEAL.body}</p>
        </div>
      </section>

      {/* ── minting ──────────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">minting</h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p>
            the ladder starts at <strong className="text-bull-text">$10</strong> and reaches{' '}
            <strong className="text-bull-text">$75</strong> for the last 100. the price is a
            dollar sticker; it converts to bnb at pay time off a live chainlink feed, so a
            sticker does not drift with the market between blocks. the exact rungs are read
            straight off the contract on the{' '}
            <Link href="/mint" className="text-bull-gold hover:underline">
              mint page
            </Link>
            , never recomputed by this site.
          </p>
          <p>
            <strong className="text-bull-text">20% of every mint buys ${TICKER}</strong> into the{' '}
            {TICKER} pot and <strong className="text-bull-text">10% goes to the BNB pot</strong>.{' '}
            <strong className="text-bull-text">
              once money reaches a pot it can never come back out
            </strong>
            , for us or for anyone. that part is the bytecode.
          </p>
          {/* ⚠ THE HONEST CAVEAT. The sentence above used to read "that is money
              the game puts in and can never take out", full stop, which is not
              true yet. `DECISIONS.md §29`: BNBULL cannot be bought while the
              four.meme curve is filling, so the 20% leg DEFERS into a pending
              bucket on MintDrop instead. `§45` is explicit that money in a
              bucket has not reached a pot and IS recoverable —
              `withdrawPendingForManualBuy` is onlyOwner, un-timelocked, and
              takes the destination as an argument. The no-withdraw guarantee is
              real and worth stating loudly; it just starts at the pot, not at
              the mint. Say where the line is rather than letting a reader find
              it in the source. */}
          <p className="rounded border border-bull-border bg-bull-panel p-4">
            <strong className="text-bull-text">one caveat while the curve is filling,</strong>{' '}
            and it is the honest one: ${TICKER} cannot be bought yet, so that 20% cannot be spent
            yet either. it waits in a holding bucket on the mint contract until there is a real
            pool, and money in that bucket has not reached a pot, so the dev can pull it out to
            place the buy by hand. that is the one step in the money path where you are trusting
            a person rather than the code. the 10% bnb leg has no such gap: it lands in the bnb
            pot on the first mint, and once anything is in a pot it is in for good.
          </p>
          <p>
            every bull rolls its own hide, horns, eyes, weapon and gear. rarity is fixed at
            deploy and hash-committed on chain, so nobody, us included, can move a bull between
            tiers after the fact. dev mints take their chances on the same table as everyone
            else&apos;s.
          </p>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full min-w-[520px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                <th className="py-2 pr-4">tier</th>
                <th className="py-2 pr-4">grade</th>
                <th className="py-2 pr-4">count</th>
                <th className="py-2 pr-4">what it reads as</th>
              </tr>
            </thead>
            <tbody>
              {BANDS.map((band) => (
                <tr key={band} className="border-b border-bull-border/60">
                  <td className={`py-2 pr-4 font-semibold ${TIER_COLOUR[band]}`}>{band}</td>
                  <td className="py-2 pr-4 text-bull-text">{TIER_FLAVOUR[band].grade}</td>
                  <td className="py-2 pr-4 font-mono">{BAND_COUNTS[band]}</td>
                  <td className="py-2 pr-4 text-bull-text-dim">
                    {BAND_INFO[band].family} hide · {TIER_FLAVOUR[band].line}
                  </td>
                </tr>
              ))}
              <tr>
                <td className="py-2 pr-4 font-semibold text-bull-gold">king (1/1)</td>
                <td className="py-2 pr-4 text-bull-gold">{KING_FLAVOUR.grade}</td>
                <td className="py-2 pr-4 font-mono">1</td>
                <td className="py-2 pr-4 text-bull-text-dim">
                  {KING_NAME.toLowerCase()} · {KING_FLAVOUR.line}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="text-sm text-bull-text-faint">
          three tells escalate together and are readable across a room: the hide family, the horn
          colour, and whether it has boots. the top two tiers also get a cape, which is the only
          tell that changes the silhouette, so it survives being shrunk to a thumbnail.
        </p>
      </section>

      {/* ── fighting ─────────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">fighting</h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p>
            both sides put up the same dollar sticker and the winner takes{' '}
            <strong className="text-bull-text">90%</strong>. of the 10% that does not go to the
            winner, <strong className="text-bull-text">3% goes straight into a pot</strong> and the
            rest is the protocol cut. a tie refunds each side its own money less the same cut, so
            nobody ends a draw holding a token they never chose.
          </p>
          <p>
            <strong className="text-bull-text">
              the currency you pay in decides which pot fattens.
            </strong>{' '}
            a bnb fight feeds the bnb pot, a {TICKER.toLowerCase()} fight feeds the{' '}
            {TICKER.toLowerCase()} pot, and a fight where the two sides picked differently drops a
            bit in each. nothing is sold, swapped or converted on the way in.
          </p>
          <p>
            the fight itself is simulated off chain from a public random seed and the result is
            signed. the contract checks the signature; it never re-runs the fight. because the
            seed is public, anyone can re-run it and catch a lying signer, and the replay endpoint
            does exactly that before it will draw you a gif.
          </p>
          <p>
            a wallet cannot fight itself, and that is enforced on chain at settlement rather than
            only checked in the browser. each wallet also carries exactly one signed fight in
            flight at a time.
          </p>
        </div>

        {/* ── where the money goes ──────────────────────────────────
            Three fights, same rules, every figure derived from the
            contract parameters at the top of this file. The point is that
            a reader can add the columns up themselves. */}
        <div className="space-y-4 border-t border-bull-border pt-5">
          <h3 className="bull-header text-lg text-bull-text">where the money goes, to the cent</h3>
          <p className="text-sm leading-relaxed text-bull-text-dim md:text-base">
            three fights at a {usd(EXAMPLE_STICKER)} sticker a side. the shape never changes: 90%
            of the money in the middle to the winner, 3% into a pot, the rest is the protocol cut.
            what changes is how big the purse is and which pot fattens.
          </p>

          <div className="overflow-x-auto">
            <table className="w-full min-w-[600px] border-collapse text-sm">
              <thead>
                <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                  <th className="py-2 pr-4 font-normal" scope="col">
                    <span className="sr-only">line</span>
                  </th>
                  {FIGHTS.map((f) => (
                    <th key={f.key} className="py-2 pr-4" scope="col">
                      {f.title}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                <tr className="border-b border-bull-border/60">
                  <th scope="row" className="py-2 pr-4 text-left font-normal text-bull-text-dim">
                    each side puts in
                  </th>
                  {FIGHTS.map((f) => (
                    <td key={f.key} className="py-2 pr-4 font-mono text-bull-text">
                      {isMixed(f)
                        ? `${usd(f.sides[0].paid)} bnb + ${usd(f.sides[1].paid)} bnbull`
                        : `${usd(f.sides[0].paid)} + ${usd(f.sides[1].paid)}`}
                    </td>
                  ))}
                </tr>
                <tr className="border-b border-bull-border/60">
                  <th scope="row" className="py-2 pr-4 text-left font-normal text-bull-text-dim">
                    money in the middle
                  </th>
                  {FIGHTS.map((f) => (
                    <td key={f.key} className="py-2 pr-4 font-mono text-bull-text">
                      {usd(total(f, (s) => s.paid))}
                    </td>
                  ))}
                </tr>
                <tr className="border-b border-bull-border/60 bg-bull-panel/40">
                  <th scope="row" className="py-2 pr-4 text-left font-semibold text-bull-text">
                    winner takes
                  </th>
                  {FIGHTS.map((f) => (
                    <td key={f.key} className="py-2 pr-4 font-mono font-semibold text-bull-gold">
                      {isMixed(f) ? (
                        <>
                          {usd(f.sides[0].toWinner)} bnb + {usd(f.sides[1].toWinner)} bnbull
                          <span className="block font-normal text-bull-text-faint">
                            · {usd(total(f, (s) => s.toWinner))} all up
                          </span>
                        </>
                      ) : (
                        usd(total(f, (s) => s.toWinner))
                      )}
                    </td>
                  ))}
                </tr>
                <tr className="border-b border-bull-border/60">
                  <th scope="row" className="py-2 pr-4 text-left font-normal text-bull-text-dim">
                    {POTS.bnbull.label}
                  </th>
                  {FIGHTS.map((f) => {
                    const v = legTotal(f, 'bnbull', (s) => s.toPot);
                    return (
                      <td key={f.key} className="py-2 pr-4 font-mono text-bull-text">
                        {v === 0 ? <span className="text-bull-text-faint">nothing</span> : usd(v)}
                      </td>
                    );
                  })}
                </tr>
                <tr className="border-b border-bull-border/60">
                  <th scope="row" className="py-2 pr-4 text-left font-normal text-bull-text-dim">
                    {POTS.bnb.label}
                  </th>
                  {FIGHTS.map((f) => {
                    const v = legTotal(f, 'bnb', (s) => s.toPot);
                    return (
                      <td key={f.key} className="py-2 pr-4 font-mono text-bull-text">
                        {v === 0 ? <span className="text-bull-text-faint">nothing</span> : usd(v)}
                      </td>
                    );
                  })}
                </tr>
                <tr className="border-b border-bull-border/60">
                  <th scope="row" className="py-2 pr-4 text-left font-normal text-bull-text-dim">
                    protocol cut
                  </th>
                  {FIGHTS.map((f) => (
                    <td key={f.key} className="py-2 pr-4 font-mono text-bull-text-dim">
                      {usd(total(f, (s) => s.toDev))}
                    </td>
                  ))}
                </tr>
                <tr className="border-t-2 border-bull-border">
                  <th scope="row" className="py-2 pr-4 text-left font-normal text-bull-text-dim">
                    adds back up to
                  </th>
                  {FIGHTS.map((f) => (
                    <td key={f.key} className="py-2 pr-4 font-mono text-bull-text">
                      {usd(
                        total(f, (s) => s.toWinner) +
                          total(f, (s) => s.toPot) +
                          total(f, (s) => s.toDev),
                      )}
                    </td>
                  ))}
                </tr>
              </tbody>
            </table>
          </div>

          <ul className="max-w-3xl list-none space-y-3 pl-0 text-sm leading-relaxed text-bull-text-dim md:text-base">
            {BNBULL_DISCOUNT_BPS > 0 ? (
              <li>
                <strong className="text-bull-text">
                  {TICKER.toLowerCase()} is the only leg that gets a discount on a fight,
                </strong>{' '}
                so a {usd(EXAMPLE_STICKER)} sticker is {usd(FIGHTS[0].sides[0].paid)} in{' '}
                {TICKER.toLowerCase()}. that discounted number is the money that actually goes in
                the middle, so the purse is smaller and so is the winner&apos;s take. it is a
                cheaper fight, not a bigger prize for less.
              </li>
            ) : (
              <li>
                <strong className="text-bull-text">a fight costs the same either way.</strong> a{' '}
                {usd(EXAMPLE_STICKER)} sticker is {usd(EXAMPLE_STICKER)} of bnb or{' '}
                {usd(EXAMPLE_STICKER)} of {TICKER.toLowerCase()}, and that is deliberate: a fight
                is a bet between two players, so discounting one side&apos;s entry would have the
                two of them put different money into the same purse. each side is settled in its
                own asset, so the gap would not average out, it would land in the winner&apos;s
                payout. the {TICKER.toLowerCase()} discount belongs to minting.
              </li>
            )}
            <li>
              <strong className="text-bull-text">
                a fight between two different currencies settles in both.
              </strong>{' '}
              each side is charged in the one it picked, and the winner is paid out in both:{' '}
              {usd(FIGHTS[2].sides[0].toWinner)} of bnb and {usd(FIGHTS[2].sides[1].toWinner)} of{' '}
              {TICKER.toLowerCase()}. nothing is converted, so nobody walks off holding a token
              they never chose, and neither does the loser.
            </li>
            <li>
              <strong className="text-bull-text">the 3% is not split between the pots.</strong> it
              goes whole into the pot named by the currency that paid it, as that currency. a bnb
              fight never buys {TICKER.toLowerCase()} and a {TICKER.toLowerCase()} fight is never
              sold for bnb.
            </li>
            <li>
              <strong className="text-bull-text">two of these three cannot happen yet.</strong>{' '}
              {TICKER.toLowerCase()} cannot be moved by anyone until the four.meme curve fills, so
              at launch every fight is the middle column. the other two switch on when the token
              does{BNBULL_DISCOUNT_BPS > 0 ? ', discount included' : ''}.
            </li>
            <li className="text-bull-text-faint">
              {usd(EXAMPLE_STICKER)} is a round number to keep the arithmetic easy to follow. the
              real sticker is set on the contract, converted to bnb at pay time off the chainlink
              feed, and the{' '}
              <Link href="/duel" className="text-bull-gold hover:underline">
                duel page
              </Link>{' '}
              reads it live rather than this page repeating it.
            </li>
          </ul>
        </div>
      </section>

      {/* ── the pots ─────────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">the two pots</h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p>
            two pots hang over every fight. the{' '}
            <strong className="text-bull-text">{POTS.bnbull.label}</strong> rolls at{' '}
            {POTS.bnbull.odds}; the <strong className="text-bull-text">{POTS.bnb.label}</strong>{' '}
            rolls at {POTS.bnb.odds}. {POTS.rule}
          </p>
          <p>
            winning is the only way in. there is no entry fee and nothing to claim: the tokens
            just appear. the roll settles a moment AFTER the fight, so you cannot grind by
            throwing away losing results.
          </p>
          <p className="rounded border border-bull-gold/30 bg-bull-panel p-4 text-bull-text">
            {POTS.trust}
          </p>
          <p>
            a fight has to actually fund the pot to earn a ticket. zero-money fights settle, move
            the streaks and record the win, they just do not buy a lottery ticket that everyone
            else paid for.{' '}
            <Link href="/pots" className="text-bull-gold hover:underline">
              see both pots live
            </Link>
            .
          </p>
        </div>
      </section>

      {/* ── the butcher ──────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">
          {DEATH.label} · permadeath
        </h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p>{DEATH.rule}</p>
          <p className="text-bull-text">{DEATH.rescue}</p>
          <p>
            there are two ways off the truck. the holder gets a head start on a ladder that costs
            more every time; once that head start expires, anyone else can pay the dearer takeover
            ladder and bring the bull back{' '}
            <strong className="text-bull-text">into their own wallet</strong>. both ladders are
            {/* ⚠ NO ARTICLE — `DEATH.label` is "the butcher", so "on the
                {DEATH.label} page" rendered "on the the butcher page". */}
            dollar-denominated and read live off the contract on{' '}
            <Link href="/graveyard" className="text-bull-gold hover:underline">
              {DEATH.label} page
            </Link>
            .
          </p>
          <p>
            there is a lifetime cap on revives, and after that the next death is forever. the
            count travels with the nft, so check the rung before you bid on somebody else&apos;s
            bull.
          </p>
          <p className="text-bull-text">
            the dev cannot revive his own bull for free either. there is no free revive in the
            bytecode for anyone.
          </p>
        </div>
      </section>

      {/* ── marketplace ──────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">the marketplace</h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p>
            standard erc-721, approval based rather than escrow, so{' '}
            <strong className="text-bull-text">the nft stays in your wallet the whole time</strong>
            . listed bulls are locked out of fights, because nobody should have a fighter sold out
            from under them mid-match.
          </p>
          <p>
            the fee is <strong className="text-bull-text">7.5%</strong>: 2.5% market-buys ${TICKER}{' '}
            into the {TICKER} pot, 5% is the protocol fee. the seller always receives the sale
            price less that whole fee, and the cap on the fee is enforced in the contract, not by
            a promise.
          </p>
          <p>
            the dead flag, the loss streak and the revive rung all travel with the token. a cheap
            bull is sometimes cheap for a reason.
          </p>
        </div>
      </section>

      {/* ── $BNBULL ──────────────────────────────────────────────── */}
      <section id="bnbull" className="scroll-mt-32 space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">${TICKER}</h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p className="rounded border border-bull-gold/40 bg-bull-panel p-4 text-bull-text">
            <strong className="bull-header text-bull-gold">not tradeable yet.</strong>{' '}
            {CURRENCY.bnbullPending}
          </p>
          <p>
            ${TICKER} launches on a fair-launch bonding curve. no presale, no team allocation, no
            vc. while the curve is filling, the token literally cannot be transferred by anyone,
            which is the pad&apos;s rule and not ours, so the whole game prices and settles in{' '}
            <strong className="text-bull-text">bnb</strong> until it fills.
          </p>
          <p>
            once it does, ${TICKER} becomes a second way to pay for everything, and it is{' '}
            <strong className="text-bull-text">the only leg that carries a discount on minting</strong>.
            fights are the same price either way: a $2 duel costs $2 in bnb or $2 in ${TICKER}, because
            both fighters should put the same money into the same purse. the buy pressure the pots
            create switches on at the same moment.
          </p>
          <p className="text-bull-text-faint">
            when there is a real address and a real pool, they will be posted here and on this
            site&apos;s socials, and nowhere else. no price predictions, no guarantees, and
            nothing is risk-free.
          </p>
        </div>
      </section>

      {/* ── the roadmap ──────────────────────────────────────────────
          ⚠ TWO PHASES ARE DECIDED AND THE THIRD IS NOT, AND THAT IS WHAT THIS
          SECTION SAYS. Owner asked for the phases on this page; the honest
          answer is that `DECISIONS.md` defines exactly two.

          Phase 1 is `§29`: BNB-only at launch, every BNBULL leg present in the
          contracts and switched off until four.meme's curve fills (`§28.1`).
          Phase 2 is `§24`: calves, with batch mint as a HARD design constraint
          on phase 1 rather than a phase 2 feature, plus `§35`/`§36`'s breeding
          lore, which is why it needs no stretching to fit.

          ⚠ THERE IS NO PHASE 3. The only "phase 3" in the repo is a note in
          `VOICE-AND-BRAND.md §5` to write the OpenSea contractURI / royalty /
          listing runbook when we actually run it. That is an ops task, not a
          product phase, and printing it as one on the page a sceptic reads
          first would be inventing a promise. The third block below says
          nothing is locked, because nothing is.

          ⚠ NO DATES ANYWHERE (`VOICE-AND-BRAND.md §1`). Not a month, not a
          quarter, not "soon-ish". "when it is ready" or nothing. */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">what happens when</h2>
        <p className="text-sm leading-relaxed text-bull-text-dim md:text-base">
          two phases are decided. anything past them is not, and this page is not going to
          pretend otherwise. there are no dates on any of it, and there will not be: it ships
          when it is done.
        </p>

        <div className="space-y-4">
          <Phase tag="up first" title="phase 1 · the drop, the fights, the pots">
            <p>
              {SUPPLY} bulls plus {KING_NAME.toLowerCase()}, duels with real money in the middle,
              the two pots, {DEATH.label} and the revive ladder, and the marketplace. everything
              on the rest of this page is phase 1.
            </p>
            <p>
              it launches <strong className="text-bull-text">in bnb</strong>. ${TICKER} goes up
              on a fair-launch curve and the pad holds it locked until that curve fills, so
              nobody can pay in it before then, us included. every {TICKER.toLowerCase()} leg is
              already written into the contracts and switched off, and they come on when the
              token does.
            </p>
          </Phase>

          <Phase tag="after that" title="phase 2 · calves">
            {/* ⚠ WHAT `§24` ACTUALLY LOCKS IS THE BATCH MINT, and that is the
                only thing stated as settled. "calves, bred out of the herd" is
                `§35`/`§36`'s direction and is worded as direction. An earlier
                draft called them "the second collection", which nothing in
                DECISIONS says. */}
            <p>
              calves. baby bulls, bred out of the herd you already have. the one rule already
              locked is that <strong className="text-bull-text">they mint in batches</strong>,
              however many you want in one go.
            </p>
            <p>
              that is a constraint on phase 1, not a phase 2 feature, which is why it is written
              down this early. hatching one egg at a time was the most annoying thing about the
              last game and it changes the pricing read, the never-fail routing and the per
              wallet guards, so it gets designed in now rather than retrofitted later.
            </p>
          </Phase>

          <Phase tag="not locked" title="past that">
            <p>
              nothing is decided, so nothing is claimed. no third phase has been signed off and
              you are not going to find one invented on this page to fill the gap.
            </p>
            <p className="text-bull-text-faint">
              when something is locked it lands in the public decisions log first and on this
              page second, the same way these two did.
            </p>
          </Phase>
        </div>
      </section>

      {/* ── trust ────────────────────────────────────────────────── */}
      <section className="space-y-4">
        <h2 className="bull-header text-xl text-bull-gold md:text-2xl">trust, and the limits</h2>
        <div className="space-y-3 text-sm leading-relaxed text-bull-text-dim md:text-base">
          <p className="text-bull-text">
            one person builds this. that is the charm and it is also the limit.
          </p>
          {/* ⚠ "a timelock on every address that could move money" WAS TOO
              BROAD, and it was too broad in the one paragraph that exists to be
              checked. What is timelocked is the WIRES — the slots holding the
              addresses of the other contracts (`TimelockedAddress.Slot`): the
              pots, the price feed, the swap router, the graveyard, the duel,
              the jackpot sink, and the VRF coordinator after `§18`. Plenty of
              plain owner setters have no delay at all, and they are listed
              under "risks" below by name. Both halves are true as written now,
              and the true version is still a strong claim. */}
          <p>
            <strong className="text-bull-text">enforced by the contracts:</strong> the rarity
            pre-commit, the no-withdraw pots, a capped protocol cut on fights, a capped
            marketplace fee, the lifetime revive cap, signed fight results, the listing lockout,
            and a timelock on the wires between the contracts, so the pots, the price feed, the
            swap route and the duel itself cannot be repointed without a public delay first.
          </p>
          <p>
            <strong className="text-bull-text">risks, said plainly:</strong> it is a solo build
            with no paid audit. it is tested, heavily, but tested is not audited. smart contracts
            can have bugs. do not put in money you need back.
          </p>
          <p>
            <strong className="text-bull-text">what has no timelock, by name:</strong> the two
            treasury addresses (<code className="font-mono text-xs">Duel.setDevTreasury</code>,{' '}
            <code className="font-mono text-xs">Marketplace.setFeeTreasury</code>), the fight
            signer (<code className="font-mono text-xs">Duel.setTrustedSigner</code>), the keeper
            {/* ⚠ NO ARTICLE BEFORE `DEATH.label` — it already carries one
                ("the butcher"), and the literal "the" in front of it rendered
                "the the butcher" on the live page. */}{' '}
            addresses on the mint and {DEATH.label} contracts, the stray-token rescues, and
            the sweeps for the leftover liquidity slice. those change the moment the owner sends
            the transaction. some of them have to: a leaked signing key has to be revocable in
            one transaction rather than in a day. none of them can reach a pot, and the rescues
            cannot touch money already earmarked for one. it is still owner power without a
            waiting period, and you should price that in.
          </p>
          <p>
            <strong className="text-bull-text">the safety rule:</strong> this site is the only
            place a real contract address gets posted. nobody dms first, and nobody will ever ask
            for your seed phrase.
          </p>
        </div>
        <div>
          <p className="bull-header mb-3 text-xs uppercase tracking-[0.2em] text-bull-text-faint">
            live contract status
          </p>
          <ContractStatus />
        </div>
      </section>
    </div>
  );
}

/** One roadmap block. The tag is a status word, never a date. */
function Phase({
  tag,
  title,
  children,
}: {
  tag: string;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded border border-bull-border bg-bull-panel p-4 md:p-5">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="bull-header text-base text-bull-text md:text-lg">{title}</h3>
        <span className="rounded-full border border-bull-gold/50 px-2 py-0.5 font-mono text-[10px] uppercase tracking-wide text-bull-gold">
          {tag}
        </span>
      </div>
      <div className="mt-3 space-y-2 text-sm leading-relaxed text-bull-text-dim md:text-base">
        {children}
      </div>
    </div>
  );
}

function Step({ n, children }: { n: number; children: React.ReactNode }) {
  return (
    <li className="flex gap-3">
      <span className="bull-header mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-bull-gold/50 text-xs text-bull-gold">
        {n}
      </span>
      <span className="leading-relaxed">{children}</span>
    </li>
  );
}
