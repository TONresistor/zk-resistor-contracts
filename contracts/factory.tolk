import "constants"
import "deployment-types"
import "errors"
import "factory-types"
import "pool-types" // Pool storage layout + InitWalletBinding body
import "ton-pool-types" // TonPool storage layout

contract Factory {
    author: "ZKResistor"
    version: "2.0.1"
    description: "Unified factory: jetton pools (custom denoms) + TON pools (fixed whitelist)"
    storage: FactoryStorage
    incomingMessages: AllowedFactoryMessage
}

// ============================================================================
// ENTRYPOINT
// ============================================================================

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedFactoryMessage.fromSlice(in.body);

    match (msg) {
        CreatePool => {
            val trailing = msg.forceLoadLazyObject();
            assert (trailing.isEmpty()) throw Errors.InvalidMessage;
            handleCreatePool(in.senderAddress, in.valueCoins, msg);
        }
        CreateTonPool => {
            val trailing = msg.forceLoadLazyObject();
            assert (trailing.isEmpty()) throw Errors.InvalidMessage;
            handleCreateTonPool(in.senderAddress, in.valueCoins, msg);
        }
        PoolDeployConfirmed => {
            handlePoolDeployConfirmed(in.senderAddress, in.body, msg);
        }
        else => {
            // Accepts passive TON forwards from pools (empty body) without throwing.
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    // A pending pool address is not sufficient authentication on its own.
    // Roll back only the unique deployment trigger sent by this Factory.
    var bouncedBody = in.bouncedBody;
    bouncedBody.skipBouncedPrefix();
    if (
        bouncedBody.remainingBitsCount() != 32 + 64 || bouncedBody.remainingRefsCount() != 0 ||
        bouncedBody.loadUint(32) != OP_CONFIRM_POOL_DEPLOYMENT
    ) {
        return;
    }
    bouncedBody.loadUint(64); // queryId is not state-bearing
    bouncedBody.assertEnd();

    // A pending Pool is keyed by its deterministic address, so a deployment
    // bounce can release the slot and refund its creator without a reverse map.
    var storage = lazy FactoryStorage.load();
    var createSenders = storage.createSenders.load();

    val jettonCreator = createSenders.poolAddressToCreator.get(in.senderAddress);
    if (jettonCreator.isFound) {
        createSenders.poolAddressToCreator.delete(in.senderAddress);
        assert (
            storage.poolCount > 0 && storage.inFlightCreates > 0
        ) throw Errors.FactoryInvariantViolation;
        storage.poolCount -= 1;
        storage.inFlightCreates -= 1;
        storage.createSenders = createSenders.toCell();
        storage.save();
        refundDeployBounce(jettonCreator.loadValue());
        return;
    }

    val tonCreator = createSenders.tonPoolAddressToCreator.get(in.senderAddress);
    if (tonCreator.isFound) {
        createSenders.tonPoolAddressToCreator.delete(in.senderAddress);
        assert (
            storage.tonPoolCount > 0 && storage.inFlightCreates > 0
        ) throw Errors.FactoryInvariantViolation;
        storage.tonPoolCount -= 1;
        storage.inFlightCreates -= 1;
        storage.createSenders = createSenders.toCell();
        storage.save();
        refundDeployBounce(tonCreator.loadValue());
        return;
    }
    // Unknown bounce: no-op.
}

// ============================================================================
// DEPLOY CONFIRMATION
// ============================================================================

// Authentication derives the expected sender from the immutable Pool code and
// identity. The callback atomically moves a pending identity into the active
// registry; an already-active callback is an idempotent no-op.
fun handlePoolDeployConfirmed(sender: address, rawBody: slice, msg: PoolDeployConfirmed) {
    // Reject trailing bits/refs and non-canonical encodings. Repacking the
    // untouched inbound slice makes the comparison cover the complete body.
    val receivedBody = beginCell().storeSlice(rawBody).endCell();
    assert (receivedBody.hash() == msg.toCell().hash()) throw Errors.InvalidPoolConfirmation;

    var storage = lazy FactoryStorage.load();
    var registries = storage.registries.load();
    var createSenders = storage.createSenders.load();

    if (msg.jettonMaster != null) {
        val key = computeRegistryKey(msg.jettonMaster!, msg.denomination);
        val expected = calcDeployedPool(
            storage.codes.load().poolCode,
            msg.jettonMaster!,
            contract.getAddress(),
            msg.denomination,
        ).calculateAddress();
        assert (sender == expected) throw Errors.InvalidPoolConfirmation;

        val registered = registries.poolRegistry.get(key);
        if (registered.isFound) {
            assert (registered.loadValue() == sender) throw Errors.FactoryInvariantViolation;
            assert (
                !createSenders.poolAddressToCreator.exists(sender)
            ) throw Errors.FactoryInvariantViolation;
            return;
        }

        assert (
            createSenders.poolAddressToCreator.exists(sender)
        ) throw Errors.InvalidPoolConfirmation;
        assert (storage.inFlightCreates > 0) throw Errors.FactoryInvariantViolation;
        createSenders.poolAddressToCreator.delete(sender);
        registries.poolRegistry.set(key, sender);
        storage.inFlightCreates -= 1;
    } else {
        val key = computeTonRegistryKey(msg.denomination);
        val expected = calcDeployedTonPool(
            storage.codes.load().tonPoolCode,
            contract.getAddress(),
            msg.denomination,
        ).calculateAddress();
        assert (sender == expected) throw Errors.InvalidPoolConfirmation;

        val registered = registries.tonPoolRegistry.get(key);
        if (registered.isFound) {
            assert (registered.loadValue() == sender) throw Errors.FactoryInvariantViolation;
            assert (
                !createSenders.tonPoolAddressToCreator.exists(sender)
            ) throw Errors.FactoryInvariantViolation;
            return;
        }

        assert (
            createSenders.tonPoolAddressToCreator.exists(sender)
        ) throw Errors.InvalidPoolConfirmation;
        assert (storage.inFlightCreates > 0) throw Errors.FactoryInvariantViolation;
        createSenders.tonPoolAddressToCreator.delete(sender);
        registries.tonPoolRegistry.set(key, sender);
        storage.inFlightCreates -= 1;
    }

    storage.registries = registries.toCell();
    storage.createSenders = createSenders.toCell();
    storage.save();
}

// ============================================================================
// CREATE POOL
// ============================================================================
//
// Pool address depends only on PoolIdentity (jettonMaster, factory, denom).
// The caller does NOT supply the wallet — the pool itself queries the master
// via TEP-89 after deploy, so no caller can poison the binding.

fun handleCreatePool(sender: address, valueCoins: coins, msg: CreatePool) {
    assert (valueCoins >= MIN_CREATE_JETTON_POOL_FEE) throw Errors.InsufficientCreatePoolFee;
    assert (msg.denomination > 0) throw Errors.InvalidDenomination;

    var storage = lazy FactoryStorage.load();
    val codes = storage.codes.load();
    val registries = storage.registries.load();
    var createSenders = storage.createSenders.load();
    val totalPoolsBefore = storage.poolCount + storage.tonPoolCount;

    val registryKey = computeRegistryKey(msg.jettonMaster, msg.denomination);
    assert (!registries.poolRegistry.exists(registryKey)) throw Errors.PoolAlreadyExists;
    val factoryAddr = contract.getAddress();
    val poolDeployed = calcDeployedPool(
        codes.poolCode,
        msg.jettonMaster,
        factoryAddr,
        msg.denomination,
    );
    val poolAddress = poolDeployed.calculateAddress();
    assert (!createSenders.poolAddressToCreator.exists(poolAddress)) throw Errors.PoolAlreadyExists;
    assert (storage.poolCount < MAX_JETTON_POOLS) throw Errors.FactoryCapacityReached;
    assert (storage.inFlightCreates < MAX_IN_FLIGHT_CREATES) throw Errors.TooManyInFlightCreates;
    assert (
        contract.getOriginalBalance() - valueCoins >= factoryRentBudget(totalPoolsBefore)
    ) throw Errors.InsufficientBalance;

    // Reserve the deterministic identity before sending deploy. The active
    // registry is written only by the authenticated Pool callback.
    createSenders.poolAddressToCreator.set(poolAddress, sender);
    storage.createSenders = createSenders.toCell();
    storage.poolCount = storage.poolCount + 1;
    storage.inFlightCreates += 1;
    storage.save();

    reserveFactoryRentBudget(storage.poolCount + storage.tonPoolCount);

    val createdEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00c0c0c0 },
        body: FactoryPoolCreatedEvent {
            jettonMaster: msg.jettonMaster,
            denomination: msg.denomination,
            poolAddress,
        },
    });
    createdEvent.send(SEND_MODE_REGULAR);

    // bounce: true keeps the rollback path live. Only value from this create
    // is forwarded: prior donations and the historical rent runway remain on
    // the Factory and cannot subsidize a later creator.
    val deployMsg = createMessage({
        bounce: true,
        dest: poolDeployed,
        value: valueCoins - FACTORY_CREATE_RETAINED_VALUE,
        body: ConfirmPoolDeployment { queryId: msg.queryId },
    });
    deployMsg.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// ============================================================================
