// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BnbullsConfig} from "../lib/BnbullsConfig.sol";
import {Bulls} from "../../contracts/Bulls.sol";
import {MintDrop} from "../../contracts/MintDrop.sol";
import {Jackpot} from "../../contracts/Jackpot.sol";

/**
 * @title RehearsePreLiquidity
 * @notice THE most valuable thing the chain-97 rehearsal proves: what happens
 *         on launch day, when BNBULL has no PancakeSwap pair at all.
 *
 * @dev ══════════════════════════════════════════════════════════════════════
 *      THE STATE BEING REHEARSED
 *      ══════════════════════════════════════════════════════════════════════
 *      `DECISIONS.md §22`: BNBULL launches on four.meme's bonding curve, and
 *      **there is no PancakeSwap pair until that curve fills**. So on day one
 *      the 20% BNBULL leg of every payment cannot execute. Testnet reproduces
 *      that exactly and for free — there is no BNBULL liquidity there either.
 *
 *      What MUST be true, and is asserted here:
 *
 *        1. **The mint does not revert.** Not "usually". Ever. The never-fail
 *           pattern exists so a discretionary buyback cannot take a sale down
 *           with it (`BNBULLS-BOOTSTRAP.md §6`).
 *        2. **The BNBULL slice ACCRUES** into `pendingBnbullBuyNative` rather
 *           than vanishing. Money that could not be spent is still owed to the
 *           pot, and the bucket is the receipt.
 *        3. **The BNB slice STILL LANDS.** That leg is a 1:1 WRAP, not a swap —
 *           no router, no pool, no floor to be stale (`DECISIONS.md §13`). If
 *           this one defers too, something is wrong that is NOT the missing
 *           pool, and the rehearsal has caught a real bug.
 *
 *      Point 3 is the discriminator. Without it, "everything deferred" reads as
 *      "no liquidity yet" when it might actually be a missing funder role.
 */
contract RehearsePreLiquidity is BnbullsConfig {
    error NotBscTestnet(uint256 chainid);
    error MintReverted();
    error BnbLegDidNotLand();
    error BnbullSliceVanished();

    function run() external {
        if (block.chainid != CHAIN_BSC_TESTNET) revert NotBscTestnet(block.chainid);

        Deployment memory d = readDeployment();
        MintDrop m = MintDrop(d.mintDrop);
        Jackpot potBull = Jackpot(d.jackpotBnbull);
        Jackpot potBnb = Jackpot(d.jackpotBnb);

        (uint256 usd, uint256 bnbDue,, uint256 px) = m.quote(1);
        console2.log("== pre-liquidity rehearsal (chain 97) ==");
        console2.log("  BNB/USD 1e18   ", px);
        console2.log("  1 bull usd     ", usd);
        console2.log("  1 bull bnb due ", bnbDue);

        uint256 bullPotBefore = potBull.pool();
        uint256 bnbPotBefore = potBnb.pool();
        uint256 deferredBefore = m.pendingBnbullBuyNative();
        uint256 soldBefore = m.totalSold();

        console2.log("");
        console2.log("  before: BNBULL pot", bullPotBefore);
        console2.log("          BNB pot   ", bnbPotBefore);
        console2.log("          deferred  ", deferredBefore);

        // Overpay so the refund path runs too.
        vm.startBroadcast();
        m.mintWithBNB{value: bnbDue * 2}(msg.sender, 1);
        vm.stopBroadcast();

        uint256 bullPotAfter = potBull.pool();
        uint256 bnbPotAfter = potBnb.pool();
        uint256 deferredAfter = m.pendingBnbullBuyNative();

        console2.log("");
        console2.log("  after:  BNBULL pot", bullPotAfter);
        console2.log("          BNB pot   ", bnbPotAfter);
        console2.log("          deferred  ", deferredAfter);

        // 1. The sale happened.
        if (m.totalSold() != soldBefore + 1) revert MintReverted();
        console2.log("");
        console2.log("  [ok] the mint SETTLED with no BNBULL pool in existence");

        // 3. The BNB leg is a wrap and must land regardless.
        if (bnbPotAfter <= bnbPotBefore) {
            console2.log("  [FAIL] the BNB pot did not grow.");
            console2.log("         That leg is a 1:1 WRAP - no router, no pool, no floor.");
            console2.log("         Missing liquidity cannot explain this. Check");
            console2.log("         Jackpot.setFunder(MintDrop) on the BNB pot.");
            revert BnbLegDidNotLand();
        }
        console2.log("  [ok] the BNB pot grew by", bnbPotAfter - bnbPotBefore, "(a wrap, not a swap)");

        // 2. The BNBULL leg either bought (a pool appeared) or accrued.
        if (bullPotAfter > bullPotBefore) {
            console2.log("  [info] the BNBULL pot GREW - somebody has seeded a testnet pool.");
            console2.log("         The pre-liquidity case is no longer being rehearsed here.");
        } else if (deferredAfter > deferredBefore) {
            console2.log(
                "  [ok] the BNBULL slice DEFERRED, +", deferredAfter - deferredBefore
            );
            console2.log("       Exactly the four.meme pre-graduation state. The money is");
            console2.log("       held, owed to the pot, and swept with sweepBnbullPot once");
            console2.log("       the curve fills and a pair exists.");
        } else {
            console2.log("  [FAIL] the BNBULL slice neither bought nor accrued.");
            console2.log("         It went somewhere it should not have.");
            revert BnbullSliceVanished();
        }

        _report(d, m);
    }

    /// @dev Split out purely to keep `run`'s stack under solc 0.8.24 without
    ///      via-IR, which this project builds with OFF.
    function _report(Deployment memory d, MintDrop m) private view {
        console2.log("");
        console2.log("  buckets now:");
        console2.log("    pendingBnbullBuyNative", m.pendingBnbullBuyNative());
        console2.log("    pendingBnbullDirect   ", m.pendingBnbullDirect());
        console2.log("    pendingBnbPotNative   ", m.pendingBnbPotNative());
        console2.log("    lpUndelivered         ", m.lpUndelivered());
        console2.log("");
        console2.log("  Bulls minted:", Bulls(d.bulls).nextTokenId() - 1);
        console2.log("");
        console2.log("  Re-run Verify with ALLOW_DEFERRALS=true - a non-zero bucket is");
        console2.log("  correct here and a hard failure before launch.");
    }
}
