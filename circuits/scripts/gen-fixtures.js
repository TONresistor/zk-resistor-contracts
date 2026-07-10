#!/usr/bin/env node
//
// gen-fixtures.js: generate Tolk fixtures with real Groth16 proofs.
//
// Writes `../tests/proofs-fixture.tolk` for the on-chain RealProof test.
// The fixture encodes the proof as 48-bit (G1) and 96-bit (G2) chunked
// slices, exactly matching the verifier's deserialization.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import * as snarkjs from "snarkjs";
import { g1ToChunks, g2ToChunks } from "./bls-encode.js";

process.env.TREE_DEPTH = "20";
const { insertWitness, withdrawWitness } = await import("./merkle.js");
const { poseidon2 } = await import("./poseidon-bls.js");

const __dirname = dirname(fileURLToPath(import.meta.url));
const BUILD = resolve(__dirname, "../build");
const VK = resolve(__dirname, "../vk");
const OUT_FILE = resolve(__dirname, "../../tests/proofs-fixture.tolk");

const INSERT_WASM = `${BUILD}/insert_js/insert.wasm`;
const INSERT_ZKEY = `${BUILD}/insert_final.zkey`;
const INSERT_VK = `${VK}/insert_vk.json`;
const WITHDRAW_WASM = `${BUILD}/withdraw_js/withdraw.wasm`;
const WITHDRAW_ZKEY = `${BUILD}/withdraw_final.zkey`;
const WITHDRAW_VK = `${VK}/withdraw_vk.json`;

function emitG1Slice(name, chunks) {
    const lines = [`fun ${name}(): slice {`, `    return beginCell()`];
    for (let i = 0; i < 8; i++) {
        lines.push(`        .storeUint(${chunks[i]}, 48)`);
    }
    lines.push(`        .endCell()`);
    lines.push(`        .beginParse();`);
    lines.push(`}`);
    return lines.join("\n");
}

function emitG2Slice(name, chunks) {
    const lines = [`fun ${name}(): slice {`, `    return beginCell()`];
    for (let i = 0; i < 8; i++) {
        lines.push(`        .storeUint(${chunks[i]}, 96)`);
    }
    lines.push(`        .endCell()`);
    lines.push(`        .beginParse();`);
    lines.push(`}`);
    return lines.join("\n");
}

// We need INSERT and WITHDRAW proofs that CHAIN: the commitment inserted
// by the insert proof must be the same commitment proven by the withdraw
// proof. Otherwise the on-chain E2E flow (deposit → withdraw) does not work.

const nullifier = 0xa1b2c3d4n;
const secret = 0x1234567890abn;
const commitment = BigInt(await poseidon2(nullifier, secret));

// Recipient: a real mainnet address (admin/1312.ton owner) so the on-chain
// test can pass `address("EQB8PZ-...")` directly as `msg.recipient`, and the
// contract's derivation of recipientField from the address hash matches the
// FIXTURE_WITHDRAW_RECIPIENT value the proof commits to.
//
// recipientField = lower 248 bits of hash (matches frontend/src/lib/note.ts:addressToField).
const RECIPIENT_ADDR = "EQB8PZ-Cp6UzydbLvjukx1OQL3LmqeYV-tJ3qVMw_mNYgqow";
const RECIPIENT_HASH_HEX = "7c3d9f82a7a533c9d6cbbe3ba4c753902f72e6a9e615fad277a95330fe635882";
const FIELD_MASK_248 = (1n << 248n) - 1n;
const recipient = BigInt("0x" + RECIPIENT_HASH_HEX) & FIELD_MASK_248;

// --- INSERT proof: empty tree → insert `commitment` at leaf 0 ---
const insertW = await insertWitness([], commitment, 0);
const { proof: pi, publicSignals: psi } = await snarkjs.groth16.fullProve(
    insertW,
    INSERT_WASM,
    INSERT_ZKEY,
);
const insertVk = JSON.parse(readFileSync(INSERT_VK, "utf8"));
if (!(await snarkjs.groth16.verify(insertVk, psi, pi)))
    throw new Error("insert proof failed snarkjs verify");
console.log("[insert] snarkjs verify ✓");

// --- SECOND INSERT proof: insert a distinct commitment at leaf 1 ---
// This keeps IC[4] observable in the on-chain verifier. A fixture only at
// leafIndex 0 multiplies the leaf-index verification-key point by zero and
// cannot detect an IC[3]/IC[4] selection regression.
const secondNullifier = 0xb1c2d3e4n;
const secondSecret = 0x234567890abcn;
const secondCommitment = BigInt(await poseidon2(secondNullifier, secondSecret));
const secondInsertW = await insertWitness([commitment], secondCommitment, 1);
const { proof: piSecond, publicSignals: psiSecond } = await snarkjs.groth16.fullProve(
    secondInsertW,
    INSERT_WASM,
    INSERT_ZKEY,
);
if (!(await snarkjs.groth16.verify(insertVk, psiSecond, piSecond)))
    throw new Error("second insert proof failed snarkjs verify");
