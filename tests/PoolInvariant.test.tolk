import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/out_actions"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/deployment-types"
import "@contracts/errors"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@tests/pool-sparse-helpers"
import "@tests/proofs-fixture"
import "@tests/sparse-set-helpers"
import "@wrappers/Pool.gen"

const INVARIANT_TEST_DENOMINATION: coins = 1000

fun invariantFixtureRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun invariantFixtureProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureWithdrawProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

fun activeShardAccount(addr: address): TlbShardAccount {
    val shard = testing.getShardAccount(addr);
    if (shard != null) {
        return shard!;
    }
    Assert.fail("Expected active shard account");
}

fun setAccountBalance(addr: address, balance: coins) {
    var shard = activeShardAccount(addr);
    val account = shard.account.load();
    if (account !is TlbAccountInfo) {
        Assert.fail("Expected active account when setting balance");
    }
    var info = account;
    info.storage.balance.grams = balance;
    shard.account = (info as TlbAccount).toCell();
    testing.setShardAccount(addr, shard);
}

fun poolReservedAmount(result: SendResultList, pool: Pool): coins? {
    var poolResult: SendResult? = null;
    var resultIndex = 0;
    while (resultIndex < result.size()) {
        val item = result.at(resultIndex);
        if (poolResult == null && item.tx.load().getAccountAddress() == pool.address) {
            poolResult = item;
        }
        resultIndex += 1;
    }
    if (poolResult == null) {
        return null;
    }

    val actions = poolResult!.allOutActions();
    var reserved: coins? = null;
    var actionIndex = 0;
    while (actionIndex < actions.size()) {
        val action = actions.at(actionIndex);
        if (action is TlbOutActionReserveCurrency) {
            reserved = action.currency.grams;
        }
        actionIndex += 1;
    }
    return reserved;
}

fun invariantFixtureInsertProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
    };
}

fun invariantZeroG1(): slice {
    return beginCell()
        .storeUint(0xC0, 8)
        .storeUint(0, 256)
        .storeUint(0, 120)
        .endCell()
        .beginParse();
}

fun invariantZeroInsertProof(): ZkProof {
    return {
        proofA: (G1Point { raw: invariantZeroG1() }).toCell(),
        proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
    };
}

