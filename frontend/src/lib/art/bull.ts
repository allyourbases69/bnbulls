// bnbulls — deterministic bull gladiator sprite core.
//
// ⚠ THIS IS A LINE-FOR-LINE PORT OF `generator/bull.mjs`. The whole contract
// of this file is that token #n renders byte-identically here and in the
// node build — see DECISIONS.md §6 and the frontend package brief. Every
// constant, every arithmetic expression, every function body below is
// copied verbatim from the .mjs source; only syntax changed (ESM exports →
// typed exports, `const fn = (...) =>` → typed functions/consts) to satisfy
// TypeScript. If you need to change the art, change `generator/bull.mjs`
// FIRST, then re-port — never edit the maths here first.
//
// Verified against the node build with `frontend/scripts/verify-art-port.ts`
// (byte-for-byte diff of every rolled token's grid, palette and rendered
// tile, ids 1..500 plus the king #501 override).

// ⚠ THE BULL IS CENTRED IN THE FRAME — see the long derivation in
// `generator/bull.mjs`. W is odd so the mirror-symmetric bull has a centre
// COLUMN, CX === (W-1)/2, and the weapon's reach (CX+31, the sledge) is what
// sets the number. It was 48 with CX=17, i.e. the bull sat 6.5px left of a true
// centre of 23.5.
export const W = 63;
export const H = 56;
export const TILE_W = W + 8;
export const TILE_H = H + 8;
export const MARGIN = 4;

// ---------- deterministic rng (unchanged from fefers) ----------

export const MASTER_SEED = 0x0b17b011;

export function lcg(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

export function tokenSeed(id: number): number {
  let h = (MASTER_SEED ^ Math.imul(id, 2654435761)) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 2246822519) >>> 0;
  return (h ^ (h >>> 13)) >>> 0;
}

// ---------- collection config ----------

export const SUPPLY = 500;
export const KING_ID = 501;

export type Band = 'common' | 'uncommon' | 'rare' | 'epic' | 'legendary';
export type RGB = [number, number, number];

export const BANDS: Band[] = ['common', 'uncommon', 'rare', 'epic', 'legendary'];
export const BAND_COUNTS: Record<Band, number> = {
  common: 200,
  uncommon: 130,
  rare: 90,
  epic: 50,
  legendary: 30,
};
export const CLEAN_CHANCE: Record<Band, number> = {
  common: 0.7,
  uncommon: 0.6,
  rare: 0.5,
  epic: 0.4,
  legendary: 0.35,
};

export interface BandInfoEntry {
  tier: number;
  family: string;
  note: string;
  bg: RGB;
  floor: RGB;
}

// "band" was fefers jargon doing two jobs at once: the rarity tier AND the hide
// colour family. split apart — `tier` is what a buyer filters on, `family` is
// the flavour word for the hide palette.
export const BAND_INFO: Record<Band, BandInfoEntry> = {
  common: {
    tier: 1,
    family: 'dust',
    note: 'greys and browns. hide and hard yakka.',
    bg: [229, 222, 208],
    floor: [201, 191, 171],
  },
  uncommon: {
    tier: 2,
    family: 'ember',
    note: 'the warm one. rust, ember, blood.',
    bg: [238, 214, 190],
    floor: [212, 178, 146],
  },
  rare: {
    tier: 3,
    family: 'venom',
    note: 'greens and purples. the wrong ones.',
    bg: [212, 222, 204],
    floor: [178, 192, 166],
  },
  epic: {
    tier: 4,
    family: 'onyx',
    note: 'black hide, cold steel.',
    bg: [206, 212, 220],
    floor: [168, 176, 190],
  },
  legendary: {
    tier: 5,
    family: 'gold',
    note: 'bnb gold. the top of the ladder.',
    bg: [246, 232, 188],
    floor: [222, 198, 136],
  },
};

export type SkinEntry = [string, RGB];

export const SKINS: Record<Band, SkinEntry[]> = {
  common: [
    ['ash', [128, 126, 120]],
    ['slate', [108, 104, 98]],
    ['bone', [148, 142, 132]],
    ['dirt', [139, 105, 72]],
    ['mud', [117, 88, 60]],
    ['tan', [158, 124, 88]],
  ],
  uncommon: [
    ['rust', [198, 88, 52]],
    ['blood', [172, 54, 44]],
    ['ochre', [214, 120, 48]],
    ['clay', [166, 84, 40]],
    ['amber', [222, 148, 62]],
    ['brick', [188, 96, 70]],
  ],
  rare: [
    ['swamp', [96, 148, 72]],
    ['moss', [72, 124, 88]],
    ['slime', [122, 164, 60]],
    ['grape', [128, 88, 168]],
    ['midnight', [98, 72, 142]],
    ['orchid', [156, 102, 180]],
  ],
  epic: [
    ['pitch', [58, 58, 66]],
    ['charcoal', [76, 78, 88]],
    ['iron', [92, 96, 108]],
    ['obsidian', [44, 46, 56]],
    ['gunmetal', [104, 110, 124]],
    ['soot', [66, 64, 62]],
  ],
  legendary: [
    ['bnb gold', [240, 185, 11]],
    ['honey', [226, 178, 58]],
    ['bronze', [192, 140, 36]],
    ['butter', [234, 198, 96]],
    ['tarnish', [176, 128, 40]],
    ['brass', [214, 166, 70]],
  ],
};

export type EyeEntry = [string, RGB];

export const EYES: EyeEntry[] = [
  ['yellow-green', [196, 214, 74]],
  ['amber', [232, 180, 60]],
  ['red', [222, 74, 52]],
  ['lime', [150, 220, 90]],
  ['pale', [240, 240, 230]],
  ['icy', [110, 200, 220]],
];
export const BAND_EYES: Record<Band, number[]> = {
  common: [0, 1, 2, 3, 5],
  uncommon: [0, 3, 4, 5],
  rare: [0, 1, 2, 3, 5],
  epic: [1, 2, 4, 5],
  legendary: [2, 3, 4, 5],
};

// 12 slots — count LOCKED (stats/weights untouched), names bull-themed
export const WEAPONS: string[] = [
  'shiv',
  'pitchfork',
  'maul',
  'cleaver',
  'hornbow',
  'bolter',
  'morningstar',
  'reaper',
  'sledge',
  'ring',
  'pike',
  // ⚠ slot 11 WAS 'prod' / "Gilded Prod" and is now 'kingpike' / "Gilded Pike".
  // Name + sprite only: `50, 100, 10, 2, 0` is untouched, type 2 (ranged) most
  // of all. See `generator/bull.mjs` for why a bow was tried and rejected.
  'kingpike',
];
// parallel to WEAPONS by index. slot 11 ('kingpike') carries weight 0 — it is
// king-only, set directly by mintKing() and never rolled.
export const WEAPON_WEIGHT: number[] = [18, 17, 15, 12, 11, 9, 7, 5, 3, 2, 1, 0];
export const KING_WEAPON = 'kingpike';
export const WEAPON_KIND: Record<string, string> = {
  maul: 'club',
  pitchfork: 'trident',
  sledge: 'axe',
  cleaver: 'sword',
  pike: 'spear',
  hornbow: 'bow',
  shiv: 'dagger',
  morningstar: 'flail',
  reaper: 'scythe',
  kingpike: 'kingpike',
  ring: 'boomerang',
  bolter: 'crossbow',
};

// ---------- the chain's tables: rarity and weapon ----------
//
// ⚠ THIS SECTION IS THE SOURCE OF TRUTH. THE ART OBEYS IT, NEVER THE REVERSE.
//
// `Bulls.sol` decides in its constructor which token is which tier, and at
// mint which weapon it carries. Both decisions are immutable, both are what a
// holder owns and what a marketplace prices, and the art is deterministic from
// the token id — so a sprite that disagrees is wrong FOREVER and nothing on
// chain would ever tell you. (`DECISIONS.md §27`.)
//
// The generator used to answer both questions itself, with its own LCG shuffle
// (`assignBands()`) and its own draw over all twelve weapon weights. Both were
// silently wrong against the seed that is about to ship:
//   • 377 of 500 tokens rendered the WRONG TIER — only 3 of the 30 legendaries
//     landed on a token the chain also calls legendary.
//   • 450 of 500 rendered a weapon the chain never assigned, and 362 of those
//     were not even inside that tier's on-chain slice (common bulls holding
//     the legendary Pike).
// Both functions are DELETED, not deprecated — a dead function that returns a
// plausible-but-wrong answer is how this recurs. If you are looking for
// `assignBands()`, you want `chainBandMap()`.
//
// Everything below is a line-for-line port of `contracts/lib/Xorshift.sol`,
// `Bulls._initializeRarity()`, `Bulls._tierWeaponRange()` and
// `Bulls._rollWeaponInTier()`. BigInt throughout because these are uint64 /
// uint256 operations and a double loses the low bits.
//
// Proved against the real contract, not merely eyeballed:
//   forge script script/Names.s.sol:PrintNamesCommitment    (rarity)
//   FOUNDRY_SCRIPT=generator/probe forge script \
//     generator/probe/ChainTableProbe.s.sol:ChainTableProbe (rarity + weapons)
//   npm run verify:rarity                                   (gate, every run)

