# Fresh redeploy — bnbulls on native BNB

**This replaces `NATIVE-MIGRATION-RUNBOOK.md`. Do not run both.**
`migrate-native.ps1`, `shorten-timelock.ps1` and `deploy-mainnet.ps1` now refuse
to run without `-RetiredRouteIUnderstand`; that is deliberate, not a bug.

Every check below has an **expected output**. **STOP on any mismatch.** Three of
the worst failures found in review were *silent* — nothing reverts, no player
sees an error, and a checklist that only asks "did it run?" signs off on all of
them.

> **2026-08-10 rewrite.** The 2026-08-10 redeploy stopped six times. Every stop
> is now a guard in the tooling rather than a paragraph in this file, because
> five of the six were *already* written down somewhere and still happened.
> §5.0 lists what the scripts enforce for you. Read it before doing anything by
> hand — several of the manual steps this runbook used to prescribe are now
> automatic, and doing them twice is its own hazard.

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

⚠ **"The old contract" means the generation you are replacing, not the first
one.** `OLD_BULLS` is read from `deployments/56.retired.json`, which
`-Step deploy` rotates. It used to be a literal pinned to the 2026-08-09
collection — right for exactly one redeploy and wrong for every one after,
silently, by minting 28 bulls to a stale holder map.

---

## §3 Fixes folded in (the reason this is worth doing)

| # | fix | status |
|---|---|---|
| 1 | `Wire.Yards` bootstrapped; `_requireInYards` fails closed | ✅ shipped (`DuelNative.sol:1213`) |
| 2 | `addFightAsset` dev bps sentinel `type(uint16).max` | ✅ shipped (`Wire.s.sol:397`) |
| 3 | **`setMinTicketStake`** — read 0 in production, so a 1-wei stake bought a full-odds, rake-free ticket | ✅ shipped (`Wire.s.sol:389`), live at 3e14 / 25,000e18 |
| 4 | self-dealt ticket farm | ⚠ **ACCEPTED RISK, with a trigger** — see §3.4 |
| 5 | `Marketplace.buyWithBNB` needs `maxPay` | ✅ shipped — `buyWithBNB(tokenId, maxUsdPrice, maxPay)` |
| 6 | anti-grind commit keyed to wallet, not bull | frontend `duelCommit.ts` |
| 7 | `minPoolLiquidity` 1e18 on MintDrop + 3 splitters | ✅ pinned in `deploy-fresh.ps1`, asserted by `postdeploy-check.ps1` |
| 8 | BNBULL peg sanity bands; `setBnbullUsd` unbounded and is a **divisor** | mitigated operationally — §5.2 |

### §3.4 The self-dealt ticket farm — ⚠ DELIBERATELY ACCEPTED RISK

Two wallets you control, two bulls. `allowSelfDuel` never engages because the
owners differ. The stake moves left hand to right, so **only the rake is a real
cost**: ~$0.43/duel, ~51 duels per hit ⇒ **~$22 expected per jackpot at 100%
payout**. +EV the moment the pot exceeds ~$22, and the farmer generates most of
the tickets so wins most of the jackpots.

**OWNER DECISION: leave it. `setMinTicketStake` (§3.3) shipped; that is all.**
Do **NOT** implement contribution-weighting, per-winner cooldowns, or
`devCut > 0` ticket eligibility. Rationale: the entire player base is the owner
and his mates, so the farm's victim is the owner himself.

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
      and the re-issue mints are on top (§7).
- [ ] **Nothing else is running from `bnbulls-owner`.** Not a bot, not a wallet
      UI, not another terminal. The scripts check (§5.0) but the mempool is not
      the only place a surprise can come from.
- [ ] `postdeploy-check.ps1` on the CURRENT deployment, so you know what "before"
      looked like.

---

## §5 THE SEQUENCE

### §5.0 What the tooling now enforces — do not do these by hand

Six things stopped the 2026-08-10 redeploy. All six are now guards. Reading this
section is the difference between one clean run and another six-stop day.

