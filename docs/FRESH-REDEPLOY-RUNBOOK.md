# Fresh redeploy — bnbulls on native BNB

**This replaces `NATIVE-MIGRATION-RUNBOOK.md`. Do not run both.**

Every check below has an **expected output**. **STOP on any mismatch.** Three of
the worst failures found in review were *silent* — nothing reverts, no player
sees an error, and a checklist that only asks "did it run?" signs off on all of
them.

---

## §0 Why this instead of the migration

The migration replaced 2 of 12 contracts on a live system. Six external reviews
found **7 blockers**, three silent and permanent-ish. A fresh deploy removes the
entire class:

| migration problem | fresh deploy |
|---|---|
| 6h timelock on `Bulls.Duel` / `Graveyard.Duel` | **gone** — fresh slots use one-shot `bootstrap` |
| 24h coexistence window, two Duels wired at once | **gone** — nothing coexists |
| 4 funders left pointing at the dead pot, forever | **gone** — wired once, correctly |
| `Wire.Yards` omitted → consent gate off | **gone** — `Wire.s.sol:328` already wires it |
| `addFightAsset(…, 0)` kills dev cut + pot funding | **gone** — `Wire.s.sol:370` already passes `type(uint16).max` |
| `duelJackpotPaid` ledger wiped mid-flight | **gone** — no in-flight state |
| old pot money stranded and *growing* | bounded: **$2.72, written off once** |

⚠ Two of those blockers existed **only** in `MigrateNative.s.sol`. `Wire.s.sol`
has always done both correctly. That is the single strongest argument for this
route: it uses the path that was already right.

---

## §1 What is redeployed, and what is kept

| contract | action | why |
|---|---|---|
| **$BNBULL token** | **KEPT** `0xA8D0…4444` | four.meme's, not ours. Still on the bonding curve, transfer-locked. `DEPLOY_BNBULL=false` adopts it. |
| Bulls (ERC-721) | redeploy | Same `masterSeed` ⇒ identical collection (§2). Fresh avoids the timelock entirely. |
| Duel | redeploy → **`DuelNative`** | The point of the exercise: native credit ledger, no WBNB. |
| Jackpot BNB | redeploy → **`JackpotNative`** | Winners receive BNB, not WBNB. |
| Jackpot BNBULL | redeploy (unchanged `Jackpot.sol`) | $BNBULL *is* an ERC-20; nothing to remove. Redeployed only because it wires to the new Duel. |
| Yards | redeploy | Fresh `bootstrap`, and it must point at the new Bulls. |
| Graveyard | redeploy | Must point at the new Bulls/Duel. |
| MintDrop | redeploy | Must point at the new Bulls and the new pot. |
| Marketplace | redeploy | Must point at the new Bulls **and** carries the `maxPay` fix (§3.5). |
| 3× splitters | redeploy | Must point at the new pot. Fresh wiring removes the 4-funder repoint problem. |

**Everything except the token.** Keeping any single game contract would
re-introduce a timelocked re-wire, which is the thing this route exists to avoid.

---

## §2 The collection is reproduced exactly — verified, not assumed

`contracts/Bulls.sol`, checked line by line:

```
_rollBull          statsSeed  = masterSeed ^ (tokenId * 0xbf58476d1ce4e5b9)
                   weaponSeed = masterSeed ^ (tokenId * 0x94d049bb133111eb)
_initializeRarity  shuffleSeed = masterSeed ^ 0x5348554646   ("SHUFF")
```

**No `block.timestamp`, no `block.number`, no `blockhash`, no `address(this)`,
no `msg.sender`** anywhere in trait derivation. `masterSeed` and
`namesCommitment` are immutable constructor args read from
`deployments/names.json`, which does not change. Names are published by
`Names.s.sol` from that same file against the same commitment.

⇒ Same seed in, byte-identical rarity table, stats, weapons and names out.
`ReissueBulls.s.sol` **asserts `initialRarityHash` matches before minting a
single bull**, so this is proven on-chain rather than trusted.

⚠ **Token ids are assigned sequentially by `mint`** — there is no `mintTo(id)`.
The only way to reproduce the token→owner map is to mint in ascending order,
handing each to whoever holds that id on the old contract. The script reads
recipients off the **old contract at run time**, so a transfer between now and
the run cannot desync it.

