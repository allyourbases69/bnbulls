# bnbulls

Pixel bull PvP on BNB Chain. Mint a bull, back it against someone else's, and
the winner takes 90% of the money in the middle. Lose five on the trot and it is
sausages.

**Site:** https://bnbulls.xyz · **X:** [@WeAreBNBulls](https://x.com/WeAreBNBulls) · **Telegram:** [t.me/WeAreBNBulls](https://t.me/WeAreBNBulls)

500 bulls plus a 1-of-1 king, **Lord Wagyu** (token 501).

---

## What this repo is, and what it is not

This is the **verifiable half** of the project: the contracts, their tests, the
deploy and verification scripts, the art engine, and the frontend. Enough for
anyone to check that the chain does what the game claims.

It is **not** the whole product. The keeper fleet, the ops runbooks, the brand
pipeline and the internal design log are deliberately not here.

---

## The claims, and where to check each one

Do not take any of these on trust. Each is a file you can read.

### Neither pot has a withdraw function

Not for a player, not for the owner. The only way money has ever left either
pool is a logged, on-chain win.

- `contracts/Jackpot.sol` — there is no withdraw, and `test/JackpotNoWithdraw.t.sol` exists to keep it that way.
- `sweepForeignToken` explicitly **reverts** if asked for the prize token.

### The rarity table is fixed in the constructor and can never change

Not for anyone, including the dev. There is no dev rarity cap, because there is
no mechanism to move a rarity at all.

- `contracts/Bulls.sol` — `_initializeRarity()` runs once; `initialRarityHash` is captured immediately after.
- `rarityHash()` must **always** equal `initialRarityHash()`. Check it from a block explorer without reading a line of source.
- The shuffle is a Fisher-Yates over a SplitMix-seeded xorshift128+ from `masterSeed`, which is public. Re-derive it yourself: `cd frontend && npm run verify:rarity`.

### One fight rolls exactly one pot, never both

Every decisive duel opens a ticket on both pools at their own odds; whichever
rolls a win first claims exclusivity.

- `contracts/Duel.sol::_rollJackpot`, and `test/JackpotRollSeparation.t.sol`.

### A ticket is earned by funding the pot

A zero-stake duel settles, records the win and moves the loss streaks — and
opens no ticket. It cannot mint a claim on money other players put in.

- `contracts/Duel.sol::_rollOnePool`, and `test/DuelJackpot.t.sol`.

### The art you see is the bull the chain describes

The renderer is derived from the contract's own algorithms, and a gate proves
it token by token.

- `generator/bull.mjs` ⇄ `frontend/src/lib/art/bull.ts` are byte-identical, enforced by `npm run verify:art`.
- `npm run verify:rarity` checks all 501 tokens' tier, weapon and name against hashes pinned from a real deployment.

### The combat maths is unchanged from the game it forked

- `npm run verify:combat` proves no combat number differs from the original source.

---

## Running it

```bash
git clone https://github.com/allyourbases69/bnbulls.git
cd bnbulls
git submodule update --init   # restores lib/ (forge-std, OpenZeppelin, chainlink)
forge build
forge test                    # 686 tests

cd frontend
npm install
npm run verify                # art + rarity + combat + typed-data
npm run dev
```

⚠ `--init`, **not** `--init --recursive`. OpenZeppelin carries its own test-only
submodules (`forge-std` → `dapphub/ds-test`) which fail to clone and abort the
whole checkout. This repo needs OZ's `contracts/` source, never its test rig.

⚠ **On Windows**, chainlink-brownie-contracts vendors some very deep paths and
will fail with `Filename too long` unless long paths are enabled, and it is
worth cloning somewhere short:

```bash
git config --global core.longpaths true
```

Mainnet-fork tests are **excluded from the default run** — `no_match_path` in
`foundry.toml` — so a plain `forge test` is green while 61 tests never execute.
Run them explicitly; they need an **archive** RPC (the public endpoints return
403 on a pinned fork):

```bash
BSC_FORK_RPC_URL=<archive-rpc> FOUNDRY_PROFILE=fork forge test -j 1   # 61 tests
```

---

## Layout

| path | what |
|---|---|
| `contracts/` | the nine deployed contracts, plus `lib/` helpers |
| `contracts/testnet/` | ⚠ test-only mocks. They **revert on chain 56** by construction |
| `test/` | 631 tests, mocks-only |
| `test/fork/` | BSC mainnet-fork tests against real Chainlink, PancakeSwap and four.meme |
| `script/` | deploy, wire, verify. `Verify.s.sol` is a 252-check preflight |
| `generator/` | the deterministic art engine |
| `frontend/` | Next.js app, and the byte-identical TS port of the engine |

---

## Notes

- **Nothing is deployed to BNB Chain mainnet.** No contract address exists yet, and there is no token. Anything claiming otherwise is not us.
- BNBULL launches fair on four.meme with no presale. When an address exists it goes on the site first.
- Nobody from this project will DM you first or ask for your seed phrase.

## Licence

All rights reserved. Published for verification, not for reuse.
