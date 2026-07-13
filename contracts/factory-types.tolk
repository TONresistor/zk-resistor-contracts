import "deployment-types"

// ============================================================================
// FACTORY STORAGE
// ============================================================================
//
// The factory has no admin. Active registries and pending creator maps are
// disjoint: every accepted identity occupies exactly one dictionary entry.
// A pool authenticates its activation with PoolDeployConfirmed, which moves
// that identity from pending to active without changing the total slot count.

// The measured worst-case state is 49,342 cells at this capacity, below the
// basechain account-state limit of 65,536 cells with roughly 25% headroom.
const MAX_FACTORY_POOLS: int = 24576
const MAX_TON_POOLS: int = 4
const MAX_JETTON_POOLS: int = MAX_FACTORY_POOLS - MAX_TON_POOLS
// Compatibility getter bound. Total capacity already enforces this value, so
// pending deployments can no longer block creation before the registry is full.
const MAX_IN_FLIGHT_CREATES: int = MAX_FACTORY_POOLS

// Keep both deployable code cells in one address-determining bundle.
struct FactoryCodes {
    poolCode: cell
    tonPoolCode: cell
}

struct Registries {
    poolRegistry: map<uint256, address>    // active hash(jettonMaster, denom) -> Pool
    tonPoolRegistry: map<uint256, address> // active hash(denom) -> TonPool
}

struct CreateSenders {
    poolAddressToCreator: map<address, address>    // pending Pool -> create sender
    tonPoolAddressToCreator: map<address, address> // pending TonPool -> create sender
}

struct FactoryStorage {
    // Deployment-only layout. Legacy Factory data is intentionally not
    // decoded or migrated in place; changing these fields changes the address.
    codes: Cell<FactoryCodes>
    poolCount: uint32
    tonPoolCount: uint32
    inFlightCreates: uint16
    registries: Cell<Registries>
    createSenders: Cell<CreateSenders>
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

// ============================================================================
// FACTORY MESSAGES
// ============================================================================

// Permissionless. The pool's jetton wallet is bound on-chain via TEP-89,
// so the caller does NOT supply a wallet address.
struct (0xa0c0c0c0) CreatePool {
    queryId: uint64
    jettonMaster: address
    denomination: coins
}

// Permissionless. Denomination MUST be in the whitelist to concentrate
// anonymity sets.
struct (0xa0c0c0c2) CreateTonPool {
    queryId: uint64
    denomination: coins
}

// Local ABI alias keeps generated Factory wrappers self-contained even when
// the underlying shared handshake type lives in deployment-types.tolk.
type FactoryPoolDeployConfirmed = PoolDeployConfirmed

type AllowedFactoryMessage = CreatePool | CreateTonPool | FactoryPoolDeployConfirmed

// jettonMaster is null for TON pools.
struct (0x00c0c0c0) FactoryPoolCreatedEvent {
    jettonMaster: address?
    denomination: coins
    poolAddress: address
}
