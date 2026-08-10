# BullPen migration runbook

**Status: ready to rehearse. NOT ready to broadcast — see §9 for the three
things that must clear first, and §10 for what is not finished.**

---

## 0. What this changes, and why

`Bulls.rarityOf(id)` is a public view over a table fixed at deploy, and
`Bulls.nextTokenId()` is public. Anyone can call `rarityOf(nextTokenId())` and
know exactly what the next mint yields. Live right now: ids 32-55 hold no
legendary, **#56 is legendary**, #38/#41/#47 are epic. The rational buyer waits
for #56; the uninformed one pays $10 for a bull whose tier is already public.

`BullPen` takes **when** you buy out of the decision of **which** bull you get.
It cannot be retro-fitted to the live `MintDrop` — that contract's pen slot has
never been bootstrapped and bootstrapping is the only instant path — so the drop
is **replaced**, not re-wired.

### The state this runbook assumes

| | |
|---|---|
| `Bulls` | `0x70CBf443981e7a3B48151708bfC8f5A5E3B02d25` |
| live `MintDrop` | `0xAE7e1FE786aFeB67Da57e032635e7fd9534aC1Ba` |
| `nextTokenId` | **32** → 31 minted, **469 unsold**, 500 max |
| `MintDrop.totalSold` | **3** (the other 28 were the re-issue, not sales) |
| `kingMinted` | **false** — #501 is separate and is NOT part of this |

Re-read these before you start. Every number below is derived from chain by the
scripts; none of it is hardcoded.

---

## 1. The eight steps

Every step:

```
powershell -ExecutionPolicy Bypass -File "C:\tools\Claude\bnbulls\marketing\keeper\deploy-pen.ps1" -Step <step> [-Simulate]
```

**Always `-Simulate` first on every broadcasting step.** Simulation restores
`deployments/56.json` byte-for-byte on exit, so a dry run leaves no trace.

Every step takes `.state/owner-signing.lock` and asks the chain whether this
wallet already has a transaction in flight. **One owner-signing script at a
time** — on 2026-08-10 a second script ate a nonce and killed a re-issue at
`expected 215 got 217`.

---

### Step 1 — `deploy`

```
deploy-pen.ps1 -Step deploy -Simulate
deploy-pen.ps1 -Step deploy
```

Deploys `BullPen` and a replacement `MintDrop`. Wires nothing. Changes nothing
live. The new drop **ships paused** (its constructor calls `_pause()`).

Resume-safe: an address already in the record **that has code** is reused.

**Check before moving on:**
```
cast code <bullPen>       # non-empty
cast code <mintDropNext>  # non-empty
grep -E "bullPen|mintDropNext" deployments/56.json
```

**Rollback:** total. Two unwired contracts sitting on chain, costing gas and
nothing else. Delete the two keys from the record and walk away.

---

### Step 2 — `wire`

```
deploy-pen.ps1 -Step wire -Simulate
deploy-pen.ps1 -Step wire
```

Idempotent — every write is guarded by a read, so a partial run is re-runnable.
It does all of:

- the new drop's four wires (`PriceFeed`, `Router`, `JackpotBnbull`, `JackpotBnb`)
  — all `bootstrapWire`, instant, because the slots are zero on a fresh contract.
  **This is the seam that makes the whole thing a same-day job instead of a
  24-hour timelock per slot.**
- **every non-wire setting COPIED OFF THE LIVE DROP** — keeper, pot shares,
  `inlineSlippageBps`, `minPoolLiquidity`, `minPoolLiquidityAlt`, oracle band,
  airdrop, both discounts, LP share, sell policy. Copied, never re-typed: a
  constant in a script is a second source of truth that drifts.
- **the ladder rebase** (§3).
- **`setFunder(newDrop, true)` on BOTH jackpots.**
- the pen: `bootstrapSeller`, `setVrfConfig` (**copied off the live BNB jackpot**,
  not from env), `setVrfTimeoutBlocks`, and `bootstrapWire(Wire.Pen, pen)` on
  the drop.
