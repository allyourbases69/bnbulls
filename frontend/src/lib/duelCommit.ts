/**
 * The anti-grind brain.
 *
 * ─── THE HOLE THIS CLOSES ───────────────────────────────────────────
 *
 * `/api/run-duel` hands back a fully signed, submittable result — winner
 * included — before a single cent has moved. Stakes are only pulled when the
 * player lands `submitDuel` on chain. So the natural attack is: roll a fight,
 * read `winnerId`, and simply never submit the ones you lost.
 *
 * `Duel.fightSeq` does NOT close this on its own, and it is worth being precise
 * about why, because it looks like it should. The per-wallet sequence
 * guarantees at most one signed result naming a wallet can ever SETTLE. It says
 * nothing about how many get ISSUED. An attacker can ask for twenty fights, all
 * naming seq N, and submit whichever one he liked — the other nineteen simply
 * never land. The sequence makes the affordability check a guarantee (that is
 * its job, see `Duel.sol`); the slot below is what makes the OUTCOME
 * unshoppable.
 *
 * ─── THE FIX, AND THE ONE PLACE IT DIVERGES FROM FEFERS ─────────────
 *
 * Fighting Fefers pinned one standing fight per FIGHTER token. That was correct
 * there, because its commit was per token too. On bnbulls the on-chain commit
 * moved to the WALLET (`DECISIONS.md §16`, `Duel.fightSeq`), so the off-chain
 * slot has to move with it — a per-token slot here would let a wallet holding
 * twenty bulls roll twenty standing fights, all spending seq N, and pick the
 * best one to settle. That is the original exploit with extra steps.
 *
 * So: one standing fight per WALLET, and it does not expire on a clock.
 *
 *   • Ask for a fight and you get one, pinned to challenger, opponent and seed.
 *   • Ask again — with ANY of your bulls, against ANY opponent — and you get
 *     that same fight back: same pair, same seed, same winner, same nonce. Only
 *     the EIP-712 expiry is refreshed, so signed payloads never linger.
 *   • You get a genuinely new fight once the standing one SETTLES ON CHAIN, or
 *     becomes impossible to settle for a reason you do not control (see
 *     `releaseReason`).
 *
 * Detecting "settled" is cheaper and stronger here than it was on fefers, which
 * had to probe `usedNonces`. The commit records the `fightSeq` it was signed
 * against; if the wallet's live sequence has moved past it, a fight naming that
 * wallet has settled and this signature is already dead on arrival
 * (`StaleFightSeq`). One read, and it cannot be faked.
 *
 * ─── WHAT THIS MODULE IS ────────────────────────────────────────────
 *
 * Pure policy: no `viem`, no `next`, no database driver. Storage arrives as a
 * `CommitStore`, so the same decisions run against whatever backing exists.
 * Keep it dependency-free.
 */

/**
 * Liveness backstop. A standing commit that has gone this long unsettled is
 * released even if nothing about it changed.
 *
 * This exists ONLY so a wallet can never be bricked forever by a corner the
 * release rules missed (it ran out of the stake asset, say). It is priced to be
 * useless as an attack: a full day of a wallet benched buys exactly one
 * declined loss, and that wallet earns nothing else in the meantime.
 */
export const COMMIT_BACKSTOP_SECONDS = 24 * 60 * 60;

export interface DuelCommit {
  /** Lowercased wallet this slot belongs to — the authenticated session's. */
  wallet: string;
  /** The bull the wallet sent in. */
  challenger: number;
  /** Who it was matched against. Pinned — re-requesting cannot change it. */
  opponent: number;
  /** Canonical (min, max) ordering, matching what gets signed. */
  tokenA: number;
  tokenB: number;
  /** 0 = tie, otherwise a token id. */
  winnerId: number;
  rounds: number;
  /** Decimal string — these are 256-bit and JSON cannot carry bigint. */
  seed: string;
  newEloA: number;
  newEloB: number;
  nonce: string;
  /**
   * `fightSeq(wallet)` as it stood when this fight was rolled, as a decimal
   * string. THE settlement detector: if the live sequence has moved past it,
   * the fight (or another fight naming this wallet) has landed.
   */
  seq: string;
  /**
   * The blow-by-blow, serialised. Stored rather than re-simulated because a
   * commit outlives stat drift: if the pinned opponent levelled up in between,
   * a re-simulation on the same seed could animate a different winner than the
   * one that is signed. Replaying the stored events keeps what the player
   * watches and what the contract records the same fight.
   */
  eventsJson: string;
  /** Unix seconds the commit was minted. Drives the backstop above. */
  createdAt: number;
}

/** Chain state about a STANDING commit, read fresh on every serve. */
export interface CommitFacts {
  now: number;
  /** The wallet's live `fightSeq`, as a decimal string. */
  liveSeq: string;
  /** The pinned opponent is still a legal target (alive, unlisted). */
  opponentEligible: boolean;
  /** The challenger's own bull is still alive. */
  challengerAlive: boolean;
  /** Lowercased current owner of the pinned opponent. */
  opponentOwner: string;
  /** Is `Duel.allowSelfDuel` on? When it is, `same-owner` stops being a
   *  release reason, because such a fight is submittable after all. */
  allowSelfDuel: boolean;
}

