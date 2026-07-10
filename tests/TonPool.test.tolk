import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/deployment-types"
import "@contracts/errors"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@contracts/ton-pool-types"
import "@tests/account-balance-helpers"
import "@tests/proofs-fixture"
import "@tests/ton-pool-sparse-helpers"
import "@wrappers/TonPool.gen"

const TEST_TON_DENOM: coins = 10000000000 // 10 TON

fun fixtureRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun fixtureRecipientHighByteAlias(): address {
    return address.fromWorkchainAndHash(
        0,
        FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW + (1 << 248),
    );
}

fun freshTonPoolWithFactory(factoryAddr: address): TonPool {
    val identity: TonPoolIdentity = { factory: factoryAddr, denomination: TEST_TON_DENOM };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: FIXTURE_INSERT_OLD_ROOT,
        rootHistory: [],
        sparseSets: createEmptySparseSetRoots(),
    };
    return TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    });
}

fun freshTonPoolWithRoot(currentRoot: uint256): TonPool {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("factory").address,
        denomination: TEST_TON_DENOM,
    };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot,
        rootHistory: [],
        sparseSets: createEmptySparseSetRoots(),
    };
    return TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    });
}

fun freshTonPoolWithCommitment(
    nextIndex: uint32,
    currentRoot: uint256,
    commitment: uint256,
): TonPool {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("factory").address,
        denomination: TEST_TON_DENOM,
    };
    val merkle: MerkleState = {
        nextIndex,
        currentRoot,
        rootHistory: [],
        sparseSets: sparseSetRootsContaining(SPARSE_SET_COMMITMENT_DOMAIN, commitment),
    };
    return TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    });
}

fun freshTonPool(): TonPool {
    return freshTonPoolWithFactory(testing.treasury("factory").address);
}

fun setupDeployedTonPoolWithFactoryAndValue(
    factoryAddr: address,
    deployValue: coins,
): (TonPool, Treasury) {
    val deployer = testing.treasury("deployer");
    val pool = freshTonPoolWithFactory(factoryAddr);
    val res = pool.deploy(deployer.address, { value: deployValue });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return (pool, deployer);
}

fun setupDeployedTonPoolWithValue(deployValue: coins): (TonPool, Treasury) {
    return setupDeployedTonPoolWithFactoryAndValue(
        testing.treasury("factory").address,
        deployValue,
    );
}

fun setupDeployedTonPool(): (TonPool, Treasury) {
    return setupDeployedTonPoolWithValue(ton("1"));
}

fun setupDepositTonPoolWithExactBalance(
    factoryAddr: address,
    targetBalance: coins,
): TonPool {
    val (pool, _) = setupDeployedTonPoolWithFactoryAndValue(
        factoryAddr,
        targetBalance + ton("0.1"),
    );
    setExactTestAccountBalance(pool.address, targetBalance);
    expect(testing.getAccountBalance(pool.address)).toEqual(targetBalance);
    return pool;
}

fun firstTonDepositBalanceThreshold(): coins {
    return POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT + POOL_SPARSE_BUCKET_RENT +
    RELAYER_REIMBURSEMENT +
    POOL_DEPOSIT_FEE_MARGIN -
    MIN_DEPOSIT_VALUE;
}

fun sendValidFirstTonDeposit(
    pool: TonPool,
    user: Treasury,
    value: coins = TEST_TON_DENOM + MIN_DEPOSIT_VALUE,
): SendResultList {
    return pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value },
    );
}

fun setupWithdrawStateTonPool(
    relayerReserve: coins,
    pendingWithdrawTon: coins,
    deployValue: coins,
    useHistoricalRoot: bool,
): TonPool {
    return setupWithdrawStateTonPoolWithFactory(
        testing.treasury("factory").address,
        relayerReserve,
        pendingWithdrawTon,
        deployValue,
        useHistoricalRoot,
    );
}

fun setupWithdrawStateTonPoolWithFactory(
    factoryAddr: address,
    relayerReserve: coins,
    pendingWithdrawTon: coins,
    deployValue: coins,
    useHistoricalRoot: bool,
): TonPool {
    val identity: TonPoolIdentity = { factory: factoryAddr, denomination: TEST_TON_DENOM };
    var rootHistory: map<uint32, uint256> = [];
    if (useHistoricalRoot) {
        rootHistory.set(0, FIXTURE_WITHDRAW_ROOT);
    }
    val merkle: MerkleState = {
        nextIndex: 1,
        currentRoot: useHistoricalRoot ? FIXTURE_WITHDRAW_ROOT + 1 : FIXTURE_WITHDRAW_ROOT,
        rootHistory,
        sparseSets: createEmptySparseSetRoots(),
    };
    val pool = TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve,
        pendingWithdrawTon,
        merkle: merkle.toCell(),
    });
    val res = pool.deploy(testing.treasury("deployer").address, { value: deployValue });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

