import "@stdlib/gas-payments"
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/out_actions"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/deployment-types"
import "@contracts/errors"
import "@contracts/factory-types"
import "@contracts/pool-types"
import "@wrappers/Factory.gen"
import "@wrappers/Pool.gen"

const FACTORY_TEN_YEARS_SECONDS: int = 10 * 365 * 24 * 60 * 60
const MAX_FACTORY_STATE_CELLS: int = 16384

fun freshFactory(): Factory {
    val registries: Registries = {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    return Factory.fromStorage({
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
}

fun setupDeployedFactory(): (Factory, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val user = testing.treasury("user");

    val factory = freshFactory();
    val res = factory.deploy(deployer.address, { value: ton("1") });
    expect(res).toHaveSuccessfulDeploy({ to: factory.address });

    return (factory, deployer, user);
}

fun activeFactoryShardAccount(factory: Factory): TlbShardAccount {
    val shard = testing.getShardAccount(factory.address);
    if (shard == null) {
        Assert.fail("Expected deployed Factory account");
    }
    return shard!;
}

fun setFactoryBalance(factory: Factory, balance: coins) {
    var shard = activeFactoryShardAccount(factory);
    val account = shard.account.load();
    if (account !is TlbAccountInfo) {
        Assert.fail("Expected active Factory account");
    }
    var info = account;
    info.storage.balance.grams = balance;
    shard.account = (info as TlbAccount).toCell();
    testing.setShardAccount(factory.address, shard);
}

fun factoryRentBudgetForTest(totalPools: int): coins {
    return FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * totalPools;
}

fun factoryReservedAmount(result: SendResultList, factory: Factory): coins? {
    var factoryResult: SendResult? = null;
    var resultIndex = 0;
    while (resultIndex < result.size()) {
        val item = result.at(resultIndex);
        if (factoryResult == null && item.tx.load().getAccountAddress() == factory.address) {
            factoryResult = item;
        }
        resultIndex += 1;
    }
    if (factoryResult == null) {
        return null;
    }

    val actions = factoryResult!.allOutActions();
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

fun expectSingleFactoryStepExit(result: SendResult, exitCode: int) {
    val description = result.tx.load().description.load();
    if (description !is TlbTransOrd) {
        Assert.fail("Expected ordinary Factory transaction");
    }
    val compute = description.computePh;
    if (compute !is TlbTrComputeVm) {
        Assert.fail("Expected Factory VM compute phase");
    }
    expect(compute.success).toEqual(false);
    expect(compute.data.load().exitCode).toEqual(exitCode as int32);
}

get fun `test factory deploys with zero pools registered`() {
    val (factory, _, _) = setupDeployedFactory();
    expect(factory.poolCount()).toEqual(0);
}

get fun `test createPool deploys a pool and registers it`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;
    val denom: coins = 100;

    val expectedAddr = factory.expectedPoolAddress(jettonMaster, denom);

    val res = factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        denom,
        { value: ton("1") },
    );

    expect(res).toHaveSuccessfulTx({
        from: user.address,
        to: factory.address,
    });
    val deployTx = res.findTransaction<ConfirmPoolDeployment>({
        from: factory.address,
        to: expectedAddr,
    })!;
    val deployMsg = deployTx.loadInMsg<ConfirmPoolDeployment>();
    if (deployMsg.info is TlbInternalMessage) {
        expect(deployMsg.info.bounce).toEqual(true);
    } else {
        expect(false).toEqual(true);
    }

    expect(factory.poolCount()).toEqual(1);
    expect(factory.poolAddressFor(jettonMaster, denom)).toEqual(expectedAddr);
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.poolDeploymentPending(jettonMaster, denom)).toEqual(true);
    expect(factory.pendingCreateSender(expectedAddr)).toEqual(user.address);

    val pool = Pool.fromAddress(expectedAddr);
    expect(
        pool.sendTakeWalletAddress(
            jettonMaster,
            1,
            testing.treasury("usdt-pool-wallet").address,
            createEmptySlice(),
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx({ from: expectedAddr, to: factory.address, opcode: 0x46504301 });
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.poolDeploymentPending(jettonMaster, denom)).toEqual(false);
    expect(factory.pendingCreateSender(expectedAddr)).toEqual(null);
}

get fun `test createPool fails on duplicate (jetton, denom)`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;
    val denom: coins = 100;

    expect(
        factory.sendCreatePool(
            user.address,
            1,
            jettonMaster,
            denom,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulTx({ from: user.address, to: factory.address });

    expect(
        factory.sendCreatePool(
            user.address,
            2,
            jettonMaster,
            denom,
            { value: ton("1") },
        ),
    ).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.PoolAlreadyExists,
    });
}

get fun `test createPool with zero denomination is rejected`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;

    val res = factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        0,
        { value: ton("1") },
    );

    expect(res).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InvalidDenomination,
    });
}

// ============================================================================
// CreatePool fee enforcement (0.45 TON floor for both pool types)
// ============================================================================

get fun `test createPool with insufficient fee is rejected`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;

    // Below MIN_CREATE_JETTON_POOL_FEE (0.45 TON).
    val res = factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        100,
        { value: ton("0.05") },
    );
    expect(res).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InsufficientCreatePoolFee,
    });
}

get fun `test createPool accepts exact minimum fee`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;
    val expectedPool = factory.expectedPoolAddress(jettonMaster, 100);

    val res = factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        100,
        { value: MIN_CREATE_JETTON_POOL_FEE },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.poolCount()).toEqual(1);
    expect(testing.getAccountBalance(expectedPool) >= POOL_BASE_RENT_RUNWAY).toEqual(true);
}

get fun `test createTonPool with insufficient fee is rejected`() {
    val (factory, _, user) = setupDeployedFactory();

    val res = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: ton("0.05") },
    );
    expect(res).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InsufficientCreatePoolFee,
    });
}

get fun `test createTonPool accepts exact minimum fee`() {
    val (factory, _, user) = setupDeployedFactory();

    val res = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: MIN_CREATE_TON_POOL_FEE },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.tonPoolCount()).toEqual(1);
}

get fun `test createPool accepts when prior balance exactly equals current rent budget`() {
    val factory = freshFactory();
    val deployer = testing.treasury("exact-jetton-balance-deployer");
    val user = testing.treasury("exact-jetton-balance-user");
    expect(factory.deploy(deployer.address, { value: ton("1") })).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    setFactoryBalance(factory, factoryRentBudgetForTest(0));

    val result = factory.sendCreatePool(
        user.address,
        1,
        testing.treasury("exact-jetton-balance-master").address,
        100,
        { value: MIN_CREATE_JETTON_POOL_FEE },
    );
    expect(result).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.poolCount()).toEqual(1);
}

get fun `test createTonPool accepts exact prior balance and forwards exact caller-funded value`() {
    val factory = freshFactory();
    val deployer = testing.treasury("exact-ton-balance-deployer");
    val user = testing.treasury("exact-ton-balance-user");
    expect(factory.deploy(deployer.address, { value: ton("1") })).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    setFactoryBalance(factory, factoryRentBudgetForTest(0));
    val expectedPool = factory.expectedTonPoolAddress(TON_POOL_DENOM_100);

    val result = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: MIN_CREATE_TON_POOL_FEE },
    );
    expect(result).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    val deployTx = result.findTransaction<ConfirmPoolDeployment>({
        from: factory.address,
        to: expectedPool,
    })!;
    val deployMessage = deployTx.loadInMsg<ConfirmPoolDeployment>();
    if (deployMessage.info is TlbInternalMessage) {
        val nominal = MIN_CREATE_TON_POOL_FEE - FACTORY_CREATE_RETAINED_VALUE;
        // The receiver observes nominal value minus forwarding fees. Keep a
        // tight band that still detects adding, rather than subtracting, the
        // Factory retained amount.
        expect(deployMessage.info.value.grams <= nominal).toEqual(true);
        expect(deployMessage.info.value.grams >= nominal - ton("0.005")).toEqual(true);
    } else {
        Assert.fail("Expected internal TonPool deploy message");
    }
    expect(factory.tonPoolCount()).toEqual(1);
}

