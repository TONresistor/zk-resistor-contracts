pragma circom 2.1.6;

// =========================================================================
// JS-ONLY hasher. DO NOT DEPLOY. DO NOT RUN A TRUSTED SETUP AGAINST THIS.
// =========================================================================
//
// This standalone circuit exists solely so the JS-side Merkle tree builder
// shares the EXACT same Poseidon BLS12-381 hash as the on-chain verifier
// (via `circom --wasm` → `hasher_js/`, used as a witness calculator only,
// never as a proving circuit).
//
// Inputs are declared NON-public so an accidental `groth16 setup` against
// this circuit cannot produce a usable zkey that leaks both preimages.

include "node_modules/poseidon-bls12381-circom/circuits/poseidon255.circom";

template Hasher() {
    signal input a;
    signal input b;
    signal output out;

    component h = Poseidon255(2);
    h.in[0] <== a;
    h.in[1] <== b;
    out <== h.out;
}

component main = Hasher();
