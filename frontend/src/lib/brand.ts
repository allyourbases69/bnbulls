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
  'build a herd, send them into the bull pit, keep them off the truck or they face the chop';

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
  bnbull: { label: '$BNBULL pot', symbolFallback: 'BNBULL', odds: '1-in-150' },
  /**
   * ⚠ `BNB`, NOT `WBNB`, AND THE PARAGRAPH ABOVE IS NOW HISTORY FOR THIS POT.
   * It reasoned that `prizeToken` is immutable so the fallback "cannot drift
   * for THIS deployment" — true, and then the deployment changed. `JackpotNative`
   * pays the winner native BNB and has no `prizeToken()` at all, so the surfaces
   * assert `BNB` (`NATIVE_POT_DECIMALS`/`NATIVE_POT_SYMBOL`) instead of reading a
   * token that does not exist. This string survives as the PRE-LAUNCH figure and
   * the legacy-pot fallback; leaving it at `WBNB` would have printed the wrong
   * ticker beside every number on the card the migration exists to fix.
   */
  bnb: { label: 'BNB pot', symbolFallback: 'BNB', odds: '1-in-75' },
  /** Shown beside an unclaimed jackpot prize on the native pot, where a win
   *  credits the winner rather than transferring to them. */
  prizeHeld:
    'the pot credits a winner rather than pushing the money out, so one broken wallet ' +
    'cannot wreck the roll for everybody else. it is yours, claim it whenever you like.',
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

// ─── the pen (contracts/BullPen.sol) ─────────────────────────────────
//
// ⚠ WHAT THE PEN IS, IN ONE PARAGRAPH, BECAUSE EVERY STRING BELOW DEPENDS ON
// IT. The rarity table is public and permanent by design — it is derived from a
// public `masterSeed`, committed on chain as `initialRarityHash`, and the same
// shuffle ships in this site's own bundle. That is fine. What was NOT fine was
// that ids came out in order, so anybody could work out which id was legendary
// and watch the counter. The pen holds every unsold bull and deals one at
// random, so WHEN you buy no longer decides WHICH bull you get.
//
// ⚠ AND THAT IS WHY IT TAKES TWO TRANSACTIONS. If the bull were drawn inside
// the buyer's own transaction, a contract caller could look at the result and
// revert if it was not a legendary — a revert costs gas and nothing else, so
// they would just retry until one landed. You cannot have same-transaction
// delivery, unpredictability, and no free abort. So the money moves first, and
// the draw settles after, once a seed exists that nobody could have seen.
//
// ⚠ THE COPY MUST NEVER PROMISE A PARTICULAR BULL, AND MUST NEVER APOLOGISE
// FOR THE WAIT. The wait is the feature. "your bull is being rolled" is the
// honest and the exciting sentence at the same time, and it is the one to use.
//
// ══════════════════════════════════════════════════════════════════════════
// ⚠⚠ THE REFUND STRINGS BELOW: THE ONE RULE THAT GOVERNS ALL OF THEM
// ══════════════════════════════════════════════════════════════════════════
// **NOTHING HERE MAY PROMISE AN INSTANT REFUND, EVER, IN ANY WORDING.**
//
// A refund is only safe once the draw definitively cannot still land. The
// contract enforces that with `refundAfterBlocks`, and the reason is not
// caution: `refund` sets `refunded` BEFORE anything else so a VRF word arriving
// later is inert, and refunding earlier would mean racing that word — a buyer
// who got their money back and then got the bull as well, paid for by everybody
// else in the pen. So the wait is mandatory, it is measured in blocks, and it
// cannot be shortened by wanting it to be.
//
// The temptation is to paper over that with softer words. Do not. The way out
// is to tell the player EARLY and keep telling them the truth the whole way
// through, which is what these strings do:
//
//   from the second they pay   the pen is holding the money, not us
//   while they wait            here is the block it becomes yours to take back
//   once the window opens      here is the button, and the keeper usually beats
//                              you to it
//   after it lands             what happened, how much came back, mint again
//
// Every one of those sentences is true at the moment it is shown, and none of
// them stops being true later. That is the whole test to apply to any edit.