// CREATE TON POOL: permissionless, fixed-denomination whitelist
// ============================================================================

fun computeTonRegistryKey(denomination: coins): uint256 {
    return beginCell().storeCoins(denomination).endCell().hash();
}

fun handleCreateTonPool(sender: address, valueCoins: coins, msg: CreateTonPool) {
    assert (valueCoins >= MIN_CREATE_TON_POOL_FEE) throw Errors.InsufficientCreatePoolFee;
    assert (isWhitelistedTonDenom(msg.denomination)) throw Errors.InvalidDenomination;

    var storage = lazy FactoryStorage.load();
    val codes = storage.codes.load();
    val registries = storage.registries.load();
    var createSenders = storage.createSenders.load();
    val totalPoolsBefore = storage.poolCount + storage.tonPoolCount;

    val registryKey = computeTonRegistryKey(msg.denomination);
    assert (!registries.tonPoolRegistry.exists(registryKey)) throw Errors.PoolAlreadyExists;
    val factoryAddr = contract.getAddress();
    val poolDeployed = calcDeployedTonPool(
        codes.tonPoolCode,
        factoryAddr,
        msg.denomination,
    );
    val poolAddress = poolDeployed.calculateAddress();
    assert (
        !createSenders.tonPoolAddressToCreator.exists(poolAddress)
    ) throw Errors.PoolAlreadyExists;
    assert (storage.tonPoolCount < MAX_TON_POOLS) throw Errors.FactoryCapacityReached;
    assert (storage.inFlightCreates < MAX_IN_FLIGHT_CREATES) throw Errors.TooManyInFlightCreates;
    assert (
        contract.getOriginalBalance() - valueCoins >= factoryRentBudget(totalPoolsBefore)
    ) throw Errors.InsufficientBalance;

    createSenders.tonPoolAddressToCreator.set(poolAddress, sender);
    storage.createSenders = createSenders.toCell();
    storage.tonPoolCount = storage.tonPoolCount + 1;
    storage.inFlightCreates += 1;
    storage.save();

    reserveFactoryRentBudget(storage.poolCount + storage.tonPoolCount);

    // TonPools have no jettonMaster: the event reuses the same shape with
    // `jettonMaster = null`.
    val createdEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00c0c0c0 },
        body: FactoryPoolCreatedEvent {
            jettonMaster: null,
            denomination: msg.denomination,
            poolAddress,
        },
    });
    createdEvent.send(SEND_MODE_REGULAR);

    val deployMsg = createMessage({
        bounce: true,
        dest: poolDeployed,
        value: valueCoins - FACTORY_CREATE_RETAINED_VALUE,
        body: ConfirmPoolDeployment { queryId: msg.queryId },
    });
    deployMsg.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// ============================================================================
