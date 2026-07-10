// Shared Factory <-> Pool deployment handshake. This module has no storage
// dependencies, so Pool, TonPool and Factory can all import it without cycles.

const OP_CONFIRM_POOL_DEPLOYMENT: int = 0x46504300
const OP_POOL_DEPLOY_CONFIRMED: int = 0x46504301

// Permissionless, retriggerable activation command. The receiving pool funds
// its confirmation callback strictly from the value attached to this message.
struct (0x46504300) ConfirmPoolDeployment {
    queryId: uint64
}

// The identity fields let Factory authenticate the sender against a permanent
// forward registry after the transient reverse/creator entries are cleaned.
struct (0x46504301) PoolDeployConfirmed {
    queryId: uint64
    jettonMaster: address? // null identifies a native TON pool
    denomination: coins
}