---

## §3 Fixes folded in (the reason this is worth doing)

| # | fix | where |
|---|---|---|
| 1 | `Wire.Yards` bootstrapped; `_requireInYards` fails closed | `Wire.s.sol:328` (already) + `DuelNative.sol` (other agent) |
| 2 | `addFightAsset` dev bps sentinel `type(uint16).max` | `Wire.s.sol:370` (already correct) |
| 3 | **`setMinTicketStake`** — reads 0 today, so a 1-wei stake mints a full-odds ticket with zero rake | `Wire.s.sol` — **in flight** (§3.3) |
| 4 | self-dealt ticket farm | ⚠ **ACCEPTED RISK, with a trigger** — see §3.4 |
| 5 | `Marketplace.buyWithBNB` needs `maxPay` | `Marketplace.sol` — **in flight** (§3.5) |
| 6 | anti-grind commit keyed to wallet, not bull | frontend `duelCommit.ts` |
| 7 | `minPoolLiquidity` 1e18 on MintDrop + 3 splitters | pinned in `deploy-fresh.ps1`; **also fix `BnbullsConfig.sol:366`** to `_mainnetReqUint` so it cannot leak again |
| 8 | BNBULL peg sanity bands; `setBnbullUsd` unbounded and is a **divisor** | `Marketplace.sol` / `Graveyard.sol` |

### §3.3 `setMinTicketStake` — one line, closes a rake-free ticket
`minTicketStakeOf` exists (`DuelNative.sol:635`, setter `:2042`, `onlyOwner`) and
**no script has ever called it**. It reads 0 in production today. `_rollJackpot`
only refuses `stake == 0`, so a **1-wei** stake mints the same full-odds ticket —
and `devCut = stake * 1000 / 10000` is 0 for any stake below 10 wei, so the
ticket is literally rake-free. Add to `Wire.s.sol` alongside `addFightAsset`:
```solidity
du.setMinTicketStake(c.ext.wbnb,   <a real floor, e.g. 50% of one fight>);
du.setMinTicketStake(c.ext.bnbull, <same in BNBULL>);
```

### §3.4 The self-dealt ticket farm — ⚠ DELIBERATELY ACCEPTED RISK

Two wallets you control, two bulls. `allowSelfDuel` never engages because the
owners differ. The stake moves left hand to right, so **only the rake is a real
cost**: ~$0.43/duel, ~51 duels per hit ⇒ **~$22 expected per jackpot at 100%
payout**. +EV the moment the pot exceeds ~$22, and the farmer generates most of
the tickets so wins most of the jackpots.

**OWNER DECISION: leave it. Ship `setMinTicketStake` (§3.3) only.**
Do **NOT** implement contribution-weighting, per-winner cooldowns, or
`devCut > 0` ticket eligibility. Rationale: the entire player base is the owner
and his mates, so the farm's victim is the owner himself. Paying for a fix now
buys nothing and changes how the game feels.

> ### 🚩 THE TRIGGER TO REVISIT — read this before any public push
>
> This risk is only acceptable **while every wallet funding the pot is one the
> owner can name.** Revisit the moment strangers fund it — any public marketing
> push, any listing that drives organic traffic, or **any mint from a wallet the
> owner cannot account for.**
>
> The asymmetry is the point: while it is all mates, the farm is self-harm and
> costs nothing to leave open. The instant an outsider's mint fees enter the
> pot, the same mechanism becomes a pipe from their money to the farmer's, and
> it is +EV from a pot of about $22 — which this pot reaches routinely.
>
> **Watch for it:** a mint from an unrecognised wallet is the signal. Check
> holders against the known set (§7) before promoting anything.
>
> Recorded in memory as `bnbulls-accepted-risk-ticket-farm`.

`setMinTicketStake` is still worth shipping regardless — it costs nothing, and
without it a **1-wei** stake mints a full-odds, literally rake-free ticket, which
is a different and strictly worse hole than the farm.

### §3.5 `Marketplace.buyWithBNB` — add `maxPay`
`buyWithBNB(uint256 tokenId)` takes **no maximum**. It reads `l.usdPrice` and the
live oracle at settlement and refunds the surplus; `updatePrice` is instant and
unbounded. The UI sends a **+1.5% cushion**, so the seller front-runs with
`updatePrice(id, price * 1.015)`, the whole `msg.value` is consumed, refund is
zero, and the `Sold` event reports the price actually charged — **invisible**.
Riskless, repeatable, 1.5% of every BNB sale. Fix is one parameter:
`buyWithBNB(uint256 tokenId, uint256 maxPay)`.

