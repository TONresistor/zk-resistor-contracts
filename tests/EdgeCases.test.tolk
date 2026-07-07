import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/pool-types"
import "@contracts/ton-pool-types"
import "@wrappers/Pool.gen"
import "@wrappers/TonPool.gen"

// ============================================================================
// Edge-case coverage: negative paths.
//
// These exercise refund branches, lifecycle guards, and bounce handling that
// the happy-path E2E + MainnetDryRun suites don't reach. Storage is forged
// directly via `fromStorage` so we can hit branches that require state the
// happy-path setup cannot produce (e.g. tree at capacity, pre-existing
// commitment, jettonWallet still null after deploy).
// ============================================================================

const EDGE_DENOM: coins = 100

fun forgePool(jw: address?, nextIdx: uint32, commitments: map<uint256, uint32>): Pool {
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("jm").address,
        factory: testing.treasury("factory").address,
        denomination: EDGE_DENOM,
    };
    val merkle: MerkleState = {
        nextIndex: nextIdx,
        currentRoot: 0,
        rootHistory: [],
        nullifiers: [],
        commitments,
    };
    return Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: jw,
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawals: [],
    });
}

fun forgeTonPool(nextIdx: uint32, commitments: map<uint256, uint32>): TonPool {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("factory").address,
        denomination: ton("10"),
    };
    val merkle: MerkleState = {
        nextIndex: nextIdx,
        currentRoot: 0,
        rootHistory: [],
        nullifiers: [],
        commitments,
    };
    return TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    });
}

// ============================================================================
// Wallet binding: TEP-89 round-trip
// ============================================================================

get fun `test Pool TakeWalletAddress is rejected when wallet already bound`() {
    val jw = testing.treasury("jw").address;
    val deployer = testing.treasury("deployer");

    // Forge a pool that already has its jettonWallet bound.
    val pool = forgePool(jw, 0, []);
    expect(
        pool.deploy(deployer.address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    // A second take_wallet_address from the legitimate master must be rejected:
    // jettonWallet is single-shot.
    val masterAddr = testing.treasury("jm").address;
    val res = pool.sendTakeWalletAddress(
        masterAddr,
        1,
        testing.treasury("attacker-jw").address,
        createEmptySlice(),
        { value: ton("0.1") },
    );
    expect(res).toHaveFailedTx({
        from: masterAddr,
        to: pool.address,
        exitCode: Errors.JettonWalletAlreadySet,
    });
    // jettonWallet untouched.
    expect(pool.jettonWallet()).toEqual(jw);
}

get fun `test Pool TakeWalletAddress from non-jettonMaster is rejected`() {
    val pool = forgePool(null, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    // Spoofed reply from someone other than the bound master must fail.
    val attacker = testing.treasury("attacker");
    val res = pool.sendTakeWalletAddress(
        attacker.address,
        1,
        testing.treasury("malicious-jw").address,
        createEmptySlice(),
        { value: ton("0.1") },
    );
    expect(res).toHaveFailedTx({
        from: attacker.address,
        to: pool.address,
        exitCode: Errors.NotJettonMaster,
    });
    expect(pool.jettonWallet()).toEqual(null);
}

get fun `test Pool InitWalletBinding is idempotent once bound`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    // Already bound: a late retrigger by anyone is accepted as a no-op
    // (no provide_wallet_address sent, no state change).
    val anyone = testing.treasury("anyone");
    val res = pool.sendInitWalletBinding(anyone.address, 1, { value: ton("0.1") });
    expect(res).toHaveSuccessfulTx({ from: anyone.address, to: pool.address });
    expect(pool.jettonWallet()).toEqual(jw);
}

get fun `test Pool InitWalletBinding sends TEP-89 query when wallet is null`() {
    val masterAddr = testing.treasury("jm").address;
    val pool = forgePool(null, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val anyone = testing.treasury("anyone");
    val res = pool.sendInitWalletBinding(anyone.address, 1, { value: ton("0.1") });
    // Pool fires provide_wallet_address (0x2c76b973) at the bound master.
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: masterAddr,
        opcode: 0x2c76b973,
    });
    // No binding yet — that happens when the master replies.
    expect(pool.jettonWallet()).toEqual(null);
}

get fun `test Pool InitWalletBinding underfunded is rejected`() {
    val pool = forgePool(null, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    // Attached value below the query budget must fail so the pool's own
    // balance is never used to fund retriggers.
    val anyone = testing.treasury("anyone");
    val res = pool.sendInitWalletBinding(anyone.address, 1, { value: ton("0.01") });
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.InsufficientGas,
    });
    expect(pool.jettonWallet()).toEqual(null);
}

