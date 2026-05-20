import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/pool-types"
import "@contracts/ton-pool-types"
import "@tests/proofs-fixture"
import "@wrappers/TonPool.gen"

const TEST_TON_DENOM: coins = 10000000000 // 10 TON

fun fixtureRecipient(): address {
    return address.fromWorkchainAndHash(0, FIXTURE_WITHDRAW_RECIPIENT_HASH_RAW);
}

fun freshTonPool(): TonPool {
    val factoryAddr = testing.treasury("factory").address;
    val identity: TonPoolIdentity = { factory: factoryAddr, denomination: TEST_TON_DENOM };
    val merkle: MerkleState = {
        nextIndex: 0,
        currentRoot: FIXTURE_INSERT_OLD_ROOT,
        rootHistory: [],
        nullifiers: [],
        commitments: [],
    };
    return TonPool.fromStorage({
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    });
}

fun setupDeployedTonPool(): (TonPool, Treasury) {
    val deployer = testing.treasury("deployer");
    val pool = freshTonPool();
    val res = pool.deploy(deployer.address, { value: ton("1") });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    return (pool, deployer);
}

fun fundedTonPool(): TonPool {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");
    expect(
        pool.sendTonDepositPayload(
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

get fun `test TonPool deploys with initial state`() {
    val (pool, _) = setupDeployedTonPool();

    expect(pool.denomination()).toEqual(TEST_TON_DENOM);
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.relayerReserve()).toEqual(0);
    expect(pool.pendingWithdrawTon()).toEqual(0);
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

get fun `test TonPool deposit below floor is refunded`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");
    val userBalBefore = testing.getAccountBalance(user.address);

    val res = pool.sendTonDepositPayload(
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

    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.1")).toEqual(true);
}

get fun `test TonPool deposit with valid proof inserts commitment + earmarks`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");

    val res = pool.sendTonDepositPayload(
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

get fun `test TonPool deposit at exact floor emits NO excess refund`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");

    // Attach exactly denom + MIN_DEPOSIT_VALUE: depositExcess = 0, the refund
    // branch must be skipped (no zero-value pool→user message).
    val attached = TEST_TON_DENOM + MIN_DEPOSIT_VALUE;
    val res = pool.sendTonDepositPayload(
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
}

// Tiny-excess (floor + 1 nanoTON) must NOT revert the TonPool deposit. The
// refund send uses SEND_MODE_IGNORE_ERRORS so a sub-fwd-fee surplus simply
// drops the dust into the forwardToFactory pot. The deposit commits.
get fun `test TonPool deposit floor+1 nanoTON commits normally (refund drops dust safely)`() {
    val (pool, _) = setupDeployedTonPool();
    val user = testing.treasury("user");

    val attached = TEST_TON_DENOM + MIN_DEPOSIT_VALUE + 1;
    val res = pool.sendTonDepositPayload(
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

    // Floor is denom + MIN_DEPOSIT_VALUE = 10 + 0.45 = 10.45. Attach 10.55
    // (0.10 surplus). The contract must refund that 0.10 to fromUser.
    val surplus = ton("0.10");
    val attached = TEST_TON_DENOM + MIN_DEPOSIT_VALUE + surplus;

    val res = pool.sendTonDepositPayload(
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

    val res = pool.sendTonWithdraw(
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

    val recipientDelta = testing.getAccountBalance(recipient) - recipientBalBefore;
    expect(recipientDelta >= TEST_TON_DENOM - ton("0.01")).toEqual(true);
    expect(recipientDelta <= TEST_TON_DENOM).toEqual(true);

    // Sender (= relayer) received RELAYER_REIMBURSEMENT minus tiny forward fee.
    val relayerDelta = testing.getAccountBalance(relayer.address) - relayerBalBefore;
    expect(relayerDelta >= RELAYER_REIMBURSEMENT - ton("0.01")).toEqual(true);
}

get fun `test TonPool self-broadcast: user receives both recipient payout and reimbursement`() {
    val pool = fundedTonPool();

    // User self-broadcasts. msg.recipient must still be the fixture address
    // (binding). Sender being the same address as a coincidence is fine, but
    // in practice the user would use a fresh wallet as recipient for anonymity.
    val recipient = fixtureRecipient();
    val recipientBalBefore = testing.getAccountBalance(recipient);

    val res = pool.sendTonWithdraw(
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

    val res = pool.sendTonWithdraw(
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

get fun `test TonPool nullifier replay is rejected (loser bounces)`() {
    val pool = fundedTonPool();
    val recipient = fixtureRecipient();

    expect(
        pool.sendTonWithdraw(
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
            { value: MIN_WITHDRAW_GAS },
        ),
    ).toHaveFailedTx({
        to: pool.address,
        exitCode: Errors.NullifierAlreadySpent,
    });
}