export const PEN = {
  /** What the pen is called anywhere a player reads it. */
  label: 'the pen',
  /** The one-liner that explains the two-step, wherever a buyer first meets it. */
  why:
    'the pen deals you a bull at random. it is drawn after you pay, off a seed that does not ' +
    'exist yet when you hit the button, so nobody can wait for the good ones.',
  /** The banner headline when bulls are on their way to the connected wallet. */
  onTheWay: 'you have bulls on the way.',

  // ── the two sides of a gift ────────────────────────────────────────
  //
  // ⚠ THE PAYER AND THE RECIPIENT NEED OPPOSITE SENTENCES, AND SWAPPING THEM
  // IS WORSE THAN SAYING NOTHING. `BullPen` indexes both roles, so one wallet's
  // banner can carry a gift going out and a gift coming in at the same time.
  // The bull lands with the RECIPIENT; the refund goes back to the PAYER. Tell
  // a gifter "you have bulls on the way" and they will go looking in a wallet
  // the bull is never arriving in.

  /** Headline: they paid, somebody else gets the bull. */
  giftOutHeading: 'the bull you bought is on its way to them.',
  giftOut:
    'you paid for this one and it is going to another wallet, so the bull lands there rather ' +
    'than here. if the draw does not come off, the money comes back to you, because you are the ' +
    'one who paid.',
  /** Headline: somebody else paid, they get the bull. */
  giftInHeading: 'someone has bought you a bull.',
  giftIn: 'another wallet paid for this one and the bull is coming to you.',
  /** The reveal step's word in the mint's step strip. */
  drawStep: 'draw',

  /**
   * ⚠ THE SENTENCE THAT DOES THE MOST WORK ON THIS WHOLE SCREEN, AND IT IS
   * TRUE IN BOTH BRANCHES. Payment is escrowed in the pen at reserve and only
   * moves when the draw settles or when the money comes back. So "your funds
   * are safe" is not reassurance here, it is a description of where the money
   * physically is, and the amount next to it is read off the contract. Shown
   * from the first block of the wait, not held back until something looks
   * wrong: a promise made only once there is trouble reads as an excuse.
   */
  moneySafe:
    'the pen contract is holding your money the whole time this takes. it only moves when the ' +
    'draw lands and your bull comes across, or when it comes back to the wallet that paid.',
  /** ⚠ SAME FACT, NO "your money". The recipient of a gift did not pay, so the
   *  possessive would be claiming a balance that is not theirs on a screen
   *  whose whole job is to be exact about where money is. */
  moneySafeGiftIn:
    'the pen contract is holding the payment the whole time this takes. it only moves when the ' +
    'draw lands and your bull comes across, or when it goes back to the wallet that paid.',

  // ── the rescue states, one sentence each ───────────────────────────
  //
  // ⚠ THESE ARE NOT ERROR MESSAGES AND MUST NOT READ LIKE THEM. Every one of
  // them describes a paid-for bull that is still coming, or money that is on
  // its way back. Three of them name a button ANYONE may press, the buyer
  // included, so that delivery is something nobody can be locked out of. The
  // fourth, the refund, is the payer's alone.

  /** WaitingForVrf, early. The ordinary case, and it is quick. */
  waitingForVrf: 'the draw is being rolled. this usually takes about a minute.',
  /**
   * WaitingForVrf, but well past typical.
   *
   * ⚠ "LONGER THAN USUAL", NEVER "SOMETHING WENT WRONG". There is no on-chain
   * flag for a broken draw, and the measured first live fulfilment took
   * thousands of blocks, so a claim of fault would be this site inventing a
   * diagnosis. Longer than usual is observable and is all we know.
   */
  stalled:
    'the chain has not answered for your bull yet. this one is taking longer than most do, ' +
    'which is the dice roller being slow rather than your money going anywhere.',
  /** The words around the countdown. ⚠ NEVER HARDCODE THE BLOCKS: the number is
   *  `refundAfterBlocks`, it is owner-settable, and it is read. */
  refundPromise: 'if the draw has not landed by then, you can take your money straight back.',

  /** Refundable, and every later un-seeded state, because `refund` stays live
   *  through all of them. */
  refundable:
    'the draw did not land in time, so your money is yours to take back whenever you want it.',
  /** ⚠ SAY THE KEEPER NORMALLY DOES IT. Otherwise the button reads as a chore
   *  the player has been left with, when it is actually the guarantee behind a
   *  keeper that is expected to get there first. */
  refundKeeper:
    'the keeper normally sends it back for you within a few minutes. this button is here so you ' +
    'never have to wait on us to do it.',
  refundCta: 'take my money back',
  /** The payer and the recipient can differ on a gifted mint, and only the
   *  payer may refund. Say whose it is rather than showing a dead button. */
  refundNotYours:
    'another wallet paid for this one, so the refund belongs to them rather than to you. the ' +
    'bull still comes here if the draw lands.',

  // ── the dialogue the owner asked for, in four parts ────────────────
  //
  // "as long as a dialogue shows on screen what the error was and that their
  // funds are safu and been returned straight away and they should mint again"
  //
  // ⚠ ON SCREEN, NOT IN A TOAST, AND IT SURVIVES A RELOAD. It is rendered off
  // `openReservationsOf(you)` and `rescueState`, so it is a fact about the
  // chain rather than something this tab happens to remember. Close the tab,
  // come back on a phone, it is still there.

  /** 1 · what happened. Plain language, no error code, no blame on the buyer. */
  refundedWhat:
    'the chain never answered with a number for your draw, so no bull was dealt. that is the ' +
    'random number service having an outage, and it is nothing you did.',
  /** 2 + 3 · safe, and returned. */
  refundedHeading: 'your money has been returned.',
  refundedBody:
    'the pen was holding it the whole time and it has gone back to the wallet that paid. the ' +
    'only thing this cost you is the gas.',
  /** Same moment, but they were buying it for somebody else. ⚠ SAY THAT NO BULL
   *  WENT ACROSS. A gifter's first question is not "where is my money", it is
   *  "did they get it or not", and leaving that unanswered is how somebody
   *  double-buys a present. */
  refundedGiftBody:
    'no bull went across to the wallet you were sending it to, and the money has come back to ' +
    'you, since you are the one who paid. the only thing this cost you is the gas.',
  /**
   * ⚠ THE RECIPIENT OF A GIFT NEVER PAID, SO "your money has been returned" IS
   * FLATLY FALSE FOR THEM AND WOULD HAVE THEM LOOKING FOR A CREDIT THAT IS NOT
   * COMING. They are owed the OUTCOME, not the money: the bull is not arriving,
   * and nobody is out of pocket.
   */
  refundedToYouHeading: 'that one is not coming after all.',
  refundedToYouBody:
    'the draw never landed, so no bull was dealt and the money went straight back to the wallet ' +
    'that paid for it. nobody is out of pocket, it just did not come off.',
  /** 4 · mint again. */
  refundedAgain:
    'nothing is wrong with the mint itself, and the pen is still full of bulls. have another go ' +
    'whenever you feel like it.',
  refundedCta: 'mint again',
  /** When the session never saw the escrow, so we can state the fact but not
   *  the figure. ⚠ NEVER SUBSTITUTE A GUESS HERE. */
  refundedAmountUnknown:
    'check the wallet that paid for the exact amount. this page will not print a figure it did ' +
    'not read off the chain itself.',

  /** ArmFallback. Chainlink went quiet; the backup is permissionless. */
  armFallback:
    'the dice roller has gone quiet, so the backup draw is available. anyone can start it, ' +
    'including you, and it costs nothing but gas.',
  armCta: 'start the backup draw',
  /** WaitFallback. Armed, waiting for the block it named. */
  waitFallback:
    'the backup draw is started and is waiting on a block that has not been mined yet. that gap ' +
    'is the point: whoever started it could not see what they were starting.',
  /** PinFallback. The window is open and it closes. */
  pinFallback:
    'the backup draw is ready to be locked in. do it soon, a block hash is only readable for ' +
    'about 256 blocks and then it has to start over.',
  pinCta: 'lock the draw in',
  /** Settle. The seed is fixed. Nothing left to decide. */
  settle:
    'your bulls have been drawn. one more transaction hands them over, and anyone can send it, ' +
    'so the result is already fixed either way.',
  settleCta: 'hand them over',
  /** QueuedBehind. FIFO is a security control, not a queue for fun. */
  queuedBehind:
    'the reservation in front of yours has to finish first. that order is deliberate: if buyers ' +
    'could choose who settles first they could shuffle the pen and shop for a better draw. ' +
    'unstick the one in front and yours goes straight after.',
  queuedCta: 'unstick the one in front',
  /** Settled. */
  settled: 'delivered.',
  /** Unknown. Should not happen; say something true rather than nothing. */
  unknown:
    'the pen does not know this reservation. that usually means this build is pointed at a ' +
    'different pen than the one you bought from.',

  /** A refund whose push back bounced. Parked, named, and collectable. */
  refundDeferred:
    'your refund was worked out but the transfer back bounced, so the pen is holding it under ' +
    'your name until you collect it. it is already yours, this only moves it.',
  claimRefundCta: 'collect my refund',

  /** A drawn bull whose delivery transfer bounced. Rare, and recoverable. */
  unclaimed:
    'one of your bulls was drawn but the handover bounced, so it is parked and waiting for you ' +
    'to collect it. it is already yours, this only moves it.',
  claimCta: 'collect it',
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

  /**
   * ⚠ FIGHTING IN BNB NEEDS NOTHING SET UP. SAY IT PLAINLY AND SAY IT FIRST.
   *
   * `Duel._takeSide`'s native path takes YOUR side straight out of the
   * transaction:
   *
   *     if (asset == address(wbnb) && owner_ == msg.sender && credit >= stake)
   *
   * and `_collectStakes` wraps only what that side owed and refunds the rest.
   * So a player who starts fights needs no wbnb, no approval and no wrap, ever.
   *
   * This string exists because the site taught the opposite. A wrap-then-approve
   * ladder sat in the primary slot of step 2, so every player read it as the
   * price of entry — six mainnet wallets signed approvals they never needed, and
   * three of them wrapped nothing, which left them approved-but-empty and
   * unfightable. The setup below is real and worth having, but it buys ONE
   * thing, and it is not the ability to fight.
   */
  fightNeedsNothing:
    'fighting in bnb needs nothing set up. the amount rides along with the ' +
    'transaction and the contract hands back whatever it did not need.',

  /**
   * The honest one-liner for the OPTIONAL setup, and it does not dress the
   * mechanism up. Owner call, 2026-08-10: wbnb is not to be hidden behind a
   * friendlier name — it is to be kept out of the normal path and explained
   * where it genuinely applies.
   */
  challengeSetup:
    'to be challenged while you are offline your side has to be pulled from an ' +
    'allowance, and only wrapped bnb can be pulled that way. it is one for one ' +
    'with bnb and unwraps the same way.',

  // ─── the native fight balance (DuelNative) ──────────────────────────
  //
  // ⚠ THE STRINGS BELOW ARE THE POST-MIGRATION SET AND ARE DARK UNTIL
  // `NATIVE_DUEL` IS ON. They replace `challengeSetup` above, which describes
  // the WBNB allowance the new contract does away with. Keep BOTH until the
  // old duel is retired: one build serves either side of the cutover.

  /** Why a balance exists at all. Same honest shape as `challengeSetup`: it
   *  buys ONE thing, and starting fights yourself is not it. */
  balanceSetup:
    'to be challenged while you are offline your side has to come from money the ' +
    'duel contract is already holding for you, because only the wallet sending a ' +
    'transaction can put bnb in it. it takes two things: money in here, and an ' +
    'away budget saying how much of it those fights may spend. it is plain bnb ' +
    'and you can take it out whenever you like.',

  /**
   * ⚠ THIS IS THE APPROVAL CUSTODY DELETED, AND SAYING SO IS THE POINT.
   *
   * On the old contract a player's exposure to a fight they did not sign was
   * the WBNB allowance they granted — a number they chose. Moving to a credit
   * ledger removed the approval step and silently replaced that ceiling with
   * their ENTIRE balance: a review's proof of concept drained 81 of 90 BNB in
   * one transaction with a leaked signer key. `passiveAllowance` puts the
   * ceiling back, and this string is why a player should bother setting one.
   *
   * It deliberately does NOT lead with "if our key leaks" — that is the true
   * reason and it is in here, but a control framed as a confession gets read as
   * an admission of fragility rather than a seatbelt. It leads with the thing
   * the player actually controls.
   */
  awayBudgetWhy:
    'this is the only thing bounding what an offline fight can take, so keep it to ' +
    'what you are happy to have in play. everything above it stays out of reach, ' +
    'even if something goes wrong at our end.',

  /**
   * ⚠ THE SINGLE BIGGEST TRAP OF THE MIGRATION, AND THE ONE STRING THAT
   * DEFUSES IT. `DuelNative._distributePot` pays a winner by CREDITING the
   * fight balance rather than sending anything — which is what stops a winner
   * with a reverting `receive()` from reverting the whole duel. The cost is
   * that somebody wins, opens their wallet, sees no change and concludes the
   * game stole from them. So the winnings say where they are and how to get
   * them, every time, on the page they were won on.
   */
  winningsHeld:
    'your winnings land in your fight balance, not straight in your wallet. that is ' +
    'what keeps one broken wallet from being able to wreck a fight for everybody. ' +
    'take it out whenever you like.',

  /** Shown next to the withdraw control. The pause point matters: players are
   *  right to distrust a contract that can freeze their money, and this one
   *  deliberately cannot. */
  withdrawAlways:
    'withdrawing is never paused. even if fights stop, your money is yours to take.',

  /**
   * ⚠ THE ANSWER TO "CAN I GET IT BACK", PUT WHERE THE DECISION IS MADE.
   *
   * Owner call, 2026-08-10: the exit belongs ABOVE the deposit control, not in
   * fine print under it. `DuelNative.withdraw` is gated on nothing at all — no
   * cooldown, no lock, no in-fight hold, and deliberately outside
   * `whenNotPaused` — so this is the strongest true sentence available, and a
   * player weighing up whether to put real bnb into a contract should read it
   * before they type an amount rather than after they have sent one.
   */
  withdrawFirst:
    'you can take it all back out whenever you like. no lock, no waiting, and no fight can hold ' +
    'it up.',

  /**
   * ⚠ THE AWAY BUDGET IN ONE SENTENCE A NORMAL PERSON GETS, AND THE WORD
   * "BUDGET" IS DOING ALL THE WORK.
   *
   * `_takeSide` DECREMENTS `passiveAllowance` on every passive fight, so it is a
   * running total that empties, not a ceiling per fight. Somebody who reads it
   * as "the most one fight can cost me" sets one fight's worth, gets exactly one
   * away fight, and is then silently unchallengeable while believing the feature
   * is on. That misreading is what a per-fight word like "limit", "cap" or "max"
   * would produce, so none of them may be used here.
   */
  /**
   * WHAT THE CURRENCY PICK COVERS, ON THE NATIVE CONTRACT.
   *
   * ⚠ REPLACES A LINE THAT DESCRIBED THE RETIRED MODEL ON THE LIVE FIGHT GATE.
   * It read "somebody else picking one of your bulls draws on the allowance you
   * gave the duel contract in step 2, in whichever currency you approved" —
   * which is true of the OLD contract and flatly false of `DuelNative`, where a
   * passive side is debited from the custodied balance and no allowance is
   * involved on the bnb leg at all. It also put a banned word on the one screen
   * a player reads immediately before signing.
   */
  pickCoversNative:
    'this covers your own side of a fight you start, and it rides along with the transaction ' +
    'straight out of your wallet. somebody else picking one of your bulls is paid from your ' +
    'fight balance instead, because only the wallet sending a transaction can put bnb in with it.',

  awayBudgetSpendsDown:
    'think of it like petrol money, not a speed limit. each fight somebody else starts takes its ' +
    'cost out of it, and when it hits empty your bulls quietly stop being pickable until you top ' +
    'it back up.',
} as const;

