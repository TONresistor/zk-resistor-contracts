#!/usr/bin/env node
// Compute the canonical empty-subtree Poseidon BLS12-381 chain for a Merkle
// tree of depth 20:
//
//     ZEROS[0] = 0
//     ZEROS[i] = Poseidon(ZEROS[i-1], ZEROS[i-1])
//
// These values are baked into `circuits/lib/merkle_tree.circom` so the
// `MerkleInsertProof` template can pin `zeros[i] === ZEROS[i]` at ~zero
// constraint cost (one equality per level) instead of recomputing the
// Poseidon chain inside the circuit (~6,500 constraints).
//
// `check-zeros.js` reruns this script and diffs the output against the
// hardcoded values, so any drift between the script and the circuit fails CI.
//
// `ZEROS[19]` MUST equal `EMPTY_TREE_ROOT` in `contracts/constants.tolk`.
// The CI gate enforces that too.

import { poseidon2 } from "./poseidon-bls.js";

const DEPTH = 20;

async function computeZeros() {
  const zeros = [0n];
  for (let i = 1; i < DEPTH; i++) {
    const prev = zeros[i - 1];
    const next = await poseidon2(prev, prev);
    zeros.push(BigInt(next));
  }
  return zeros;
}

const zeros = await computeZeros();
for (let i = 0; i < zeros.length; i++) {
  const hex = zeros[i].toString(16).padStart(64, "0");
  console.log(`    0x${hex},   // ZEROS[${i}]`);
}
console.log();
console.log(`// EMPTY_TREE_ROOT (depth-20 root with all zero leaves):`);
console.log(`//   0x${(await poseidon2(zeros[DEPTH - 1], zeros[DEPTH - 1])).toString(16).padStart(64, "0")}`);
