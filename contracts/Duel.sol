// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Bulls} from "./Bulls.sol";
import {TimelockedAddress} from "./lib/TimelockedAddress.sol";

/// @dev Jackpot surface used by Duel: open a ticket, nudge the queue, and push
///      a dev-cut slice straight in when the cut is already the prize token.
/// @dev ⚠ Names are deliberately unique to this file. Solidity hoists
///      file-level declarations into any file that imports them, so a test
///      importing both `MintDrop.sol` and `Duel.sol` would fail to compile if
///      both declared `IJackpotFund`. Every interface here carries a Duel-
///      specific name for that reason. Do not "tidy" them back to the generic
///      spellings.
interface IDuelJackpot {
    function recordWin(address winner, uint256 tokenId, uint256 entropy, uint256 duelKey)
        external
        returns (uint256 ticketId);
    function resolve(uint256 max) external returns (uint256 resolved);
    function fund(uint256 amount, string calldata source) external;
}

/// @dev MintDrop's Chainlink read. `DECISIONS.md §26` deleted the stablecoin
///      and with it the dollar anchor the BNB stake price used to be derived
///      from, so the anchor is now `usdFightPrice1e18` here and this is the
///      feed side of the conversion (`§1`, option A).
///
///      Why MintDrop rather than a `Wire.PriceFeed` of Duel's own: it deploys
///      alongside this contract, is wired to the SAME aggregator, and already
///      owns the staleness / sanity-band policy that `§1` demands. A second
///      feed wire here would mean a second, independently-drifting staleness
///      rule for the same price — and `bnbUsdPrice()` REVERTS on a stale
///      round, a non-positive answer, an incomplete round or an out-of-band
///      price, so that revert is exactly the behaviour to inherit rather than
///      re-implement. Nothing is clamped, at either end.
interface IMintDropOracle {
    function bnbUsdPrice() external view returns (uint256 price1e18);
}

/// @dev Marketplace read. Declared here rather than imported to avoid a
///      circular dependency (Marketplace already references Bulls).
interface IMarketplaceListing {
    function isListed(uint256 tokenId) external view returns (bool);
}

/// @dev The yards roster (`Yards.sol`) — arena membership, per bull, bound to
///      the live owner. One question, one staticcall, answered out of storage
///      alone so it can never fault a fight.
/// @dev Both live owners are passed IN rather than looked up, because
///      `submitDuel` has already read them and a second `ownerOf` pair would be
///      two more cold reads for an answer it is holding.
interface IDuelYards {
    function fightBlocked(uint256 tokenA, address ownerA, uint256 tokenB, address ownerB)
        external
        view
        returns (uint256 blockedToken);
}

/// @dev Wrapped BNB. `deposit()` is a 1:1 wrap — no router, no liquidity, no
///      slippage — which is why a native-BNB stake still costs the player
///      nothing extra and still settles as an ERC-20.
interface IWrappedBNB is IERC20 {
    function deposit() external payable;
}

/**
 * @title Duel
 * @notice The signed-result PvP engine for bnbulls. It VERIFIES a duel, it
 *         does not fight one: the off-chain simulator decides the winner, the
 *         rounds and both new ELOs, signs the whole result EIP-712, and this
 *         contract checks the signature, settles the stakes, applies the state
 *         and opens the jackpot tickets.
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      NO COMBAT ON CHAIN — AND THAT IS THE DESIGN, NOT A SHORTCUT
 *      ══════════════════════════════════════════════════════════════════════
 *      `submitDuel` does `ECDSA.recover(hashDuelResult(result), sig) ==
 *      trustedSigner` and checks `winnerId ∈ {0, tokenA, tokenB}`. It never
 *      re-runs the sim. ELO uses `10^((B-A)/400)` in TypeScript; a Solidity
 *      re-implementation would diverge on rounding from the very numbers the
 *      UI showed the player, so the signer signs its own arithmetic instead.
 *
 *      What that buys: the signed struct covers tokenA/tokenB/winnerId/rounds/
 *      seed/elo/assets/stakes/seqs/nonce/expiry — and NOT the per-round events
 *      or HP. So the simulator can change freely (a phase-2 bonded calf, a
 *      re-tuned weapon table) and every outstanding signature stays valid, as
 *      long as the struct SHAPE is unchanged and `winnerId` stays in the set.
 *      Seeds and outcomes are public, so anyone can re-run a fight and catch a
 *      lying signer.
 *
 *      ⚠ THE EIP-712 DOMAIN IS SET **BEFORE** THE FIRST DEPLOY. Fighting
 *      Fefers still carries "Stable WarriorsDuel" scars in its sweeps because
 *      the domain was renamed after launch and every old signature died with
 *      it. `"BNBullsDuel"` / version `"1"` are final; the signer in
 *      `api/run-duel` must carry the identical pair in the SAME commit, and
 *      `DUEL_RESULT_TYPEHASH` below must stay byte-identical to the `types`
 *      array it hands viem.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE AFFORDABILITY HOLE, CLOSED — PER-WALLET FIGHT SEQUENCE
 *      ══════════════════════════════════════════════════════════════════════
 *      `BNBULLS-BOOTSTRAP.md §5` describes the fefers latent revert: the
 *      one-fight-per-token commit pinned one signed outcome per BULL, not per
 *      WALLET. Two bulls in one wallet could each hold a signed fight drawing
 *      on the same balance. Both passed the signer's affordability snapshot,
 *      the first to settle took the money, the second reverted deep inside
 *      `ERC20: transfer amount exceeds balance`. The fix on Stable was a
 *      client-side re-check, so the exposure never actually closed.
 *
 *      Here the commit is PER WALLET and it is enforced on chain. Every
 *      address carries a `fightSeq`. The signed result names the sequence
 *      number each side is spending (`seqA`, `seqB`); settlement requires an
 *      exact match and bumps it. The consequence is the whole point:
 *
 *        **at most one signed result naming a given wallet can ever settle.**
 *
 *      The moment one lands, every other outstanding signature naming that
 *      wallet is dead on arrival — it carries a stale sequence and reverts
 *      `StaleFightSeq` BEFORE a single token moves. The signer's affordability
 *      check stops being a hopeful snapshot and becomes a guarantee: nothing
 *      else can spend that balance in between.
 *
 *      Why this shape and not the alternatives:
 *        - A *balance reservation at sign time* cannot be done on chain —
 *          signing is an off-chain event and nothing reserves anything without
 *          a transaction. Making the player send one turns every fight into
 *          two transactions.
 *        - An *escrowed arena purse* (deposit, fight from the balance) moves
 *          the failure from `ERC20: balance` to `InsufficientCredit` without
 *          removing it, and costs a deposit/withdraw UX plus the bytecode.
 *        - A *parallelism window* (allow N open fights per wallet) was
 *          considered and rejected: consuming sequence numbers out of order
 *          reintroduces exactly the ambiguity about which signature is live
 *          that this mechanism exists to remove.
 *
 *      The cost, stated plainly: **one wallet has one fight in flight at a
 *      time.** A holder with twenty bulls fights them in sequence, not in
 *      parallel, and a passive opponent picked by two players at once resolves
 *      one of them. That is a re-quote, not a lost stake, and the API can see
 *      it coming by reading `fightSeq` before it signs. Nothing expires
 *      awkwardly either: an unsubmitted result simply lapses at `expiry` and
 *      the same sequence number is re-signed.
 *
 *      On top of that, `_takeSide` checks balance AND allowance explicitly and
 *      reverts `StakeUnaffordable` / `StakeNotApproved` with the numbers in
 *      the error, so the residual "the player moved their own money" case is
 *      legible in a wallet simulation instead of an opaque ERC-20 string.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      NO SELF-DUELS — `allowSelfDuel`, DEFAULT OFF (owner, 2026-08-06)
 *      ══════════════════════════════════════════════════════════════════════
 *      Two bulls in the same wallet may not fight, and the check is made HERE,
 *      at settlement, against live `ownerOf` reads. An off-chain check in
 *      `api/run-duel` is not enough: a bull can change hands between the
 *      signature being issued and the result being submitted, so only the
 *      on-chain read at settle time is binding.
 *
 *      Two reasons, and the second is the one that actually bites:
 *        - ECONOMIC. An owner alternating wins between two of their own bulls
 *          keeps both alive forever, pays only the dev cut, and buys a
 *          full-odds ticket on a pot everybody else funded. Once a pot clears
 *          real money that is unboundedly +EV, and the ticket is a self-duel's
 *          only real output — the purse just moves from one hand to the other.
 *        - COLLECTION SAFETY. `KEEPER-FLEET-AND-OPS.md` records the fefers
 *          autoplay bot killing 34 of 60 bulls before its opponent-protection
 *          bug was found: it kept picking the softest, already-losing bull and
 *          delivering the killing blow. This flag is the structural version of
 *          that protection, enforced by the bytecode rather than trusted to
 *          every bot anyone ever writes.
 *
 *      `allowSelfDuel` is a plain owner switch (a policy flag, not a wiring
 *      leg) and defaults to FALSE so the safe behaviour is the one that
 *      happens if the configuration transaction is never sent. Flipping it on
 *      composes with the per-wallet sequence above without a special case: the
 *      two sequence numbers are then both that wallet's, consumed in order, so
 *      the signer names `seq` and `seq + 1`.
 *
 *      This flag NARROWS the affordability case but does not close it, which
 *      is why the per-wallet sequence exists as well: two of my bulls fighting
 *      two DIFFERENT opponents still draw on one balance.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      NO CONSENT, NO FIGHT — THE YARDS (`Yards.sol`), Wire.Yards
 *      ══════════════════════════════════════════════════════════════════════
 *      A bull may only be fought while its CURRENT owner has explicitly sent
 *      it into the yards. Checked here, at settlement, off the same live
 *      `ownerOf` pair every other ownership rule uses.
 *
 *      Before that wire existed, arena membership was the ERC-20 ALLOWANCE —
 *      `_takeSide` says so itself, "A passive opponent stakes by allowance,
 *      always". It gated the wrong thing in two ways. It is WALLET-WIDE, so
 *      one `approve` sent to fight a common also volunteered the legendary
 *      sitting beside it. And **a zero-stake duel skips it entirely**:
 *      `_takeSide` returns on `stake == 0` BEFORE it reads any allowance, so a
 *      fight with no assets and no stakes touches nothing a holder controls,
 *      yet still runs `applyDuelResult`, still moves ELO, still increments
 *      `consecutiveLosses` — and the `lossesToDie`-th consecutive loss kills.
 *      `DECISIONS.md §25` stopped such a fight buying a jackpot TICKET; it did
 *      not stop it killing a bull. Only the signer's off-chain policy did, and
 *      `§16` is the standing ruling that a protection which matters belongs in
 *      the bytecode, not in whatever bot happens to be running.
 *
 *      ⚠ THE CHECK IS UNCONDITIONAL, WHICH IS THE POINT. It sits in
 *      `submitDuel`, not in `_takeSide`, so it covers the staked path and the
 *      free path identically. A promotional zero-stake fight is still legal —
 *      against a bull whose owner put it in the yards.
 *
 *      ⚠ AN EJECT IS DELAYED AND THAT IS DELIBERATE. The owner's requirement
 *      is "eject if not in a fight and haven't paid the money". A signed
 *      result carries `winnerId` and BSC's mempool is public, so an instant
 *      eject would let a losing side front-run the submission and delete the
 *      loss — every fight becomes optional, and only wins land. `Yards` gives
 *      leaving a floor of 15 minutes, which is `MAX_DUEL_EXPIRY_SECONDS` in
 *      the signer, so every signature that could name the bull has expired by
 *      the time the eject bites. `fightSeq` does NOT cover this: it bounds how
 *      many results can settle, not whether a particular one does, and it is
 *      consumed at settlement so nothing on chain marks a wallet as busy.
 *
 *      An UNWIRED slot means no check — the same shape as `marketplace`. That
 *      is a deploy-preflight obligation, not a shrug: `Wire.Yards` must be
 *      bootstrapped before the first duel is signed or the eject is decorative.
 *      A future escrowing router must enter the bulls it holds; it becomes
 *      their live owner, so it can, and no carve-out is needed here.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      STAKE ASSETS: BNB AND BNBULL (`DECISIONS.md §26`)
 *      ══════════════════════════════════════════════════════════════════════
 *      Registered assets are ordinary ERC-20s with a one-shot per-asset
 *      ceiling and a per-asset dev cut. **BNB is staked as WBNB**, and a
 *      player never has to wrap it themselves: send BNB with `submitDuel` and
 *      the contract wraps exactly what your side owes, refunding the rest.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ HOW THE BNB STAKE IS PRICED, AND WHY IT CHANGED
 *      ══════════════════════════════════════════════════════════════════════
 *      Until `DECISIONS.md §26` this contract had NO dollar figure of its own.
 *      The signer derived one off chain: it took "the registered fight asset
 *      that is neither BNBULL nor WBNB" — the stablecoin — rescaled its
 *      `fightCostOf` peg to 1e18 as the dollar sticker, and converted that
 *      through `MintDrop.bnbUsdPrice()`. **Dropping the stablecoin deletes that
 *      anchor.**
 *
 *      Deleting it and doing nothing else would leave BNB fights priced by
 *      `fightCostOf[wbnb]` — a flat number a keeper wrote at some point in the
 *      past, with NO freshness guarantee anywhere in the bytecode. On Stable
 *      that was harmless because the gas token WAS the dollar. On BNB it
 *      drifts, and a "$5 fight" quietly becomes a $2 fight or a $12 one between
 *      keeper writes. That is precisely the failure `§1` option A exists to
 *      prevent, and `§3` names it: a mechanical USDT0->BNB rename produces code
 *      that compiles and is economically wrong.
 *
 *      So the dollar figure is now **stored explicitly** — `usdFightPrice1e18`,
 *      one 1e18-scaled sticker per fighter — and the WBNB leg is DERIVED from
 *      it through the Chainlink feed, on chain, in `fighterCost`:
 *
 *          sticker -> BNB      ceil(usdFightPrice1e18 * 1e18 / bnbUsdPrice())
 *          then the discount   * (BPS - discountBpsOf[wbnb]) / BPS
 *
 *      **Sticker first, discount second.** Taking the discount off the dollar
 *      anchor AND again off the BNB result is the same double-discount trap
 *      documented on `fightCostOf` below, and it would hand out 19% on a 10%
 *      setting. There is exactly one place the discount is applied.
 *
 *      `setFightCost` therefore REFUSES WBNB: a stored peg for an
 *      oracle-derived asset is a second source of truth whose only future is to
 *      disagree with the first. `fightCostOf[wbnb]` reads zero, forever, and
 *      that is honest — there is no stored peg.
 *
 *      What did NOT change: settlement still charges `stakeA`/`stakeB` exactly
 *      as signed, so the price the API quoted and the UI displayed is still the
 *      price the wallet pays, and ordinary BNB volatility between quote and
 *      submit still cannot revert an honest fight. The pay-time bound on that
 *      number is `maxFightCostOf[asset]` — one-shot at registration, immutable
 *      after, and re-checked in `_takeSide` — which is the ceiling a
 *      compromised owner key, a lying keeper and a stale oracle all run into
 *      alike.
 *
 *      ⚠ Why the pot settles in WBNB rather than raw BNB, spelled out because
 *      it looks like a cosmetic choice and is not. The winner takes BOTH
 *      sides' stakes. A raw-BNB payout is a `.call{value:}` to whoever won,
 *      and a winner that is a contract with a reverting `receive()` would
 *      revert the whole duel — a griefing vector that settles nothing and
 *      kills the fight. `safeTransfer` cannot be refused. This is the same
 *      reasoning that makes the second Jackpot a WBNB pot; see `Jackpot.sol`.
 *      The native leg is therefore convenience on the way IN only, where the
 *      payer is `msg.sender` and a refund failure is their own contract's bug.
 *
 *      A stake can only be pulled from a PASSIVE opponent by allowance, and
 *      raw BNB cannot grant one — so a side that is not `msg.sender` stakes
 *      WBNB or BNBULL, never a native send. That is physics, not policy.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE POTS — ONE TICKET EACH, ONE PAYOUT PER FIGHT
 *      ══════════════════════════════════════════════════════════════════════
 *      Every decisive duel opens a ticket on BOTH pools carrying the same
 *      `duelKey`, each at its own true odds (1-in-50 BNBULL, 1-in-100 WBNB).
 *      Whichever ticket rolls a win FIRST calls `claimJackpotForDuel` here and
 *      takes exclusivity; the other pays nothing. Nothing about which pot pays
 *      is knowable at submit time, which is what stops a wrapper contract from
 *      recomputing the outcome, reverting, and retrying next block until it
 *      gets the pot it wanted.
 *
 *      Every pot call is wrapped in try/catch. A pot fault — a paused token, a
 *      pool that has not whitelisted us, an outright bug — must never stop a
 *      fight from settling. A failed roll costs a ticket, never the duel.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      RULE 2: PLAYER-FACING NUMBERS ARE BOUNDED SETTERS
 *      ══════════════════════════════════════════════════════════════════════
 *      `CONSECUTIVE_LOSSES_TO_DIE = 3` was a `constant` on fefers, pinned into
 *      a one-time-set Duel slot on the live NFT, and a later request for four
 *      losses was flat impossible. Here it is `lossesToDie`, an owner-settable
 *      variable inside `[MIN_LOSSES_TO_DIE, MAX_LOSSES_TO_DIE]`. `constant` is
 *      reserved for true security ceilings. Wiring is TIMELOCKED.
 */
