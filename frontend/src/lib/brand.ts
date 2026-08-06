/**
 * brand.ts — EVERY player-facing lore string, in one file.
 *
 * ⚠ WHY THIS FILE EXISTS. `DECISIONS.md §17` says the lore is NOT settled, and
 * `§35` says the beef-grade direction is a SKETCH. So the theme has to be a
 * reskin, not a rebuild: change the words here and the whole site changes with
 * them. Nothing below may be duplicated into a component. If you find yourself
 * typing a lore word in a `.tsx` file, it belongs here instead.
 *
 * The palette lives in the other half of the same idea: CSS custom properties
 * on `:root` in `globals.css`, surfaced to Tailwind as `bull-*` colours.
 * Between the two, a rebrand is one file and one `:root` block.
 *
 * VOICE (`VOICE-AND-BRAND.md §1`, binding, do not soften):
 *   - lowercase, casual, australian english. headings included.
 *   - NO em-dashes, ever. the sanctioned separator is the mid-dot `·`.
 *   - no AI-speak: leverage / unlock / explore / elevate / seamless / robust /
 *     ecosystem / journey / immersive.
 *   - banned in player copy: "stake" (say "money in the middle", "back your
 *     bull"), "fully pvp", "win both pots" (a fight rolls exactly ONE).
 *   - confident and funny, never crude. this page gets screenshot.
 */

// ─── the mark ────────────────────────────────────────────────────────

/**
 * ⚠ CASE IS DELIBERATE: `BNBulls`, not `bnbulls`. Owner call, 2026-08-06.
 * This is the ONE documented exception to VOICE-AND-BRAND §1's lowercase rule
 * — a wordmark is a mark, not a sentence, and every other heading, label and
 * line on the site stays lowercase.
 *
 * For STYLED display use `<Wordmark />`, which puts BNB Chain's gold on exactly
 * the letters `BNB`. This string is for places that can only take plain text:
 * aria-labels, <title>, meta tags, alt text.
 */
export const SITE_NAME = 'BNBulls';

/**
 * ⚠⚠ THE LANDING PAGE IS THIS LINE AND LORD WAGYU. NOTHING ELSE. ⚠⚠
 *
 * Owner call, verbatim: "that is lord wagyu up there. one of one, token 501.
 * the other 500 fight for the pots. **remove this from the front page**, just
 * leave [the line below]."
 *
 * So the front page carries the picture and one sentence. Do NOT put a
 * subtitle, an explainer, a stat line, a "what is this" paragraph or a CTA
 * under it. `VOICE-AND-BRAND.md §1`: "never explain the joke, the sentence
 * after a punchline kills it." That rule is now literally the layout.
 *
 * The facts that came off the front (1-of-1, token 501, what the other 500 do)
 * are still true and still on the site: `/about` and `/bull/501` carry them.
 * They are just not the first thing anybody reads.
 *
 * Lowercase exactly as written.
 */
export const HERO_LINE =
  'build a herd, send them into the yards, keep them off the truck or they face the chop';

/** For <title> and link previews ONLY. Never rendered on the landing page. */
export const TAGLINE = 'pixel bull pvp on bnb chain. real money in the middle.';

/** The one-liner that goes in <meta description>, the footer, and the og card.
 *  Kept to one sentence on purpose. */
export const DESCRIPTION =
  'bnbulls: mint a bull, fight for real money, and every mint fattens two pots ' +
  'nobody can withdraw from. permadeath pixel pvp on bnb chain. 🐂⚔️';

// ─── emoji (VOICE-AND-BRAND §3) · never stacked ──────────────────────

export const EMOJI = {
  bull: '🐂',
  duel: '⚔️',
  death: '💀',
  pot: '💰',
  shield: '🛡️',
} as const;

// ─── the beef-grade ladder (DECISIONS.md §35) ────────────────────────
//
// The rarity ladder IS a beef-grade ladder, and it terminates on wagyu,
// because `§9` locked the king as Lord Wagyu before this lore existed. Grade
// and tier agree for free.

export interface TierFlavour {
  /** The beef grade. Flavour only — `tier` is the canonical on-chain trait. */
  readonly grade: string;
  /** One line, read across a room. */
  readonly line: string;
}