- `addConsumer(subId, pen)` on the VRF coordinator.

> ⚠ **The funder wires are the ones that fail silently.** `Jackpot.fund` reverts
> `NotFunder` for an unknown caller, `MintDrop._toBnbPotOrAccrue` **catches**
> it, and the slice accrues instead. Mints keep working, the site keeps saying
> the pot grows, and **the pot does not grow**. The preflight asserts both,
> twice.

**Check before moving on:** run step 3. That is what it is for.

**Rollback:** total. Nothing live has been touched. The old drop is still the
only seller and is still open.

---

### Step 3 — `preflight`

```
deploy-pen.ps1 -Step preflight
```

Read-only. **Reverts** rather than warning, because a warning in a green run is
a warning nobody reads. Full list of refusals in §2.

**Read every line of the output.** This is the step that stands between a typo
and 469 permanently stranded bulls.

**Rollback:** n/a, it sends nothing.

---

### Step 4 — `silence`

```
deploy-pen.ps1 -Step silence
```

See §6. Records the block the pre-mint starts from and tells you which bots to
stop and how. **`premint` refuses to start until this has run.**

**Rollback:** delete `.state/pen-premint-silence.json`.

---

### Step 5 — `premint` ⛔

**See §4. This is the irreversible one.** Read that section before running it.

---

### Step 6 — `unsilence`

```
deploy-pen.ps1 -Step unsilence
```

Advances the cursors past the pre-mint range, **after** verifying on chain that
the range contains the pre-mint and nothing else. See §6.

**Rollback:** copy `.state/<bot>.json.pre-pen.bak` back over `<bot>.json`.

---

### Step 7 — `switch`

```
deploy-pen.ps1 -Step switch -Simulate
deploy-pen.ps1 -Step switch
```

Pauses the old drop, unpauses the new one, and rotates the record so
`.contracts.mintDrop` names the new seller.

**Order is load-bearing: pause first, then unpause.** The reverse leaves a window
where both sell.

Refuses if the pen is empty, if the pre-mint did not finish, if the new drop is
not wired to the pen, or if the pen does not trust the new drop.

**Check before moving on:**
```
cast call <oldDrop> "paused()(bool)"   # true
cast call <newDrop> "paused()(bool)"   # false
cast call <bullPen> "sellable()(uint256)"   # 469
```

**Rollback: fully reversible, and it is one transaction each way.** `pause()`
the new drop and `unpause()` the old one. But note the old drop can no longer
mint — after the pre-mint `Bulls.mint()` reverts `SupplyExhausted` for every
caller — so rolling back means **the drop is closed**, not "back to normal".
There is no way back to selling without the pen.

---

### Step 8 — `verify`, then the fleet and the frontend

```
deploy-pen.ps1 -Step verify
```

Then, and these are **not optional**:

1. **Fleet:** set `BULLPEN=` and repoint `MINTDROP=` in
   `marketing/keeper/env/common.env`, then **`./deploy.sh ship-all`** — not
   `ship <service>`. `bot-common.mjs` ships in a **single shared image** across
   32 importers, so one service does not carry the change.
2. **Frontend:** `NEXT_PUBLIC_BULLPEN` **and** `NEXT_PUBLIC_MINTDROP` must flip
   in the **same deploy**.
   > ⚠ If the pen var is set against a drop that lacks `penContract()`, the read
   > **fails rather than returning zero** — `usePen` goes `unavailable` and that
   > propagates to browse / market / ranks / mint as retry cards.
   > `launch-frontend.ps1` pulls both from `deployments/56.json`, so the happy
   > path is covered; the rule exists so nobody sets one by hand. The loud
   > failure is correct and should not be softened.
3. **BscScan:** `verify-all.ps1` for both new contracts. Note `MintDrop` now
   verifies at **`optimizer_runs = 1`** (§8).
4. **Blockaid:** two fresh addresses do not inherit the domain appeal. Re-check.

---

## 2. What the preflight refuses, and why