| was | is now |
|---|---|
| `-Step reissue` died on `vm.envAddress: NEW_BULLS not found` | `NEW_BULLS` is read from `deployments/56.json`, `OLD_BULLS` from `56.retired.json`. Neither is a literal. |
| An unpinned env var silently took its **testnet** value | `Assert-EnvNotLeaking` refuses to run when `.env` supplies a non-empty value for anything `script/*.sol` reads that the script does not pin. The audit is now code. |
| `-Step deploy -Simulate` wrote a `56.json` full of **simulated** addresses, which then tripped the resume guard on the real run | Every `-Simulate` restores `deployments/56.json` byte-for-byte on exit, and the deploy simulation now genuinely simulates a *fresh* deploy instead of quietly simulating a twelve-contract resume. |
| A second owner-signing script ate forge's planned nonces mid-broadcast | `.state/owner-signing.lock` + a `pending`-vs-`latest` nonce check. Every owner-signing script takes both. |
| The BNBULL pegs shipped 1,250× wrong, twice | `-Step wire` chains straight into the zeroing, and **no step prints OK while a peg reads non-zero pre-graduation.** |
| Four scripts pinned retired addresses | `pot-seed`, `post-deploy-vrf`, `open-mint`, `verify-all`, `zero-bnbull-pegs` and `launch-frontend -FromRecord` all read `deployments/56.json`. |

Two ordering rules the tooling can only partly enforce — **these are yours**:

1. **Seed the pot before anything can fight.** `resolve` computes
   `won = roll == 0 && balance >= minPool` and **advances the cursor either
   way**, so a pot below `minPoolToFire` *consumes winning tickets and loses
   them silently* — no revert, no event, nothing in a log. At 1-in-75 that is
   roughly one real winner destroyed per 75 tickets. Tickets are minted by
   fights, so the window opens the moment the fleet and the frontend point at
   the new Duel. Seed first (§5.3), flip last (§9).
2. **One owner-signing script at a time.** The lock enforces it for scripts that
   cooperate; nothing can stop a hand-typed `cast send`. `forge` plans its whole
   nonce sequence *before the first transaction*, so one stray send derails a
   run in flight. On 2026-08-10 that killed a re-issue at `expected 215 got
   217` — survivable only because zero of 28 mints had landed. **Mid-mint it is
   unrecoverable**: `ReissueBulls` refuses any target whose `nextTokenId != 1`,
   so a half-done re-issue means redeploying the collection again.

### §5.1 Deploy and wire

⚠ **THE RESUME TRAP.** `DeployCore._resume` reuses any recorded address that
still has code. All twelve old contracts have code, so running `Deploy` against
an existing `deployments/56.json` **resumes all twelve and deploys nothing** — a
"successful" run that changes nothing. `-Step deploy` archives the record to
`deployments/56.retired-<utc>.json`, rotates `56.retired.json` to point at the
generation being replaced, and refuses to broadcast if a record is still present.
**Keep the archives** — `56.retired.json` is where `OLD_BULLS` comes from.

```
powershell -File marketing/keeper/deploy-fresh.ps1 -Step deploy -Simulate
powershell -File marketing/keeper/deploy-fresh.ps1 -Step deploy
powershell -File marketing/keeper/deploy-fresh.ps1 -Step wire   -Simulate
powershell -File marketing/keeper/deploy-fresh.ps1 -Step wire        # auto-runs the pegs
```

⚠ **A broadcast is NOT atomic.** `forge script` sends a *sequence*; only the
simulation is atomic. If tx 7 fails, txs 1–6 are mined. `Deploy` and `Wire` are
resume-safe by design; read `broadcast/*/56/run-latest.json` before re-running.

### §5.2 The BNBULL pegs — now automatic, still worth understanding

`Wire.s.sol` **writes** the BNBULL pegs from env, and `deploy-fresh.ps1`'s four
placeholders carry the **testnet** numbers, because all four are
`_mainnetReqUint` and revert on zero — so they cannot simply be set to their
correct live value, which *is* zero. What lands:

```
Wire.s.sol:623   Marketplace.bnbullUsd1e18 = 1e16   -> $0.01/BNBULL vs a real ~$0.000008
Wire.s.sol:437   Graveyard.bnbullPerUsd    = 1e20   -> 100 BNBULL/$1 vs a real ~125,000
Wire.s.sol:245   MintDrop ladder BNBULL column, DERIVED from MARKETPLACE_BNBULL_USD
                 -> a $10 bull for ~1,000 BNBULL (~$0.008), the whole 500-bull
                    collection for ~1.9M BNBULL (~$15)
Wire.s.sol:748   PotSplitter.setFloors on all three splitters (FLOOR_* placeholders)
```

Harmless **only** while four.meme's transfer lock holds (`_mode()==1`): BNBULL
cannot move at all pre-graduation. Each is a live exploit the instant the curve
fills — which may happen while nobody is watching.