const XS_MASK = (1n << 64n) - 1n;
const u64 = (x: bigint): bigint => x & XS_MASK;

export interface XorshiftState {
  s0: bigint;
  s1: bigint;
}

/** Xorshift128+ state from a uint256 seed, SplitMix64-mixed. `Xorshift.create`. */
export function xorshiftCreate(seed: bigint | number): XorshiftState {
  let z = u64(u64(BigInt(seed)) + 0x9e3779b97f4a7c15n);
  z = u64((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
  z = u64((z ^ (z >> 27n)) * 0x94d049bb133111ebn);
  const s0 = z ^ (z >> 31n);

  z = u64(s0 + 0x9e3779b97f4a7c15n);
  z = u64((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
  z = u64((z ^ (z >> 27n)) * 0x94d049bb133111ebn);
  const s1 = z ^ (z >> 31n);

  // the degenerate all-zero state is replaced, exactly as the library does.
  if (s0 === 0n && s1 === 0n) return { s0: 1n, s1: 2n };
  return { s0, s1 };
}

/** `Xorshift.nextUint64`. MUTATES `st`. */
export function xorshiftNext(st: XorshiftState): bigint {
  let s1 = st.s0;
  const s0 = st.s1;
  const result = u64(s0 + s1);
  st.s0 = s0;
  s1 = u64(s1 ^ u64(s1 << 23n));
  st.s1 = u64(s1 ^ s0 ^ (s1 >> 17n) ^ (s0 >> 26n));
  return result;
}

/** `Xorshift.nextInt` — inclusive [min, max], rejection sampled. BigInt in/out. */
export function xorshiftInt(st: XorshiftState, min: bigint, max: bigint): bigint {
  if (min > max) throw new Error('Xorshift: min > max');
  if (min === max) return min;
  const range = max - min + 1n;
  if (range > 1n << 64n) throw new Error('Xorshift: range too large');
  const maxValid = ((1n << 64n) / range) * range;
  let roll: bigint;
  do {
    roll = xorshiftNext(st);
  } while (roll >= maxValid);
  return min + (roll % range);
}

/** `Xorshift.weightedPick` — returns the index, not the value. */
export function xorshiftWeightedPick(st: XorshiftState, weights: number[]): number {
  if (weights.length === 0) throw new Error('Xorshift: empty weights');
  let total = 0n;
  for (const w of weights) total += BigInt(w);
  if (total === 0n) throw new Error('Xorshift: zero total weight');
  const roll = xorshiftInt(st, 0n, total - 1n);
  let cumulative = 0n;
  for (let i = 0; i < weights.length; i++) {
    cumulative += BigInt(weights[i]);
    if (roll < cumulative) return i;
  }
  throw new Error('Xorshift: unreachable');
}

// domain separators, straight out of Bulls.sol. the rarity shuffle and the
// weapon draw are decorrelated on purpose — changing one must not shift the
// other.
export const SHUFFLE_DOMAIN = 0x5348554646n; // uint256("SHUFF")
export const WEAPON_SEED_MULT = 0x94d049bb133111ebn;

/**
 * `Bulls._initializeRarity()`. Returns `tiers[tokenId - 1]` in 0..4 — the table
 * exactly as it stands when the constructor returns, which is the snapshot
 * `initialRarityHash` covers and the one the names were dealt against.
 *
 * ⚠ `Bulls._skipRareForDev()` can still swap two slots at mint time while a
 * dev wallet is configured and `freezeRarity()` has not been called. That
 * would move a token's tier AWAY from this table (and away from its dealt
 * name) after the fact. Deploy with `DEV_WALLET` unset, or call
 * `freezeRarity()` before the public mint — otherwise no off-chain table can
 * be right.
 */
export function chainTiers(masterSeed: bigint | number = MASTER_SEED): number[] {
  const tiers: number[] = [];
  BANDS.forEach((band, tier) => {
    for (let i = 0; i < BAND_COUNTS[band]; i++) tiers.push(tier);
  });
  if (tiers.length !== SUPPLY) throw new Error(`rarity dist mismatch: ${tiers.length} != ${SUPPLY}`);

  const st = xorshiftCreate(BigInt(masterSeed) ^ SHUFFLE_DOMAIN);
  for (let i = SUPPLY - 1; i > 0; i--) {
    const j = Number(xorshiftInt(st, 0n, BigInt(i)));
    const tmp = tiers[i];
    tiers[i] = tiers[j];
    tiers[j] = tmp;
  }
  return tiers;
}

/**
 * The chain's rarity table as `{ tokenId -> band }`, which is the shape every
 * caller here wants. THIS IS THE ONLY LEGITIMATE WAY TO GET A BAND MAP.
 * Covers ids 1..500; the king #501 has no entry (`rarityOf(501)` is tier 5,
 * "king", which has no hide family — the site renders it as a legendary
 * override).
 */
export function chainBandMap(masterSeed: bigint | number = MASTER_SEED): Record<number, Band> {
  const tiers = chainTiers(masterSeed);
  const map: Record<number, Band> = {};
  for (let id = 1; id <= SUPPLY; id++) map[id] = BANDS[tiers[id - 1]];
  return map;
}

/**
 * `Bulls._tierWeaponRange()` — [startIndex, count] into `WEAPONS` per tier.
 * A bull can only ever carry a weapon from its OWN tier's slice; there is no
 * collection-wide weapon draw and there never was one on chain.
 *   0 common    0-2   shiv, pitchfork, maul
 *   1 uncommon  3-4   cleaver, hornbow
 *   2 rare      5-6   bolter, morningstar
 *   3 epic      7-8   reaper, sledge
 *   4 legendary 9-10  ring, pike
 *   5 king      11    kingpike — set directly by mintKing(), never rolled
 */
export const TIER_WEAPON_SLICE: Array<[number, number]> = [
  [0, 3],
  [3, 2],
  [5, 2],
  [7, 2],
  [9, 2],
  [11, 1],
];

/** `Bulls._rollWeaponInTier()`. Returns a catalog index 0..11. */
export function chainWeaponId(
  tokenId: number,
  tier: number,
  masterSeed: bigint | number = MASTER_SEED,
): number {
  const slice = TIER_WEAPON_SLICE[tier];
  if (!slice) throw new Error(`chainWeaponId: invalid tier ${tier}`);
  const [start, count] = slice;
  // `masterSeed ^ (tokenId * 0x94d049bb133111eb)` in uint256, then create()
  // truncates to uint64 — the same two steps, in the same order, as the chain.
  const st = xorshiftCreate(BigInt(masterSeed) ^ (BigInt(tokenId) * WEAPON_SEED_MULT));
  const weights: number[] = [];
  for (let i = 0; i < count; i++) weights.push(WEAPON_WEIGHT[start + i]);
  return start + xorshiftWeightedPick(st, weights);
}

/** The weapon name the chain gives this token. The king is set, not rolled. */
export function chainWeapon(
  tokenId: number,
  band: Band,
  masterSeed: bigint | number = MASTER_SEED,
): string {
  if (tokenId === KING_ID) return KING_WEAPON;
  const tier = BANDS.indexOf(band);
  if (tier < 0) throw new Error(`chainWeapon: unknown band ${band}`);
  return WEAPONS[chainWeaponId(tokenId, tier, masterSeed)];
}

// boots are absent from common and rare on uncommon — one of the two "you can
// tell it's a good one from across the room" tells, alongside horn colour.
export const ACC_POOLS: Record<Band, string[][]> = {
  common: [['ringnose'], ['bandana'], ['horncaps'], ['ringnose', 'bandana']],
  uncommon: [['bandana'], ['shades'], ['horncaps'], ['ringnose'], ['boots']],
  rare: [['shades'], ['horncaps'], ['boots'], ['bandana'], ['boots', 'shades']],
  epic: [['shades'], ['boots'], ['horncaps'], ['shades', 'ringnose'], ['boots', 'shades']],
  legendary: [
    ['crown'],
    ['boots'],
    ['horncaps'],
    ['crown', 'boots'],
    ['crown', 'shades'],
    ['boots', 'shades'],
  ],
};
export const ACC_LABEL: Record<string, string> = {
  ringnose: 'nose ring',
  bandana: 'bandana',
  horncaps: 'horn caps',
  shades: 'shades',
  crown: 'crown',
  boots: 'boots',
};

export type HornEntry = [string, RGB, RGB];

// horn colour — the second rarity tell. common is always plain bone; the top
// tiers roll something that reads at a glance.
export const HORN_POOLS: Record<Band, HornEntry[]> = {
  common: [['bone', [228, 224, 208], [176, 170, 152]]],
  uncommon: [
    ['bone', [228, 224, 208], [176, 170, 152]],
    ['ash', [198, 192, 180], [148, 142, 130]],
  ],
  rare: [
    ['bone', [228, 224, 208], [176, 170, 152]],
    ['jade', [186, 222, 196], [124, 166, 138]],
  ],
  epic: [
    ['obsidian', [96, 98, 110], [56, 58, 68]],
    ['steel', [198, 208, 224], [134, 144, 162]],
  ],
  legendary: [
    ['gilt', [246, 208, 96], [196, 150, 32]],
    ['ivory', [248, 244, 228], [198, 190, 166]],
  ],
};

// ---------- names ----------
//
// ⚠ the pools are FROZEN at deploy, exactly like the rarity shuffle. reordering
// or inserting an entry re-rolls every token's name. finalise before launch.

// every surname below is a real English surname that means cattle or
// cattle-keeping: Coward is cow-herd, Calvert is calf-herd, Oxnard is ox-herd,
// Vachell is Norman French for cow, Bovill is from `bo`, ox. Kine is the
// archaic plural of cow. Whittingstall is "white cattle stall". Stirk is a
// yearling bullock. Bullen is Boleyn.
const CATTLE_SURNAME: string[] = [
  'Bullock', 'Coward', 'Oxley', 'Oxenford', 'Calverley', 'Bulmer', 'Bullen',
  'Cowper', 'Neate', 'Steerforth', 'Stirk', 'Hayward', 'Tupper', 'Byres',
  'Bullingham', 'Drover', 'Grazely', 'Herdwick', 'Chumley', 'Fetlock',
  'Bulkeley', 'Bullard', 'Bulwer', 'Cowley', 'Cowden', 'Cowdray', 'Oxborough',
  'Oxenham', 'Oxnard', 'Studley', 'Calvert', 'Grazier', 'Meadowcroft',
  'Horncastle', 'Horner', 'Hornby', 'Bulstrode', 'Bullivant', 'Cattley',
  'Cattermole', 'Steere', 'Vachell', 'Veale', 'Whittingstall', 'Bulleid',
  'Bullimore', 'Bovingdon', 'Bovill', 'Kine', 'Bulman', 'Coates', 'Longhorne',
  'Beeston', 'Hereford', 'Neatham', 'Stirkland', 'Haywood', 'Shorthose',
];
const PLAIN_FIRST: string[] = [
  'Bert', 'Tom', 'Stan', 'Alf', 'Sid', 'Ted', 'Wal', 'Nobby', 'Ron', 'Reg',
  'Cliff', 'Norm', 'Doug', 'Ken', 'Les', 'Vic', 'Wilf', 'Arthur', 'Frank',
  'Harold', 'Stanley', 'Cyril', 'Ernie', 'Fred', 'Gordon', 'Herbert', 'Jack',
  'Maurice', 'Walter', 'Clifford',
];
const POSH_FIRST: string[] = [
  'Reginald', 'Bartholomew', 'Percival', 'Algernon', 'Montgomery', 'Cuthbert',
  'Humphrey', 'Peregrine', 'Rupert', 'Clarence', 'Nigel', 'Basil', 'Cecil',
  'Archibald', 'Barnaby', 'Crispin', 'Digby', 'Fitzwilliam', 'Horatio',
  'Marmaduke', 'Neville', 'Quentin', 'Tarquin', 'Wilfred', 'Aubrey', 'Bertram',
  'Godfrey', 'Mortimer', 'Rowland', 'Sebastian', 'Thaddeus', 'Ambrose',
  'Augustus', 'Beauregard', 'Cornelius', 'Desmond', 'Edmund', 'Ferdinand',
  'Gilbert', 'Hubert', 'Ignatius', 'Jasper', 'Lionel', 'Maximilian',
  'Nathaniel', 'Octavius', 'Rufus', 'Sylvester', 'Theodore', 'Vernon',
  'Winthrop', 'Barnabas', 'Claudius', 'Everard', 'Fitzroy', 'Hector',
  'Lysander', 'Osbert', 'Ptolemy', 'Rodolphus',
];
const ESTATE: string[] = [
  'Ashcombe', 'Applecross', 'Bexley', 'Cranborne', 'Duxbury',
  'Elmsworth', 'Fairhaven', 'Gorsemoor', 'Havelock', 'Ilminster', 'Kingsmead',
  'Larkspur', 'Marlowe', 'Netherby', 'Oakhanger', 'Pemberley', 'Quenby',
  'Ravensworth', 'Standish', 'Thornbury', 'Underhill', 'Wrenfield',
  'Yatesbury', 'Blandford', 'Chetwynd', 'Dunhollow', 'Eastnor', 'Foxbourne',
  'Glasscombe', 'Harkaway', 'Inglewood', 'Marchwood',
];
const NUMERAL: string[] = [
  'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI',
  'XII', 'XIII', 'XIV', 'XV',
];

type Pick = (arr: string[]) => string;
type NameFormatFn = (p: Pick, r: () => number) => string;

// per-tier name formats. rank escalates with rarity, so a bull's tier is
// legible from its name before you look at a single trait.
const NAME_FORMAT: Record<Band, NameFormatFn> = {
  // commoner — no title. the farmhand bulls.
  common: (p, r) =>
    r() < 0.3 ? `Old ${p(PLAIN_FIRST)} ${p(CATTLE_SURNAME)}` : `${p(PLAIN_FIRST)} ${p(CATTLE_SURNAME)}`,
  // knight
  uncommon: (p, r) =>
    r() < 0.25
      ? `Master ${p(POSH_FIRST)} ${p(CATTLE_SURNAME)}`
      : `Sir ${p(POSH_FIRST)} ${p(CATTLE_SURNAME)}`,
  // baron — the territorial "of <estate>" style starts here
  rare: (p, r) =>
    r() < 0.35
      ? `Baron ${p(CATTLE_SURNAME)} of ${p(ESTATE)}`
      : `Lord ${p(POSH_FIRST)} ${p(CATTLE_SURNAME)}`,
  // earl / viscount
  epic: (p, r) =>
    r() < 0.45 ? `The Earl of ${p(ESTATE)}` : `Viscount ${p(CATTLE_SURNAME)} of ${p(ESTATE)}`,
  // duke — the grandest ranks, plus the county-show champion format
  legendary: (p, r) => {
    const roll = r();
    if (roll < 0.4) return `His Grace the Duke of ${p(ESTATE)}`;
    if (roll < 0.7) return `The Marquess of ${p(ESTATE)}`;
    return `${p(ESTATE)} Champion ${p(NUMERAL)}`;
  },
};

export const KING_NAME = 'Lord Wagyu';

// ── the king's own look (#501) ──────────────────────────────────────────────
// `§34` he is the face of the project; until this pass he rendered as a plain
// `legendary` band override, i.e. a re-skin of a 30-strong tier. `§35`/`§36`:
// the rarity ladder IS the beef-grade ladder and terminates on wagyu, so his
// tells are beef tells — a deeper hide, marbling, gold-veined horns, and the
// crown always. Full rationale in `generator/bull.mjs`.
export const KING_SKIN: SkinEntry = ['wagyu', [206, 146, 20]];
export const KING_HORN: HornEntry = ['gold-veined ivory', [248, 244, 228], [206, 190, 150]];
export const KING_EYE: EyeEntry = ['molten', [255, 214, 92]];

// names are DEALT, not drawn independently. the name rng is its OWN stream,
// so editing a name pool can never re-roll a bull's hide, weapon or horns.
export function assignNames(bandMap: Record<number, Band>): Record<number, string> {
  const rng = lcg((MASTER_SEED ^ 0x5eed5eed) >>> 0);
  const pick: Pick = (arr) => arr[Math.floor(rng() * arr.length)];
  const idsBy: Record<Band, number[]> = { common: [], uncommon: [], rare: [], epic: [], legendary: [] };
  for (let id = 1; id <= SUPPLY; id++) idsBy[bandMap[id]].push(id);

  const out: Record<number, string> = {};
  const taken = new Set<string>([KING_NAME]);
  for (const tier of BANDS) {
    const fmt = NAME_FORMAT[tier];
    if (!fmt) throw new Error(`no name format for tier ${tier}`);
    for (const id of idsBy[tier]) {
      let name: string | null = null;
      for (let tries = 0; tries < 5000 && name === null; tries++) {
        const candidate = fmt(pick, rng);
        if (!taken.has(candidate)) name = candidate;
      }
      if (name === null) throw new Error(`name generator exhausted for ${tier}`);
      taken.add(name);
      out[id] = name;
    }
  }
  out[KING_ID] = KING_NAME;
  return out;
}

// weapon metal is tiered. same twelve shapes, same combat stats — only the
// M/m/G palette entries move, so a legendary's maul is visibly gilded and a
// common's is plain iron. zero sim impact, and it costs nothing to render.
export interface MetalEntry {
  M: RGB;
  m: RGB;
  G: RGB;
}
export const METAL: Record<Band, MetalEntry> = {
  common: { M: [174, 180, 190], m: [108, 114, 124], G: [198, 164, 72] },
  uncommon: { M: [192, 199, 209], m: [120, 128, 140], G: [214, 176, 66] },
  rare: { M: [200, 168, 108], m: [128, 102, 60], G: [226, 186, 88] },
  epic: { M: [152, 164, 184], m: [74, 82, 98], G: [206, 218, 234] },
  legendary: { M: [240, 208, 122], m: [176, 132, 40], G: [255, 234, 152] },
};

// cape: epic and legendary only. it is the one change that alters the
// SILHOUETTE, so it reads at thumbnail size in a marketplace grid where palette
// differences do not.
export const CAPES: Partial<Record<Band, [RGB, RGB]>> = {
  epic: [[104, 28, 44], [62, 16, 26]],
  legendary: [[132, 26, 42], [78, 14, 24]],
};

// armour must CONTRAST the hide, not tint it — this is what separates a
// gladiator from livestock in a poncho (ref: teal vest over brown hide).
export const ARMOUR: Record<Band, [RGB, RGB]> = {
  common: [[44, 106, 106], [226, 184, 72]], // teal + brass over grey/brown
  uncommon: [[32, 70, 92], [216, 208, 182]], // cold blue + bone over red
  rare: [[128, 72, 36], [234, 182, 92]], // bronze over green/purple
  epic: [[96, 116, 146], [206, 218, 234]], // pale steel over black
  legendary: [[36, 40, 60], [240, 185, 11]], // navy + BNB gold #F0B90B
};

export const FIXED_PALETTE: Record<string, RGB> = {
  O: [22, 26, 34], // outline
  P: [16, 16, 20], // pupil / nostril / socket
  T: [246, 246, 240], // tusk
  C: [228, 224, 208], // horn + hoof keratin
  c: [176, 170, 152], // horn shadow
  W: [146, 100, 58], // wood haft
  M: [192, 199, 209], // metal
  m: [120, 128, 140], // metal dark
  G: [232, 188, 62], // gold fitting
  H: [178, 60, 48], // accessory primary (overridden per band)
  h: [232, 220, 196], // accessory secondary
  // ⚠ THE SECOND ACCESSORY'S OWN PAIR. A bull can roll TWO accessories
  // (`ACC_POOLS` — e.g. ['crown','shades']), and both used to be drawn with
  // H/h while `derivePalette` only ever resolved `accessories[0]`. So the
  // second accessory silently wore the FIRST one's colours: a legendary's
  // shades came out crown-gold on a gold hide and the whole face vanished.
  // Defaulted here as well so an accessory char can never fall through to
  // background if a caller builds a palette without going through
  // `derivePalette`.
  J: [178, 60, 48], // 2nd accessory primary
  j: [232, 220, 196], // 2nd accessory secondary
  V: [240, 185, 11], // horn vein — KING ONLY, BNB gold #F0B90B
  // ⚠ NOT near-white: at [250,236,196] the streaks read as scratches.
  n: [242, 210, 138], // wagyu marbling — KING ONLY
  // the king's pennant. Deliberately NOT the cape's `K`/`k`, which only exist
  // on epic and legendary — `build.mjs` sweeps every weapon against every band.
  Y: [150, 30, 44], // pennant cloth — KING ONLY
  y: [96, 18, 30], // pennant shadow — KING ONLY
};

type AccColourMap = Partial<Record<string, [RGB, RGB]>>;

const ACC_COLOURS: { default: AccColourMap } & Partial<Record<Band, AccColourMap>> = {
  default: {
    bandana: [[52, 118, 122], [96, 168, 170]],
    shades: [[38, 40, 48], [104, 110, 124]],
    crown: [[232, 188, 62], [252, 228, 142]],
    ringnose: [[214, 176, 66], [246, 220, 132]],
    horncaps: [[190, 197, 207], [120, 128, 140]],
    boots: [[62, 48, 38], [188, 150, 96]],
  },
  uncommon: {
    bandana: [[236, 224, 200], [196, 182, 156]],
    boots: [[58, 44, 46], [206, 132, 74]],
  },
  rare: { boots: [[46, 58, 44], [186, 214, 150]] },
  // ONE entry per tier. these were split across two `onyx` keys before the tier
  // rename, and the later one silently won — epic boots were falling back to
  // the default brown for several passes. duplicate object keys fail silently
  // in JS; keep every tier's overrides in a single literal.
  epic: {
    boots: [[44, 48, 60], [176, 190, 214]],
    // on a near-black hide the default dark shades vanish, so epic
    // flips them: pale steel frame, dark glint.
    shades: [[198, 212, 232], [48, 54, 68]],
  },
  legendary: {
    horncaps: [[240, 185, 11], [255, 228, 122]],
    boots: [[46, 40, 26], [240, 185, 11]],
    // EVERY legendary hide is a gold tone (see SKINS.legendary: bnb gold,
    // honey, bronze, butter, tarnish, brass), so the default gold crown
    // [232,188,62] sat within ~10/255 of the skin it was drawn on and the whole
    // skull read as one blob. Same failure the `epic` shades entry above fixes
    // for near-black hides, in the opposite direction. Deep crimson band with a
    // bright gold rim: it separates from all six golds, ties to the legendary
    // cape, and still reads as treasure rather than a hat.
    crown: [[136, 26, 44], [255, 214, 92]],
    // the lens stays near-black (it is the one accessory that must read as a
    // hole in the face) but the glint goes BNB gold instead of the default
    // grey, so the tier's metal is consistent.
    shades: [[32, 34, 44], [240, 185, 11]],
  },
};

// ---------- grid primitives ----------

export type Grid = string[][];

const blank = (): Grid => Array.from({ length: H }, () => Array(W).fill('.'));
const put = (g: Grid, x: number, y: number, ch: string): void => {
  x = Math.round(x);
  y = Math.round(y);
  if (x >= 0 && x < W && y >= 0 && y < H) g[y][x] = ch;
};
const rect = (g: Grid, x0: number, y0: number, x1: number, y1: number, ch: string): void => {
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) put(g, x, y, ch);
};
const ell = (g: Grid, cx: number, cy: number, rx: number, ry: number, ch: string): void => {
  for (let y = Math.ceil(cy - ry); y <= Math.floor(cy + ry); y++)
    for (let x = Math.ceil(cx - rx); x <= Math.floor(cx + rx); x++) {
      const dx = (x - cx) / rx,
        dy = (y - cy) / ry;
      if (dx * dx + dy * dy <= 1.0) put(g, x, y, ch);
    }
};
const stroke = (
  g: Grid,
  pts: Array<[number, number]>,
  r: number | [number, number],
  ch: string,
): void => {
  for (let i = 0; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i],
      [x1, y1] = pts[i + 1];
    const n = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0)) * 4 + 1;
    for (let k = 0; k <= n; k++) {
      const t = k / n;
      const rr = Array.isArray(r) ? r[0] + (r[1] - r[0]) * ((i + t) / (pts.length - 1)) : r;
      ell(g, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, rr, rr, ch);
    }
  }
};

