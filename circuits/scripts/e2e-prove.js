#!/usr/bin/env node
//
// e2e-prove.js: full pipeline:
//   1. build a tiny Merkle tree (depth 20) with a few existing leaves
//   2. generate a witness for inserting a new commitment
//   3. snarkjs.groth16.fullProve(witness, insert.wasm, insert_final.zkey)
//   4. snarkjs.groth16.verify(vk, publicSignals, proof) for sanity check
//   5. print the proof + public signals
//
// Used to validate the circuit + setup are correct BEFORE wiring into Tolk.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import * as snarkjs from "snarkjs";
import { insertWitness, withdrawWitness } from "./merkle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BUILD = resolve(__dirname, "../build");

async function proveInsert() {
    // Empty tree, insert at leafIndex 0.
    const witness = await insertWitness([], 0xc0ffeen, 0);
    console.log("[insert] witness shape:");
    console.log({
        oldRoot: witness.oldRoot,
        newRoot: witness.newRoot,
        commitment: witness.commitment,
        leafIndex: witness.leafIndex,
        pathElementsLen: witness.pathElements.length,
        zerosLen: witness.zeros.length,
    });

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        witness,
        `${BUILD}/insert_js/insert.wasm`,
        `${BUILD}/insert_final.zkey`,
    );

    const vk = JSON.parse(readFileSync(`${BUILD}/insert_vk.json`, "utf8"));
    const ok = await snarkjs.groth16.verify(vk, publicSignals, proof);
    console.log(`[insert] snarkjs.verify(vk, ...) = ${ok ? "✓ valid" : "✗ INVALID"}`);

    return { proof, publicSignals, vk };
}

async function proveWithdraw() {
    // Build a tree with our commitment at leafIndex 0, then prove withdraw.
    const nullifier = 0xa1b2c3d4e5f6n;
    const secret = 0x1234567890abcdefn;
    const witness = await withdrawWitness({
        leaves: [],
        leafIndex: 0,
        nullifier,
        secret,
        recipient: 0xdead0000beef0000n,
    });
    console.log("[withdraw] witness shape:");
    console.log({
        root: witness.root,
        nullifierHash: witness.nullifierHash,
        recipient: witness.recipient,
    });

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        witness,
        `${BUILD}/withdraw_js/withdraw.wasm`,
        `${BUILD}/withdraw_final.zkey`,
    );

    const vk = JSON.parse(readFileSync(`${BUILD}/withdraw_vk.json`, "utf8"));
    const ok = await snarkjs.groth16.verify(vk, publicSignals, proof);
    console.log(`[withdraw] snarkjs.verify(vk, ...) = ${ok ? "✓ valid" : "✗ INVALID"}`);

    return { proof, publicSignals, vk };
}

const [, , circuit] = process.argv;

try {
    if (circuit === "insert") {
        await proveInsert();
    } else if (circuit === "withdraw") {
        await proveWithdraw();
    } else {
        console.log("=== INSERT ===");
        await proveInsert();
        console.log("\n=== WITHDRAW ===");
        await proveWithdraw();
    }
    process.exit(0);
} catch (e) {
    console.error("FAILED:", e);
    process.exit(1);
}