fun setupWithdrawStateTonPoolWithRootHistory(
    relayerReserve: coins,
    pendingWithdrawTon: coins,
    deployValue: coins,
    currentRoot: uint256,
    rootHistory: map<uint32, uint256>,
): TonPool {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("factory").address,
        denomination: TEST_TON_DENOM,
    };
    val merkle: MerkleState = {
        nextIndex: 2,
        currentRoot,
        rootHistory,
        sparseSets: createEmptySparseSetRoots(),
    };
    val pool = TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve,
        pendingWithdrawTon,
        merkle: merkle.toCell(),
    });
    val res = pool.deploy(testing.treasury("deployer").address, { value: deployValue });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

fun setupWithdrawStateTonPoolWithExactBalance(
    factoryAddr: address,
    targetBalance: coins,
): TonPool {
    val pool = setupWithdrawStateTonPoolWithFactory(
        factoryAddr,
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        targetBalance + ton("0.1"),
        false,
    );
    setExactTestAccountBalance(pool.address, targetBalance);
    expect(testing.getAccountBalance(pool.address)).toEqual(targetBalance);
    return pool;
}

fun setupWithdrawStateTonPoolWithReservesAndExactBalance(
    factoryAddr: address,
    relayerReserve: coins,
    pendingWithdrawTon: coins,
    targetBalance: coins,
): TonPool {
    val pool = setupWithdrawStateTonPoolWithFactory(
        factoryAddr,
        relayerReserve,
        pendingWithdrawTon,
        targetBalance + ton("0.1"),
        false,
    );
    setExactTestAccountBalance(pool.address, targetBalance);
    expect(testing.getAccountBalance(pool.address)).toEqual(targetBalance);
    return pool;
}

fun setupUnderfundedWithdrawTonPool(): TonPool {
    return setupWithdrawStateTonPool(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("0.10"),
        false,
    );
}

fun fundedTonPool(): TonPool {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");
    expect(
        pool.sendTonDepositWithEmptySparseProof(
            user.address,
            1,
            user.address,
            FIXTURE_INSERT_COMMITMENT,
            FIXTURE_INSERT_NEW_ROOT,
            ZkProof {
                proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
                proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
                proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
            },
            { value: ton("10.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });
    return pool;
}

fun realWithdrawProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureWithdrawProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

fun realInsertProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
    };
}

fun insertProofWith(proofA: slice, proofB: slice, proofC: slice): ZkProof {
    return {
        proofA: (G1Point { raw: proofA }).toCell(),
        proofB: (G2Point { raw: proofB }).toCell(),
        proofC: (G1Point { raw: proofC }).toCell(),
    };
}

fun withdrawProofWith(proofA: slice, proofB: slice, proofC: slice): ZkProof {
    return {
        proofA: (G1Point { raw: proofA }).toCell(),
        proofB: (G2Point { raw: proofB }).toCell(),
        proofC: (G1Point { raw: proofC }).toCell(),
    };
}

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

fun expectTonDepositProofRejected(proof: ZkProof, factoryAddr: address) {
    val (pool, _) = setupDeployedTonPoolWithFactoryAndValue(factoryAddr, ton("1"));
    val user = testing.treasury("user");
    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        proof,
        { value: ton("10.6") },
    );
    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_OLD_ROOT);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    expect(pool.withdrawalCount()).toEqual(0);
}

