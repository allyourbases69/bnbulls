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
 *  Kept to one sentence on purpose.
 *
 *  ⚠ NO "nobody can withdraw from". That was the retired trust-story pitch and
 *  it survived here, in the footer of every page, after the owner ordered the
 *  angle dead (2026-08-07: "drop all the crap about nobody can withdraw from
 *  it"). Sell the climb: the pots stack until somebody rolls the number. */
export const DESCRIPTION =
  'bnbulls: mint a bull, fight for real money, and every fight rolls two jackpots ' +
  'that stack until somebody hits. permadeath pixel pvp on bnb chain. 🐂⚔️';

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

// ─── the arena · THE BULL PIT (owner call, 2026-08-07) ───────────────
//
// Owner, verbatim: "OMG that is what the fighting area can be renamed to — the
// bull pit, why didn't we think of that."
//
// ⚠ THIS IS A LABEL, AND ONLY A LABEL. The contract is `contracts/Yards.sol`,
// it is DEPLOYED, and its whole surface is chain-facing and unrenameable:
// `enter` / `eject` / `inYards` / `inYardsMany` / `statusOf` / `fightBlocked`,
// the `EnteredYards` and `LeavingYards` events, `Duel.Wire.Yards` and the
// `BullNotInYards` revert. Nothing under `contracts/`, `script/`, `test/` or
// `lib/abi/` may be renamed to match this word, and the ABI is generated from
// the forge artefact so it could not be anyway. The site already runs this
// split: `/graveyard` is labelled "the butcher".
//
// ⚠ THE ROUTE STAYS `/duel`. Urls get shared and a 404 is worse than a label
// that does not match a path — the same call `DEATH` records above.
//
// ⚠ ONE STRING IS DELIBERATELY LEFT SAYING "the yards": `HERO_LINE`. It is the
// owner's own landing sentence, `DECISIONS.md §36` locks it, and `Yards.sol`'s
// header quotes it as the reason the contract is called what it is. Changing an
// owner-verbatim line is his call, not a sweep's. It is ONE word here if he
// wants it.
//
// ⚠ "IN THE PIT" NOW MEANS SOMETHING EXACT, SO DO NOT REUSE IT FOR "ALIVE".
// Several filters used to be labelled "in the yards" when what they actually
// counted was bulls that are not dead. That was harmless while nothing read the
// roster; it is a lie now, because an alive bull that was never entered is NOT
// in the pit and cannot be fought. Those labels moved to `DEATH.standing`.

export const PIT = {
  /** Nav, page label, and anywhere the arena is named. */
  label: 'the bull pit',
  /** Page eyebrow. */
  eyebrow: '⚔️ the bull pit',
  /** A second mention in the same paragraph, where the full name drags. */
  short: 'the pit',
  /** Page h1 sits under the eyebrow. */
  heading: 'the bull pit',
  /** The one line under the h1. */
  lead: 'pick your bull and hit fight. we find you an opponent on rating.',

  // ── membership ─────────────────────────────────────────────────────

  /** THE RULE. `Duel.submitDuel` reverts `BullNotInYards` on a bull that is
   *  out, staked fight or free one, so this is not a soft gate. */
  rule:
    'a bull only fights while you have it in the pit. one that is out cannot be picked, cannot ' +
    'be matched, and cannot be fought by anybody.',
  /** The default is OUT, for a fresh mint too (`Yards.sol` header). */
  defaultOut:
    'nothing goes in by itself, a fresh mint included. a bull you have not sent in cannot be ' +
    'dragged into a fight you never agreed to.',
  /** Entry is instant, and batched. */
  enterInstant:
    'sending them in bites the moment the transaction lands, and one transaction covers as many ' +
    'as you tick.',
  enterCta: 'send into the pit',
  enterAllCta: 'send them all in',
  ejectCta: 'pull out of the pit',
  ejectAllCta: 'pull them all out',
  /** Per-bull status words. */
  inLabel: 'in the pit',
  outLabel: 'out of the pit',
  leavingLabel: 'leaving',

  // ── ⚠ THE DELAYED EJECT. DO NOT SOFTEN ANY OF THE NEXT FIVE STRINGS ──
  //
  // `Yards.eject` stamps `leavesAt = now + ejectDelay` and the bull STAYS
  // FIGHTABLE until that stamp passes (`inYardsFor`: `lv == 0 || now < lv`).
  // Rendering an ejected bull as instantly safe would be a lie the contract
  // contradicts, and it would be the expensive kind: somebody would eject to
  // duck a loss, watch it land anyway, and be right to be angry about what the
  // screen told them.
  //
  // The delay is not caution, it is the anti-dodge bound. A duel settles when
  // somebody submits a SIGNED result, BSC's mempool is public, so an instant
  // eject would let the losing side front-run the submission and make the loss
  // evaporate. `MIN_EJECT_DELAY` is pinned to `MAX_DUEL_EXPIRY_SECONDS`, the
  // ceiling on how long a fight signature may live, so by the time an eject
  // bites every signature that could name that bull has already expired. (The
  // source pins both at 300s; the deployed contract still carries the older,
  // longer floor until the redeploy lands — either way the bound holds, and
  // either way the number on screen is read off chain.)
  //
  // ⚠ NEVER HARDCODE THE MINUTES. `ejectDelay` is an owner-settable value
  // inside a bounded range. Read it off the contract; these strings are the
  // words around the number, never the number.

  /** Why the wait exists. Rendered next to the eject controls. */
  ejectDelayed:
    'pulling a bull out is not instant, and that is on purpose. the eject is stamped with a ' +
    'time and the bull keeps fighting until it passes.',
  ejectWhy:
    'a fight settles when somebody submits a signed result, and on bnb chain everyone can see ' +
    'that transaction coming. if eject were instant the losing side would yank their bull out ' +
    'from under a loss they can already see. the wait is never shorter than the longest a fight ' +
    'signature can live, so a loss that was already signed lands first and the bull leaves after.',
  /** THE COUNTDOWN STATE. What is still true while it runs. */
  ejectPending:
    'still in the pit until this hits zero. a fight signed before you hit eject can still land ' +
    'in that time, so this is not a way out of one.',
  /** ...and what is already true, which is the good half. */
  ejectImmediate:
    'nothing new can be matched against it from now, though. the matchmaker drops a bull the ' +
    'second an eject is stamped.',
  /** Verified against `Yards.enter`, which writes `leavesAt: 0` unconditionally
   *  and documents it: "Calling this on a bull that is already leaving CANCELS
   *  the eject… cancelling an eject can only ever make the bull MORE available,
   *  so it cannot duck anything." */
  reenterCancels:
    'changed your mind mid-countdown? send it back in and the departure is cancelled on the ' +
    'spot. entry never waits, because entering can only ever expose you to more fights.',

  // ── ⚠ THE ONE THAT HAS ALREADY BITTEN US IN TESTING ────────────────
  //
  // `Yards` stores `(enteredBy, leavesAt)` and membership requires `enteredBy
  // == the LIVE owner`, so a transfer takes a bull out for free with no ERC-721
  // hook. The flip side is that a BUYER gets a bull that looks fine and is
  // silently unfightable. Say so where a buyer will actually see it.
  saleVoidsEntry:
    'buying a bull does not put it in the pit. the pit remembers the wallet that sent a bull ' +
    'in, so the moment it changes hands that spot is void and the new owner has a bull nobody ' +
    'can fight until they send it in themselves. every sale, here or anywhere else.',

  // ── states ─────────────────────────────────────────────────────────

  /** Nothing of yours is in. */
  emptyMine: 'none of your herd is in the pit, so none of them can fight yet.',
  /** Wallet holds nothing at all. */
  emptyWallet: 'no living bulls in this wallet.',
  /** The whole pit is empty. */
  empty: 'the pit is empty. nobody has sent anything in yet.',
  quiet: 'nothing has been settled yet. the pit is quiet.',
  /** History, filtered to mine, with nothing in it. */
  noneOfMineFought: 'none of your bulls have been in the pit yet.',
  /** Leaders / anything ranked by fights. */
  onlyFought: 'only bulls that have stepped into the pit.',
  /** `<meta description>` for /leaders. */
  leadersDescription:
    'every bull that has stepped into the bull pit, ranked by rating. win against higher-rated ' +
    'bulls to climb faster.',
  /** The duel-picker dropdown instruction line. */
  pickerHint: 'tick to send a bull into the pit · click a name to make it the one that fights next',
  /** Post-mint. */
  mintCta: 'send into the pit',
  loading: 'checking who is in the pit…',
  /** The read failed. Never render "out of the pit" off a failed read — that is
   *  the same class of lie as rendering an ejected bull as safe. */
  unreadable:
    "couldn't read the pit off the chain just now, so nothing here claims to know who is in it.",
} as const;

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
  /**
   * THE OPPOSITE POLE, and it lives here because it is the same axis: this is
   * the label on every "not dead" filter and count, the pair to `listHeading`.
   *
   * ⚠ IT USED TO READ "in the yards" AND THAT IS NOW A LIE. `PIT` membership is
   * a real on-chain fact (`Yards.inYards`), and an alive bull nobody has
   * entered is emphatically not in it. A filter labelled with the arena's name
   * while it actually counts heartbeats would send a player to the duel page
   * with a herd the contract will not let fight.
   */
  standing: 'still standing',
  /** Nothing is alive. Pairs with `standing`. */
  noneStanding: 'nobody is still standing. every fighter on the board is on the truck.',
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
  /**
   * ⚠ THIS SLOT USED TO BE THE "no withdraw function" TRUST STORY. Owner,
   * 2026-08-07: "get rid of the withdraw function and the way it's all worded,
   * no need for trust story, just make hype jackpot or show how the pots grow."
   *
   * The fact has not changed and is not being hidden: the only way money leaves
   * either pool is a logged on-chain win, and `/about` still says so plainly
   * where a sceptic goes looking. It is simply not the PITCH. Players already
   * accept it, so spending the loudest line on it buys nothing and reads
   * defensive. Sell the climb instead.
   */
  grow:
    'both pots only ever go one way between wins. every mint, every scrap and every ' +
    'revive drops more in, and it sits there stacking until somebody rolls the number.',
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
  /**
   * The discount, once BNBULL is live (`§2`).
   *
   * ⚠ "ON A MINT" IS LOAD-BEARING, NOT PADDING. `DECISIONS.md §39` killed the
   * fight discount outright: a $2 duel costs $2 in either currency, because
   * discounting one side's entry would have the two fighters put different
   * money into the same purse and `_distributePot` settles each side in its
   * own asset, so the gap lands in the winner's payout. This string used to
   * read "the only leg that ever carries a discount", which is now false of
   * fighting. It is rendered on `/mint` only, and it says so.
   */
  discount: 'bnbull is the only leg that carries a discount on a mint.',
} as const;

