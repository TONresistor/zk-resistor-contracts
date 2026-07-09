import "pool-types" // for MerkleState (shared with jetton pool)

// ============================================================================
// STORAGE
// ============================================================================
//
// Mirror of the jetton Pool for native TON. Identity drops jettonMaster /
// jettonWallet; the deposit value is plain TON carried by the message.

struct TonPoolIdentity {
    factory: address
    denomination: coins
}

// pendingWithdrawTon = denomination * (deposits - withdraws); enforces the
// pool keeps enough TON to pay every pending recipient.
struct TonPoolStorage {
    identity: Cell<TonPoolIdentity>
    relayerReserve: coins
    pendingWithdrawTon: coins
    merkle: Cell<MerkleState>
}

fun TonPoolStorage.load(): TonPoolStorage {
    return TonPoolStorage.fromCell(contract.getData());
}

fun TonPoolStorage.save(self) {
    contract.setData(self.toCell());
}

// ============================================================================
// MESSAGES
// ============================================================================

// Direct TON deposit. Requires msg.value >= denomination + MIN_DEPOSIT_VALUE;
// below the floor, the pool refunds the full TON value to fromUser.
struct (0xd6e05111) TonDepositPayload {
    queryId: uint64
    fromUser: address
    commitment: uint256
    newRoot: uint256
    insertProof: Cell<ZkProof>
}

// Same body / circuit as jetton Pool's Withdraw.
struct (0x4b6f0b50) TonWithdraw {
    queryId: uint64
    root: uint256
    nullifierHash: uint256
    recipient: address
    proof: Cell<ZkProof>
}

// Legacy failure-event ABI retained for negative tests; current refund paths
// do not emit contract-funded failure logs.
struct (0x00def000) TonDepositRefundedEvent {
    fromUser: address
    amount: coins
    reason: uint16
}

struct (0x00de9051) TonDepositEvent {
    leafIndex: uint32
    commitment: uint256
    newRoot: uint256
    fromUser: address
}

struct (0x00717d3a) TonWithdrawEvent {
    nullifierHash: uint256
    recipient: address
    payout: coins
}

// ============================================================================
// DISPATCH UNION
// ============================================================================

type AllowedTonMessage =
    | TonDepositPayload
    | TonWithdraw