// Draws `paint(scratch)` and copies it onto `g` ONLY where `g` already holds
// one of `only`. This is what keeps the king's marbling and horn veins from
// becoming silhouette: a stray pixel on transparent background would be
// wrapped by the outline pass, and one on the border ring would fail the
// 3,960-combination sweep.
function paintInside(g: Grid, only: string[], paint: (t: Grid) => void): void {
  const t = blank();
  paint(t);
  const allowed = new Set(only);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      if (t[y][x] !== '.' && allowed.has(g[y][x])) g[y][x] = t[y][x];
    }
  }
}

// the outline pass: any transparent pixel touching body becomes O.
// ⚠ 8-CONNECTED, NOT 4 — see DECISIONS.md §6 for why.
const NEIGHBOURS: Array<[number, number]> = [
  [1, 0], [-1, 0], [0, 1], [0, -1],
  [1, 1], [1, -1], [-1, 1], [-1, -1],
];

function outlinePass(g: Grid): Grid {
  const out = g.map((r) => r.slice());
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      if (g[y][x] !== '.') continue;
      let touch = false;
      for (const [dx, dy] of NEIGHBOURS) {
        const nx = x + dx,
          ny = y + dy;
        if (nx < 0 || nx >= W || ny < 0 || ny >= H) continue;
        if (g[ny][nx] !== '.' && g[ny][nx] !== 'O') {
          touch = true;
          break;
        }
      }
      if (touch) out[y][x] = 'O';
    }
  }
  return out;
}