// HELPERS
// ============================================================================

fun computeRegistryKey(jettonMaster: address, denomination: coins): uint256 {
    return beginCell().storeAddress(jettonMaster).storeCoins(denomination).endCell().hash();
}

fun factoryRentBudget(totalPools: uint32): coins {
    return FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * totalPools;
}

// Reserve the factory's rent budget for the current set of registry entries.
fun reserveFactoryRentBudget(totalPools: uint32) {
    reserveToncoinsOnBalance(
        factoryRentBudget(totalPools),
        RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

fun refundDeployBounce(creator: address) {
    val refund = createMessage({
        bounce: false,
        dest: creator,
        value: 0,
    });
    refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

// Initial Pool state. MUST match `Storage` byte-for-byte: any divergence
// breaks address determinism.
fun calcDeployedPool(
    poolCode: cell,
    jettonMaster: address,
    factoryAddr: address,
    denomination: coins,
): AutoDeployAddress {
    val initialIdentity: PoolIdentity = {
        jettonMaster,
        factory: factoryAddr,
        denomination,
    };
    val initialMerkle: MerkleState = {
        nextIndex: 0,
        currentRoot: EMPTY_TREE_ROOT, // depth-20 Poseidon BLS12-381 empty root
        rootHistory: [],
        sparseSets: (SparseSetRoots {
            commitmentSeenRoots: [],
            nullifierSpentRoots: [],
        }).toCell(),
    };
    val initialStorage: Storage = {
        identity: initialIdentity.toCell(),
        jettonWallet: null,
        relayerReserve: 0,
        merkle: initialMerkle.toCell(),
        withdrawalCount: 0,
    };

    return { stateInit: { code: poolCode, data: initialStorage.toCell() } };
}

// Initial TonPool state. MUST match `TonPoolStorage` byte-for-byte.
fun calcDeployedTonPool(
    tonPoolCode: cell,
    factoryAddr: address,
    denomination: coins,
): AutoDeployAddress {
    val initialIdentity: TonPoolIdentity = { factory: factoryAddr, denomination };
    val initialMerkle: MerkleState = {
        nextIndex: 0,
        currentRoot: EMPTY_TREE_ROOT,
        rootHistory: [],
        sparseSets: (SparseSetRoots {
            commitmentSeenRoots: [],
            nullifierSpentRoots: [],
        }).toCell(),
    };
    val initialStorage: TonPoolStorage = {
        identity: initialIdentity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: initialMerkle.toCell(),
    };

    return { stateInit: { code: tonPoolCode, data: initialStorage.toCell() } };
}

// Empty initial Registries cell. Exported for deploy scripts.
fun initialRegistries(): Registries {
    return { poolRegistry: [], tonPoolRegistry: [] };
}

fun initialCreateSenders(): CreateSenders {
    return { poolAddressToCreator: [], tonPoolAddressToCreator: [] };
}

fun initialFactoryCodes(
    poolCode: cell,
    tonPoolCode: cell,
): FactoryCodes {
    return { poolCode, tonPoolCode };
}

// ============================================================================
// GETTERS
// ============================================================================

get fun poolCount(): uint32 {
    val storage = lazy FactoryStorage.load();
    return storage.poolCount;
}

get fun totalPoolCount(): uint32 {
    val storage = lazy FactoryStorage.load();
    return storage.poolCount + storage.tonPoolCount;
}

get fun inFlightCreateCount(): uint16 {
    val storage = lazy FactoryStorage.load();
    return storage.inFlightCreates;
}

get fun maxFactoryPools(): uint32 {
    return MAX_FACTORY_POOLS as uint32;
}

get fun maxInFlightCreates(): uint16 {
    return MAX_IN_FLIGHT_CREATES as uint16;
}

get fun pendingCreateSender(poolAddress: address): address? {
    val storage = lazy FactoryStorage.load();
    val senders = storage.createSenders.load();
    val jettonCreator = senders.poolAddressToCreator.get(poolAddress);
    if (jettonCreator.isFound) {
        return jettonCreator.loadValue();
    }
    val tonCreator = senders.tonPoolAddressToCreator.get(poolAddress);
    return tonCreator.isFound ? tonCreator.loadValue() : null;
}

get fun poolAddressFor(jettonMaster: address, denomination: coins): address? {
    val storage = lazy FactoryStorage.load();
    val registries = storage.registries.load();
    val key = computeRegistryKey(jettonMaster, denomination);
    val r = registries.poolRegistry.get(key);
    if (r.isFound) {
        return r.loadValue();
    }
    val expected = calcDeployedPool(
        storage.codes.load().poolCode,
        jettonMaster,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
    return storage.createSenders.load().poolAddressToCreator.exists(expected) ? expected : null;
}

// The address a pool for (jettonMaster, denomination) would have, whether
// or not it has been deployed yet.
get fun expectedPoolAddress(
    jettonMaster: address,
    denomination: coins,
): address {
    val storage = lazy FactoryStorage.load();
    val codes = storage.codes.load();
    return calcDeployedPool(
        codes.poolCode,
        jettonMaster,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
}

get fun poolDeploymentPending(jettonMaster: address, denomination: coins): bool {
    val storage = lazy FactoryStorage.load();
    val expected = calcDeployedPool(
        storage.codes.load().poolCode,
        jettonMaster,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
    return storage.createSenders.load().poolAddressToCreator.exists(expected);
}

get fun tonPoolCount(): uint32 {
    val storage = lazy FactoryStorage.load();
    return storage.tonPoolCount;
}

get fun tonPoolAddressFor(denomination: coins): address? {
    val storage = lazy FactoryStorage.load();
    val registries = storage.registries.load();
    val r = registries.tonPoolRegistry.get(computeTonRegistryKey(denomination));
    if (r.isFound) {
        return r.loadValue();
    }
    val expected = calcDeployedTonPool(
        storage.codes.load().tonPoolCode,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
    return storage.createSenders.load().tonPoolAddressToCreator.exists(expected) ? expected : null;
}

get fun expectedTonPoolAddress(denomination: coins): address {
    val storage = lazy FactoryStorage.load();
    val codes = storage.codes.load();
    return calcDeployedTonPool(
        codes.tonPoolCode,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
}

get fun tonPoolDeploymentPending(denomination: coins): bool {
    val storage = lazy FactoryStorage.load();
    val expected = calcDeployedTonPool(
        storage.codes.load().tonPoolCode,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
    return storage.createSenders.load().tonPoolAddressToCreator.exists(expected);
}