fun expectTonWithdrawProofRejected(proof: ZkProof, factoryAddr: address) {
    val pool = setupWithdrawStateTonPoolWithFactory(
        factoryAddr,
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        false,
    );
    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        proof,
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InvalidWithdrawProof,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool deploys with initial state`() {
    val (pool, _) = setupDeployedTonPool();

    expect(pool.factory()).toEqual(testing.treasury("factory").address);
    expect(pool.denomination()).toEqual(TEST_TON_DENOM);
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    expect(pool.treeDepth()).toEqual(MERKLE_TREE_DEPTH);
}

get fun `test TonPool rejects unknown non-empty messages`() {
    val (pool, _) = setupDeployedTonPool();
    val sender = testing.treasury("unknown-message-sender");
    val result = pool.sendAny(
        sender.address,
        beginCell().storeUint(0xdeadbeef, 32).endCell(),
        { value: ton("0.05") },
    );
    expect(result).toHaveFailedTx({
        from: sender.address,
        to: pool.address,
        exitCode: Errors.InvalidMessage,
    });
}

get fun `test TonPool init surplus stays on pool (no factory forward)`() {
    val factoryAddr = testing.treasury("factory").address;
    val pool = freshTonPool();
    val factoryBalBefore = testing.getAccountBalance(factoryAddr);

    val res = pool.deploy(testing.treasury("deployer").address, { value: ton("1") });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });

    // Trustless-no-fee model: factory receives nothing on pool init.
    val factoryBalAfter = testing.getAccountBalance(factoryAddr);
    expect(factoryBalAfter).toEqual(factoryBalBefore);

    // The 1 TON deploy value stays on the pool as a storage-rent buffer
    // above POOL_TON_RESERVE.
    val poolBal = testing.getAccountBalance(pool.address);
    expect(poolBal > POOL_TON_RESERVE).toEqual(true);
}

get fun `test TonPool deployment trigger sends authenticated factory callback`() {
    val factory = testing.treasury("ton-confirm-factory");
    val caller = testing.treasury("ton-confirm-caller");
    val (pool, _) = setupDeployedTonPoolWithFactoryAndValue(factory.address, ton("1"));

    val result = pool.sendTonPoolConfirmPoolDeployment(
        caller.address,
        77,
        { value: ton("0.02") },
    );
    expect(result).toHaveSuccessfulTx({ from: caller.address, to: pool.address });
    val callbackTx = result.findTransaction<PoolDeployConfirmed>({
        from: pool.address,
        to: factory.address,
    });
    expect(callbackTx).toBeNotNull();
    val callback = callbackTx!.loadInMsg<PoolDeployConfirmed>().loadBody();
    expect(callback.queryId).toEqual(77);
    expect(callback.jettonMaster).toEqual(null);
    expect(callback.denomination).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool deployment trigger is caller funded`() {
    val factory = testing.treasury("ton-confirm-low-factory");
    val caller = testing.treasury("ton-confirm-low-caller");
    val (pool, _) = setupDeployedTonPoolWithFactoryAndValue(factory.address, ton("1"));

    val result = pool.sendTonPoolConfirmPoolDeployment(
        caller.address,
        1,
        { value: ton("0.02") - 1 },
    );
    expect(result).toHaveFailedTx({
        from: caller.address,
        to: pool.address,
        exitCode: Errors.InsufficientGas,
    });
}

get fun `test TonPool deployment trigger rejects trailing data`() {
    val caller = testing.treasury("ton-confirm-trailing-caller");
    val (pool, _) = setupDeployedTonPool();
    val body = beginCell().storeUint(0x46504300, 32).storeUint(9, 64).storeUint(1, 1).endCell();

    val result = pool.sendAny(caller.address, body, { value: ton("0.03") });
    expect(result).toHaveFailedTx({ from: caller.address, to: pool.address, exitCode: 9 });
}

get fun `test TonPool deposit below floor is refunded`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: ton("9") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);

    val refundTx = res.findTransaction({
        from: pool.address,
        to: user.address,
    })!;
    val refundMsg = refundTx.messages.load().inMsg.unwrap().load();
    expect(refundMsg.info.bounce).toEqual(false);

    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
}

get fun `test TonPool withdraw with insufficient gas is rejected`() {
    val (pool, _) = setupDeployedTonPool();
    val zeroProof: ZkProof = {
        proofA: (G1Point { raw: createEmptySlice() }).toCell(),
        proofB: (G2Point { raw: createEmptySlice() }).toCell(),
        proofC: (G1Point { raw: createEmptySlice() }).toCell(),
    };

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        1,
        0,
        0,
        testing.treasury("recipient").address,
        zeroProof,
        { value: ton("0.05") },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientGas,
    });
}

get fun `test TonPool deposit at floor refunds if pool reserve is underfunded`() {
    val (pool, _) = setupDeployedTonPoolWithValue(ton("0.01"));
    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: TEST_TON_DENOM + MIN_DEPOSIT_VALUE },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);

    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
}

get fun `test TonPool deposit succeeds at exact reserve threshold`() {
    // After the first deposit the pool has one history slot and one sparse
    // commitment bucket. The inbound value already carries the denomination
    // and MIN_DEPOSIT_VALUE, so only the missing runway stays pre-funded.
    val targetBalance = firstTonDepositBalanceThreshold();
    val pool = setupDepositTonPoolWithExactBalance(
        testing.treasury("ton-deposit-exact-factory").address,
        targetBalance,
    );
    val user = testing.treasury("user");

    val res = sendValidFirstTonDeposit(pool, user);

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
    expect(
        testing.getAccountBalance(pool.address) >=
        pool.rentRunway() + pool.relayerReserve() + pool.pendingWithdrawTon(),
    ).toEqual(true);
}