// ---------- the bull ----------
//
// ⚠ THE OUTLINE PASS CANNOT WRITE OUTSIDE THE GRID — see DECISIONS.md §6.
// ⚠ CX IS THE FRAME'S CENTRE COLUMN. The owner's note was "they need to be
// CENTERED in the frame", so the bull's axis of symmetry and the tile's centre
// are the same column, and `assertCentred()` proves it on every sweep.
export const CX = (W - 1) / 2; // body centre column == the frame's centre
export const HY = 15; // skull centre row
// centre row of the pale muzzle pad. The nostrils are positioned off THIS, not
// off HY, so the snout and the nostrils cannot drift apart.
export const MUZZLE_CY = HY + 6;
// The weapon sits a FIXED offset right of centre, and that offset IS §6's
// clearance rule. It was 21, which measured out at ONE clear column for the
// pitchfork bar and the maul head and ZERO for the morningstar — the exact
// cases §6 names and the owner has reported tangling on twice. 22 makes the
// rule true as written. See `generator/bull.mjs` for the measurements.
export const SX = CX + 22; // weapon shaft column (held vertical, right side)
export const FIST: [number, number] = [SX - 2, 36];

// ⚠ FAILS AT IMPORT, not at render time — every consumer inherits the
// guarantee instead of re-deriving it.
if (!Number.isInteger(CX)) {
  throw new Error(`bull.ts: W=${W} must be ODD so the symmetric bull has a centre COLUMN (CX=${CX})`);
}
if (CX * 2 !== W - 1) {
  throw new Error(`bull.ts: CX=${CX} is not the centre of a ${W}-wide grid`);
}
if (MARGIN + CX !== (TILE_W - 1) / 2) {
  throw new Error(`bull.ts: the bull is centred in the GRID but not in the ${TILE_W}px TILE`);
}