Each line tells you whether you hit a real problem or skipped a step.

| Refusal | Meaning |
|---|---|
| `BullPen is missing or has no code` | you skipped step 1 |
| `the replacement MintDrop is missing or has no code` | you skipped step 1 |
| `the record already names the new drop as live` | you already switched; this preflight compares new-vs-old and no longer means anything |
| `BullPen.bulls is not the live collection` | **real.** A pen over a different `Bulls` accepts stock and can never hand out what the drop sells. Immutable, so redeploy |
| `new MintDrop.bulls / .bnbull / .wbnb differ` | **real.** Same shape, redeploy |
| `new MintDrop is not wired to this pen` | you skipped step 2, or it half-ran |
| `BullPen.seller is not the new MintDrop` | ditto. Half a loop is worse than none: the drop reserves into a pen that reverts `NotSeller` and every mint fails |
| `BullPen.keyHash / subscriptionId is unset` | step 2 half-ran. `reserve()` reverts without them |
| **`BullPen is NOT a consumer on the VRF subscription`** | **real and fatal.** Every mint reverts |
| **`VRF subscription native balance below 0.25 BNB`** | **real. This is failing today at 0.2489 BNB.** Top it up. When it runs dry `reserve()` reverts and every mint reverts with it |
| `the refund window does not open before the forced-draw window` | **real.** A stranger could force an outcome onto a buyer still entitled to leave |
| `the refund window is below the floor` | **real.** It would open while VRF could still plausibly deliver |
| **`JackpotBnb wire is wrong — MINT PROCEEDS WOULD STOP REACHING THE BNB JACKPOT`** | **real and silent.** Nothing reverts; the pot just stops growing |
| **`BNB pot does not accept the new drop as a funder`** | same failure, other half. Asserted separately on purpose |
| `BNBULL pot does not accept the new drop as a funder` | every BNBULL slice would silently accrue |
| `treasury / lpTreasury / keeper / pot shares / lpShare / sell policy differs` | step 2 half-ran, or somebody changed the live drop mid-migration |
| `minPoolLiquidity is not the 1 BNB thin-pool floor` | **real.** A 200x-low floor is the exact class of leak this check exists for |
| `inlineSlippageBps is not 500` | **real.** The constructor default matches today by coincidence; this pins it |
| `feedDecimals differs` | the oracle wire did not read `decimals()`. Re-run step 2 |
| `bnbUsdPrice() REVERTS` | **real.** Bad oracle wire or a stale feed. A drop whose price read reverts is a dead drop |
| **`LADDER NOT REBASED`** | **real, and the expensive one.** See §3 |
| `LADDER CORRUPT: a dollar sticker moved` | **real.** The rebase moves boundaries only. Somebody re-priced the drop |
| `a price tier carries a NON-ZERO BNBULL peg pre-graduation` | **real.** The 1,250x peg leak, third attempt |
| `Bulls is PAUSED` | the pre-mint would revert. Unpause it |
| `the new drop is NOT paused` | it must stay closed until step 7 |
| `BullPen already holds BNB` | **real.** Leftover money that cannot be told apart from live escrow later |
| `the signing wallet does not own Bulls / the drop / the pen` | wrong wallet. The pre-mint would revert 469 times |
| **WARN** `old drop has pending pot buckets` | **not a blocker.** Currently 0.00996 BNB. **Do not revoke the old drop's funder role until it is drained** — the sweep ends in `Jackpot.fund` and revoking strands it |

---

## 3. The ladder rebase — the silent money loss

A fresh `MintDrop` starts `totalSold = 0`. A ladder copied across verbatim
**restarts at rung one**: the `upToSold: 100` rung would run for another 100
sales instead of the 69 that remain.

**Correct rebase, computed on chain from `nextTokenId`:**

```
69 / 169 / 269 / 369 / 500     at $10 / $20 / $35 / $50 / $75
```

Two things to know:

- **It is 69, not 70.** 31 are minted; `100 − 31 = 69`.
- **The last boundary is 500, not 469.** `setPriceTiers` **reverts
  `InvalidTiers`** unless the final rung reaches `MAX_MINT`. A table stopping at
  469 would also leave mints 470-500 unpriced, and there is no flat-price
  fallback — `priceForMint` reverts `NotPriced`. The real cap is the pen's own
  `PoolTooSmall`, so the headroom is unreachable, not loose.

An un-rebased ladder sells **31 bulls at $10 that should be $20**. Nothing
reverts, nothing logs, and it is not recoverable — those buyers keep their
bulls. The preflight asserts it; `script/lib/LadderRebase.sol` is a pure library
with 11 tests including one that demonstrates the cost.

---

## 4. ⛔ Step 5 — `premint` — THE IRREVERSIBLE ONE

```
deploy-pen.ps1 -Step premint -Simulate      # ALWAYS FIRST
deploy-pen.ps1 -Step premint
```

**This owner-mints all 469 remaining bulls into the pen. It cannot be undone.**
`Bulls` has no burn and `nextTokenId` never goes backwards. The moment it lands
the collection is **permanently fully minted** and the **pen is the only route
to a bull, forever**. A pen that cannot hand them out strands 469 bulls
permanently.

**It is 469 separate owner transactions.** `Bulls.mint` has no batch and a helper
contract cannot be the minter without a 24-hour timelock, so `forge script`
sends one transaction per bull — roughly 12 minutes at `--slow`, spanning ~469
blocks. That block span is why §6 exists.

### What must be true before it runs

1. **`-Step preflight` passes clean.** No exceptions.
2. **The VRF subscription is funded.** Today it is at **0.2489 BNB and the
   preflight refuses.** Worst case is one request per bull.
3. **`-Step silence` has run.** The script refuses without it.
4. **The pen-keeper is deployed and running** (§10).
5. **You have simulated it.**

### The three gates

- The script re-runs **the identical preflight code** (not a copy) inside its own
  simulation. A revert during simulation stops the run before a single
  transaction is broadcast. **There is no path from a failing check to a landed
  mint.**
- It refuses without the silence marker.
- It asks you to **type the number of bulls** (`469`) to proceed.

**There is no `-Force` that opens a path past any of these.**

### Rollback

**None for the mint itself.** What *is* recoverable: the pre-mint is resumable —
if it dies at bull 200, re-running mints exactly the remaining 269, because
`nextTokenId` is the only cursor it has. And a stocked pen with an unopened drop
is a safe resting state: nothing is for sale, nobody has paid, and you can take
as long as you like over step 7.

---

## 5. The refund design

> **The owner asked for this specifically. This section is the answer.**

### The problem

`MintDrop._routeNative` ran **before** the reservation existed: 70% to a
treasury EOA and 30% into `Jackpot.fund`, which is **no-withdraw by design**.
Nothing gets money out of a jackpot except a won ticket. So if VRF never
delivered, the buyer had paid, had no bull, and **there was nothing left to
refund them out of.** A refund bolted onto that would have had no funds.

### The change

**Escrow at reserve → route at settle → refund on timeout.**

| | |
|---|---|
| `reserve` | the **pen takes custody**. Nothing decided, nothing moved anywhere irreversible |
| `settle` | bulls delivered **and** the escrow pushed back to `MintDrop.routeReservedPayment`, which runs the identical 20/10/70 split |
| `refund` | after the timeout, and **only while no seed exists**, the payer takes their money back |

Escrow lives in `BullPen`, not `MintDrop` — `MintDrop` had 371 bytes of room
(§8). The pots and treasury are paid **one transaction later** than before.
**That is the entire cost.**

### The timeout: `refundAfterBlocks = 7,200`

- Floor `MIN_REFUND_AFTER_BLOCKS = 4,000`, owner-settable, and it **must stay
  below `vrfTimeoutBlocks` (24,000)** — enforced by both setters, both
  directions.
