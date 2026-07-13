#!/usr/bin/env node
// CI gate: re-derive the canonical Poseidon BLS12-381 empty-subtree chain
// and diff against the values hardcoded in `lib/merkle_tree.circom`. Any
// drift between the script and the circuit fails the build.
//
// Also asserts that Poseidon(`ZEROS[19]`, `ZEROS[19]`) equals the
// `EMPTY_TREE_ROOT` constant in `contracts/constants.tolk`, i.e. the empty
// depth-20 root the on-chain pool initializes with on deploy. Drift here would
// mean the first deposit's insertion proof cannot verify against that root.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { poseidon2 } from "./poseidon-bls.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");

const DEPTH = 20;

async function computeZeros() {
  const zeros = [0n];
  for (let i = 1; i < DEPTH; i++) {
    zeros.push(BigInt(await poseidon2(zeros[i - 1], zeros[i - 1])));
  }
  return zeros;
}

function parseHardcodedZeros() {
  const src = readFileSync(join(ROOT, "lib", "merkle_tree.circom"), "utf8");
  const match = src.match(/var ZEROS\[20\]\s*=\s*\[([\s\S]*?)\];/);
  if (!match) {
    console.error("  ✗ Could not locate `var ZEROS[20] = [...]` in merkle_tree.circom");
    process.exit(1);
  }
  const values = match[1]
    .split(",")
    .map((line) => line.replace(/\/\/.*$/m, "").trim())
    .filter((s) => s.length > 0)
    .map((s) => BigInt(s));
  if (values.length !== DEPTH) {
    console.error(`  ✗ Expected ${DEPTH} ZEROS values, found ${values.length}`);
    process.exit(1);
  }
  return values;
}

function parseEmptyTreeRootFromContract() {
  const src = readFileSync(
    join(ROOT, "..", "contracts", "constants.tolk"),
    "utf8",
  );
  const match = src.match(/EMPTY_TREE_ROOT[^=]*=\s*(0x[0-9a-fA-F]+)/);
  if (!match) {
    console.error("  ✗ Could not locate EMPTY_TREE_ROOT in contracts/constants.tolk");
    process.exit(1);
  }
  return BigInt(match[1]);
}

const computed = await computeZeros();
const hardcoded = parseHardcodedZeros();
const contractRoot = parseEmptyTreeRootFromContract();

let failed = false;

for (let i = 0; i < DEPTH; i++) {
  if (computed[i] !== hardcoded[i]) {
    console.error(`  ✗ ZEROS[${i}] mismatch:`);
    console.error(`      script:   0x${computed[i].toString(16).padStart(64, "0")}`);
    console.error(`      circuit:  0x${hardcoded[i].toString(16).padStart(64, "0")}`);
    failed = true;
  }
}
if (!failed) {
  console.log(`  ✓ All ${DEPTH} ZEROS[] values match canonical Poseidon chain`);
}

// EMPTY_TREE_ROOT = root of a depth-20 tree with all empty leaves
//                 = Poseidon(ZEROS[19], ZEROS[19])
const expectedRoot = BigInt(await poseidon2(computed[DEPTH - 1], computed[DEPTH - 1]));
if (expectedRoot !== contractRoot) {
  console.error(`  ✗ EMPTY_TREE_ROOT mismatch:`);
  console.error(`      computed:   0x${expectedRoot.toString(16).padStart(64, "0")}`);
  console.error(`      contract:   0x${contractRoot.toString(16).padStart(64, "0")}`);
  failed = true;
} else {
  console.log(`  ✓ EMPTY_TREE_ROOT (0x${expectedRoot.toString(16).slice(0, 12)}…) matches contracts/constants.tolk`);
}

if (failed) {
  console.error(
    "\nIf the change is intentional (e.g. tree depth or hash function changed), regenerate via `node scripts/compute-zeros.js` and update both the circuit and the contract.",
  );
  process.exit(1);
}
console.log("\nCanonical chain integrity OK.");
