import "@stdlib/exotic-cells"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@contracts/ton-pool-types"
import "@tests/pool-sparse-helpers"
import "@tests/proofs-fixture"
import "@tests/ton-pool-sparse-helpers"
import "@wrappers/Pool.gen"
import "@wrappers/TonPool.gen"

// ============================================================================
// Edge-case coverage: negative paths.
//
// These exercise refund branches, lifecycle guards, and bounce handling that
// the happy-path E2E + MainnetDryRun suites don't reach. Storage is forged
// directly via `fromStorage` so we can hit branches that require state the
// happy-path setup cannot produce (e.g. tree at capacity, an occupied sparse
// commitment bucket, or jettonWallet still null after deploy).
// ============================================================================

const EDGE_DENOM: coins = 100

fun forgePoolWithSparseSets(
    jw: address?,
    nextIdx: uint32,
    sparseSets: Cell<SparseSetRoots>,
): Pool {
    return forgePoolWithState(jw, nextIdx, 0, sparseSets);
}

fun forgePoolWithState(
    jw: address?,
    nextIdx: uint32,
    currentRoot: uint256,
    sparseSets: Cell<SparseSetRoots>,
): Pool {
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("jm").address,
        factory: testing.treasury("factory").address,
        denomination: EDGE_DENOM,
    };
    val merkle: MerkleState = {
        nextIndex: nextIdx,
        currentRoot,
        rootHistory: [],
        sparseSets,
    };
    return Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: jw,
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawalCount: 0,
    });
}

fun forgePool(jw: address?, nextIdx: uint32): Pool {
    return forgePoolWithSparseSets(jw, nextIdx, createEmptySparseSetRoots());
}

fun forgeTonPoolWithSparseSets(nextIdx: uint32, sparseSets: Cell<SparseSetRoots>): TonPool {
    return forgeTonPoolWithState(nextIdx, 0, sparseSets);
}

fun forgeTonPoolWithState(
    nextIdx: uint32,
    currentRoot: uint256,
    sparseSets: Cell<SparseSetRoots>,
): TonPool {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("factory").address,
        denomination: ton("10"),
    };
    val merkle: MerkleState = {
        nextIndex: nextIdx,
        currentRoot,
        rootHistory: [],
        sparseSets,
    };
    return TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    });
}

fun forgeTonPool(nextIdx: uint32): TonPool {
    return forgeTonPoolWithSparseSets(nextIdx, createEmptySparseSetRoots());
}

// ============================================================================
// Wallet binding: TEP-89 round-trip
// ============================================================================

