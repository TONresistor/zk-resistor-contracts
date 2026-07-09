pragma circom 2.1.6;

include "lib/merkle_tree.circom";

// ============================================================================
// ZKResistor: Insertion proof
// ============================================================================
//
// Verifiable on-chain proof that:
//
//   newRoot = MerkleInsert(oldRoot, commitment, leafIndex)
//
// Inputs:
//   public  oldRoot       : current Merkle root of the pool
//   public  newRoot       : root after inserting the commitment
//   public  commitment    : the new leaf (Poseidon(nullifier, secret))
//   public  leafIndex     : must equal pool.nextIndex on-chain
//
//   private pathElements  : siblings on the path under leafIndex
//   private zeros         : empty-subtree constants (one per level)
//
// SOUNDNESS NOTE: `zeros[]` is witness-supplied, but MerkleInsertProof pins it
// to the canonical Poseidon empty-subtree chain baked in
// `circuits/lib/merkle_tree.circom`. Insertion freshness also relies on TWO
// upstream pool-contract checks that MUST stay in place:
//
//   - leafIndex == pool.nextIndex   (anti-replay across concurrent inserts)
//   - oldRoot   == pool.currentRoot (no insertion against a stale root)
//
// Together these guarantee the prover can only produce a valid proof for the
// next slot of the current tree. Relaxing either check (e.g. accepting
// historical roots for inserts as withdraw does) would let a malicious prover
// diverge the on-chain tree from the pool's append-only state. Keep both in
// `pool.tolk:handleDeposit` / `ton-pool.tolk:handleDeposit`.
//
// The pool contract checks (per above):
//   - the Groth16 verifier accepts the proof under the pinned VK
//   - leafIndex == pool.nextIndex
//   - oldRoot   == pool.currentRoot
//
// On success, the pool sets currentRoot = newRoot and bumps nextIndex.
//
// LEVELS = 20 -> 1_048_576 leaves per pool. Proof generation ~5-8s in WASM
// on a modern laptop; ~30s in mobile browser. Acceptable for deposit UX.

template Insert(levels) {
    signal input oldRoot;
    signal input newRoot;
    signal input commitment;
    signal input leafIndex;

    signal input pathElements[levels];
    signal input zeros[levels];

    component proof = MerkleInsertProof(levels);
    proof.oldRoot   <== oldRoot;
    proof.newRoot   <== newRoot;
    proof.leaf      <== commitment;
    proof.leafIndex <== leafIndex;
    for (var i = 0; i < levels; i++) {
        proof.pathElements[i] <== pathElements[i];
        proof.zeros[i]        <== zeros[i];
    }
}

component main { public [oldRoot, newRoot, commitment, leafIndex] } = Insert(20);
