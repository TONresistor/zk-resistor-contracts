import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/pool-types"
import "@tests/proofs-fixture"
import "@wrappers/Pool.gen"

// ============================================================================
// E2E: full deposit -> withdraw flow with REAL Groth16 BLS12-381 proofs
//
// Uses the chained fixture (insert.newRoot == withdraw.root) so the deposit
// brings the pool into the exact state the withdraw proof expects.
//
// IMPORTANT: the withdraw fixture binds `recipient` to the field derived from
// `FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW` (the admin/1312.ton owner address).
// Tests MUST pass exactly that address as `Withdraw.recipient` so the
// contract's derivation matches.
// ============================================================================

const TEST_DENOMINATION: coins = 1000

// Reconstruct the fixture's recipient address so the contract's
// `recipientHash & ADDRESS_FIELD_MASK` matches `FIXTURE_WITHDRAW_RECIPIENT`.
fun fixtureRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun setupPoolWithMasterAndDeployValue(
    jettonMaster: address,
    deployValue: coins,
): (Pool, Treasury, address) {
    val deployer = testing.treasury("deployer");
    val jettonWallet = testing.treasury("pool-jw").address;
    val identity: PoolIdentity = {
        jettonMaster,
        factory: testing.treasury("factory").address,
        denomination: TEST_DENOMINATION,
    };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: FIXTURE_INSERT_OLD_ROOT, // empty depth-20 tree root
        rootHistory: [],
        nullifiers: [],
        commitments: [],
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet, // pre-set for E2E; prod uses InitWalletBinding
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawals: [],
    });
    val res = pool.deploy(deployer.address, { value: deployValue });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return (pool, deployer, jettonWallet);
}

fun setupPoolWithDeployValue(deployValue: coins): (Pool, Treasury, address) {
    return setupPoolWithMasterAndDeployValue(
        testing.treasury("jetton-master").address,
        deployValue,
    );
}

fun setupPool(): (Pool, Treasury, address) {
    return setupPoolWithDeployValue(ton("1"));
}

fun setupDepositPoolWithExactBalance(
    probeMaster: address,
    jettonMaster: address,
    targetBalance: coins,
): (Pool, Treasury, address) {
    val probeDeployValue = targetBalance + ton("0.01");
    val (probe, _, _) = setupPoolWithMasterAndDeployValue(probeMaster, probeDeployValue);
    val deployFee = probeDeployValue - testing.getAccountBalance(probe.address);
    val (pool, deployer, jettonWallet) = setupPoolWithMasterAndDeployValue(
        jettonMaster,
        targetBalance + deployFee,
    );
    expect(testing.getAccountBalance(pool.address)).toEqual(targetBalance);
    return (pool, deployer, jettonWallet);
}

fun setupUnderfundedWithdrawPool(): (Pool, Treasury, address) {
    return setupWithdrawStatePool(RELAYER_REIMBURSEMENT, ton("0.10"), false);
}

fun setupWithdrawStatePool(
    relayerReserve: coins,
    deployValue: coins,
    useHistoricalRoot: bool,
): (Pool, Treasury, address) {
    return setupWithdrawStatePoolWithMaster(
        testing.treasury("jetton-master").address,
        relayerReserve,
        deployValue,
        useHistoricalRoot,
    );
}

fun setupWithdrawStatePoolWithMaster(
    jettonMaster: address,
    relayerReserve: coins,
    deployValue: coins,
    useHistoricalRoot: bool,
): (Pool, Treasury, address) {
    val deployer = testing.treasury("deployer");
    val jettonWallet = testing.treasury("pool-jw").address;
    val identity: PoolIdentity = {
        jettonMaster,
        factory: testing.treasury("factory").address,
        denomination: TEST_DENOMINATION,
    };
    var rootHistory: map<uint32, uint256> = [];
    if (useHistoricalRoot) {
        rootHistory.set(0, FIXTURE_WITHDRAW_ROOT);
    }
    val merkle: MerkleState = {
        nextIndex: 1,
        currentRoot: useHistoricalRoot ? FIXTURE_WITHDRAW_ROOT + 1 : FIXTURE_WITHDRAW_ROOT,
        rootHistory,
        nullifiers: [],
        commitments: [],
    };
    val pool = Pool.fromStorage({
        identity: identity.toCell(),
        jettonWallet,
        relayerReserve,
        merkle: merkle.toCell(),
        withdrawals: [],
    });
    val res = pool.deploy(deployer.address, { value: deployValue });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return (pool, deployer, jettonWallet);
}