if (BigInt(secondInsertW.oldRoot) !== BigInt(insertW.newRoot))
    throw new Error("second insert fixture does not extend the first insert root");
console.log("[insert leaf 1] snarkjs verify ✓");

// --- WITHDRAW proof: prove (nullifier, secret) for the commitment at leaf 0 ---
const ww = await withdrawWitness({
    leaves: [],
    leafIndex: 0,
    nullifier,
    secret,
    recipient,
});
const { proof: pw, publicSignals: psw } = await snarkjs.groth16.fullProve(
    ww,
    WITHDRAW_WASM,
    WITHDRAW_ZKEY,
);
const withdrawVk = JSON.parse(readFileSync(WITHDRAW_VK, "utf8"));
if (!(await snarkjs.groth16.verify(withdrawVk, psw, pw)))
    throw new Error("withdraw proof failed snarkjs verify");
console.log("[withdraw] snarkjs verify ✓");

// Sanity: insert.newRoot should equal withdraw.root since both use the
// same commitment at leaf 0 in a depth-20 empty tree.
if (BigInt(insertW.newRoot) !== BigInt(ww.root)) {
    console.warn(`[chain] WARNING: insert.newRoot != withdraw.root`);
    console.warn(`  insert.newRoot = ${insertW.newRoot}`);
    console.warn(`  withdraw.root  = ${ww.root}`);
} else {
    console.log(`[chain] insert.newRoot == withdraw.root ✓`);
}

const lines = [
    `// AUTO-GENERATED by circuits/scripts/gen-fixtures.js`,
    `// Real Groth16 BLS12-381 proofs for the depth-20 production circuits.`,
    `// Used by tests/RealProof.test.tolk to validate end-to-end pairing.`,
    ``,
    `// =========================================================`,
    `// INSERT: proves new_root = insert(old_root, commitment, leafIndex)`,
    `// =========================================================`,
    `const FIXTURE_INSERT_OLD_ROOT: uint256 = ${insertW.oldRoot}`,
    `const FIXTURE_INSERT_NEW_ROOT: uint256 = ${insertW.newRoot}`,
    `const FIXTURE_INSERT_COMMITMENT: uint256 = ${insertW.commitment}`,
    `const FIXTURE_INSERT_LEAF_INDEX: uint32 = ${insertW.leafIndex}`,
    ``,
    emitG1Slice("fixtureInsertProofA", g1ToChunks(pi.pi_a)),
    ``,
    emitG2Slice("fixtureInsertProofB", g2ToChunks(pi.pi_b)),
    ``,
    emitG1Slice("fixtureInsertProofC", g1ToChunks(pi.pi_c)),
    ``,
    `// =========================================================`,
    `// SECOND INSERT: extends the first root at leafIndex = 1`,
    `// =========================================================`,
    `const FIXTURE_SECOND_INSERT_OLD_ROOT: uint256 = ${secondInsertW.oldRoot}`,
    `const FIXTURE_SECOND_INSERT_NEW_ROOT: uint256 = ${secondInsertW.newRoot}`,
    `const FIXTURE_SECOND_INSERT_COMMITMENT: uint256 = ${secondInsertW.commitment}`,
    `const FIXTURE_SECOND_INSERT_LEAF_INDEX: uint32 = ${secondInsertW.leafIndex}`,
    ``,
    emitG1Slice("fixtureSecondInsertProofA", g1ToChunks(piSecond.pi_a)),
    ``,
    emitG2Slice("fixtureSecondInsertProofB", g2ToChunks(piSecond.pi_b)),
    ``,
    emitG1Slice("fixtureSecondInsertProofC", g1ToChunks(piSecond.pi_c)),
    ``,
    `// =========================================================`,
    `// WITHDRAW: proves commitment in tree with matching nullifier`,
    `// =========================================================`,
    `const FIXTURE_WITHDRAW_ROOT: uint256 = ${ww.root}`,
    `const FIXTURE_WITHDRAW_NULLIFIER_HASH: uint256 = ${ww.nullifierHash}`,
    `// recipientField = lower 248 bits of the address hash, matching`,
    `// frontend/src/lib/note.ts:addressToField and the contract's derivation.`,
    `// The full raw hash is exposed so tests can reconstruct the address via`,
    `// address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW).`,
    `// Friendly form: ${RECIPIENT_ADDR}`,
    `const FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW: uint256 = 0x${RECIPIENT_HASH_HEX}`,
    `const FIXTURE_WITHDRAW_RECIPIENT: uint256 = ${ww.recipient}`,
    ``,
    emitG1Slice("fixtureWithdrawProofA", g1ToChunks(pw.pi_a)),
    ``,
    emitG2Slice("fixtureWithdrawProofB", g2ToChunks(pw.pi_b)),
    ``,
    emitG1Slice("fixtureWithdrawProofC", g1ToChunks(pw.pi_c)),
];

writeFileSync(OUT_FILE, lines.join("\n") + "\n");
console.log(`\n✓ wrote ${OUT_FILE}`);
console.log(`  Use in tests/RealProof.test.tolk with the production verifier`);
process.exit(0);