function drawHorns(g: Grid): void {
  for (const dir of [-1, 1]) {
    const p = (dx: number, y: number): [number, number] => [CX + dir * dx, y];
    stroke(g, [p(6, 14), p(10, 12), p(13, 9.5), p(14, 6), p(13.6, 3)], [3.6, 1.2], 'C');
    stroke(g, [p(7, 15.5), p(10.5, 13.5), p(12.5, 11.5)], [1.6, 0.7], 'c');
  }
}

// KING ONLY. A gold vein up each horn, masked to horn pixels so the sweep's
// outline is untouched. `§8` lists gold-veined horns as a planned legendary
// tell; giving it to the 1/1 alone is what makes it a 1/1 tell.
function drawHornVeins(g: Grid): void {
  paintInside(g, ['C', 'c'], (t) => {
    for (const dir of [-1, 1]) {
      const p = (dx: number, y: number): [number, number] => [CX + dir * dx, y];
      stroke(t, [p(8, 13.5), p(11, 11), p(13.2, 7.5), p(13.4, 4)], [1.0, 0.6], 'V');
    }
  });
}

// KING ONLY. Wagyu marbling: fine pale fat veins through the hide.
// Deliberately ASYMMETRIC — real marbling is not mirrored. Every streak sits on
// row 30 or below, which keeps the head rows perfectly symmetric for both
// `assertCentred()` and the favicon crop's axis detector.
const MARBLING: Array<[number, number, number]> = [
  [-8, 42, 3], [-5, 44, 2], [-8, 46, 4], [-4, 49, 3], [-7, 51, 2],
  [4, 43, 3], [7, 45, 2], [3, 47, 4], [6, 50, 3], [4, 52, 2],
  [-13, 33, 2], [-12, 39, 2],
];

function drawMarbling(g: Grid): void {
  paintInside(g, ['S', 'D'], (t) => {
    for (const [dx, y, len] of MARBLING) rect(t, CX + dx, y, CX + dx + len - 1, y, 'n');
  });
}

// A FIST, not a mitten. The old hand was three overlapping ellipses — the arm's
// end cap, an oversized fist and a wide armour wrist wrap on top — which fused
// into one 7x9 lump. On the gold palettes that read as a detached mitten, which
// is what the owner flagged on Lord Wagyu.
function drawFist(g: Grid, x: number, y: number): void {
  ell(g, x, y, 2.6, 2.4, 'S');
  // knuckles, INSET. A full-width dark row reads as a slot cut through the hand.
  rect(g, x - 1, y - 1, x + 1, y - 1, 'D');
}

// drawn FIRST so it sits behind everything.
const capeSpread = (y: number): number => Math.min(14, 10 + Math.round((y - 26) * 0.24));

function drawCape(g: Grid): void {
  for (let y = 26; y <= 47; y++) {
    const s = capeSpread(y);
    rect(g, CX - s, y, CX + s, y, 'K');
  }
  // ragged hem
  for (const dx of [-13, -8, -3, 2, 7, 12]) rect(g, CX + dx, 48, CX + dx + 2, 49, 'K');
  // fold shading down both edges so it doesn't read as a flat slab
  for (let y = 28; y <= 47; y++) {
    const s = capeSpread(y);
    rect(g, CX - s + 1, y, CX - s + 2, y, 'k');
    rect(g, CX + s - 2, y, CX + s - 1, y, 'k');
  }
}