fun setupWithdrawStatePoolWithExactBalance(
    probeMaster: address,
    jettonMaster: address,
    targetBalance: coins,
): (Pool, Treasury, address) {
    val probeDeployValue = targetBalance + ton("0.01");
    val (probe, _, _) = setupWithdrawStatePoolWithMaster(
        probeMaster,
        RELAYER_REIMBURSEMENT,
        probeDeployValue,
        false,
    );
    val deployFee = probeDeployValue - testing.getAccountBalance(probe.address);
    val (pool, deployer, jettonWallet) = setupWithdrawStatePoolWithMaster(
        jettonMaster,
        RELAYER_REIMBURSEMENT,
        targetBalance + deployFee,
        false,
    );
    expect(testing.getAccountBalance(pool.address)).toEqual(targetBalance);
    return (pool, deployer, jettonWallet);
}

fun depositPayloadCell(): cell {
    val payload: DepositPayload = {
        queryId: 1,
        commitment: FIXTURE_INSERT_COMMITMENT,
        newRoot: FIXTURE_INSERT_NEW_ROOT,
        insertProof: (ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        }).toCell(),
    };
    return payload.toCell();
}

// Variant 1: TEP-74 forward_payload INLINE: either bit = 0 followed by
// the DepositPayload's raw bits.
fun buildDepositForwardPayload(): slice {
    return beginCell()
        .storeUint(0, 1)
        .storeSlice(depositPayloadCell().beginParse())
        .endCell()
        .beginParse();
}

// Variant 2: TEP-74 forward_payload REF: either bit = 1 followed by a ref
// whose content IS the DepositPayload cell directly (NO nested either bit).
// This is exactly what the frontend's deposit.ts emits.
fun buildDepositForwardPayloadRef(): slice {
    return beginCell().storeUint(1, 1).storeRef(depositPayloadCell()).endCell().beginParse();
}

fun realWithdrawProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureWithdrawProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

// ============================================================================
// Happy path: real deposit → real withdraw on the same commitment
// ============================================================================

get fun `test real deposit advances root and stores commitment (inline payload)`() {
    val (pool, _, jettonWallet) = setupPool();

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: ton("0.6") },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });

    expect(pool.nextIndex()).toEqual(1);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_NEW_ROOT);
}

get fun `test deposit at floor refunds if pool reserve is underfunded`() {
    val (pool, _, jettonWallet) = setupPoolWithDeployValue(ton("0.01"));

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE },
    );

    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
}

get fun `test deposit succeeds at exact reserve threshold`() {
    val targetBalance: coins = POOL_TON_RESERVE + RELAYER_REIMBURSEMENT - MIN_DEPOSIT_VALUE;
    val (pool, _, jettonWallet) = setupDepositPoolWithExactBalance(
        testing.treasury("deposit-exact-probe-jm").address,
        testing.treasury("deposit-exact-jm").address,
        targetBalance,
    );

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE },
    );

    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
}

get fun `test deposit surplus cannot mask underfunded reserve`() {
    val (pool, _, jettonWallet) = setupPoolWithDeployValue(ton("0.01"));

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE + ton("0.02") },
    );

    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
}

get fun `test real deposit succeeds with FE ref-encoded forward payload`() {
    val (pool, _, jettonWallet) = setupPool();

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayloadRef(),
        { value: ton("0.6") },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_NEW_ROOT);
}

get fun `test real withdraw spends nullifier and pays recipient + sender`() {
    val (pool, _, jettonWallet) = setupPool();

    // Deposit first (advances root to FIXTURE_INSERT_NEW_ROOT).
    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);

    // The relayer broadcasts the withdraw. Recipient = the fixture address.
    val relayer = testing.treasury("relayer").address;
    val res = pool.sendWithdraw(
        relayer,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });

    // Reserve decremented to 0.
    expect(pool.relayerReserve()).toEqual(0);

    // Pool sent RELAYER_REIMBURSEMENT TON to the TX sender (= relayer).
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: relayer,
    });
}

