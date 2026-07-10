import "errors"
import "pool-types" // for MerkleState (shared with jetton pool)
import "sparse-set"

// Acton 1.0.0 wrappers import only this direct ABI module. Local aliases keep
// the generated wrapper self-contained while preserving the exact cell layout.
type TonPoolZkProof = ZkProof

type TonPoolSparseSetUpdateProof = SparseSetUpdateProof

// Local wire-equivalent declaration keeps Acton 1.0.0's generated wrapper
// independent from transitive imports.
struct (0x46504300) TonPoolConfirmPoolDeployment {
    queryId: uint64
}

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

fun calculateTonPoolWithdrawalCount(
    denomination: coins,
    deposits: uint32,
    pendingWithdrawTon: coins,
): uint32 {
    assert (denomination > 0) throw Errors.InvalidDenomination;
    assert (pendingWithdrawTon % denomination == 0) throw Errors.FactoryInvariantViolation;
    val pendingCount = pendingWithdrawTon / denomination;
    assert (pendingCount <= deposits) throw Errors.FactoryInvariantViolation;
    return deposits - (pendingCount as uint32);
}

// ============================================================================
// MESSAGES
// ============================================================================

// Direct TON deposit. Requires msg.value >= denomination + MIN_DEPOSIT_VALUE;
// below the floor, the pool refunds the full TON value to fromUser.
struct (0xd6e05112) TonDepositPayload {
    queryId: uint64
    fromUser: address
    commitment: uint256
    newRoot: uint256
    insertProof: Cell<TonPoolZkProof>
    commitmentSetProof: Cell<TonPoolSparseSetUpdateProof>
}

// Same body / circuit as jetton Pool's Withdraw.
struct (0x4b6f0b51) TonWithdraw {
    queryId: uint64
    root: uint256
    nullifierHash: uint256
    recipient: address
    proof: Cell<TonPoolZkProof>
    nullifierSetProof: Cell<TonPoolSparseSetUpdateProof>
}

struct (0x00de9052) TonDepositEvent {
    leafIndex: uint32
    commitment: uint256
    newRoot: uint256
    fromUser: address
    sparseUpdate: Cell<SparseSetEventUpdate>
}

struct (0x00717d3b) TonWithdrawEvent {
    nullifierHash: uint256
    recipient: address
    payout: coins
    sparseUpdate: Cell<SparseSetEventUpdate>
}

// ============================================================================
// DISPATCH UNION
// ============================================================================

type AllowedTonMessage =
    | TonPoolConfirmPoolDeployment
    | TonDepositPayload
    | TonWithdraw
