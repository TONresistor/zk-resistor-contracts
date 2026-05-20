// Poseidon BLS12-381 (2-input): JS reference for client-side Merkle ops.
//
// We reuse the circuit's witness calculator: instead of writing a full
// Poseidon implementation in JS, we compile a tiny circom circuit that
// computes Poseidon(a,b) for two inputs and use its WASM witness.
//
// This guarantees bit-perfect compatibility with the on-chain hash because
// the same WASM produces both the witness for the insert/withdraw circuits
// AND the Merkle tree hashes used to build their witnesses.
//
// Build (once):
//   echo 'pragma circom 2.1.6;
//   include "../node_modules/poseidon-bls12381-circom/circuits/poseidon255.circom";
//   template Hasher() { signal input a; signal input b; signal output out;
//     component h = Poseidon255(2); h.in[0] <== a; h.in[1] <== b; out <== h.out;
//   } component main = Hasher();' > build/hasher.circom
//   circom build/hasher.circom --r1cs --wasm -o build/ -p bls12381

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const __dirname = dirname(fileURLToPath(import.meta.url));
const HASHER_WASM = resolve(__dirname, "../build/hasher_js/hasher.wasm");
// circom emits the witness calculator as `witness_calculator.js`. We import
// it as a CommonJS module (it uses `module.exports`); since we're in an
// ESM script, we go through `createRequire` so Node treats it as CJS even
// though the file extension is `.js`. The circuits/package.json has
// `"type": "module"` so we explicitly point at `.js`.
const HASHER_BUILDER = resolve(__dirname, "../build/hasher_js/witness_calculator.js");

let calculator = null;

async function getCalculator() {
    if (calculator) return calculator;
    // Circom witness calculators are CommonJS: load via require() shim.
    // Read the file content, evaluate it as CJS (createRequire honors the
    // file's extension; since `.js` resolves as ESM under "type": "module"
    // in this package, we use a CJS-safe alternative below).
    const Module = require("node:module");
    const src = readFileSync(HASHER_BUILDER, "utf8");
    const m = new Module.Module(HASHER_BUILDER);
    m.filename = HASHER_BUILDER;
    m.paths = Module.Module._nodeModulePaths(dirname(HASHER_BUILDER));
    m._compile(src, HASHER_BUILDER);
    const builder = m.exports;
    const wasm = readFileSync(HASHER_WASM);
    calculator = await builder(wasm);
    return calculator;
}

export async function poseidon2(a, b) {
    const wc = await getCalculator();
    const witness = await wc.calculateWitness({ a: a.toString(), b: b.toString() }, false);
    // Witness slot 1 holds the first output signal.
    return witness[1];
}
