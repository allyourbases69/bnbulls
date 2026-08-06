// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PotSplitter} from "./lib/PotSplitter.sol";

/**
 * @title ReviveBuySplitter
 * @notice Sits on the revive money path, in front of `MintDrop`. The
 *         `Graveyard` takes its 70% dev cut and donates the remaining pot slice
 *         to whatever address sits in its `mintDrop` slot. Point that slot here
 *         and the slice is divided between the two no-withdraw pots in the
 *         live `bnbullShareBps : bnbShareBps` ratio — 2:1 at launch, so a
 *         revive ends up at the same **20% BNBULL / 10% BNB / 70% dev** as
 *         everything else (`DECISIONS.md §13`). A BNBULL-denominated revive
 *         routes **30% BNBULL / 0% BNB** and sells nothing (`§14`).
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      ⚠ THE ENTRYPOINTS MUST NEVER REVERT — EVERY REVIVE DEPENDS ON IT
 *      ══════════════════════════════════════════════════════════════════════
 *      On fefers the `Graveyard` called `donateJackpotBuy{value}()` on its
 *      `mintDrop` slot **with no try/catch on its side**. If that entrypoint
 *      reverted, every revive in the game — owner ladder and takeover alike —
 *      was bricked for every token, forever, on a contract nobody could patch.
 *      The bnbulls `MintDrop` inherits the shape: `donatePotNative()` is
 *      documented as "NOT PAUSABLE, AND IT MUST NOT REVERT" for exactly this
 *      reason.
 *
 *      **This contract implements the same two selectors on purpose** —
 *      `donatePotNative()` and `donatePotToken(address,uint256)` — so the
 *      Graveyard's slot can be repointed at it with no other change anywhere,
 *      and repointed back just as easily. Both are never-fail:
 *
 *        - the split is plain arithmetic that cannot overflow or divide by
 *          zero (the zero-total case is handled explicitly);
 *        - each pot leg is `try this.…Inline() catch { accrue }` behind a cheap
 *          pre-check, per `BNBULLS-BOOTSTRAP.md §6`;
 *        - even the ERC-20 PULL is wrapped. A missing allowance emits
 *          `PullFailed` and returns; it does not revert the Graveyard's
 *          transaction. A revive must not fail because a donation could not be
 *          collected;
 *        - there is deliberately no `nonReentrant` on either entrypoint —
 *          `ReentrancyGuard` reverts, and a reverting modifier on a never-fail
 *          entrypoint is the brick this pattern exists to prevent. See the note
 *          in `PotSplitter`.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHY 100% OF WHAT ARRIVES GOES TO THE POTS
 *      ══════════════════════════════════════════════════════════════════════
 *      Unlike `MintBnbullSplitter`, this contract keeps nothing. The caller has
 *      ALREADY taken its dev cut before donating — that is what makes the
 *      end-to-end revive split 20/10/70 rather than 20/10 of 30%. The ratio
 *      between the two pots is read live off `MintDrop` so the policy has one
 *      source of truth on chain, exactly as `MintDrop._potSplit` divides a
 *      donation.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      WHAT CHANGED FROM THE FEFERS VERSION, AND WHY
 *      ══════════════════════════════════════════════════════════════════════
 *      The fefers `ReviveBuySplitter` split its slice 50/50 and forwarded the
 *      $FEFER half back into the real MintDrop's own buyback, because MintDrop
 *      was frozen and could not be taught the second leg. Here MintDrop is not
 *      frozen and this contract does both legs itself, so there is no pipe to
 *      forward to and no second never-fail hop to get wrong. Gone with it:
 *      `NATIVE_TO_ERC20 = 1e12`, the 6-dp USDT0 view of a native balance, and
 *      the sub-1e12 dust accounting — none of which has any meaning on BNB
 *      Chain, where BNB is a real, volatile, 18-dp gas token that gives this
 *      contract no ERC-20 balance whatsoever. Gone too, by `DECISIONS.md §26`:
 *      the stablecoin donation leg. BNB and BNBULL are the only two currencies
 *      that can arrive here.
 */
