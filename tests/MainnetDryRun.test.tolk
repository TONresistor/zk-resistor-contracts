import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/factory-types"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@tests/pool-sparse-helpers"
import "@tests/proofs-fixture"
import "@tests/ton-pool-sparse-helpers"
import "@wrappers/Factory.gen"
import "@wrappers/Pool.gen"
import "@wrappers/TonPool.gen"

// ============================================================================
// MAINNET DRY-RUN: full deploy + lifecycle in sandbox
//
// This test mirrors the exact production flow:
//   1. Deploy Factory
//   2. Create 1 jetton pool
//   3. Create 1 TON pool
//   4. Deposit on jetton pool (real Groth16 proof)
//   5. Withdraw on jetton pool (real proof, sender takes fees)
//   6. Deposit on TON pool (real proof)
//   7. Withdraw on TON pool (real proof)
//
// Passes end-to-end with real BLS pairing if the mainnet deploy will too.
// ============================================================================

const TEST_JETTON_DENOM: coins = 1000
const TEST_TON_DENOM: coins = 10000000000 // 10 TON (whitelisted)

fun fixtureRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun realInsertProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureInsertProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureInsertProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureInsertProofC() }).toCell(),
    };
}

fun realWithdrawProof(): ZkProof {
    return {
        proofA: (G1Point { raw: fixtureWithdrawProofA() }).toCell(),
        proofB: (G2Point { raw: fixtureWithdrawProofB() }).toCell(),
        proofC: (G1Point { raw: fixtureWithdrawProofC() }).toCell(),
    };
}

fun depositPayloadCell(): cell {
    val payload: DepositPayload = {
        queryId: 1,
        commitment: FIXTURE_INSERT_COMMITMENT,
        newRoot: FIXTURE_INSERT_NEW_ROOT,
        insertProof: realInsertProof().toCell(),
        commitmentSetProof: poolEmptySparseSetProof(
            SPARSE_SET_COMMITMENT_DOMAIN,
            FIXTURE_INSERT_COMMITMENT,
        ).toCell(),
    };
    return payload.toCell();
}

fun buildJettonForwardPayload(): slice {
    return beginCell().storeUint(1, 1).storeRef(depositPayloadCell()).endCell().beginParse();
}

