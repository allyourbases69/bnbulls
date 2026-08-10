# Native migration runbook

Replace `Duel` with `DuelNative` and the WBNB `Jackpot` with `JackpotNative`,
so **no player ever holds or receives WBNB**.

Read this whole file before running anything. The one-line summary: **stage 1
is safe and reversible, stage 2 is the cutover and is mostly not.**

> **How to read the checks.** Every `cast call` below has an expected output on
> the same line. If what you see does not match, **STOP** — do not continue to
> the next step, do not "fix it later". Three of the defects this runbook exists
> to prevent are *silent*: nothing reverts, no player sees an error, and the game
> looks healthy while it is broken. The checks are the only thing that sees them.

---

## 0. Why this is a redeploy and not a setting

`Duel._payStake` is `IERC20.safeTransfer` and `Jackpot.prizeToken` is
`immutable` WBNB. A duel winner and a jackpot winner both receive **WBNB
tokens**. No setter, no wiring change and no UI copy can alter that — it is what
the bytecode does. Hence new contracts.

## 1. What is NOT redeployed — but four of them DO need rewiring

`MintDrop`, the three splitters, `Bulls`, `Yards`, `Marketplace` and the
**BNBULL jackpot** are not redeployed.

`JackpotNative.fund(uint256,string)` keeps the old WBNB ABI byte for byte and
unwraps inside the same transaction, so every existing funder keeps calling
exactly what it called before. That one decision is what turns "replace the
money layer" into "replace two contracts".

> ⚠ **"Does not need redeploying" is NOT "does not need rewiring."** The ABI door
> means the funders *can call* the new pot. Nothing points them *at* it. All four
> of `MintDrop`, `mintSplitter`, `reviveSplitter` and `marketSplitter` hold
> `Wire.JackpotBnb = 0xb83eAf…62dA` — the **old** pot. Repointing them is
> timelocked, so it must happen in stage 1 or **every mint and every revive keeps
> paying real money into the stranded pot forever, after cutover.**

The BNBULL pot stays ERC-20 on purpose: $BNBULL genuinely *is* a token, so
there is no WBNB to remove and replacing it would strand its balance for
nothing.

## 2. What is permanently lost

| | |
|---|---|
| **Old pot balance** | **Stranded forever.** `sweepForeignToken` reverts on the prize token — pot money can only be won, never withdrawn. **0.004531 BNB (~$2.72)** at the time of writing. Stage 1 prints the live figure before you sign anything. |
| Jackpot ticket queue | Tickets pending on the old pot never resolve. Drained in §5b, immediately before cutover. |
| `consecutiveLosses` | **Every bull's loss streak resets to 0.** Player-favourable — a bull one loss from the butcher becomes fresh — but it is an undisclosed state change. Say so in the announcement. |
| `fightSeq` nonces | Reset to 0 on the new Duel. Harmless — per-wallet counters. |
| Standing-fight commits | KV is keyed `{chainId}:{duelAddress}`, so old and new partition cleanly. In-flight commits are abandoned, not corrupted. |
| Players' WBNB approvals | Dead. Nobody needs to re-approve — they `deposit()` BNB instead. |

**Preserved:** elo, wins/losses, names, rarity, ownership. All of it lives on
`Bulls`, which is not touched.

> The old balance being unrecoverable is *not* because a pending ticket might
> still win it. It is because `won` requires `balance >= minPoolToFire`, and the
> old pot holds 0.004531 against its own floor of 0.0168 — every ticket there
> loses regardless. There is no scenario where that money moves.

---

## 3. Before you start

**3.1 Tests green.**
```bash
forge test
```
`DuelNative` and `JackpotNative` must both pass, including the solvency
invariants, the fork tests against real WBNB, and the hostile-`receive()` cases.
**STOP on a red suite.** Also confirm the invariant campaigns report real
coverage counts (deposits/duels/tickets/awards > 0) — two campaigns have already
reported green while exercising *nothing*.

