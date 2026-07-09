import "constants"
import "errors"
import "factory-types"
import "pool-types" // Pool storage layout + InitWalletBinding body
import "ton-pool-types" // TonPool storage layout

contract Factory {
    author: "ZKResistor"
    version: "1.0.0"
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
            handleCreatePool(in.senderAddress, in.valueCoins, msg);
        }
        CreateTonPool => {
            handleCreateTonPool(in.senderAddress, in.valueCoins, msg);
        }
        else => {
            // Accepts passive TON forwards from pools (empty body) without throwing.
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
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
        storage.poolCount = storage.poolCount - 1;
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
        storage.tonPoolCount = storage.tonPoolCount - 1;
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
// CREATE POOL
// ============================================================================
//
// Pool address depends only on PoolIdentity (jettonMaster, factory, denom).
// The caller does NOT supply the wallet — the pool itself queries the master
// via TEP-89 after deploy, so no caller can poison the binding.

fun handleCreatePool(sender: address, valueCoins: coins, msg: CreatePool) {
    assert (valueCoins >= MIN_CREATE_POOL_FEE) throw Errors.InsufficientCreatePoolFee;
    assert (msg.denomination > 0) throw Errors.InvalidDenomination;

    var storage = lazy FactoryStorage.load();
    var registries = storage.registries.load();
    var createSenders = storage.createSenders.load();

    val registryKey = computeRegistryKey(msg.jettonMaster, msg.denomination);
    assert (!registries.poolRegistry.exists(registryKey)) throw Errors.PoolAlreadyExists;

    val factoryAddr = contract.getAddress();
    val poolDeployed = calcDeployedPool(
        storage.poolCode,
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

    // bounce: true keeps the rollback path live; CARRY_ALL_BALANCE forwards
    // every TON above the rent reserve to the new pool, which uses it to
    // fund the TEP-89 query in handleInitWalletBinding.
    val deployMsg = createMessage({
        bounce: true,
        dest: poolDeployed,
        value: 0,
        body: InitWalletBinding { queryId: msg.queryId },
    });
    // SAFETY: reserveFactoryRentBudget pins every registry rent allocation;
    // only the caller-funded surplus is forwarded to the deterministic pool.
    deployMsg.send(SEND_MODE_CARRY_ALL_BALANCE);
}

// ============================================================================
// CREATE TON POOL: permissionless, fixed-denomination whitelist
// ============================================================================

fun computeTonRegistryKey(denomination: coins): uint256 {
    return beginCell().storeCoins(denomination).endCell().hash();
}

fun handleCreateTonPool(sender: address, valueCoins: coins, msg: CreateTonPool) {
    assert (valueCoins >= MIN_CREATE_POOL_FEE) throw Errors.InsufficientCreatePoolFee;
    assert (isWhitelistedTonDenom(msg.denomination)) throw Errors.InvalidDenomination;

    var storage = lazy FactoryStorage.load();
    var registries = storage.registries.load();
    var createSenders = storage.createSenders.load();

    val registryKey = computeTonRegistryKey(msg.denomination);
    assert (!registries.tonPoolRegistry.exists(registryKey)) throw Errors.PoolAlreadyExists;

    val factoryAddr = contract.getAddress();
    val poolDeployed = calcDeployedTonPool(
        storage.tonPoolCode,
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
        value: 0,
    });
    // SAFETY: reserveFactoryRentBudget pins every registry rent allocation;
    // only the caller-funded surplus is forwarded to the deterministic pool.
    deployMsg.send(SEND_MODE_CARRY_ALL_BALANCE);
}

// ============================================================================
// HELPERS
// ============================================================================

fun computeRegistryKey(jettonMaster: address, denomination: coins): uint256 {
    return beginCell().storeAddress(jettonMaster).storeCoins(denomination).endCell().hash();
}

// Reserve the factory's rent budget for the current set of registry
// entries. CARRY_ALL_BALANCE then forwards the surplus to the new pool.
fun reserveFactoryRentBudget(totalPools: uint32) {
    val target: coins = FACTORY_TON_RESERVE + REGISTRY_RENT_PER_POOL * totalPools;
    reserveToncoinsOnBalance(target, RESERVE_MODE_AT_MOST);
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
        nullifiers: [],
        commitments: [],
    };
    val initialStorage: Storage = {
        identity: initialIdentity.toCell(),
        jettonWallet: null,
        relayerReserve: 0,
        merkle: initialMerkle.toCell(),
        withdrawals: [],
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
        nullifiers: [],
        commitments: [],
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

// ============================================================================
// GETTERS
// ============================================================================

get fun poolCount(): uint32 {
    val storage = lazy FactoryStorage.load();
    return storage.poolCount;
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
    return calcDeployedPool(
        storage.poolCode,
        jettonMaster,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
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
    return calcDeployedTonPool(
        storage.tonPoolCode,
        contract.getAddress(),
        denomination,
    ).calculateAddress();
}