fun invariantZeroWithdrawProof(): ZkProof {
    return {
        proofA: (G1Point { raw: invariantZeroG1() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

fun deployDepositRentPool(): (Pool, Treasury) {
    val deployer = testing.treasury("pool-deposit-rent-deployer");
    val jettonWallet = testing.treasury("pool-deposit-rent-wallet");
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("pool-deposit-rent-master").address,
        factory: testing.treasury("pool-deposit-rent-factory").address,
        denomination: INVARIANT_TEST_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: FIXTURE_INSERT_OLD_ROOT,
        rootHistory: [],
        sparseSets: (SparseSetRoots {
            commitmentSeenRoots: [],
            nullifierSpentRoots: [],
        }).toCell(),
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: jettonWallet.address,
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawalCount: 0,
    });
    expect(pool.deploy(deployer.address, { value: ton("0.28") })).toHaveSuccessfulDeploy({
        to: pool.address,
    });
    return (pool, jettonWallet);
}

get fun `test deposit floor funds first history slot bucket and measured handler`() {
    val (pool, jettonWallet) = deployDepositRentPool();
    val user = testing.treasury("pool-deposit-rent-user");
    val payload = poolDepositPayload(
        1,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        invariantFixtureInsertProof(),
        poolEmptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, FIXTURE_INSERT_COMMITMENT),
    );
    val forwardPayload = beginCell().storeBool(true).storeRef(payload).endCell().beginParse();

    val result = pool.sendJettonTransferNotification(
        jettonWallet.address,
        1,
        INVARIANT_TEST_DENOMINATION,
        user.address,
        forwardPayload,
        { value: MIN_DEPOSIT_VALUE },
    );
    expect(result).toHaveSuccessfulTx({ from: jettonWallet.address, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(pool.rentRunway()).toEqual(
        POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT + POOL_SPARSE_BUCKET_RENT,
    );
    expect(
        testing.getAccountBalance(pool.address) >= pool.rentRunway() + pool.relayerReserve(),
    ).toEqual(true);
}

get fun `test zero insert point is rejected before the expensive pairing`() {
    val (pool, jettonWallet) = deployDepositRentPool();
    val payload = poolDepositPayload(
        2,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        invariantZeroInsertProof(),
        poolEmptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, FIXTURE_INSERT_COMMITMENT),
    );
    val result = sendRawDepositPayload(
        pool,
        jettonWallet.address,
        testing.treasury("pool-zero-insert-user").address,
        payload,
    );

    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    val gas = result
        .findTransaction<JettonTransferNotification>({ to: pool.address })!
        .getUsedGas();
    println("zero insert point rejection gas={}", gas);
    expect(gas < 300000).toEqual(true);
}

fun sendRawDepositPayload(
    pool: Pool,
    jettonWallet: address,
    user: address,
    payload: cell,
    value: coins = MIN_DEPOSIT_VALUE,
): SendResultList {
    return pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        INVARIANT_TEST_DENOMINATION,
        user,
        beginCell().storeBool(true).storeRef(payload).endCell().beginParse(),
        { value },
    );
}

get fun `test exact-shape bad deposit opcode and proof refund instead of trapping`() {
    val user = testing.treasury("pool-malformed-deposit-user");
    val sparseProof = poolEmptySparseSetProof(
        SPARSE_SET_COMMITMENT_DOMAIN,
        FIXTURE_INSERT_COMMITMENT,
    ).toCell();

    val (badOpcodePool, badOpcodeWallet) = deployDepositRentPool();
    val badOpcode = beginCell()
        .storeUint(0xdeadbeef, 32)
        .storeUint(1, 64)
        .storeUint(FIXTURE_INSERT_COMMITMENT, 256)
        .storeUint(FIXTURE_INSERT_NEW_ROOT, 256)
        .storeRef(invariantFixtureInsertProof().toCell())
        .storeRef(sparseProof)
        .endCell();
    val badOpcodeResult = sendRawDepositPayload(
        badOpcodePool,
        badOpcodeWallet.address,
        user.address,
        badOpcode,
    );
    expect(badOpcodeResult).toHaveSuccessfulTx({ to: badOpcodePool.address });
    expect(badOpcodeResult).toHaveSuccessfulTx({
        from: badOpcodePool.address,
        to: badOpcodeWallet.address,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(badOpcodePool.nextIndex()).toEqual(0);

    val badProof = beginCell()
        .storeUint(OP_DEPOSIT_PAYLOAD, 32)
        .storeUint(2, 64)
        .storeUint(FIXTURE_INSERT_COMMITMENT, 256)
        .storeUint(FIXTURE_INSERT_NEW_ROOT, 256)
        .storeRef(createEmptyCell())
        .storeRef(sparseProof)
        .endCell();
    val badProofResult = sendRawDepositPayload(
        badOpcodePool,
        badOpcodeWallet.address,
        user.address,
        badProof,
    );
    expect(badProofResult).toHaveSuccessfulTx({ to: badOpcodePool.address });
    expect(badProofResult).toHaveSuccessfulTx({
        from: badOpcodePool.address,
        to: badOpcodeWallet.address,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(badOpcodePool.nextIndex()).toEqual(0);
}

get fun `test occupied commitment with valid insert proof is refunded before state commit`() {
    val deployer = testing.treasury("pool-occupied-valid-deployer");
    val jettonWallet = testing.treasury("pool-occupied-valid-wallet");
    val user = testing.treasury("pool-occupied-valid-user");
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("pool-occupied-valid-master").address,
        factory: testing.treasury("pool-occupied-valid-factory").address,
        denomination: INVARIANT_TEST_DENOMINATION,
    };
    var tree = newSparseSetTestTree(SPARSE_SET_COMMITMENT_DOMAIN);
    tree.insert(FIXTURE_INSERT_COMMITMENT);
    var commitmentRoots: map<uint8, uint256> = [];
    commitmentRoots.set(
        sparseSetBucketId(FIXTURE_INSERT_COMMITMENT),
        tree.rootFor(FIXTURE_INSERT_COMMITMENT),
    );
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: FIXTURE_INSERT_OLD_ROOT,
        rootHistory: [],
        sparseSets: (SparseSetRoots {
            commitmentBucketCount: 1,
            nullifierBucketCount: 0,
            commitmentSeenRoots: commitmentRoots,
            nullifierSpentRoots: [],
        }).toCell(),
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: jettonWallet.address,
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawalCount: 0,
    });
    expect(pool.deploy(deployer.address, { value: ton("0.7") })).toHaveSuccessfulDeploy({
        to: pool.address,
    });

    val payload = poolDepositPayload(
        3,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        invariantFixtureInsertProof(),
        SparseSetUpdateProof.fromCell(tree.proofFor(FIXTURE_INSERT_COMMITMENT)),
    );
    val result = sendRawDepositPayload(
        pool,
        jettonWallet.address,
        user.address,
        payload,
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(result).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet.address,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.nextIndex()).toEqual(0);
}

fun validFirstDepositPayload(): cell {
    return poolDepositPayload(
        4,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        invariantFixtureInsertProof(),
        poolEmptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, FIXTURE_INSERT_COMMITMENT),
    );
}

fun firstDepositSolvencyThreshold(): coins {
    return POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT + POOL_SPARSE_BUCKET_RENT +
    RELAYER_REIMBURSEMENT +
    POOL_DEPOSIT_FEE_MARGIN;
}

get fun `test deposit solvency accepts the funded threshold with storage allowance`() {
    val (pool, jettonWallet) = deployDepositRentPool();
    setAccountBalance(
        pool.address,
        firstDepositSolvencyThreshold() - MIN_DEPOSIT_VALUE + ton("0.001"),
    );
    val result = sendRawDepositPayload(
        pool,
        jettonWallet.address,
        testing.treasury("pool-deposit-exact-threshold-user").address,
        validFirstDepositPayload(),
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
}

get fun `test deposit fee margin cannot be spent as rent or relayer reserve`() {
    val (pool, jettonWallet) = deployDepositRentPool();
    setAccountBalance(
        pool.address,
        firstDepositSolvencyThreshold() - MIN_DEPOSIT_VALUE - POOL_DEPOSIT_FEE_MARGIN,
    );
    val result = sendRawDepositPayload(
        pool,
        jettonWallet.address,
        testing.treasury("pool-deposit-margin-user").address,
        validFirstDepositPayload(),
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
}

get fun `test deposit excess never subsidizes the solvency threshold`() {
    val (pool, jettonWallet) = deployDepositRentPool();
    setAccountBalance(
        pool.address,
        firstDepositSolvencyThreshold() - MIN_DEPOSIT_VALUE - POOL_DEPOSIT_FEE_MARGIN,
    );
    val result = sendRawDepositPayload(
        pool,
        jettonWallet.address,
        testing.treasury("pool-deposit-excess-user").address,
        validFirstDepositPayload(),
        MIN_DEPOSIT_VALUE + ton("0.1"),
    );
    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
}

fun deployInvariantPool(
    withdrawalCount: uint32 = 0,
    depositCount: uint32 = 1,
    deployValue: coins = ton("2"),
): (Pool, Treasury, Treasury, Treasury) {
    val deployer = testing.treasury("pool-invariant-deployer");
    val jettonWallet = testing.treasury("pool-invariant-wallet");
    val factory = testing.treasury("pool-invariant-factory");
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("pool-invariant-master").address,
        factory: factory.address,
        denomination: INVARIANT_TEST_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex: depositCount,
        currentRoot: FIXTURE_WITHDRAW_ROOT,
        rootHistory: [],
        sparseSets: createEmptySparseSetRoots(),
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet: jettonWallet.address,
        relayerReserve: RELAYER_REIMBURSEMENT,
        merkle: merkle.toCell(),
        withdrawalCount,
    });
    expect(pool.deploy(deployer.address, { value: deployValue })).toHaveSuccessfulDeploy({
        to: pool.address,
    });
    return (pool, jettonWallet, factory, deployer);
}

fun unboundInvariantPool(): (Pool, Treasury, Treasury) {
    val factory = testing.treasury("pool-seed-factory");
    val jettonMaster = testing.treasury("pool-seed-master");
    val identity: PoolIdentity = {
        jettonMaster: jettonMaster.address,
        factory: factory.address,
        denomination: INVARIANT_TEST_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: EMPTY_TREE_ROOT,
        rootHistory: [],
        sparseSets: (SparseSetRoots {
            commitmentSeenRoots: [],
            nullifierSpentRoots: [],
        }).toCell(),
    };
    return (
        Pool.fromStorage({
            identity: identity.toCell(),
            jettonWallet: null,
            relayerReserve: 0,
            merkle: merkle.toCell(),
            withdrawalCount: 0,
        }),
        factory,
        jettonMaster,
    );
}

get fun `test deployment trigger seed preserves empty rent runway and sends TEP89 query`() {
    val (pool, factory, jettonMaster) = unboundInvariantPool();
    val seed: coins = POOL_BASE_RENT_RUNWAY + ton("0.07");
    val trigger = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: { stateInit: pool.stateInit! },
        value: seed,
        body: ConfirmPoolDeployment { queryId: 1 },
    });
    val result = net.send(factory.address, trigger);
    expect(result).toHaveSuccessfulDeploy({ to: pool.address });
    expect(result).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonMaster.address,
        opcode: 0x2c76b973,
    });
    expect(testing.getAccountBalance(pool.address) >= pool.rentRunway()).toEqual(true);
}

