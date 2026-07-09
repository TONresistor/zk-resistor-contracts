import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/pool-types"
import "@tests/proofs-fixture"
import "@wrappers/Pool.gen"

// ============================================================================
// REAL PROOF VALIDATION: executes the on-chain BLS12-381 pairing check
// against a Groth16 proof generated off-chain by snarkjs.
//
// If both `test insert proof verifies on-chain` and `test withdraw proof
// verifies on-chain` pass, then the entire pipeline is validated:
//   circuit (circom) → setup (snarkjs) → witness (JS) → proof (snarkjs)
//                   → BLST encoding → Tolk slice → TVM pairing check
//
// Fixtures are generated from the production depth-20 circuits and final VKs.
// A passing fixture validates the same proving stack used for deployment. To
// regenerate, see `circuits/scripts/gen-fixtures.js`.
// ============================================================================

fun freshPool(): Pool {
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("jm").address,
        factory: testing.treasury("factory").address,
        denomination: 100,
    };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: 0,
        rootHistory: [],
        nullifiers: [],
        commitments: [],
    };
    return Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: testing.treasury("jw").address,
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawals: [],
    });
}

fun setupPool(): Pool {
    val deployer = testing.treasury("deployer");
    val pool = freshPool();
    val res = pool.deploy(deployer.address, { value: ton("1") });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

get fun `test insert proof verifies on-chain via BLS pairing`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    expect(ok).toEqual(true);
}

get fun `test insert proof rejected when commitment tampered`() {
    val pool = setupPool();
    val tampered: uint256 = FIXTURE_INSERT_COMMITMENT + 1;
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        tampered,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof verifies on-chain via BLS pairing`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(true);
}

get fun `test withdraw proof rejected when nullifier tampered`() {
    val pool = setupPool();
    val tampered: uint256 = FIXTURE_WITHDRAW_NULLIFIER_HASH + 1;
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        tampered,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejected when recipient field tampered`() {
    val pool = setupPool();
    val tampered: uint256 = FIXTURE_WITHDRAW_RECIPIENT + 1;
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        tampered, // proof must reject when recipient changes
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(false);
}

// ============================================================================
// Slice-shape gate: malformed proof slices return false, never crash
// ============================================================================
//
// Strict length validation in the verifier ensures over-length proofs (which
// TVM would silently truncate to 48/96 bytes) and under-length proofs (which
// would trigger cell_underflow during pairing) are both rejected cleanly.

fun underLengthG1(): slice {
    return beginCell().storeUint(0, 200).endCell().beginParse();
}

fun overLengthG1(): slice {
    return beginCell().storeUint(0, 256).storeUint(0, 144).endCell().beginParse();
}

fun underLengthG2(): slice {
    return beginCell().storeUint(0, 256).storeUint(0, 256).storeUint(0, 188).endCell().beginParse();
}

fun overLengthG2(): slice {
    // 800 bits total (expected 768). storeUint caps at 256 bits per call,
    // so chain four stores: 256 + 256 + 256 + 32 = 800.
    return beginCell()
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 32)
        .endCell()
        .beginParse();
}

fun withExtraRef(proof: slice): slice {
    return beginCell().storeSlice(proof).storeRef(beginCell().endCell()).endCell().beginParse();
}

fun zeroG1(): slice {
    return beginCell()
        .storeUint(0xC0, 8)
        .storeUint(0, 256)
        .storeUint(0, 120)
        .endCell()
        .beginParse();
}

fun zeroG2(): slice {
    return beginCell()
        .storeUint(0xC0, 8)
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 248)
        .endCell()
        .beginParse();
}

fun invalidNonZeroG1(): slice {
    return beginCell()
        .storeUint(0x80, 8)
        .storeUint(1, 256)
        .storeUint(0, 120)
        .endCell()
        .beginParse();
}

fun invalidNonZeroG2(): slice {
    return beginCell()
        .storeUint(0x80, 8)
        .storeUint(1, 256)
        .storeUint(0, 256)
        .storeUint(0, 248)
        .endCell()
        .beginParse();
}

get fun `test insert proof rejected when proofA is under-length`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        underLengthG1(), // 200 bits, expected 384
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test insert proof rejects valid G1 payload with trailing ref`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        withExtraRef(fixtureInsertProofA()),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test insert proof rejects valid G2 payload with trailing ref`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        withExtraRef(fixtureInsertProofB()),
        fixtureInsertProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test insert proof rejects valid proofC payload with trailing ref`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        withExtraRef(fixtureInsertProofC()),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejects valid proofA payload with trailing ref`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        withExtraRef(fixtureWithdrawProofA()),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejects valid proofB payload with trailing ref`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        withExtraRef(fixtureWithdrawProofB()),
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejects valid G1 payload with trailing ref`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        withExtraRef(fixtureWithdrawProofC()),
    );
    expect(ok).toEqual(false);
}