contract ReviveBuySplitter is PotSplitter {
    /// @notice A donation's pull could not be completed, so nothing was routed
    ///         and the caller keeps its money. Emitted instead of reverting.
    event PullFailed(address indexed asset, address indexed from, uint256 amount);
    /// @notice An asset other than the wired BNBULL was offered. Ignored rather
    ///         than rejected, so a mis-wired caller cannot brick itself on us.
    event UnsupportedAssetIgnored(address indexed asset, uint256 amount);

    /**
     * @param initialOwner Owner. A zero here is caught by Ownable's own
     *                     constructor, which runs first.
     * @param _wbnb        Wrapped BNB (0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c).
     * @param _keeper      May publish the swap floors and run the sweeps.
     */
    constructor(address initialOwner, address _wbnb, address _keeper)
        PotSplitter(initialOwner, _wbnb, _keeper)
    {}

    // ══════════════════════════════════════════════════════════════════════
    //  Entrypoints — same selectors as MintDrop, so the slot just repoints
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Accept a BNB pot donation and split it across the two pots.
     * @dev NEVER REVERTS, and deliberately not pausable. This is the selector
     *      the Graveyard calls un-guarded on every native revive.
     */
    function donatePotNative() external payable {
        _route(PotSource.Native, msg.value);
    }

    /**
     * @notice The same, paid in BNBULL — the only ERC-20 payment currency left
     *         (`DECISIONS.md §26`). Approve `amount` first; the pull is
     *         measured, so what gets split is what actually arrived.
     * @dev NEVER REVERTS. An unsupported asset or a failed pull emits and
     *      returns rather than reverting the caller's revive.
     *
     *      ⚠ The `(address,uint256)` shape is KEPT even though there is only
     *      one legal asset: it is the selector `MintDrop.donatePotToken` and
     *      `Graveyard.routePotTokenInline` speak, and the whole point of this
     *      contract is that the Graveyard's slot can be repointed at it with no
     *      other change anywhere.
     */
    function donatePotToken(address asset, uint256 amount) external {
        if (amount == 0) return;

        if (asset == address(0) || asset != _wire(Wire.Bnbull)) {
            emit UnsupportedAssetIgnored(asset, amount);
            return;
        }

        try this.pullInline(asset, msg.sender, amount) returns (uint256 received) {
            _route(PotSource.Bnbull, received);
        } catch {
            emit PullFailed(asset, msg.sender, amount);
        }
    }

    /// @notice The measured pull. `external` ONLY so `donatePotToken` can
    ///         try/catch it; `NotSelf` makes it unreachable to anyone else, so
    ///         it is not a way to move somebody else's approved balance.
    function pullInline(address asset, address from, uint256 amount)
        external
        returns (uint256 received)
    {
        if (msg.sender != address(this)) revert NotSelf();
        return _pullMeasured(IERC20(asset), from, amount);
    }

    /// @dev Bare native sends are treated as a donation, so a value transfer
    ///      that arrives without calldata is routed rather than sitting as
    ///      untracked residue. NEVER REVERTS.
    receive() external payable {
        _route(PotSource.Native, msg.value);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The split rule — 100% to the pots, in the live ratio
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev Divide a pot-only amount in the configured `bnbullShareBps :
     *      bnbShareBps` ratio (2:1 at launch). With both shares at zero — pots
     *      disabled — it all goes to the BNBULL leg rather than dividing by
     *      zero or silently vanishing, matching `MintDrop._potSplit`.
     *
     *      `DECISIONS.md §14`: a BNBULL donation is never sold, so the whole
     *      amount goes to the BNBULL pot and no DEX is touched.
     *
     *      CANNOT REVERT.
     */
    function _route(PotSource src, uint256 amount) internal override {
        if (amount == 0) return;
        (uint256 bnbullBps, uint256 bnbBps, bool sells) = potPolicy();

        uint256 toBnbull;
        uint256 toBnb;
        uint256 total = bnbullBps + bnbBps;
        if (total == 0) {
            toBnbull = amount;
        } else {
            toBnbull = (amount * bnbullBps) / total;
            toBnb = amount - toBnbull;
        }

        if (src == PotSource.Bnbull && !sells) {
            toBnbull = amount;
            toBnb = 0;
        }

        _toBnbullPotOrAccrue(src, toBnbull);
        _toBnbPotOrAccrue(src, toBnb);
    }
}