get fun `test bound Pool reconfirm accepts the exact caller-funded budget`() {
    val (pool, _, factory, _) = deployInvariantPool();
    val result = pool.sendInitWalletBinding(
        testing.treasury("pool-reconfirm-caller").address,
        2,
        { value: 20000000 },
    );

    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(result).toHaveSuccessfulTx({
        from: pool.address,
        to: factory.address,
        opcode: 0x46504301,
    });
    expect(result).toNotHaveTx({
        from: pool.address,
        to: testing.treasury("pool-invariant-master").address,
        opcode: 0x2c76b973,
    });
}

get fun `test bound Pool reconfirm rejects one nano below its budget`() {
    val (pool, _, factory, _) = deployInvariantPool();
    val result = pool.sendInitWalletBinding(
        testing.treasury("pool-reconfirm-underfunded-caller").address,
        3,
        { value: 19999999 },
    );

    expect(result).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InsufficientGas,
    });
    expect(result).toNotHaveTx({
        from: pool.address,
        to: factory.address,
        opcode: 0x46504301,
    });
}

get fun `test bound Pool reconfirm reserves rent plus every note obligation`() {
    val (pool, _, factory, _) = deployInvariantPool();
    // Forge the pre-message balance below the full obligation, then attach
    // enough caller funding to make the action possible. RAWRESERVE must pin
    // rent + relayerReserve, never only the pre-message balance.
    val rentRunway = pool.rentRunway();
    setAccountBalance(pool.address, rentRunway + ton("0.05"));

    val result = pool.sendInitWalletBinding(
        testing.treasury("pool-reconfirm-corrupt-state-caller").address,
        4,
        { value: ton("0.40") },
    );

    expect(result).toHaveSuccessfulTx({ to: pool.address });
    expect(result).toHaveSuccessfulTx({
        from: pool.address,
        to: factory.address,
        opcode: 0x46504301,
    });
    expect(poolReservedAmount(result, pool)).toEqual(rentRunway + RELAYER_REIMBURSEMENT);
}

