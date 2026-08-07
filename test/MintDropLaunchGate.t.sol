// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BnbullsBase} from "./Base.t.sol";
import {Bulls} from "../contracts/Bulls.sol";
import {MintDrop} from "../contracts/MintDrop.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MintDropLaunchGateTest
 * @notice **The "start minting" switch**, as the owner asked for it on
 *         2026-08-07: *"make sure there is a 'start minting' switch so mints
 *         only start when we say so (aka straight after four.meme deploy)."*
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      WHAT WAS ACTUALLY WRONG, AND WHY IT LOOKED FINE
 *      ══════════════════════════════════════════════════════════════════════
 *      `MintDrop` already had `pause()` / `unpause()`, and both mint
 *      entrypoints already carried `whenNotPaused`. So a grep answered "yes,
 *      there is a switch" — and the answer was wrong in the only way that
 *      mattered: **OpenZeppelin's `Pausable` initialises `_paused = false`, and
 *      the constructor never called `_pause()`. The drop shipped OPEN.**
 *
 *      `script/Verify.s.sol` then *asserted* `!m.paused()`, so the pre-launch
 *      checklist actively required minting to be live. Two independent pieces
 *      of the deploy path agreed on the wrong default, which is precisely why
 *      neither looked suspicious on its own.
 *
 *      The window that opens is short and unrecoverable: between `Deploy` and
 *      the four.meme launch, the **$10 rung** of the `§12` ladder — the
 *      cheapest the drop will ever be — belongs to whoever watches the mempool,
 *      and every BNBULL leg on those mints defers (`§29`, no pool yet).
 *
 *      ⚠ THE TEST THAT MATTERS IS `test_theDropShipsClosed`. Everything else
 *      here would pass just as happily against the broken version.
 */
contract MintDropLaunchGateTest is BnbullsBase {
    /// @dev A fresh, unwired `MintDrop` — the exact thing `Deploy.s.sol`
    ///      produces. The inherited `drop` is deliberately NOT used: the base
    ///      `setUp` unpauses it, so it cannot answer the constructor question.
    function _freshDrop() internal returns (MintDrop d) {
        d = new MintDrop(
            MintDrop.DeployParams({
                initialOwner: owner,
                bulls: address(bulls),
                bnbull: address(bnbull),
                wbnb: address(wbnb),
                treasury: treasury,
                lpTreasury: lpTreasury
            })
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The guarantee
    // ══════════════════════════════════════════════════════════════════════

    /// @notice ⚠ THE REGRESSION GUARD. A newly deployed drop is CLOSED.
    ///         Delete `_pause()` from the constructor and only this fails.
    function test_theDropShipsClosed() public {
        MintDrop d = _freshDrop();
        assertTrue(d.paused(), "a freshly deployed MintDrop must be CLOSED");
    }

    /// @notice Both paid entrypoints are shut, not just the BNB one.
    function test_bothMintEntrypointsAreShutBeforeGoLive() public {
        MintDrop d = _freshDrop();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.mintWithBNB{value: 1 ether}(alice, 1);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.mintWithBNBULL(alice, 1);
    }

    /// @notice `unpause()` IS the start switch: the same call that failed
    ///         succeeds once it is pulled.
    function test_unpauseIsTheStartSwitchAndMintingThenWorks() public {
        // The inherited `drop` is fully wired by the base; re-close it so this
        // exercises the real go-live transition rather than a bare constructor.
        drop.pause();
        assertTrue(drop.paused());

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        drop.mintWithBNB{value: 2 ether}(alice, 1);

        drop.unpause();
        assertFalse(drop.paused(), "the switch must actually open it");

        uint256 before = bulls.balanceOf(alice);
        vm.prank(alice);
        drop.mintWithBNB{value: 2 ether}(alice, 1);
        assertEq(bulls.balanceOf(alice) - before, 1, "the same mint now succeeds");
    }

    /// @notice Only the owner may open the drop. A public `unpause` would make
    ///         the whole gate decorative.
    function test_onlyTheOwnerCanStartMinting() public {
        MintDrop d = _freshDrop();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        d.unpause();
        assertTrue(d.paused(), "still closed");
    }

    /// @notice The emergency stop still exists after go-live. `pause()` is not
    ///         consumed by having been the launch gate.
    function test_theEmergencyStopStillWorksAfterGoLive() public {
        drop.pause();
        drop.unpause();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        drop.mintWithBNB{value: 2 ether}(alice, 1);

        drop.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        drop.mintWithBNB{value: 2 ether}(alice, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ⚠ The gate must not block the deploy sequence itself
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Wiring, configuration and pot funding all still work while the
     *         drop is closed.
     *
     * @dev This is the half that makes shipping-closed SAFE rather than merely
     *      strict. The launch order is deploy → wire → verify → fund → open, so
     *      if `whenNotPaused` had leaked onto the wiring or the donation path,
     *      the gate would have made its own deploy sequence unrunnable and the
     *      only way out would have been to open mints early — the exact thing
     *      it exists to prevent.
     */
    function test_theDeploySequenceRunsFullyWhileStillClosed() public {
        MintDrop d = _freshDrop();
        assertTrue(d.paused());

        // Wiring.
        d.bootstrapWire(MintDrop.Wire.PriceFeed, address(feed));
        d.bootstrapWire(MintDrop.Wire.JackpotBnbull, address(potBnbull));
        d.bootstrapWire(MintDrop.Wire.JackpotBnb, address(potBnb));
        potBnbull.setFunder(address(d), true);
        potBnb.setFunder(address(d), true);

        // Configuration.
        d.setKeeper(keeper);

        // Funding the pots — the money layer comes up before the doors open.
        vm.deal(owner, 3 ether);
        d.donatePotNative{value: 3 ether}();
        assertGt(potBnb.pool(), 0, "the BNB pot funds while the drop is shut");

        // And the oracle answers, so `Verify` can do its job pre-launch.
        assertGt(d.bnbUsdPrice(), 0);

        // Still closed the whole time.
        assertTrue(d.paused(), "nothing in the deploy sequence opened the drop");
    }
}