- **Why not the house 24,000?** That number is right for a jackpot roll, which
  is a background job nobody is standing over. A mint is not. A buyer who has
  paid and has nothing is **a person waiting**, and 24,000 blocks is hours.
- **Why not shorter?** The worst measured live fulfilment was **3,169 blocks**.
  7,200 is **2.3×** that, so a refund essentially never races a live word.
  Racing is *safe* (the flags make it harmless) but wasteful — the subscription
  has already paid for a word that then gets dropped.
- **~90 minutes** at BSC's current ~0.75s blocks. ⚠ **The unit is the trap**: it
  bounds a human wait, which is time, but it counts **blocks**. Re-check it
  whenever the block time moves. That is why it is a bounded setter, not a
  `constant`.
- **The floor exists to stop the owner, not the buyer.** Below the worst
  observed fulfilment a refund window becomes a griefing tool: reserve, refund
  instantly, repeat, and the queue churns while the subscription pays for words
  nobody uses.

### The ordering, which is the design

```
0 .. 7,200 blocks     VRF is working on it. Wait.
7,200 ..              the BUYER may leave with their money.
24,000 ..             ANYONE may force the draw through the blockhash fallback.
```

The refund window opens **first**, deliberately. The buyer gets the choice to
leave before the system starts forcing an outcome on them. If the fallback
opened first, a stranger could force an outcome onto a buyer who wanted out, and
the refund would be a promise anybody could cancel.

### The two rules that keep it safe

1. **`refund` requires `!seeded`, not merely `!settled`.** Once a word exists the
   drawn ids are computable off chain from public state, so a refund after that
   point **would be the free-abort attack** the whole two-transaction design
   exists to close: buy, compute, unwind unless it is a legendary. This is the
   single most important line in the contract after `_drawOne`.
2. **Refund and settle are mutually exclusive forever.** One flag, written
   before any external call, checked by `settle`, `fulfillRandomWords`,
   `armFallback` and `pinFallbackSeed`. A word arriving after a refund is
   **inert**.

### Payer-only, and why

`refund` is callable **only by the payer**. Not for permission — for
correctness. A refund draws nothing, so `_pool` is identical either side of it,
but **whether a stuck reservation refunds or settles changes what the next one
draws**. Permissionless refunding would let the holder of a seeded reservation B
refund a stranger's stuck reservation A and pick between two outcomes for B,
both computable off chain. One bit, free. Payer-only makes that bit cost the
attacker **a whole mint of their own**.

It is a **narrowing, not a proof**: a buyer holding two reservations, one stuck,
can still make that choice. Written down rather than papered over.

**Liveness is unaffected.** `armFallback`, `pinFallbackSeed` and `settle` stay
permissionless, so anyone can always push a stuck reservation through to
delivery. A lost key can never wedge the queue.

### Everything else

- **FIFO holes:** `_advanceQueue()` skips refunded slots. Safe *because* a refund
  draws nothing. Tested at the head, in the middle with live reservations both
  sides, and as a consecutive run.
- **Batches are all-or-nothing** — one reservation carries one seed, so there is
  no partial seed to refund partially.
- **A reverting recipient** parks to `unclaimedRefundNative` + `claimRefund`;
  the queue advances regardless.
- **Gifts:** a `_byPayer` index (written only when `payer != to`, so a self-mint
  costs nothing) means the **gifter can find the reservation they are entitled
  to refund**. Without it the one person who could refund was the one person who
  could not find it.

**19 refund tests**, including `test_aWordArrivingAfterARefundIsInertAndCannotSettle`.

---

## 6. Silencing the mint monitoring

```
pen-premint-silence.ps1 -Action status | silence | unsilence
```

(or `deploy-pen.ps1 -Step silence` / `-Step unsilence`)

### Why stopping the bots is not enough

Every announce bot keeps a **block cursor** in `.state/<bot>.json` and on restart
sweeps `lastBlock+1 .. head`. **A bot that is stopped for the pre-mint does not
miss it — it posts the entire backlog the moment it comes back.**

### Who actually reacts — established by reading them, not assuming