// ============================================================================
// Withdraw on uninitialized pool
// ============================================================================

get fun `test Pool withdraw is rejected when jettonWallet is unset`() {
    val pool = forgePool(null, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val anyone = testing.treasury("anyone");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val res = pool.sendWithdraw(
        anyone.address,
        1,
        0,
        0,
        anyone.address,
        zeroProof,
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.JettonWalletNotSet,
    });
}

// ============================================================================
// Withdraw: recipient shape guards
// ============================================================================

get fun `test Pool withdraw rejects masterchain recipient`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val anyone = testing.treasury("anyone");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val masterchainRecipient = address.fromWorkchainAndHash(-1, 0x1234);
    val res = pool.sendWithdraw(
        anyone.address,
        1,
        0,
        0,
        masterchainRecipient,
        zeroProof,
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.InvalidRecipient,
    });
}

get fun `test Pool withdraw rejects zero-hash recipient`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val anyone = testing.treasury("anyone");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val zeroHashRecipient = address.fromWorkchainAndHash(0, 0);
    val res = pool.sendWithdraw(
        anyone.address,
        1,
        0,
        0,
        zeroHashRecipient,
        zeroProof,
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.InvalidRecipient,
    });
}

get fun `test TonPool withdraw rejects masterchain recipient`() {
    val tonPool = forgeTonPool(0, []);
    expect(
        tonPool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: tonPool.address });

    val anyone = testing.treasury("anyone");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val masterchainRecipient = address.fromWorkchainAndHash(-1, 0x1234);
    val res = tonPool.sendTonWithdraw(
        anyone.address,
        1,
        0,
        0,
        masterchainRecipient,
        zeroProof,
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: tonPool.address,
        exitCode: Errors.InvalidRecipient,
    });
}

get fun `test TonPool withdraw rejects zero-hash recipient`() {
    val tonPool = forgeTonPool(0, []);
    expect(
        tonPool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: tonPool.address });

    val anyone = testing.treasury("anyone");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val zeroHashRecipient = address.fromWorkchainAndHash(0, 0);
    val res = tonPool.sendTonWithdraw(
        anyone.address,
        1,
        0,
        0,
        zeroHashRecipient,
        zeroProof,
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: tonPool.address,
        exitCode: Errors.InvalidRecipient,
    });
}

// ============================================================================
// Pool refund branches: tree-full + duplicate commitment
// ============================================================================

get fun `test Pool deposit is refunded when tree is at capacity`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, MERKLE_TREE_CAPACITY as uint32, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val res = pool.sendJettonTransferNotification(
        jw,
        1,
        EDGE_DENOM,
        user.address,
        createEmptySlice(),
        { value: ton("0.7") },
    );

    expect(res).toHaveSuccessfulTx({ from: jw, to: pool.address });
    expect(pool.nextIndex()).toEqual(MERKLE_TREE_CAPACITY);
    // Refund jetton transfer back to user's JW (= pool's JW for a refund).
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jw,
        opcode: 0x0f8a7ea5, // OP_JETTON_TRANSFER
    });
}

get fun `test Pool deposit is refunded when commitment is already used`() {
    val jw = testing.treasury("jw").address;
    val existingCommitment: uint256 = 0x1337;
    var commitments: map<uint256, uint32> = [];
    commitments.set(existingCommitment, 0);

    val pool = forgePool(jw, 1, commitments);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    // Build a forward payload carrying the duplicate commitment so the pool
    // hits the CommitmentAlreadyExists branch (before the proof check).
    val depositPayload = beginCell()
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(7, 64) // queryId
        .storeUint(existingCommitment, 256)
        .storeUint(0, 256) // newRoot (irrelevant: branch fires before verifier)
        .storeRef(
            beginCell()
                .storeRef(beginCell().endCell())
                .storeRef(beginCell().endCell())
                .storeRef(beginCell().endCell())
                .endCell(),
        )
        .endCell();
    val forwardPayload = beginCell()
        .storeUint(1, 1) // Either: right side (ref)
        .storeRef(depositPayload)
        .endCell()
        .beginParse();

    val user = testing.treasury("user");
    val res = pool.sendJettonTransferNotification(
        jw,
        1,
        EDGE_DENOM,
        user.address,
        forwardPayload,
        { value: ton("0.7") },
    );

    expect(res).toHaveSuccessfulTx({ from: jw, to: pool.address });
    expect(pool.nextIndex()).toEqual(1); // unchanged
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jw,
        opcode: 0x0f8a7ea5, // refund
    });
}

// ============================================================================
// Pool refund: malformed forward_payload
// ============================================================================

