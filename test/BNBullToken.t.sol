// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BNBull} from "../contracts/BNBull.sol";

/**
 * @title BNBullTokenTest
 * @notice The fallback fixed-supply BEP-20.
 *
 * @dev ⚠ THIS MAY NOT BE THE TOKEN THAT SHIPS. `DECISIONS.md §4` picks
 *      **four.meme**, and a four.meme launch means the token contract is
 *      theirs. This one is the self-seeded, LP-locked PancakeSwap path, built
 *      so the choice stays open to launch week — so it is tested to the same
 *      standard as everything else.
 *
 *      TWO THINGS MATTER MOST HERE.
 *
 *      1. **THE ORDER OF THE ONE-WAY SWITCHES.**
 *         `LEARNINGS-AND-MISTAKES §A`: "`liftLimits()` is one-way; renouncing
 *         ownership first makes the launch caps (maxWallet/maxTx) permanent and
 *         chokes the token forever." `test_renouncingBeforeLiftingLimits...`
 *         reproduces exactly that dead end, on purpose, so the deploy runbook
 *         has a test to point at.
 *
 *      2. **NO TRANSFER GATE SURVIVES LAUNCH.** `BNB-CHAIN-FACTS.md §5`: a game
 *         that does `transferFrom` in its flows (mint stake, fight purse,
 *         marketplace) **bricks on a token with a transfer gate**. The launch
 *         arsenal here is real but every piece of it is one-way DISARMABLE, and
 *         `lockBlacklist()` can only ever loosen the token: `unblacklist` keeps
 *         working afterwards, adding does not.
 */