get fun `test withdraw fails if pool balance cannot cover reserved payout`() {
    val (pool, _, _) = setupUnderfundedWithdrawPool();
    val relayer = testing.treasury("relayer").address;

    val res = pool.sendWithdraw(
        relayer,
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
}

get fun `test withdraw succeeds at jetton solvency threshold with storage slack`() {
    val targetBalance: coins = POOL_TON_RESERVE + RELAYER_REIMBURSEMENT + JETTON_TRANSFER_GAS +
    30000000;
    val (pool, _, jettonWallet) = setupWithdrawStatePoolWithExactBalance(
        testing.treasury("jetton-exact-probe-jm").address,
        testing.treasury("jetton-exact-jm").address,
        targetBalance + ton("0.01"),
    );

    val res = pool.sendWithdraw(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.relayerReserve()).toEqual(0);
}

get fun `test withdraw fails one nano below jetton solvency threshold`() {
    val targetBalance: coins = POOL_TON_RESERVE + RELAYER_REIMBURSEMENT + JETTON_TRANSFER_GAS +
    30000000;
    val (pool, _, _) = setupWithdrawStatePoolWithExactBalance(
        testing.treasury("jetton-below-probe-jm").address,
        testing.treasury("jetton-below-jm").address,
        targetBalance - 1,
    );

    val res = pool.sendWithdraw(
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
}

get fun `test withdraw fails if relayer reserve is missing`() {
    val (pool, _, _) = setupWithdrawStatePool(0, ton("1"), false);
    val relayer = testing.treasury("relayer").address;

    val res = pool.sendWithdraw(
        relayer,
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
}

get fun `test withdraw accepts a root from recent history`() {
    val (pool, _, jettonWallet) = setupWithdrawStatePool(RELAYER_REIMBURSEMENT, ton("1"), true);
    val relayer = testing.treasury("relayer").address;

    val res = pool.sendWithdraw(
        relayer,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: OP_JETTON_TRANSFER,
    });
    expect(pool.relayerReserve()).toEqual(0);
}

// ============================================================================
// Relayer economics: deposit earmarks, withdraw pays sender
// ============================================================================

get fun `test deposit increments relayerReserve`() {
    val (pool, _, jettonWallet) = setupPool();
    expect(pool.relayerReserve()).toEqual(0);

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
}

get fun `test refund deposit leaves relayerReserve unchanged`() {
    val (pool, _, jettonWallet) = setupPool();

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION + 1,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: ton("0.6") },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.nextIndex()).toEqual(0);
}

get fun `test sender (relayer wallet) receives RELAYER_REIMBURSEMENT`() {
    val (pool, _, jettonWallet) = setupPool();
    val relayerAddr = testing.treasury("relayer").address;
    val balanceBefore = testing.getAccountBalance(relayerAddr);

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    val res = pool.sendWithdraw(
        relayerAddr, // <-- sender of the tx
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });

    val balanceAfter = testing.getAccountBalance(relayerAddr);
    expect(balanceAfter > balanceBefore).toEqual(true);
}

get fun `test self-broadcast: user receives their own RELAYER_REIMBURSEMENT`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user").address;
    val userBefore = testing.getAccountBalance(user);

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            user,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    // The user broadcasts their OWN withdraw (sender = user). The 0.30 TON
    // reimbursement flows back to them.
    val res = pool.sendWithdraw(
        user, // sender = the depositor themself
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });

    val userAfter = testing.getAccountBalance(user);
    // User received ~RELAYER_REIMBURSEMENT minus forward fee.
    expect(userAfter > userBefore).toEqual(true);
}