function drawBody(g: Grid): void {
  // --- legs, gap down the middle so the outline pass separates them ---
  for (const dir of [-1, 1]) {
    const x0 = dir < 0 ? CX - 9 : CX + 3;
    rect(g, x0, 41, x0 + 6, 51, 'S');
    rect(g, x0, 47, x0 + 6, 51, 'D');
    rect(g, x0 - 1, 51, x0 + 7, 54, 'C'); // hoof
    rect(g, x0 - 1, 54, x0 + 7, 54, 'c');
  }

  // --- torso ---
  ell(g, CX, 34, 9, 8, 'S');
  rect(g, CX - 9, 34, CX + 9, 41, 'S');
  ell(g, CX, 37, 5.5, 4.5, 'B');
  ell(g, CX - 9, 36, 2.6, 5.5, 'D');
  ell(g, CX + 9, 36, 2.6, 5.5, 'D');

  // --- arms, swung clear of the torso ---
  stroke(g, [[CX - 9, 29], [CX - 11, 34], [CX - 11, 39]], [3.8, 2.8], 'S');
  drawFist(g, CX - 11, 40); // left fist
  // right arm reaches further out than the left so the weapon clears the horn.
  // ⚠ it ends at FIST[1]-2, not -3: the forearm must OVERLAP the fist or the
  // hand reads as a lump hanging below the wrist.
  stroke(g, [[CX + 9, 29], [CX + 13, 32], [FIST[0], FIST[1] - 2]], [3.8, 2.6], 'S');
  rect(g, CX - 9, 31, CX - 9, 39, 'D');
  rect(g, CX + 9, 31, CX + 9, 37, 'D');
  // carve a transparent notch between forearm and torso — the outline pass then
  // draws a hard edge down BOTH sides, which is what makes the arms read.
  for (const dir of [-1, 1]) rect(g, CX + dir * 10, 32, CX + dir * 10, 40, '.');

  // --- neck: narrow and dark, so the skull reads as its own mass ---
  rect(g, CX - 5, 24, CX + 5, 29, 'D');
  rect(g, CX - 4, 24, CX + 4, 28, 'S');

  // ears deliberately omitted — see DECISIONS.md §6.

  // --- skull ---
  ell(g, CX, HY, 9, 7.5, 'S');
  ell(g, CX, HY - 4, 6.5, 2.8, 'L'); // crown highlight
  // snout sits inside the lower skull and protrudes barely
  ell(g, CX, MUZZLE_CY - 1, 5.4, 3.2, 'B');
  ell(g, CX, MUZZLE_CY, 4.4, 2.0, 'L');
  rect(g, CX - 5, HY + 2, CX + 5, HY + 2, 'D'); // muzzle shelf shadow
  rect(g, CX - 2, HY + 1, CX + 2, HY + 2, 'D'); // nose bridge
}

function drawFace(g: Grid): void {
  // brow ridge: a solid dark mass with an angled lower edge.
  for (let i = 0; i <= 7; i++) {
    const drop = Math.floor(i / 2);
    for (const dir of [-1, 1]) {
      const x = CX + dir * (9 - i);
      rect(g, x, HY - 5 + drop, x, HY - 2 + drop, 'R');
      put(g, x, HY - 1 + drop, 'O');
    }
  }
  // furrow between the brows — the classic angry tell
  for (const dir of [-1, 1]) rect(g, CX + dir, HY - 3, CX + dir, HY - 1, 'O');
  // eye sockets punched dark, then a bright iris inside
  for (const dir of [-1, 1]) {
    const ex = CX + dir * 6;
    rect(g, ex - 2, HY - 1, ex + 2, HY + 1, 'P'); // socket, 1px proud of the eye
    rect(g, ex - 1, HY, ex + 1, HY, 'E');
    put(g, ex - dir * 1, HY, 'P'); // pupil to the inside
  }
  // nostrils — TWO of them, set into the pale muzzle pad.
  //
  // 🔴 THE LEFT ONE WAS NEVER DRAWN. The old line was
  //     rect(g, CX + dir*3, HY+4, CX + dir*3 + dir, HY+5, 'P')
  // and `rect` iterates x0..x1 ASCENDING, so on dir = -1 it got (CX-3 .. CX-4),
  // an empty range. Every bull rendered with ONE nostril on an otherwise
  // mirror-symmetric face. Never pass a signed offset as a rect's right edge.
  //
  // One pixel each, at CX±2, on the muzzle HIGHLIGHT `L` — which is a lightened
  // hide colour on every band, so it never approaches `P` even on epic's
  // near-black obsidian. Four shapes were rendered at 28x across the darkest
  // and lightest hide of every band before this one was chosen.
  for (const dir of [-1, 1]) put(g, CX + dir * 2, MUZZLE_CY, 'P');
  // mouth, and small tusks hooking up at the corners
  rect(g, CX - 3, HY + 7, CX + 3, HY + 7, 'O');
  for (const dir of [-1, 1]) {
    put(g, CX + dir * 4, HY + 7, 'O');
    put(g, CX + dir * 5, HY + 6, 'T');
    put(g, CX + dir * 5, HY + 5, 'T');
  }
}

function drawArmour(g: Grid, tier: Band): void {
  // pauldrons — kept small so the upper arm stays visible below them
  for (const dir of [-1, 1]) {
    ell(g, CX + dir * 10, 29, 4.4, 2.9, 'A');
    ell(g, CX + dir * 10, 28, 3.2, 1.5, 'a');
    rect(g, CX + dir * 13, 31, CX + dir * 13, 32, 'O'); // shoulder/arm break
  }
  // chest plate: one clean shape, trim along the top edge
  rect(g, CX - 7, 31, CX + 7, 37, 'A');
  rect(g, CX - 6, 38, CX + 6, 38, 'A');
  rect(g, CX - 7, 31, CX + 7, 31, 'a');
  // centre boss — the BNB diamond on legendary, a plain stud everywhere else
  if (tier === 'legendary') {
    for (let i = 0; i <= 3; i++) {
      rect(g, CX - i, 31 + i, CX + i, 31 + i, 'G');
      rect(g, CX - i, 37 - i, CX + i, 37 - i, 'G');
    }
    put(g, CX, 34, 'a');
  } else {
    ell(g, CX, 34, 2.6, 2.4, 'a');
  }
  // belt + buckle
  rect(g, CX - 9, 39, CX + 9, 41, 'A');
  rect(g, CX - 3, 38, CX + 3, 41, 'G');
  // wrist wraps — a narrow cuff ON the forearm, above the knuckles. These were
  // wide ellipses that overlapped the fist and the arm's end cap and welded all
  // three into the "mitten".
  rect(g, CX - 13, 36, CX - 9, 37, 'a');
  rect(g, FIST[0] - 2, FIST[1] - 4, FIST[0] + 2, FIST[1] - 3, 'a');
}