// ─── the setup ladder · THE BULL PIT, STEP BY STEP ───────────────────
//
// ⚠ WHY THIS BLOCK EXISTS. Owner, 2026-08-10, verbatim: *"make the bullpit
// extremely step by step user friendly. Cant see anywhere there easy it quotes
// HOW MUCH bnb will be deposited etc."*
//
// The migration to native bnb split what used to be one signature into three
// separate jobs, and the page presented none of them as a sequence:
//
//   1. `Yards.enter`               · gas only, and NOTHING fights without it
//   2. `DuelNative.deposit`        · real bnb, for fights you did not start
//   3. `DuelNative.setPassiveAllowance` · DEFAULTS TO ZERO
//
// Step 3 is the one that bit. A wallet can do 1 and 2, see its money sitting
// there, and have every incoming fight refused with `PassiveAllowanceExceeded`
// and no idea why — which is exactly the run of "cannot be fought" reports in
// the telegram group. So the ladder is rendered as a ladder, with each rung's
// live state on it, and a wallet that has parked money behind a zero budget is
// told out loud that it is not finished.
//
// ⚠⚠ AND THE LADDER MUST NOT RE-TEACH THE LIE THE LAST FIX REMOVED. Starting
// your own fight needs NONE of rungs 2 and 3: `_takeSide` spends `msg.value`
// first, so the amount rides along with the transaction. Six mainnet wallets
// once signed for setup they never needed because a control in the primary slot
// read as the price of entry. The rungs are therefore split into two named
// groups — what lets YOU fight, and what lets OTHERS fight your bulls — and the
// second group says "optional" in its own heading rather than in a footnote.