// ─── the pre-launch state (DECISIONS.md §29) ─────────────────────────
//
// ⚠ THE PRE-LAUNCH STATE IS DELIBERATE AND HAS TO READ THAT WAY.
//
// Every panel on this site renders "not deployed yet" when its address is
// unset, which is honest — but a panel that says that because a READ FAILED
// looks exactly the same as one that means it. So the site states its position
// out loud instead of leaving a visitor to infer it from a wall of empty
// boxes: nothing is deployed, that is on purpose, here is what happens first,
// and here is what there is to do meanwhile.
//
// ⚠ THE FACT UNDERNEATH IS `§29` + `§28.1`, and neither is softened here.
// $BNBULL launches on four.meme's fair-launch curve. Pre-graduation four.meme
// holds the token transfer-locked in its own contract, so NOBODY can move it,
// us included — which is why the game prices and settles in BNB until the
// curve fills. That is the normal launch state, not an error state, and saying
// so is stronger than hiding it.
//
// ⚠ NO DATES, EVER (`VOICE-AND-BRAND.md §1`). "soon" or "when X is done".

export const PRELAUNCH = {
  heading: 'not open yet.',
  /** What is and is not deployed. The honest headline fact. */
  state:
    'nothing is deployed. no mint, no fights, no marketplace, no $BNBULL. every panel here ' +
    'that reads a contract is empty because there is no contract to read yet, not because ' +
    'something is broken.',
  /** What happens first. `DECISIONS.md §29`. */
  order:
    '$BNBULL goes up on four.meme first, fair-launch curve, no presale and no team ' +
    'allocation. the pad holds the token locked until that curve fills, so nobody can move ' +
    'it, us included. the game prices and settles in bnb until it does.',
  /** The one guarantee that is already true of this site. */
  addresses:
    'every address on this site is read from config and never invented, so a fake one can ' +
    'never turn up on a page here.',
  /** The lead-in to the link row. */
  meanwhile: 'in the meantime:',
} as const;