export type ReleaseReason =
  | 'settled'
  | 'opponent-ineligible'
  | 'same-owner'
  | 'challenger-dead'
  | 'backstop';

/**
 * May this standing commit be torn up and replaced with a fresh roll?
 *
 * @returns null to keep it (the caller must then serve it verbatim), or the
 *          reason it is being released.
 *
 * ⚠ EVERY reason here is deliberately outside the challenger's control. That is
 *   the whole safety property. If a challenger could manufacture a release —
 *   by listing their own bull, by moving it to another wallet — they would have
 *   their re-roll back and this file would be decoration. In particular:
 *
 *     - the CHALLENGER's own listing status is NOT a release reason, even
 *       though it blocks `submitDuel`. It is one click to undo, so the fight is
 *       still theirs to settle.
 *     - the OPPONENT's status IS, because the challenger cannot touch it, and
 *       without it a dead or listed opponent would strand the slot.
 *     - `same-owner` covers the challenger BUYING the opponent to free the
 *       slot. It is a real release because `DECISIONS.md §16` makes such a
 *       fight unsubmittable — and it is not an exploit, because buying an NFT
 *       to dodge one loss is a terrible trade. It stops being a release the
 *       moment the owner flips `allowSelfDuel` on, since the fight is legal
 *       again then.
 */
export function releaseReason(c: DuelCommit, f: CommitFacts): ReleaseReason | null {
  // Settlement first: a landed fight beats every other consideration, and this
  // is the branch that makes the slot self-clearing in normal play.
  if (BigInt(f.liveSeq) > BigInt(c.seq)) return 'settled';
  if (!f.opponentEligible) return 'opponent-ineligible';
  if (!f.allowSelfDuel && f.opponentOwner.toLowerCase() === c.wallet.toLowerCase()) {
    return 'same-owner';
  }
  if (!f.challengerAlive) return 'challenger-dead';
  if (f.now - c.createdAt >= COMMIT_BACKSTOP_SECONDS) return 'backstop';
  return null;
}

/* ─── Storage ──────────────────────────────────────────────────────── */

/** One standing commit per challenger WALLET. */
export interface CommitStore {
  get(wallet: string): Promise<DuelCommit | null>;
  put(commit: DuelCommit): Promise<void>;
  del(wallet: string): Promise<void>;
}

/**
 * Process-local store.
 *
 * ⚠ NOT A PRODUCTION SUBSTITUTE, and this is the one thing on this path that is
 *   knowingly incomplete. Serverless instances are ephemeral and do not share
 *   memory, so on Vercel this enforces the slot only against whichever warm
 *   instance answered — an attacker who spreads requests around gets his scan
 *   back. Fighting Fefers backed the same interface with Postgres; bnbulls has
 *   no database wired yet, so `/api/run-duel` logs loudly at startup and the
 *   store is swappable by implementing `CommitStore` and pointing
 *   `commitStore()` at it. **A shared store is required before mainnet.**
 */
export class MemoryCommitStore implements CommitStore {
  private readonly rows = new Map<string, DuelCommit>();

  async get(wallet: string): Promise<DuelCommit | null> {
    return this.rows.get(wallet.toLowerCase()) ?? null;
  }

  async put(commit: DuelCommit): Promise<void> {
    this.rows.set(commit.wallet.toLowerCase(), commit);
  }

  async del(wallet: string): Promise<void> {
    this.rows.delete(wallet.toLowerCase());
  }

  /** Test/debug helper: how many wallets currently hold a standing fight. */
  get size(): number {
    return this.rows.size;
  }
}

/* ─── The decision ─────────────────────────────────────────────────── */

export type CommitDecision =
  | {
      kind: 'serve';
      /** The pinned fight. Serve it VERBATIM — same pair, seed, winner, nonce.
       *  Only the EIP-712 expiry and the stake numbers may be refreshed. */
      commit: DuelCommit;
      /** The caller asked for a different matchup than the one pinned. Say so
       *  in the response rather than silently swapping the portrait. */
      redirected: boolean;
    }
  | {
      kind: 'mint';
      /** Set when a standing fight was torn up to get here, naming why. null
       *  means the slot was simply empty. */
      released: ReleaseReason | null;
    };

/**
 * THE decision. Given the wallet's standing fight (if any) and fresh chain
 * facts about it, may a new outcome be rolled?
 *
 * A pure function taking data rather than something that reaches for a
 * database, so it can be exhaustively tested and `/api/run-duel` has exactly
 * one place that mints — the `kind: 'mint'` branch. `facts` is required
 * whenever `standing` is non-null; passing null there is treated as "no
 * information", which means KEEP the standing fight, because failing safe is
 * the only direction that doesn't hand out a free re-roll.
 */
export function decideCommit(args: {
  standing: DuelCommit | null;
  facts: CommitFacts | null;
  requestedChallenger: number;
  requestedOpponent: number;
}): CommitDecision {
  const { standing, facts } = args;
  if (!standing) return { kind: 'mint', released: null };
  const redirected =
    standing.opponent !== args.requestedOpponent ||
    standing.challenger !== args.requestedChallenger;
  if (!facts) {
    return { kind: 'serve', commit: standing, redirected };
  }
  const reason = releaseReason(standing, facts);
  if (reason === null) {
    return { kind: 'serve', commit: standing, redirected };
  }
  return { kind: 'mint', released: reason };
}
