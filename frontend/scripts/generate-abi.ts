// Regenerates `src/lib/abi/*.ts` straight from the forge build artefacts in
// `../out/` (repo root). Per the frontend package brief: "Generate ABIs from
// `forge build` artefacts in `out/` — do not hand-write them." Run this again
// any time a contract's public interface changes, then re-run `npm run build`
// to catch any call site the new ABI no longer matches.
//
// Run with: `npm run gen:abi` (from frontend/), or `node
// scripts/generate-abi.ts` directly. Requires Node 22.7+ for native
// TypeScript execution — same convention as `verify-art-port.ts`.
//
// Only the `abi` field is kept. `bytecode` / `deployedBytecode` / metadata are
// deploy-time concerns that belong to `contracts/` and `script/`, not to a
// frontend that never deploys anything (this package must not touch either).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');
const outDir = path.join(repoRoot, 'out');
const abiDir = path.join(__dirname, '../src/lib/abi');

interface Target {
  /** Exported const name, e.g. `MintDropAbi`. */
  exportName: string;
  /** Output file, under `src/lib/abi/`. */
  file: string;
  /** Path to the forge artifact, relative to `out/`. */
  artifact: string;
}

// One entry per contract the frontend actually calls. `BNBull` is
// DELIBERATELY represented by the generic `IERC20Metadata` artifact, not
// `BNBull.sol` — `DECISIONS.md §4` picks four.meme as the launch venue, so the
// deployed token is very likely NOT this repo's `BNBull.sol` contract at all.
// Coding the frontend against the fallback contract's bespoke surface
// (`whitelisted`, `blacklisted`, ...) would silently break the moment a
// four.meme token is wired in. The standard ERC-20 surface is the only
// contract every possible token shares.
const TARGETS: Target[] = [
  { exportName: 'MintDropAbi', file: 'MintDrop.ts', artifact: 'MintDrop.sol/MintDrop.json' },
  { exportName: 'BullsAbi', file: 'Bulls.ts', artifact: 'Bulls.sol/Bulls.json' },
  { exportName: 'DuelAbi', file: 'Duel.ts', artifact: 'Duel.sol/Duel.json' },
  // The native-BNB replacement for `Duel`. Same fight surface, but the passive
  // side is charged from a custodied `bnbCredit` balance instead of a WBNB
  // allowance, and payouts accrue to that balance instead of transferring a
  // token. BOTH ABIs ship: the live contract is still the WBNB one, and the
  // frontend picks between them off `NATIVE_DUEL` so one build serves the
  // cutover in either direction. Drop `Duel.ts` once the migration is done and
  // no deployment references the old contract.
  { exportName: 'DuelNativeAbi', file: 'DuelNative.ts', artifact: 'DuelNative.sol/DuelNative.json' },
  { exportName: 'GraveyardAbi', file: 'Graveyard.ts', artifact: 'Graveyard.sol/Graveyard.json' },
  { exportName: 'JackpotAbi', file: 'Jackpot.ts', artifact: 'Jackpot.sol/Jackpot.json' },
  // The native-BNB pot, replacing ONLY the BNB jackpot. The $BNBULL pot stays
  // on `Jackpot.sol` forever — $BNBULL genuinely IS an ERC-20, so there is
  // nothing to make native there.
  //
  // ⚠ ITS SURFACE DIFFERS IN TWO WAYS THAT BREAK CALL SITES, NOT JUST ONE:
  //   `prizeToken()` is GONE — the prize is native, and a view claiming
  //     otherwise is the "print a misleading value" bug this repo keeps
  //     catching. Anything reading it must branch on the pot, not fall back.
  //   `topUp(uint256)` became payable `topUp()` — the amount is `msg.value`.
  // It also adds `owed(address)` / `withdraw` / `withdrawAll`: a win CREDITS
  // the winner rather than transferring, so the prize is claimed, not received.
  {
    exportName: 'JackpotNativeAbi',
    file: 'JackpotNative.ts',
    artifact: 'JackpotNative.sol/JackpotNative.json',
  },
  {
    exportName: 'MarketplaceAbi',
    file: 'Marketplace.ts',
    artifact: 'Marketplace.sol/Marketplace.json',
  },
  // The arena roster. `Duel.submitDuel` reverts `BullNotInYards` for a bull
  // whose live owner has not entered it, so the UI has to be able to READ
  // membership and WRITE both `enter` and `eject` or a player's bulls are
  // silently unfightable. ⚠ The contract is `Yards` and stays `Yards` — the
  // player-facing name for it is `PIT` in `lib/brand.ts`, and the two are
  // deliberately allowed to differ (same as `/graveyard` being "the butcher").
  { exportName: 'YardsAbi', file: 'Yards.ts', artifact: 'Yards.sol/Yards.json' },
  // The pen that holds the unsold bulls and deals them at random. The frontend
  // needs the WHOLE surface, not just the views: `armFallback`,
  // `pinFallbackSeed` and `settle` are PERMISSIONLESS, so the buyer's own
  // browser is the thing that unsticks a reservation VRF abandoned. A read-only
  // ABI here would leave a paid-for bull undeliverable with nobody to press the
  // button. ⚠ Regenerating this also refreshes `MintDrop.ts`, which is where
  // `penContract` / `penWire` / `BullsReserved` come from — the pen is useless
  // to the UI without them, because `BullsReserved` is the ONLY thing a
  // pen-wired mint receipt carries (no `BullMinted` fires in the buyer's tx).
  { exportName: 'BullPenAbi', file: 'BullPen.ts', artifact: 'BullPen.sol/BullPen.json' },
  {
    exportName: 'Erc20Abi',
    file: 'Erc20.ts',
    artifact: 'IERC20Metadata.sol/IERC20Metadata.json',
  },
];

interface AbiItem {
  type: string;
  name?: string;
  [key: string]: unknown;
}

mkdirSync(abiDir, { recursive: true });

const indexLines: string[] = [
  '// GENERATED FILE — see `scripts/generate-abi.ts`. Do not hand-edit.',
  '// Re-run `npm run gen:abi` after any contract interface change.',
  '',
];

let written = 0;
for (const t of TARGETS) {
  const artifactPath = path.join(outDir, t.artifact);
  const raw = readFileSync(artifactPath, 'utf8');
  const parsed = JSON.parse(raw) as { abi: AbiItem[] };
  const abi = parsed.abi;
  if (!Array.isArray(abi) || abi.length === 0) {
    throw new Error(`${t.artifact}: empty or missing "abi" field`);
  }

  const header = [
    '// GENERATED FILE — see `scripts/generate-abi.ts`. Do not hand-edit.',
    `// Source: out/${t.artifact} ("abi" field only — bytecode is a deploy-time`,
    '// concern that belongs to contracts/ and script/, not the frontend).',
    '// Re-run `npm run gen:abi` after any contract interface change.',
    '',
  ].join('\n');

  const body = `export const ${t.exportName} = ${JSON.stringify(abi, null, 2)} as const;\n`;
  writeFileSync(path.join(abiDir, t.file), header + body);
  indexLines.push(`export { ${t.exportName} } from './${t.file.replace(/\.ts$/, '')}';`);
  written++;
  console.log(`wrote src/lib/abi/${t.file} (${abi.length} abi entries)`);
}

writeFileSync(path.join(abiDir, 'index.ts'), indexLines.join('\n') + '\n');
console.log(`\n${written} ABI file(s) generated from out/.`);