export const TIER_FLAVOUR: Record<
  'common' | 'uncommon' | 'rare' | 'epic' | 'legendary',
  TierFlavour
> = {
  common: { grade: 'grain fed', line: 'cheap feed, cheap attitude. still turns up.' },
  uncommon: { grade: 'grass fed', line: 'real paddock, real muscle. knows it, too.' },
  rare: { grade: 'prime', line: 'the butcher would fight you for one of these.' },
  epic: { grade: 'dry aged', line: 'black hide, cold steel, no manners.' },
  legendary: { grade: 'top grade', line: 'bnb gold, and he is not humble about it.' },
};

export const KING_FLAVOUR: TierFlavour = {
  grade: 'wagyu',
  line: 'one of one. the top of the grade, and the only bull with a title.',
};

// ─── death · THE BUTCHER (DECISIONS.md §35, CONFIRMED by the owner) ──
//
// This axis of the lore is SETTLED, not a sketch. Owner: "love the butcher and
// saving it from the butcher lore, good work, focus on that for when marketing
// is created."
//
// The two images that carry it, and the ONLY ones the UI may use for death:
//   1. the back of the truck, on the way to the butcher
//   2. buying your bull back OFF that truck
//
// ⚠ DO NOT INVENT A COMPETING DEATH METAPHOR ANYWHERE ELSE IN THE UI. No
// crypts, no tombstones, no "rest in peace". The owner has named the truck as
// meme and animation material, and a second metaphor somewhere in a panel is
// what makes a brand look like it was written by three different people.
//
// ⚠ SAVING A BULL IS THE EMOTIONAL CORE, not a fee schedule. The revive copy
// leans on the rescue, not on the transaction.
//
// ⚠ THE ROUTE STAYS `/graveyard`. It matches the contract, urls get shared,
// and a 404 is worse than a label that does not match the path. Same precedent
// fefers set with "Marketplace" living at `/market`.

export const DEATH = {
  /** Nav + page label. */
  label: 'the butcher',
  /** Page h1. */
  heading: 'five straight losses and it is the chop',
  /** The rule, in one sentence. The real `lossesToDie` is read off chain
   *  wherever a number is available; this is the copy around it. */
  rule:
    'lose five on the trot, no win and no tie in between, and your bull is on the back ' +
    'of the truck. a win or a tie resets the count.',
  /** The rescue. THE line, per the owner. */
  rescue: 'you can buy him back off the truck. it costs more every time.',
  /** The philosophy line. Ported from fefers, rethemed. */
  philosophy:
    'a bull that can always come back is a subscription. a bull on its last life is a ' +
    'decision every time you send it in.',
  /** Empty state when nothing has died. */
  empty: 'the truck is empty. quiet week at the butcher.',
  /** Out of revives. */
  gone: 'out of lives. this one is mince.',
  /** The list of the dead. */
  listHeading: 'on the truck',
  listLoading: 'checking the yard…',
} as const;

// ─── the two pots ────────────────────────────────────────────────────

/**
 * ⚠ `symbolFallback` IS A FALLBACK FOR AN UNREAD CHAIN, NOT THE TRUTH.
 *
 * The pot components read `prizeToken()` and then BOTH of that token's own
 * facts off it — `decimals()` for the number and `symbol()` for the ticker
 * beside it. The ticker used to come from this literal instead, so a pot whose
 * prize token was not what we assumed rendered the right amount with the wrong
 * ticker. `duel-bot.mjs` is the one place in the codebase that always got this
 * right; now everything does.
 *
 * The live read wins wherever a token is wired. These strings are reached only
 * once that read has SETTLED with no answer, and never while it is still in
 * flight — a ticker guessed during loading is the same bug in slow motion. See
 * `tickerToPrint` in `useTokenDecimals.ts` for the one rule all the surfaces
 * share.
 *
 * These values are correct as of `POT-ASSET-SWAP-DESIGN.md`, which establishes
 * that `Jackpot.prizeToken` is `immutable` and the BNB pot's prize is WBNB
 * permanently — so they cannot drift for THIS deployment. They can still be
 * wrong for a redeploy, a testnet run, or a mock, which is exactly when a
 * hardcoded ticker is most misleading.
 */
