import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@contracts/ton-pool-types"
import "@tests/proofs-fixture"
import "@tests/sparse-set-helpers"
import "@wrappers/Pool.gen"
import "@wrappers/TonPool.gen"

const INTEGRATED_SPARSE_GAS_GATE: int = 500000
const GAS_TEST_JETTON_DENOMINATION: coins = 100
const GAS_TEST_TON_DENOMINATION: coins = 10000000000

fun gasFixtureRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun gasInsertProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
    };
}

fun gasWithdrawProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureWithdrawProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

fun setDenseGasAccountBalance(addr: address, balance: coins) {
    val currentShard = testing.getShardAccount(addr);
    assert (currentShard != null) throw 9905;
    var shard = currentShard!;
    val currentAccount = shard.account.load();
    assert (currentAccount is TlbAccountInfo) throw 9905;
    var account = currentAccount;
    account.storage.balance.grams = balance;
    shard.account = (account as TlbAccount).toCell();
    testing.setShardAccount(addr, shard);
}

fun denseGasPool(
    currentRoot: uint256,
    nextIndex: uint32,
    relayerReserve: coins,
    sparseSets: Cell<SparseSetRoots>,
): (Pool, Treasury) {
    val jettonWallet = testing.treasury("dense-gas-jetton-wallet");
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("dense-gas-master").address,
        factory: testing.treasury("dense-gas-factory").address,
        denomination: GAS_TEST_JETTON_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex,
        currentRoot,
        rootHistory: [],
        sparseSets,
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: jettonWallet.address,
        relayerReserve,
        merkle: merkle.toCell(),
        withdrawalCount: 0,
    });
    expect(
        pool.deploy(testing.treasury("dense-gas-pool-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    return (pool, jettonWallet);
}

fun denseGasTonPool(
    currentRoot: uint256,
    nextIndex: uint32,
    relayerReserve: coins,
    pendingWithdrawTon: coins,
    sparseSets: Cell<SparseSetRoots>,
    deployValue: coins,
): TonPool {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("dense-gas-ton-factory").address,
        denomination: GAS_TEST_TON_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex,
        currentRoot,
        rootHistory: [],
        sparseSets,
    };
    val pool = TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve,
        pendingWithdrawTon,
        merkle: merkle.toCell(),
    });
    expect(
        pool.deploy(
            testing.treasury("dense-gas-ton-deployer").address,
            { value: deployValue },
        ),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

get fun `test Jetton deposit with real Groth16 and 247 siblings succeeds at exact balance floor`() {
    val (pool, jettonWallet) = denseGasPool(
        FIXTURE_INSERT_OLD_ROOT,
        0,
        0,
        denseSparseSetTestRoots(
            SPARSE_SET_COMMITMENT_DOMAIN,
            FIXTURE_INSERT_COMMITMENT,
        ),
    );
    val user = testing.treasury("dense-gas-user");
    val expectedRunway = POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT +
    POOL_SPARSE_BUCKET_RENT;
    val exactPreMessageBalance = expectedRunway + RELAYER_REIMBURSEMENT + POOL_DEPOSIT_FEE_MARGIN -
    MIN_DEPOSIT_VALUE;
    setDenseGasAccountBalance(pool.address, exactPreMessageBalance);
    expect(testing.getAccountBalance(pool.address)).toEqual(exactPreMessageBalance);

    val payload = (DepositPayload {
        queryId: 1,
        commitment: FIXTURE_INSERT_COMMITMENT,
        newRoot: FIXTURE_INSERT_NEW_ROOT,
        insertProof: gasInsertProof().toCell(),
        commitmentSetProof: denseSparseSetTestProof(
            SPARSE_SET_COMMITMENT_DOMAIN,
            FIXTURE_INSERT_COMMITMENT,
        ).toCell(),
    }).toCell();
    val forwardPayload = beginCell().storeUint(1, 1).storeRef(payload).endCell().beginParse();
    val result = pool.sendJettonTransferNotification(
        jettonWallet.address,
        1,
        GAS_TEST_JETTON_DENOMINATION,
        user.address,
        forwardPayload,
        { value: MIN_DEPOSIT_VALUE },
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.rentRunway()).toEqual(expectedRunway);
    expect(
        testing.getAccountBalance(pool.address) >= pool.rentRunway() + pool.relayerReserve(),
    ).toEqual(true);
    val gas = result
        .findTransaction<JettonTransferNotification>({ to: pool.address })!
        .getUsedGas();
    println("dense Jetton deposit gas={}", gas);
    expect(gas <= INTEGRATED_SPARSE_GAS_GATE).toEqual(true);
}

get fun `test Jetton withdraw with real Groth16 and 247 siblings stays below gas gate`() {
    val (pool, _) = denseGasPool(
        FIXTURE_WITHDRAW_ROOT,
        1,
        RELAYER_REIMBURSEMENT,
        denseSparseSetTestRoots(
            SPARSE_SET_NULLIFIER_DOMAIN,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
        ),
    );
    val rentRunwayBeforeWithdrawal = pool.rentRunway();
    val result = pool.sendWithdraw(
        testing.treasury("dense-gas-relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        gasFixtureRecipient(),
        gasWithdrawProof(),
        denseSparseSetTestProof(
            SPARSE_SET_NULLIFIER_DOMAIN,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
        ),
        { value: MIN_JETTON_WITHDRAW_GAS },
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.rentRunway()).toEqual(rentRunwayBeforeWithdrawal);
    val gas = result.findTransaction<Withdraw>({ to: pool.address })!.getUsedGas();
    println("dense Jetton withdraw gas={}", gas);
    expect(gas <= INTEGRATED_SPARSE_GAS_GATE).toEqual(true);
}

get fun `test TON deposit with real Groth16 and 247 siblings stays below gas gate`() {
    val pool = denseGasTonPool(
        FIXTURE_INSERT_OLD_ROOT,
        0,
        0,
        0,
        denseSparseSetTestRoots(
            SPARSE_SET_COMMITMENT_DOMAIN,
            FIXTURE_INSERT_COMMITMENT,
        ),
        ton("1"),
    );
    val user = testing.treasury("dense-gas-ton-user");
    val result = pool.sendTonDepositPayload(
        user.address,
        1,
        user.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        gasInsertProof(),
        denseSparseSetTestProof(
            SPARSE_SET_COMMITMENT_DOMAIN,
            FIXTURE_INSERT_COMMITMENT,
        ),
        { value: GAS_TEST_TON_DENOMINATION + MIN_DEPOSIT_VALUE },
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    val gas = result.findTransaction<TonDepositPayload>({ to: pool.address })!.getUsedGas();
    println("dense TON deposit gas={}", gas);
    expect(gas <= INTEGRATED_SPARSE_GAS_GATE).toEqual(true);
}

get fun `test TON withdraw with real Groth16 and 247 siblings stays below gas gate`() {
    val pool = denseGasTonPool(
        FIXTURE_WITHDRAW_ROOT,
        1,
        RELAYER_REIMBURSEMENT,
        GAS_TEST_TON_DENOMINATION,
        denseSparseSetTestRoots(
            SPARSE_SET_NULLIFIER_DOMAIN,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
        ),
        ton("11"),
    );
    val result = pool.sendTonWithdraw(
        testing.treasury("dense-gas-ton-relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        gasFixtureRecipient(),
        gasWithdrawProof(),
        denseSparseSetTestProof(
            SPARSE_SET_NULLIFIER_DOMAIN,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
        ),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    val gas = result.findTransaction<TonWithdraw>({ to: pool.address })!.getUsedGas();
    println("dense TON withdraw gas={}", gas);
    expect(gas <= INTEGRATED_SPARSE_GAS_GATE).toEqual(true);
}
