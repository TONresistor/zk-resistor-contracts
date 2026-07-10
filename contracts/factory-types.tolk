import "deployment-types"

// ============================================================================
// FACTORY STORAGE
// ============================================================================
//
// The factory has no admin. Forward maps are permanent enumeration indexes;
// reverse and creator maps exist only while a deploy is in flight. A pool
// authenticates its activation with PoolDeployConfirmed, after which the
// transient entries are deleted. Sub-cells keep FactoryStorage below the
// 1023-bit / 4-ref main-cell limit.

const MAX_FACTORY_POOLS: int = 4096
const MAX_IN_FLIGHT_CREATES: int = 128

// Keep both deployable code cells in one address-determining bundle.
struct FactoryCodes {
    poolCode: cell
    tonPoolCode: cell
}

struct Registries {
    poolRegistry: map<uint256, address>        // hash(jettonMaster, denom) -> jetton pool addr
    poolAddressToKey: map<address, uint256>    // jetton pool addr -> registry key
    tonPoolRegistry: map<uint256, address>     // hash(denom) -> TonPool addr
    tonPoolAddressToKey: map<address, uint256> // TonPool addr -> registry key
}

struct CreateSenders {
    poolAddressToCreator: map<address, address>    // jetton pool addr -> create sender
    tonPoolAddressToCreator: map<address, address> // TON pool addr -> create sender
}

struct FactoryStorage {
    // vNext deployment-only layout. Legacy Factory data is intentionally not
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
