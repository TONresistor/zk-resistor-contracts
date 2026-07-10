import "@acton/build"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/factory-types"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@contracts/ton-pool-types"
import "@tests/pool-sparse-helpers"
import "@tests/proofs-fixture"
import "@tests/ton-pool-sparse-helpers"
import "@wrappers/Factory.gen"
import "@wrappers/Pool.gen"
import "@wrappers/TonPool.gen"

const FAULT_TEST_DENOMINATION: coins = 1000

fun faultRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun faultWithdrawProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureWithdrawProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

fun faultAccountIsActive(addr: address): bool {
    val account = testing.getAccountState(addr);
    if (account == null) {
        return false;
    }
    return account!.storage.state is TlbAccountStateActive;
}

fun deployFaultPool(jettonWallet: address): Pool {
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("fault-master").address,
        factory: testing.treasury("fault-factory").address,
        denomination: FAULT_TEST_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex: 1,
        currentRoot: FIXTURE_WITHDRAW_ROOT,
        rootHistory: [],
        sparseSets: createEmptySparseSetRoots(),
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet,
        relayerReserve: RELAYER_REIMBURSEMENT,
        merkle: merkle.toCell(),
        withdrawalCount: 0,
    });
    expect(
        pool.deploy(testing.treasury("fault-deployer").address, { value: ton("2") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

get fun `test local withdrawal action failure rolls back all committed accounting`() {
    val jettonWallet = testing.treasury("action-failure-wallet");
    val pool = deployFaultPool(jettonWallet.address);
    val payer = testing.treasury("action-failure-payer");
    val nullifierBucket = sparseSetBucketId(FIXTURE_WITHDRAW_NULLIFIER_HASH) as uint8;

    val originalConfig = testing.getConfig();
    var expensiveConfig = originalConfig;
    var messagePrices = expensiveConfig.getMsgForwardPrices(BASECHAIN);
    messagePrices.lumpPrice = ton("2") as uint64;
    expensiveConfig.setMsgForwardPrices(messagePrices, BASECHAIN);
    expect(testing.setConfig(expensiveConfig)).toEqual(true);

    val failed = pool.sendWithdrawWithEmptySparseProof(
        payer.address,
        3,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        faultRecipient(),
        faultWithdrawProof(),
        { value: MIN_JETTON_WITHDRAW_GAS },
    );
    expect(testing.setConfig(originalConfig)).toEqual(true);

    expect(failed).toHaveTx<Withdraw>({
        from: payer.address,
        to: pool.address,
        success: false,
        actionExitCode: 37,
    });
    expect(failed).toNotHaveTx<JettonTransfer>({
        from: pool.address,
        to: jettonWallet.address,
    });
    expect(pool.withdrawalCount()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.sparseRoot(SPARSE_SET_NULLIFIER_DOMAIN, nullifierBucket)).toEqual(0);
}

fun deployFaultTonPool(): TonPool {
    val pool = TonPool.fromStorage({
        identity: (TonPoolIdentity {
            factory: testing.treasury("fault-ton-factory").address,
            denomination: FAULT_TEST_DENOMINATION,
        }).toCell(),
        relayerReserve: RELAYER_REIMBURSEMENT,
        pendingWithdrawTon: FAULT_TEST_DENOMINATION,
        merkle: (MerkleState {
            nextIndex: 1,
            currentRoot: FIXTURE_WITHDRAW_ROOT,
            rootHistory: [],
            sparseSets: createEmptySparseSetRoots(),
        }).toCell(),
    });
    expect(
        pool.deploy(testing.treasury("fault-ton-deployer").address, { value: ton("2") }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    return pool;
}

get fun `test TonPool local payout action failure rolls back every accounting write`() {
    val pool = deployFaultTonPool();
    val payer = testing.treasury("fault-ton-payer");
    val nullifierBucket = sparseSetBucketId(FIXTURE_WITHDRAW_NULLIFIER_HASH) as uint8;

    val originalConfig = testing.getConfig();
    var expensiveConfig = originalConfig;
    var messagePrices = expensiveConfig.getMsgForwardPrices(BASECHAIN);
    messagePrices.lumpPrice = ton("2") as uint64;
    expensiveConfig.setMsgForwardPrices(messagePrices, BASECHAIN);
    expect(testing.setConfig(expensiveConfig)).toEqual(true);

    val failed = pool.sendTonWithdrawWithEmptySparseProof(
        payer.address,
        1,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        faultRecipient(),
        faultWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(testing.setConfig(originalConfig)).toEqual(true);

    expect(failed).toHaveTx<TonWithdraw>({
        from: payer.address,
        to: pool.address,
        success: false,
        actionExitCode: 37,
    });
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.pendingWithdrawTon()).toEqual(FAULT_TEST_DENOMINATION);
    expect(pool.withdrawalCount()).toEqual(0);
    expect(pool.sparseRoot(SPARSE_SET_NULLIFIER_DOMAIN, nullifierBucket)).toEqual(0);
}

fun deployFaultFactory(): Factory {
    val factory = Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 0,
        tonPoolCount: 0,
        inFlightCreates: 0,
        registries: (Registries {
            poolRegistry: [],
            poolAddressToKey: [],
            tonPoolRegistry: [],
            tonPoolAddressToKey: [],
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator: [],
            tonPoolAddressToCreator: [],
        }).toCell(),
    });
    expect(
        factory.deploy(testing.treasury("fault-factory-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    return factory;
}

get fun `test Factory local deploy action failure rolls back registries and counters`() {
    val factory = deployFaultFactory();
    val payer = testing.treasury("fault-factory-payer");
    val expectedPool = factory.expectedTonPoolAddress(TON_POOL_DENOM_10);

    val originalConfig = testing.getConfig();
    var expensiveConfig = originalConfig;
    var messagePrices = expensiveConfig.getMsgForwardPrices(BASECHAIN);
    messagePrices.lumpPrice = ton("2") as uint64;
    expensiveConfig.setMsgForwardPrices(messagePrices, BASECHAIN);
    expect(testing.setConfig(expensiveConfig)).toEqual(true);

    val failed = factory.sendCreateTonPool(
        payer.address,
        1,
        TON_POOL_DENOM_10,
        { value: MIN_CREATE_TON_POOL_FEE },
    );
    expect(testing.setConfig(originalConfig)).toEqual(true);

    expect(failed).toHaveTx<CreateTonPool>({
        from: payer.address,
        to: factory.address,
        success: false,
        actionExitCode: 37,
    });
    expect(factory.totalPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.tonPoolAddressFor(TON_POOL_DENOM_10)).toEqual(null);
    expect(faultAccountIsActive(expectedPool)).toEqual(false);
}
