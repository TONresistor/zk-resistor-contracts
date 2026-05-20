#!/usr/bin/env node
// Verifies R1CS constraint counts stay within tolerance of the pinned
// baseline. A regression here means someone changed a circuit without
// updating the baseline; review carefully before merging.

import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const baseline = pkg.config.constraint_baseline;
const TOLERANCE = 0.05; // ±5%

const TARGETS = ["insert", "withdraw", "hasher"];
let failed = false;

for (const name of TARGETS) {
  const r1csPath = join(root, "build", `${name}.r1cs`);
  let info;
  try {
    info = execSync(`npx --no-install snarkjs r1cs info "${r1csPath}"`, {
      cwd: root,
      stdio: ["pipe", "pipe", "pipe"],
    }).toString();
  } catch (e) {
    console.error(`  ✗ ${name}: cannot read ${r1csPath}, run \`npm run compile\` first`);
    failed = true;
    continue;
  }
  const m = info.match(/# of Constraints:\s*(\d+)/);
  if (!m) {
    console.error(`  ✗ ${name}: could not parse constraint count from snarkjs output`);
    failed = true;
    continue;
  }
  const actual = parseInt(m[1], 10);
  const expected = baseline[name];
  const lo = Math.floor(expected * (1 - TOLERANCE));
  const hi = Math.ceil(expected * (1 + TOLERANCE));
  if (actual < lo || actual > hi) {
    console.error(
      `  ✗ ${name}: ${actual} constraints, baseline ${expected} (tolerance ±${(TOLERANCE * 100).toFixed(0)}% = [${lo}, ${hi}])`,
    );
    failed = true;
  } else {
    console.log(`  ✓ ${name}: ${actual} constraints (baseline ${expected})`);
  }
}

if (failed) {
  console.error(
    "\nIf the change is intentional, update `config.constraint_baseline` in circuits/package.json.",
  );
  process.exit(1);
}
console.log("\nAll circuit constraint counts within tolerance.");
