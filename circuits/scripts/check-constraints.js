#!/usr/bin/env node
// Verifies exact R1CS constraint counts and hashes. Insert/withdraw hashes pin
// compilation to the R1CS used by the finalized ceremony.

import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const baseline = pkg.config.constraint_baseline;
const expectedHashes = pkg.config.r1cs_sha256;

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
  if (actual !== expected) {
    console.error(`  ✗ ${name}: ${actual} constraints, expected exactly ${expected}`);
    failed = true;
  }

  const actualHash = createHash("sha256").update(readFileSync(r1csPath)).digest("hex");
  const expectedHash = expectedHashes[name];
  if (actualHash !== expectedHash) {
    console.error(`  ✗ ${name}: R1CS SHA-256 ${actualHash}, expected ${expectedHash}`);
    failed = true;
  }

  if (actual === expected && actualHash === expectedHash) {
    console.log(`  ✓ ${name}: ${actual} constraints, SHA-256 ${actualHash}`);
  }
}

if (failed) {
  console.error(
    "\nReview any intentional artifact change before updating the pins; changing insert or withdraw requires a new trusted setup.",
  );
  process.exit(1);
}
console.log("\nAll R1CS artifacts match their exact release pins.");
