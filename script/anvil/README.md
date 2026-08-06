# local chain — mint, fight and revive before anything touches BSC

One command:

```bash
npm install            # once; only ethers, and only the art build needs it
node scripts/anvil-up.mjs
```

That starts anvil, deploys the mocks and all nine contracts, wires everything,
**verifies every silent-failure leg**, seeds real game state, prints the
`NEXT_PUBLIC_*` block for `frontend/.env.local`, and leaves the chain running.
Ctrl-C stops it.

```
--no-seed    deploy and wire, leave the chain empty
--no-wait    tear anvil down when the run finishes (CI)
--port <n>   default 8545
--reuse      do not start anvil; use whatever is already on the port
```

---

## the commands it runs, if you would rather drive them yourself

```bash
# 0. deal the 501 names (writes deployments/names.json + rarity.json)
node scripts/gen-names.mjs

# 0b. optional but worth doing once: print the commitment and PROVE that the
#     off-chain rarity port matches the real Bulls constructor
forge script script/Names.s.sol:PrintNamesCommitment

# 1. the chain
anvil --port 8545 --chain-id 31337

# 2. mocks + deploy + wire + verify, all in one, in a second terminal
export PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/anvil/DeployLocal.s.sol:DeployLocal \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --private-key $PK

# 3. game state: mint, fight, kill, revive, jackpot, listing
forge script script/anvil/Seed.s.sol:Seed \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --private-key $PK

# 4. re-verify at any time (read-only, no keys needed)
forge script script/Verify.s.sol:Verify --rpc-url http://127.0.0.1:8545
```

`--slow` is not optional. Without it a ~100-transaction script can outrun a
local node's mempool ordering and one transaction in the middle quietly ends up
without a receipt — which looks exactly like a wiring call that never happened.

---

## what you get

Addresses land in `.state/anvil/deployment.json`, and the paste-ready env block
in `.state/anvil/frontend.env.local`. Both paths are already gitignored.

**Nothing here ever writes `frontend/.env.local` or any real env file, and that
is deliberate.** On 2026-07-30 fighting fefers lost **154 USDT permanently**
because a fork rehearsal wrote its throwaway addresses into the *mainnet* env
file, they survived into the real deploy, and the keystore was then deleted
(`DEPLOY-SAFETY-PREFLIGHT.md §1`). A rehearsal that cannot reach real config
cannot poison it. Copy the block by hand.

### seeded state

| | |
|---|---|
| bulls #1–#3 | anvil account 0 (`0xf39F…2266`) — minted with BNB and with BNBULL |
| bull #4 | anvil account 1 (`0x7099…79C8`) — the opponent |
| three duels | #1 loses all three and **dies** on the third (`lossesToDie = 3`) |
| a revive | #1 brought back on the owner ladder's first rung ($50) |
| both pots | funded, one VRF round trip requested → fulfilled → resolved |
| a listing | bull #2 at $250 with the BNBULL leg pegged |

Account 0 is the owner, the keeper AND the duel signer, so you can drive
everything from one wallet in MetaMask.

### the local outside world

| mock | what it is for |
|---|---|
| `LocalWBNB` | `deposit()` is 1:1. The BNB pot leg is a **wrap, not a swap** |
| `LocalStable` | 18dp by default. `LOCAL_STABLE_DECIMALS=6` rehearses the other world |
| `LocalAggregator` | BNB/USD at $600. `setAnswer(700e8)` moves it |
| `LocalRouter` | v2 **and** v3 dialects over real `x*y=k` reserves with a 0.25% fee |
| `LocalVRFCoordinator` | `fulfillPending(word)` delivers a word you choose |

The router genuinely moves price. A flat fixed-rate mock would let a `minOut`
bug through, because slippage would always be zero; here a fat buy really does
get a worse fill, and a `setFloors` value that is too optimistic really does
make the swap miss `amountOutMinimum` and defer.

**These mocks can never reach mainnet.** `script/Deploy.s.sol` imports nothing
from `mocks/`, so a chain-56 run does not have the bytecode in scope at all, and
`DeployLocal` refuses to run on any chain id but 31337. That is the hole stable
warriors fell through: a deploy script with a silent mock fallback baked a
`MockUSDT` into `MintDrop`'s **immutable** storage forever.

---

## driving it by hand

```bash
export R=http://127.0.0.1:8545
export PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
J=$(cat .state/anvil/deployment.json)
FEED=$(echo $J | jq -r .ext.priceFeed)
DROP=$(echo $J | jq -r .contracts.mintDrop)

# move BNB to $700 and re-quote a mint
cast send $FEED "setAnswer(int256)" 70000000000 --rpc-url $R --private-key $PK
cast call $DROP "quote(uint256)(uint256,uint256,uint256,uint256,uint256)" 1 --rpc-url $R

# drive the oracle into the failure modes MintDrop must REVERT on, not clamp
cast send $FEED "setAnswer(int256)" 0 --rpc-url $R --private-key $PK        # non-positive
cast send $FEED "setUpdatedAt(uint256)" 1 --rpc-url $R --private-key $PK    # stale

# fulfil a jackpot request with a word of your choosing
VRF=$(echo $J | jq -r .ext.vrfCoordinator)
cast send $VRF "fulfillPending(uint256)" 42 --rpc-url $R --private-key $PK
```

---

## when something is wrong

`Verify` prints every failure at once and then reverts. Read the whole list —
they are the legs that fail **silently** in production:

- `setFunder(...)` missing → `Jackpot.fund` reverts `NotFunder`, the splitter's
  `try/catch` swallows it, and every buyback defers into a `pending*` bucket.
  Forever. No error anywhere.
- `bootstrapDuel` missing → `recordWin` reverts `NotDuel`, the Duel's roll is
  wrapped, and **no ticket is ever opened**. A jackpot that never pays.
- `setVrfConfig` missing → tickets open, `requestResolve` reverts
  `VrfNotConfigured`, nothing can be decided. Fights are unaffected.
- `setFloors` missing → `floorsFresh()` is false, the pre-check on every swap
  leg fails, and every slice defers. Nothing reverts. Nothing warns.
- `addFightAsset(WBNB)` missing → the native fight path does not exist and
  every WBNB stake reverts `UnsupportedAsset`.

A pool of 0 with tickets open in the seed output means a buyback deferred. Grep
the run for `PotDeferred` / `PotSliceFailed`.

---

## after anvil: the chain-97 rehearsal

anvil proves the wiring. It cannot prove the *outside world*, because
everything outside is a mock. BSC testnet is the next rung — real PancakeSwap
routers, the real Chainlink feed, the real VRF coordinator:

```bash
EXPECT_CHAIN_ID=97 forge script script/testnet/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $RPC_URL_TESTNET --broadcast --slow --private-key $PRIVATE_KEY
```

See the `_TESTNET` block in `.env.example` for how each of those addresses was
proven on chain. Every BNBULL swap leg will defer there, and that is the single
most valuable thing it proves — it is an exact rehearsal of launch day, when
BNBULL is still on four.meme's bonding curve and no PancakeSwap pair exists.