| bot | reacts? |
|---|---|
| **mint-bot** | **yes, loudly.** Watches `Bulls.BullMinted`, posts **one Telegram card per transaction**, uncapped, spaced 3.2s. 469 transactions ≈ **25 minutes of flood** |
| **flash-mint-guard** | **no.** It watches `MintDrop.BullSold` **only**. An owner pre-mint calls `Bulls.mint()` and emits no `BullSold`, so it is invisible. Its cursor is advanced anyway, so the evidence is a skipped range with zero matching logs rather than an argument |
| **alert-bot** | **yes, indirectly — this is the surprising one.** It does not watch mints, but detector 4 reads **mint-bot's own state file** and alarms when it looks stalled. Silencing mint-bot without this fires "mint-bot LOOKS STALLED" into the ops channel |
| **game-stats** | **yes, but it has NO cursor** — it is a poller reading `nextTokenId`. Advancing a cursor cannot help it. Its fix is the pen-aware count, not this script. It is profile-gated (`stats`) so it is often not running |

### The procedure

**`-Action silence`** records the starting block, backs up every state file to
`<name>.pre-pen.bak`, and prints exactly which env var to blank in which file,
plus the **sanctioned stop method**: unset the address, then
`./deploy.sh ship <service>`. **Never `docker compose restart`** — it does not
re-read the env file.

**`-Action unsilence`** (after the pre-mint) does the important half:

> It reads the skipped block range **back off chain** and counts every
> `BullMinted` in it against those whose recipient was the pen. **If any log in
> the range did not go to the pen, it REFUSES** — that log is a real buyer's
> mint, and advancing past it means it is *never* announced, not delayed.
> `-SkipForeignLogs` exists and should not be used.

Only if the range is clean does it advance each `lastBlock` to the end block and
clear the dedupe ring.

### Confirming the skip worked

1. Restore each env file's address and `./deploy.sh ship <service>`.
2. Watch the channel for 60s — **zero pre-mint cards is the pass.**
3. **Buy one bull through the new drop** and confirm exactly one card appears —
   that also proves the cursor was not advanced too far.
4. `healthcheck.mjs <bot>` — green within one poll.

**Rollback:** copy `.state/<bot>.json.pre-pen.bak` back and delete
`.state/pen-premint-silence.json`.

---

## 7. The player-facing copy

Source of truth is `frontend/src/components/mint/PendingReservations.tsx` and
`MintPanel.tsx`. Verified strings include **"your bulls are being drawn"**,
**"checking where your bulls are up to…"**, **"your money has been returned"**
and **"check the wallet that paid"** (shown to a gift recipient, whose refund
belongs to the payer).

The design the copy implements:

- **⚠ It must never promise an instant refund.** The wait is mandatory —
  refunding earlier lets the word arrive afterwards and hand them the bull as
  well. Resolved by telling the player early rather than pretending it is
  instant.
- **The moment a reservation looks stalled**, say so, with a **real countdown**
  from `reservedAtBlock + refundAfterBlocks` against the current block, and say
  the money is safe because the contract is holding it.
- **The money is safe from the moment it is escrowed**, in both branches. Say
  that, because it is true whether it ends as a bull or a refund.
- **`Refundable`** → offer the button, and say the keeper will normally do it
  for them.
- **`Refunded`** → what happened, the amount, and **mint again**.
- **All of it survives a page reload and works on another device**, because it
  is derived purely from the connected address and chain state. A refunded
  reservation deliberately **stays in `openReservationsOf`** so the dialogue does
  not vanish the instant it becomes true.
- Gifts render by role: the payer gets the refund controls, the recipient gets
  the wait and an honest line about whose money it is.

---

## 8. Two things that will surprise you