get fun `test withdrawal increments count and sends the exact plain payout`() {
    val (pool, jettonWallet, _, _) = deployInvariantPool(0, 1, ton("0.58"));
    val relayer = testing.treasury("pool-initial-relayer");
    val balanceBefore = testing.getAccountBalance(pool.address);
    expect(balanceBefore >= pool.rentRunway() + RELAYER_REIMBURSEMENT).toEqual(true);

    val result = pool.sendWithdrawWithEmptySparseProof(
        relayer.address,
        99,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        invariantFixtureRecipient(),
        invariantFixtureProof(),
        { value: MIN_JETTON_WITHDRAW_GAS },
    );
    expect(result).toHaveSuccessfulTx({ from: relayer.address, to: pool.address });
    expect(result).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet.address,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.withdrawalCount()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(0);
    expect(testing.getAccountBalance(pool.address) >= pool.rentRunway()).toEqual(true);

    val transferTx = result.findTransaction<JettonTransfer>({
        from: pool.address,
        to: jettonWallet.address,
    })!;
    val transferMessage = transferTx.loadInMsg<JettonTransfer>();
    if (transferMessage.info is TlbInternalMessage) {
        expect(transferMessage.info.value.grams).toEqual(ton("0.15"));
        expect(transferMessage.info.bounce).toEqual(false);
    } else {
        expect(false).toEqual(true);
    }
    val transfer = transferMessage.loadBody();
    expect(transfer.queryId).toEqual(99);
    expect(transfer.amount).toEqual(INVARIANT_TEST_DENOMINATION);
    expect(transfer.destination).toEqual(invariantFixtureRecipient());
    expect(transfer.responseDestination).toEqual(relayer.address);
    expect(transfer.customPayload).toEqual(null);
    expect(transfer.forwardAmount).toEqual(0);
    expect(transfer.forwardPayload).toEqual(null);
}