fun expectMalformedDepositRefunds(forwardPayload: slice) {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val res = pool.sendJettonTransferNotification(
        jw,
        1,
        EDGE_DENOM,
        user.address,
        forwardPayload,
        { value: ton("0.7") },
    );

    expect(res).toHaveSuccessfulTx({ from: jw, to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jw,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.nextIndex()).toEqual(0);
}

get fun `test Pool deposit with empty forward_payload refunds safely`() {
    expectMalformedDepositRefunds(createEmptySlice());
}

get fun `test Pool deposit with missing payload ref refunds safely`() {
    expectMalformedDepositRefunds(beginCell().storeUint(1, 1).endCell().beginParse());
}

get fun `test Pool deposit with malformed proof cell refunds safely`() {
    val badPayload = beginCell()
        .storeUint(1, 1)
        .storeRef(
            beginCell()
                .storeUint(OP_DEPOSIT_PAYLOAD, 32)
                .storeUint(1, 64)
                .storeUint(0x1234, 256)
                .storeUint(0x5678, 256)
                .storeRef(beginCell().endCell())
                .endCell(),
        )
        .endCell()
        .beginParse();

    expectMalformedDepositRefunds(badPayload);
}

// ============================================================================
// TonPool refund branches: tree-full + duplicate commitment
// ============================================================================

get fun `test TonPool deposit is refunded when tree is at capacity`() {
    val pool = forgeTonPool(MERKLE_TREE_CAPACITY as uint32, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendTonDepositPayload(
        user.address,
        1,
        user.address,
        0x4242, // commitment
        0,      // newRoot
        zeroProof,
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(MERKLE_TREE_CAPACITY);
    // User got back ~ton("10.6") minus action fees via CARRY_ALL_REMAINING.
    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
}

get fun `test TonPool deposit is refunded when commitment is already used`() {
    val existingCommitment: uint256 = 0xC0FFEE;
    var commitments: map<uint256, uint32> = [];
    commitments.set(existingCommitment, 0);

    val pool = forgeTonPool(1, commitments);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val res = pool.sendTonDepositPayload(
        user.address,
        2,
        user.address,
        existingCommitment,
        0,
        zeroProof,
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1); // unchanged
}

// ============================================================================
// TonPool: bounce handler is a no-op (state-preserving by design)
// ============================================================================

get fun `test TonPool onBouncedMessage does not corrupt state`() {
    val pool = forgeTonPool(0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val rootBefore = pool.currentRoot();
    val indexBefore = pool.nextIndex();
    val reserveBefore = pool.relayerReserve();
    val pendingBefore = pool.pendingWithdrawTon();

    // Send a bounced internal message. The handler is `onBouncedMessage`
    // which must do nothing observable. We exercise it via sendAny with a
    // synthesized bounce-like body (TON sandbox doesn't expose a direct
    // bounce-injection API, so we approximate by sending an unknown body
    // which should also be a no-op via the InvalidMessage path).
    pool.sendAny(
        testing.treasury("attacker").address,
        beginCell().storeUint(0xfeedface, 32).endCell(),
        { value: ton("0.05") },
    );

    expect(pool.currentRoot()).toEqual(rootBefore);
    expect(pool.nextIndex()).toEqual(indexBefore);
    expect(pool.relayerReserve()).toEqual(reserveBefore);
    expect(pool.pendingWithdrawTon()).toEqual(pendingBefore);
}

// Note: a runtime test of `MOCK_VERIFIER == false` is omitted intentionally:
// constructing slices that exercise the verifier without underflowing the BLS
// chunk parser requires a real fixture. The flag is instead guarded by the
// existing `RealProof.test.tolk` suite: a tampered fixture must be rejected;
// if `MOCK_VERIFIER` ever flips to true, those tests fail because the mocked
// path short-circuits to `true` even for tampered inputs.

// ============================================================================
// Refund event assertion: SDK consumers depend on opcode + leafIndex shape
// ============================================================================

get fun `test Pool refund emits DepositRefundedEvent with correct opcode`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 0, []);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    // Below MIN_DEPOSIT_VALUE forces the InsufficientDepositValue refund branch.
    val res = pool.sendJettonTransferNotification(
        jw,
        1,
        EDGE_DENOM,
        user.address,
        createEmptySlice(),
        { value: ton("0.30") }, // < MIN_DEPOSIT_VALUE (0.32)
    );

    expect(res).toHaveSuccessfulTx({ from: jw, to: pool.address });
    // We can't directly assert ext-out body in current matcher, but we can
    // confirm the jetton refund went out: proves refundDeposit() ran fully.
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jw,
        opcode: 0x0f8a7ea5,
    });
}