// ============================================================================
// CreateTonPool (native TON pools with fixed-denomination whitelist)
// ============================================================================

get fun `test createTonPool deploys a TonPool at whitelisted denom`() {
    val (factory, _, user) = setupDeployedFactory();
    val denom: coins = TON_POOL_DENOM_100;
    val expectedAddr = factory.expectedTonPoolAddress(denom);

    val res = factory.sendCreateTonPool(user.address, 1, denom, { value: ton("1") });

    expect(res).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    val deployTx = res.findTransaction({
        from: factory.address,
        to: expectedAddr,
    })!;
    val deployMsg = deployTx.messages.load().inMsg.unwrap().load();
    expect(deployMsg.info.bounce).toEqual(true);
    expect(factory.tonPoolCount()).toEqual(1);
    expect(factory.tonPoolAddressFor(denom)).toEqual(expectedAddr);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.tonPoolDeploymentPending(denom)).toEqual(false);
    expect(factory.pendingCreateSender(expectedAddr)).toEqual(null);
}

get fun `test createTonPool fails on non-whitelisted denom`() {
    val (factory, _, user) = setupDeployedFactory();

    val res = factory.sendCreateTonPool(user.address, 1, ton("77"), { value: ton("1") });

    expect(res).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InvalidDenomination,
    });
}

get fun `test createTonPool fails on duplicate denom`() {
    val (factory, _, user) = setupDeployedFactory();
    val denom: coins = TON_POOL_DENOM_10;

    expect(
        factory.sendCreateTonPool(user.address, 1, denom, { value: ton("1") }),
    ).toHaveSuccessfulTx({ from: user.address, to: factory.address });

    expect(
        factory.sendCreateTonPool(user.address, 2, denom, { value: ton("1") }),
    ).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.PoolAlreadyExists,
    });
}

get fun `test factory retains REGISTRY_RENT_PER_POOL per CreatePool`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster1 = testing.treasury("master-1").address;
    val jettonMaster2 = testing.treasury("master-2").address;

    val balBefore = testing.getAccountBalance(factory.address);
    factory.sendCreatePool(user.address, 1, jettonMaster1, 100, { value: ton("1") });
    val balAfterFirst = testing.getAccountBalance(factory.address);

    factory.sendCreatePool(user.address, 2, jettonMaster2, 100, { value: ton("1") });
    val balAfterSecond = testing.getAccountBalance(factory.address);

    val targetAfterFirst: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL;
    val targetAfterSecond: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * 2;
    val slack: coins = 10000000; // 0.01 TON slack for storage rent / action fees
    expect(balAfterFirst >= targetAfterFirst - slack).toEqual(true);
    expect(balAfterSecond >= targetAfterSecond - slack).toEqual(true);

    // Each caller funds at least its own registry growth. The explicit deploy
    // value leaves only FACTORY_CREATE_RETAINED_VALUE on this Factory, so the
    // upper bound also proves prior balances are not involved in forwarding.
    val firstDelta = balAfterFirst - balBefore;
    val delta = balAfterSecond - balAfterFirst;
    expect(firstDelta >= REGISTRY_RENT_PER_POOL - slack).toEqual(true);
    expect(firstDelta <= FACTORY_CREATE_RETAINED_VALUE + slack).toEqual(true);
    expect(delta >= REGISTRY_RENT_PER_POOL - slack).toEqual(true);
    expect(delta <= FACTORY_CREATE_RETAINED_VALUE + slack).toEqual(true);
}

get fun `test factory tracks jetton + TON pools independently`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;

    // 1 jetton pool + 1 TON pool deployed.
    expect(
        factory.sendCreatePool(
            user.address,
            1,
            jettonMaster,
            100,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulTx({ to: factory.address });

    expect(
        factory.sendCreateTonPool(user.address, 2, TON_POOL_DENOM_100, { value: ton("1") }),
    ).toHaveSuccessfulTx({ to: factory.address });

    expect(factory.poolCount()).toEqual(1);
    expect(factory.tonPoolCount()).toEqual(1);
}

get fun `test factory retains rent for mixed jetton and TON pools`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;

    expect(
        factory.sendCreatePool(
            user.address,
            1,
            jettonMaster,
            100,
            { value: MIN_CREATE_JETTON_POOL_FEE },
        ),
    ).toHaveSuccessfulTx({ to: factory.address });
    setFactoryBalance(factory, factoryRentBudgetForTest(1));
    expect(
        factory.sendCreateTonPool(
            user.address,
            2,
            TON_POOL_DENOM_100,
            { value: MIN_CREATE_TON_POOL_FEE },
        ),
    ).toHaveSuccessfulTx({ to: factory.address });

    val balance = testing.getAccountBalance(factory.address);
    val target: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * 2;
    val slack: coins = 1000000;
    expect(balance >= target - slack).toEqual(true);
}

get fun `test factory retains rent for TON then jetton pools`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;

    factory.sendCreateTonPool(user.address, 1, TON_POOL_DENOM_100, { value: ton("1") });
    factory.sendCreatePool(
        user.address,
        2,
        jettonMaster,
        100,
        { value: ton("1") },
    );

    val balance = testing.getAccountBalance(factory.address);
    val target: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * 2;
    val slack: coins = 10000000;
    expect(balance >= target - slack).toEqual(true);
}

get fun `test factory accepts empty body (passive forward)`() {
    val (factory, _, user) = setupDeployedFactory();

    val res = factory.sendAny(user.address, createEmptyCell(), { value: ton("0.5") });

    expect(res).toHaveSuccessfulTx({
        from: user.address,
        to: factory.address,
    });
}

get fun `test createPool never sweeps a prior passive donation`() {
    val (factory, _, user) = setupDeployedFactory();
    val donor = testing.treasury("factory-donor");
    expect(
        factory.sendAny(donor.address, createEmptyCell(), { value: ton("0.5") }),
    ).toHaveSuccessfulTx({ to: factory.address });
    val balanceBeforeCreate = testing.getAccountBalance(factory.address);
    val master = testing.treasury("donation-isolation-master").address;
    val poolAddress = factory.expectedPoolAddress(master, 100);

    val result = factory.sendCreatePool(
        user.address,
        77,
        master,
        100,
        { value: MIN_CREATE_JETTON_POOL_FEE },
    );
    expect(result).toHaveSuccessfulTx({ to: factory.address });
    val deployTx = result.findTransaction<ConfirmPoolDeployment>({
        from: factory.address,
        to: poolAddress,
    })!;
    val deployMessage = deployTx.loadInMsg<ConfirmPoolDeployment>();
    if (deployMessage.info is TlbInternalMessage) {
        expect(
            deployMessage.info.value.grams <=
            MIN_CREATE_JETTON_POOL_FEE - FACTORY_CREATE_RETAINED_VALUE,
        ).toEqual(true);
        expect(deployMessage.info.value.grams >= ton("0.40")).toEqual(true);
    } else {
        expect(false).toEqual(true);
    }
    expect(testing.getAccountBalance(factory.address) >= balanceBeforeCreate).toEqual(true);
}