get fun `test TonPool deposit rejects one nano below reserve threshold`() {
    val pool = setupDepositTonPoolWithExactBalance(
        testing.treasury("ton-deposit-below-factory").address,
        firstTonDepositBalanceThreshold() - 1,
    );
    val result = sendValidFirstTonDeposit(pool, testing.treasury("ton-deposit-below-user"));

    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool deposit excess cannot cross a one-nano reserve deficit`() {
    val pool = setupDepositTonPoolWithExactBalance(
        testing.treasury("ton-deposit-excess-edge-factory").address,
        firstTonDepositBalanceThreshold() - 1,
    );
    val result = sendValidFirstTonDeposit(
        pool,
        testing.treasury("ton-deposit-excess-edge-user"),
        TEST_TON_DENOM + MIN_DEPOSIT_VALUE + 1,
    );

    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool otherwise valid deposit with trailing data only is refunded`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("ton-valid-trailing-user");
    val body = beginCell()
        .storeSlice(
            (TonDepositPayload {
                queryId: 1,
                fromUser: user.address,
                commitment: FIXTURE_INSERT_COMMITMENT,
                newRoot: FIXTURE_INSERT_NEW_ROOT,
                insertProof: realInsertProof().toCell(),
                commitmentSetProof: emptySparseSetProof(
                    SPARSE_SET_COMMITMENT_DOMAIN,
                    FIXTURE_INSERT_COMMITMENT,
                ).toCell(),
            })
                .toCell()
                .beginParse(),
        )
        .storeBool(true)
        .endCell();

    val result = pool.sendAny(user.address, body, { value: TEST_TON_DENOM + MIN_DEPOSIT_VALUE });
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool deposit surplus cannot mask underfunded reserve`() {
    val (pool, _) = setupDeployedTonPoolWithValue(ton("0.01"));
    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: TEST_TON_DENOM + MIN_DEPOSIT_VALUE + ton("0.02") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
}

get fun `test TonPool deposit with valid proof inserts commitment + earmarks`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_NEW_ROOT);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool deposit rejects malformed raw insert proof points`() {
    expectTonDepositProofRejected(
        insertProofWith(underLengthG1(), fixtureInsertProofB(), fixtureInsertProofC()),
        testing.treasury("ton-insert-proof-a-short").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(fixtureInsertProofA(), overLengthG2(), fixtureInsertProofC()),
        testing.treasury("ton-insert-proof-b-long").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(
            fixtureInsertProofA(),
            withExtraRef(fixtureInsertProofB()),
            fixtureInsertProofC(),
        ),
        testing.treasury("ton-insert-proof-b-ref").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(
            fixtureInsertProofA(),
            fixtureInsertProofB(),
            withExtraRef(fixtureInsertProofC()),
        ),
        testing.treasury("ton-insert-proof-c-ref").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(invalidNonZeroG1(), fixtureInsertProofB(), fixtureInsertProofC()),
        testing.treasury("ton-insert-proof-a-invalid").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(fixtureInsertProofA(), invalidNonZeroG2(), fixtureInsertProofC()),
        testing.treasury("ton-insert-proof-b-invalid").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(fixtureInsertProofA(), fixtureInsertProofB(), invalidNonZeroG1()),
        testing.treasury("ton-insert-proof-c-invalid").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(zeroG1(), fixtureInsertProofB(), fixtureInsertProofC()),
        testing.treasury("ton-insert-proof-a-zero").address,
    );
    expectTonDepositProofRejected(
        insertProofWith(fixtureInsertProofA(), zeroG2(), fixtureInsertProofC()),
        testing.treasury("ton-insert-proof-b-zero").address,
    );
}

get fun `test TonPool deposit rejects public inputs at scalar field order`() {
    val user = testing.treasury("user");

    val rootAtR = freshTonPoolWithRoot(BLS12_381_R);
    expect(
        rootAtR.deploy(testing.treasury("deployer-root-r").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: rootAtR.address });
    val rootRes = rootAtR.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        insertProofWith(fixtureInsertProofA(), fixtureInsertProofB(), fixtureInsertProofC()),
        { value: ton("10.6") },
    );
    expect(rootRes).toHaveSuccessfulTx({ to: rootAtR.address });
    expect(rootAtR.nextIndex()).toEqual(0);

    val (newRootAtR, _) = setupDeployedTonPoolWithFactoryAndValue(
        testing.treasury("ton-new-root-r-factory").address,
        ton("1"),
    );
    val newRootRes = newRootAtR.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        BLS12_381_R,
        insertProofWith(fixtureInsertProofA(), fixtureInsertProofB(), fixtureInsertProofC()),
        { value: ton("10.6") },
    );
    expect(newRootRes).toHaveSuccessfulTx({ to: newRootAtR.address });
    expect(newRootAtR.nextIndex()).toEqual(0);

    val (commitmentAtR, _) = setupDeployedTonPoolWithFactoryAndValue(
        testing.treasury("ton-commitment-r-factory").address,
        ton("1"),
    );
    val commitmentRes = commitmentAtR.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        BLS12_381_R,
        FIXTURE_INSERT_NEW_ROOT,
        insertProofWith(fixtureInsertProofA(), fixtureInsertProofB(), fixtureInsertProofC()),
        { value: ton("10.6") },
    );
    expect(commitmentRes).toHaveSuccessfulTx({ to: commitmentAtR.address });
    expect(commitmentAtR.nextIndex()).toEqual(0);
}