get fun `test full accounting: deposit+withdraw conservation`() {
    val (pool, _, jettonWallet) = setupPool();
    val factoryAddr = testing.treasury("factory").address;
    val relayer = testing.treasury("relayer");

    val factoryBalBefore = testing.getAccountBalance(factoryAddr);
    val relayerBalBefore = testing.getAccountBalance(relayer.address);

    // === DEPOSIT ===
    val depositRes = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: ton("0.6") },
    );
    expect(depositRes).toHaveSuccessfulTx({ to: pool.address });
    // No factory forward on deposits in the trustless-no-fee model; pool keeps
    // any handler-gas residual as a storage-rent buffer.
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);

    val poolBalAfterDeposit = testing.getAccountBalance(pool.address);
    val expectedPoolMin = POOL_TON_RESERVE + RELAYER_REIMBURSEMENT;
    // Pool balance >= reserve + earmark. With the trustless-no-fee model the
    // pool also retains the deploy seed and any handler-gas residual; there
    // is no upper bound at the protocol level beyond the inbound message values.
    expect(poolBalAfterDeposit >= expectedPoolMin).toEqual(true);

    // Factory receives nothing from pool ops in the no-fee model.
    val factoryBalAfterDeposit = testing.getAccountBalance(factoryAddr);
    expect(factoryBalAfterDeposit).toEqual(factoryBalBefore);

    // === WITHDRAW (relayer broadcasts) ===
    val withdrawRes = pool.sendWithdraw(
        relayer.address,
        JETTON_QUERY_ID_MASK,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(withdrawRes).toHaveSuccessfulTx({ to: pool.address });
    expect(withdrawRes).toHaveSuccessfulTx({ from: pool.address, to: relayer.address });

    expect(pool.relayerReserve()).toEqual(0);

    // Conservation: the pool released exactly one earmark and kept everything
    // else. Its buffer is NOT swept by the broadcaster.
    val poolBalAfterWithdraw = testing.getAccountBalance(pool.address);
    expect(
        poolBalAfterWithdraw >= poolBalAfterDeposit - RELAYER_REIMBURSEMENT - ton("0.05"),
    ).toEqual(true);
    expect(poolBalAfterWithdraw <= poolBalAfterDeposit).toEqual(true);

    // Broadcaster nets ~RELAYER_REIMBURSEMENT (minus the jetton-transfer gas
    // it covered) plus its unused gas — never the pool buffer.
    val relayerBalAfter = testing.getAccountBalance(relayer.address);
    val relayerNet = relayerBalAfter - relayerBalBefore;
    expect(relayerNet > ton("0.32")).toEqual(true);
    expect(relayerNet < ton("0.38")).toEqual(true);
}

get fun `test deposit below MIN_DEPOSIT_VALUE is refunded (anti-spam)`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: ton("0.2") },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5,
    });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
}

get fun `test deposit just below floor is refunded`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");
    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: ton("0.31") }, // below MIN_DEPOSIT_VALUE (0.32)
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5,
    });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
}

get fun `test factory balance is unchanged by deposits (no admin revenue)`() {
    val (pool, _, jettonWallet) = setupPool();
    val factoryAddr = testing.treasury("factory").address;
    val factoryBalBefore = testing.getAccountBalance(factoryAddr);

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            2,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    // Trustless-no-fee model: factory receives nothing from pool operations.
    // Any handler-gas residual stays on the pool itself as storage buffer.
    val factoryDelta = testing.getAccountBalance(factoryAddr) - factoryBalBefore;
    expect(factoryDelta).toEqual(0);
}

get fun `test deposit at floor 0.32 is accepted`() {
    val (pool, _, jettonWallet) = setupPool();

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
}

get fun `test deposit with surplus refunds excess to fromUser`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");

    // forward_amount = MIN_DEPOSIT_VALUE + 0.10. The 0.10 surplus over the
    // contract floor must come back to fromUser, not silently flow to admin.
    val surplus = ton("0.10");
    val attached = MIN_DEPOSIT_VALUE + surplus;
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: attached },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);

    // A refund tx must exist from the pool to the user.
    expect(res).toHaveSuccessfulTx({ from: pool.address, to: user.address });

    // User balance grew by approximately the surplus (minus forwarding fee).
    val userBalAfter = testing.getAccountBalance(user.address);
    val delta = userBalAfter - userBalBefore;
    expect(delta > surplus - ton("0.01")).toEqual(true);
    expect(delta <= surplus).toEqual(true);
}

// ============================================================================
// Excess-refund edge cases (added after introducing the success-path refund)
// ============================================================================

// At exactly MIN_DEPOSIT_VALUE the branch `if (depositExcess > 0)` must skip
// the send. No zero-value pool→user message can be emitted (would be wasted
// gas + would confuse indexers parsing the deposit's outgoing tx list).
get fun `test deposit at exact floor emits NO excess refund to fromUser`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);

    // No TON refund from pool to user: the only outgoing TON tx from the pool
    // is the forward to factory.
    expect(res).toNotHaveTx({ from: pool.address, to: user.address });
}

// Tiny-excess (floor + 1 nanoTON) must NOT revert the deposit. The refund
// send uses SEND_MODE_IGNORE_ERRORS so a sub-fwd-fee surplus simply drops
// the dust into the pool rent buffer. The deposit itself commits
// normally: tree advances, reserve bumped, no orphaned jettons.
get fun `test deposit floor+1 nanoTON commits normally (refund drops dust safely)`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE + 1 },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });

    // State advances normally despite the dust-sized excess.
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_NEW_ROOT);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
}