export const READY = {
  /** The panel heading. */
  heading: 'where you are up to',
  /** Under the heading, for somebody who has never done this. The two halves
   *  are named in the order they bite, and the second is flagged as skippable
   *  in the same breath so nothing below it can read as the price of entry. */
  lead: 'get the top half done and you can fight all day. the bottom half is what lets somebody ' +
    'else pick your bulls while you are off doing something else, and it is the bit people miss.',

  /** Group one: the rungs that decide whether YOU can fight. */
  groupSelf: 'so you can fight',
  /** Group two. ⚠ "optional" is in the heading on purpose. */
  groupAway: 'so others can fight your bulls · optional',

  // ── rung 1 · the pit ───────────────────────────────────────────────
  pitTitle: 'get a bull in the bull pit',
  pitLine: 'nothing fights until it is in. one transaction covers as many as you tick, and it ' +
    'costs gas and nothing else.',
  /** The price column for a rung that takes no bnb. Never blank: a blank cell
   *  next to three priced ones reads as a figure that failed to load. */
  pitFree: 'gas only',

  // ── rung 2 · bnb in the wallet ─────────────────────────────────────
  walletTitle: 'keep bnb in your wallet',
  walletLine: 'a fight you start is paid straight out of your wallet with the transaction. ' +
    'nothing to set up and nothing to sign in advance.',
  /** Wallet is short of one fight. Not an error, just a fact with a fix. */
  walletShort: 'not enough in the wallet for one fight right now. top the wallet up and you are ' +
    'good to go.',

  // ── rung 3 · the fight balance ─────────────────────────────────────
  balanceTitle: 'put fight money in',
  balanceLine: 'somebody else picking your bull cannot reach into your wallet, so away fights ' +
    'come out of money the pit is already holding for you. it stays yours and comes back out ' +
    'whenever you want it.',
  balanceEmpty: 'nothing in yet, so nobody can pick your bulls.',

  // ── rung 4 · the away budget ───────────────────────────────────────
  budgetTitle: 'set an away budget',
  budgetLine: 'the most those away fights may spend in total. it starts at zero, which is why ' +
    'this one gets missed.',
  /**
   * ⚠⚠ THE SENTENCE THE WHOLE REDESIGN IS FOR. Money in, budget at zero: the
   * contract refuses every incoming fight, the player sees a balance on screen
   * and concludes the game is broken. Loud, gold, and never behind a fold.
   */
  budgetTrap: 'your money is in but your away budget is zero, so every fight anybody tries ' +
    'against your bulls is getting refused. one more tap and they are in.',
  budgetOff: 'not set, so nobody can pick your bulls while you are away.',

  // ── states ─────────────────────────────────────────────────────────
  done: 'done',
  todo: 'to do',
  optional: 'optional',
  /** ⚠ A READ THAT HAS NOT LANDED IS NOT A ZERO. Every rung uses this rather
   *  than defaulting to "not done", because "we do not know yet" and "you have
   *  not done it" send a player to two different places. */
  unread: 'checking…',
  connect: 'connect a wallet',
  /** A rung that cannot be started yet for a reason that is not the wallet
   *  being absent, e.g. a connected wallet holding no bulls at all. */
  notYet: 'nothing to do here yet',
  /** Progress, right-aligned on the heading row. */
  progress: (done: number, total: number) => `${done} of ${total} done`,

  // ── the price line, above everything ───────────────────────────────
  /** The eyebrow on the always-visible cost strip. */
  priceLabel: 'one fight',
  /** What the figure beside it means. Both sides put up the same. */
  priceLine: 'each side puts in the same, and the winner takes 90% of it.',
  /** ⚠ THE FIGURE MOVES. Never let a screenshot of it read as a fixed price. */
  priceMoves: 'the price is a dollar sticker converted at the moment you pay, so this figure ' +
    'moves with the market. what you sign for is what you pay.',
  /**
   * The read did not land. Distinct from a zero, and it has to be.
   *
   * ⚠ THE CONTRACT REFUSING TO QUOTE IS A DESIGNED ANSWER, NOT A FAULT.
   * `stickerCost` reverts on a stale or out-of-band chainlink round rather than
   * clamping, because a clamped price is a wrong price presented as a right one
   * and here it would price a fight at a figure nobody chose. So this says the
   * pit will not quote, never that the site is broken.
   */
  priceUnreadable: 'the price feed is not answering right now, so the pit will not quote a bnb ' +
    'fight. nothing here will guess one.',
  /**
   * ⚠ A ZERO COST IS NOT A CHEAP FIGHT. `Duel.sol` treats a zero as a FREE
   * fight, and in practice it means nobody has pegged that leg yet, so it must
   * never be printed as "0.000000 bnb" beside a fight button.
   */
  priceUnset: 'no bnb price is registered on the duel contract yet.',
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
   *
   * ⚠ THE MINT/REVIVE SPLIT IS PER PAYMENT ASSET, NOT UNIVERSAL. E2E-verified
   * 2026-08-08: BNB payments route 20% BNBULL-buy / 10% BNB / 70% dev, but
   * BNBULL payments route 30 / 0 / 70 — the never-sell default (owner decision
   * 2026-08-06) means the game never swaps $BNBULL into anything, so the whole
   * pot leg stays in the gold pot. "30% into the pots" is the only sentence
   * true of both currencies; the copy below leads with it for that reason.
   */
  body:
    'every mint and every revive drops 30% into the pots. paid in bnb, 20% of it buys ' +
    '$BNBULL and 10% goes to the BNB pot. paid in $BNBULL, all 30% stays $BNBULL, ' +
    'because the game never sells it. every fight feeds them too: the winner takes 90% ' +
    'of the money in the middle and 3% drops into the pot for whichever currency was ' +
    'played. they stack until someone hits, and the winner takes the lot.',
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