get fun `test TonPool duplicate commitment guard fires before valid proof`() {
    val pool = freshTonPoolWithCommitment(
        0,
        FIXTURE_INSERT_OLD_ROOT,
        FIXTURE_INSERT_COMMITMENT,
    );
    expect(
        pool.deploy(testing.treasury("deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });

    val user = testing.treasury("user");
    val res = pool.sendTonDepositPayload(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        insertProofWith(fixtureInsertProofA(), fixtureInsertProofB(), fixtureInsertProofC()),
        occupiedSparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, FIXTURE_INSERT_COMMITMENT),
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_OLD_ROOT);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool deposit refunds a stale sparse-set witness`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("stale-deposit-user");

    val res = pool.sendTonDepositPayload(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        insertProofWith(fixtureInsertProofA(), fixtureInsertProofB(), fixtureInsertProofC()),
        staleSparseSetProof(1),
        { value: ton("10.6") },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(
        pool.sparseRoot(
            SPARSE_SET_COMMITMENT_DOMAIN,
            sparseSetBucketId(FIXTURE_INSERT_COMMITMENT),
        ),
    ).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool deposit at exact floor emits NO excess refund`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");

    // Attach exactly denom + MIN_DEPOSIT_VALUE: depositExcess = 0, the refund
    // branch must be skipped (no zero-value pool→user message).
    val attached = TEST_TON_DENOM + MIN_DEPOSIT_VALUE;
    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: attached },
    );
    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);

    // No refund tx from pool back to the depositing user.
    expect(res).toNotHaveTx({ from: pool.address, to: user.address });
    val depositTx = res.findTransaction<TonDepositPayload>({
        from: user.address,
        to: pool.address,
    })!;
    val description = depositTx.description.load();
    if (description is TlbTransOrd) {
        val action = description.action.unwrap().load();
        expect(action.totActions).toEqual(1);
        expect(action.msgsCreated).toEqual(1);
        expect(action.skippedActions).toEqual(0);
    } else {
        expect(false).toEqual(true);
    }
}