// Large excess (5 TON over the floor): user gets ~5 TON back, deposit state
// is the same as a normal-sized one. Guards against any cap or truncation in
// the surplus calculation.
get fun `test deposit with large surplus refunds full excess to fromUser`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");

    val surplus = ton("5.0");
    val attached = MIN_DEPOSIT_VALUE + surplus;
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: attached },
    );
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);

    // Pool→user refund tx is present and worth ~surplus.
    expect(res).toHaveSuccessfulTx({ from: pool.address, to: user.address });

    val userBalAfter = testing.getAccountBalance(user.address);
    val delta = userBalAfter - userBalBefore;
    // Should receive surplus minus tiny forwarding fee (< 0.01 TON).
    expect(delta > surplus - ton("0.01")).toEqual(true);
    expect(delta <= surplus).toEqual(true);
}

// Validation-failure refund path must NOT double-fire the success-path TON
// refund. When the deposit fails on duplicate commitment (or any other
// recoverable validation), refundDeposit() runs and returns BEFORE the
// state-commit + excess-refund block. We assert that the deposit attempt
// emits the jetton refund (TEP-74 transfer back to the JW) but does NOT
// emit a TON refund from pool→fromUser.
get fun `test failed deposit does not double-fire excess refund`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");

    // First deposit (succeeds, advances tree).
    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            user.address,
            buildDepositForwardPayload(),
            { value: MIN_DEPOSIT_VALUE + ton("0.20") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });
    val reserveAfterFirst = pool.relayerReserve();
    val indexAfterFirst = pool.nextIndex();

    val poolBalanceBeforeRefund = testing.getAccountBalance(pool.address);

    // Second deposit with the SAME commitment: hits the duplicate-commitment
    // refund branch. The contract returns the jettons via refundDeposit(),
    // which must NOT be followed by the success-path TON excess refund.
    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        2,
        TEST_DENOMINATION,
        user.address,
        buildDepositForwardPayload(),
        { value: MIN_DEPOSIT_VALUE + ton("0.20") },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });

    // State preserved (no second insert).
    expect(pool.nextIndex()).toEqual(indexAfterFirst);
    expect(pool.relayerReserve()).toEqual(reserveAfterFirst);
    val poolBalanceAfterRefund = testing.getAccountBalance(pool.address);
    expect(poolBalanceAfterRefund - poolBalanceBeforeRefund < ton("0.05")).toEqual(true);

    // Jetton refund leg present (pool sends jettons back through its JW).
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5,
    });
    // CRITICAL: no TON refund from pool to fromUser. The TEP-74 path returns
    // the user's gas surplus via the jetton-transfer response_destination,
    // not via a direct pool→user TON message.
    expect(res).toNotHaveTx({ from: pool.address, to: user.address });
}