// ─── the deal ────────────────────────────────────────────────────────
//
// ⚠ NOT ON THE LANDING PAGE ANY MORE. It used to sit under the hero, the way
// fefers stacks it, and the owner cut it: the front page is the picture and
// `HERO_LINE`, full stop. This copy now lives on `/about`, which is where
// somebody who wants the detail goes.

export const DEAL = {
  eyebrow: 'the deal',
  /**
   * ⚠ THE FIGHT SLICE IS 3% AND IT IS NOT SPLIT BETWEEN THE POTS. `DECISIONS.md
   * §23` was CORRECTED on 2026-08-06: it used to say "BNBULL pot 2% / BNB pot
   * 1%" and that was wrong. `Duel.routePotSliceInline` routes per asset, whole,
   * "no swap, no split and no second hop anywhere on this path" — the slice
   * lands in the pot matching the currency that side actually paid in.
   * Winner 90% · pot 3% · dev 7%, from `duelDefaultDevBps = 1000` and
   * `potShareBps = 3000`.
   */
  body:
    'every mint and every revive feeds two pots: 20% buys $BNBULL, 10% goes to BNB. ' +
    'every fight feeds them too: the winner takes 90% of the money in the middle and 3% ' +
    'drops into the pot for whichever currency was played. they stack until someone ' +
    'hits, and the winner takes the lot.',
} as const;