// weapons are held VERTICAL at the right side and pass through the fist, so the
// grip always reads. shaft runs down column SX; the head sits up at y 4..20.
function drawWeapon(g: Grid, display: string): void {
  const kind = WEAPON_KIND[display] || display;
  const shaft = (top: number, bot = 48, ch = 'W'): void => rect(g, SX - 1, top, SX, bot, ch);
  if (kind === 'club') {
    shaft(19);
    rect(g, SX - 2, 7, SX + 4, 19, 'W');
    for (const [x, y] of [[SX, 10], [SX + 2, 14], [SX, 17]] as Array<[number, number]>)
      ell(g, x, y, 1.3, 1.3, 'm');
  } else if (kind === 'trident') {
    // 1px haft, uniquely — see DECISIONS.md §6.
    rect(g, SX, 13, SX, 48, 'M');
    rect(g, SX - 2, 11, SX + 2, 12, 'M');
    for (const dx of [-2, 0, 2]) {
      rect(g, SX + dx, 4, SX + dx, 11, 'M');
      put(g, SX + dx, 4, 'm');
    }
  } else if (kind === 'axe') {
    shaft(12);
    ell(g, SX + 3, 14, 5.4, 6.2, 'M');
    ell(g, SX - 1, 14, 4.2, 5.2, '.');
    ell(g, SX + 4, 14, 3.4, 4.0, 'm');
  } else if (kind === 'sword') {
    rect(g, SX - 4, 33, SX + 3, 34, 'G'); // crossguard at the hand
    rect(g, SX - 1, 9, SX, 32, 'M');
    rect(g, SX - 1, 10, SX - 1, 32, 'm');
    put(g, SX - 1, 8, 'M');
    put(g, SX, 8, 'M');
    rect(g, SX - 1, 35, SX, 38, 'G'); // pommel
  } else if (kind === 'spear') {
    shaft(9);
    rect(g, SX - 2, 7, SX + 1, 10, 'M');
    rect(g, SX - 1, 4, SX, 7, 'M');
    put(g, SX, 5, 'm');
  } else if (kind === 'bow') {
    stroke(g, [[SX - 1, 9], [SX + 4, 19], [SX + 4, 35], [SX - 1, 45]], 1.6, 'W');
    stroke(g, [[SX - 1, 9], [SX - 2, 27], [SX - 1, 45]], 0.6, 'm');
  } else if (kind === 'dagger') {
    rect(g, SX - 3, 33, SX + 2, 34, 'G');
    rect(g, SX - 1, 23, SX, 32, 'M');
    put(g, SX - 1, 22, 'm');
    put(g, SX, 22, 'm');
  } else if (kind === 'flail') {
    shaft(26);
    stroke(g, [[SX, 25], [SX + 3, 19]], 0.6, 'm');
    // 🔴 the head sat on SX+2, putting its LEFT SPIKE on SX-3 — one column past
    // §6's floor, and the only weapon in the catalog breaking its own clearance
    // rule. Measured, its outline and the horn's were touching.
    ell(g, SX + 3, 14, 3.8, 3.8, 'm');
    for (const [dx, dy] of [[0, -5], [5, 0], [0, 5], [-5, 0]] as Array<[number, number]>)
      put(g, SX + 3 + dx, 14 + dy, 'M');
  } else if (kind === 'scythe') {
    shaft(9);
    // blade sweeps AWAY from the body — see DECISIONS.md §6.
    stroke(g, [[SX + 1, 10], [SX + 5, 6], [SX + 7, 10]], [1.9, 0.7], 'M');
  } else if (kind === 'kingpike') {
    // ── the Gilded Pike — slot 11, king only (§34). ──────────────────────
    // Replaces the Gilded Prod, which drew as a wooden shaft plus a gold ball:
    // a mop, and the only brown thing on the 1/1.
    //
    // ⚠ A BOW WAS TRIED FIRST AND REJECTED ON THE RENDER — four designs, all
    // of which read as a LEAF, because a vertically-held bow is an almond and
    // this engine's outline pass is heavy, uniform and 8-connected. The rest
    // of the catalog speaks SHAFT + HEAD, which is why the others read at
    // 56px. Full note in `generator/bull.mjs`.
    rect(g, SX - 1, 13, SX, 48, 'M'); // shaft — metal, no wood
    rect(g, SX - 1, 13, SX - 1, 48, 'm'); // shaft shadow, body side
    rect(g, SX - 1, 3, SX, 13, 'M'); // blade spine
    rect(g, SX - 2, 6, SX + 1, 12, 'M'); // blade body
    rect(g, SX - 1, 6, SX - 1, 12, 'm');
    put(g, SX - 2, 9, 'G');
    put(g, SX + 1, 9, 'G'); // gilt glints at the widest point
    rect(g, SX - 2, 14, SX + 1, 15, 'G'); // collar
    rect(g, SX - 1, 45, SX, 47, 'G'); // butt cap
    // the pennant. ⚠ its far corner lands on SX+8 = W-2, so its OUTLINE sits on
    // the border ring — legal, and exactly as tight as the sledge.
    for (const [y, len] of [[16, 8], [17, 8], [18, 8], [19, 7], [20, 6], [21, 5], [22, 3]] as Array<
      [number, number]
    >) {
      rect(g, SX + 1, y, SX + len, y, 'Y');
    }
    rect(g, SX + 6, 21, SX + 8, 22, 'Y'); // swallowtail
    rect(g, SX + 7, 23, SX + 8, 24, 'Y');
    rect(g, SX + 1, 16, SX + 2, 22, 'y'); // fold, against the shaft
  } else if (kind === 'boomerang') {
    stroke(g, [[SX - 1, 11], [SX + 4, 19], [SX - 1, 27]], 1.8, 'W');
    put(g, SX - 1, 11, 'G');
    put(g, SX - 1, 27, 'G');
    shaft(29);
  } else if (kind === 'crossbow') {
    shaft(17, 42, 'W');
    rect(g, SX - 2, 17, SX + 5, 18, 'M');
    stroke(g, [[SX - 2, 16], [SX + 1, 22], [SX + 5, 16]], 0.5, 'm');
    rect(g, SX - 1, 9, SX, 17, 'M');
    put(g, SX - 1, 8, 'm');
    put(g, SX, 8, 'm');
  }
}

// ⚠ THE COLOUR PAIR IS CHOSEN BY SLOT, NOT BY ACCESSORY. `derivePalette` loads
// accessory 0 into H/h and accessory 1 into J/j; drawing every accessory with a
// hardcoded 'H'/'h' is what made a second accessory wear the first one's
// colours. `P` is this accessory's primary char, `S` its secondary.
function drawAccessories(g: Grid, kinds: string[], king = false): void {
  for (let i = 0; i < kinds.length; i++) {
    const k = kinds[i];
    const P = i === 0 ? 'H' : 'J';
    const S = i === 0 ? 'h' : 'j';
    if (k === 'horncaps') {
      for (const dir of [-1, 1]) {
        ell(g, CX + dir * 13.6, 3.6, 2.4, 2.8, P);
        ell(g, CX + dir * 13.6, 2.8, 1.4, 1.5, S);
      }
    } else if (k === 'ringnose') {
      ell(g, CX, HY + 12, 3.2, 2.8, P);
      ell(g, CX, HY + 12, 1.8, 1.5, '.');
      put(g, CX, HY + 9, S);
    } else if (k === 'bandana') {
      rect(g, CX - 9, HY - 8, CX + 9, HY - 6, P);
      rect(g, CX - 9, HY - 6, CX + 9, HY - 6, S);
      rect(g, CX + 9, HY - 7, CX + 13, HY - 6, P);
      put(g, CX + 13, HY - 5, S);
    } else if (k === 'shades') {
      rect(g, CX - 9, HY - 2, CX + 9, HY - 2, P);
      rect(g, CX - 9, HY - 1, CX - 3, HY + 2, P);
      rect(g, CX + 3, HY - 1, CX + 9, HY + 2, P);
      put(g, CX - 8, HY, S);
      put(g, CX + 4, HY, S);
    } else if (k === 'boots') {
      for (const dir of [-1, 1]) {
        const x0 = dir < 0 ? CX - 10 : CX + 2;
        rect(g, x0, 48, x0 + 8, 54, P); // boot over the hoof
        rect(g, x0, 46, x0 + 8, 47, S); // cuff
        rect(g, x0 + 1, 52, x0 + 7, 52, S); // sole line
      }
    } else if (k === 'crown' && king) {
      // THE KING'S CROWN — three broad points with two small ones between, and
      // the only accessory nobody else in the collection can roll. It reads at
      // thumbnail size because it breaks the SILHOUETTE (`§8`). A five-point
      // version in 1px points was rendered against it and read as a comb.
      rect(g, CX - 7, HY - 9, CX + 7, HY - 7, P); // band
      rect(g, CX - 7, HY - 7, CX + 7, HY - 7, S); // lower edge
      for (const [dx, rise] of [[-6, 3], [0, 5], [6, 3]] as Array<[number, number]>) {
        rect(g, CX + dx - 1, HY - 9 - rise, CX + dx + 1, HY - 10, P);
        rect(g, CX + dx - 1, HY - 9 - rise, CX + dx + 1, HY - 9 - rise, S);
      }
      for (const dx of [-3, 3]) {
        rect(g, CX + dx, HY - 11, CX + dx, HY - 10, P);
        put(g, CX + dx, HY - 11, S);
      }
    } else if (k === 'crown') {
      // sits low on the brow between the horns, not up in the horn sweep.
      // ⚠ the band ran CX-6..CX+5 — one column short on the right, so a crowned
      // bull sat half a pixel off its own axis of symmetry.
      for (const dx of [-5, -2, 1, 4]) rect(g, CX + dx, HY - 11, CX + dx + 1, HY - 9, P);
      rect(g, CX - 6, HY - 9, CX + 6, HY - 7, P);
      rect(g, CX - 6, HY - 7, CX + 6, HY - 7, S);
      put(g, CX, HY - 11, S);
    }
  }
}

// nothing may occupy the outermost ring: the outline pass has no pixel outside
// the grid to draw into, so a body pixel there renders with a raw, unoutlined
// edge. returns a description of the first offender, or null when clean.
export function assertBorderClear(g: Grid): string | null {
  const bad = (ch: string): boolean => ch !== '.' && ch !== 'O';
  for (let x = 0; x < W; x++) {
    if (bad(g[0][x])) return `top row: '${g[0][x]}' at x=${x}`;
    if (bad(g[H - 1][x])) return `bottom row: '${g[H - 1][x]}' at x=${x}`;
  }
  for (let y = 0; y < H; y++) {
    if (bad(g[y][0])) return `left column: '${g[y][0]}' at y=${y}`;
    if (bad(g[y][W - 1])) return `right column: '${g[y][W - 1]}' at y=${y}`;
  }
  return null;
}