---

## §4 Pre-flight — STOP on any mismatch

```bash
forge build                      # clean
forge test                       # green
```
- [ ] `deployments/names.json` is the **same file** the live collection used
      (this is what makes §2 true). Confirm `masterSeed` in it matches
      `cast call <oldBulls> "masterSeed()(uint256)"`.
- [ ] Deployer BNB: **≥ 0.6 BNB**. `preflight` alone demands 46M gas × gasprice,
      and the 28 re-issue mints are on top (§7).
- [ ] `contracts/DuelNative.sol` C1/C2 fixes are in and tested (other agent).
- [ ] §3.3 / §3.5 changes are in and tested.

---

## §5 Deploy

⚠ **THE RESUME TRAP.** `DeployCore._resume` reuses any recorded address that
still has code. All twelve old contracts have code, so running `Deploy` against
the existing `deployments/56.json` **resumes all twelve and deploys nothing** — a
"successful" run that changes nothing. `deploy-fresh.ps1` archives the record to
`deployments/56.retired.json` first and refuses to broadcast if it is still
present. That archive is also what §7 reads its recipients from — **keep it.**

```
powershell -File marketing/keeper/deploy-fresh.ps1 -Step deploy -Simulate
powershell -File marketing/keeper/deploy-fresh.ps1 -Step deploy
powershell -File marketing/keeper/deploy-fresh.ps1 -Step wire   -Simulate
powershell -File marketing/keeper/deploy-fresh.ps1 -Step wire
powershell -File marketing/keeper/deploy-fresh.ps1 -Step names
```

⚠ **A broadcast is NOT atomic.** `forge script` sends a *sequence*; only the
simulation is atomic. If tx 7 fails, txs 1–6 are mined. `Deploy` and `Wire` are
resume-safe by design; read `broadcast/*/56/run-latest.json` before re-running.

---

## §6 Before the re-issue — seed and register the pot

**Do this BEFORE any ticket can resolve.** `resolve` computes
`won = roll == 0 && balance >= minPool` and advances the cursor **either way** —
a pot below `minPoolToFire` **consumes winning tickets and silently loses them**.
At 1-in-75 that is roughly one real winner destroyed per 75 tickets, with no
revert and no event.

1. Add the new pot as a VRF consumer at **vrf.chain.link/bsc** (sub
   `1152762826695795728545582152023678311743202668033671445953077796554315763700 20`).
   Until then `requestResolve` reverts at the coordinator.
2. Seed it — **fresh $25**, as agreed:
   ```
   powershell -File marketing/keeper/pot-seed.ps1 -Pot 0x<newPot> -Bnb 0.0416
   ```
3. Confirm: `cast call <newPot> "pool()(uint256)"` → **above** `minPoolToFire`.

---

## §7 Re-issue the collection

```
powershell -File marketing/keeper/deploy-fresh.ps1 -Step reissue -Simulate
powershell -File marketing/keeper/deploy-fresh.ps1 -Step reissue
```

The script gates itself before minting anything:
- `masterSeed` old == new — else the traits differ and it **reverts**
- `initialRarityHash` old == new — the whole shuffled table, proven equal
- target `nextTokenId == 1`, unpaused, owned by the deployer

Then mints 1..28 in order to the holder of that id on the old contract, and
verifies **every** token afterwards on owner, stats, weapon, tier and name.

**Expected holders** (28 bulls, 7 wallets, all reachable):
```
1-5    0x5b1A749cc7bF1dE8ecA505769BD34Ba65f456805   (deployer)
6-11   0x04230AB84bDaeEF318C600779112D9Cd5741D852
12-16  0xbafb03402c85F246970FAB3667E9fA826125e331
17     0x613794Dc02cc1a9f29Fbbdc8C5A82d08162bc04E
18-19  0x64b20FF702224e6DB03A5faeA3F162B2714fb283
20-21  0xEA5A3B918dff24b4d2BcaF324f44cA93EB68AA82
22-28  0x2179c3B50Ec23fa9F2FCcF06eD97acE575f6a94a
```
⚠ The ranges are **contiguous and ascending**, which is what makes a sequential
re-mint reproduce the map exactly. If a bull moves before the run, the script
follows the new owner (it reads live) but the ranges above will no longer match —
re-read them and update this table rather than assuming.

