import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/pool-types"
import "@wrappers/Pool.gen"

const TEST_DENOMINATION: coins = 100

fun freshPool(jettonWallet: address): Pool {
    val jettonMaster = testing.treasury("jetton-master").address;
    val factoryAddr = testing.treasury("factory").address;
    val identity: PoolIdentity = {
        jettonMaster,
        factory: factoryAddr,
        denomination: TEST_DENOMINATION,
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
        jettonWallet, // pre-set for these tests; in prod the factory sets it
        relayerReserve: 0,
        merkle: merkle.toCell(),
    });
}

fun setupDeployedPool(): (Pool, Treasury, address) {
    val deployer = testing.treasury("deployer");
    val jettonWalletTreasury = testing.treasury("pool-jetton-wallet");
    val jettonWallet = jettonWalletTreasury.address;

    val pool = freshPool(jettonWallet);
    val res = pool.deploy(deployer.address, { value: ton("1") });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });

    return (pool, deployer, jettonWallet);
}

get fun `test deploy succeeds and exposes initial getters`() {
    val (pool, _, jettonWallet) = setupDeployedPool();

    expect(pool.denomination()).toEqual(TEST_DENOMINATION);
    expect(pool.jettonWallet()).toEqual(jettonWallet);
    expect(pool.currentRoot()).toEqual(0);
    expect(pool.nextIndex()).toEqual(0);
    expect(pool.treeDepth()).toEqual(MERKLE_TREE_DEPTH);
}

get fun `test deposit from non-jetton-wallet is silently dropped`() {
    val (pool, _, _) = setupDeployedPool();
    val attacker = testing.treasury("attacker");

    // Forged notification: sender != pool's jetton wallet. Refunding would
    // gift jettons to the attacker (no real transfer happened); pool just
    // ignores the message silently.
    val res = pool.sendJettonTransferNotification(
        attacker.address,
        1,
        TEST_DENOMINATION,
        attacker.address,
        createEmptySlice(),
        { value: ton("0.2") },
    );

    expect(res).toHaveSuccessfulTx({
        from: attacker.address,
        to: pool.address,
    });
    expect(pool.nextIndex()).toEqual(0); // pool state unchanged
}

get fun `test deposit with wrong amount is refunded`() {
    val (pool, _, jettonWallet) = setupDeployedPool();
    val user = testing.treasury("user");

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION + 1,
        user.address,
        createEmptySlice(),
        { value: ton("0.5") },
    );

    // Tx should succeed (refund path), pool state unchanged, and the pool
    // must have emitted an outgoing JettonTransfer to its jetton wallet.
    expect(res).toHaveSuccessfulTx({ from: jettonWallet, to: pool.address });
    expect(pool.nextIndex()).toEqual(0);
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5, // OP_JETTON_TRANSFER (refund leg)
    });
}

get fun `test withdraw with insufficient gas is rejected`() {
    val (pool, _, _) = setupDeployedPool();
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
        { value: ton("0.05") },
    );

    expect(res).toHaveFailedTx({
        from: anyone.address,
        to: pool.address,
        exitCode: Errors.InsufficientGas,
    });
}

get fun `test unknown non-empty message is rejected`() {
    val (pool, deployer, _) = setupDeployedPool();

    val res = pool.sendAny(
        deployer.address,
        beginCell().storeUint(0xdeadbeef, 32).endCell(),
        { value: ton("0.05") },
    );

    expect(res).toHaveFailedTx({
        from: deployer.address,
        to: pool.address,
        exitCode: Errors.InvalidMessage,
    });
}

get fun `test empty body (balance top-up) is accepted`() {
    val (pool, deployer, _) = setupDeployedPool();

    val res = pool.sendAny(deployer.address, createEmptyCell(), { value: ton("0.05") });

    expect(res).toHaveSuccessfulTx({
        from: deployer.address,
        to: pool.address,
    });
}

// ============================================================================
// Refund / no-forward tests: refundDeposit must send back the jettons and
// NOT forward any TON to the factory (trustless-no-fee model).
// ============================================================================

get fun `test refund deposit emits jetton refund without factory forward`() {
    val (pool, _, jettonWallet) = setupDeployedPool();
    val user = testing.treasury("user");
    val factoryAddr = testing.treasury("factory").address;
    val factoryBalBefore = testing.getAccountBalance(factoryAddr);

    val res = pool.sendJettonTransferNotification(
        jettonWallet,
        1,
        TEST_DENOMINATION + 1,
        user.address,
        createEmptySlice(),
        { value: ton("0.5") },
    );

    // Refund leg present: jettons go back to the pool's JW.
    expect(res).toHaveSuccessfulTx({
        from: pool.address,
        to: jettonWallet,
        opcode: 0x0f8a7ea5,
    });
    // Factory balance is unchanged: no admin-fee forward in this model.
    val factoryBalAfter = testing.getAccountBalance(factoryAddr);
    expect(factoryBalAfter).toEqual(factoryBalBefore);
}
