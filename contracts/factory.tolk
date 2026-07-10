import "constants"
import "deployment-types"
import "errors"
import "factory-types"
import "pool-types" // Pool storage layout + InitWalletBinding body
import "ton-pool-types" // TonPool storage layout

contract Factory {
    author: "ZKResistor"
    version: "2.0.0"
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

    // Pool deploy bounce: drop the forward + reverse registry entries the
    // CreatePool path wrote, so the (jettonMaster, denomination) pair is
    // deployable again. Identifies the failed pool by in.senderAddress.
    var storage = lazy FactoryStorage.load();
    var registries = storage.registries.load();
    var createSenders = storage.createSenders.load();

    val jettonKeyEntry = registries.poolAddressToKey.get(in.senderAddress);
    if (jettonKeyEntry.isFound) {
        val key = jettonKeyEntry.loadValue();
        val creatorEntry = createSenders.poolAddressToCreator.get(in.senderAddress);
        registries.poolRegistry.delete(key);
        registries.poolAddressToKey.delete(in.senderAddress);
        createSenders.poolAddressToCreator.delete(in.senderAddress);
        assert (
            storage.poolCount > 0 && storage.inFlightCreates > 0
        ) throw Errors.FactoryInvariantViolation;
        storage.poolCount -= 1;
        storage.inFlightCreates -= 1;
        storage.registries = registries.toCell();
        storage.createSenders = createSenders.toCell();
        storage.save();
        if (creatorEntry.isFound) {
            refundDeployBounce(creatorEntry.loadValue());
        }
        return;
    }

    val tonKeyEntry = registries.tonPoolAddressToKey.get(in.senderAddress);
    if (tonKeyEntry.isFound) {
        val key = tonKeyEntry.loadValue();
        val creatorEntry = createSenders.tonPoolAddressToCreator.get(in.senderAddress);
        registries.tonPoolRegistry.delete(key);
        registries.tonPoolAddressToKey.delete(in.senderAddress);
        createSenders.tonPoolAddressToCreator.delete(in.senderAddress);
        assert (
            storage.tonPoolCount > 0 && storage.inFlightCreates > 0
        ) throw Errors.FactoryInvariantViolation;
        storage.tonPoolCount -= 1;
        storage.inFlightCreates -= 1;
        storage.registries = registries.toCell();
        storage.createSenders = createSenders.toCell();
        storage.save();
        if (creatorEntry.isFound) {
            refundDeployBounce(creatorEntry.loadValue());
        }
        return;
    }
    // Unknown bounce: no-op.
}

// ============================================================================
// DEPLOY CONFIRMATION
// ============================================================================