get fun `test underfunded Factory cannot charge a new creator for old runway`() {
    val factory = freshFactory();
    val deployer = testing.treasury("underfunded-factory-deployer");
    val user = testing.treasury("underfunded-factory-user");
    expect(
        factory.deploy(deployer.address, { value: ton("0.10") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(
        factory.sendCreatePool(
            user.address,
            1,
            testing.treasury("underfunded-factory-master").address,
            100,
            { value: MIN_CREATE_JETTON_POOL_FEE },
        ),
    ).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InsufficientBalance,
    });
    expect(factory.poolCount()).toEqual(0);
}

get fun `test factory rejects unknown non-empty body`() {
    val (factory, _, user) = setupDeployedFactory();

    val res = factory.sendAny(
        user.address,
        beginCell().storeUint(0xdeadbeef, 32).endCell(),
        { value: ton("0.05") },
    );

    expect(res).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InvalidMessage,
    });
}

get fun `test createPool rejects trailing data without registering pool`() {
    val (factory, _, user) = setupDeployedFactory();
    val canonical = (CreatePool {
        queryId: 1,
        jettonMaster: testing.treasury("trailing-create-master").address,
        denomination: 100,
    }).toCell();
    val withTrailing = beginCell().storeSlice(canonical.beginParse()).storeBool(true).endCell();
    val result = factory.sendAny(user.address, withTrailing, { value: ton("1") });
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InvalidMessage,
    });
    expect(factory.totalPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
}

get fun `test createTonPool rejects trailing data without registering pool`() {
    val (factory, _, user) = setupDeployedFactory();
    val canonical = (CreateTonPool {
        queryId: 1,
        denomination: TON_POOL_DENOM_100,
    }).toCell();
    val withTrailing = beginCell().storeSlice(canonical.beginParse()).storeBool(true).endCell();
    val result = factory.sendAny(user.address, withTrailing, { value: ton("1") });
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InvalidMessage,
    });
    expect(factory.totalPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
}

// ============================================================================
// BOUNCE ROLLBACK: verify onBouncedMessage cleans the phantom registry
// ============================================================================
//
// We can't directly inject a bounced message through the sandbox API, so we
// force a real deploy bounce by giving the factory a `poolCode` that does
// NOT understand the ConfirmPoolDeployment body (we swap in TonPool's
// code under the `poolCode` slot). When CreatePool runs:
//
//   1. Factory persists the (jettonMaster, denomination) → poolAddress entry
//      in both forward + reverse maps, then sends the deploy with bounce: true.
//   2. The ghost pool (= TonPool code at the Pool identity address)
//      receives ConfirmPoolDeployment and rejects the unknown opcode,
//      throws InvalidMessage.
//   3. The message bounces back to the factory.
//   4. Factory.onBouncedMessage looks up `in.senderAddress` in the reverse
//      map, finds the entry, deletes the registry + reverse map entries
//      and decrements poolCount.
//
// The post-state must therefore show an empty registry, proving the rollback
// path is actually wired up.