---

## §8 Verify — STOP on any mismatch

```bash
powershell -File marketing/keeper/deploy-fresh.ps1 -Step verify
```
Then, because `Verify` cannot see everything that matters:

```bash
# THE CONSENT GATE. Zero here means every bull is fightable by anyone. P0.
cast call <newDuel> "wireOf(uint8)(address,address,uint64)" 4   # -> <newYards>, NOT 0

# THE DEV CUT AND ALL FIGHT-DRIVEN POT FUNDING. Zero = both off. P0.
cast call <newDuel> "devShareBpsOf(address)(uint16)" <wbnb>     # -> 1000, NOT 0
cast call <newDuel> "devShareBpsOf(address)(uint16)" <bnbull>   # -> 1000, NOT 0
cast call <newDuel> "potShareBps()(uint16)"                     # -> 3000

# THE RAKE-FREE TICKET BACKSTOP (§3.3). Zero means it is still open.
cast call <newDuel> "minTicketStakeOf(address)(uint256)" <wbnb> # -> NOT 0

# THE FUNDERS. All four must point at the NEW pot.
for c in <mintDrop> <mintSplitter> <reviveSplitter> <marketSplitter>; do
  cast call $c "wireOf(uint8)(address,address,uint64)" 3        # -> <newPot>
done

# The pot can actually pay.
cast call <newPot> "pool()(uint256)"                            # -> > minPoolToFire
cast call <newPot> "trustedCoordinator()(address)"              # -> 0xd691f04b…694C9

# The collection.
cast call <newBulls> "nextTokenId()(uint32)"                    # -> 29
cast call <newBulls> "initialRarityHash()(bytes32)"             # -> same as old
cast call <newBulls> "namesWritten()(uint256)"                  # -> 501
```

**Then the one proof no `cast call` can give you: from a wallet that is NOT the
owner's, do one real deposit, one real fight, and one real withdraw — before you
announce anything.**

---

## §9 Frontend and fleet

- `marketing/keeper/.state/mainnet-addresses.json`: every address → the new set,
  **and add `"nativeDuel": true`**. `launch-frontend.ps1` already reads that flag
  and sets `NEXT_PUBLIC_DUEL_NATIVE`. The address and the flag are **one atomic
  decision** — new address with the flag off means a winner sees nothing in their
  wallet and no explanation; old address with the flag on offers a `deposit()`
  that does not exist.
- Add the **old** Duel `0x024616…` and old pot `0xb83eAf…` to the `$testnetAddrs`
  guard in `launch-frontend.ps1` so a stale build is caught.
- Fleet — **eight** services read these addresses, not two:
  ```
  docker compose up -d --force-recreate --no-deps duel-bot alert-bot dev-bot fight-buy-bot jackpot-vrf-keeper
  ```
  ⚠ `restart` does **not** re-read env. ⚠ `env/autoplay-bot.env` pins its **own**
  `DUEL=` and loads *before* `common.env` (first value wins) — editing
  `common.env` alone leaves autoplay on the dead contract. Autoplay is also
  architecturally incompatible until updated: it wraps BNB and approves WBNB,
  where `DuelNative` needs `deposit()`.
- Wipe: `.state/duel-bot.json`, `.state/duel-bot.tickets.json`,
  `.state/alert-bot.json`, `.state/alert-bot.alarms.json`.

### §9.1 Two files that silently point at dead contracts — **STOP if either is missed**

Both of these report *healthy* while doing nothing. That is what makes them
expensive: on launch day the identical class of mistake (testnet pot addresses
in `JACKPOT_POOLS`) took an hour to find, because the keeper logged clean ticks
the whole time and simply never resolved a ticket.

**1. `marketing/keeper/env/jackpot-vrf-keeper.env:24` — `JACKPOT_POOLS`**

It pins both pot addresses, and **that var OVERRIDES the `JACKPOT_BNB` /
`JACKPOT_BNBULL` fallback** — so correct values in `common.env` will *not* save
you. Left stale, the keeper drives the **retired** pots: it requests and resolves
against contracts nobody is ticketing, while every ticket on the new pots sits
pending forever and the jackpot never pays.