`-Step wire` now runs `zero-bnbull-pegs.ps1` itself, and `-Step wire/names/
reissue/verify` all **refuse to print OK** while a peg reads non-zero and BNBULL
has not graduated. Zero is a clean disable, not a mispricing: all three contracts
read it as "this leg is priced in USD only", and the keepers repeg once a real
pool exists.

⚠ **Zero means the opposite thing in `Duel`.** `fightCostOf[BNBULL] = 0` is a
**free fight**, and a free fight still opens a jackpot ticket. It is correctly
250,000e18 and is never touched. `postdeploy-check.ps1` asserts it stays non-zero.

⚠ The splitter floors are **not** zeroed. On a `PotSplitter` a zero rate is a
per-leg kill switch, and raising one back off zero is leashed for the keeper, so
zeroing could strand the leg for the wallet meant to repeg it. Pre-graduation
they are inert anyway — every swap defers under `minPoolLiquidity`. They are
printed, not changed.

### §5.3 Register and seed the pot — BEFORE anything can fight

```
powershell -File marketing/keeper/post-deploy-vrf.ps1     # both pots as VRF consumers
powershell -File marketing/keeper/pot-seed.ps1            # ~$25, address read from the record
```

Both are idempotent and read `deployments/56.json`; neither needs an address
argument any more. Without the consumer registration `requestResolve` reverts at
the coordinator and tickets pile up forever while the fights look fine.

Confirm: `pool()` **above** `minPoolToFire` — `postdeploy-check.ps1` asserts it.

### §5.4 Names, then the re-issue

```
powershell -File marketing/keeper/deploy-fresh.ps1 -Step names
powershell -File marketing/keeper/deploy-fresh.ps1 -Step reissue -Simulate
powershell -File marketing/keeper/deploy-fresh.ps1 -Step reissue
```

`FREEZE_NAMES` is pinned **false** — `freezeNames()` is one-way and there is no
unfreeze, so it can no longer be triggered by a stray `.env` edit during a
routine `-Step names`.

Before forge runs, `-Step reissue` checks that `OLD_BULLS ≠ NEW_BULLS`, that both
have code, and that `NEW_BULLS.nextTokenId == 1`. Then `ReissueBulls` gates
itself again:
- `masterSeed` old == new — else the traits differ and it **reverts**
- `initialRarityHash` old == new — the whole shuffled table, proven equal
- target `nextTokenId == 1`, unpaused, owned by the deployer

Then it mints 1..N in order to the holder of that id on the old contract, and
verifies **every** token afterwards on owner, stats, weapon, tier and name.

---

## §6 Verify — STOP on any mismatch

```
powershell -File marketing/keeper/deploy-fresh.ps1 -Step verify
powershell -File marketing/keeper/postdeploy-check.ps1
```

`REQUIRE_NAMES` is pinned **true**, so `Verify` now asserts the name table
instead of skipping it — `.env` leaves that opt-in check off, which means a
verify could previously pass against a collection with no published names.

`postdeploy-check.ps1` is read-only, signs nothing, needs no password file, and
exits non-zero on any FAIL. It asserts, in a pass/fail table:

- every contract in the record has code
- the Duel is `DuelNative` (`bnbCredit` responds) and the BNB pot is
  `JackpotNative` (`prizeToken()` **reverts**) — same ABI otherwise, so nothing
  else distinguishes them
- every wire non-zero **and pointing at the right address**, including
  `Duel.Yards` (zero = every bull fightable by anyone) and the four pot funders
- `minPoolLiquidity` 1e18 on MintDrop + all three splitters
- ticket floors non-zero **and below `fighterCost`** — above it,
  `_rollOnePool` *returns* instead of reverting, so fights silently stop
  minting tickets
- `devShareBps` and `potShareBps` non-zero (zero turns off the dev cut *and*
  every fight-driven pot deposit)
- the BNBULL pegs all ZERO pre-graduation, and `fightCostOf[BNBULL]` NOT zero
- both pots registered as VRF consumers, and the subscription above the ~0.12
  BNB floor below which the node accepts requests and never answers
- `pool()` above `minPoolToFire`
- MintDrop unpaused
- `initialRarityHash`, `masterSeed` and the collection count vs the retired one
- the frontend/fleet state files (§9)

**Then the one proof no `cast call` can give you: from a wallet that is NOT the
owner's, do one real deposit, one real fight, and one real withdraw — before you
announce anything.**

---

## §7 Expected holders

**28 bulls, 7 wallets, all reachable** (as at the 2026-08-10 re-issue):
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
re-mint reproduce the map exactly. The script reads owners live, so a transfer
before the run is followed correctly — but this table then stops matching.
**Re-read it before the next redeploy rather than assuming.** Public mints since
the re-issue are additional holders and are *not* in this table.