// Authentication uses the permanent forward registry, not the transient
// reverse map. Therefore the same callback remains valid after cleanup and
// can be retriggered without consuming another in-flight slot.
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
        val registered = registries.poolRegistry.get(key);
        assert (
            registered.isFound && registered.loadValue() == sender
        ) throw Errors.InvalidPoolConfirmation;

        val reverse = registries.poolAddressToKey.get(sender);
        if (!reverse.isFound) {
            // Already confirmed: forward-registry authentication above makes
            // this an authenticated, idempotent no-op.
            return;
        }
        assert (reverse.loadValue() == key) throw Errors.FactoryInvariantViolation;
        assert (storage.inFlightCreates > 0) throw Errors.FactoryInvariantViolation;

        registries.poolAddressToKey.delete(sender);
        createSenders.poolAddressToCreator.delete(sender);
        storage.inFlightCreates -= 1;
    } else {
        val key = computeTonRegistryKey(msg.denomination);
        val registered = registries.tonPoolRegistry.get(key);
        assert (
            registered.isFound && registered.loadValue() == sender
        ) throw Errors.InvalidPoolConfirmation;

        val reverse = registries.tonPoolAddressToKey.get(sender);
        if (!reverse.isFound) {
            return;
        }
        assert (reverse.loadValue() == key) throw Errors.FactoryInvariantViolation;
        assert (storage.inFlightCreates > 0) throw Errors.FactoryInvariantViolation;

        registries.tonPoolAddressToKey.delete(sender);
        createSenders.tonPoolAddressToCreator.delete(sender);
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
    var registries = storage.registries.load();
    var createSenders = storage.createSenders.load();
    val totalPoolsBefore = storage.poolCount + storage.tonPoolCount;

    val registryKey = computeRegistryKey(msg.jettonMaster, msg.denomination);
    assert (!registries.poolRegistry.exists(registryKey)) throw Errors.PoolAlreadyExists;
    assert (
        storage.poolCount + storage.tonPoolCount < MAX_FACTORY_POOLS
    ) throw Errors.FactoryCapacityReached;
    assert (storage.inFlightCreates < MAX_IN_FLIGHT_CREATES) throw Errors.TooManyInFlightCreates;
    assert (
        contract.getOriginalBalance() - valueCoins >= factoryRentBudget(totalPoolsBefore)
    ) throw Errors.InsufficientBalance;

    val factoryAddr = contract.getAddress();
    val poolDeployed = calcDeployedPool(
        codes.poolCode,
        msg.jettonMaster,
        factoryAddr,
        msg.denomination,
    );
    val poolAddress = poolDeployed.calculateAddress();

    // Persist registry + reverse map BEFORE sending deploy. The reverse map
    // lets `onBouncedMessage` roll back if the deploy fails.
    registries.poolRegistry.set(registryKey, poolAddress);
    registries.poolAddressToKey.set(poolAddress, registryKey);
    createSenders.poolAddressToCreator.set(poolAddress, sender);
    storage.registries = registries.toCell();
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
    // the Factory and can never subsidize a later creator.
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
    var registries = storage.registries.load();
    var createSenders = storage.createSenders.load();
    val totalPoolsBefore = storage.poolCount + storage.tonPoolCount;

    val registryKey = computeTonRegistryKey(msg.denomination);
    assert (!registries.tonPoolRegistry.exists(registryKey)) throw Errors.PoolAlreadyExists;
    assert (
        storage.poolCount + storage.tonPoolCount < MAX_FACTORY_POOLS
    ) throw Errors.FactoryCapacityReached;
    assert (storage.inFlightCreates < MAX_IN_FLIGHT_CREATES) throw Errors.TooManyInFlightCreates;
    assert (
        contract.getOriginalBalance() - valueCoins >= factoryRentBudget(totalPoolsBefore)
    ) throw Errors.InsufficientBalance;

    val factoryAddr = contract.getAddress();
    val poolDeployed = calcDeployedTonPool(
        codes.tonPoolCode,
        factoryAddr,
        msg.denomination,
    );
    val poolAddress = poolDeployed.calculateAddress();

    registries.tonPoolRegistry.set(registryKey, poolAddress);
    registries.tonPoolAddressToKey.set(poolAddress, registryKey);
    createSenders.tonPoolAddressToCreator.set(poolAddress, sender);
    storage.registries = registries.toCell();
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
    return {
        poolRegistry: [],
        poolAddressToKey: [],
        tonPoolRegistry: [],
        tonPoolAddressToKey: [],
    };
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
    return r.isFound ? r.loadValue() : null;
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
    val registries = storage.registries.load();
    val registered = registries.poolRegistry.get(computeRegistryKey(jettonMaster, denomination));
    return registered.isFound && registries.poolAddressToKey.exists(registered.loadValue());
}

get fun tonPoolCount(): uint32 {
    val storage = lazy FactoryStorage.load();
    return storage.tonPoolCount;
}

get fun tonPoolAddressFor(denomination: coins): address? {
    val storage = lazy FactoryStorage.load();
    val registries = storage.registries.load();
    val r = registries.tonPoolRegistry.get(computeTonRegistryKey(denomination));
    return r.isFound ? r.loadValue() : null;
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
    val registries = storage.registries.load();
    val registered = registries.tonPoolRegistry.get(computeTonRegistryKey(denomination));
    return registered.isFound && registries.tonPoolAddressToKey.exists(registered.loadValue());
}
