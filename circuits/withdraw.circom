pragma circom 2.1.6;

include "lib/merkle_tree.circom";
// `IsZero` is reachable transitively through `merkle_tree.circom`, but we
// include `comparators` explicitly so a refactor of merkle_tree does not
// silently drop the recipient-non-zero check below (defense-in-depth).
include "node_modules/circomlib/circuits/comparators.circom";

// ============================================================================
// ZKResistor: Withdrawal proof (recipient-only binding)
// ============================================================================
//
// The proof attests that the prover knows (nullifier, secret) and a Merkle
// path under leafIndex such that:
//   commitment    = Poseidon(nullifier, secret)
//   nullifierHash = Poseidon(nullifier, 0)
//   root          = MerkleRoot(commitment, leafIndex, path)
//
// Public inputs:
//   root            : must be a recently-known root of the pool
//   nullifierHash   : must not be in the pool's spent-set
//   recipient       : address that receives the funds (binds the proof)
//
// The relayer (= tx sender) earns RELAYER_REIMBURSEMENT TON from the pool.
// We deliberately do NOT bind the relayer in the proof, so anyone (the user
// themself or any third party) can broadcast a published proof. The first
// to land wins; replays bounce thanks to the nullifier check, refunding the
// loser's attached gas.
//
// Private inputs:
//   nullifier, secret      : the commitment preimage
//   pathElements           : siblings on the Merkle path
//   pathIndices            : left/right bits (0/1) per level

template Withdraw(levels) {
    signal input root;
    signal input nullifierHash;
    signal input recipient;

    signal input nullifier;
    signal input secret;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // Reject zero recipient: defends against any pathological encoding
    // where addressToField produces 0 (and against grossly malformed inputs).
    component recipientCheck = IsZero();
    recipientCheck.in <== recipient;
    recipientCheck.out === 0;

    // Defense-in-depth: pin recipient to the 248-bit window the SDK and
    // on-chain verifier mask to. Without this, the circuit would accept ANY
    // Fr-reduced value, drifting from the off-chain invariant if the masking
    // layer is ever bypassed.
    component recipientBits = Num2Bits(248);
    recipientBits.in <== recipient;

    // Defense-in-depth: pin nullifier + secret to the 248-bit entropy
    // window the SDK generates. Two values differing only by a multiple of
    // the Fr modulus would otherwise hash to the same commitment via
    // circom's auto-reduction: birthday-bounded but not structurally
    // enforced without this.
    component nullifierBits = Num2Bits(248);
    nullifierBits.in <== nullifier;
    component secretBits = Num2Bits(248);
    secretBits.in <== secret;

    // Derive commitment and nullifierHash from the witness.
    component hasher = CommitmentHasher();
    hasher.nullifier <== nullifier;
    hasher.secret    <== secret;
    nullifierHash === hasher.nullifierHash;

    // Prove commitment is in the tree at the given path.
    component tree = MerkleProof(levels);
    tree.leaf <== hasher.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i]  <== pathIndices[i];
    }

    // Anti-optimization: bind recipient so the compiler does not drop it.
    signal s1 <== recipient * recipient;
}

component main { public [root, nullifierHash, recipient] } = Withdraw(20);