---

## §8 Open the mint — LAST

```
powershell -File marketing/keeper/open-mint.ps1
```

⚠ **This is the last step, not an early one.** MintDrop ships paused; opening it
before the re-issue finishes is **unrecoverable**. The first public mint takes
token id 1, `ReissueBulls` refuses any target whose `nextTokenId != 1`, and the
collection would have to be redeployed again. `open-mint.ps1` refuses until the
new collection's `nextTokenId` matches the retired one's.

---

## §9 Frontend and fleet

```
powershell -File marketing/keeper/launch-frontend.ps1 -FromRecord
```

`-FromRecord` builds the whole address map from `deployments/56.json` and probes
the Duel flavour for `NEXT_PUBLIC_DUEL_NATIVE`, so there is nothing to keep in
sync. The old path (`-AddressesJson .state\mainnet-addresses.json`) reads a
hand-maintained file that, on 2026-08-10, still held **every retired 2026-08-09
address and no `nativeDuel` flag** — a stage-3 deploy from it would have shipped
the dead set and then failed its own guard at the end. `postdeploy-check.ps1`
flags that file when it disagrees with the record.

⚠ **The address and the flag are one atomic decision.** New Duel with the flag
off ⇒ the deposit/withdraw UI never renders and a winner sees nothing in their
wallet with no explanation. Old address with the flag on ⇒ the UI offers a
`deposit()` that contract does not have.

### §9.0 The retired-address guard — two phases, and only one of them aborts

`launch-frontend.ps1` derives the forbidden list from every
`deployments/56.retired*.json`, so it extends itself at each redeploy instead of
needing a hand-edit. It runs twice:

| when | what it checks | on a match |
|---|---|---|
| **before `vercel deploy`** | the build env about to be baked into the bundle | **aborts.** Nothing has shipped, so stopping is free. |
| after the deploy | the live HTML at bnbulls.xyz | **warns.** |

⚠ **The post-deploy scan deliberately does not fail the run.** The bundle is
already live by then, so a non-zero exit cannot un-ship anything — it can only
convince the operator that a good deploy failed, and an operator who believes
that may roll back or redeploy for no reason. On 2026-08-10 exactly that
happened: a correct deploy was failed by the guard after the fact.

⚠ **What made that a false positive was CARRY-OVER, and it is the trap to
understand.** `$BNBULL` is four.meme's, was never ours to redeploy,
`DEPLOY_BNBULL=false` makes every deploy *adopt* it — so it is byte-identical in
the retired record and the live one. A naive "everything in a retired record is
retired" derivation therefore flags the live token, which is *supposed* to be in
the bundle. Two independent subtractions now prevent it:

1. only the retired **`contracts`** block is ever a candidate — `ext` (WBNB, the
   Chainlink feed, both routers, the VRF coordinator) is external protocol
   infrastructure, unchanged across every generation and never "retired";
2. everything live is subtracted — the live `contracts`, `ext`, `roles` and the
   top-level owner/keeper/deployer.

And with **no** `deployments/56.json` there is nothing to subtract, so the guard
refuses to derive a list at all rather than manufacture false positives. Every
match prints its provenance (`address <- retired "duel" in 56.retired.json`), so
a false positive can be told from a real stale ship in one look.

**Fleet — eight services read these addresses, not two:**
```
docker compose up -d --force-recreate --no-deps duel-bot alert-bot dev-bot fight-buy-bot jackpot-vrf-keeper
```
⚠ `restart` does **not** re-read env. ⚠ `env/autoplay-bot.env` pins its **own**
`DUEL=` and loads *before* `common.env` (first value wins) — editing
`common.env` alone leaves autoplay on the dead contract.

### §9.1 Two files that silently point at dead contracts — **STOP if either is missed**

Both report *healthy* while doing nothing. On launch day the identical class of
mistake took an hour to find, because the keeper logged clean ticks the whole
time and simply never resolved a ticket. `postdeploy-check.ps1` checks both.

**1. `marketing/keeper/env/jackpot-vrf-keeper.env` — `JACKPOT_POOLS`**

It pins both pot addresses and **overrides the `JACKPOT_BNB`/`JACKPOT_BNBULL`
fallback**, so correct values in `common.env` will *not* save you. Left stale,
the keeper drives the **retired** pots while every ticket on the new pots sits
pending forever.

