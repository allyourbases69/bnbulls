// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PotSplitter} from "./lib/PotSplitter.sol";

/**
 * @title MintBnbullSplitter
 * @notice The house pot-routing policy as a standalone, never-fail money sink.
 *         Send it BNB or BNBULL and it applies `DECISIONS.md §13` — **20%
 *         BNBULL pot / 10% BNB pot / 70% dev** — except that a BNBULL payment
 *         routes **30% BNBULL pot / 0% BNB / 70% dev and sells nothing**
 *         (`§14`).
 *
 * @custom:website   https://bnbulls.xyz
 * @custom:twitter   https://x.com/WeAreBNBulls
 * @custom:telegram  https://t.me/WeAreBNBulls
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT IT IS FOR
 *      ══════════════════════════════════════════════════════════════════════
 *      This is the bnbulls descendant of the fefers `MintFightSplitter`, and it
 *      exists for the same reason: **the LP-slot trick**
 *      (`BNBULLS-BOOTSTRAP.md §6`). `MintDrop` carries an owner-settable payout
 *      slot — `lpTreasury` / `lpShareBps` — that is unused at launch
 *      (`lpShareBps = 0`) and deliberately kept available. On the native mint
 *      path `MintDrop._routeNative` forwards that slice with a bare
 *      `lpTreasury.call{value: lpShare}("")`; on the ERC-20 paths
 *      `MintDrop._routeToken` forwards it with a plain `safeTransfer`.
 *
 *      Point `lpTreasury` here, set `lpShareBps`, and a whole extra buyback leg
 *      joins the mint money path with **no redeploy of MintDrop at all**. On
 *      fefers that trick was a necessity, because MintDrop was frozen. Here it
 *      is insurance and extensibility: phase-2 egg sales, a Duel dev-cut leg,
 *      or a second mint contract can all be pointed at this one address and
 *      inherit the house split without any of them re-implementing it.
 *
 *      Because MintDrop has already taken its own 20/10 pot slices before it
 *      sends the LP slice, what arrives here is **dev-side money the owner has
 *      chosen to put back through the policy**. Applying the policy to it again
 *      is not double-dipping; it is exactly the dial `lpShareBps` is for.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      ⚠ `receive()` MUST NEVER REVERT — EVERY NATIVE MINT DEPENDS ON IT
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop._routeNative` does `if (!ok) revert LpTransferFailed();` on
 *      that bare call. **If this `receive()` reverts, every native mint in the
 *      game bricks.** So it does exactly three things, none of which can fail:
 *
 *        1. computes the split with plain arithmetic on values that cannot
 *           overflow (shares are bps of `msg.value`, bounded by
 *           `MAX_TOTAL_POT_BPS`);
 *        2. calls the two `…OrAccrue` legs in `PotSplitter`, each of which is
 *           `try this.…Inline() catch { accrue }` behind a cheap pre-check;
 *        3. emits. The retained remainder is simply left as balance.
 *
 *      There is deliberately no `nonReentrant` on it: `ReentrancyGuard` reverts,
 *      and a reverting modifier is precisely the brick this pattern exists to
 *      avoid. See the note in `PotSplitter` for why that is safe here.
 *
 *      ══════════════════════════════════════════════════════════════════════
 *      THE DEV SHARE IS *RETAINED*, NOT FORWARDED
 *      ══════════════════════════════════════════════════════════════════════
 *      The 70% is left as this contract's balance and withdrawn by the owner
 *      through `withdrawUnreserved`, rather than pushed to a treasury address
 *      inside `receive()`. That is not laziness: a push to a treasury that
 *      reverts — a blacklisted USDT recipient, a multisig mid-upgrade, a
 *      contract with an expensive fallback — would revert the mint. The one
 *      thing that can never fail is not doing anything at all.
 */
contract MintBnbullSplitter is PotSplitter {
    /// @notice A pull could not be completed, so nothing was routed and the
    ///         caller keeps its money. Emitted instead of reverting.
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
    //  Entrypoints
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice THE LP-SLOT HOOK. `MintDrop`'s bare native call lands here.
     * @dev NEVER REVERTS. See the header.
     */
    receive() external payable {
        _route(PotSource.Native, msg.value);
    }

    /// @notice The same thing behind a selector, for a caller that would rather
    ///         send with calldata than rely on a bare value transfer.
    /// @dev NEVER REVERTS.
    function routeNative() external payable {
        _route(PotSource.Native, msg.value);
    }

    /**
     * @notice Push a token slice through the policy in one call: pull `amount`
     *         from the caller, then split it.
     *
     * @dev NEVER REVERTS — including the pull, which is wrapped so that a
     *      caller with a missing allowance gets a `PullFailed` event and keeps
     *      its money rather than having its own transaction reverted. That
     *      matters because a future caller may be a frozen contract with no
     *      try/catch of its own, exactly like the Graveyard is for
     *      `ReviveBuySplitter`.
     *
     *      `MintDrop`'s own ERC-20 LP slice does NOT arrive this way — a plain
     *      `safeTransfer` gives this contract no callback — so those balances
     *      pile up and the keeper puts them through `routeHeld`.
     */
    function routePayment(address asset, uint256 amount) external {
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

    /// @notice The measured pull. `external` ONLY so `routePayment` can
    ///         try/catch it; `NotSelf` makes it unreachable to anyone else.
    function pullInline(address asset, address from, uint256 amount)
        external
        returns (uint256 received)
    {
        if (msg.sender != address(this)) revert NotSelf();
        return _pullMeasured(IERC20(asset), from, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The split rule — DECISIONS §13 + §14
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev 20% BNBULL / 10% BNB / 70% retained, except that a BNBULL payment
     *      routes 30% BNBULL / 0% BNB / 70% retained and touches no DEX.
     *
     *      The three numbers are read live off `MintDrop` (`potPolicy`) rather
     *      than duplicated here, so there is ONE place on chain where the house
     *      split lives. If that read is unavailable the local fallback — which
     *      launches at the same 2000 / 1000 / never-sell — is used instead.
     *
     *      CANNOT REVERT.
     */
    function _route(PotSource src, uint256 amount) internal override {
        if (amount == 0) return;
        (uint256 bnbullBps, uint256 bnbBps, bool sells) = potPolicy();

        uint256 potBnbull = (amount * bnbullBps) / BPS;
        uint256 potBnb = (amount * bnbBps) / BPS;

        // `DECISIONS.md §14`: never sell BNBULL. Read literally, "20/10/70 on
        // everything" would have a BNBULL payment sell 10% of itself to fund
        // the BNB pot — the game dumping the one token whose chart its holders
        // watch, partly cancelling the buy pressure the pot exists to create.
        // It does not. The slice joins the BNBULL pot instead.
        if (src == PotSource.Bnbull && !sells) {
            potBnbull += potBnb;
            potBnb = 0;
        }

        uint256 retained = amount - potBnbull - potBnb;

        _toBnbullPotOrAccrue(src, potBnbull);
        _toBnbPotOrAccrue(src, potBnb);
        if (retained > 0) emit Retained(src, retained);
    }
}
