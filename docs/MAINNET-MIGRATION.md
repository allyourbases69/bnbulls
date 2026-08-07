# MAINNET MIGRATION — bnbulls launch-day runbook

> **Written for 3am under pressure.** Every step is a command or a decision, in
> the order it must happen. If you are reading this for the first time on launch
> day, read §0 and §1 in full before you type anything — the rest can be
> followed line by line.
>
> Companion docs, none of which this one replaces:
> `DEPLOY-SAFETY-PREFLIGHT.md` (the $154 loss and the blocking rules),
> `BNBULLS-BOOTSTRAP.md §7` (why the order is the order),
> `FOUR-MEME-LAUNCH-ROUTE.md` (the token launch itself),
> `DECISIONS.md` (every numbered ruling referenced below).

---

## 0. STOP CONDITIONS — do not proceed if any of these is true

| # | Condition | Why it stops you |
|---|---|---|
| 0.1 | `deployments/56.json` already exists with contracts that have code | You are about to deploy a **second** game. Resume instead — the deploy is resumable and keyed on `code.length`. |
| 0.2 | `~/.foundry/keystores` has not been copied off this box | Blocking rule 2. A fork rehearsal **creates and deletes wallets**. `KEYSTORE_SNAPSHOT_TAKEN=true` is an assertion you made, not one the script can check. |
| 0.3 | The BNBULL token address is not final | `Duel`, `MintDrop`, `Graveyard`, `Marketplace` and all three splitters take it at construction or in a **bootstrap-once** slot. Wrong token = full redeploy. |
| 0.4 | VRF subscription does not exist and is not funded | Not fatal to the deploy, but the pots will fill and never pay, **with no error anywhere**. See §7. |
| 0.5 | You cannot name the owner address from memory and confirm it at the terminal | The $154 loss was a well-formed address nobody re-checked. |
| 0.6 | `forge test` is not green | 760 tests. Non-negotiable. |

**The single most expensive property of this deployment:** almost every wiring
slot is `bootstrap`-once-then-**timelocked**. On a fresh chain every slot is
zero, so `bootstrap` is instant and the whole wiring lands in one run. **That
free instant write exists exactly once per slot, on launch day.** Every
correction afterwards costs 24 hours. Get it right the first time.

---

## 1. THE FOUR GOTCHAS WE HAVE ALREADY PAID FOR

### 1.1 The whitelist gap that killed the BNBULL money layer

Our own `BNBull.sol` has a launch-window transfer whitelist. Nine contracts move
BNBULL, and **every one of them must be whitelisted or its leg dies silently**:

```
Jackpot BNBULL   <- the one that actually wedged: a WINNING ticket reverts
Jackpot BNB          TradingNotEnabled, Duel's try/catch swallows it, and the
MintDrop             ticket queue wedges with no error anywhere
Duel
Graveyard
Marketplace
MintBnbullSplitter
ReviveBuySplitter
MarketPotSplitter
+ PancakeSwap v2 router   (not a "mover", but an LP seed moves BNBULL through
                           it in amounts over the launch window's 1%/0.5% caps)
+ the PAIR                (does NOT exist yet — created by the first
                           addLiquidity. Whitelist BY HAND at launch if caps
                           are still active.)
```

`Wire.s.sol:wireTokenWhitelist` writes all of these in one `setWhitelistBulk`.
`Verify` fails on a missing pot and warns on a missing router.

### 1.2 ⚠ ON MAINNET THIS SECTION IS PROBABLY A NO-OP — AND THAT IS CORRECT

`DECISIONS.md §4` launches BNBULL on **four.meme**. That token is **theirs**:

- **immutable** — no whitelist, no caps, no `enableTrading`;
- **no owner control** — you cannot call `setWhitelist`, there is no such function;
- so **every whitelist step above must be skipped, not attempted**.