```
JACKPOT_POOLS=bnbull=<newJackpotBnbull>,bnb=<newJackpotBnb>
docker logs bnbulls-jackpot-vrf-keeper 2>&1 | grep -E "bnbull .*·|bnb .*·" | tail -2
#  -> must show the NEW addresses, prize BNB (18dp) on the bnb pot, odds 1-in-75
```

**2. `marketing/keeper/.state/launch-watcher.json`**

It holds `contracts.duel`/`contracts.jackpotBnb` from an old set, and
`launch-watcher.mjs:250` **fingerprints contracts by probing `prizeToken()`** —
which `JackpotNative` does not have — so it cannot recognise the new pot even if
it re-ran. If it ever completes again it **rewrites
`.state/mainnet-addresses.json` from that stale state, silently reverting every
frontend address on the next deploy.**

**Delete it.** The watcher exists to catch a launch that has already happened.
```
rm marketing/keeper/.state/launch-watcher.json
```

Also wipe: `.state/duel-bot.json`, `.state/duel-bot.tickets.json`,
`.state/alert-bot.json`, `.state/alert-bot.alarms.json`.

---

## §10 What is lost — ✅ SIGNED OFF BY THE OWNER

**The stats reset is APPROVED.** All bulls restart at 1000 elo with clean
records. No further sign-off needed; this table is the record of what that means.

| lost | detail |
|---|---|
| **Combat history** | elo, wins, losses, ties, level, xp. Everything restarts at 1000 elo. There is no setter and adding one would be a lie — the record is meant to be earned. **Approved.** |
| **Loss streaks / deaths** | `consecutiveLosses`, `diedAt`, `resurrectsUsed` all reset. Player-favourable: a bull at 4/5 losses walks away from death. |
| **Jackpot history** | ticket queue, `ticketCount`, `awardCount`, `totalAwarded`. |
| **The old pot** | unrecoverable — `sweepForeignToken` reverts on the prize token. Written off deliberately; the new pot gets a fresh seed. |
| **Old NFTs** | ⚠ **The old bulls are NOT burned.** Every holder keeps their old token — it is simply no longer the live collection. **Holders will see BOTH sets in their wallet**, the old one inert and the new one live, with the same names and artwork. **Tell them before the cutover**, or the duplicates read as a bug or a scam. There is no way to burn them: the old contract has no burn and is not ours to change. |
| **Approvals** | Every WBNB approval to the old Duel is dead. Under `DuelNative` nobody approves anything — they `deposit()`. |

---

## §11 What worries me

1. **The new contracts are young.** `DuelNative`/`JackpotNative` are days old
   against an incumbent with 800+ tests and a launch behind it. Six reviews found
   no defect in the *contracts* — every blocker was in the tooling — but "no
   defect found" is not "no defect".
2. **Custody is a new threat surface.** The old Duel held nothing between calls.
   These hold player deposits indefinitely, which is what turned an unwired Yards
   slot from a nuisance into a drain, and what makes the trusted signer a money
   path.
3. **The re-issue is one-shot.** `ReissueBulls` refuses a non-empty target, so a
   half-completed run cannot be resumed — it must be diagnosed from the broadcast
   log and finished by hand, or the collection is redeployed again. This is why
   §5.0's one-script-at-a-time rule is a lock and not a note.
4. **The guards are only as good as `$KNOWN_ENV_READS`.** `Assert-EnvNotLeaking`
   compares `.env` against a hand-maintained list of every var `script/*.sol`
   reads. If a new `vm.envOr` lands in a script and nobody adds it to that list,
   the scan cannot see it. Re-harvest the list whenever `script/` changes:
   ```bash
   grep -rhoE 'vm\.env[A-Za-z]*\(\s*"[A-Za-z0-9_]+"' script/ | sed -E 's/.*"(.*)"/\1/' | sort -u
   grep -rhoE '_(mainnetReq|req|opt|chain)[A-Za-z]*\(\s*"[A-Za-z0-9_]+"' script/ | sed -E 's/.*\("(.*)"/\1/' | sort -u
   ```
   Two dynamic families never appear in that harvest and must be remembered:
   `CONFIRM_<TREASURY>` (`BnbullsConfig:611`) and `<NAME>_TESTNET`
   (`BnbullsConfig:267`, chain 97 only).
5. **`OneWaySwitches` / `Handover` is deliberately not a step in this runbook.**
   It is an irreversible ownership lock. If you find yourself reaching for it,
   you are on the wrong page.
6. **No downtime plan is needed, but there is a gap**: between the new contracts
   going live and the frontend flip, the site still points at the old set. Budget
   20–30 minutes and post the notice before, not after.
