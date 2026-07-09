import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/constants"
import "@contracts/errors"
import "@contracts/factory-types"
import "@contracts/pool-types"
import "@wrappers/Factory.gen"

fun freshFactory(): Factory {
    val registries: Registries = {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    return Factory.fromStorage({
        poolCode: build("Pool"),
        tonPoolCode: build("TonPool"),
        poolCount: 0,
        tonPoolCount: 0,
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
    val deployTx = res.findTransaction<InitWalletBinding>({
        from: factory.address,
        to: expectedAddr,
    })!;
    val deployMsg = deployTx.loadInMsg<InitWalletBinding>();
    if (deployMsg.info is TlbInternalMessage) {
        expect(deployMsg.info.bounce).toEqual(true);
    } else {
        expect(false).toEqual(true);
    }

    expect(factory.poolCount()).toEqual(1);
    expect(factory.poolAddressFor(jettonMaster, denom)).toEqual(expectedAddr);
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
// CreatePool fee enforcement (0.20 TON floor for both pool types)
// ============================================================================

get fun `test createPool with insufficient fee is rejected`() {
    val (factory, _, user) = setupDeployedFactory();
    val jettonMaster = testing.treasury("usdt-master").address;

    // Below MIN_CREATE_POOL_FEE (0.20 TON).
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

    val res = factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        100,
        { value: MIN_CREATE_POOL_FEE },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.poolCount()).toEqual(1);
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
        { value: MIN_CREATE_POOL_FEE },
    );

    expect(res).toHaveSuccessfulTx({ from: user.address, to: factory.address });
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

    // First CreatePool drains the over-funded deploy seed down to the
    // post-reserve floor (FACTORY_TON_RESERVE + 1 * REGISTRY_RENT_PER_POOL).
    factory.sendCreatePool(user.address, 1, jettonMaster1, 100, { value: ton("1") });
    val balAfterFirst = testing.getAccountBalance(factory.address);

    // Second CreatePool: balance MUST grow by exactly REGISTRY_RENT_PER_POOL,
    // since the AT_MOST reserve target rises by that amount.
    factory.sendCreatePool(user.address, 2, jettonMaster2, 100, { value: ton("1") });
    val balAfterSecond = testing.getAccountBalance(factory.address);

    // Absolute targets: balance after N CreatePools ≈ FACTORY_TON_RESERVE +
    // N * REGISTRY_RENT_PER_POOL, within compute-gas slack.
    val targetAfterFirst: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL;
    val targetAfterSecond: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * 2;
    val slack: coins = 10000000; // 0.01 TON slack for storage rent / action fees
    expect(balAfterFirst >= targetAfterFirst - slack).toEqual(true);
    expect(balAfterFirst <= targetAfterFirst + slack).toEqual(true);
    expect(balAfterSecond >= targetAfterSecond - slack).toEqual(true);
    expect(balAfterSecond <= targetAfterSecond + slack).toEqual(true);

    // Incremental delta MUST equal REGISTRY_RENT_PER_POOL (modulo slack).
    val delta = balAfterSecond - balAfterFirst;
    expect(delta >= REGISTRY_RENT_PER_POOL - slack).toEqual(true);
    expect(delta <= REGISTRY_RENT_PER_POOL + slack).toEqual(true);
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

    factory.sendCreatePool(
        user.address,
        1,
        jettonMaster,
        100,
        { value: ton("1") },
    );
    factory.sendCreateTonPool(user.address, 2, TON_POOL_DENOM_100, { value: ton("1") });

    val balance = testing.getAccountBalance(factory.address);
    val target: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * 2;
    val slack: coins = 10000000;
    expect(balance >= target - slack).toEqual(true);
    expect(balance <= target + slack).toEqual(true);
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
    expect(balance <= target + slack).toEqual(true);
}

get fun `test factory accepts empty body (passive forward)`() {
    val (factory, _, user) = setupDeployedFactory();

    val res = factory.sendAny(user.address, createEmptyCell(), { value: ton("0.5") });

    expect(res).toHaveSuccessfulTx({
        from: user.address,
        to: factory.address,
    });
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

// ============================================================================
// BOUNCE ROLLBACK: verify onBouncedMessage cleans the phantom registry
// ============================================================================
//
// We can't directly inject a bounced message through the sandbox API, so we
// force a real deploy bounce by giving the factory a `poolCode` that does
// NOT understand the InitWalletBinding body (we swap in TonPool's code under
// the `poolCode` slot). When CreatePool runs:
//
//   1. Factory persists the (jettonMaster, denomination) → poolAddress entry
//      in both forward + reverse maps, then sends the deploy with bounce: true.
//   2. The ghost pool (= TonPool code at the Pool's identity-derived address)
//      receives InitWalletBinding, fails to parse it as AllowedTonMessage,
//      throws InvalidMessage.
//   3. The message bounces back to the factory.
//   4. Factory.onBouncedMessage looks up `in.senderAddress` in the reverse
//      map, finds the entry, deletes the registry + reverse map entries
//      and decrements poolCount.
//
// The post-state must therefore show an empty registry, proving the rollback
// path is actually wired up.

fun factoryWithGuaranteedBounce(): Factory {
    // Both pool slots use TonPool code so the InitWalletBinding body deploy
    // hits TonPool's `else => throw InvalidMessage` branch on the first run.
    val registries: Registries = {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
    return Factory.fromStorage({
        poolCode: build("TonPool"), // intentionally wrong: guarantees bounce
        tonPoolCode: build("TonPool"),
        poolCount: 0,
        tonPoolCount: 0,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
}

fun factoryWithLegacyJettonCreateSenderMissing(poolAddress: address): Factory {
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
        poolCode: build("Pool"),
        tonPoolCode: build("TonPool"),
        poolCount: 1,
        tonPoolCount: 0,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    });
}

fun factoryWithLegacyTonCreateSenderMissing(poolAddress: address): Factory {
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
        poolCode: build("Pool"),
        tonPoolCode: build("TonPool"),
        poolCount: 0,
        tonPoolCount: 1,
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
    expect(factory.poolAddressFor(jettonMaster, denom)).toEqual(null);
}

get fun `test factory rolls back registry when TON pool deploy bounces`() {
    val (factory, _, user) = setupDeployedFactory();
    val denom: coins = TON_POOL_DENOM_10;
    val tonPoolAddr = factory.expectedTonPoolAddress(denom);

    expect(
        factory.sendCreateTonPool(user.address, 1, denom, { value: ton("1") }),
    ).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.tonPoolCount()).toEqual(1);
    expect(factory.tonPoolAddressFor(denom)).toEqual(tonPoolAddr);

    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell().storeUint(0xFFFFFFFF, 32).endCell(),
    }).bounced();

    val bounceRes = testing.processSingleTraceStep(tonPoolAddr, bouncedMessage);
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

    expect(factory.tonPoolCount()).toEqual(0);
    expect(factory.tonPoolAddressFor(denom)).toEqual(null);
    expect(bounceRes.outMessages.size()).toEqual(1);
    val bounceRefund = (bounceRes.outMessages.atCell(0) as Cell<TlbMessageRelaxedGeneric>).load();
    expect(bounceRefund.info.dest).toEqual(user.address);
    expect(bounceRefund.info.value.grams > 0).toEqual(true);
    expect(bounceRefund.info.bounce).toEqual(false);

    val secondRes = factory.sendCreateTonPool(user.address, 2, denom, { value: ton("1") });
    expect(secondRes).toHaveSuccessfulTx({ from: user.address, to: factory.address });
    expect(factory.tonPoolCount()).toEqual(1);
    expect(factory.tonPoolAddressFor(denom)).toEqual(tonPoolAddr);
}

get fun `test factory rollback tolerates missing legacy jetton creator`() {
    val poolAddress = testing.treasury("legacy-jetton-pool").address;
    val factory = factoryWithLegacyJettonCreateSenderMissing(poolAddress);
    expect(
        factory.deploy(testing.treasury("legacy-deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell().storeUint(0xFFFFFFFF, 32).endCell(),
    }).bounced();

    val bounceRes = testing.processSingleTraceStep(poolAddress, bouncedMessage);

    expect(factory.poolCount()).toEqual(0);
    expect(bounceRes.outMessages.size()).toEqual(0);
}

get fun `test factory rollback tolerates missing legacy TON creator`() {
    val poolAddress = testing.treasury("legacy-ton-pool").address;
    val factory = factoryWithLegacyTonCreateSenderMissing(poolAddress);
    expect(
        factory.deploy(testing.treasury("legacy-deployer").address, { value: ton("0.5") }),
    ).toHaveSuccessfulDeploy({ to: factory.address });

    val bouncedMessage = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.01"),
        body: beginCell().storeUint(0xFFFFFFFF, 32).endCell(),
    }).bounced();

    val bounceRes = testing.processSingleTraceStep(poolAddress, bouncedMessage);

    expect(factory.tonPoolCount()).toEqual(0);
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
        body: beginCell().storeUint(0xFFFFFFFF, 32).endCell(),
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
    expect(factory.poolAddressFor(jettonMaster, jettonDenom)).toEqual(jettonPoolAddr);
    expect(factory.tonPoolAddressFor(tonDenom)).toEqual(tonPoolAddr);
}