get fun `test MAINNET-DRY-RUN: full lifecycle end-to-end`() {
    // === STEP 1: Deploy Factory (mimics deploy-factory.ts) ============
    val deployer = testing.treasury("deployer");
    val registries: Registries = { poolRegistry: [], tonPoolRegistry: [] };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    val factory = Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 0,
        tonPoolCount: 0,
        inFlightCreates: 0,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
    val deployRes = factory.deploy(deployer.address, { value: ton("0.5") });
    expect(deployRes).toHaveSuccessfulDeploy({ to: factory.address });
    expect(factory.poolCount()).toEqual(0);
    expect(factory.tonPoolCount()).toEqual(0);

    // === STEP 2: Create 1 jetton pool (REDO/1000 mimic) ===============
    val jettonMaster = testing.treasury("redo-master").address;
    val poolJw = testing.treasury("pool-redo-jw").address;

    val createRes = factory.sendCreatePool(
        deployer.address,
        1,
        jettonMaster,
        TEST_JETTON_DENOM,
        { value: ton("1.05") }, // matches cli/scripts/create-pool.ts
    );
    expect(createRes).toHaveSuccessfulTx({ to: factory.address });
    expect(factory.poolCount()).toEqual(1);

    val poolAddrOpt = factory.poolAddressFor(jettonMaster, TEST_JETTON_DENOM);
    expect(poolAddrOpt != null).toEqual(true);
    val pool = Pool.fromAddress(poolAddrOpt!);

    // Pool is deployed but jettonWallet still null: it just queried the
    // master via TEP-89. The master treasury has no contract code to reply,
    // so we simulate the canonical take_wallet_address response here.
    expect(pool.jettonWallet()).toEqual(null);
    val takeRes = pool.sendTakeWalletAddress(
        jettonMaster,
        1,
        poolJw,
        createEmptySlice(),
        { value: ton("0.05") },
    );
    expect(takeRes).toHaveSuccessfulTx({ from: jettonMaster, to: pool.address });
    expect(pool.jettonWallet()).toEqual(poolJw);
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.currentRoot()).toEqual(EMPTY_TREE_ROOT);

    // === STEP 3: Create 1 TON pool (TON-10) ===========================
    val createTonRes = factory.sendCreateTonPool(
        deployer.address,
        2,
        TEST_TON_DENOM,
        { value: ton("1.05") }, // matches cli/scripts/create-ton-pool.ts
    );
    expect(createTonRes).toHaveSuccessfulTx({ to: factory.address });
    expect(factory.tonPoolCount()).toEqual(1);

    val tonPoolAddrOpt = factory.tonPoolAddressFor(TEST_TON_DENOM);
    expect(tonPoolAddrOpt != null).toEqual(true);
    val tonPool = TonPool.fromAddress(tonPoolAddrOpt!);
    expect(tonPool.denomination()).toEqual(TEST_TON_DENOM);
    expect(tonPool.nextIndex()).toEqual(0);

    // === STEP 4: Deposit on jetton pool (real proof) ==================
    val user = testing.treasury("user");
    val depRes = pool.sendJettonTransferNotification(
        poolJw,
        100,
        TEST_JETTON_DENOM,
        user.address,
        buildJettonForwardPayload(),
        { value: ton("0.6") },
    );
    expect(depRes).toHaveSuccessfulTx({ from: poolJw, to: pool.address });
    expect(pool.nextIndex()).toEqual(1);
    expect(pool.currentRoot()).toEqual(FIXTURE_INSERT_NEW_ROOT);
    expect(pool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);

    // No factory forward in the trustless-no-fee model: pool keeps the
    // handler-gas residual as a storage-rent buffer.

    // === STEP 5: Withdraw on jetton pool (real proof, sender takes fees) ===
    val relayer = testing.treasury("relayer");
    val recipient = fixtureRecipient();
    val _recipientBalBefore = testing.getAccountBalance(recipient);
    val relayerBalBefore = testing.getAccountBalance(relayer.address);

    val wdRes = pool.sendWithdrawWithEmptySparseProof(
        relayer.address,
        200,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        recipient,
        realWithdrawProof(),
        { value: MIN_JETTON_WITHDRAW_GAS },
    );
    expect(wdRes).toHaveSuccessfulTx({ to: pool.address });
    expect(pool.relayerReserve()).toEqual(0);

    // Recipient got... nothing in this test (no real jetton wallet to deliver).
    // What we can verify: pool sent the JettonTransfer to its jw, and paid
    // the relayer in TON.
    expect(wdRes).toHaveSuccessfulTx({
        from: pool.address,
        to: poolJw,
        opcode: 0x0f8a7ea5, // JettonTransfer to recipient via pool's jw
    });
    expect(wdRes).toHaveSuccessfulTx({
        from: pool.address,
        to: relayer.address, // RELAYER_REIMBURSEMENT in TON
    });

    // Relayer attached MIN_JETTON_WITHDRAW_GAS, receives everything above
    // POOL_TON_RESERVE: released RELAYER_REIMBURSEMENT plus any pool buffer
    // (deploy seed + prior handler-gas residuals).
    val relayerNet = testing.getAccountBalance(relayer.address) - relayerBalBefore;
    expect(relayerNet > ton("0.20")).toEqual(true);

    // === STEP 6: Deposit on TON pool (real proof) =====================
    val tonUser = testing.treasury("ton-user");
    val tonDepRes = tonPool.sendTonDepositWithEmptySparseProof(
        tonUser.address,
        300,
        tonUser.address,
        FIXTURE_INSERT_COMMITMENT,
        FIXTURE_INSERT_NEW_ROOT,
        realInsertProof(),
        { value: ton("10.6") }, // 10 denom + 0.55 floor + headroom
    );
    expect(tonDepRes).toHaveSuccessfulTx({ to: tonPool.address });
    expect(tonPool.nextIndex()).toEqual(1);
    expect(tonPool.relayerReserve()).toEqual(RELAYER_REIMBURSEMENT);
    expect(tonPool.pendingWithdrawTon()).toEqual(TEST_TON_DENOM);

    // === STEP 7: Withdraw on TON pool (real proof) ====================
    val tonRecipientBalBefore = testing.getAccountBalance(recipient);
    val tonWdRes = tonPool.sendTonWithdrawWithEmptySparseProof(
        relayer.address,
        400,
        FIXTURE_WITHDRAW_ROOT,
        FIXTURE_WITHDRAW_NULLIFIER_HASH,
        recipient,
        realWithdrawProof(),
        { value: MIN_WITHDRAW_GAS },
    );
    expect(tonWdRes).toHaveSuccessfulTx({ to: tonPool.address });
    expect(tonPool.relayerReserve()).toEqual(0);
    expect(tonPool.pendingWithdrawTon()).toEqual(0);

    // Recipient received the 10 TON denomination directly.
    val tonRecipientDelta = testing.getAccountBalance(recipient) - tonRecipientBalBefore;
    expect(tonRecipientDelta >= TEST_TON_DENOM - ton("0.01")).toEqual(true);
    expect(tonRecipientDelta <= TEST_TON_DENOM).toEqual(true);

    // No admin in this protocol: factory accumulates nothing from pool ops.
    // Each create retains only its bounded registry allocation; pools do not
    // forward operational revenue back to Factory.
    val factoryBalEnd = testing.getAccountBalance(factory.address);
    expect(factoryBalEnd >= FACTORY_TON_RESERVE).toEqual(true);
    expect(
        factoryBalEnd <= ton("0.5") + FACTORY_CREATE_RETAINED_VALUE * 2 + ton("0.02"),
    ).toEqual(true);
}

get fun `test MAINNET-DRY-RUN: TonPool with bad denom rejected at factory`() {
    val deployer = testing.treasury("deployer");
    val registries: Registries = { poolRegistry: [], tonPoolRegistry: [] };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    val factory = Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 0,
        tonPoolCount: 0,
        inFlightCreates: 0,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
    expect(
        factory.deploy(deployer.address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    // 42 TON is not in the whitelist {10, 100, 1000, 10000}.
    val res = factory.sendCreateTonPool(
        deployer.address,
        1,
        42000000000,
        { value: ton("1.05") },
    );
    expect(res).toHaveFailedTx({
        to: factory.address,
        exitCode: Errors.InvalidDenomination,
    });
    expect(factory.tonPoolCount()).toEqual(0);
}