// ─── safety refrain (VOICE-AND-BRAND §4, on every page footer) ───────

/**
 * ⚠ TWO TRUST SURFACES, ONE STORY. The telegram pin says "the CA drops here
 * first", and this footer used to say the SITE was the only place — two
 * official voices contradicting each other on the one subject where a scammer
 * exploits any daylight. Both now name the same two places and nothing else.
 */
export const SAFETY =
  'the real contract address gets posted exactly two places: this site and the pinned ' +
  'telegram post. nobody dms first, and nobody will ever ask for your seed phrase.';

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
 * labelled by `DEATH.label`, `/duel` by `PIT.label`, exactly the way fefers
 * labels `/market` "Marketplace".
 */
export const NAV: readonly NavEntry[] = [
  { href: '/mint', label: 'mint' },
  { href: '/duel', label: PIT.label },
  { href: '/history', label: 'history' },
  { href: '/graveyard', label: DEATH.label },
  { href: '/market', label: 'marketplace' },
  // Fefers' nav order puts the two ranking pages between marketplace and
  // browse, and they carry different meanings on purpose: `leaders` ranks by
  // duel RATING (how well a bull fights), `ranks` by rarity SCORE (how rare it
  // is). Keeping both visible is what stops either being read as the other.
  { href: '/leaders', label: 'leaders' },
  { href: '/ranks', label: 'ranks' },
  { href: '/pots', label: 'pots' },
  { href: '/bulls', label: 'browse' },
  { href: '/about', label: 'how to play' },
  { href: '/about#bnbull', label: `buy $${TICKER}`, cta: true },
];