fun factoryWithGuaranteedBounce(): Factory {
    // TonPool does not accept the Jetton Pool deployment state, so deployment
    // deterministically bounces before any callback can clean the reverse map.
    val registries: Registries = {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    return Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("TonPool"), // intentionally wrong: guarantees bounce
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 0,
        tonPoolCount: 0,
        inFlightCreates: 0,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
}

fun factoryWithGuaranteedTonBounce(): Factory {
    return Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("Pool"), // intentionally wrong: rejects the TON Pool state
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
}

fun factoryWithJettonCreateSenderMissing(poolAddress: address): Factory {
    val key: uint256 = 0xA11CE;
    var poolRegistry: map<uint256, address> = [];
    var poolAddressToKey: map<address, uint256> = [];
    poolRegistry.set(key, poolAddress);
    poolAddressToKey.set(poolAddress, key);
    val registries: Registries = {
        poolRegistry,
        poolAddressToKey,
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    return Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 1,
        tonPoolCount: 0,
        inFlightCreates: 1,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
}

fun factoryWithTonCreateSenderMissing(poolAddress: address): Factory {
    val key: uint256 = 0xB0B;
    var tonPoolRegistry: map<uint256, address> = [];
    var tonPoolAddressToKey: map<address, uint256> = [];
    tonPoolRegistry.set(key, poolAddress);
    tonPoolAddressToKey.set(poolAddress, key);
    val registries: Registries = {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry,
        tonPoolAddressToKey,
    };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    return Factory.fromStorage({
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 0,
        tonPoolCount: 1,
        inFlightCreates: 1,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
}

get fun `test factory rolls back registry when jetton pool deploy bounces`() {
    val factory = factoryWithGuaranteedBounce();
    val deployer = testing.treasury("rollback-deployer");
    val user = testing.treasury("rollback-user");
    val jettonMaster = testing.treasury("rollback-jm").address;
    val denom: coins = 100;

    expect(
        factory.deploy(deployer.address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    expect(factory.poolCount()).toEqual(0);

    // CreatePool inserts the phantom entry, sends bounceable deploy, the
    // ghost pool throws, the bounce returns to factory.onBouncedMessage,
    // and the rollback runs.
    val userBalBefore = testing.getAccountBalance(user.address);
    val firstRes = factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        denom,
        { value: ton("1.5") },
    );

    // Post-rollback state: registry empty, count back to 0.
    expect(firstRes).toHaveSuccessfulTx({ from: factory.address, to: user.address });
    val userBalAfter = testing.getAccountBalance(user.address);
    expect(userBalAfter > userBalBefore - ton("0.2")).toEqual(true);
    expect(factory.poolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.poolAddressFor(jettonMaster, denom)).toEqual(null);

    // The (jettonMaster, denom) pair should be deployable again. (With the
    // intentionally-broken poolCode it will bounce again, but the second
    // CreatePool must not be rejected by PoolAlreadyExists.)
    val secondRes = factory.sendCreatePool(
        user.address,
        2,
        jettonMaster,
        denom,
        { value: ton("1.5") },
    );
    // Successful at the factory level (it accepted the request and tried
    // again). Bouncing is fine: what we're proving is "no permanent lock".
    expect(secondRes).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.poolCount()).toEqual(0); // rolled back again
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.poolAddressFor(jettonMaster, denom)).toEqual(null);
}

get fun `test factory rolls back registry when TON pool deploy bounces`() {
    val factory = factoryWithGuaranteedTonBounce();
    val deployer = testing.treasury("ton-rollback-deployer");
    val user = testing.treasury("ton-rollback-user");
    val denom: coins = TON_POOL_DENOM_10;
    expect(factory.deploy(deployer.address, { value: ton("0.5") })).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    val tonPoolAddr = factory.expectedTonPoolAddress(denom);

    val first = factory.sendCreateTonPool(user.address, 1, denom, { value: ton("1") });
    expect(first).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(first).toHaveSuccessfulTx({ from: factory.address, to: user.address });
    expect(factory.tonPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.tonPoolAddressFor(denom)).toEqual(null);

    val secondRes = factory.sendCreateTonPool(user.address, 2, denom, { value: ton("1") });
    expect(secondRes).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.tonPoolCount()).toEqual(0);
    expect(factory.tonPoolAddressFor(denom)).toEqual(null);
    expect(factory.expectedTonPoolAddress(denom)).toEqual(tonPoolAddr);
}

get fun `test factory rollback tolerates missing jetton creator entry`() {
    val poolAddress = testing.treasury("legacy-jetton-pool").address;
    val factory = factoryWithJettonCreateSenderMissing(poolAddress);
    expect(
        factory.deploy(testing.treasury("legacy-deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell()
            .storeUint(0xFFFFFFFF, 32)
            .storeSlice((ConfirmPoolDeployment { queryId: 1 }).toCell().beginParse())
            .endCell(),
    }).bounced();

    val bounceRes = testing.processSingleTraceStep(poolAddress, bouncedMessage);

    expect(factory.poolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(bounceRes.outMessages.size()).toEqual(0);
}

get fun `test factory rollback tolerates missing TON creator entry`() {
    val poolAddress = testing.treasury("legacy-ton-pool").address;
    val factory = factoryWithTonCreateSenderMissing(poolAddress);
    expect(
        factory.deploy(testing.treasury("legacy-deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell()
            .storeUint(0xFFFFFFFF, 32)
            .storeSlice((ConfirmPoolDeployment { queryId: 1 }).toCell().beginParse())
            .endCell(),
    }).bounced();

    val bounceRes = testing.processSingleTraceStep(poolAddress, bouncedMessage);

    expect(factory.tonPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(bounceRes.outMessages.size()).toEqual(0);
}

get fun `test factory ignores unknown bounced sender without changing registries`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("known-jm").address;
    val jettonDenom: coins = 100;
    val tonDenom: coins = TON_POOL_DENOM_100;
    val jettonPoolAddr = factory.expectedPoolAddress(jettonMaster, jettonDenom);
    val tonPoolAddr = factory.expectedTonPoolAddress(tonDenom);

    expect(
        factory.sendCreatePool(user.address, 1, jettonMaster, jettonDenom, { value: ton("1") }),
    ).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(
        factory.sendCreateTonPool(user.address, 2, tonDenom, { value: ton("1") }),
    ).toHaveSuccessfulTx({ from: user.address, to: factory.address });

    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell()
            .storeUint(0xFFFFFFFF, 32)
            .storeSlice((ConfirmPoolDeployment { queryId: 1 }).toCell().beginParse())
            .endCell(),
    }).bounced();
    val bounceRes = testing.processSingleTraceStep(
        testing.treasury("unknown-bounce-sender").address,
        bouncedMessage,
    );
    val description = bounceRes.tx.load().description.load();
    if (description is TlbTransOrd) {
        if (description.computePh is TlbTrComputeVm) {
            expect(description.computePh.success).toEqual(true);
        } else {
            expect(false).toEqual(true);
        }
    } else {
        expect(false).toEqual(true);
    }

    expect(factory.poolCount()).toEqual(1);
    expect(factory.tonPoolCount()).toEqual(1);
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.poolAddressFor(jettonMaster, jettonDenom)).toEqual(jettonPoolAddr);
    expect(factory.tonPoolAddressFor(tonDenom)).toEqual(tonPoolAddr);
}

// ============================================================================
// DEPLOY CONFIRMATION, CAPS AND WORST-CASE STATE
// ============================================================================

fun factoryCodesForTest(): Cell<FactoryCodes> {
    return (FactoryCodes {
        poolCode: build("Pool"),
        tonPoolCode: build("TonPool"),
    }).toCell();
}

get fun `test factory storage vNext has canonical root and code bundle layout`() {
    val codes = factoryCodesForTest();
    val codesSlice = codes.beginParse();
    expect(codesSlice.remainingBitsCount()).toEqual(0);
    expect(codesSlice.remainingRefsCount()).toEqual(2);

    val registries = (Registries {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    }).toCell();
    val createSenders = (CreateSenders {
        poolAddressToCreator: [],
        tonPoolAddressToCreator: [],
    }).toCell();
    val data = (FactoryStorage {
        codes,
        poolCount: 0,
        tonPoolCount: 0,
        inFlightCreates: 0,
        registries,
        createSenders,
    }).toCell();
    val dataSlice = data.beginParse();
    expect(dataSlice.remainingBitsCount()).toEqual(80);
    expect(dataSlice.remainingRefsCount()).toEqual(3);

    // Byte-level mirror used by cli/scripts/deploy-factory.ts.
    val manual = beginCell()
        .storeRef(codes)
        .storeUint(0, 32)
        .storeUint(0, 32)
        .storeUint(0, 16)
        .storeRef(registries)
        .storeRef(createSenders)
        .endCell();
    expect(manual.hash()).toEqual(data.hash());
}

fun testJettonRegistryKey(jettonMaster: address, denomination: coins): uint256 {
    return beginCell().storeAddress(jettonMaster).storeCoins(denomination).endCell().hash();
}

fun factoryWithPendingJetton(
    poolAddress: address,
    creator: address,
    jettonMaster: address,
    denomination: coins,
): Factory {
    val key = testJettonRegistryKey(jettonMaster, denomination);
    var poolRegistry: map<uint256, address> = [];
    var poolAddressToKey: map<address, uint256> = [];
    var poolAddressToCreator: map<address, address> = [];
    poolRegistry.set(key, poolAddress);
    poolAddressToKey.set(poolAddress, key);
    poolAddressToCreator.set(poolAddress, creator);

    return Factory.fromStorage({
        codes: factoryCodesForTest(),
        poolCount: 1,
        tonPoolCount: 0,
        inFlightCreates: 1,
        registries: (Registries {
            poolRegistry,
            poolAddressToKey,
            tonPoolRegistry: [],
            tonPoolAddressToKey: [],
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator,
            tonPoolAddressToCreator: [],
        }).toCell(),
    });
}

fun factoryWithCounters(
    poolCount: uint32,
    tonPoolCount: uint32,
    inFlightCreates: uint16,
): Factory {
    return Factory.fromStorage({
        codes: factoryCodesForTest(),
        poolCount,
        tonPoolCount,
        inFlightCreates,
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
}

fun factoryWithJettonPendingCounters(
    poolAddress: address,
    creator: address,
    jettonMaster: address,
    denomination: coins,
    poolCount: uint32,
    inFlightCreates: uint16,
    reverseKey: uint256,
): Factory {
    val key = testJettonRegistryKey(jettonMaster, denomination);
    var poolRegistry: map<uint256, address> = [];
    var poolAddressToKey: map<address, uint256> = [];
    var poolAddressToCreator: map<address, address> = [];
    poolRegistry.set(key, poolAddress);
    poolAddressToKey.set(poolAddress, reverseKey);
    poolAddressToCreator.set(poolAddress, creator);

    return Factory.fromStorage({
        codes: factoryCodesForTest(),
        poolCount,
        tonPoolCount: 0,
        inFlightCreates,
        registries: (Registries {
            poolRegistry,
            poolAddressToKey,
            tonPoolRegistry: [],
            tonPoolAddressToKey: [],
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator,
            tonPoolAddressToCreator: [],
        }).toCell(),
    });
}

fun factoryWithTonPendingCounters(
    poolAddress: address,
    creator: address,
    denomination: coins,
    tonPoolCount: uint32,
    inFlightCreates: uint16,
    reverseKey: uint256,
): Factory {
    val key = beginCell().storeCoins(denomination).endCell().hash();
    var tonPoolRegistry: map<uint256, address> = [];
    var tonPoolAddressToKey: map<address, uint256> = [];
    var tonPoolAddressToCreator: map<address, address> = [];
    tonPoolRegistry.set(key, poolAddress);
    tonPoolAddressToKey.set(poolAddress, reverseKey);
    tonPoolAddressToCreator.set(poolAddress, creator);

    return Factory.fromStorage({
        codes: factoryCodesForTest(),
        poolCount: 0,
        tonPoolCount,
        inFlightCreates,
        registries: (Registries {
            poolRegistry: [],
            poolAddressToKey: [],
            tonPoolRegistry,
            tonPoolAddressToKey,
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator: [],
            tonPoolAddressToCreator,
        }).toCell(),
    });
}

fun processFactoryDeployBounce(
    factory: Factory,
    poolAddress: address,
    value: coins,
): SendResult {
    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value,
        body: beginCell()
            .storeUint(0xFFFFFFFF, 32)
            .storeSlice((ConfirmPoolDeployment { queryId: 1 }).toCell().beginParse())
            .endCell(),
    }).bounced();
    return testing.processSingleTraceStep(poolAddress, bouncedMessage);
}

get fun `test authenticated confirmation cleans transient state and is idempotent`() {
    val pool = testing.treasury("confirmed-pool");
    val creator = testing.treasury("confirmed-creator");
    val jettonMaster = testing.treasury("confirmed-master").address;
    val denomination: coins = 100;
    val factory = factoryWithPendingJetton(
        pool.address,
        creator.address,
        jettonMaster,
        denomination,
    );
    expect(
        factory.deploy(testing.treasury("confirmed-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.poolDeploymentPending(jettonMaster, denomination)).toEqual(true);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);

    val first = factory.sendPoolDeployConfirmed(
        pool.address,
        7,
        jettonMaster,
        denomination,
        { value: ton("0.05") },
    );
    expect(first).toHaveSuccessfulTx({ from: pool.address, to: factory.address });
    expect(factory.poolCount()).toEqual(1);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.poolDeploymentPending(jettonMaster, denomination)).toEqual(false);
    expect(factory.pendingCreateSender(pool.address)).toEqual(null);

    // The permanent forward registry authenticates a retrigger after cleanup.
    val second = factory.sendPoolDeployConfirmed(
        pool.address,
        8,
        jettonMaster,
        denomination,
        { value: ton("0.02") },
    );
    expect(second).toHaveSuccessfulTx({ from: pool.address, to: factory.address });
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.poolAddressFor(jettonMaster, denomination)).toEqual(pool.address);
}

get fun `test unrelated bounce from pending pool cannot roll back registry`() {
    val pool = testing.treasury("wrong-bounce-pool");
    val creator = testing.treasury("wrong-bounce-creator");
    val jettonMaster = testing.treasury("wrong-bounce-master").address;
    val denomination: coins = 100;
    val factory = factoryWithPendingJetton(
        pool.address,
        creator.address,
        jettonMaster,
        denomination,
    );
    expect(
        factory.deploy(testing.treasury("wrong-bounce-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val unrelatedBounce = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell().storeUint(0xFFFFFFFF, 32).storeUint(0xDEADBEEF, 32).endCell(),
    }).bounced();
    val result = testing.processSingleTraceStep(pool.address, unrelatedBounce);
    val description = result.tx.load().description.load();
    if (description is TlbTransOrd) {
        if (description.computePh is TlbTrComputeVm) {
            expect(description.computePh.success).toEqual(true);
        } else {
            expect(false).toEqual(true);
        }
    } else {
        expect(false).toEqual(true);
    }

    expect(factory.poolCount()).toEqual(1);
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.poolAddressFor(jettonMaster, denomination)).toEqual(pool.address);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test spoofed confirmation cannot clean or decrement pending create`() {
    val pool = testing.treasury("spoof-target-pool");
    val creator = testing.treasury("spoof-creator");
    val attacker = testing.treasury("spoof-attacker");
    val jettonMaster = testing.treasury("spoof-master").address;
    val denomination: coins = 100;
    val factory = factoryWithPendingJetton(
        pool.address,
        creator.address,
        jettonMaster,
        denomination,
    );
    expect(
        factory.deploy(testing.treasury("spoof-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val spoof = factory.sendPoolDeployConfirmed(
        attacker.address,
        1,
        jettonMaster,
        denomination,
        { value: ton("0.05") },
    );
    expect(spoof).toHaveFailedTx({
        from: attacker.address,
        to: factory.address,
        exitCode: Errors.InvalidPoolConfirmation,
    });
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.poolDeploymentPending(jettonMaster, denomination)).toEqual(true);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test confirmation for absent registry key cannot mutate factory`() {
    val factory = freshFactory();
    val deployer = testing.treasury("absent-confirm-deployer");
    val sender = testing.treasury("absent-confirm-sender");
    expect(factory.deploy(deployer.address, { value: ton("1") })).toHaveSuccessfulDeploy({
        to: factory.address,
    });

    val result = factory.sendPoolDeployConfirmed(
        sender.address,
        1,
        testing.treasury("absent-confirm-master").address,
        100,
        { value: ton("0.05") },
    );
    expect(result).toHaveFailedTx({
        from: sender.address,
        to: factory.address,
        exitCode: Errors.InvalidPoolConfirmation,
    });
    expect(factory.totalPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.pendingCreateSender(sender.address)).toEqual(null);
}

get fun `test confirmation rejects trailing data without cleaning pending state`() {
    val pool = testing.treasury("trailing-target-pool");
    val creator = testing.treasury("trailing-creator");
    val jettonMaster = testing.treasury("trailing-master").address;
    val denomination: coins = 100;
    val factory = factoryWithPendingJetton(
        pool.address,
        creator.address,
        jettonMaster,
        denomination,
    );
    expect(
        factory.deploy(testing.treasury("trailing-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val canonical = (PoolDeployConfirmed {
        queryId: 1,
        jettonMaster,
        denomination,
    }).toCell();
    val withTrailingBit = beginCell().storeSlice(canonical.beginParse()).storeBool(true).endCell();
    val result = factory.sendAny(pool.address, withTrailingBit, { value: ton("0.05") });
    expect(result).toHaveFailedTx({
        from: pool.address,
        to: factory.address,
        exitCode: Errors.InvalidPoolConfirmation,
    });
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

fun factoryWithPendingTon(
    poolAddress: address,
    creator: address,
    denomination: coins,
): Factory {
    val key = beginCell().storeCoins(denomination).endCell().hash();
    var tonPoolRegistry: map<uint256, address> = [];
    var tonPoolAddressToKey: map<address, uint256> = [];
    var tonPoolAddressToCreator: map<address, address> = [];
    tonPoolRegistry.set(key, poolAddress);
    tonPoolAddressToKey.set(poolAddress, key);
    tonPoolAddressToCreator.set(poolAddress, creator);

    return Factory.fromStorage({
        codes: factoryCodesForTest(),
        poolCount: 0,
        tonPoolCount: 1,
        inFlightCreates: 1,
        registries: (Registries {
            poolRegistry: [],
            poolAddressToKey: [],
            tonPoolRegistry,
            tonPoolAddressToKey,
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator: [],
            tonPoolAddressToCreator,
        }).toCell(),
    });
}

get fun `test authenticated TON pool confirmation cleans transient state`() {
    val pool = testing.treasury("confirmed-ton-pool");
    val creator = testing.treasury("confirmed-ton-creator");
    val denomination: coins = TON_POOL_DENOM_100;
    val factory = factoryWithPendingTon(pool.address, creator.address, denomination);
    expect(
        factory.deploy(testing.treasury("confirmed-ton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(factory.tonPoolDeploymentPending(denomination)).toEqual(true);
    expect(
        factory.sendPoolDeployConfirmed(
            pool.address,
            1,
            null,
            denomination,
            { value: ton("0.05") },
        ),
    ).toHaveSuccessfulTx({ from: pool.address, to: factory.address });
    expect(factory.tonPoolCount()).toEqual(1);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.tonPoolDeploymentPending(denomination)).toEqual(false);
    expect(factory.pendingCreateSender(pool.address)).toEqual(null);
}

get fun `test TON pool confirmation is authenticated and idempotent`() {
    val pool = testing.treasury("idempotent-ton-pool");
    val creator = testing.treasury("idempotent-ton-creator");
    val attacker = testing.treasury("idempotent-ton-attacker");
    val denomination: coins = TON_POOL_DENOM_100;
    val factory = factoryWithPendingTon(pool.address, creator.address, denomination);
    expect(
        factory.deploy(testing.treasury("idempotent-ton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(
        factory.sendPoolDeployConfirmed(
            attacker.address,
            1,
            null,
            denomination,
            { value: ton("0.05") },
        ),
    ).toHaveFailedTx({
        from: attacker.address,
        to: factory.address,
        exitCode: Errors.InvalidPoolConfirmation,
    });
    expect(factory.inFlightCreateCount()).toEqual(1);

    expect(
        factory.sendPoolDeployConfirmed(
            pool.address,
            2,
            null,
            denomination,
            { value: ton("0.05") },
        ),
    ).toHaveSuccessfulTx({ from: pool.address, to: factory.address });
    expect(factory.inFlightCreateCount()).toEqual(0);

    expect(
        factory.sendPoolDeployConfirmed(
            pool.address,
            3,
            null,
            denomination,
            { value: ton("0.02") },
        ),
    ).toHaveSuccessfulTx({ from: pool.address, to: factory.address });
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.tonPoolAddressFor(denomination)).toEqual(pool.address);
}

get fun `test TON confirmation rejects non-canonical coins encoding`() {
    val pool = testing.treasury("noncanonical-ton-pool");
    val creator = testing.treasury("noncanonical-ton-creator");
    val denomination: coins = TON_POOL_DENOM_100;
    val factory = factoryWithPendingTon(pool.address, creator.address, denomination);
    expect(
        factory.deploy(testing.treasury("noncanonical-ton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    // TON_POOL_DENOM_100 needs five bytes canonically. Six bytes with a leading
    // zero decode to the same value but must fail the full-body hash check.
    val nonCanonical = beginCell()
        .storeUint(OP_POOL_DEPLOY_CONFIRMED, 32)
        .storeUint(1, 64)
        .storeUint(0, 2) // addr_none$00
        .storeUint(6, 4)
        .storeUint(denomination, 48)
        .endCell();
    val result = factory.sendAny(pool.address, nonCanonical, { value: ton("0.05") });
    expect(result).toHaveFailedTx({
        from: pool.address,
        to: factory.address,
        exitCode: Errors.InvalidPoolConfirmation,
    });
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test jetton confirmation rejects corrupt reverse registry key`() {
    val pool = testing.treasury("corrupt-reverse-jetton-pool");
    val creator = testing.treasury("corrupt-reverse-jetton-creator");
    val master = testing.treasury("corrupt-reverse-jetton-master").address;
    val factory = factoryWithJettonPendingCounters(
        pool.address,
        creator.address,
        master,
        100,
        1,
        1,
        0xBAD,
    );
    expect(
        factory.deploy(
            testing.treasury("corrupt-reverse-jetton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(
        factory.sendPoolDeployConfirmed(pool.address, 1, master, 100, { value: ton("0.05") }),
    ).toHaveFailedTx({
        from: pool.address,
        to: factory.address,
        exitCode: Errors.FactoryInvariantViolation,
    });
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test TON confirmation rejects corrupt reverse registry key`() {
    val pool = testing.treasury("corrupt-reverse-ton-pool");
    val creator = testing.treasury("corrupt-reverse-ton-creator");
    val factory = factoryWithTonPendingCounters(
        pool.address,
        creator.address,
        TON_POOL_DENOM_100,
        1,
        1,
        0xBAD,
    );
    expect(
        factory.deploy(
            testing.treasury("corrupt-reverse-ton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(
        factory.sendPoolDeployConfirmed(
            pool.address,
            1,
            null,
            TON_POOL_DENOM_100,
            { value: ton("0.05") },
        ),
    ).toHaveFailedTx({
        from: pool.address,
        to: factory.address,
        exitCode: Errors.FactoryInvariantViolation,
    });
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test jetton confirmation rejects zero in-flight counter with reverse entry`() {
    val pool = testing.treasury("zero-inflight-confirm-jetton-pool");
    val creator = testing.treasury("zero-inflight-confirm-jetton-creator");
    val master = testing.treasury("zero-inflight-confirm-jetton-master").address;
    val key = testJettonRegistryKey(master, 100);
    val factory = factoryWithJettonPendingCounters(
        pool.address,
        creator.address,
        master,
        100,
        1,
        0,
        key,
    );
    expect(
        factory.deploy(
            testing.treasury("zero-inflight-confirm-jetton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(
        factory.sendPoolDeployConfirmed(pool.address, 1, master, 100, { value: ton("0.05") }),
    ).toHaveFailedTx({
        from: pool.address,
        to: factory.address,
        exitCode: Errors.FactoryInvariantViolation,
    });
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test TON confirmation rejects zero in-flight counter with reverse entry`() {
    val pool = testing.treasury("zero-inflight-confirm-ton-pool");
    val creator = testing.treasury("zero-inflight-confirm-ton-creator");
    val denomination: coins = TON_POOL_DENOM_100;
    val key = beginCell().storeCoins(denomination).endCell().hash();
    val factory = factoryWithTonPendingCounters(
        pool.address,
        creator.address,
        denomination,
        1,
        0,
        key,
    );
    expect(
        factory.deploy(
            testing.treasury("zero-inflight-confirm-ton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    expect(
        factory.sendPoolDeployConfirmed(
            pool.address,
            1,
            null,
            denomination,
            { value: ton("0.05") },
        ),
    ).toHaveFailedTx({
        from: pool.address,
        to: factory.address,
        exitCode: Errors.FactoryInvariantViolation,
    });
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test jetton deploy bounce rejects zero pool counter`() {
    val pool = testing.treasury("zero-count-bounce-jetton-pool");
    val creator = testing.treasury("zero-count-bounce-jetton-creator");
    val master = testing.treasury("zero-count-bounce-jetton-master").address;
    val key = testJettonRegistryKey(master, 100);
    val factory = factoryWithJettonPendingCounters(
        pool.address,
        creator.address,
        master,
        100,
        0,
        1,
        key,
    );
    expect(
        factory.deploy(
            testing.treasury("zero-count-bounce-jetton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val result = processFactoryDeployBounce(factory, pool.address, ton("0.05"));
    expectSingleFactoryStepExit(result, Errors.FactoryInvariantViolation);
    expect(factory.poolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test jetton deploy bounce rejects zero in-flight counter`() {
    val pool = testing.treasury("zero-inflight-bounce-jetton-pool");
    val creator = testing.treasury("zero-inflight-bounce-jetton-creator");
    val master = testing.treasury("zero-inflight-bounce-jetton-master").address;
    val key = testJettonRegistryKey(master, 100);
    val factory = factoryWithJettonPendingCounters(
        pool.address,
        creator.address,
        master,
        100,
        1,
        0,
        key,
    );
    expect(
        factory.deploy(
            testing.treasury("zero-inflight-bounce-jetton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val result = processFactoryDeployBounce(factory, pool.address, ton("0.05"));
    expectSingleFactoryStepExit(result, Errors.FactoryInvariantViolation);
    expect(factory.poolCount()).toEqual(1);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test TON deploy bounce rejects zero pool counter`() {
    val pool = testing.treasury("zero-count-bounce-ton-pool");
    val creator = testing.treasury("zero-count-bounce-ton-creator");
    val denomination: coins = TON_POOL_DENOM_100;
    val key = beginCell().storeCoins(denomination).endCell().hash();
    val factory = factoryWithTonPendingCounters(
        pool.address,
        creator.address,
        denomination,
        0,
        1,
        key,
    );
    expect(
        factory.deploy(
            testing.treasury("zero-count-bounce-ton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val result = processFactoryDeployBounce(factory, pool.address, ton("0.05"));
    expectSingleFactoryStepExit(result, Errors.FactoryInvariantViolation);
    expect(factory.tonPoolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(1);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test TON deploy bounce rejects zero in-flight counter`() {
    val pool = testing.treasury("zero-inflight-bounce-ton-pool");
    val creator = testing.treasury("zero-inflight-bounce-ton-creator");
    val denomination: coins = TON_POOL_DENOM_100;
    val key = beginCell().storeCoins(denomination).endCell().hash();
    val factory = factoryWithTonPendingCounters(
        pool.address,
        creator.address,
        denomination,
        1,
        0,
        key,
    );
    expect(
        factory.deploy(
            testing.treasury("zero-inflight-bounce-ton-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val result = processFactoryDeployBounce(factory, pool.address, ton("0.05"));
    expectSingleFactoryStepExit(result, Errors.FactoryInvariantViolation);
    expect(factory.tonPoolCount()).toEqual(1);
    expect(factory.inFlightCreateCount()).toEqual(0);
    expect(factory.pendingCreateSender(pool.address)).toEqual(creator.address);
}

get fun `test deploy bounce refund to uninitialized creator is non-bounceable`() {
    val pool = testing.treasury("uninit-refund-pool");
    val creator = address.fromWorkchainAndHash(0, 0xDEAD001);
    val master = testing.treasury("uninit-refund-master").address;
    val key = testJettonRegistryKey(master, 100);
    val factory = factoryWithJettonPendingCounters(
        pool.address,
        creator,
        master,
        100,
        1,
        1,
        key,
    );
    expect(
        factory.deploy(testing.treasury("uninit-refund-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    expect(testing.getAccountBalance(creator)).toEqual(0);

    val result = processFactoryDeployBounce(factory, pool.address, ton("0.20"));
    expect(result.outMessages.size()).toEqual(1);
    val refund = (result.outMessages.atCell(0) as Cell<TlbMessageRelaxedGeneric>).load();
    expect(refund.info.dest).toEqual(creator);
    expect(refund.info.bounce).toEqual(false);
    expect(refund.info.value.grams > 0).toEqual(true);
    expect(factory.poolCount()).toEqual(0);
    expect(factory.inFlightCreateCount()).toEqual(0);
}

get fun `test combined factory pool cap rejects another create`() {
    val factory = factoryWithCounters(MAX_FACTORY_POOLS as uint32, 0, 0);
    val deployer = testing.treasury("capacity-deployer");
    val user = testing.treasury("capacity-user");
    expect(factory.deploy(deployer.address, { value: ton("1") })).toHaveSuccessfulDeploy({
        to: factory.address,
    });

    val result = factory.sendCreatePool(
        user.address,
        1,
        testing.treasury("capacity-master").address,
        100,
        { value: ton("1") },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.FactoryCapacityReached,
    });
    expect(factory.totalPoolCount()).toEqual(MAX_FACTORY_POOLS);
}

get fun `test in-flight cap rejects another create`() {
    val factory = factoryWithCounters(1, 0, MAX_IN_FLIGHT_CREATES as uint16);
    val deployer = testing.treasury("in-flight-cap-deployer");
    val user = testing.treasury("in-flight-cap-user");
    expect(factory.deploy(deployer.address, { value: ton("1") })).toHaveSuccessfulDeploy({
        to: factory.address,
    });

    val result = factory.sendCreatePool(
        user.address,
        1,
        testing.treasury("in-flight-cap-master").address,
        100,
        { value: ton("1") },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.TooManyInFlightCreates,
    });
    expect(factory.inFlightCreateCount()).toEqual(MAX_IN_FLIGHT_CREATES);
}

get fun `test totalPoolCount adds mixed jetton and TON counters`() {
    val factory = factoryWithCounters(3, 2, 0);
    expect(
        factory.deploy(testing.treasury("mixed-total-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    expect(factory.totalPoolCount()).toEqual(5);
}

get fun `test mixed counters cannot hide old jetton registry rent from a new creator`() {
    val factory = factoryWithCounters(3, 2, 0);
    val user = testing.treasury("mixed-rent-jetton-user");
    expect(
        factory.deploy(testing.treasury("mixed-rent-jetton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    // Correct budget for five entries is 0.47 TON. A subtraction bug computes
    // only one entry and would let this creator replenish historical runway.
    setFactoryBalance(factory, ton("0.46"));

    val result = factory.sendCreatePool(
        user.address,
        1,
        testing.treasury("mixed-rent-jetton-master").address,
        100,
        { value: MIN_CREATE_JETTON_POOL_FEE },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InsufficientBalance,
    });
    expect(factory.totalPoolCount()).toEqual(5);
}

get fun `test mixed counters cannot hide old TON registry rent from a new creator`() {
    val factory = factoryWithCounters(3, 2, 0);
    val user = testing.treasury("mixed-rent-ton-user");
    expect(
        factory.deploy(testing.treasury("mixed-rent-ton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    setFactoryBalance(factory, ton("0.46"));

    val result = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: MIN_CREATE_TON_POOL_FEE },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.InsufficientBalance,
    });
    expect(factory.totalPoolCount()).toEqual(5);
}

get fun `test mixed Jetton create reserves all historical registry rent`() {
    val factory = factoryWithCounters(3, 2, 0);
    val user = testing.treasury("mixed-action-jetton-rent-user");
    expect(
        factory.deploy(
            testing.treasury("mixed-action-jetton-rent-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    setFactoryBalance(factory, ton("1"));

    val result = factory.sendCreatePool(
        user.address,
        1,
        testing.treasury("mixed-action-jetton-master").address,
        100,
        { value: MIN_CREATE_JETTON_POOL_FEE },
    );
    expect(result).toHaveSuccessfulTx<CreatePool>({
        from: user.address,
        to: factory.address,
    });
    expect(factoryReservedAmount(result, factory)).toEqual(factoryRentBudgetForTest(6));
    expect(factory.poolCount()).toEqual(4);
    expect(factory.tonPoolCount()).toEqual(2);
    expect(factory.inFlightCreateCount()).toEqual(1);
}

get fun `test mixed TON create reserves all historical registry rent`() {
    val factory = factoryWithCounters(3, 2, 0);
    val user = testing.treasury("mixed-action-rent-user");
    expect(
        factory.deploy(
            testing.treasury("mixed-action-rent-deployer").address,
            { value: ton("1") },
        ),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    setFactoryBalance(factory, ton("1"));

    val result = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: MIN_CREATE_TON_POOL_FEE },
    );
    expect(result).toHaveSuccessfulTx<CreateTonPool>({
        from: user.address,
        to: factory.address,
    });
    expect(factoryReservedAmount(result, factory)).toEqual(factoryRentBudgetForTest(6));
    expect(factory.poolCount()).toEqual(3);
    expect(factory.tonPoolCount()).toEqual(3);
    expect(factory.inFlightCreateCount()).toEqual(0);
}

get fun `test mixed counters at combined cap reject jetton create`() {
    val factory = factoryWithCounters(1, (MAX_FACTORY_POOLS - 1) as uint32, 0);
    val user = testing.treasury("mixed-cap-jetton-user");
    expect(
        factory.deploy(testing.treasury("mixed-cap-jetton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    setFactoryBalance(factory, factoryRentBudgetForTest(MAX_FACTORY_POOLS));

    val result = factory.sendCreatePool(
        user.address,
        1,
        testing.treasury("mixed-cap-jetton-master").address,
        100,
        { value: MIN_CREATE_JETTON_POOL_FEE },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.FactoryCapacityReached,
    });
    expect(factory.totalPoolCount()).toEqual(MAX_FACTORY_POOLS);
}

get fun `test mixed counters at combined cap reject TON create`() {
    val factory = factoryWithCounters((MAX_FACTORY_POOLS - 1) as uint32, 1, 0);
    val user = testing.treasury("mixed-cap-ton-user");
    expect(
        factory.deploy(testing.treasury("mixed-cap-ton-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    setFactoryBalance(factory, factoryRentBudgetForTest(MAX_FACTORY_POOLS));

    val result = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: MIN_CREATE_TON_POOL_FEE },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.FactoryCapacityReached,
    });
    expect(factory.totalPoolCount()).toEqual(MAX_FACTORY_POOLS);
}

get fun `test exact in-flight cap rejects TON create`() {
    val factory = factoryWithCounters(0, 0, MAX_IN_FLIGHT_CREATES as uint16);
    val user = testing.treasury("ton-inflight-cap-user");
    expect(
        factory.deploy(testing.treasury("ton-inflight-cap-deployer").address, { value: ton("1") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    setFactoryBalance(factory, factoryRentBudgetForTest(0));

    val result = factory.sendCreateTonPool(
        user.address,
        1,
        TON_POOL_DENOM_100,
        { value: MIN_CREATE_TON_POOL_FEE },
    );
    expect(result).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.TooManyInFlightCreates,
    });
    expect(factory.inFlightCreateCount()).toEqual(MAX_IN_FLIGHT_CREATES);
}

fun factoryWithMaximumInflight(
    confirmedPool: address,
    creator: address,
    jettonMaster: address,
    denomination: coins,
): Factory {
    var poolRegistry: map<uint256, address> = [];
    var poolAddressToKey: map<address, uint256> = [];
    var poolAddressToCreator: map<address, address> = [];

    val confirmedKey = testJettonRegistryKey(jettonMaster, denomination);
    poolRegistry.set(confirmedKey, confirmedPool);
    poolAddressToKey.set(confirmedPool, confirmedKey);
    poolAddressToCreator.set(confirmedPool, creator);

    var i = 1;
    while (i < MAX_IN_FLIGHT_CREATES) {
        val key = i as uint256;
        val poolAddress = address.fromWorkchainAndHash(0, 0x10000 + i);
        poolRegistry.set(key, poolAddress);
        poolAddressToKey.set(poolAddress, key);
        poolAddressToCreator.set(poolAddress, creator);
        i += 1;
    }

    return Factory.fromStorage({
        codes: factoryCodesForTest(),
        poolCount: MAX_IN_FLIGHT_CREATES as uint32,
        tonPoolCount: 0,
        inFlightCreates: MAX_IN_FLIGHT_CREATES as uint16,
        registries: (Registries {
            poolRegistry,
            poolAddressToKey,
            tonPoolRegistry: [],
            tonPoolAddressToKey: [],
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator,
            tonPoolAddressToCreator: [],
        }).toCell(),
    });
}

get fun `test permissionless confirmation frees an in-flight slot for another create`() {
    val pool = testing.treasury("slot-release-pool");
    val creator = testing.treasury("slot-release-creator");
    val user = testing.treasury("slot-release-user");
    val jettonMaster = testing.treasury("slot-release-master").address;
    val denomination: coins = 100;
    val factory = factoryWithMaximumInflight(
        pool.address,
        creator.address,
        jettonMaster,
        denomination,
    );
    expect(
        factory.deploy(testing.treasury("slot-release-deployer").address, { value: ton("4") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    expect(factory.inFlightCreateCount()).toEqual(MAX_IN_FLIGHT_CREATES);

    expect(
        factory.sendCreatePool(
            user.address,
            1,
            testing.treasury("blocked-master").address,
            100,
            { value: ton("1") },
        ),
    ).toHaveFailedTx({
        from: user.address,
        to: factory.address,
        exitCode: Errors.TooManyInFlightCreates,
    });

    // Any account may fund the pool-side trigger; Factory trusts only the
    // resulting callback sender. Here we inject that authenticated callback.
    expect(
        factory.sendPoolDeployConfirmed(
            pool.address,
            2,
            jettonMaster,
            denomination,
            { value: ton("0.05") },
        ),
    ).toHaveSuccessfulTx({ from: pool.address, to: factory.address });
    expect(factory.inFlightCreateCount()).toEqual(MAX_IN_FLIGHT_CREATES - 1);

    val accepted = factory.sendCreatePool(
        user.address,
        3,
        testing.treasury("released-master").address,
        100,
        { value: ton("1") },
    );
    expect(accepted).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.totalPoolCount()).toEqual(MAX_IN_FLIGHT_CREATES + 1);
}

fun maximumFactoryStateForSizeGate(): FactoryStorage {
    var poolRegistry: map<uint256, address> = [];
    var poolAddressToKey: map<address, uint256> = [];
    var poolAddressToCreator: map<address, address> = [];

    var i = 0;
    while (i < MAX_FACTORY_POOLS) {
        val key = beginCell().storeUint(0x464b4559, 32).storeUint(i, 32).endCell().hash();
        val poolAddress = address.fromWorkchainAndHash(
            0,
            beginCell().storeUint(0x46504f4f, 32).storeUint(i, 32).endCell().hash(),
        );
        poolRegistry.set(key, poolAddress);
        if (i < MAX_IN_FLIGHT_CREATES) {
            val creator = address.fromWorkchainAndHash(
                0,
                beginCell().storeUint(0x46435254, 32).storeUint(i, 32).endCell().hash(),
            );
            poolAddressToKey.set(poolAddress, key);
            poolAddressToCreator.set(poolAddress, creator);
        }
        i += 1;
    }

    return {
        codes: factoryCodesForTest(),
        poolCount: MAX_FACTORY_POOLS as uint32,
        tonPoolCount: 0,
        inFlightCreates: MAX_IN_FLIGHT_CREATES as uint16,
        registries: (Registries {
            poolRegistry,
            poolAddressToKey,
            tonPoolRegistry: [],
            tonPoolAddressToKey: [],
        }).toCell(),
        createSenders: (CreateSenders {
            poolAddressToCreator,
            tonPoolAddressToCreator: [],
        }).toCell(),
    };
}

get fun `test maximum factory state remains below sixteen thousand cells`() {
    val maximumState = (ContractState {
        code: build("Factory"),
        data: maximumFactoryStateForSizeGate().toCell(),
    }).toCell();
    val (cells, _, _, complete) = maximumState.calculateSize(16384);
    expect(complete).toEqual(true);
    expect(cells! < 16384).toEqual(true);
    println("factory max-state cells: {}", cells!);
}

fun emptyFactoryStorageForRent(): FactoryStorage {
    return {
        codes: factoryCodesForTest(),
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
    };
}

get fun `test empty Factory StateInit reports ten-year storage runway`() {
    val state = (ContractState {
        code: build("Factory"),
        data: emptyFactoryStorageForRent().toCell(),
    }).toCell();
    val (cells, bits, refs) = state.calculateSizeStrict(MAX_FACTORY_STATE_CELLS);
    val tenYearFee = calculateStorageFee(
        BASECHAIN,
        FACTORY_TEN_YEARS_SECONDS,
        bits,
        cells,
    );
    println(
        "empty Factory StateInit cells={} bits={} refs={} ten-year-fee={}",
        cells,
        bits,
        refs,
        tenYearFee,
    );
    expect(tenYearFee > 0).toEqual(true);
    expect(FACTORY_TON_RESERVE >= tenYearFee * 2).toEqual(true);
}

get fun `test maximum Factory allocation covers twice ten-year storage rent`() {
    val state = (ContractState {
        code: build("Factory"),
        data: maximumFactoryStateForSizeGate().toCell(),
    }).toCell();
    val (cells, bits, refs) = state.calculateSizeStrict(MAX_FACTORY_STATE_CELLS);
    val tenYearFee = calculateStorageFee(
        BASECHAIN,
        FACTORY_TEN_YEARS_SECONDS,
        bits,
        cells,
    );
    val maximumAllocation: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * MAX_FACTORY_POOLS;
    println(
        "max Factory StateInit cells={} bits={} refs={} ten-year-fee={} allocation={}",
        cells,
        bits,
        refs,
        tenYearFee,
        maximumAllocation,
    );
    expect(maximumAllocation >= tenYearFee * 2).toEqual(true);
}