`tokenHasWhitelist()` probes this **by calling `whitelisted(address)`, never by
chain id** — a chain-id test would be wrong the moment we self-issue on mainnet
and right for the wrong reason on chain 97. If the probe says "no whitelist",
the wiring logs `[info] this BNBULL has no whitelist (four.meme's)` and moves
on. **That log line is a pass, not a warning.**

If instead you see `/!\ THIS BNBULL HAS A WHITELIST AND WE DO NOT OWN IT`, stop:
you are pointed at a token with a whitelist you cannot write, and the money
layer will wedge exactly as in §1.1.

### 1.3 VRF subscription funding is `maxGas × (callbackGasLimit + ~115k)`

The number that matters is **not** the callback gas limit. Chainlink bills the
subscription at the **lane's max gas price** against the callback limit **plus
its own verification overhead of roughly 115,000 gas**:

```
cost per request ≈ maxGasPrice × (callbackGasLimit + ~115_000)
mainnet lane     = 200 gwei
callbackGasLimit = 200_000     (set by Wire: setVrfConfig(keyHash, subId, 3, 200_000, true))
                 ⇒ 200 gwei × 315_000 ≈ 0.063 BNB reserved PER REQUEST
```

Fund for the number of rolls you expect between top-ups, not for one. An
underfunded subscription does not error — the request is simply never fulfilled.

Also set at wiring time, and both were once shipped as accidental defaults
(`DECISIONS.md §40`):

| Param | Value | Why |
|---|---|---|
| `requestTimeoutBlocks` | **24,000** | The contract default of 1,200 (~9 min) is **shorter than a measured real fulfilment of 3,169 blocks / ~24 min** on chain 97. A keeper obeying 1,200 cancels a request that is about to be answered: the payment is spent and the word that arrives is discarded. |
| `publicRequestDelayBlocks` | **1,200** | Dead-keeper fallback: after this, anyone may request. |
| `requestConfirmations` | 3 | |
| `payWithNative` | `true` | Pots are funded in BNB, not LINK. |

**Add BOTH pots as consumers.** They are two separate consumer contracts; one is
not enough.

### 1.4 An unwired `Duel.Wire.Yards` is not "no yards", it is NO CHECK AT ALL

`Duel._requireInYards` **returns early on a zero slot**. So a deployment that
lands `Yards` and forgets the wire looks complete and gates nothing: every bull
is fightable by anyone holding a signature, including on the zero-stake path
that touches no allowance and still kills a bull on its `lossesToDie`-th loss.

Every other slot in the game fails toward "the money went somewhere else". This
one fails toward "there is no consent check". `Verify` asserts it is non-zero
**and has code**.

---

## 2. THE CONTRACTS AND THEIR CONSTRUCTOR ARGS

Deploy order is dependency order and is enforced by `DeployCore.deployAll`.
Everything is deployed **to the deployer** and handed over at the end (§9) —
`Wire` makes ~50 `onlyOwner` calls and a cold multisig would mean 50 multisig
transactions.

