// the tier map is the CHAIN's (DECISIONS.md 27) - `assignBands()` was a
// different shuffle and is deleted. names are dealt against this map, so this
// listing is the same one `scripts/gen-names.mjs` writes to deployments/.
import { chainBandMap, assignNames, BANDS, KING_ID, KING_NAME } from "./bull.mjs";
const bandMap = chainBandMap();
const names = assignNames(bandMap);
const byTier = {}; BANDS.forEach(t => byTier[t] = []);
for (let id = 1; id <= 500; id++) byTier[bandMap[id]].push({ id, name: names[id] });
let dupTotal = 0;
for (const tier of BANDS) {
  const all = byTier[tier].map(t => t.name);
  const uniq = new Set(all);
  dupTotal += all.length - uniq.size;
  console.log(`\n${tier.toUpperCase()}  ${all.length} tokens / ${uniq.size} unique`);
  console.log("  " + byTier[tier].slice(0, 6).map(t => `#${t.id} ${t.name}`).join("\n  "));
}
const everyName = Object.values(names);
console.log(`\nCOLLECTION: ${everyName.length} names, ${new Set(everyName).size} unique, ${dupTotal} within-tier dupes`);
console.log(`KING #${KING_ID}: ${KING_NAME}`);