export const POTS = {
  bnbull: { label: '$BNBULL pot', symbolFallback: 'BNBULL', odds: '1-in-50' },
  bnb: { label: 'BNB pot', symbolFallback: 'WBNB', odds: '1-in-100' },
  /** The trust story. This IS the brand (`VOICE-AND-BRAND.md §4`). */
  trust:
    'neither pot has a withdraw function. not for a player, not for us. the only way ' +
    'money has ever left either pool is a logged, on-chain win. that is not a promise, ' +
    'it is the bytecode.',
  /** ⚠ BANNED: "win both pots". A fight rolls exactly ONE. */
  rule:
    'every decisive fight opens a ticket on both pools at their own odds, and the first ' +
    'to roll a win claims it. one fight never pays both.',
  empty: 'no wins yet. the pots are still fattening.',
} as const;

// ─── currency (DECISIONS.md §26 + §29) ───────────────────────────────
//
// ⚠ TWO CURRENCIES. BNB and BNBULL. There is no stablecoin anywhere in this
// product any more, and the word must not appear in the UI.
//
// ⚠ BNBULL IS NOT USABLE AT LAUNCH. four.meme's curve holds the token in a
// transfer-locked custodial phase (`§28.1`), so every BNBULL leg reads "not
// available yet" rather than erroring. This is the NORMAL launch state.

export const TICKER = 'BNBULL';

export const CURRENCY = {
  bnb: { label: 'bnb', symbol: 'BNB' },
  bnbull: { label: 'bnbull', symbol: 'BNBULL' },
  /** Why the BNBULL leg is dark at launch. Shown on every currency picker. */
  bnbullPending:
    '$BNBULL is not tradeable until the four.meme curve fills. the token cannot be ' +
    'moved at all before then, so every bnbull leg is switched off rather than ' +
    'quietly failing. bnb works today.',
  /** The discount, once BNBULL is live (`§2`). */
  discount: 'bnbull is the only leg that ever carries a discount.',
} as const;

// ─── the deal ────────────────────────────────────────────────────────
//
// ⚠ NOT ON THE LANDING PAGE ANY MORE. It used to sit under the hero, the way
// fefers stacks it, and the owner cut it: the front page is the picture and
// `HERO_LINE`, full stop. This copy now lives on `/about`, which is where
// somebody who wants the detail goes.

export const DEAL = {
  eyebrow: 'the deal',
  body:
    'every mint and every revive feeds two pots: 20% buys $BNBULL, 10% goes to BNB. ' +
    'neither pot has a withdraw function, for anybody. winners only.',
} as const;

// ─── safety refrain (VOICE-AND-BRAND §4, on every page footer) ───────

export const SAFETY =
  'this site is the only place a real contract address gets posted. nobody dms first, ' +
  'and nobody will ever ask for your seed phrase.';

// ─── nav (IA ported from fighting fefers) ────────────────────────────

export interface NavEntry {
  readonly href: string;
  readonly label: string;
  /** Renders as the gold "bazinga" CTA (`VOICE-AND-BRAND.md §5`). */
  readonly cta?: boolean;
  /** Opens in a new tab via a plain <a>. */
  readonly external?: boolean;
}

/**
 * ⚠ ROUTES ARE URLS, LABELS ARE COPY. Rename the label freely; the route is a
 * shared, linkable thing. `/bulls` is labelled "browse", `/graveyard` is
 * labelled by `DEATH.label`, exactly the way fefers labels `/market`
 * "Marketplace".
 */
export const NAV: readonly NavEntry[] = [
  { href: '/mint', label: 'mint' },
  { href: '/duel', label: 'duel' },
  { href: '/graveyard', label: DEATH.label },
  { href: '/market', label: 'marketplace' },
  { href: '/pots', label: 'pots' },
  { href: '/bulls', label: 'browse' },
  { href: '/about', label: 'how to play' },
  { href: '/about#bnbull', label: `buy $${TICKER}`, cta: true },
];
