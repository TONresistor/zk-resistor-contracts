// ============================================================================
// FACTORY STORAGE
// ============================================================================
//
// The factory has no admin and no changeable state beyond the registries.
// Forward maps (key -> poolAddress) let off-chain consumers enumerate pools;
// reverse maps (poolAddress -> key) let onBouncedMessage roll back a failed
// deploy. The Registries struct lives in a sub-cell so FactoryStorage stays
// under the 1023-bit / 4-ref main-cell limit.

struct Registries {
    poolRegistry: map<uint256, address>        // hash(jettonMaster, denom) -> jetton pool addr
    poolAddressToKey: map<address, uint256>    // jetton pool addr -> registry key
    tonPoolRegistry: map<uint256, address>     // hash(denom) -> TonPool addr
    tonPoolAddressToKey: map<address, uint256> // TonPool addr -> registry key
}

struct FactoryStorage {
    poolCode: cell    // jetton pool code, set at deploy
    tonPoolCode: cell // TON pool code, set at deploy
    poolCount: uint32
    tonPoolCount: uint32
    registries: Cell<Registries>
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

type AllowedFactoryMessage = CreatePool | CreateTonPool

// jettonMaster is null for TON pools.
struct (0xc0c0c0) FactoryPoolCreatedEvent {
    jettonMaster: address?
    denomination: coins
    poolAddress: address
}
