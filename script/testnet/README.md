# BSC testnet rehearsal — chain 97

anvil proves the wiring. It cannot prove the **outside world**, because
everything outside is a mock. This is the rung between anvil and mainnet: the
real PancakeSwap routers, the real Chainlink BNB/USD feed, the real Chainlink
VRF v2.5 coordinator.

Budget: a full deploy + wiring + names is **~0.005 BNB** at testnet's ~0.1 gwei.
Nothing here is optimised for gas at the cost of clarity.

---

## the command

```bash
export PATH="$PATH:$HOME/.foundry/bin"
export RPC_URL_TESTNET=https://bsc-testnet-rpc.publicnode.com
export PRIVATE_KEY=0x...            # the funded chain-97 dev key. TESTNET ONLY.
export EXPECT_CHAIN_ID=97

node scripts/gen-names.mjs          # once; writes deployments/names.json

forge script script/testnet/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $RPC_URL_TESTNET --broadcast --slow --private-key $PRIVATE_KEY
```

Then, in order:

```bash
# exact per-contract deploy blocks, read back off the receipts
node scripts/record-deploy.mjs 97 --script DeployTestnet.s.sol

# the 501 dealt names, in batches, resumable
forge script script/Names.s.sol:SetNames \
  --rpc-url $RPC_URL_TESTNET --broadcast --slow --private-key $PRIVATE_KEY

# the whole point: prove the pre-liquidity behaviour
forge script script/testnet/RehearsePreLiquidity.s.sol:RehearsePreLiquidity \
  --rpc-url $RPC_URL_TESTNET --broadcast --slow --private-key $PRIVATE_KEY

# re-verify. ALLOW_DEFERRALS because a non-zero bucket is CORRECT here.
ALLOW_DEFERRALS=true REQUIRE_NAMES=true \
  forge script script/Verify.s.sol:Verify --rpc-url $RPC_URL_TESTNET
```

Drop `--broadcast` on any of them for a free dry run against real chain state.
That is worth doing first: the deploy simulates the entire deploy + wire +
verify path and spends nothing.

`--slow` is not optional. Without it a ~100-transaction script can outrun the
node's mempool ordering and one transaction in the middle quietly ends up
without a receipt — indistinguishable from a wiring call that never happened.

**The run is resumable.** Every address lands in `deployments/97.json`, and a
re-run reuses anything that **has code on chain right now** — never on the
record's say-so, because a run that dies mid-broadcast leaves a record written
during simulation describing contracts that were never delivered.

---

## ⚠ THE MANUAL STEP: Chainlink VRF v2.5

**This cannot be scripted and the deploy cannot do it for you.** In order:

1. Go to **vrf.chain.link**, switch to **BNB Chain Testnet**.
2. **Create Subscription.** Note the id.
3. **Fund it** — testnet LINK from faucets.chain.link, or testnet BNB (the
   pots are configured `payWithNative = true`).
4. **Add consumers**: BOTH Jackpot addresses from `deployments/97.json`
   (`jackpotBnbull` AND `jackpotBnb`). One is not enough — they are two
   separate consumer contracts.
5. Put the id in `VRF_SUBSCRIPTION_ID_TESTNET` and **re-run the deploy** (it
   resumes) so `setVrfConfig` lands on both pots.

### what happens if you skip it

Nothing that looks like an error. That is the problem.

- Duels settle normally.
- `recordWin` opens a ticket on both pots on every decisive duel, normally.
- `requestResolve` reverts `VrfNotConfigured`, so **no ticket can ever be
  decided**. The queue grows forever.
- The `Duel` wraps its roll in try/catch, so no fight is ever affected.

The pot fills up and never pays, with no error anywhere. `Verify` fails on
`keyHash is set` / `subscriptionId is set` for exactly this reason — it is the
only thing that will tell you.

Mainnet is the same procedure with mainnet LINK and the 200-gwei lane.

---

## what is real and what is mocked

| | on chain 97 |
|---|---|
| WBNB | **real** `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |
| PancakeSwap v2 Router | **real** `0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3` |
| PancakeSwap v3 SmartRouter | **real** `0x9a489505a00cE272eAa5e07Dba6491314CaE3796` |
| Chainlink BNB/USD | **real** `0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526` |
| Chainlink VRF v2.5 | **real** `0xDA3b641D438362C440Ac5458c57e00a712b66700` |
| BNBULL | **deployed** — `BNBull.sol`, our own contract. four.meme is mainnet-only |
| the stablecoin | **mock, 6 decimals** — still an open owner decision |

Every one of those five was **proven on chain 97** before it went into
`.env.example`; the proof for each is written out there. WBNB in particular was
not looked up at all — it was *discovered* by calling `WETH()` on the v2 router,
and cross-checked against the v3 SmartRouter's `WETH9()`.

### the stablecoin mock is SIX decimals, on purpose

BSC-USDT is 18dp, unlike ethereum/tron USDT at 6dp, and `.env.example` leaves
both the address and the decimals blank because the choice is not made. Picking
**6** for the rehearsal means the deploy runs against the value that is *wrong*
for BSC — so anything that quietly assumed 18 fails on testnet instead of on
mainnet. The stake ceilings and fight prices are scaled off the mock's live
`decimals()` for the same reason: they are denominated in the coin's own units,
and an 18dp number against a 6dp coin would price a fight at ten billion
dollars.

---

## ⚠ EVERY BNBULL SWAP LEG WILL DEFER. THAT IS THE POINT.

There is no BNBULL/WBNB pool on testnet, so every buyback that needs a swap
fails and accrues.

**Do not seed a fake pool to make it go away.** It is an exact rehearsal of
launch day (`DECISIONS.md §22`): BNBULL launches on four.meme's bonding curve
and **there is no PancakeSwap pair at all** until that curve fills. The 20%
BNBULL leg of every payment cannot execute on day one, for real, on mainnet.

`RehearsePreLiquidity.s.sol` asserts the three things that must hold:

1. **the mint does not revert** — ever, not "usually". A discretionary buyback
   may never take a sale down with it;
2. **the BNBULL slice ACCRUES** into `pendingBnbullBuyNative` rather than
   vanishing — the bucket is the receipt for money still owed to the pot;
3. **the BNB slice STILL LANDS** — that leg is a 1:1 *wrap*, not a swap: no
   router, no pool, no floor to be stale.

Point 3 is the discriminator. Without it, "everything deferred" reads as "no
liquidity yet" when it might actually be a missing funder role. Once the curve
fills and a pair exists, the keeper spends the backlog with `sweepBnbullPot`
against an off-chain quoted floor.

The Marketplace's jackpot slice behaves the same way and accrues to
`potFeeUndelivered`, swept later with `sweepPotFee`.

---

## mainnet is NOT this command

Chain 56 refuses to broadcast without `CONFIRM_MAINNET=true`, refuses a
plaintext `PRIVATE_KEY` outright, and requires `USE_KEYSTORE=true` plus
`KEYSTORE_SNAPSHOT_TAKEN=true` (rule 2: copy `~/.foundry/keystores` somewhere
off the deploy box first — a fork rehearsal creates AND deletes wallets).

The records are separate files (`deployments/97.json` vs `deployments/56.json`)
and the env keys are separate names (`WBNB_TESTNET` vs `WBNB`), so a testnet
rehearsal cannot reach mainnet config. That separation is the whole fix for the
$154 loss in `DEPLOY-SAFETY-PREFLIGHT.md §1`.