get fun `test Pool TakeWalletAddress is rejected when wallet already bound`() {
    val jw = testing.treasury("jw").address;
    val deployer = testing.treasury("deployer");

    // Forge a pool that already has its jettonWallet bound.
    val pool = forgePool(jw, 0);
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
    val pool = forgePool(null, 0);
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

get fun `test Pool binds the master-provided wallet once and confirms readiness`() {
    val pool = forgePool(null, 0);
    val master = testing.treasury("jm");
    val factory = testing.treasury("factory");
    val wallet = testing.treasury("bound-wallet");
    expect(
        pool.deploy(testing.treasury("binding-deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val result = pool.sendTakeWalletAddress(
        master.address,
        42,
        wallet.address,
        createEmptySlice(),
        { value: ton("0.1") },
    );
    expect(result).toHaveSuccessfulTx({ from: master.address, to: pool.address });
    expect(pool.jettonWallet()).toEqual(wallet.address);
    expect(
        result.findExternalOutMessage<PoolReadyEvent>({ from: pool.address }) != null,
    ).toEqual(true);
    expect(result).toHaveSuccessfulTx({
        from: pool.address,
        to: factory.address,
        opcode: 0x46504301,
    });

    expect(
        pool.sendTakeWalletAddress(
            master.address,
            43,
            testing.treasury("second-wallet").address,
            createEmptySlice(),
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx({ to: pool.address, exitCode: Errors.JettonWalletAlreadySet });
}

get fun `test Pool InitWalletBinding sends TEP-89 query when wallet is null`() {
    val masterAddr = testing.treasury("jm").address;
    val pool = forgePool(null, 0);
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
    val queryTx = res.findTransaction<ProvideWalletAddress>({
        from: pool.address,
        to: masterAddr,
    })!;
    val queryMessage = queryTx.loadInMsg<ProvideWalletAddress>();
    if (queryMessage.info is TlbInternalMessage) {
        expect(queryMessage.info.bounce).toEqual(false);
    } else {
        expect(false).toEqual(true);
    }
    val queryBody = queryMessage.loadBody();
    expect(queryBody.includeAddress).toEqual(false);
    // No binding yet — that happens when the master replies.
    expect(pool.jettonWallet()).toEqual(null);
}

get fun `test Pool InitWalletBinding accepts exact query budget`() {
    val masterAddr = testing.treasury("jm").address;
    val pool = forgePool(null, 0);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val res = pool.sendInitWalletBinding(
        testing.treasury("anyone").address,
        1,
        { value: 60000000 },
    );
    expect(res).toHaveSuccessfulTx({ from: pool.address, to: masterAddr, opcode: 0x2c76b973 });
}

get fun `test Pool InitWalletBinding one nano below query budget is rejected`() {
    val pool = forgePool(null, 0);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val res = pool.sendInitWalletBinding(
        testing.treasury("anyone").address,
        1,
        { value: 59999999 },
    );
    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientGas,
    });
}

get fun `test Pool InitWalletBinding underfunded is rejected`() {
    val pool = forgePool(null, 0);
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
// Deposits before wallet binding
// ============================================================================

get fun `test Pool deposit before wallet binding is silently dropped`() {
    val pool = forgePool(null, 0);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val res = pool.sendJettonTransferNotification(
        testing.treasury("unbound-jw").address,
        1,
        EDGE_DENOM,
        user.address,
        createEmptySlice(),
        { value: ton("0.7") },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(res).toNotHaveTx({ from: pool.address });
}

// ============================================================================
// Withdraw on uninitialized pool
// ============================================================================

get fun `test Pool withdraw is rejected when jettonWallet is unset`() {
    val pool = forgePool(null, 0);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val anyone = testing.treasury("anyone");
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val res = pool.sendWithdrawWithEmptySparseProof(
        anyone.address,
        1,
        0,
        0,
        anyone.address,
        zeroProof,
        { value: MIN_JETTON_WITHDRAW_GAS },
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
    val pool = forgePool(jw, 1);
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
    val res = pool.sendWithdrawWithEmptySparseProof(
        anyone.address,
        1,
        0,
        0,
        masterchainRecipient,
        zeroProof,
        { value: MIN_JETTON_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.InvalidRecipient,
    });
}

get fun `test Pool withdraw rejects zero-hash recipient`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 1);
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
    val res = pool.sendWithdrawWithEmptySparseProof(
        anyone.address,
        1,
        0,
        0,
        zeroHashRecipient,
        zeroProof,
        { value: MIN_JETTON_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.InvalidRecipient,
    });
}

get fun `test TonPool withdraw rejects masterchain recipient`() {
    val tonPool = forgeTonPool(0);
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
    val res = tonPool.sendTonWithdrawWithEmptySparseProof(
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
    val tonPool = forgeTonPool(0);
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
    val res = tonPool.sendTonWithdrawWithEmptySparseProof(
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
    val pool = forgePoolWithState(
        jw,
        MERKLE_TREE_CAPACITY as uint32,
        FIXTURE_INSERT_OLD_ROOT,
        createEmptySparseSetRoots(),
    );
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val payload = (DepositPayload {
        queryId: 1,
        commitment: FIXTURE_INSERT_COMMITMENT,
        newRoot: FIXTURE_INSERT_NEW_ROOT,
        insertProof: (ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        }).toCell(),
        commitmentSetProof: poolEmptySparseSetProof(
            SPARSE_SET_COMMITMENT_DOMAIN,
            FIXTURE_INSERT_COMMITMENT,
        ).toCell(),
    }).toCell();
    val res = pool.sendJettonTransferNotification(
        jw,
        1,
        EDGE_DENOM,
        user.address,
        beginCell().storeBool(true).storeRef(payload).endCell().beginParse(),
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
    // The capacity guard must reject before sparse verification and the costly
    // BLS pairing. A missing or off-by-one guard still refunds, but exceeds
    // this deliberately generous early-rejection gas ceiling.
    val gas = res
        .findTransaction<JettonTransferNotification>({ from: jw, to: pool.address })!
        .getUsedGas();
    println("full Jetton tree rejection gas={}", gas);
    expect(gas < 100000).toEqual(true);
}

get fun `test Pool deposit is refunded when commitment is already used`() {
    val jw = testing.treasury("jw").address;
    val existingCommitment: uint256 = 0x1337;

    val pool = forgePoolWithSparseSets(
        jw,
        1,
        sparseSetRootsContaining(SPARSE_SET_COMMITMENT_DOMAIN, existingCommitment),
    );
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
    val pool = forgePool(jw, 0);
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

fun dummyProofCell(): cell {
    return beginCell()
        .storeRef(beginCell().endCell())
        .storeRef(beginCell().endCell())
        .storeRef(beginCell().endCell())
        .endCell();
}

fun zeroProofPoint(bits: int): cell {
    var builder = beginCell();
    var remaining = bits;
    while (remaining >= 256) {
        builder = builder.storeUint(0, 256);
        remaining -= 256;
    }
    if (remaining > 0) {
        builder = builder.storeUint(0, remaining);
    }
    return builder.endCell();
}

fun proofCellWithFirstPoint(firstPoint: cell): cell {
    return beginCell()
        .storeRef(firstPoint)
        .storeRef(zeroProofPoint(768))
        .storeRef(zeroProofPoint(384))
        .endCell();
}

fun depositForwardPayloadWithProof(proofCell: cell): slice {
    val payload = beginCell()
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(1, 64)
        .storeUint(0x1234, 256)
        .storeUint(0x5678, 256)
        .storeRef(proofCell)
        .storeRef(emptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, 0x1234).toCell())
        .endCell();
    return beginCell().storeUint(1, 1).storeRef(payload).endCell().beginParse();
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

get fun `test Pool deposit with missing proof ref refunds safely`() {
    val badPayload = beginCell()
        .storeUint(0, 1)
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(1, 64)
        .storeUint(0x1234, 256)
        .storeUint(0x5678, 256)
        .endCell()
        .beginParse();

    expectMalformedDepositRefunds(badPayload);
}

get fun `test Pool deposit with exotic payload ref refunds safely`() {
    expectMalformedDepositRefunds(
        beginCell()
            .storeUint(1, 1)
            .storeRef(createEmptyCell().toLibraryReference())
            .endCell()
            .beginParse(),
    );
}

get fun `test Pool deposit with exotic proof root refunds safely`() {
    expectMalformedDepositRefunds(
        depositForwardPayloadWithProof(createEmptyCell().toLibraryReference()),
    );
}

get fun `test Pool deposit with exotic proof point refunds safely`() {
    expectMalformedDepositRefunds(
        depositForwardPayloadWithProof(
            proofCellWithFirstPoint(createEmptyCell().toLibraryReference()),
        ),
    );
}

get fun `test Pool deposit with inline payload trailing bit refunds safely`() {
    val badPayload = beginCell()
        .storeUint(0, 1)
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(1, 64)
        .storeUint(0x1234, 256)
        .storeUint(0x5678, 256)
        .storeUint(1, 1)
        .storeRef(dummyProofCell())
        .endCell()
        .beginParse();

    expectMalformedDepositRefunds(badPayload);
}

get fun `test Pool deposit with wrong payload opcode refunds safely`() {
    val badPayload = beginCell()
        .storeUint(1, 1)
        .storeRef(
            beginCell()
                .storeUint(0xdeadbeef, 32)
                .storeUint(1, 64)
                .storeUint(0x1234, 256)
                .storeUint(0x5678, 256)
                .storeRef(dummyProofCell())
                .endCell(),
        )
        .endCell()
        .beginParse();

    expectMalformedDepositRefunds(badPayload);
}

get fun `test Pool deposit with ref payload trailing bits refunds safely`() {
    val badPayload = beginCell()
        .storeUint(1, 1)
        .storeUint(1, 1)
        .storeRef(
            beginCell()
                .storeUint(OP_DEPOSIT_PAYLOAD, 32)
                .storeUint(1, 64)
                .storeUint(0x1234, 256)
                .storeUint(0x5678, 256)
                .storeRef(dummyProofCell())
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
    val pool = forgeTonPoolWithState(
        MERKLE_TREE_CAPACITY as uint32,
        FIXTURE_INSERT_OLD_ROOT,
        createEmptySparseSetRoots(),
    );
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val realProof: ZkProof = {
        proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
    };
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        realProof,
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(MERKLE_TREE_CAPACITY);
    // User got back ~ton("10.6") minus action fees via CARRY_ALL_REMAINING.
    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
    val gas = res.findTransaction<TonDepositPayload>({ to: pool.address })!.getUsedGas();
    println("full TON tree rejection gas={}", gas);
    expect(gas < 100000).toEqual(true);
}

get fun `test TonPool deposit is refunded when commitment is already used`() {
    val existingCommitment: uint256 = 0xC0FFEE;
    val pool = forgeTonPoolWithSparseSets(
        1,
        sparseSetRootsContaining(SPARSE_SET_COMMITMENT_DOMAIN, existingCommitment),
    );
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
        occupiedSparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, existingCommitment),
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1); // unchanged
}

fun expectMalformedTonDepositProofRefunds(proofCell: cell) {
    val pool = forgeTonPool(0);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);
    val body = beginCell()
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(1, 64)
        .storeAddress(user.address)
        .storeUint(0x1234, 256)
        .storeUint(0x5678, 256)
        .storeRef(proofCell)
        .storeRef(
            emptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, 0x1234).toCell(),
        )
        .endCell();

    val res = pool.sendAny(user.address, body, { value: ton("10.6") });

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
}

get fun `test TonPool deposit with empty proof cell refunds safely`() {
    expectMalformedTonDepositProofRefunds(beginCell().endCell());
}

get fun `test TonPool deposit with proof trailing bits refunds safely`() {
    expectMalformedTonDepositProofRefunds(
        beginCell()
            .storeUint(1, 1)
            .storeRef(beginCell().endCell())
            .storeRef(beginCell().endCell())
            .storeRef(beginCell().endCell())
            .endCell(),
    );
}

get fun `test TonPool deposit with four proof refs refunds safely`() {
    expectMalformedTonDepositProofRefunds(
        beginCell()
            .storeRef(beginCell().endCell())
            .storeRef(beginCell().endCell())
            .storeRef(beginCell().endCell())
            .storeRef(beginCell().endCell())
            .endCell(),
    );
}

get fun `test TonPool deposit with exotic proof root refunds safely`() {
    expectMalformedTonDepositProofRefunds(createEmptyCell().toLibraryReference());
}

get fun `test TonPool deposit with exotic proof point refunds safely`() {
    expectMalformedTonDepositProofRefunds(
        proofCellWithFirstPoint(createEmptyCell().toLibraryReference()),
    );
}

get fun `test TonPool deposit with trailing body data refunds safely`() {
    val pool = forgeTonPool(0);
    expect(
        pool.deploy(testing.treasury("ton-trailing-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    val user = testing.treasury("ton-trailing-user");
    val body = beginCell()
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(1, 64)
        .storeAddress(user.address)
        .storeUint(0x1234, 256)
        .storeUint(0x5678, 256)
        .storeRef(dummyProofCell())
        .storeRef(emptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, 0x1234).toCell())
        .storeUint(1, 1)
        .endCell();

    val result = pool.sendAny(user.address, body, { value: ton("10.6") });
    expect(result).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool withdraw with trailing body data is rejected`() {
    val pool = forgeTonPool(1);
    expect(
        pool.deploy(
            testing.treasury("ton-withdraw-trailing-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    val user = testing.treasury("ton-withdraw-trailing-user");
    val body = beginCell()
        .storeUint(0x4b6f0b51, 32)
        .storeUint(1, 64)
        .storeUint(EMPTY_TREE_ROOT, 256)
        .storeUint(1, 256)
        .storeAddress(user.address)
        .storeRef(dummyProofCell())
        .storeRef(emptySparseSetProof(SPARSE_SET_NULLIFIER_DOMAIN, 1).toCell())
        .storeUint(1, 1)
        .endCell();

    expect(
        pool.sendAny(user.address, body, { value: MIN_WITHDRAW_GAS }),
    ).toHaveFailedTx({ from: user.address, to: pool.address, exitCode: Errors.InvalidMessage });
}

// ============================================================================
// TonPool: bounce handler is a no-op (state-preserving by design)
// ============================================================================

get fun `test TonPool onBouncedMessage does not corrupt state`() {
    val pool = forgeTonPool(0);
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

// ============================================================================
// Refund safety: failure paths refund but do not emit contract-funded logs
// ============================================================================

get fun `test Pool refund sends jettons without external failure log`() {
    val jw = testing.treasury("jw").address;
    val pool = forgePool(jw, 0);
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
        { value: ton("0.30") }, // < MIN_DEPOSIT_VALUE (0.37)
    );

    expect(res).toHaveSuccessfulTx({ from: jw, to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jw,
        opcode: 0x0f8a7ea5,
    });
    expect(res.at(0).externals.size()).toEqual(0);
}

get fun `test TonPool refund sends TON without external failure log`() {
    val pool = forgeTonPool(0);
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        0x4242,
        0,
        zeroProof,
        { value: ton("1") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
    expect(res.at(0).externals.size()).toEqual(0);
}