// THE CENTRING CHECK. `assertBorderClear` proves nothing leaves the frame;
// this proves the bull SITS IN THE MIDDLE OF IT.
//
// Two facts together are the proof: `CX === (W-1)/2` (asserted at module load)
// and the bull is mirror-symmetric about CX (checked here). It runs to |d| <=
// 17 and rows 0..28 because that is exactly the region where the bull is the
// only thing on the grid — the weapon's leftmost ink is SX-3 = CX+19, and
// below row 28 the right arm reaches out and the cape hem is ragged.
//
// ⚠ Two accessories are legitimately one-sided and must be excluded by the
// CALLER: the bandana's knot tail, and the shades' glint (one pixel in from
// each lens's left edge, so the highlight reads as one light source).
export function assertCentred(g: Grid): string | null {
  for (let y = 0; y <= 28; y++) {
    for (let d = 1; d <= 17; d++) {
      const l = g[y][CX - d],
        r = g[y][CX + d];
      if (l !== r) return `row ${y}: x=${CX - d} is '${l}' but its mirror x=${CX + d} is '${r}'`;
    }
    for (let d = 18; d <= CX; d++) {
      if (g[y][CX - d] !== '.') return `row ${y}: bull ink at x=${CX - d}, ${d} columns from centre`;
    }
  }
  return null;
}

export interface Token {
  id: number;
  band: Band;
  /** #501 only. Unlocks the king's hide, marbling, horn veins and crown. */
  king: boolean;
  name: string;
  skin: SkinEntry;
  eye: EyeEntry;
  weapon: string;
  horn: HornEntry;
  accessories: string[];
  bg: RGB;
  floor: RGB;
}

export function tokenGrid(token: Token): Grid {
  let g = blank();
  if (CAPES[token.band]) drawCape(g); // behind everything
  drawHorns(g);
  if (token.king) drawHornVeins(g);
  drawBody(g);
  if (token.king) drawMarbling(g);
  drawWeapon(g, token.weapon);
  drawFist(g, FIST[0], FIST[1]); // fist over the shaft = gripped
  drawArmour(g, token.band);
  g = outlinePass(g);
  drawFace(g);
  drawAccessories(g, token.accessories, token.king);
  // second pass so accessories that break the silhouette get the same
  // outline as the body — see DECISIONS.md §6.
  g = outlinePass(g);
  return g;
}

// ---------- palette (same ramp maths as fefers derivePalette) ----------

const clampC = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));

export type Palette = Record<string, RGB>;

export function derivePalette(token: Token): Palette {
  const skin = token.skin[1];
  const pal: Palette = { ...FIXED_PALETTE };
  pal.S = skin.map(clampC) as RGB;
  pal.D = skin.map((v) => clampC(v * 0.68)) as RGB;
  pal.L = skin.map((v) => clampC(v * 1.3 + 12)) as RGB;
  pal.B = skin.map((v) => clampC(Math.min(255, v * 1.3 + 12) * 0.45 + 255 * 0.45)) as RGB;
  pal.R = skin.map((v) => clampC(v * 0.5)) as RGB;
  pal.E = token.eye[1];
  const [A, a] = ARMOUR[token.band];
  pal.A = A;
  pal.a = a;
  const cape = CAPES[token.band];
  if (cape) {
    pal.K = cape[0];
    pal.k = cape[1];
  }
  const met = METAL[token.band];
  if (met) {
    pal.M = met.M;
    pal.m = met.m;
    pal.G = met.G;
  }
  if (token.horn) {
    pal.C = token.horn[1];
    pal.c = token.horn[2];
  }
  if (token.accessories.length) {
    // ⚠ EVERY ACCESSORY GETS ITS OWN COLOURS. This used to resolve
    // `accessories[0]` ONLY, into H/h — while `drawAccessories` drew every
    // accessory with H/h. So on a two-accessory roll the second one wore the
    // first one's palette. It was invisible on most bands because the borrowed
    // colour still contrasted the hide, but on legendary ['crown','shades'] the
    // shades were painted in crown-gold over a gold hide and the face was a
    // featureless blob. Slot 0 -> H/h, slot 1 -> J/j; `drawAccessories` picks
    // the pair by index.
    const over = ACC_COLOURS[token.band] || {};
    const resolve = (key: string): [RGB, RGB] | undefined =>
      over[key] || ACC_COLOURS.default[key];
    const first = resolve(token.accessories[0]);
    if (first) {
      pal.H = first[0];
      pal.h = first[1];
    }
    // fall back to the first pair so J/j is ALWAYS a real colour — an
    // undefined palette char renders as background, i.e. a hole in the sprite.
    const second = (token.accessories[1] ? resolve(token.accessories[1]) : undefined) || first;
    if (second) {
      pal.J = second[0];
      pal.j = second[1];
    }
  }
  return pal;
}

// ---------- roll + render ----------

function pickFrom<T>(rng: () => number, arr: T[]): T {
  return arr[Math.floor(rng() * arr.length)];
}

// ⚠ `assignBands()` AND `pickWeighted()` USED TO LIVE HERE. THEY ARE GONE.
//
// `assignBands()` was an LCG fisher-yates over the ID LIST. The chain shuffles
// the TIER ARRAY with Xorshift128+. Different algorithm, different answer, and
// the answer the chain gives is the one a holder owns — 377 of 500 tokens
// disagreed. `pickWeighted()` drew from all twelve weapon weights at once; the
// chain draws only inside the token's own tier slice, so 362 tokens were
// rendered holding a weapon they cannot possibly have.
//
// Use `chainBandMap()` and `chainWeapon()` above. They are deleted rather than
// deprecated deliberately: a named import of a missing export is a hard
// link-time error in ESM and a compile error in TypeScript, which is exactly
// how a mistake this expensive should fail. `npm run verify:rarity` re-checks
// the whole table against the committed map on every run.

export interface RollOverride {
  band?: Band;
  skin?: SkinEntry;
  eye?: EyeEntry;
  weapon?: string;
  horn?: HornEntry;
  accessories?: string[];
  names?: Record<number, string>;
}

export function rollToken(
  id: number,
  bandMap: Record<number, Band>,
  override: RollOverride = {},
): Token {
  const band = override.band || bandMap[id];
  // ⚠ THE KING BRANCHES ON THE TOKEN ID, NOT ON AN OVERRIDE. Every caller asks
  // for #501 with `{ band: 'legendary' }` and none of them should have to know
  // what makes him look like the king. It is also what stops a normal bull ever
  // being handed the king's hide.
  const king = id === KING_ID;
  const rng = lcg(tokenSeed(id));
  // ⚠ the rng call ORDER for ids 1..500 is unchanged; the king takes his
  // cosmetics from constants and simply does not draw.
  const skin = override.skin || (king ? KING_SKIN : pickFrom(rng, SKINS[band]));
  const eye = override.eye || (king ? KING_EYE : EYES[pickFrom(rng, BAND_EYES[band])]);
  // the weapon is CHAIN STATE, not a roll off `tokenSeed`. it deliberately
  // does not touch `rng`, so the cosmetic stream stays independent of it.
  const weapon = override.weapon || chainWeapon(id, band);
  const horn = override.horn || (king ? KING_HORN : pickFrom(rng, HORN_POOLS[band]));
  const clean = rng() < CLEAN_CHANCE[band];
  // the king is never "clean" and never rolls: he wears the crown, always.
  const accessories =
    override.accessories || (king ? ['crown'] : clean ? [] : pickFrom(rng, ACC_POOLS[band]));
  return {
    id,
    band,
    king,
    name: (override.names || {})[id] || `bnbull #${id}`,
    skin,
    eye,
    weapon,
    horn,
    accessories,
    bg: BAND_INFO[band].bg,
    floor: BAND_INFO[band].floor,
  };
}

export function renderTile(token: Token): Uint8ClampedArray {
  const g = tokenGrid(token);
  const pal = derivePalette(token);
  const px = new Uint8ClampedArray(TILE_W * TILE_H * 4);
  const floorY = MARGIN + H - 2;
  for (let y = 0; y < TILE_H; y++) {
    for (let x = 0; x < TILE_W; x++) {
      const c = y >= floorY ? token.floor : token.bg;
      const o = (y * TILE_W + x) * 4;
      px[o] = c[0];
      px[o + 1] = c[1];
      px[o + 2] = c[2];
      px[o + 3] = 255;
    }
  }
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const c = pal[g[y][x]];
      if (!c) continue;
      const o = ((y + MARGIN) * TILE_W + (x + MARGIN)) * 4;
      px[o] = c[0];
      px[o + 1] = c[1];
      px[o + 2] = c[2];
      px[o + 3] = 255;
    }
  }
  return px;
}