**`MintDrop` was 139 bytes over EIP-170 and could not be deployed at all.** The
committed pen wiring built to 24,715 against a 24,576 limit. Nobody noticed
because a zero pen address is today's behaviour byte-for-byte, so it was never
rebuilt for deployment. Fixed structurally — the pen slot is now an appended
`Wire.Pen` enum member reusing `bootstrapWire`/`proposeWire`/`commitWire`/
`cancelWire`, with `penContract()` kept as a one-line view — **plus a per-file
`optimizer_runs = 1` restriction on `contracts/MintDrop.sol` only.** Now 24,205,
**371 bytes spare**. Project-wide settings are untouched so every other artifact
stays byte-identical and `verify-all.ps1` can still reproduce the live set.
`via_ir` was tried and rejected: a single build did not finish in 15 minutes.

> ⚠ **The admin ceremony for the pen moved.** `bootstrapPen`/`proposePen`/
> `commitPen`/`cancelPen`/`penWire()` **are gone**. Use
> `bootstrapWire(Wire.Pen, x)` etc. `penContract()` is unchanged, so every
> *reader* is unaffected.

**Three slots elsewhere still name the OLD `MintDrop`, deliberately.**
`Bulls.Wire.MintDrop` (inert — after the pre-mint `Bulls.mint()` reverts
`SupplyExhausted` for everyone), `Duel.Wire.MintDrop` (the BNB/USD **oracle**,
a view with no `whenNotPaused`), and the two splitters' policy slot (views).
All three are 24-hour timelocked and none needs to move.

> ⚠ **So the old drop is retired as a SELLER but stays live as an ORACLE and a
> POLICY source. Do not treat it as dead.** Changing `bnbullShareBps` on it
> still moves both splitters' policy.

---

## 9. Before you broadcast anything

- [ ] **Top up the VRF subscription.** At 0.2489 BNB the preflight refuses.
- [ ] **Deploy and run the pen-keeper** (§10). Without it, "wait, then get
      refunded" becomes the normal outcome instead of the backstop.
- [ ] Ship the `bot-common.mjs` provider fix fleet-wide with **`ship-all`**. It
      is worth shipping ahead of this migration on its own merits: a
      revert-with-no-data was taking **85 seconds** on `bsc.drpc.org` and
      hitting every bot's FallbackProvider. Idle pass **40s → 3.3s**.
- [ ] Rehearse the whole sequence on a fork. It has been done once end-to-end
      (deploy → wire → preflight → 469-bull pre-mint → pen holds 469); do it
      again after any change.
- [ ] Decide about the king. **It is NOT in the 469** (ids 32-500 is exactly
      469). `rarityOf(501)` is a constant 5, so there is no snipe to close, and
      `mintKing` is a separate owner call. Recommendation: leave it out.

Unaffected and verified: **marketplace listings and bull pit membership** both
key on token id and owner, and no already-minted bull moves.

---

## 10. What is NOT finished — read this

- **The pen-keeper is built and green but has not been deployed.** It is the
  hard gate on step 5. `pen-keeper.mjs`, `pen-keeper.selftest.mjs` (123
  assertions), compose entry and healthcheck all exist and pass; nothing has
  been shipped to the NAS.
- **The frontend gift-role rendering was still being applied** when this was
  written. The contract side is done and tested; the last UI pass splits the
  payer/recipient views and regenerates the ABIs. **Re-run `npm run build` and
  confirm before the switch.** Everything else frontend-side had already
  verified green (`tsc` 0, lint 0, `npm run verify` 0, build 520/520).
- **Nothing is committed.** The whole change set is working-tree only.
- **No BscScan verification has been attempted** for either new contract.
- **The 0.00996 BNB in the old drop's pending pot buckets has not been drained.**
  Not a blocker; just do not revoke that drop's funder role until it is.
- **The residual grind edge in §5 is real and not closed**: a buyer holding two
  reservations, one stuck and unseeded, can choose between two outcomes for the
  other. One bit, and it costs them a whole mint. Documented in the contract.

**Test position:** 991 tests / 59 suites, 0 failed, 0 skipped (baseline 944/56).
Nothing disabled. `forge build` clean. All 51 keeper `.mjs` parse, all 15
selftests pass, `compose-check` ALL PASS.