| # | Contract | Constructor args |
|---|---|---|
| 0 | **BNBull** *(mainnet: normally NOT deployed — four.meme's token already exists)* | `(initialOwner, initialHolder, supply)` — deployer, deployer, `BNBULL_SUPPLY`. Only deployed if `BNBULL_TOKEN` is blank **and** `DEPLOY_BNBULL=true` on chain 56. |
| 1 | **Bulls** (ERC-721) | `(initialOwner, masterSeed, namesCommitment)` — ⚠ both hashes are **immutable** and committed here, before anything is sold. |
| 2 | **MintDrop** | `DeployParams{initialOwner, bulls, bnbull, wbnb, treasury: MINT_TREASURY, lpTreasury: LP_TREASURY}` — ⚠ reverts on a zero `lpTreasury`; repointed at `MintBnbullSplitter` during wiring (see §3.2). |
| 3 | **Duel** | `DeployParams{initialOwner, bulls, bnbull, wbnb, trustedSigner, devTreasury, defaultDevShareBps: 1000}` — EIP-712 domain `"BNBullsDuel"` / version `"1"` is a baked-in constant and must be right **before** the first deploy (`DECISIONS.md §13`). |
| 3b | **Yards** | `(initialOwner, bullsAddress)` |
| 4 | **Graveyard** | `(initialOwner, bulls, bnbull, resurrectTreasury)` |
| 5 | **Jackpot ×2** | `(prizeToken, _owner, vrfCoordinator, oddsOneIn)`<br>BNBULL pot: `(bnbull, 0, coordinator, 50)`<br>BNB pot: `(wbnb, 0, coordinator, 100)`<br>⚠ `_owner = 0` **on purpose** — see §9.2. |
| 6 | **Marketplace** | `(bulls, feeTreasury, feeBps: 750, initialOwner)` |
| 7 | **MintBnbullSplitter** | `(initialOwner, wbnb, keeper)` — policy 20/10/70, retains the dev share |
| 7 | **ReviveBuySplitter** | `(initialOwner, wbnb, keeper)` — 100% to pots, 2:1 BNBULL:BNB |
| 7 | **MarketPotSplitter** | `(initialOwner, wbnb, keeper)` — a **second `ReviveBuySplitter`**, repolicied to 100% BNBULL / 0% BNB (`DECISIONS.md §21`) |

**`address(this)` is mixed into each pot's roll.** That is what keeps two pots
with identical parameters from rolling identically — 600 duels on Stable gave 7
payouts on one pot and 0 on the other before that line existed.

---

## 3. WIRING — WHAT IS TIMELOCKED, WHAT IS INSTANT, WHAT IS FOREVER

### 3.1 The three classes

**(a) TIMELOCKED SLOTS — `bootstrap` once (instant, only while zero), then
`propose` → wait `wiringDelay` → `commit`.**

`wiringDelay` defaults to **24 hours**, floor `MIN_WIRING_DELAY` = **6 hours**,
ceiling 30 days. `setWiringDelay` is itself a **plain, instant** setter.

| Contract | Slots |
|---|---|
| `Bulls.Wire` | `MintDrop`, `Duel`, `Graveyard` |
| `Duel.Wire` | `Graveyard`, `JackpotBnbull`, `JackpotBnb`, `MintDrop` *(oracle)*, **`Yards`** *(index 4)* |
| `Graveyard.Wire` | `Duel`, `MintDrop`, `PriceFeed` |
| `MintDrop.Wire` | `PriceFeed`, `Router`, `JackpotBnbull`, `JackpotBnb`, `SwapIntermediate` *(deliberately left UNWIRED)* |
| `Marketplace.Wire` | `PriceFeed`, `Bnbull`, `JackpotSink` |
| `PotSplitter._wires` | the three splitters' own slots |
| `Jackpot` | `duel` (`bootstrapDuel`), `trustedCoordinator` (`proposeCoordinator`/`commitCoordinator`), payout params (§3.3) |

> ⚠ **`propose` stamps `eta = block.timestamp + wiringDelay` AT PROPOSE TIME.**
> To move faster you must lower `wiringDelay` **before** proposing. Lowering it
> afterwards changes nothing.

**(b) PLAIN SETTERS — instant, any time, no notice.** Deliberately not
timelocked because they sit on a hot path and a dependency that starts reverting
must be removable in one transaction:

`Duel.setMarketplace`, `Duel.setAuthorizedRouter`, `Duel.setUsdFightPrice`,
`Duel.setWiringDelay`, `MintDrop.setKeeper` / `setInlineSlippageBps` /
`setMinPoolLiquidity` / `setLpTreasury`, `Marketplace.setKeeper` /
`setBlocksDeadListings` / `setBnbullUsd` / `setFee` / `setJackpotFeeBps`,
`Jackpot.setFunder` / `setRequester` / `setVrfConfig` / `setTimeouts`,
`Yards.setEjectDelay` / `setSocials`.

**(c) ONE-SHOT / PERMANENT — no undo, ever:**

| Call | What is permanent |
|---|---|
| `Duel.addFightAsset(asset, maxCost, ...)` | **one-shot per asset**, and `maxCost` is a ceiling that can never be raised. A fat-fingered value is a **redeploy**. |
| `Bulls` `masterSeed`, `namesCommitment` | immutable, constructor |
| `Jackpot.bootstrapPayoutParams` | the single free payout write (§3.3) |
| `freezeNames` | one-way |

### 3.2 The wiring order (`WireCore.wireAll`)

Run it exactly in this order — it is the order in the script:

```
1.  Bulls        -> MintDrop, Duel, Graveyard          [bootstrap]
                    setBaseURI
2.  MintDrop     -> PriceFeed, Router(v2),
                    JackpotBnbull, JackpotBnb           [bootstrap]
                    SwapIntermediate LEFT UNWIRED       (DECISIONS §28/§30)
                    setKeeper
                    setInlineSlippageBps  = 1500        ⚠ §1.5 below
                    setMinPoolLiquidity   = 1 ether     (mainnet)
                    setLpTreasury -> MintBnbullSplitter
                    the $10 -> $75 price ladder
3.  Duel         -> Graveyard, JackpotBnbull, JackpotBnb,
                    MintDrop (ORACLE, not a money route),
                    Yards (THE consent gate)            [bootstrap]
                    addFightAsset WBNB    ⚠ ONE-SHOT, permanent ceiling
                    addFightAsset BNBULL  ⚠ ONE-SHOT, permanent ceiling
                    setUsdFightPrice ($2.50, 1e18)
                    setMarketplace        (listing lockout)
4.  Graveyard    -> Duel, MintDrop, PriceFeed           [bootstrap]
5.  Jackpot ×2   bootstrapDuel
                 bootstrapPayoutParams                  ⛔ §3.3
                 setFunder: MintDrop, Duel, and ALL THREE splitters
                 setRequester: keeper
                 setVrfConfig(keyHash, subId, 3, 200_000, true)
                 setTimeouts(24_000, 1_200)
6.  Marketplace  -> PriceFeed, Bnbull                   [bootstrap]
                    setKeeper, setBlocksDeadListings(true), setBnbullUsd
                    setFee(750) FIRST, then setJackpotFeeBps(250)
                    JackpotSink -> MarketPotSplitter
7.  Splitters ×3 (mint, revive, market) + market splitter policy
8.  wireTokenWhitelist                                  §1.1 / §1.2
```

**Order note on the Marketplace fee:** `setJackpotFeeBps` is bounded by the live
`feeBps`, and `setFee` refuses a fee below the live jackpot leg. Set `feeBps`
first.

**Every funder role is a silent deferral if missed.** A pot that does not
recognise a caller as a funder does not revert — it just never receives.

### 3.3 ⛔ SPEND THE FREE PAYOUT WRITE ON DEPLOY DAY

`oddsOneIn` / `payoutBps` / `minPoolToFire` decide **who wins and how much they
take**. They are money slots: once `payoutParamsBootstrapped` is set, every later
change is propose → wait → commit, in public, with an ETA.

Launch values (these merely re-assert the constructor + contract defaults, so
they change no behaviour — the point is to **close the door behind them**):

| Pot | `oddsOneIn` | `payoutBps` | `minPoolToFire` |
|---|---|---|---|
| BNBULL | 50 | 10,000 (100% of pot) | 0 |
| BNB | 100 | 10,000 | 0 |

**Leaving that free write unspent on a live pot leaves a one-shot, no-notice
change to the payout terms sitting available to whoever holds the owner key** —
which is the entire thing the timelock exists to remove. `Verify` asserts it
happened.

### 3.4 Launch numbers (`.env`, mainnet values)

```
MARKETPLACE_FEE_BPS=750           MARKETPLACE_JACKPOT_FEE_BPS=250
DUEL_DEFAULT_DEV_BPS=1000
FIGHT_MAX_COST_WBNB=1e18          ⚠ permanent
FIGHT_MAX_COST_BNBULL=1e24        ⚠ permanent
FIGHT_COST_USD=2.5e18             (the BNB stake is a DOLLAR figure)
FIGHT_COST_BNBULL=200e18
MIN_POOL_LIQUIDITY_WBNB=1 ether   ⚠ MAINNET. Testnet uses 0.005 — a decoy pool
                                     held 0.01 WBNB, so 0.005 is NOT mainnet-safe.
                                     four.meme graduation opens at 17.64 WBNB.
MINT_INLINE_SLIPPAGE_BPS=1500     ⚠ 500 (the old default) CANNOT clear a
                                     four.meme template-B 10% tax; every inline
                                     BNBULL buy deferred FOREVER (§37/§40).
GRAVEYARD_BNBULL_PER_USD=100e18   MARKETPLACE_BNBULL_USD=0.01e18
```

---

## 4. LAUNCH-DAY ORDER OF OPERATIONS

```bash
# ── 0. guards ────────────────────────────────────────────────────────────
cp -r ~/.foundry/keystores ~/keystores.backup.$(date +%s)   # rule 2
export CONFIRM_MAINNET=true USE_KEYSTORE=true KEYSTORE_SNAPSHOT_TAKEN=true
export EXPECT_CHAIN_ID=56
forge test                                                   # 760 green

# ── 1. names, committed before anything is sold ──────────────────────────
node scripts/gen-names.mjs

# ── 2. DRY RUN. Simulates deploy + wire + verify. Spends nothing. ────────
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL \
  --account bnbulls-owner --password-file <path>

# ── 3. deploy ────────────────────────────────────────────────────────────
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --slow \
  --account bnbulls-owner --password-file <path>
node scripts/record-deploy.mjs 56 --script Deploy.s.sol   # exact deploy blocks

# ── 4. wire ──────────────────────────────────────────────────────────────
forge script script/Wire.s.sol:Wire --rpc-url $RPC_URL --broadcast --slow \
  --account bnbulls-owner --password-file <path>

# ── 5. VRF — MANUAL, CANNOT BE SCRIPTED (§7) ─────────────────────────────
#    then re-run step 4; it resumes and lands setVrfConfig on both pots.

# ── 6. names ─────────────────────────────────────────────────────────────
forge script script/Names.s.sol:SetNames --rpc-url $RPC_URL --broadcast --slow \
  --account bnbulls-owner --password-file <path>

# ── 7. verify — must be fully green ──────────────────────────────────────
REQUIRE_NAMES=true forge script script/Verify.s.sol:Verify --rpc-url $RPC_URL

# ── 8. handover (§9) ─────────────────────────────────────────────────────
forge script script/OneWaySwitches.s.sol:Handover --rpc-url $RPC_URL --broadcast \
  --account bnbulls-owner --password-file <path>
#    then, FROM THE NEW OWNER'S KEY:
forge script script/OneWaySwitches.s.sol:AcceptJackpotOwnership \
  --rpc-url $RPC_URL --broadcast --account <new-owner>
```

`--slow` is **not optional**. Without it a ~100-transaction script can outrun the
node's mempool ordering and one transaction in the middle quietly ends up
without a receipt — indistinguishable from a wiring call that never happened.

**The run is resumable** and keyed on `code.length` at the address, never on the
record's say-so: a run that dies mid-broadcast leaves a record written during
*simulation* describing contracts that were never delivered.

---

## 5. ⚠ THE YARDS ARE EMPTY WHEN YOU FINISH

The default is **OUT**, for every bull, including freshly minted ones. After a
correct, fully-verified deploy **nobody can be fought**: `submitDuel` reverts
`BullNotInYards` until each holder calls `Yards.enter([...])` **from the wallet
that actually holds the bull**.

That is the design (`Yards.sol`, "THE DEFAULT IS OUT"), not a gap. It is called
out here because the symptom is a duel that refuses to settle with everything
else reading green.

There is **no operator path** — no `enterFor`, no approval override. A roster
swap can never be completed by the deployer alone.
`script/testnet/RetuneYards.s.sol:EnterMyBulls` is the per-wallet helper.

---

## 6. REPLACING A LIVE `Yards` (the 24-hour trap, learned the hard way)

`Yards.MIN_EJECT_DELAY` is a **`constant`** — it is bytecode, not config.
`setEjectDelay` is bounded *below* by it. So retuning the eject delay below the
current floor is **a redeploy plus a rewire**, and the rewire is timelocked.

**The route that does NOT work:** deploying a fresh `Duel` to get a free
`bootstrap` of its Yards slot. `Bulls.Wire.Duel` and `Graveyard.Wire.Duel` are
timelocked too and already set, so the new `Duel` then needs **two more 24-hour
timelocks** before it can kill or revive anything. Strictly worse, and it resets
`fightSeq` under a signer that is mid-session.

**The route that works:**

1. `setWiringDelay(6 hours)` — **before** proposing; `propose` stamps the ETA at
   propose time. *(Mainnet: consider leaving this at 24h. The delay is the window
   in which holders can see a proposed rewire and react to it.)*
2. `proposeWire(Wire.Yards, newYards)` → note the ETA.
3. Re-enter bulls into the new roster **per wallet** (§5).
4. After the ETA: `commitWire(4)`  ← `Wire.Yards` is index **4**.

**Who reads which address — this asymmetry is the whole hazard:**

| Reader | Resolves the roster from |
|---|---|
| `Duel._requireInYards` | `Duel.yardsContract()` |
| The off-chain signer (`api/run-duel`) | **`Duel.yardsContract()`** — deliberately, so the pre-check *cannot* disagree with the contract |
| The UI / pit page | **`NEXT_PUBLIC_YARDS`** |

So between `propose` and `commit`, the UI can drive the new contract while the
signer and `Duel` both still enforce the old one. A bull entered **only** in the
new yards will look in-pit in the UI and be **refused a fight** by the signer.
Mitigate by keeping the old roster permissive for the window, and understand
that **enforcement only moves when `commitWire` lands**.

---

## 7. VRF — THE MANUAL STEP, AND WHAT SKIPPING IT LOOKS LIKE

1. **vrf.chain.link** → BNB Chain (mainnet) → **Create Subscription**
2. **Fund it** — see §1.3 for the real per-request reserve
3. **Add consumers: BOTH Jackpot addresses.** One is not enough.
4. Put the id in `VRF_SUBSCRIPTION_ID`, the 200-gwei lane hash in
   `VRF_KEY_HASH_200GWEI`
5. Re-run `Wire` — it resumes and lands `setVrfConfig` on both pots

**What skipping it looks like: nothing.** Duels settle normally. `recordWin`
opens a ticket on both pots on every decisive duel, normally. `requestResolve`
reverts `VrfNotConfigured`, so **no ticket can ever be decided** and the queue
grows forever. `Duel` wraps its roll in try/catch, so no fight is ever affected.
The pot fills and never pays, with no error anywhere. `Verify` failing on
`keyHash is set` / `subscriptionId is set` is the **only** thing that will tell
you.

`setVrfConfig` **refuses a zero on either field** — both or neither.

A later coordinator migration is **both halves**, or words from the new
coordinator are refused with `UntrustedCoordinator`:

```
p.proposeCoordinator(new) -> wait wiringDelay -> p.commitCoordinator()
p.setCoordinator(new)     (VRFConsumerBaseV2Plus, no timelock)
```

Doing only `setCoordinator` is precisely the hand-pick-a-winner attack the
timelock exists to stop.

---

## 8. EXPECTED "FAILURES" THAT ARE CORRECT AT LAUNCH

Until BNBULL's four.meme bonding curve fills there is **no PancakeSwap pair at
all** (`DECISIONS.md §22`/`§29`). Therefore:

- every BNBULL **swap** leg defers and **accrues** — `pendingBnbullBuyNative`,
  `potFeeUndelivered`. The bucket is the receipt for money still owed to the pot.
- the **mint never reverts** — a discretionary buyback may never take a sale
  down with it;
- the **BNB slice still lands** — that leg is a 1:1 *wrap*, not a swap.

That third point is the discriminator. Without it, "everything deferred" reads
as "no liquidity yet" when it might actually be a missing funder role.

**Do not seed a fake pool to make it go away.** Once the curve fills, the keeper
spends the backlog with `sweepBnbullPot` / `sweepPotFee` against an off-chain
quoted floor.

Run `Verify` with `ALLOW_DEFERRALS=true` while this is the expected state.

---

## 9. HANDOVER — LAST, AND IT IS TWO DIFFERENT MECHANISMS

### 9.1 The eight `Ownable` contracts
`Handover` transfers: `Bulls`, `MintDrop`, `Duel`, **`Yards`**, `Graveyard`,
`Marketplace`, and all three splitters.

> `Yards` is easy to forget and expensive to forget: **its owner is who sets
> `ejectDelay`**, i.e. who decides how long a holder waits to get a bull out of
> the arena. Left behind, it stays on the deployer key while `Verify`'s
> `EXPECT_OWNER` gate reads as though the handover landed.

### 9.2 The two pots are **`ConfirmedOwner`, which is TWO-STEP**
`transferOwnership` only **proposes**. The intended owner must call
`acceptOwnership()` **from its own key**. This is why the pots are deployed with
`_owner = 0` (keeping `msg.sender`) rather than straight to the multisig:
passing the real owner in the constructor would leave them owned by the
**deployer** while a block explorer reads as though the handover worked.

```bash
forge script script/OneWaySwitches.s.sol:AcceptJackpotOwnership \
  --rpc-url $RPC_URL --broadcast     # FROM THE NEW OWNER'S KEY
```

Then re-run `Verify` to prove all ten landed.

---

## 10. AFTER THE DEPLOY

- [ ] `deployments/56.json` committed, `deployBlock` **never 0** (every keeper
      and indexer cursor starts there; a 0 forces a full-chain rescan on every
      restart)
- [ ] `frontend/.env.local` / production env updated — **including
      `NEXT_PUBLIC_YARDS`**
- [ ] Contracts verified on bscscan (etherscan v2: one key, `chainid=56`)
- [ ] Keeper pointed at mainnet, `DRY_RUN` off
- [ ] Signer key (`BNBULLS_SIGNER_KEY_56`) live on the web server and **a
      different wallet from the owner** — it signs fight results and must never
      be able to move funds
- [ ] `MAX_DUEL_EXPIRY_SECONDS` (300) ≥ nothing else changed it, and
      `Yards.MIN_EJECT_DELAY` (300) ≥ it. `forge test` reads the TypeScript and
      enforces this across the repo boundary — see §11.
- [ ] The whitelist question answered honestly: no-op (four.meme) or fully
      written (self-issued). Never "probably fine".

---

## 11. THE ONE INVARIANT THAT SPANS BOTH REPOSITORIES

```
Yards.MIN_EJECT_DELAY  >=  MAX_DUEL_EXPIRY_SECONDS
   (contracts/Yards.sol)      (frontend/src/lib/serverEnv.ts)
        300                            300
```

An eject that bit **sooner** than a signature can expire would let a player
cancel a fight they can already see themselves losing in the public mempool —
an undefeatable-bull button. Two numbers, two languages, two repositories, no
compiler between them.

`test/DuelYards.t.sol::test_theEjectFloorMatchesTheSignersSignatureCeiling`
**reads `serverEnv.ts` from Solidity** and fails if they drift, so `forge test`
catches a change made entirely inside the frontend.

⚠ **Raising `MAX_DUEL_EXPIRY_SECONDS` is not a config change.**
`MIN_EJECT_DELAY` is a `constant`: raising the floor means redeploying **and
rewiring** `Yards`, and that rewire is timelocked (§6). **Raise the floor and
get it live FIRST, then raise the TTL.**