get fun `test withdraw before deposit reverts (UnknownRoot)`() {
    val (pool, _, _) = setupPool();
    val res = pool.sendWithdraw(
        testing.treasury("relayer").address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(res).toHaveFailedTx({ to: pool.address, exitCode: Errors.UnknownRoot });
}

// ============================================================================
// Anti-replay: same nullifier cannot be spent twice
// ============================================================================

get fun `test real nullifier replay is rejected`() {
    val (pool, _, jettonWallet) = setupPool();

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    expect(
        pool.sendWithdraw(
            testing.treasury("r1").address,
            2,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            fixtureRecipient(),
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    // Second submission with same nullifier → must fail. The tx is bounceable
    // by default, so the loser of a race only loses ~0.005 TON of gas, not
    // the full attached value. This is the protection against proof-replay
    // griefing in the relayer-public-broadcast model.
    expect(
        pool.sendWithdraw(
            testing.treasury("r2").address,
            3,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            fixtureRecipient(),
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.NullifierAlreadySpent,
    });
}

get fun `test bounced jetton payout can be retried without a second relayer reward`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user");
    val relayer = testing.treasury("relayer");

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            user.address,
            buildDepositForwardPayload(),
            { value: MIN_DEPOSIT_VALUE },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    val res = pool.sendWithdraw(
        relayer.address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(
        res,
    ).toHaveSuccessfulTx({ from: pool.address, to: jettonWallet, opcode: OP_JETTON_TRANSFER });
    val firstTransferTx = res.findTransaction<JettonTransfer>({
        from: pool.address,
        to: jettonWallet,
    })!;
    val firstTransferMessage = firstTransferTx.loadInMsg<JettonTransfer>();
    if (firstTransferMessage.info is TlbInternalMessage) {
        expect(firstTransferMessage.info.bounce).toEqual(true);
    } else {
        expect(false).toEqual(true);
    }
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.isWithdrawalRetryable(2)).toEqual(false);

    expect(
        pool.sendWithdraw(
            testing.treasury("query-reuser").address,
            2,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            fixtureRecipient(),
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({ to: pool.address, exitCode: Errors.WithdrawalNotRetryable });
    expect(pool.isWithdrawalRetryable(2)).toEqual(false);

    val wireQueryId: uint64 = (1 << 63) | 2;
    val bouncedBody = beginCell()
        .storeUint(0xFFFFFFFF, 32)
        .storeSlice(
            (JettonTransfer {
                queryId: wireQueryId,
                amount: TEST_DENOMINATION,
                destination: fixtureRecipient(),
                responseDestination: relayer.address,
            })
                .toCell()
                .beginParse(),
        )
        .endCell();
    val bouncedMessage = createMessage({
        bounce: false,
        dest: pool.address,
        value: JETTON_TRANSFER_GAS,
        body: bouncedBody,
    }).bounced();
    testing.processSingleTraceStep(testing.treasury("attacker").address, bouncedMessage);
    expect(pool.isWithdrawalRetryable(2)).toEqual(false);

    val refundDomainBounce = createMessage({
        bounce: false,
        dest: pool.address,
        value: JETTON_TRANSFER_GAS,
        body: beginCell()
            .storeUint(0xFFFFFFFF, 32)
            .storeSlice(
                (JettonTransfer {
                    queryId: 2,
                    amount: TEST_DENOMINATION,
                    destination: fixtureRecipient(),
                    responseDestination: relayer.address,
                })
                    .toCell()
                    .beginParse(),
            )
            .endCell(),
    }).bounced();
    testing.processSingleTraceStep(jettonWallet, refundDomainBounce);
    expect(pool.isWithdrawalRetryable(2)).toEqual(false);

    val unknownWithdrawalBounce = createMessage({
        bounce: false,
        dest: pool.address,
        value: JETTON_TRANSFER_GAS,
        body: beginCell()
            .storeUint(0xFFFFFFFF, 32)
            .storeSlice(
                (JettonTransfer {
                    queryId: JETTON_WITHDRAW_QUERY_DOMAIN | 999,
                    amount: TEST_DENOMINATION,
                    destination: fixtureRecipient(),
                    responseDestination: relayer.address,
                })
                    .toCell()
                    .beginParse(),
            )
            .endCell(),
    }).bounced();
    val unknownBounceResult = testing.processSingleTraceStep(jettonWallet, unknownWithdrawalBounce);
    val unknownBounceDescription = unknownBounceResult.tx.load().description.load();
    if (unknownBounceDescription is TlbTransOrd) {
        if (unknownBounceDescription.computePh is TlbTrComputeVm) {
            expect(unknownBounceDescription.computePh.success).toEqual(true);
        } else {
            expect(false).toEqual(true);
        }
    } else {
        expect(false).toEqual(true);
    }

    val authenticatedBounce = testing.processSingleTraceStep(jettonWallet, bouncedMessage);
    expect(pool.isWithdrawalRetryable(2)).toEqual(true);
    expect(authenticatedBounce.outMessages.size()).toEqual(1);
    expect(authenticatedBounce.externals.size()).toEqual(0);
    val bounceRefund = (authenticatedBounce
        .outMessages
        .atCell(0) as Cell<TlbMessageRelaxedGeneric>).load();
    expect(bounceRefund.info.dest).toEqual(relayer.address);
    expect(bounceRefund.info.value.grams > 0).toEqual(true);
    expect(bounceRefund.info.bounce).toEqual(false);

    val retrySender = testing.treasury("retry-sender");
    expect(
        pool.sendWithdraw(
            retrySender.address,
            2,
            FIXTURE_WITHDRAW_ROOT + 1,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            fixtureRecipient(),
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({ to: pool.address, exitCode: Errors.InvalidRetry });
    expect(pool.isWithdrawalRetryable(2)).toEqual(true);

    expect(
        pool.sendWithdraw(
            retrySender.address,
            2,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            testing.treasury("attacker-recipient").address,
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({ to: pool.address, exitCode: Errors.InvalidWithdrawProof });
    expect(pool.isWithdrawalRetryable(2)).toEqual(true);

    val retry = pool.sendWithdraw(
        retrySender.address,
        2,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        fixtureRecipient(),
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(retry).toHaveSuccessfulTx({ from: retrySender.address, to: pool.address });
    expect(
        retry.findExternalOutMessage<WithdrawRetriedEvent>({ from: pool.address }) == null,
    ).toEqual(true);
    expect(retry).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: OP_JETTON_TRANSFER,
    });
    val retryTransferTx = retry.findTransaction<JettonTransfer>({
        from: pool.address,
        to: jettonWallet,
    })!;
    val retryTransferMessage = retryTransferTx.loadInMsg<JettonTransfer>();
    if (retryTransferMessage.info is TlbInternalMessage) {
        expect(retryTransferMessage.info.bounce).toEqual(true);
    } else {
        expect(false).toEqual(true);
    }
    expect(retry).toNotHaveTx({ from: pool.address, to: retrySender.address });
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.isWithdrawalRetryable(2)).toEqual(false);

    expect(
        pool.sendWithdraw(
            retrySender.address,
            2,
            FIXTURE_WITHDRAW_ROOT,
            FIXTURE_WITHDRAW_NULLIFIER_HASH,
            fixtureRecipient(),
            realWithdrawProof(),
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({ to: pool.address, exitCode: Errors.WithdrawalNotRetryable });

    val retryBounce = testing.processSingleTraceStep(jettonWallet, bouncedMessage);
    expect(pool.isWithdrawalRetryable(2)).toEqual(true);
    expect(retryBounce.outMessages.size()).toEqual(1);
    val retryBounceRefund = (retryBounce
        .outMessages
        .atCell(0) as Cell<TlbMessageRelaxedGeneric>).load();
    expect(retryBounceRefund.info.dest).toEqual(retrySender.address);
    expect(retryBounceRefund.info.value.grams > 0).toEqual(true);
}

// ============================================================================
// Invalid proof rejected by the on-chain BLS pairing
// ============================================================================

get fun `test deposit with tampered proof is refunded`() {
    val (pool, _, jettonWallet) = setupPool();

    val tamperedPayload: DepositPayload = {
        queryId: 1,
        commitment: FIXTURE_INSERT_COMMITMENT + 1,
        newRoot: FIXTURE_INSERT_NEW_ROOT,
        insertProof: (ZkProof {
            proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
            proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
            proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
        }).toCell(),
    };
    val payloadSlice = beginCell()
        .storeUint(0, 1)
        .storeSlice(tamperedPayload.toCell().beginParse())
        .endCell()
        .beginParse();

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION,
        testing.treasury("user").address,
        payloadSlice,
        { value: ton("0.5") },
    );

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_OLD_ROOT);
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5,
    });
}

get fun `test duplicate commitment is refunded (not throw)`() {
    val (pool, _, jettonWallet) = setupPool();
    val user = testing.treasury("user").address;

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            user,
            buildDepositForwardPayload(),
            { value: ton("0.5") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });
    val rootAfter = pool.currentRoot();
    val indexAfter = pool.nextIndex();

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        2,
        TEST_DENOMINATION,
        user,
        buildDepositForwardPayload(),
        { value: ton("0.5") },
    );
    expect(res).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.currentRoot()).toEqual(rootAfter);
    expect(pool.nextIndex()).toEqual(indexAfter);
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5,
    });
}

// ============================================================================
// Recipient swap on a valid proof is rejected
// ============================================================================
//
// Take a valid proof (root, nullifierHash, recipient=fixture) and submit it
// with a DIFFERENT msg.recipient. The contract derives a different
// recipientField from the new address → pairing check fails. The funds
// remain in the pool.

get fun `test recipient swap is rejected (proof bound by construction)`() {
    val (pool, _, jettonWallet) = setupPool();

    expect(
        pool.sendJettonTransferNotification(
            jettonWallet,
            1,
            TEST_DENOMINATION,
            testing.treasury("user").address,
            buildDepositForwardPayload(),
            { value: ton("0.6") },
        ),
    ).toHaveSuccessfulTx({ to: pool.address });

    // Submit with attacker.address instead of fixtureRecipient().
    val attacker = testing.treasury("attacker").address;
    val res = pool.sendWithdraw(
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
}