contract BNBullTokenTest is Test {
    BNBull internal token;

    address internal owner;
    address internal holder = address(0x401DE2);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000e18;

    function setUp() public {
        owner = address(this);
        token = new BNBull(holder, owner, SUPPLY);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Identity and supply
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `DECISIONS.md §13`: the ticker is **BNBULL**, LOCKED. (The ERC-721
    ///      collection symbol is the separate `BNBULLS`, §15.)
    function test_theTickerIsLocked() public view {
        assertEq(token.name(), "BNBull");
        assertEq(token.symbol(), "BNBULL");
        assertEq(token.decimals(), 18);
    }

    function test_theSupplyIsFixedAtConstructionAndThereIsNoMintPath() public {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.fixedSupply(), SUPPLY);
        assertEq(token.balanceOf(holder), SUPPLY);

        string[3] memory noSuchThing =
            ["mint(address,uint256)", "setSupply(uint256)", "issue(uint256)"];
        for (uint256 i = 0; i < noSuchThing.length; i++) {
            (bool ok,) = address(token).call(
                abi.encodeWithSignature(noSuchThing[i], alice, uint256(1))
            );
            assertFalse(ok, "a mint path exists on a fixed-supply token");
        }
    }

    function test_theConstructorRefusesNonsense() public {
        vm.expectRevert(BNBull.ZeroInitialHolder.selector);
        new BNBull(address(0), owner, SUPPLY);

        vm.expectRevert(BNBull.ZeroSupply.selector);
        new BNBull(holder, owner, 0);

        uint256 cap = token.MAX_FIXED_SUPPLY();
        vm.expectRevert(abi.encodeWithSelector(BNBull.SupplyTooHigh.selector, cap + 1, cap));
        new BNBull(holder, owner, cap + 1);
    }

    function test_theLaunchCapsStartAtOneAndAHalfPercent() public view {
        assertEq(token.maxWallet(), SUPPLY / 100, "1% wallet cap");
        assertEq(token.maxTx(), SUPPLY / 200, "0.5% tx cap");
        assertTrue(token.limitsActive());
        assertFalse(token.tradingEnabled());
        assertTrue(token.whitelisted(owner));
        assertTrue(token.whitelisted(holder));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Trading gate
    // ══════════════════════════════════════════════════════════════════════

    function test_nothingButWhitelistedSetupMovesBeforeTradingOpens() public {
        // Whitelisted sender: setup transfers work.
        vm.prank(holder);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);

        // Two non-whitelisted parties: closed.
        vm.prank(alice);
        vm.expectRevert(BNBull.TradingNotEnabled.selector);
        token.transfer(bob, 1e18);
    }

    function test_enableTradingIsOneWayAndStampsTheLaunchBlock() public {
        vm.roll(100);
        token.enableTrading();
        assertTrue(token.tradingEnabled());
        assertEq(token.launchBlock(), 100);

        vm.expectRevert(BNBull.AlreadyEnabled.selector);
        token.enableTrading();

        vm.prank(alice);
        vm.expectRevert();
        token.enableTrading();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Anti-bot window
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Catches atomic block-0 snipers: a non-whitelisted CONTRACT that
    ///      receives tokens inside the window is blocked. EOAs always pass.
    function test_aContractReceiverInsideTheWindowIsBlocked() public {
        vm.prank(holder);
        token.transfer(alice, 10_000e18);
        vm.roll(100);
        token.enableTrading();

        address sniper = address(new Sniper());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BNBull.SniperBlocked.selector, sniper));
        token.transfer(sniper, 1_000e18);
        assertEq(token.balanceOf(sniper), 0);

        // An EOA in the same block is untouched.
        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
    }

    /**
     * @notice ⚠ FINDING — the "auto-blacklist" does not persist, and its event
     *         never fires.
     *
     * @dev `_update` does
     *
     *          blacklisted[to] = true;
     *          emit Blacklisted(to, "anti-bot");
     *          revert SniperBlocked(to);
     *
     *      The `revert` discards BOTH the storage write and the log. So the
     *      contract's own documentation —
     *
     *        "Anti-bot: for `antiBotBlocks` after trading opens, a
     *         non-whitelisted CONTRACT that receives tokens is
     *         **auto-blacklisted** and the transfer reverts."
     *
     *      — is not what happens. The transfer is blocked (which is the
     *      protection that matters), but the sniper is NOT recorded, is free to
     *      transact the moment the window closes, and no `Blacklisted` event is
     *      ever emitted for it.
     *
     *      Consequences, in order of how much they matter:
     *        - A launch-day keeper subscribing to `Blacklisted(addr,
     *          "anti-bot")` to build a sniper list receives nothing. That log
     *          does not exist on chain, ever.
     *        - `blacklisted` only ever grows through the manual `blacklist()`
     *          call, so `lockBlacklist()` seals a list that never contained an
     *          auto-entry.
     *        - No funds are at risk, and the fail-safe direction is arguably the
     *          nicer one (an aggregator caught by the window is not permanently
     *          banned).
     *
     *      FIX: either drop the write and the event and rename the mechanism to
     *      what it is (a contract-receiver block), or keep the ban by NOT
     *      reverting — accept the transfer into a blacklisted address so the
     *      write survives — which is a real behavioural choice, not a typo.
     *
     *      ⚠ THE ASSERTIONS BELOW DOCUMENT TODAY'S BEHAVIOUR.
     */
    function test_FINDING_theAntiBotAutoBlacklistIsDiscardedByItsOwnRevert() public {
        vm.prank(holder);
        token.transfer(alice, 10_000e18);
        vm.roll(100);
        token.enableTrading();

        address sniper = address(new Sniper());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BNBull.SniperBlocked.selector, sniper));
        token.transfer(sniper, 1_000e18);

        assertFalse(
            token.blacklisted(sniper),
            "FINDING no longer reproduces - the auto-blacklist now persists; invert this test"
        );

        // ...and once the window closes it trades freely, never having been
        // recorded.
        vm.roll(block.number + token.antiBotBlocks() + 1);
        vm.prank(alice);
        token.transfer(sniper, 1_000e18);
        assertEq(token.balanceOf(sniper), 1_000e18);
    }

    function test_theWindowClosesAndOrdinaryContractsPassAfterwards() public {
        vm.prank(holder);
        token.transfer(alice, 10_000e18);
        vm.roll(100);
        token.enableTrading();

        address pool = address(new Sniper());
        vm.roll(100 + token.antiBotBlocks() + 1);
        vm.prank(alice);
        token.transfer(pool, 1_000e18);
        assertEq(token.balanceOf(pool), 1_000e18);
        assertFalse(token.blacklisted(pool));
    }

    /// @dev A whitelisted contract — the router, the pair, MintDrop, Duel, the
    ///      Marketplace, both pots — bypasses the window entirely. Getting this
    ///      wrong would auto-blacklist the game's own contracts at launch.
    function test_whitelistedGameContractsBypassTheWindow() public {
        address[] memory game = new address[](2);
        game[0] = address(new Sniper());
        game[1] = address(new Sniper());
        token.setWhitelistBulk(game, true);

        vm.prank(holder);
        token.transfer(alice, 10_000e18);
        vm.roll(100);
        token.enableTrading();

        vm.prank(alice);
        token.transfer(game[0], 1_000e18);
        assertFalse(token.blacklisted(game[0]));
    }

    function test_theAntiBotWindowIsBoundedAndFrozenOnceTradingOpens() public {
        uint256 cap = token.MAX_ANTI_BOT_BLOCKS();
        assertEq(cap, 5);
        vm.expectRevert(abi.encodeWithSelector(BNBull.AntiBotWindowTooLong.selector, cap + 1, cap));
        token.setAntiBotBlocks(cap + 1);

        token.setAntiBotBlocks(0); // disabling it before launch is allowed
        token.setAntiBotBlocks(3);
        token.enableTrading();

        // Moving the window once it is running changes the rules mid-flight.
        vm.expectRevert(BNBull.TradingAlreadyOpen.selector);
        token.setAntiBotBlocks(1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Launch caps
    // ══════════════════════════════════════════════════════════════════════

    function test_theCapsBiteAndThenAreLiftedForGood() public {
        token.setAntiBotBlocks(0);
        token.enableTrading();
        vm.prank(holder);
        token.transfer(alice, 50_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BNBull.MaxTxExceeded.selector, SUPPLY / 200 + 1, SUPPLY / 200)
        );
        token.transfer(bob, SUPPLY / 200 + 1);

        // Wallet cap: bob may hold 1% and not a wei more. Two max-size
        // transfers get him exactly there.
        vm.prank(alice);
        token.transfer(bob, SUPPLY / 200);
        vm.prank(alice);
        token.transfer(bob, SUPPLY / 200);
        assertEq(token.balanceOf(bob), SUPPLY / 100);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BNBull.MaxWalletExceeded.selector, SUPPLY / 100 + 1, SUPPLY / 100
            )
        );
        token.transfer(bob, 1);

        token.liftLimits();
        assertFalse(token.limitsActive());
        vm.prank(alice);
        token.transfer(bob, 1_000e18); // now unbounded

        vm.expectRevert(BNBull.LimitsAlreadyLifted.selector);
        token.liftLimits();
        vm.expectRevert(BNBull.LimitsAlreadyLifted.selector);
        token.setLimits(SUPPLY / 2, SUPPLY / 2);
    }

    /// @dev Fefers let the owner set these to anything, so a compromised key
    ///      could set `maxTx = 1` and halt the market without touching a pause
    ///      flag. The floor is 0.10% of supply.
    function test_theCapsCannotBeTunedDownToAFreeze() public {
        uint256 floorAmount = (SUPPLY * token.MIN_LIMIT_BPS()) / 10_000;
        assertEq(floorAmount, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(BNBull.LimitTooLow.selector, uint256(1), floorAmount));
        token.setLimits(1, SUPPLY / 100);
        vm.expectRevert(abi.encodeWithSelector(BNBull.LimitTooLow.selector, uint256(0), floorAmount));
        token.setLimits(SUPPLY / 200, 0);

        token.setLimits(floorAmount, floorAmount); // the floor itself is allowed
        assertEq(token.maxTx(), floorAmount);
    }

    /**
     * @notice ⚠ THE ORDER-OF-OPERATIONS DEAD END, REPRODUCED.
     *
     * @dev Renounce first and the caps are enforced forever with nobody able to
     *      lift them. This test exists so the deploy runbook has something
     *      concrete to point at: enable trading -> let the launch settle ->
     *      **liftLimits -> lockBlacklist -> renounce**, in that order.
     */
    function test_renouncingBeforeLiftingLimitsChokesTheTokenForever() public {
        token.enableTrading();
        token.renounceOwnership();
        assertEq(token.owner(), address(0));

        vm.expectRevert();
        token.liftLimits();
        vm.expectRevert();
        token.setLimits(SUPPLY / 2, SUPPLY / 2);
        assertTrue(token.limitsActive(), "the caps are now permanent - this is the trap");

        // The correct order, on a fresh deployment.
        BNBull ok = new BNBull(holder, owner, SUPPLY);
        ok.enableTrading();
        ok.liftLimits();
        ok.lockBlacklist();
        ok.renounceOwnership();
        assertFalse(ok.limitsActive());
        assertTrue(ok.blacklistLocked());
        assertEq(ok.owner(), address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The blacklist can only ever loosen
    // ══════════════════════════════════════════════════════════════════════

    function test_lockingTheBlacklistStopsAdditionsButNotRemovals() public {
        token.setAntiBotBlocks(0);
        token.enableTrading();
        vm.prank(holder);
        token.transfer(alice, 10_000e18);

        token.blacklist(bob, "confirmed bot");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BNBull.AddrBlacklisted.selector, bob));
        token.transfer(bob, 1e18);

        token.lockBlacklist();
        assertTrue(token.blacklistLocked());

        vm.expectRevert(BNBull.BlacklistIsLocked.selector);
        token.blacklist(alice, "too late");

        // Loosening still works, which is what makes the switch safe.
        token.unblacklist(bob);
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_aBlacklistedSenderIsAlsoStopped() public {
        token.setAntiBotBlocks(0);
        token.enableTrading();
        vm.prank(holder);
        token.transfer(alice, 10_000e18);
        token.blacklist(alice, "bot");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BNBull.AddrBlacklisted.selector, alice));
        token.transfer(bob, 1e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The game's own flows must work
    // ══════════════════════════════════════════════════════════════════════

    /// @dev MintDrop, Duel, Graveyard and the Marketplace all use
    ///      `transferFrom`. Once the launch arsenal is disarmed, the token must
    ///      behave like a plain BEP-20 with no gate at all.
    function test_afterDisarmingItIsAPlainBep20() public {
        token.setAntiBotBlocks(0);
        token.enableTrading();
        token.liftLimits();
        token.lockBlacklist();

        vm.prank(holder);
        token.transfer(alice, 100_000e18);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 100_000e18);
        assertEq(token.balanceOf(bob), 100_000e18);
        assertEq(token.balanceOf(alice), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Socials (DECISIONS §5) — settable, because handles and domains move
    // ══════════════════════════════════════════════════════════════════════

    function test_theSocialsAreEmbeddedAndSettable() public {
        assertEq(token.website(), "https://bnbulls.xyz");
        assertEq(token.twitter(), "https://x.com/WeAreBNBulls");
        assertEq(token.telegram(), "https://t.me/WeAreBNBulls");

        token.setSocials("https://a", "https://b", "https://c");
        assertEq(token.website(), "https://a");

        vm.prank(alice);
        vm.expectRevert();
        token.setSocials("x", "y", "z");
    }
}

/// @dev Any contract will do — the anti-bot rule is `to.code.length > 0`.
contract Sniper {}