get fun `test zero withdraw point is rejected before the expensive pairing`() {
    val (pool, _, _, _) = deployInvariantPool();
    val result = pool.sendWithdrawWithEmptySparseProof(
        testing.treasury("pool-zero-withdraw-relayer").address,
        100,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        invariantFixtureRecipient(),
        invariantZeroWithdrawProof(),
        { value: MIN_JETTON_WITHDRAW_GAS },
    );

    expect(result).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.InvalidWithdrawProof,
    });
    val gas = result.findTransaction<Withdraw>({ to: pool.address })!.getUsedGas();
    println("zero withdraw point rejection gas={}", gas);
    expect(gas < 50000).toEqual(true);
}

get fun `test withdrawal count cannot exceed accepted deposits`() {
    val (pool, _, _, _) = deployInvariantPool(1, 1);
    val relayer = testing.treasury("pool-withdrawal-count-relayer");
    expect(
        pool.sendWithdrawWithEmptySparseProof(
            relayer.address,
            1,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            invariantFixtureRecipient(),
            invariantFixtureProof(),
            { value: MIN_JETTON_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({
        from: relayer.address,
        to: pool.address,
        exitCode: Errors.WithdrawalCapacityReached,
    });
    expect(pool.withdrawalCount()).toEqual(1);
}

get fun `test withdraw distinguishes stale and malformed sparse witnesses`() {
    val relayer = testing.treasury("pool-sparse-status-relayer");

    val (stalePool, _, _, _) = deployInvariantPool();
    val staleProof: SparseSetUpdateProof = {
        expectedRoot: 1,
        siblingBitmap: 0,
        siblings: createEmptyCell(),
    };
    expect(
        stalePool.sendWithdraw(
            relayer.address,
            1,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            invariantFixtureRecipient(),
            invariantFixtureProof(),
            staleProof,
            { value: MIN_JETTON_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({ to: stalePool.address, exitCode: Errors.StaleSparseSetRoot });

    val malformedProof: SparseSetUpdateProof = {
        expectedRoot: 0,
        siblingBitmap: 1,
        siblings: createEmptyCell(),
    };
    expect(
        stalePool.sendWithdraw(
            relayer.address,
            2,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            invariantFixtureRecipient(),
            invariantFixtureProof(),
            malformedProof,
            { value: MIN_JETTON_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({ to: stalePool.address, exitCode: Errors.InvalidSparseSetProof });
}