get fun `test insert proof rejects zero prover points`() {
    val pool = setupPool();
    val zeroA = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        zeroG1(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    val zeroB = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        zeroG2(),
        fixtureInsertProofC(),
    );
    expect(zeroA).toEqual(false);
    expect(zeroB).toEqual(false);
}

get fun `test withdraw proof rejects zero prover points`() {
    val pool = setupPool();
    val zeroA = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        zeroG1(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    val zeroB = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        zeroG2(),
        fixtureWithdrawProofC(),
    );
    expect(zeroA).toEqual(false);
    expect(zeroB).toEqual(false);
}

get fun `test insert proof rejects non-group prover points`() {
    val pool = setupPool();
    val badA = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        invalidNonZeroG1(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    val badB = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        invalidNonZeroG2(),
        fixtureInsertProofC(),
    );
    val badC = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        invalidNonZeroG1(),
    );
    expect(badA).toEqual(false);
    expect(badB).toEqual(false);
    expect(badC).toEqual(false);
}

get fun `test withdraw proof rejects non-group prover points`() {
    val pool = setupPool();
    val badA = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        invalidNonZeroG1(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    val badB = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        invalidNonZeroG2(),
        fixtureWithdrawProofC(),
    );
    val badC = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        invalidNonZeroG1(),
    );
    expect(badA).toEqual(false);
    expect(badB).toEqual(false);
    expect(badC).toEqual(false);
}

get fun `test insert proof rejects public input field aliases`() {
    val pool = setupPool();
    val aliasedOldRoot = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT + BLS12_381_R,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    val aliasedNewRoot = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT + BLS12_381_R,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    val aliasedCommitment = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT + BLS12_381_R,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    expect(aliasedOldRoot).toEqual(false);
    expect(aliasedNewRoot).toEqual(false);
    expect(aliasedCommitment).toEqual(false);
}

get fun `test insert proof rejects public inputs exactly equal to scalar field order`() {
    val pool = setupPool();
    val rootAtR = pool.previewInsertProof(
        BLS12_381_R,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    val newRootAtR = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        BLS12_381_R,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    val commitmentAtR = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        BLS12_381_R,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        fixtureInsertProofC(),
    );
    expect(rootAtR).toEqual(false);
    expect(newRootAtR).toEqual(false);
    expect(commitmentAtR).toEqual(false);
}

get fun `test withdraw proof rejects public input field aliases`() {
    val pool = setupPool();
    val aliasedRoot = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT + BLS12_381_R,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    val aliasedNullifier = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH + BLS12_381_R,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(aliasedRoot).toEqual(false);
    expect(aliasedNullifier).toEqual(false);
}

get fun `test withdraw proof rejects public inputs exactly equal to scalar field order`() {
    val pool = setupPool();
    val rootAtR = pool.previewWithdrawProof(
        BLS12_381_R,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    val nullifierAtR = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        BLS12_381_R,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(rootAtR).toEqual(false);
    expect(nullifierAtR).toEqual(false);
}

get fun `test insert proof rejected when proofB is under-length`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        underLengthG2(), // 700 bits, expected 768
        fixtureInsertProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test insert proof rejected when proofC is over-length`() {
    val pool = setupPool();
    val ok = pool.previewInsertProof(
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_NEW_ROOT,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_LEAF_INDEX,
        fixtureInsertProofA(),
        fixtureInsertProofB(),
        overLengthG1(), // 400 bits, expected 384
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejected when proofA is over-length`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        overLengthG1(), // 400 bits, expected 384
        fixtureWithdrawProofB(),
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejected when proofB is over-length`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        overLengthG2(), // 800 bits, expected 768
        fixtureWithdrawProofC(),
    );
    expect(ok).toEqual(false);
}

get fun `test withdraw proof rejected when proofC is under-length`() {
    val pool = setupPool();
    val ok = pool.previewWithdrawProof(
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        FIXTURE_WITHDRAW_RECIPIENT,
        fixtureWithdrawProofA(),
        fixtureWithdrawProofB(),
        underLengthG1(), // 200 bits, expected 384
    );
    expect(ok).toEqual(false);
}