**3.2 Audit every timelocked slot for a stale proposal.**

`TimelockedAddress.propose` has **no expiry and no grace period**. A proposal
made months ago is still committable in one transaction with no fresh delay — so
a forgotten one is a zero-delay write sitting available to the owner key forever.

```bash
cast call <bulls>          "wireOf(uint8)(address,address,uint64)" 0   --rpc-url $RPC  # pending -> 0x0
cast call <graveyard>      "wireOf(uint8)(address,address,uint64)" 0   --rpc-url $RPC  # pending -> 0x0
cast call <jackpotBnbull>  "duelWire()(address,address,uint64)"        --rpc-url $RPC  # pending -> 0x0
cast call <mintDrop>       "wireOf(uint8)(address,address,uint64)" 3   --rpc-url $RPC  # pending -> 0x0
cast call <mintSplitter>   "wireOf(uint8)(address,address,uint64)" 3   --rpc-url $RPC  # pending -> 0x0
cast call <reviveSplitter> "wireOf(uint8)(address,address,uint64)" 3   --rpc-url $RPC  # pending -> 0x0
cast call <marketSplitter> "wireOf(uint8)(address,address,uint64)" 3   --rpc-url $RPC  # pending -> 0x0
```
The middle return value is `pending`. **Any non-zero pending: STOP and cancel it**
(`cancelWire(uint8)` / `cancelDuel()`) before proposing anything new — otherwise
stage 1's proposal silently overwrites it and you lose track of what is armed.

*(Verified clean at time of writing: all seven read `pending == 0`.)*

**3.3 Note the stranded figure** so the loss is a decision, not a surprise.
```bash
cast call 0xb83eAf7171690f9Cb1b6Cc4cdA882861998F62dA "pool()(uint256)" --rpc-url $RPC
```

**3.4 Deployer gas: 0.2 BNB.** `preflight` demands `46,000,000 × gasprice`; at
3 gwei that alone is 0.138 BNB. Below this, stage 1 dies on `InsufficientBalance`.

---

## 4. Ship the frontend and keeper code FIRST, dormant

**Do this days before the cutover, not during it.** All of it is inert while
`NEXT_PUBLIC_DUEL_NATIVE=false`, so it can be deployed, reviewed and left alone.
Writing this code under time pressure with the game half-migrated is how the
cutover turns into an outage.

Must be shipped and dormant before stage 1:

- **`frontend/src/app/api/run-duel/route.ts`** — the passive-side stake path.
  It currently resolves the opponent's stake by checking **WBNB balance +
  allowance**. `DuelNative._takeSide` debits `bnbCredit` and never reads an
  allowance, so after cutover every passive opponent reads as 0/0 and the route
  **400s on every fight** with advice ("ask that owner to approve one of the
  two") that is actively wrong. This is the single biggest cutover-day risk.
- **`JackpotNativeAbi`** — `frontend/scripts/generate-abi.ts` has a `DuelNative`
  target but no `JackpotNative` one. Without it `useJackpot.ts` and `PotCard.tsx`
  keep calling the removed `prizeToken()`; with `allowFailure: true` that sets
  `read.error`, `potFigure` returns `'?'`, and the symbol falls back to the
  literal string **`WBNB`**. The native BNB pot would advertise itself as paying
  WBNB with `?` for every number — precisely what this migration exists to prevent.
- **`AdminPots.tsx`** and **`marketing/keeper/pot-seed.ps1`** — both still send
  `topUp(uint256)` with no value. It is payable `topUp()` now.
- **`revertDecode`** — add the new error selectors.

---

## 5. Stage 1 — deploy, wire, propose (players unaffected)

```
powershell -ExecutionPolicy Bypass -File .\keeper\migrate-native.ps1 -Stage 1 -Simulate
powershell -ExecutionPolicy Bypass -File .\keeper\migrate-native.ps1 -Stage 1
```

**Always simulate first.** On launch day simulation caught three separate gates
before a wei moved.

Stage 1 deploys both contracts, wires the new Duel's **five** slots, and
**proposes six** timelocked slots:

| slot | mechanism |
|---|---|
| `Bulls.Duel` | propose → wait → commit |
| `Graveyard.Duel` | propose → wait → commit |
| `JackpotBnbull.duelWire` | propose → wait → commit |
| `MintDrop.JackpotBnb` | propose → wait → commit |
| `mintSplitter.JackpotBnb` | propose → wait → commit |
| `reviveSplitter.JackpotBnb` | propose → wait → commit |
| `marketSplitter.JackpotBnb` | propose → wait → commit |
| new `JackpotNative.duelWire` | `bootstrapDuel`, immediate (fresh contract) |

> `marketSplitter` is 100% BNBULL / 0% BNB so its BNB leg is inert — repoint it
> anyway, so a future policy change cannot resurrect the dead pot.

**Nothing changes for players.** The old Duel serves every fight until stage 2.
**Record `NEW_DUEL` and `NEW_JACKPOT_BNB` from the output** — stage 2 needs them,
and re-running stage 1 without them deploys a *second* pair (see 5.2).

### 5.1 Rollback during the wait — free and total

```bash
cast send <bulls>          "cancelWire(uint8)" 0 --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast send <graveyard>      "cancelWire(uint8)" 0 --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast send <jackpotBnbull>  "cancelDuel()"        --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast send <mintDrop>       "cancelWire(uint8)" 3 --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast send <mintSplitter>   "cancelWire(uint8)" 3 --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast send <reviveSplitter> "cancelWire(uint8)" 3 --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast send <marketSplitter> "cancelWire(uint8)" 3 --rpc-url $RPC --account bnbulls-owner --password-file $PF
```
Then **confirm `pending == 0` on all seven** (§3.2's commands) — there is no
proposal expiry, so an uncancelled one stays armed.

The proposals vanish, the new contracts sit unused, and **nothing was ever at
risk**. The only cost is gas. This is the window to change your mind in.

### 5.2 ⚠ Stage 1 is NOT atomic and NOT resumable

`forge script --broadcast` sends a **sequence of independent transactions**. Only
the *simulation* is atomic. If transaction 7 fails, transactions 1–6 are mined.

`bootstrapDuel`, `bootstrapPayoutParams`, `bootstrapWire` and `addFightAsset` all
revert on a repeat. So after a partial stage 1:

- Re-running **with** `-NewDuel` reverts on the first bootstrap.
- Re-running **without** it deploys a **second pair** and re-proposes at the new
  addresses — and 24h later you commit whichever address is on the command line,
  while the frontend and fleet point at the other. **The game silently splits in half.**

**If stage 1 fails partway:** read `broadcast/MigrateNative.s.sol/56/` to see
exactly which transactions landed, then hand-complete the remainder with `cast
send`. Do not re-run blind.

---

## 5a. During the wait — do these, they are not optional

Both are owner-only, and the new pot exists from stage 1.

**5a.1 Register the new pot as a VRF consumer** at
[vrf.chain.link/bsc](https://vrf.chain.link/bsc), subscription
`115276282669579572854558215202367831174320266803367144595307779655431576370020`.
Until you do, `requestResolve` reverts at the coordinator and tickets pile up
unresolved.

**5a.2 Seed the new pot above `minPoolToFire`. This one destroys real winners.**

`JackpotNative.resolve` computes:
```solidity
bool won = roll == 0 && balance >= minPool && balance > 0;
...
nextToResolve = id + 1;   // the ticket is consumed EITHER WAY
```
A ticket resolved while `pool() < 0.0168 ether` is **consumed and silently
loses**. At 1-in-75 that is roughly **one real winner destroyed per 75 tickets**,
emitting `TicketResolved(..., won=false)` and nothing else. Nobody can ever tell.

```bash
cast send <newPot> "topUp()" --value 0.02ether --rpc-url $RPC --account bnbulls-owner --password-file $PF
cast call <newPot> "pool()(uint256)" --rpc-url $RPC
```
**STOP unless `pool()` reads above `16800000000000000`.**

**5a.3 Diff the incumbent's tunables against the new contract.**

Stage 1 sets none of these — they take the new contract's constructor defaults.
They coincide today, but nothing pins them and cutover day is later.

```bash
for f in "lossesToDie()(uint8)" "potShareBps()(uint16)" "jackpotResolvePerDuel()(uint256)" "allowSelfDuel()(bool)" "wiringDelay()(uint256)"; do
  echo "$f  old=$(cast call <oldDuel> "$f" --rpc-url $RPC)  new=$(cast call <newDuel> "$f" --rpc-url $RPC)"
done
```
Expected on both: `5 / 3000 / 3 / false / 86400`. **Any difference: STOP** and
decide deliberately whether it is intended.

---

## 5b. Immediately before stage 2 — drain and pause

> The old §3.2 said to drain the queues *before stage 1*. That cannot work: the
> wait is 6–24h, during which the old Duel serves every fight and refills them.
> The precondition has to be established **here**, minutes before the commit.

**5b.1 Drain BOTH queues to zero.** Let the keeper resolve everything.
```bash
cast call 0xb83eAf7171690f9Cb1b6Cc4cdA882861998F62dA "pendingTickets()(uint256)" --rpc-url $RPC  # old BNB pot -> 0
cast call 0xAD48049201E79F5DA6fd9ac58Ac6B98B502501a5 "pendingTickets()(uint256)" --rpc-url $RPC  # BNBULL pot  -> 0
```
**STOP unless both read `0`.**

This is not tidiness. `Jackpot._claimDuel` reads `_duelWire.current` **at resolve
time**, not the Duel that opened the ticket. After stage 2 the BNBULL pot consults
the **new** Duel's `duelJackpotPaid` while the abandoned old pot consults the
**old** one. Both maps are empty for a pre-cutover `duelKey`, so **the same fight
could win both pots** — the one-pot-per-fight invariant is arbitrated by
per-Duel storage, and after cutover the two pots read two different contracts.
Draining closes it structurally.

**5b.2 Pause the old Duel, then wait 10 minutes.**
```bash
cast send <oldDuel> "pause()" --rpc-url $RPC --account bnbulls-owner --password-file $PF
```
`MAX_DUEL_EXPIRY_SECONDS` is **300 seconds (5 minutes)** — `serverEnv.ts:62`,
matching `Yards.MIN_EJECT_DELAY`. Wait **10 minutes** for margin, so no signed
result is still live. Without this, every outstanding signature dies at the
instant of commit with a bare, undecodable `NotAuthorized`. No money is lost
(`submitDuel` reverts before taking a stake) but every in-flight fight fails
with an error nobody can read.

---

## 6. Stage 2 — commit (this IS the cutover)

> **⏱ DECLARE THE OUTAGE FIRST.** From the moment stage 2 lands until §8 and §9
> complete, the site still points at the old Duel and **every fight reverts**.
> With a Vercel cloud build that is minutes, not seconds. **Budget 20–30 minutes
> and post the maintenance notice BEFORE you run stage 2, not after.**

**6.1 Pre-commit: confirm what is actually pending.**
```bash
cast call <bulls>         "wireOf(uint8)(address,address,uint64)" 0 --rpc-url $RPC  # pending == NEW duel
cast call <graveyard>     "wireOf(uint8)(address,address,uint64)" 0 --rpc-url $RPC  # pending == NEW duel
cast call <jackpotBnbull> "duelWire()(address,address,uint64)"     --rpc-url $RPC  # pending == NEW duel
```
**STOP on any mismatch.** `commit` takes whatever is pending and only checks the
eta — it does not check the address. If a second stage-1 run armed a different
Duel, this is the last moment you can see it.

**6.2 Commit.**
```
powershell -ExecutionPolicy Bypass -File "...\migrate-native.ps1" -Stage 2 -NewDuel 0x... -NewJackpotBnb 0x... -Simulate
powershell -ExecutionPolicy Bypass -File "...\migrate-native.ps1" -Stage 2 -NewDuel 0x... -NewJackpotBnb 0x...
```

**6.3 Stage 2 must rewrite `deployments/56.json`** with the new `duel` and
`jackpotBnb` and their deploy blocks. Otherwise `Verify.s.sol` reads the stale
record and **fails on a successful migration** — a verifier that always fails
teaches the operator to ignore verifiers. The duel-bot also has no deploy block
to cold-start from, and would rescan from `114896896`.

---

## 7. Verify ON CHAIN before touching the frontend

Do this **first**. A frontend pointed at a half-wired contract is how players
lose money. The previous version of this checklist would have passed with the
Yards gate off, the dev cut at zero, all four funders aimed at the dead pot, and
an unseeded pot burning tickets — it checked the pots' view of the Duel but never
the Duel's view of the pots.

```bash
# ── THE CONSENT GATE. Zero here means EVERY bull is fightable by anyone,
#    whether its owner entered it or not, and eject() becomes decorative.
cast call <newDuel> "wireOf(uint8)(address,address,uint64)" 4 --rpc-url $RPC
#   -> 0x6394151f65b81359A47E193f8a0C80C4c2961544

# ── THE DEV CUT AND ALL FIGHT-DRIVEN POT FUNDING. potShareBps is a share OF the
#    dev cut, so zero here silently kills both.
cast call <newDuel> "devShareBpsOf(address)(uint16)" <wbnb>   --rpc-url $RPC   # -> 1000, NOT 0
cast call <newDuel> "devShareBpsOf(address)(uint16)" <bnbull> --rpc-url $RPC   # -> 1000, NOT 0
cast call <newDuel> "potShareBps()(uint16)"                   --rpc-url $RPC   # -> 3000

# ── THE DUEL'S OWN FIVE WIRES. An unwired pot slot = tickets silently never open.
cast call <newDuel> "wireOf(uint8)(address,address,uint64)" 0 --rpc-url $RPC  # -> graveyard (else every revive reverts)
cast call <newDuel> "wireOf(uint8)(address,address,uint64)" 1 --rpc-url $RPC  # -> jackpotBnbull
cast call <newDuel> "wireOf(uint8)(address,address,uint64)" 2 --rpc-url $RPC  # -> NEW pot
cast call <newDuel> "wireOf(uint8)(address,address,uint64)" 3 --rpc-url $RPC  # -> mintDrop (oracle; zero = every BNB quote reverts)
cast call <newDuel> "marketplace()(address)"                  --rpc-url $RPC  # -> marketplace, NOT 0

# ── THE FOUR FUNDERS. Zero-diff these or the new pot has NO INCOME AT ALL and
#    every mint keeps paying the stranded pot.
for c in <mintDrop> <mintSplitter> <reviveSplitter> <marketSplitter>; do
  cast call $c "wireOf(uint8)(address,address,uint64)" 3 --rpc-url $RPC
done
#   -> all four the NEW pot, NOT 0xb83eAf7171690f9Cb1b6Cc4cdA882861998F62dA

# ── THE COMMITTED WIRES
cast call <bulls>         "duelContract()(address)" --rpc-url $RPC   # -> NEW duel
cast call <graveyard>     "duelContract()(address)" --rpc-url $RPC   # -> NEW duel
cast call <jackpotBnbull> "duel()(address)"         --rpc-url $RPC   # -> NEW duel

# ── THE POT CAN ACTUALLY PAY. Below minPoolToFire every winning ticket is burned.
cast call <newPot> "pool()(uint256)"                   --rpc-url $RPC  # -> > 16800000000000000
cast call <newPot> "payoutParamsBootstrapped()(bool)"  --rpc-url $RPC  # -> true
cast call <newPot> "duel()(address)"                   --rpc-url $RPC  # -> NEW duel
cast call <newPot> "oddsOneIn()(uint256)"              --rpc-url $RPC  # -> 75
cast call <newPot> "payoutBps()(uint256)"              --rpc-url $RPC  # -> 10000
cast call <newPot> "minPoolToFire()(uint256)"          --rpc-url $RPC  # -> 16800000000000000
cast call <newPot> "requestTimeoutBlocks()(uint256)"   --rpc-url $RPC  # -> 24000
cast call <newPot> "publicRequestDelayBlocks()(uint256)" --rpc-url $RPC # -> 1200
cast call <newPot> "trustedCoordinator()(address)"     --rpc-url $RPC  # -> 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9
cast call <newPot> "keyHash()(bytes32)"                --rpc-url $RPC  # -> non-zero
cast call <newPot> "subscriptionId()(uint256)"         --rpc-url $RPC  # -> non-zero
cast call <newPot> "isRequester(address)(bool)" <keeper> --rpc-url $RPC # -> true

# ── IDENTITY. bnbull is IMMUTABLE in the constructor — a mismatch is a redeploy.
cast call <newDuel> "owner()(address)"   --rpc-url $RPC  # -> 0x5b1A749cc7bF1dE8ecA505769BD34Ba65f456805
cast call <newPot>  "owner()(address)"   --rpc-url $RPC  # -> same
cast call <newDuel> "bulls()(address)"   --rpc-url $RPC  # -> 0x3d5f560eF4fd09015BDD203A0e65D9Aa94d96480
cast call <newDuel> "bnbull()(address)"  --rpc-url $RPC  # -> 0xA8D00F9b3ac9D1F7cd0065083fa3ca9221574444

# ── THE FIGHT PATH ITSELF
cast call <newDuel> "usdFightPrice1e18()(uint256)"          --rpc-url $RPC  # -> 2000000000000000000
cast call <newDuel> "fightCostOf(address)(uint256)" <bnbull> --rpc-url $RPC # -> 250000e18. ZERO HERE = FREE FIGHTS.
cast call <newDuel> "maxFightCostOf(address)(uint256)" <wbnb> --rpc-url $RPC # -> non-zero (else every fight reverts UnsupportedAsset)
cast call <newDuel> "trustedSigner()(address)"              --rpc-url $RPC  # -> 0xe9c40972f92C26FD86f22773C6ed74ceBaFe5536

# ── NOTHING CROSSES THE SEAM
cast call 0xb83eAf7171690f9Cb1b6Cc4cdA882861998F62dA "pendingTickets()(uint256)" --rpc-url $RPC  # -> 0
cast call 0xAD48049201E79F5DA6fd9ac58Ac6B98B502501a5 "pendingTickets()(uint256)" --rpc-url $RPC  # -> 0
```

**Zero means opposite things in different contracts.** On MintDrop, Marketplace
and Graveyard, zero *disables* the BNBULL leg. On `Duel`, zero reads as a **free
fight**, and a free fight still opens a jackpot ticket.

### 7.1 The proof no `cast call` can give you

**Before you announce anything**, from a wallet that is **not the owner's**:

1. `deposit()` some BNB, confirm `bnbCredit` reads it back.
2. Submit **one real fight** end to end and confirm it settles.
3. `withdraw()` and confirm the BNB lands in the wallet.

Every check above can pass on a contract that still cannot be used. This is the
one that proves it can.

---

## 8. Flip the frontend

Only after §7 passes.

**8.1** Edit `marketing/keeper/.state/mainnet-addresses.json` — `"duel"` and
`"jackpotBnb"` to the new addresses. *(The addresses are not literals in
`launch-frontend.ps1`; they come from this file.)*

**8.2** Add to `$envMap` in `marketing/keeper/launch-frontend.ps1`:
```powershell
'NEXT_PUBLIC_DUEL_NATIVE' = 'true'
```
`env.ts` requires this flipped in the **same deploy** as the new `NEXT_PUBLIC_DUEL`.
Miss it and `NATIVE_DUEL` computes false: the deposit/withdraw UI never renders,
and **a winner sees nothing in their wallet and no explanation of where their
money went.**

**8.3** Add the OLD Duel and OLD pot to the `$testnetAddrs` guard in
`launch-frontend.ps1` so a stale deploy is caught by the existing check.

**8.4** Redeploy, then confirm `/duel` and `/pots` read the new addresses and the
fight-balance UI renders.

---

## 9. Flip the fleet

**Eight** services read these addresses, not two.

**9.1** `env/common.env`: `DUEL`, `JACKPOT_BNB` → new addresses.

**9.2** `jackpot-vrf-keeper`'s **`JACKPOT_POOLS` overrides** the fallback
addresses — update it or the keeper silently polls the dead pot. This exact trap
cost an hour on launch day.

**9.3** `marketing/keeper/env/autoplay-bot.env` pins its **own** `DUEL=0x024616…`
and loads **before** `common.env` on a first-value-wins basis, so editing
`common.env` alone leaves autoplay hammering the dead Duel. It is also
architecturally incompatible — it wraps BNB and `approve`s WBNB where
`DuelNative` needs `deposit()` into `bnbCredit`. It does not run under
`docker compose` (it is launched by `start-autoplay.ps1`), so compose will not
touch it. **Leave it stopped until it is rewritten.**

**9.4** Wipe the state files whose cursors and ids describe the old contracts:
```
.state/duel-bot.json
.state/duel-bot.tickets.json     # ticket ids on the old pot's numbering
.state/alert-bot.json
.state/alert-bot.alarms.json     # pot-flat counters keyed to the old pot
```
Seed the duel-bot cursor to the **new Duel's deploy block** (printed by stage 1).
A wiped state file with no cursor rescans from the original deploy block.

**9.5** `marketing/keeper/.state/launch-watcher.json` still holds
`contracts.duel` / `contracts.jackpotBnb`. If launch-watcher ever re-completes it
rewrites `.state/mainnet-addresses.json` from that state and **silently reverts
the frontend addresses on the next deploy.** Update or delete it.

**9.6** Recreate:
```bash
ssh <host> "cd '<stack>' && export KEEPER_SECRETS_DIR=<secrets-dir> && \
  docker compose up -d --force-recreate --no-deps <services>"
```
`docker compose restart` does **not** re-read env or code. Always `--force-recreate`.

*(`game-stats`, `token-bought` and `fight-price-keeper` also read these addresses
— recreate them too if they are running.)*

---

## 10. Rollback AFTER cutover — honest version

Reversible: all six wires can be proposed back — but each costs **another full
timelock**. You cannot fail back quickly. Budget for a bad cutover meaning hours
on the old contract, not minutes.

Irreversible: money already paid into the new pot, tickets opened on the new
Duel, and the stranded balance in the old pot.

**Therefore: the real safety margin is the window in §5, not the rollback.** The
plan's whole safety budget is that wait — spend it on §5a and §5b, not on waiting.

## 11. What worries me

- **Three of the worst failures are silent.** The Yards gate, the dev-cut
  sentinel and the funder rewiring all fail with nothing reverting and no player
  seeing an error. §7 is the only thing that catches them. Run it.
- **The new code is young.** The incumbent has 760 tests and an E2E matrix
  settled to the wei. The replacement custodies native BNB, which the old one
  never did.
- **`bnbCredit` changes the threat model.** The old Duel held nothing between
  calls; the new one custodies player funds indefinitely. Any future native
  rescue must be bounded by `address(this).balance - totalBnbCredit`.
- **`jackpot-vrf-keeper`'s label-swap alarm dies at cutover** — it reads
  `prizeToken()`, `soft()` swallows the revert, `symbol` stays `'?'`, and the
  mismatch guard skips itself. The "two pools got swapped" alarm is dead for the
  BNB pool from cutover onward until that reader is updated.