contract Duel is Ownable, Pausable, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;
    using TimelockedAddress for TimelockedAddress.Slot;

    // ─── EIP-712 ─────────────────────────────────────────────────────────

    /// @notice Domain name. LOCKED by `DECISIONS.md §13` and set before the
    ///         first deploy. Combined with the version, the chain id and this
    ///         contract's address it binds every signature to THIS deployment
    ///         on chain 56 — a testnet signature cannot be replayed on
    ///         mainnet, and a v2 Duel cannot honour v1 signatures.
    string private constant EIP712_NAME = "BNBullsDuel";
    /// @notice Version 1. This is a fresh collection on a fresh chain; the
    ///         fefers version-3 history (per-side assets, then per-side signed
    ///         amounts) is already folded into the struct below.
    string private constant EIP712_VERSION = "1";

    /// @notice Typehash for `DuelResult`.
    /// @dev ⚠ Duplicated field-for-field in the signer's `types.DuelResult`
    ///      array (`frontend/src/app/api/run-duel/route.ts`). The two MUST
    ///      stay byte-identical: order, names and types are all hashed, and any
    ///      drift makes every fight revert `InvalidSignature`.
    bytes32 private constant DUEL_RESULT_TYPEHASH = keccak256(
        "DuelResult(uint256 tokenA,uint256 tokenB,uint32 winnerId,uint16 rounds,uint256 seed,uint32 newEloA,uint32 newEloB,address assetA,address assetB,uint256 stakeA,uint256 stakeB,uint64 seqA,uint64 seqB,uint256 nonce,uint256 expiry)"
    );

    // ─── True security ceilings (the only policy-free `constant`s) ───────

    /// @notice Ceiling on any per-asset dev cut. 20%.
    uint16 public constant MAX_DEV_BPS = 2_000;
    /// @notice Ceiling on the share OF THE DEV CUT routed to the pots.
    uint16 public constant MAX_POT_SHARE_BPS = 10_000;
    /// @notice Ceiling on any per-asset discount. The launch value is 1000
    ///         (10%) on BNBULL and 0 everywhere else (`DECISIONS.md §2`).
    uint16 public constant MAX_DISCOUNT_BPS = 5_000;
    /// @notice Ceiling on the stored dollar sticker, 1e18-scaled. Matches
    ///         `MintDrop.MAX_USD_PRICE`. This bounds a compromised owner key —
    ///         but it is NOT the binding constraint on what a fighter can be
    ///         charged, because the derived stake still has to clear the
    ///         asset's one-shot `maxFightCostOf`.
    uint256 public constant MAX_USD_FIGHT_PRICE = 10_000e18;
    /// @notice Bounds on the death threshold. A floor of 1 means "one loss
    ///         kills", which is a legitimate (brutal) setting; a ceiling stops
    ///         a compromised key making bulls immortal and the graveyard dead
    ///         content.
    uint8 public constant MIN_LOSSES_TO_DIE = 1;
    uint8 public constant MAX_LOSSES_TO_DIE = 20;
    /// @notice Ceiling on how many older tickets a duel drains on its way past.
    uint8 public constant MAX_JACKPOT_RESOLVE_PER_DUEL = 25;
    /// @notice Wiring timelock bounds.
    uint256 public constant MIN_WIRING_DELAY = 6 hours;
    uint256 public constant MAX_WIRING_DELAY = 30 days;

    uint256 private constant BPS = 10_000;

    // ─── Types ───────────────────────────────────────────────────────────

    /**
     * @notice A signed duel result.
     * @param winnerId 0 for a tie, else `tokenA` or `tokenB` as uint32.
     * @param assetA   Stake token for side A. `address(0)` means "this side
     *                 stakes nothing" and REQUIRES `stakeA == 0`.
     * @param stakeA   The exact amount side A is charged, in that asset's own
     *                 units, discount already applied by the quoting signer.
     *                 Signed rather than read live off `fightCostOf`: the
     *                 price the API quoted and the UI displayed is the price
     *                 the wallet pays. A keeper repeg mid-quote changes the
     *                 NEXT fight, never the one on the player's screen, and a
     *                 compromised owner key that repegs to the ceiling cannot
     *                 reach into standing allowances because no signature
     *                 authorises the new number. Bounded by the asset's
     *                 one-shot `maxFightCostOf`.
     * @param seqA     Side A's owner's `fightSeq` at sign time. See the
     *                 per-wallet commit section of the header — this is the
     *                 field that makes the affordability check a guarantee.
     */
    struct DuelResult {
        uint256 tokenA;
        uint256 tokenB;
        uint32 winnerId;
        uint16 rounds;
        uint256 seed;
        uint32 newEloA;
        uint32 newEloB;
        address assetA;
        address assetB;
        uint256 stakeA;
        uint256 stakeB;
        uint64 seqA;
        uint64 seqB;
        uint256 nonce;
        uint256 expiry;
    }

    /// @dev Timelocked wiring slots. Everything that can move money or gate a
    ///      payout lives here. `trustedSigner`, `devTreasury`, `marketplace`
    ///      and `authorizedRouter` deliberately do NOT — see their setters.
    enum Wire {
        /// The Graveyard, the only address allowed to reset a loss streak.
        Graveyard,
        /// The BNBULL-prize Jackpot (1 in 50).
        JackpotBnbull,
        /// The WBNB-prize Jackpot (1 in 100).
        JackpotBnb,
        /// MintDrop — read for the Chainlink BNB/USD price (`bnbUsdPrice()`),
        /// which is what converts the stored dollar sticker into a BNB stake
        /// (`DECISIONS.md §1` + `§26`). Timelocked because repointing it moves
        /// the price source for every BNB fight.
        ///
        /// ⚠ It no longer receives money. It used to take a stablecoin dev-cut
        /// slice through `donatePotToken`, because a stablecoin was neither
        /// pot's prize token and needed MintDrop's 20/10 split and swap routes
        /// to become one. With only BNB and BNBULL left, EVERY dev-cut slice is
        /// already a prize token and goes straight into its own pot; there is
        /// no third asset for that route to carry.
        MintDrop,
        /// The yards roster (`Yards.sol`) — per-bull arena membership. Zero
        /// disables the check, so this MUST be bootstrapped at deploy or the
        /// eject does nothing.
        ///
        /// ⚠ TIMELOCKED, unlike `marketplace` and `authorizedRouter`, which
        /// are plain setters. Those two are plain because a hot-path
        /// dependency that starts reverting has to be removable in one
        /// transaction. `Yards.fightBlocked` reads storage and nothing else —
        /// no external call, no `ownerOf`, no revert — so there is no liveness
        /// case to answer, and an eject that one compromised-key transaction
        /// could switch off for the whole collection would not be a guarantee.
        /// `DECISIONS.md §18`'s lesson pointed at a safety gate rather than a
        /// money slot.
        ///
        /// ⚠ Appended to the END of this enum on purpose. The existing members
        /// keep their indices, so every `bootstrapWire`/`proposeWire` call
        /// already written in `script/` and `test/` still names the same slot.
        Yards
    }

    // ─── Immutable refs ──────────────────────────────────────────────────

    /// @notice The bulls collection this contract settles fights for.
    Bulls public immutable bulls;
    /// @notice BNBULL: a stake asset, and the prize token of one pot — so a
    ///         BNBULL dev cut is routed straight in and NOTHING IS EVER SOLD
    ///         (`DECISIONS.md §14`).
    IERC20 public immutable bnbull;
    /// @notice Wrapped BNB: the BNB stake asset and the other pot's prize
    ///         token. Immutable because it is the canonical wrapper.
    IWrappedBNB public immutable wbnb;

    // ─── Wiring ──────────────────────────────────────────────────────────

    mapping(uint8 => TimelockedAddress.Slot) private _wires;

    /// @notice Delay a wiring change must age before it can be committed.
    uint256 public wiringDelay = 24 hours;

    /// @notice Who signs duel results off chain.
    /// @dev A PLAIN setter, deliberately. A leaked signing key has to be
    ///      rotatable in one transaction — a 24-hour timelock on this slot is
    ///      24 hours of an attacker signing whatever they like. The blast
    ///      radius is bounded the other way instead: a bad signer can only
    ///      produce results that are publicly re-simulatable from the seed,
    ///      and it can never exceed `maxFightCostOf` or move a bull it does
    ///      not have an allowance for.
    address public trustedSigner;

    /// @notice Marketplace. When set, listed bulls cannot fight — nobody sells
    ///         a fighter out from under a buyer mid-match. Zero disables.
    /// @dev Also a plain setter, and for the mirror-image reason: this call
    ///      sits on the hot path of every fight, so a Marketplace that starts
    ///      reverting halts ALL duels. Being able to unwire it in one
    ///      transaction is the liveness valve. It can only ever block a duel,
    ///      never redirect money.
    address public marketplace;

    /// @notice When set, ONLY this address may call `submitDuel`. The phase-2
    ///         router hook. Zero keeps the direct path, where an owner of
    ///         either bull submits.
    /// @dev Plain setter for the same liveness reason as `marketplace`: a
    ///      broken router must be removable in one transaction, or fights stop.
    address public authorizedRouter;

    // ─── Fight economics ─────────────────────────────────────────────────

    /// @notice Per-asset stake per fighter, in that asset's own units, at the
    ///         FULL undiscounted sticker. The keeper's peg.
    /// @dev ⚠ DOUBLE-DISCOUNT TRAP, handled the same way `MintDrop` handles
    ///      it. `DECISIONS.md §2` says the keeper pegs the BNBULL legs to
    ///      "dollar sticker − discount". If the keeper wrote the discounted
    ///      number here AND `fighterCost` took another 10% off, BNBULL fights
    ///      would cost 19% less, not 10%. **The keeper pegs the full sticker
    ///      and this contract owns the discount.** `fightCostOf` is the peg;
    ///      `fighterCost` is what a player is quoted.
    ///
    ///      ⚠ WBNB IS NOT IN HERE and `setFightCost` refuses it. Its sticker is
    ///      `usdFightPrice1e18` converted through the oracle at read time — see
    ///      the pricing section of the header. This mapping reading ZERO for
    ///      WBNB is the correct answer, not a missing configuration.
    mapping(address => uint256) public fightCostOf;

    /// @notice THE DOLLAR ANCHOR. What one fighter is charged, as a plain
    ///         1e18-scaled dollar figure ($5 = 5e18), before any discount.
    ///
    /// @dev This exists because `DECISIONS.md §26` deleted the stablecoin, and
    ///      the stablecoin's `fightCostOf` peg was the dollar sticker the BNB
    ///      leg used to be derived from — OFF CHAIN, by the signer. Storing it
    ///      here moves the anchor into the bytecode, where the conversion can
    ///      be audited and the oracle's freshness rules apply to it.
    ///
    ///      Zero means "the BNB leg is not priced", which reads as a free BNB
    ///      fight exactly as `fightCostOf[bnbull] == 0` reads as a free BNBULL
    ///      one. It is deliberately NOT an oracle read in that case: an unwired
    ///      MintDrop must not make `fighterCost` revert for an unpriced leg.
    uint256 public usdFightPrice1e18;
    /// @notice One-shot per-asset ceiling, fixed when the asset is registered
    ///         and immutable after. A compromised owner key can re-price
    ///         within it but can never set a stake nobody can afford, and no
    ///         signature can charge above it.
    mapping(address => uint256) public maxFightCostOf;
    /// @notice Per-asset dev cut in bps. Set at registration, retunable within
    ///         `MAX_DEV_BPS`. Per-asset because a BNB fight and a BNBULL fight
    ///         are not the same trade for the game.
    mapping(address => uint16) public devShareBpsOf;
    /// @notice Per-asset discount in bps. Launch: 1000 on BNBULL, 0 elsewhere.
    ///         Generic on purpose — do NOT hardcode which asset is discounted
    ///         (`DECISIONS.md §2`).
    mapping(address => uint16) public discountBpsOf;
    /// @notice Per-asset minimum stake for a decisive duel to open a jackpot
    ///         ticket. OPTIONAL and additive — a zero here does NOT mean "free
    ///         tickets", because `_rollOnePool` refuses a zero stake outright
    ///         whatever this says. See `DECISIONS.md §25`.
    mapping(address => uint256) public minTicketStakeOf;
    /// @notice Registered stake assets, for the UI and the keepers.
    address[] public fightAssets;

    /// @notice Dev cut applied to any asset registered from now on.
    uint16 public defaultDevShareBps;
    /// @notice Receives the dev cut of every fight.
    address public devTreasury;
    /// @notice Share OF THE DEV CUT that feeds the pots. 3000 = 30% of the
    ///         cut, i.e. 3% of a pot at a 10% dev share. The winner's take is
    ///         untouched: this comes out of the dev's slice, never off the top.
    /// @dev The mint is a one-time event at 500 supply. If only mints fed the
    ///      pots, buy pressure would stop the day the drop sold out. Fights
    ///      are forever.
    uint16 public potShareBps = 3_000;

    // ─── Fight state ─────────────────────────────────────────────────────

    /// @notice Consumed signature nonces.
    mapping(uint256 => bool) public usedNonces;

    /// @notice Per-wallet fight sequence — the per-wallet commit. A signed
    ///         result must name the CURRENT value for each side's owner, and
    ///         settling bumps it, so only one signed result naming a wallet
    ///         can ever land. Read this before signing.
    mapping(address => uint64) public fightSeq;

    /// @notice Per-bull consecutive loss counter. Reset by a win, a tie, or a
    ///         resurrection.
    mapping(uint256 => uint8) public consecutiveLosses;

    /// @notice Consecutive losses that kill a bull. A VARIABLE, not a
    ///         constant — see the header.
    /// @dev    **5, not fefers' 3** (`DECISIONS.md §32`, owner call). Fefers
    ///         froze this at 3 by pinning the Duel with a one-time-set wire and
    ///         then could not change it; here it is a bounded setter AND the
    ///         launch value is the one actually wanted, so neither half of that
    ///         mistake repeats.
    uint8 public lossesToDie = 5;

    /// @notice How many older jackpot tickets each duel drains on its way
    ///         past, so a busy day needs no keeper. Small: gas belongs to the
    ///         duel.
    uint8 public jackpotResolvePerDuel = 3;

    /// @notice May two bulls held by the SAME wallet fight each other?
    /// @dev FALSE by default, and that default is the decision — not a switch
    ///      waiting to be set. See the no-self-duels section of the header for
    ///      why (the free jackpot ticket, and the autoplay bot that killed 34
    ///      of 60 bulls by farming the softest target). Checked at settlement
    ///      against live `ownerOf`, because a signing-time check is bypassable
    ///      by transferring a bull after the quote.
    bool public allowSelfDuel;

    /// @notice Which duels have already had a pot pay out, keyed by
    ///         `duelJackpotKey(nonce)`. The one-pot-per-fight lock. It lives
    ///         here because both pools already point at this contract, so
    ///         there is no extra wiring step to forget.
    mapping(uint256 => bool) public duelJackpotPaid;

    // ─── Socials (DECISIONS §5) ──────────────────────────────────────────

    string public website = "https://bnbulls.xyz";
    string public twitter = "https://x.com/WeAreBNBulls";
    string public telegram = "https://t.me/WeAreBNBulls";

    // ─── Events ──────────────────────────────────────────────────────────

    event DuelCompleted(
        uint256 indexed tokenA,
        uint256 indexed tokenB,
        uint32 winnerId,
        uint16 rounds,
        uint256 seed,
        uint256 nonce,
        uint32 newEloA,
        uint32 newEloB
    );
    event BullDied(uint256 indexed tokenId);
    /// @notice Stake settlement for one duel. Who received what follows from
    ///         the same-tx `DuelCompleted`: the winner takes both sides'
    ///         post-devcut stakes, a tie refunds each side its own.
    event StakesSettled(
        uint256 indexed tokenA,
        uint256 indexed tokenB,
        address assetA,
        address assetB,
        uint256 stakeA,
        uint256 stakeB,
        uint256 devCutA,
        uint256 devCutB
    );
    /// @notice A side's stake was paid with BNB sent alongside the duel and
    ///         wrapped 1:1 into WBNB, rather than pulled by allowance.
    event NativeStakeWrapped(address indexed payer, uint256 amount);
    event FightSeqConsumed(address indexed wallet, uint64 seq);
    /// @notice A winner got a ticket. TWO of these fire per decisive duel
    ///         while both pools are wired.
    event JackpotTicketOpened(uint256 indexed tokenId, address indexed winner, uint256 ticketId);
    /// @notice The pot call reverted and was swallowed. The duel still settled.
    event JackpotRollFailed(uint256 indexed tokenId);
    /// @notice ⚠ A POT'S `resolve` REVERTED AND WAS SWALLOWED — SO THE QUEUE
    ///         DID NOT MOVE, AND IT WILL NOT MOVE ON THE NEXT FIGHT EITHER.
    ///         The fight still settled; nothing a player did is affected. This
    ///         is the only trace such a fault leaves anywhere. See
    ///         `_resolveOnly` for why it cannot be emitted by the pot itself.
    /// @param reason The 4-byte selector of the revert, or zero when the pot
    ///        returned nothing (a bare `revert()`, or out of gas).
    event JackpotResolveFailed(address indexed pot, bytes4 reason);
    /// @notice A pot claimed the exclusive right to pay out for a duel.
    event DuelJackpotClaimed(uint256 indexed duelKey, address indexed pot);
    /// @notice A dev-cut slice reached a pot.
    event PotSliceFunded(address indexed asset, uint256 amount);
    /// @notice A dev-cut slice could not reach a pot, so it stayed with dev
    ///         rather than blocking the fight. On chain, so nobody has to take
    ///         our word for which happened.
    event PotSliceFailed(address indexed asset, uint256 amount);

    event TrustedSignerChanged(address indexed previous, address indexed next);
    event MarketplaceSet(address indexed previous, address indexed next);
    event AllowSelfDuelChanged(bool allowed);
    event AuthorizedRouterSet(address indexed previous, address indexed next);
    event StreakReset(uint256 indexed tokenId);
    event FightAssetAdded(address indexed asset, uint256 maxCost, uint16 devShareBps);
    event FightCostChanged(address indexed asset, uint256 cost);
    /// @notice The dollar anchor moved. The BNB stake leg re-derives from it on
    ///         the next quote — there is no separate BNB peg to repeg.
    event UsdFightPriceChanged(uint256 usd1e18);
    event DevShareChanged(address indexed asset, uint16 bps);
    event DefaultDevShareChanged(uint16 bps);
    event DevTreasuryChanged(address indexed previous, address indexed next);
    event DiscountSet(address indexed asset, uint16 bps);
    event MinTicketStakeSet(address indexed asset, uint256 minStake);
    event PotShareChanged(uint16 bps);
    event LossesToDieChanged(uint8 losses);
    event JackpotResolvePerDuelChanged(uint8 count);
    event WireBootstrapped(Wire indexed slot, address indexed target);
    event WireProposed(Wire indexed slot, address indexed target, uint64 eta);
    event WireCommitted(Wire indexed slot, address indexed previous, address indexed next);
    event WireCancelled(Wire indexed slot, address indexed dropped);
    event WiringDelayChanged(uint256 newDelay);
    event SocialsChanged(string website, string twitter, string telegram);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────

    error InvalidSignature();
    error NonceAlreadyUsed();
    error Expired();
    error InvalidWinnerId();
    error BullNotAlive(uint256 tokenId);
    error BullIsListed(uint256 tokenId);
    /// @dev This bull's owner has not put it in the yards (or has ejected it),
    ///      so it cannot be fought at any stake — including a stake of zero.
    error BullNotInYards(uint256 tokenId);
    error NotOwnerOfEither();
    error OnlyAuthorizedRouter();
    error SelfFight();
    /// @dev Both bulls are held by the same wallet and `allowSelfDuel` is off.
    error SelfDuelBlocked(address owner);
    error SignerMustBeNonZero();
    error NotGraveyard();
    error NotSelf();
    error ZeroAddress();
    error ZeroMaxCost();
    error AssetAlreadyAdded(address asset);
    error UnsupportedAsset(address asset);
    error FightCostTooHigh(uint256 requested);
    error DevShareTooHigh(uint16 requested);
    /// @dev `setFightCost` was called on WBNB. Its price is the stored dollar
    ///      sticker converted through the oracle, not a keeper peg — writing
    ///      one would create a second source of truth that can only ever
    ///      disagree with the first. Use `setUsdFightPrice`.
    error OraclePricedAsset(address asset);
    /// @dev The dollar anchor is set but MintDrop — the Chainlink read — is
    ///      not wired, so a BNB stake cannot be priced. Fail closed: a wrong
    ///      price is worse than no fight.
    error OracleNotWired();
    error InvalidShare(uint256 bps);
    error LossThresholdOutOfRange(uint8 requested);
    error ResolveCountOutOfRange(uint8 requested);
    error DelayOutOfRange(uint256 requested);
    /// @dev A side carries an amount but no asset. `(address(0), 0)` is the
    ///      only legal "this side stakes nothing".
    error StakeWithoutAsset();
    /// @dev The per-wallet commit. Another signed result naming this wallet
    ///      already settled, so this signature is void — request a fresh quote.
    error StaleFightSeq(address wallet, uint64 expected, uint64 provided);
    error StakeUnaffordable(address wallet, address asset, uint256 needed, uint256 held);
    error StakeNotApproved(address wallet, address asset, uint256 needed, uint256 approved);
    /// @dev A stake pull delivered less than the signed amount — a
    ///      fee-on-transfer or rebasing stake asset. The duel cannot settle
    ///      the numbers that were signed, so it does not settle at all.
    error StakeShortfall(address asset, uint256 expected, uint256 received);
    error WrapShortfall(uint256 expected, uint256 received);
    error RefundFailed();

    // ─── Constructor ─────────────────────────────────────────────────────

    struct DeployParams {
        address initialOwner;
        address bulls;
        address bnbull;
        address wbnb;
        address trustedSigner;
        address devTreasury;
        uint16 defaultDevShareBps;
    }

    constructor(DeployParams memory p)
        Ownable(p.initialOwner)
        EIP712(EIP712_NAME, EIP712_VERSION)
    {
        if (p.bulls == address(0) || p.bnbull == address(0) || p.wbnb == address(0)) {
            revert ZeroAddress();
        }
        if (p.trustedSigner == address(0)) revert SignerMustBeNonZero();
        if (p.devTreasury == address(0)) revert ZeroAddress();
        if (p.defaultDevShareBps > MAX_DEV_BPS) revert DevShareTooHigh(p.defaultDevShareBps);

        bulls = Bulls(p.bulls);
        bnbull = IERC20(p.bnbull);
        wbnb = IWrappedBNB(p.wbnb);
        trustedSigner = p.trustedSigner;
        devTreasury = p.devTreasury;
        defaultDevShareBps = p.defaultDevShareBps;

        // ⚠ NO LAUNCH DISCOUNT ON FIGHTS — not even on BNBULL (`DECISIONS.md
        // §39`, owner call). A $2 duel costs $2, whether it is paid in BNB or
        // in BNBULL.
        //
        // `§2`'s "the discount is ALWAYS BNBULL" still holds — it just belongs
        // to MINTING, not fighting. A duel is a bet between two players, and
        // discounting one side's entry means the two fighters put in different
        // money for the same purse. `_distributePot` settles each side in its
        // own asset, so that asymmetry lands straight in the winner's payout.
        //
        // The mapping stays GENERIC and the setter stays live, so this is a
        // launch value rather than a decision welded into the bytecode — the
        // owner can turn it on later without a redeploy.
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The fight
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Settle a signed duel.
     * @param result    The signed result.
     * @param signature 65-byte ECDSA signature from `trustedSigner`.
     *
     * @dev Payable so a side staking WBNB can pay in raw BNB in the same
     *      transaction: send at least that side's stake and the contract wraps
     *      exactly what it needs, refunding the remainder. Send nothing and
     *      both sides settle by allowance as usual.
     */
    function submitDuel(DuelResult calldata result, bytes calldata signature)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        _validate(result, signature);

        // Consume the nonce before any external call (CEI).
        usedNonces[result.nonce] = true;

        // ⚠ Read ONCE, here, at settlement. Every ownership-derived rule below
        // — who may submit, the self-duel block, whose balance is charged, who
        // gets paid — keys off these two reads, so a bull that changed hands
        // after the signature was issued is judged on where it is NOW.
        address ownerA = bulls.ownerOf(result.tokenA);
        address ownerB = bulls.ownerOf(result.tokenB);
        _authorize(ownerA, ownerB);
        _requireInYards(result.tokenA, ownerA, result.tokenB, ownerB);

        // The per-wallet commit. Consumed SEQUENTIALLY, which also makes the
        // router case fall out for free: with both bulls escrowed by a router,
        // `ownerA == ownerB` and the signer simply names `seq` and `seq + 1`.
        _consumeSeq(ownerA, result.seqA);
        _consumeSeq(ownerB, result.seqB);

        uint256 refund = _collectStakes(result, ownerA, ownerB);

        (bool aDied, bool bDied) = _updateStreaksAndCheckDeaths(result);

        bulls.applyDuelResult(
            result.tokenA,
            result.tokenB,
            result.newEloA,
            result.newEloB,
            result.winnerId,
            aDied,
            bDied
        );

        _distributePot(result, ownerA, ownerB);

        _emitDuelCompleted(result);
        if (aDied) emit BullDied(result.tokenA);
        if (bDied) emit BullDied(result.tokenB);

        _rollJackpot(result, ownerA, ownerB);

        // Dead last, and only what the wrap did not need. The refund is the
        // one call in this function that hands control to an address of the
        // caller's choosing, so it happens after every piece of state is
        // settled — there is nothing left for a re-entrant frame to catch
        // half-done, on top of the `nonReentrant` guard.
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev Structural validation, signature recovery, liveness and the
    ///      listing lockout. Ownership-derived rules live in `_authorize`, off
    ///      a single pair of reads. Split out of `submitDuel` to keep the
    ///      stack shallow.
    function _validate(DuelResult calldata result, bytes calldata signature) private view {
        if (result.tokenA == result.tokenB) revert SelfFight();
        if (
            result.winnerId != 0 && result.winnerId != uint32(result.tokenA)
                && result.winnerId != uint32(result.tokenB)
        ) revert InvalidWinnerId();
        if (block.timestamp > result.expiry) revert Expired();
        if (usedNonces[result.nonce]) revert NonceAlreadyUsed();

        // `hashDuelResult` already returns the final EIP-712 digest, domain-
        // separated by chain id and `address(this)`, so recover directly with
        // no extra EIP-191 wrap.
        if (ECDSA.recover(hashDuelResult(result), signature) != trustedSigner) {
            revert InvalidSignature();
        }

        if (!bulls.isAlive(result.tokenA)) revert BullNotAlive(result.tokenA);
        if (!bulls.isAlive(result.tokenB)) revert BullNotAlive(result.tokenB);

        // Listing lockout. A listed bull cannot fight, which kills the "owner
        // sends a listed bull into combat, it dies, the buyer is stuck with a
        // corpse" race. A reverting Marketplace therefore halts fights — that
        // is fail-CLOSED on purpose, and `setMarketplace(0)` is the one-tx
        // valve if it ever happens.
        address m = marketplace;
        if (m != address(0)) {
            if (IMarketplaceListing(m).isListed(result.tokenA)) {
                revert BullIsListed(result.tokenA);
            }
            if (IMarketplaceListing(m).isListed(result.tokenB)) {
                revert BullIsListed(result.tokenB);
            }
        }
    }

    /**
     * @dev Who may submit, and the self-duel block. Both run off the live
     *      `ownerOf` reads taken in `submitDuel`, never off anything the
     *      signature asserted — a bull that moved between quote and submit is
     *      judged where it is now.
     */
    function _authorize(address oA, address oB) private view {
        address router = authorizedRouter;
        if (router != address(0)) {
            if (msg.sender != router) revert OnlyAuthorizedRouter();
            // A router escrows both bulls before calling, so `ownerOf` reads
            // the router on BOTH sides and equality there is an artefact of
            // custody, not a self-duel — the router must run the same check
            // against the signed quote's real owners before taking them. Any
            // OTHER pair of equal owners on this path is a genuine self-duel
            // and is blocked here just the same.
            if (oA == oB && oA != router && !allowSelfDuel) revert SelfDuelBlocked(oA);
        } else {
            if (oA == oB && !allowSelfDuel) revert SelfDuelBlocked(oA);
            if (oA != msg.sender && oB != msg.sender) revert NotOwnerOfEither();
        }
    }

    /**
     * @dev Both bulls must be in the yards under their LIVE owners.
     *
     *      Runs on EVERY duel, staked or free, before a sequence number is
     *      consumed or a token moves — the zero-stake path is the one the
     *      allowance gate never covered (see the header), so a check that
     *      lived in `_takeSide` would miss exactly the case that matters.
     *
     *      ⚠ `code.length`, and the skip on an empty slot, are both load
     *      bearing. `fightBlocked` returns a value, so solc emits an
     *      `extcodesize` check before the call; a slot pointing at a WALLET
     *      would revert every duel in the game until the wiring timelock could
     *      be walked — the same trap `_rollOnePool` documents on the ticket
     *      leg. Treating a non-contract as "no yards" makes a mis-wire a
     *      degraded check instead of a dead game, and a compromised key trying
     *      to use it as a back door still has to propose an EOA, publish an
     *      ETA and wait out `wiringDelay` in the open.
     */
    function _requireInYards(uint256 tokenA, address ownerA, uint256 tokenB, address ownerB)
        private
        view
    {
        address y = _wire(Wire.Yards);
        if (y == address(0) || y.code.length == 0) return;
        uint256 blocked = IDuelYards(y).fightBlocked(tokenA, ownerA, tokenB, ownerB);
        if (blocked != 0) revert BullNotInYards(blocked);
    }

    /// @dev The per-wallet commit, consumed. See the header.
    function _consumeSeq(address wallet, uint64 seq) private {
        uint64 expected = fightSeq[wallet];
        if (seq != expected) revert StaleFightSeq(wallet, expected, seq);
        unchecked {
            fightSeq[wallet] = seq + 1;
        }
        emit FightSeqConsumed(wallet, seq);
    }

    /**
     * @dev Pull both stakes. Each side pays in its own signed asset at its own
     *      signed amount; `address(0)` stakes nothing and must carry a zero
     *      amount. Any BNB sent with the call is applied to `msg.sender`'s own
     *      WBNB stake first.
     * @return refund The unspent native credit, returned to the caller at the
     *         very end of `submitDuel`.
     */
    function _collectStakes(DuelResult calldata result, address ownerA, address ownerB)
        private
        returns (uint256 refund)
    {
        uint256 credit = msg.value;
        credit = _takeSide(result.assetA, result.stakeA, ownerA, credit);
        credit = _takeSide(result.assetB, result.stakeB, ownerB, credit);

        uint256 used = msg.value - credit;
        if (used > 0) {
            // A wrap, not a swap: 1:1, no router, no liquidity dependency.
            // Measured anyway, because measuring is free and assumptions are
            // how the fefers decimals trap happened.
            uint256 before = wbnb.balanceOf(address(this));
            wbnb.deposit{value: used}();
            uint256 got = wbnb.balanceOf(address(this)) - before;
            if (got < used) revert WrapShortfall(used, got);
            emit NativeStakeWrapped(msg.sender, used);
        }
        refund = credit;
    }

    /**
     * @dev Validate and collect one side's stake, returning the unspent native
     *      credit.
     *
     *      The explicit balance/allowance checks are the visible half of the
     *      affordability fix: with the per-wallet sequence guaranteeing no
     *      other signed fight can front-run this one, the only way a stake can
     *      still be short is that the wallet moved its own money — and when it
     *      does, the error says so by name and by number instead of surfacing
     *      as an opaque ERC-20 string.
     */
    function _takeSide(address asset, uint256 stake, address owner_, uint256 credit)
        private
        returns (uint256)
    {
        if (asset == address(0)) {
            if (stake != 0) revert StakeWithoutAsset();
            return credit;
        }
        uint256 ceiling = maxFightCostOf[asset];
        if (ceiling == 0) revert UnsupportedAsset(asset);
        if (stake > ceiling) revert FightCostTooHigh(stake);
        if (stake == 0) return credit;

        // The native convenience path: only ever for the wallet that sent the
        // BNB, because only `msg.sender` can post value. A passive opponent
        // stakes by allowance, always.
        if (asset == address(wbnb) && owner_ == msg.sender && credit >= stake) {
            unchecked {
                return credit - stake;
            }
        }

        IERC20 t = IERC20(asset);
        uint256 held = t.balanceOf(owner_);
        if (held < stake) revert StakeUnaffordable(owner_, asset, stake, held);
        uint256 approved = t.allowance(owner_, address(this));
        if (approved < stake) revert StakeNotApproved(owner_, asset, stake, approved);

        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(owner_, address(this), stake);
        uint256 received = t.balanceOf(address(this)) - before;
        if (received < stake) revert StakeShortfall(asset, stake, received);
        return credit;
    }

    /**
     * @dev Pay out the mixed pot. Each side settles in its own asset: the
     *      winner takes both sides' post-devcut stakes (possibly two different
     *      tokens); a tie refunds each fighter their own stake less the cut,
     *      with no cross-asset splitting so nobody ends a draw holding a token
     *      they never opted into.
     *
     *      The numbers come from the SIGNATURE, so what went in is exactly
     *      what goes out and a keeper repeg landing between the pull and the
     *      payout can neither strand nor overdraw the pot.
     */
    function _distributePot(DuelResult calldata result, address ownerA, address ownerB)
        private
    {
        uint256 stakeA = result.stakeA;
        uint256 stakeB = result.stakeB;
        if (stakeA == 0 && stakeB == 0) return;

        uint256 devCutA = (stakeA * devShareBpsOf[result.assetA]) / BPS;
        uint256 devCutB = (stakeB * devShareBpsOf[result.assetB]) / BPS;
        uint256 shareA = stakeA - devCutA;
        uint256 shareB = stakeB - devCutB;

        if (result.winnerId == uint32(result.tokenA)) {
            _payStake(result.assetA, ownerA, shareA);
            _payStake(result.assetB, ownerA, shareB);
        } else if (result.winnerId == uint32(result.tokenB)) {
            _payStake(result.assetA, ownerB, shareA);
            _payStake(result.assetB, ownerB, shareB);
        } else {
            _payStake(result.assetA, ownerA, shareA);
            _payStake(result.assetB, ownerB, shareB);
        }

        if (devCutA > 0) _payDevCut(result.assetA, devCutA);
        if (devCutB > 0) _payDevCut(result.assetB, devCutB);

        emit StakesSettled(
            result.tokenA,
            result.tokenB,
            result.assetA,
            result.assetB,
            stakeA,
            stakeB,
            devCutA,
            devCutB
        );
    }

    /**
     * @dev Pay the dev cut, routing `potShareBps` of it into the pots.
     *
     *      NEVER-FAIL (`BNBULLS-BOOTSTRAP.md §6`). The whole leg — the
     *      approval included — runs inside `try this.routePotSliceInline()`,
     *      so a paused MintDrop, a pot that has not whitelisted us, a thin
     *      pair or an outright bug rolls back to exactly this point and the
     *      slice simply stays with dev. A fight is never blocked by a buyback.
     */
    function _payDevCut(address asset, uint256 amount) private {
        uint256 slice = (amount * potShareBps) / BPS;
        if (slice > 0 && _potLegReady(asset)) {
            try this.routePotSliceInline(asset, slice) {
                emit PotSliceFunded(asset, slice);
            } catch {
                emit PotSliceFailed(asset, slice);
                slice = 0;
            }
        } else {
            slice = 0;
        }
        _payStake(asset, devTreasury, amount - slice);
    }

    /**
     * @dev Cheap pre-check so a fight does not pay for a try/catch that cannot
     *      possibly work.
     *
     *      ⚠ `code.length` is load-bearing, not belt-and-braces. A call to an
     *      EOA SUCCEEDS with empty returndata, and neither `fund` nor
     *      `donatePotToken` returns anything for the decode to choke on — so a
     *      mis-wired slot pointing at a wallet would report a funded pot, the
     *      slice would be deducted from the dev payout, and the tokens would
     *      sit stranded in this contract with nothing having happened. Refuse
     *      the leg instead, and the whole cut goes to dev where it can be seen.
     */
    function _potLegReady(address asset) private view returns (bool) {
        address target;
        if (asset == address(bnbull)) target = _wire(Wire.JackpotBnbull);
        else if (asset == address(wbnb)) target = _wire(Wire.JackpotBnb);
        // Anything else has no pot leg at all: `DECISIONS.md §26` leaves BNB
        // and BNBULL as the only currencies, and each IS a pot's prize token.
        // A stray registered asset keeps its whole dev cut with dev, visibly,
        // rather than being quietly routed somewhere that cannot use it.
        else return false;
        return target != address(0) && target.code.length > 0;
    }

    /**
     * @notice The inline pot leg. `external` ONLY so this contract can
     *         try/catch its own call; `NotSelf` makes it unreachable to anyone
     *         else, so it is not a door into this contract's balance.
     * @dev Reverts freely — every revert is caught upstream and the slice
     *      falls back to dev.
     *
     *      ⚠ `DECISIONS.md §14`: a BNBULL slice is ALREADY the prize token of
     *      the BNBULL pot and goes straight in. Nothing sells BNBULL, ever.
     *      A WBNB slice is likewise already the other pot's prize token. With
     *      the stablecoin gone (`§26`) there is no third case — and therefore
     *      no swap, no split and no second hop anywhere on this path.
     */
    function routePotSliceInline(address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();

        if (asset == address(bnbull)) {
            _fundPotDirect(_wire(Wire.JackpotBnbull), bnbull, amount);
        } else if (asset == address(wbnb)) {
            _fundPotDirect(_wire(Wire.JackpotBnb), IERC20(address(wbnb)), amount);
        } else {
            revert UnsupportedAsset(asset);
        }
    }

    function _fundPotDirect(address pot, IERC20 token, uint256 amount) private {
        token.forceApprove(pot, amount);
        IDuelJackpot(pot).fund(amount, "duel-devcut");
        token.forceApprove(pot, 0);
    }

    /// @dev Transfer helper tolerating the zero-asset / zero-amount cases.
    function _payStake(address asset, address to, uint256 amount) private {
        if (asset == address(0) || amount == 0) return;
        IERC20(asset).safeTransfer(to, amount);
    }

    /**
     * @dev Update the loss streaks and decide who died. A win or a tie clears
     *      the relevant streaks; the `lossesToDie`-th consecutive loss kills.
     */
    function _updateStreaksAndCheckDeaths(DuelResult calldata result)
        private
        returns (bool aDied, bool bDied)
    {
        uint8 threshold = lossesToDie;
        if (result.winnerId == 0) {
            consecutiveLosses[result.tokenA] = 0;
            consecutiveLosses[result.tokenB] = 0;
        } else if (result.winnerId == uint32(result.tokenA)) {
            consecutiveLosses[result.tokenA] = 0;
            uint8 streakB = consecutiveLosses[result.tokenB] + 1;
            consecutiveLosses[result.tokenB] = streakB;
            if (streakB >= threshold) bDied = true;
        } else {
            consecutiveLosses[result.tokenB] = 0;
            uint8 streakA = consecutiveLosses[result.tokenA] + 1;
            consecutiveLosses[result.tokenA] = streakA;
            if (streakA >= threshold) aDied = true;
        }
    }

    /// @dev Split out so the event's eight arguments do not add to
    ///      `submitDuel`'s already-loaded stack.
    function _emitDuelCompleted(DuelResult calldata result) private {
        emit DuelCompleted(
            result.tokenA,
            result.tokenB,
            result.winnerId,
            result.rounds,
            result.seed,
            result.nonce,
            result.newEloA,
            result.newEloB
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The pots
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev Open a ticket for the winner on BOTH pools, then nudge both queues.
     *      Ties get nothing.
     *
     *      No payout happens here, and NEITHER DOES THE CHOICE OF WHICH POT
     *      PAYS. On fefers that choice used to be a coin flip over the signed
     *      seed, the signed nonce and the parent block hash — every one of
     *      which is readable INSIDE the submitting transaction. A wrapper
     *      contract could recompute the flip, revert unless it landed on the
     *      pot it wanted, and retry next block for the price of a failed
     *      transaction: raw odds on its preferred pot instead of the halved
     *      rate everyone else lived with. A 2x edge, in a contract that cannot
     *      be upgraded.
     *
     *      Anything computable at submit time is grindable by definition. So
     *      both pools get a ticket at their own TRUE odds and the mutual
     *      exclusion happens at RESOLUTION, gated on randomness that does not
     *      exist yet. Both tickets carry the same `duelKey`; the first to roll
     *      a win claims it below and the other pays nothing for that fight.
     *      A pool's stored `oddsOneIn` is therefore the odds a player actually
     *      experiences: 50 means 1 in 50.
     */
    function _rollJackpot(DuelResult calldata result, address ownerA, address ownerB) private {
        address potBnbull = _wire(Wire.JackpotBnbull);
        address potBnb = _wire(Wire.JackpotBnb);
        uint256 duelKey = duelJackpotKey(result.nonce);

        _rollOnePool(potBnbull, result, ownerA, ownerB, duelKey);
        _rollOnePool(potBnb, result, ownerA, ownerB, duelKey);

        _resolveOnly(potBnbull);
        _resolveOnly(potBnb);
    }

    function _rollOnePool(
        address pot,
        DuelResult calldata result,
        address ownerA,
        address ownerB,
        uint256 duelKey
    ) private {
        // ⚠⚠ `code.length`, NOT `!= address(0)` — AND THE TRY/CATCH DOES NOT
        // COVER THIS. `recordWin` has a return value, so solc emits an
        // `extcodesize` check before the call; that check reverts in THIS
        // frame, outside the `try`, and is therefore uncatchable. A
        // `Wire.JackpotBnbull` or `Wire.JackpotBnb` pointed at a WALLET would
        // then revert EVERY duel in the game — not defer a ticket, not lose a
        // slice: brick the whole fight, permanently, until the 24-hour wiring
        // timelock could be walked. `_potLegReady` already refuses a wallet in
        // a money slot for the money leg; this is the same guard on the TICKET
        // leg, which had been left without one.
        if (pot.code.length == 0 || result.winnerId == 0) return;

        // ⚠ A TICKET IS EARNED BY FUNDING THE POT (`DECISIONS.md §25`).
        //
        // A zero-stake duel is legal, moves no money and takes no dev cut, so
        // it contributes NOTHING to the pool. Without this guard, whoever holds
        // the signing key mints unlimited 1-in-50 and 1-in-100 tickets for the
        // price of two mints, on a pot everybody else funded — and draining it
        // becomes a schedule rather than a gamble. Two bulls in two different
        // wallets is not a self-duel, so `§16` never engages; alternating the
        // winner keeps both loss streaks at zero so nothing ever dies.
        //
        // This is `§18`'s attack in a new costume and it needs no VRF at all.
        // Adding entropy to the roll does not help — `§18` settles that.
        // Timelocking `setTrustedSigner` would be worse: it is deliberately the
        // instant valve for a leaked key.
        //
        // The zero check is unconditional and needs no configuration, because
        // an unset mapping defaults to zero and a forgotten wiring tx must fail
        // SAFE. `minTicketStakeOf` only tightens it.
        if (result.stakeA == 0 || result.stakeB == 0) return;
        if (result.stakeA < minTicketStakeOf[result.assetA]) return;
        if (result.stakeB < minTicketStakeOf[result.assetB]) return;

        bool aWon = result.winnerId == uint32(result.tokenA);
        address winnerOwner = aWon ? ownerA : ownerB;
        uint256 winnerId = aWon ? result.tokenA : result.tokenB;

        // The signed seed and nonce ride along as extra entropy. They are
        // never the deciding value, only part of the mix — the deciding value
        // is a VRF word that does not exist yet.
        uint256 entropy = uint256(keccak256(abi.encodePacked(result.seed, result.nonce)));

        try IDuelJackpot(pot).recordWin(winnerOwner, winnerId, entropy, duelKey) returns (
            uint256 id
        ) {
            emit JackpotTicketOpened(winnerId, winnerOwner, id);
        } catch {
            emit JackpotRollFailed(winnerId);
        }
    }

    /**
     * @dev Drain a few already-decided tickets on the way past. Never opens
     *      one. Any duel traffic pays for resolving earlier winners' tickets,
     *      so the queues drain themselves on a busy day.
     *
     *      ⚠ THE TRY/CATCH IS RIGHT AND IT WAS ALSO SILENT. THAT WAS THE BUG.
     *      A pot fault must never revert a fight, so the swallow stays. But
     *      `Jackpot.resolve` walks a CURSOR, and any revert inside it rolls
     *      that cursor back — so the same ticket is retried, and fails, on
     *      every duel afterwards. The queue stops dead and **nothing anywhere
     *      says so**: the fight settles, the player sees nothing, no error is
     *      raised, and the pot has no withdraw path to inspect. Measured live
     *      on chain 97: one winning BNBULL ticket against a token whose
     *      `tradingEnabled` was still false (the real launch state,
     *      `DECISIONS.md §29`) wedged 77 more behind it while the game read
     *      perfectly healthy. The whitelist is one cause; a blacklisted
     *      winner, a paused prize token or an outright bug are the others, and
     *      they all present identically — as silence.
     *
     *      ⛔ AND THE EVENT CANNOT LIVE ON THE POT. That is not a preference:
     *      a revert discards every log written in the frame it reverts, which
     *      is exactly what `BNBull._update` documents about the anti-bot
     *      auto-blacklist that "never existed" (`DECISIONS.md §19`). A pot
     *      cannot report its own failure for the same reason it cannot record
     *      a rejected transfer — the rejection is what erases the record. Only
     *      the frame that SWALLOWS the revert survives to log it, and that
     *      frame is this one. A keeper calling `Jackpot.resolve` directly does
     *      see the revert, because its own transaction fails; this path is the
     *      one where nobody was ever told.
     *
     *      The reason travels as the 4-byte selector, not the whole payload:
     *      it is what an alert bot switches on (`TradingNotEnabled()` and
     *      `AddrBlacklisted(address)` are different pages of the runbook) and
     *      it costs one word. Copying the returndata at all is safe here for
     *      the same reason `DuelGuzzlerJackpot` is: a hostile pot can already
     *      burn this frame's gas under EIP-150, so a returndata bomb adds no
     *      capability it did not have.
     */
    function _resolveOnly(address pot) private {
        // Same reason as `_rollOnePool`: `resolve` returns a value, so the
        // `extcodesize` check solc emits for it lives OUTSIDE the try/catch.
        if (pot.code.length == 0) return;
        try IDuelJackpot(pot).resolve(jackpotResolvePerDuel) {}
        catch (bytes memory reason) {
            emit JackpotResolveFailed(pot, _revertSelector(reason));
        }
    }

    /// @dev First four bytes of a revert payload, zero when there are not four
    ///      of them. The mask matters: `bytes4` is left-aligned in a word and
    ///      an unmasked `mload` would leave the rest of the revert data in the
    ///      low bytes, which is not what gets logged.
    function _revertSelector(bytes memory reason) private pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel :=
                and(
                    mload(add(reason, 0x20)),
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
        }
    }

    /**
     * @notice The per-duel key both pools share. Derived rather than the raw
     *         nonce so it can never be zero (a Jackpot reads zero as "no
     *         exclusivity") and bound to `address(this)` so two Duel
     *         deployments sharing a pool can never collide.
     */
    function duelJackpotKey(uint256 nonce) public view returns (uint256) {
        return uint256(keccak256(abi.encodePacked("bnbulls-duel-jackpot", nonce, address(this))));
    }

    /**
     * @notice Claim the right to pay the jackpot for one duel. Called by a
     *         wired pool at RESOLUTION time, once its ticket has already
     *         rolled a win.
     * @return claimed True the first time for a given duel, false every time
     *         after — which is what stops a winner taking both pots for one
     *         fight.
     *
     * @dev Deliberately NOT `whenNotPaused` (pausing new duels must not freeze
     *      payouts on tickets already in flight) and deliberately NOT
     *      `nonReentrant` (a duel's own `resolve` nudge runs inside
     *      `submitDuel`, which already holds the guard). Pure storage, no
     *      external calls, so it cannot revert on a wired caller.
     *
     *      Unknown callers get `false` rather than a revert: a stranger must
     *      not be able to pre-claim keys and quietly switch every payout off.
     */
    function claimJackpotForDuel(uint256 duelKey) external returns (bool claimed) {
        if (msg.sender != _wire(Wire.JackpotBnbull) && msg.sender != _wire(Wire.JackpotBnb)) {
            return false;
        }
        if (duelKey == 0) return false;
        if (duelJackpotPaid[duelKey]) return false;
        duelJackpotPaid[duelKey] = true;
        emit DuelJackpotClaimed(duelKey, msg.sender);
        return true;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice BNB/USD, 1e18-scaled, read off the wired `MintDrop`.
     *
     * @dev `DECISIONS.md §1`, option A, inherited whole: `MintDrop.bnbUsdPrice`
     *      REVERTS on a non-positive answer, an incomplete round, a zero
     *      timestamp, an answer older than its `maxOracleAge`, or a price
     *      outside its sanity band. **Nothing is clamped.** A clamped price is
     *      a wrong price presented as a right one, and here it would quote
     *      fights at a stake nobody chose.
     *
     *      An unwired MintDrop reverts too. That is fail-CLOSED on purpose:
     *      refusing to quote a BNB fight is recoverable in one transaction;
     *      quoting one off a stale peg is not.
     */
    function bnbUsdPrice() public view returns (uint256 price1e18) {
        address md = _wire(Wire.MintDrop);
        if (md == address(0)) revert OracleNotWired();
        return IMintDropOracle(md).bnbUsdPrice();
    }

    /**
     * @notice The FULL undiscounted sticker for `asset`, in that asset's own
     *         units. A keeper peg for BNBULL; the stored dollar figure
     *         converted through Chainlink for WBNB.
     * @dev Reverts if a priced BNB leg cannot reach a healthy oracle. Zero is
     *      returned without touching the feed, so an unpriced leg never depends
     *      on the wiring.
     */
    function stickerCost(address asset) public view returns (uint256) {
        if (asset == address(wbnb)) {
            uint256 usd = usdFightPrice1e18;
            if (usd == 0) return 0;
            return _ceilDiv(usd * 1e18, bnbUsdPrice());
        }
        return fightCostOf[asset];
    }

    /**
     * @notice What one fighter is charged to fight in `asset` right now: the
     *         full sticker less that asset's discount.
     *
     * @dev THE QUOTING VIEW. Settlement never calls it — `submitDuel` charges
     *      `stakeA`/`stakeB` exactly as signed. The signer and the UI read
     *      this to decide what to quote, so a keeper repeg (or an oracle tick)
     *      between quote and submit changes the NEXT fight's price, never the
     *      one already on the player's screen.
     *
     *      ⚠ STICKER FIRST, DISCOUNT SECOND. `stickerCost` converts the dollar
     *      anchor to BNB and the discount comes off the RESULT. Applying it to
     *      the dollar anchor as well would give 19% on a 10% setting — the
     *      double-discount trap documented on `fightCostOf`, which is easier to
     *      fall into now that one leg is a two-step conversion.
     */
    function fighterCost(address asset) public view returns (uint256) {
        if (asset == address(0)) return 0;
        uint256 cost = stickerCost(asset);
        uint16 bps = discountBpsOf[asset];
        if (bps == 0) return cost;
        return (cost * (BPS - bps)) / BPS;
    }

    /// @notice The sequence number a signer must put in the next result for
    ///         this wallet. THE call the signer makes before quoting.
    function nextFightSeq(address wallet) external view returns (uint64) {
        return fightSeq[wallet];
    }

    /// @notice Every registered stake asset, for the UI and the keepers.
    function getFightAssets() external view returns (address[] memory) {
        return fightAssets;
    }

    function fightAssetCount() external view returns (uint256) {
        return fightAssets.length;
    }

    /// @notice The wired Graveyard.
    function graveyardContract() external view returns (address) {
        return _wire(Wire.Graveyard);
    }

    /// @notice The wired yards roster. Zero means the membership check is OFF
    ///         — the deploy preflight must assert this is non-zero.
    /// @dev A separate getter rather than a fifth return on `wires()`, because
    ///      widening that tuple would break every existing caller in `script/`
    ///      and `test/` for no gain.
    function yardsContract() external view returns (address) {
        return _wire(Wire.Yards);
    }

    /// @notice Every live wiring address in one call — the read the deploy
    ///         preflight and the keepers use.
    function wires()
        external
        view
        returns (address graveyard, address jackpotBnbull, address jackpotBnb, address mintDrop)
    {
        return (
            _wire(Wire.Graveyard),
            _wire(Wire.JackpotBnbull),
            _wire(Wire.JackpotBnb),
            _wire(Wire.MintDrop)
        );
    }

    /**
     * @notice The EIP-712 digest of a `DuelResult`, as signed off chain.
     *
     * @dev Off-chain workflow (ethers v6 / viem):
     *
     *      const domain = {
     *        name: "BNBullsDuel",
     *        version: "1",
     *        chainId: 56,
     *        verifyingContract: duelAddr
     *      };
     *      const types = {
     *        DuelResult: [
     *          { name: "tokenA",   type: "uint256" },
     *          { name: "tokenB",   type: "uint256" },
     *          { name: "winnerId", type: "uint32"  },
     *          { name: "rounds",   type: "uint16"  },
     *          { name: "seed",     type: "uint256" },
     *          { name: "newEloA",  type: "uint32"  },
     *          { name: "newEloB",  type: "uint32"  },
     *          { name: "assetA",   type: "address" },
     *          { name: "assetB",   type: "address" },
     *          { name: "stakeA",   type: "uint256" },
     *          { name: "stakeB",   type: "uint256" },
     *          { name: "seqA",     type: "uint64"  },
     *          { name: "seqB",     type: "uint64"  },
     *          { name: "nonce",    type: "uint256" },
     *          { name: "expiry",   type: "uint256" },
     *        ],
     *      };
     *
     *      `seqA`/`seqB` come from `nextFightSeq(ownerA)` / `nextFightSeq(
     *      ownerB)` read at quote time. Sign, then submit `(result, sig)`.
     */
    function hashDuelResult(DuelResult calldata r) public view returns (bytes32) {
        // ⚠ Encoded in two halves and concatenated, NOT because that changes
        // the hash — every member is a value type, so `abi.encode` is just
        // 32-byte words laid end to end and the concatenation is byte-
        // identical to encoding all sixteen at once — but because encoding
        // sixteen in one expression is stack-too-deep on solc 0.8.24 without
        // via-IR, and this project builds with via-IR off. Do not "simplify"
        // it back into one call, and if a member is ever added, add it to the
        // TAIL and to the typehash string together.
        bytes memory head = abi.encode(
            DUEL_RESULT_TYPEHASH,
            r.tokenA,
            r.tokenB,
            r.winnerId,
            r.rounds,
            r.seed,
            r.newEloA,
            r.newEloB
        );
        bytes memory tail = abi.encode(
            r.assetA, r.assetB, r.stakeA, r.stakeB, r.seqA, r.seqB, r.nonce, r.expiry
        );
        return _hashTypedDataV4(keccak256(bytes.concat(head, tail)));
    }

    /// @notice The EIP-712 domain separator, so the dashboard can check the
    ///         signing config matches at a glance.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Graveyard hook
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Clear a bull's loss streak. Graveyard-only, called on revive.
    function resetStreak(uint256 tokenId) external {
        if (msg.sender != _wire(Wire.Graveyard)) revert NotGraveyard();
        consecutiveLosses[tokenId] = 0;
        emit StreakReset(tokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a stake asset with its permanent per-fighter ceiling.
     *         One-shot per asset: the ceiling can never be changed, so a later
     *         owner-key compromise can re-price within it but can never set a
     *         stake nobody can afford. Assets cannot be removed either — set
     *         the cost and stop signing duels in them to retire one.
     * @param asset   The ERC-20 to stake: WBNB or BNBULL (`DECISIONS.md §26`).
     * @param maxCost Ceiling in the asset's own units. ⚠ For WBNB this is the
     *                one bound that survives to PAY time on the oracle-derived
     *                leg — the dollar anchor is bounded by
     *                `MAX_USD_FIGHT_PRICE`, but the BNB amount it converts to
     *                depends on the feed, and only this stops a collapsed BNB
     *                price turning a $5 fight into an unaffordable one.
     * @param devBps  Dev cut for this asset. `type(uint16).max` takes
     *                `defaultDevShareBps`.
     */
    function addFightAsset(address asset, uint256 maxCost, uint16 devBps) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (maxCost == 0) revert ZeroMaxCost();
        if (maxFightCostOf[asset] != 0) revert AssetAlreadyAdded(asset);
        uint16 bps = devBps == type(uint16).max ? defaultDevShareBps : devBps;
        if (bps > MAX_DEV_BPS) revert DevShareTooHigh(bps);
        maxFightCostOf[asset] = maxCost;
        devShareBpsOf[asset] = bps;
        fightAssets.push(asset);
        emit FightAssetAdded(asset, maxCost, bps);
    }

    /// @notice The keeper's knob: repeg an asset's FULL undiscounted sticker
    ///         as prices move. Zero means that asset temporarily fights free
    ///         (still a valid duel asset).
    /// @dev ⚠ REFUSES WBNB. Its sticker is `usdFightPrice1e18` converted
    ///      through the oracle at read time (`DECISIONS.md §26`), so a stored
    ///      peg here would be a second source of truth that can only ever
    ///      disagree with the first — and disagree SILENTLY, because a stale
    ///      peg looks exactly like a fresh one. Use `setUsdFightPrice`.
    function setFightCost(address asset, uint256 cost) external onlyOwner {
        if (asset == address(wbnb)) revert OraclePricedAsset(asset);
        uint256 ceiling = maxFightCostOf[asset];
        if (ceiling == 0) revert UnsupportedAsset(asset);
        if (cost > ceiling) revert FightCostTooHigh(cost);
        fightCostOf[asset] = cost;
        emit FightCostChanged(asset, cost);
    }

    /**
     * @notice Set the dollar anchor: what one fighter is charged, as a plain
     *         1e18-scaled dollar figure. Zero unprices the BNB leg.
     *
     * @dev THE `§1` OPTION-A SETTER. It replaces the keeper's WBNB peg
     *      entirely, and it is a DOLLAR figure on purpose: it does not need
     *      re-pegging when BNB moves, because the feed does that job. The only
     *      reason to touch it is an actual change of price policy.
     *
     *      Bounded by `MAX_USD_FIGHT_PRICE` so a compromised owner key cannot
     *      re-price fights absurdly — and bounded again, in the asset's own
     *      units at pay time, by the one-shot `maxFightCostOf[wbnb]` that
     *      `_takeSide` enforces on every signed stake.
     */
    function setUsdFightPrice(uint256 usd1e18) external onlyOwner {
        if (usd1e18 > MAX_USD_FIGHT_PRICE) revert FightCostTooHigh(usd1e18);
        usdFightPrice1e18 = usd1e18;
        emit UsdFightPriceChanged(usd1e18);
    }

    /// @notice Retune one asset's dev cut.
    function setDevShareBps(address asset, uint16 bps) external onlyOwner {
        if (maxFightCostOf[asset] == 0) revert UnsupportedAsset(asset);
        if (bps > MAX_DEV_BPS) revert DevShareTooHigh(bps);
        devShareBpsOf[asset] = bps;
        emit DevShareChanged(asset, bps);
    }

    /// @notice The dev cut applied to assets registered from now on.
    function setDefaultDevShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_DEV_BPS) revert DevShareTooHigh(bps);
        defaultDevShareBps = bps;
        emit DefaultDevShareChanged(bps);
    }

    function setDevTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit DevTreasuryChanged(devTreasury, next);
        devTreasury = next;
    }

    /// @notice Set an asset's discount. Generic on purpose (`DECISIONS.md
    ///         §2`) even though only BNBULL carries one at launch.
    function setDiscountBps(address asset, uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert InvalidShare(bps);
        discountBpsOf[asset] = bps;
        emit DiscountSet(asset, bps);
    }

    /**
     * @notice Raise the stake an asset must carry before a decisive duel opens
     *         a jackpot ticket (`DECISIONS.md §25`).
     * @dev    Purely additive. Zero is the default and is SAFE: `_rollOnePool`
     *         refuses a zero stake unconditionally, so a forgotten call here
     *         cannot reopen the free-ticket hole. Bounded by the asset's
     *         one-shot `maxFightCostOf` ceiling so a compromised owner key
     *         cannot set a floor above any affordable stake and quietly switch
     *         ticketing off for everyone — the pot would fill and never issue.
     */
    function setMinTicketStake(address asset, uint256 minStake) external onlyOwner {
        uint256 ceiling = maxFightCostOf[asset];
        if (ceiling != 0 && minStake > ceiling) revert FightCostTooHigh(minStake);
        minTicketStakeOf[asset] = minStake;
        emit MinTicketStakeSet(asset, minStake);
    }

    /// @notice Retune the share of the dev cut that feeds the pots.
    function setPotShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_POT_SHARE_BPS) revert InvalidShare(bps);
        potShareBps = bps;
        emit PotShareChanged(bps);
    }

    /**
     * @notice Retune the death threshold. THE setter that fefers could not
     *         have: `CONSECUTIVE_LOSSES_TO_DIE` was a constant behind a
     *         one-time-set wiring slot, and a later request for four losses
     *         was impossible without redeploying the collection.
     * @dev Raising it does not resurrect anything already dead; lowering it
     *      does not retroactively kill — a bull already carrying a streak at
     *      or above the new threshold dies on its NEXT loss.
     */
    function setLossesToDie(uint8 losses) external onlyOwner {
        if (losses < MIN_LOSSES_TO_DIE || losses > MAX_LOSSES_TO_DIE) {
            revert LossThresholdOutOfRange(losses);
        }
        lossesToDie = losses;
        emit LossesToDieChanged(losses);
    }

    function setJackpotResolvePerDuel(uint8 count) external onlyOwner {
        if (count > MAX_JACKPOT_RESOLVE_PER_DUEL) revert ResolveCountOutOfRange(count);
        jackpotResolvePerDuel = count;
        emit JackpotResolvePerDuelChanged(count);
    }

    function setTrustedSigner(address next) external onlyOwner {
        if (next == address(0)) revert SignerMustBeNonZero();
        emit TrustedSignerChanged(trustedSigner, next);
        trustedSigner = next;
    }

    /**
     * @notice Allow (or forbid) two bulls in the same wallet to fight.
     * @dev An OWNER CALL with consequences, so read the header before flipping
     *      it. On: a wallet can farm jackpot tickets against itself for the
     *      price of the dev cut, and any misbehaving bot can hunt its own
     *      stable's weakest bull to death. Off (the default) that is
     *      impossible by bytecode.
     */
    function setAllowSelfDuel(bool allowed) external onlyOwner {
        allowSelfDuel = allowed;
        emit AllowSelfDuelChanged(allowed);
    }

    /// @notice Wire the Marketplace. Zero disables the listing lockout.
    function setMarketplace(address next) external onlyOwner {
        emit MarketplaceSet(marketplace, next);
        marketplace = next;
    }

    /// @notice Wire a router. Non-zero makes it the sole entrypoint; zero
    ///         restores the direct owner-submits path.
    function setAuthorizedRouter(address next) external onlyOwner {
        emit AuthorizedRouterSet(authorizedRouter, next);
        authorizedRouter = next;
    }

    function setSocials(string calldata w, string calldata t, string calldata g)
        external
        onlyOwner
    {
        website = w;
        twitter = t;
        telegram = g;
        emit SocialsChanged(w, t, g);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Admin: timelocked wiring ────────────────────────────────────────

    function bootstrapWire(Wire slot, address target) external onlyOwner {
        _wires[uint8(slot)].bootstrap(target);
        emit WireBootstrapped(slot, target);
    }

    function proposeWire(Wire slot, address target) external onlyOwner returns (uint64 eta) {
        eta = _wires[uint8(slot)].propose(target, wiringDelay);
        emit WireProposed(slot, target, eta);
    }

    function commitWire(Wire slot) external onlyOwner {
        (address previous, address next) = _wires[uint8(slot)].commit();
        emit WireCommitted(slot, previous, next);
    }

    function cancelWire(Wire slot) external onlyOwner {
        address dropped = _wires[uint8(slot)].cancel();
        emit WireCancelled(slot, dropped);
    }

    function wireOf(Wire slot)
        external
        view
        returns (address current, address pending, uint64 eta)
    {
        TimelockedAddress.Slot storage s = _wires[uint8(slot)];
        return (s.current, s.pending, s.eta);
    }

    function setWiringDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_WIRING_DELAY || newDelay > MAX_WIRING_DELAY) {
            revert DelayOutOfRange(newDelay);
        }
        wiringDelay = newDelay;
        emit WiringDelayChanged(newDelay);
    }

    function _wire(Wire slot) private view returns (address) {
        return _wires[uint8(slot)].current;
    }

    /**
     * @notice Recover a token sent here by mistake.
     * @dev Stakes are pulled and paid out inside one transaction, so this
     *      contract holds no player money between calls and there is nothing
     *      here for this to steal. There is deliberately no native rescue: the
     *      only BNB that ever touches this contract is a stake being wrapped
     *      or a refund going straight back out in the same call.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @dev Rounds UP, matching `MintDrop`, `Graveyard` and `Marketplace`, so a
    ///      rounding artefact can never quote a fighter a hair under the
    ///      sticker.
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