```
# edit env/jackpot-vrf-keeper.env
JACKPOT_POOLS=bnbull=<newJackpotBnbull>,bnb=<newJackpotBnb>
```
Verify after the recreate — the boot line prints the pools it actually resolved:
```
docker logs bnbulls-jackpot-vrf-keeper 2>&1 | grep -E "bnbull .*·|bnb .*·" | tail -2
#  -> must show the NEW addresses, prize BNB (18dp) on the bnb pot, odds 1-in-75
```

**2. `marketing/keeper/.state/launch-watcher.json` — the frontend-reverting trap**

It holds `contracts.duel` / `contracts.jackpotBnb` from the old set. Worse,
`launch-watcher.mjs:250` **fingerprints contracts by probing `prizeToken()`** —
which `JackpotNative` does not have — so it cannot recognise the new pot even if
it re-ran. If launch-watcher ever completes again it **rewrites
`.state/mainnet-addresses.json` from that stale state, silently reverting every
frontend address on the next deploy.**

**Delete it** (simplest — the watcher's job is done, it exists to catch a launch
that has already happened):
```
rm marketing/keeper/.state/launch-watcher.json
```
If you keep it instead, update `contracts.duel`/`contracts.jackpotBnb` **and**
fix the `prizeToken()` fingerprint, or it will fight you again later.

---

## §10 What is lost — ✅ SIGNED OFF BY THE OWNER

**The stats reset is APPROVED.** All 28 bulls restart at 1000 elo with clean
records. No further sign-off needed; this table is the record of what that means.

| lost | detail |
|---|---|
| **Combat history** | elo, wins, losses, ties, level, xp on all 28 bulls. Everything restarts at 1000 elo. There is no setter and adding one would be a lie — the record is meant to be earned. **Approved.** |
| **Loss streaks / deaths** | `consecutiveLosses`, `diedAt`, `resurrectsUsed` all reset. Player-favourable: a bull at 4/5 losses walks away from death. |
| **Jackpot history** | ticket queue, `ticketCount`, `awardCount`, `totalAwarded`. The one paid jackpot stays in the old contract's history. |
| **The old pot** | **$2.72**, unrecoverable — `sweepForeignToken` reverts on the prize token. Written off deliberately; the new pot gets a fresh $25. |
| **Old NFTs** | ⚠ **The old bulls are NOT burned.** The retired Bulls contract keeps existing and every holder keeps their old token — it is simply no longer the live collection. **All 7 holders will see BOTH sets in their wallet**, the old one inert and the new one live, with the same names and artwork. **Tell them before the cutover**, or the duplicates read as a bug or a scam. There is no way to burn them: the old contract has no burn and is not ours to change. |
| **Approvals** | Every WBNB approval to the old Duel is dead. Under `DuelNative` nobody approves anything — they `deposit()`. |

---

## §11 What worries me

0. **One blocker is still open at the time of writing: the `DuelNative` C1/C2
   hardening** — `_requireInYards` failing closed, and bounding what a signature
   can debit from a wallet that did not sign it. Both are in flight. **Do not run
   §5 until they land and their PoCs flip.** (`Marketplace.maxPay` and
   `setMinTicketStake` are also in flight but are not deploy blockers — they are
   improvements this deploy is the chance to include.)
1. **The new contracts are young.** `DuelNative`/`JackpotNative` are days old
   against an incumbent with 800+ tests and a launch behind it. Six reviews found
   no defect in the *contracts* — every blocker was in the tooling — but "no
   defect found" is not "no defect".
2. **Custody is a new threat surface.** The old Duel held nothing between calls.
   These hold player deposits indefinitely, which is what turned an unwired Yards
   slot from a nuisance into a drain, and what makes the trusted signer a money
   path. Both are being fixed; both deserve a re-read after the fix.
3. **The re-issue is one-shot.** `ReissueBulls` refuses a non-empty target, so a
   half-completed run cannot be resumed — it must be diagnosed from the broadcast
   log and finished by hand, or the collection is redeployed again.
4. **No downtime plan is needed, but there is a gap**: between the new contracts
   going live and the frontend flip, the site still points at the old set. Budget
   20–30 minutes and post the notice before, not after.