// Tiny-excess (floor + 1 nanoTON) must NOT revert the TonPool deposit. The
// refund send uses SEND_MODE_IGNORE_ERRORS so a sub-fwd-fee surplus simply
// drops the dust into the pool rent buffer. The deposit commits.
get fun `test TonPool deposit floor+1 nanoTON commits normally (refund drops dust safely)`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");

    val attached = TEST_TON_DENOM + MIN_DEPOSIT_VALUE + 1;
    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: attached },
    );
    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });

    // State advances normally despite the dust-sized excess.
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool deposit with surplus refunds excess to fromUser`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);

    // Floor is denom + MIN_DEPOSIT_VALUE = 10 + 0.32 = 10.32. Attach 10.42
    // (0.10 surplus). The contract must refund that 0.10 to fromUser.
    val surplus = ton("0.10");
    val attached = TEST_TON_DENOM + MIN_DEPOSIT_VALUE + surplus;

    val res = pool.sendTonDepositWithEmptySparseProof(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        },
        { value: attached },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);

    // A refund tx must exist from the pool to the user.
    expect(res).toHaveSuccessfulTx({ from: pool.address, to: user.address });
    val refundTx = res.findTransaction({
        from: pool.address,
        to: user.address,
    })!;
    val refundMsg = refundTx.messages.load().inMsg.unwrap().load();
    expect(refundMsg.info.bounce).toEqual(false);

    // User received at least most of the surplus back (some action fee deducted).
    val userBalAfter = testing.getAccountBalance(user.address);
    val userSpent = userBalBefore - userBalAfter;
    // Without the refund the user would spend the full `attached`. With it,
    // they spend approximately denom + MIN_DEPOSIT_VALUE.
    expect(userSpent < attached - ton("0.05")).toEqual(true);
}

get fun `test TonPool withdraw pays recipient + sender TON`() {
    val pool = fundedTonPool();

    val relayer = testing.treasury("relayer");
    val recipient = fixtureRecipient();
    val recipientBalBefore = testing.getAccountBalance(recipient);
    val relayerBalBefore = testing.getAccountBalance(relayer.address);

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        relayer.address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        recipient,
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });

    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    expect(pool.withdrawalCount()).toEqual(1);

    val recipientDelta = testing.getAccountBalance(recipient) - recipientBalBefore;
    expect(recipientDelta).toEqual(TEST_TON_DENOM);

    // Sender (= relayer) received RELAYER_REIMBURSEMENT minus tiny forward fee.
    val relayerDelta = testing.getAccountBalance(relayer.address) - relayerBalBefore;
    expect(relayerDelta >= RELAYER_REIMBURSEMENT - ton("0.01")).toEqual(true);
}

get fun `test TonPool withdraw fails if balance cannot cover pending payout`() {
    val pool = setupUnderfundedWithdrawTonPool();
    val relayer = testing.treasury("relayer");

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        relayer.address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientBalance,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw succeeds at native solvency threshold`() {
    val targetBalance: coins = POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT +
    TEST_TON_DENOM +
    RELAYER_REIMBURSEMENT;
    val pool = setupWithdrawStateTonPoolWithExactBalance(
        testing.treasury("ton-exact-factory").address,
        targetBalance,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    expect(testing.getAccountBalance(pool.address) >= pool.rentRunway()).toEqual(true);
}

fun deployTonPoolForWithdrawalCount(
    suffix: int,
    denomination: coins,
    nextIndex: uint32,
    pendingWithdrawTon: coins,
): TonPool {
    val pool = TonPool.fromStorage({
        identity: (TonPoolIdentity {
            factory: address.fromWorkchainAndHash(0, 0x7000 + suffix),
            denomination,
        }).toCell(),
        relayerReserve: 0,
        pendingWithdrawTon,
        merkle: (MerkleState {
            nextIndex,
            currentRoot: EMPTY_TREE_ROOT,
            rootHistory: [],
            sparseSets: createEmptySparseSetRoots(),
        }).toCell(),
    });
    expect(
        pool.deploy(testing.treasury("withdrawal-count-deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

// SAFETY: callers pass one method id, compiled code, and deployed data in RUNVM's stack order.
fun runGetterForExitCode(methodId: int, argCount: int, code: slice, data: cell): (int, cell?)
    asm "4 RUNVM"

fun TonPool.withdrawalCountExitCode(self): int {
    val account = testing.getAccountState(self.address);
    assert (account != null) throw 9907;
    val accountState = account!.storage.state;
    assert (accountState is TlbAccountStateActive) throw 9907;
    val stateInit = accountState.stateInit;
    assert (stateInit.code != null && stateInit.data != null) throw 9907;
    val methodId = ("withdrawalCount".crc16() & 0xffff) | 0x10000;
    val (exitCode, _) = runGetterForExitCode(
        methodId,
        1,
        stateInit.code!.beginParse(),
        stateInit.data!,
    );
    return exitCode;
}

get fun `test TonPool withdrawal count subtracts pending payouts`() {
    val valid = deployTonPoolForWithdrawalCount(1, TEST_TON_DENOM, 2, TEST_TON_DENOM);
    expect(valid.withdrawalCount()).toEqual(1);
    expect(calculateTonPoolWithdrawalCount(TEST_TON_DENOM, 2, TEST_TON_DENOM)).toEqual(1);
}

get fun `test TonPool withdrawal count getter rejects zero denomination storage`() {
    val zeroDenomination = deployTonPoolForWithdrawalCount(2, 0, 0, 0);
    expect(zeroDenomination.withdrawalCountExitCode()).toEqual(Errors.InvalidDenomination as int);
}

get fun `test TonPool withdrawal count getter rejects non-divisible pending storage`() {
    val nonDivisiblePending = deployTonPoolForWithdrawalCount(3, TEST_TON_DENOM, 1, 1);
    expect(nonDivisiblePending.withdrawalCountExitCode()).toEqual(
        Errors.FactoryInvariantViolation as int,
    );
}

get fun `test TonPool withdrawal count getter rejects pending above deposits`() {
    val pendingExceedsDeposits = deployTonPoolForWithdrawalCount(
        4,
        TEST_TON_DENOM,
        0,
        TEST_TON_DENOM,
    );
    expect(pendingExceedsDeposits.withdrawalCountExitCode()).toEqual(
        Errors.FactoryInvariantViolation as int,
    );
}

get fun `test TonPool withdraw fails one nano below native solvency threshold`() {
    val targetBalance: coins = POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT +
    TEST_TON_DENOM +
    RELAYER_REIMBURSEMENT;
    val pool = setupWithdrawStateTonPoolWithExactBalance(
        testing.treasury("ton-below-factory").address,
        targetBalance - 1,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientBalance,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw succeeds at native threshold with second pending payout`() {
    val relayerReserve = RELAYER_REIMBURSEMENT * 2;
    val pendingWithdrawTon = TEST_TON_DENOM * 2;
    val targetBalance: coins = POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT +
    relayerReserve +
    pendingWithdrawTon;
    val pool = setupWithdrawStateTonPoolWithReservesAndExactBalance(
        testing.treasury("ton-two-reserve-exact-factory").address,
        relayerReserve,
        pendingWithdrawTon,
        targetBalance,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw fails one nano below threshold with second pending payout`() {
    val relayerReserve = RELAYER_REIMBURSEMENT * 2;
    val pendingWithdrawTon = TEST_TON_DENOM * 2;
    val targetBalance: coins = POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT +
    relayerReserve +
    pendingWithdrawTon;
    val pool = setupWithdrawStateTonPoolWithReservesAndExactBalance(
        testing.treasury("ton-two-reserve-below-factory").address,
        relayerReserve,
        pendingWithdrawTon,
        targetBalance - 1,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientBalance,
    });
    expect(pool.relayerReserve()).toEqual(relayerReserve);
    expect(pool.pendingWithdrawTon()).toEqual(pendingWithdrawTon);
}

get fun `test TonPool withdraw with unknown root is rejected`() {
    val pool = setupWithdrawStateTonPool(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        false,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT + 1,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.UnknownRoot,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw rejects a stale sparse-set witness`() {
    val pool = setupWithdrawStateTonPool(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        false,
    );

    val res = pool.sendTonWithdraw(
        testing.treasury("stale-withdraw-relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        staleSparseSetProof(1),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({ to: pool.address, exitCode: Errors.StaleSparseSetRoot });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw rejects a malformed sparse-set witness`() {
    val pool = setupWithdrawStateTonPool(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        false,
    );

    val res = pool.sendTonWithdraw(
        testing.treasury("malformed-withdraw-relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        malformedSparseSetProof(0),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({ to: pool.address, exitCode: Errors.InvalidSparseSetProof });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw rejects unknown root even when history is non-empty`() {
    var rootHistory: map<uint32, uint256> = [];
    rootHistory.set(0, FIXTURE_WITHDRAW_ROOT + 123);
    val pool = setupWithdrawStateTonPoolWithRootHistory(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        FIXTURE_WITHDRAW_ROOT + 1,
        rootHistory,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.UnknownRoot,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw accepts second root from recent history`() {
    var rootHistory: map<uint32, uint256> = [];
    rootHistory.set(0, FIXTURE_WITHDRAW_ROOT + 123);
    rootHistory.set(1, FIXTURE_WITHDRAW_ROOT);
    val pool = setupWithdrawStateTonPoolWithRootHistory(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        FIXTURE_WITHDRAW_ROOT + 1,
        rootHistory,
    );

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool withdraw fails if relayer reserve is missing`() {
    val pool = setupWithdrawStateTonPool(0, TEST_TON_DENOM, ton("11"), false);

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientReserve,
    });
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool withdraw fails if pending payout reserve is missing`() {
    val pool = setupWithdrawStateTonPool(RELAYER_REIMBURSEMENT, 0, ton("11"), false);

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientReserve,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(0);
}

get fun `test TonPool withdraw accepts a root from recent history`() {
    val pool = setupWithdrawStateTonPool(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        true,
    );
    val recipient = fixtureRecipient();
    val recipientBalBefore = testing.getAccountBalance(recipient);

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        recipient,
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
    expect(
        testing.getAccountBalance(recipient) - recipientBalBefore >= TEST_TON_DENOM - ton("0.01"),
    ).toEqual(true);
}

get fun `test TonPool self-broadcast: user receives both recipient payout and reimbursement`() {
    val pool = fundedTonPool();

    // User self-broadcasts. msg.recipient must still be the fixture address
    // (binding). Sender being the same address as a coincidence is fine, but
    // in practice the user would use a fresh wallet as recipient for anonymity.
    val recipient = fixtureRecipient();
    val recipientBalBefore = testing.getAccountBalance(recipient);

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        recipient, // sender = recipient (self-broadcast)
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        recipient,
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });

    val recipientDelta = testing.getAccountBalance(recipient) - recipientBalBefore;
    // Receives denomination (as recipient) + RELAYER_REIMBURSEMENT (as sender),
    // minus the attached gas. Expect ~10 + 0.30 - 0.12 = ~10.18.
    expect(recipientDelta > TEST_TON_DENOM + ton("0.15")).toEqual(true);
}

get fun `test TonPool recipient swap is rejected`() {
    val pool = fundedTonPool();
    val attacker = testing.treasury("attacker").address;

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        attacker,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        attacker, // wrong recipient: proof binds to fixture
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InvalidWithdrawProof,
    });
    // Nullifier NOT consumed.
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool rejects recipient with same low 248 bits without consuming nullifier`() {
    val pool = fundedTonPool();
    val nullifierBucket = sparseSetBucketId(FIXTURE_WITHDRAW_NULLIFIER_HASH) as uint8;

    val res = pool.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("ton-recipient-alias-relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipientHighByteAlias(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InvalidWithdrawProof,
    });
    expect(pool.withdrawalCount()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
    expect(pool.sparseRoot(SPARSE_SET_NULLIFIER_DOMAIN, nullifierBucket)).toEqual(0);
}

get fun `test TonPool withdraw rejects malformed raw proof points`() {
    expectTonWithdrawProofRejected(
        withdrawProofWith(underLengthG1(), fixtureWithdrawProofB(), fixtureWithdrawProofC()),
        testing.treasury("ton-withdraw-proof-a-short").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(fixtureWithdrawProofA(), overLengthG2(), fixtureWithdrawProofC()),
        testing.treasury("ton-withdraw-proof-b-long").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(
            fixtureWithdrawProofA(),
            withExtraRef(fixtureWithdrawProofB()),
            fixtureWithdrawProofC(),
        ),
        testing.treasury("ton-withdraw-proof-b-ref").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(
            fixtureWithdrawProofA(),
            fixtureWithdrawProofB(),
            withExtraRef(fixtureWithdrawProofC()),
        ),
        testing.treasury("ton-withdraw-proof-c-ref").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(invalidNonZeroG1(), fixtureWithdrawProofB(), fixtureWithdrawProofC()),
        testing.treasury("ton-withdraw-proof-a-invalid").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(fixtureWithdrawProofA(), invalidNonZeroG2(), fixtureWithdrawProofC()),
        testing.treasury("ton-withdraw-proof-b-invalid").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(fixtureWithdrawProofA(), fixtureWithdrawProofB(), invalidNonZeroG1()),
        testing.treasury("ton-withdraw-proof-c-invalid").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(zeroG1(), fixtureWithdrawProofB(), fixtureWithdrawProofC()),
        testing.treasury("ton-withdraw-proof-a-zero").address,
    );
    expectTonWithdrawProofRejected(
        withdrawProofWith(fixtureWithdrawProofA(), zeroG2(), fixtureWithdrawProofC()),
        testing.treasury("ton-withdraw-proof-b-zero").address,
    );
}

get fun `test TonPool withdraw rejects public inputs at scalar field order`() {
    val rootAtR = setupWithdrawStateTonPoolWithRootHistory(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        BLS12_381_R,
        [],
    );
    val rootRes = rootAtR.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer-root-r").address,
        2,
        BLS12_381_R,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(rootRes).toHaveFailedTx({
        to: rootAtR.address,
        exitCode: Errors.InvalidWithdrawProof,
    });
    expect(rootAtR.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(rootAtR.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);

    val nullifierAtR = setupWithdrawStateTonPool(
        RELAYER_REIMBURSEMENT,
        TEST_TON_DENOM,
        ton("11"),
        false,
    );
    val nullifierRes = nullifierAtR.sendTonWithdrawWithEmptySparseProof(
        testing.treasury("relayer-nullifier-r").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        BLS12_381_R,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(nullifierRes).toHaveFailedTx({
        to: nullifierAtR.address,
        exitCode: Errors.InvalidSparseSetProof,
    });
    expect(nullifierAtR.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(nullifierAtR.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);
}

get fun `test TonPool nullifier replay is rejected (loser bounces)`() {
    val pool = fundedTonPool();
    val recipient = fixtureRecipient();

    expect(
        pool.sendTonWithdrawWithEmptySparseProof(
            testing.treasury("r1").address,
            2,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            recipient,
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    // Second submission with same nullifier → must fail. Bounceable tx means
    // the loser of a race only loses ~0.005 TON of gas, not the attached
    // MIN_WITHDRAW_GAS. This is the safety net of the public-broadcast model.
    expect(
        pool.sendTonWithdraw(
            testing.treasury("r2").address,
            3,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            recipient,
            realWithdrawProof(),
            occupiedSparseSetProof(
                SPARSE_SET_NULLIFIER_DOMAIN,
                FIXTURE_WITHDRAW_NULLIFIER_HASH,
            ),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.NullifierAlreadySpent,
    });
}
