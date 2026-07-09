import "constants"

// ============================================================================
// STORAGE
// ============================================================================
//
// Field order is TL-B compatible and address-determining. Changing it bumps
// the code hash and so the pool address.

// Immutable identity. Pool address depends on (poolCode, this struct).
struct PoolIdentity {
    jettonMaster: address
    factory: address
    denomination: coins
}

// jettonWallet starts null at deploy and is bound by the TEP-89 round-trip
// (see InitWalletBinding / TakeWalletAddress). Once locked, it is the only
// sender allowed to forward jetton-transfer-notifications.
struct Storage {
    identity: Cell<PoolIdentity>
    jettonWallet: address?
    relayerReserve: coins
    merkle: Cell<MerkleState>
    withdrawals: map<uint64, Cell<JettonWithdrawalRecovery>>
}

// Durable recovery record for the first asynchronous hop
// Pool -> Pool's jetton wallet. `retryable` is set only by an authenticated
// bounced JettonTransfer. A successful first hop leaves it false forever,
// preventing duplicate payouts even though TEP-74 has no universal final ACK.
struct JettonWithdrawalRecovery {
    root: uint256
    nullifierHash: uint256
    lastPayer: address
    retryable: bool
}

struct MerkleState {
    nextIndex: uint32
    currentRoot: uint256
    rootHistory: map<uint32, uint256> = [] // circular buffer; index = leafIndex % ROOT_HISTORY_SIZE
    nullifiers: map<uint256, bool> = []    // spent withdraw nullifiers (value always true)
    commitments: map<uint256, uint32> = [] // commitment -> leafIndex (anti-replay on deposits)
}

// ------ MerkleState mutate methods (state transitions live near the data) ------

fun MerkleState.isCommitmentUsed(self, commitment: uint256): bool {
    return self.commitments.exists(commitment);
}

fun MerkleState.isNullifierSpent(self, nullifierHash: uint256): bool {
    return self.nullifiers.exists(nullifierHash);
}

fun MerkleState.isKnownRoot(self, root: uint256): bool {
    if (root == self.currentRoot) {
        return true;
    }
    // Iterate only the present slots (bounded by ROOT_HISTORY_SIZE = 100).
    var entry = self.rootHistory.findFirst();
    while (entry.isFound) {
        if (entry.loadValue() == root) {
            return true;
        }
        entry = self.rootHistory.iterateNext(entry);
    }
    return false;
}

fun MerkleState.insertCommitment(mutate self, commitment: uint256, newRoot: uint256): uint32 {
    val leafIndex = self.nextIndex;
    self.commitments.set(commitment, leafIndex);
    self.nextIndex = leafIndex + 1;

    // Append the new root to the history at the circular slot, then advance.
    val slot: uint32 = leafIndex % ROOT_HISTORY_SIZE;
    self.rootHistory.set(slot, newRoot);
    self.currentRoot = newRoot;

    return leafIndex;
}

fun MerkleState.markNullifierSpent(mutate self, nullifierHash: uint256) {
    self.nullifiers.set(nullifierHash, true);
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// ============================================================================
// MESSAGES
// ============================================================================

// TEP-74 transfer notification. forward_payload (Either Cell ^Cell) carries
// the user's commitment + insertion proof as a DepositPayload.
struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64
    amount: coins
    fromUser: address
    forwardPayload: RemainingBitsAndRefs
}

// Forward payload inside the TEP-74 notification. Generated client-side
// alongside the insertion proof.
struct (0xd6e05111) DepositPayload {
    queryId: uint64
    commitment: uint256
    newRoot: uint256
    insertProof: Cell<ZkProof>
}

// Withdraw: the recipient field binding is derived inside handleWithdraw
// from msg.recipient, so the message cannot disagree with the proof.
struct (0x4b6f0b50) Withdraw {
    queryId: uint64
    root: uint256
    nullifierHash: uint256
    recipient: address
    proof: Cell<ZkProof>
}

// Wallet-binding trigger. Factory sends it atomic-with-deploy; anyone may
// retrigger if the master never replied. Idempotent.
struct (0xa0c0c0c1) InitWalletBinding {
    queryId: uint64
}

// TEP-89 outgoing query (pool -> jettonMaster). includeAddress=false: we
// already know the owner.
struct (0x2c76b973) ProvideWalletAddress {
    queryId: uint64
    ownerAddress: address
    includeAddress: bool
}

// TEP-89 incoming response (jettonMaster -> pool). The trailing
// `owner_address:(Maybe ^MsgAddress)` is slurped by `rest` for compat with
// masters that always echo it.
struct (0xd1735400) TakeWalletAddress {
    queryId: uint64
    walletAddress: address
    rest: RemainingBitsAndRefs
}

// Pool transitions to ready: jettonWallet locked.
struct (0x00def002) PoolReadyEvent {
    jettonWallet: address
}

struct (0x00de9051) DepositEvent {
    leafIndex: uint32
    commitment: uint256
    newRoot: uint256
    fromUser: address
}

struct (0x00717d3a) WithdrawEvent {
    nullifierHash: uint256
    recipient: address
    payout: coins
}

// Legacy failure-event ABI retained for negative tests; current refund paths
// do not emit contract-funded failure logs.
struct (0x00def000) DepositRefundedEvent {
    fromUser: address
    amount: coins
    reason: uint16
}

// Legacy failure-event ABI retained for negative tests; current bounce paths
// refund remaining bounce gas to the last payer without emitting this log.
struct (0x00def001) WithdrawBouncedEvent {
    queryId: uint64
}

// Legacy failure-event ABI retained for negative tests; current retry paths do
// not emit contract-funded retry logs.
struct (0x00def003) WithdrawRetriedEvent {
    queryId: uint64
    recipient: address
}

// Outgoing TEP-74 jetton transfer.
struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address
    customPayload: cell? = null
    forwardAmount: coins = 0
    forwardPayload: cell? = null
}

// Groth16 BLS12-381 proof. G1 = 48 bytes, G2 = 96 bytes, compressed BLST.
struct ZkProof {
    proofA: Cell<G1Point>
    proofB: Cell<G2Point>
    proofC: Cell<G1Point>
}

fun isWellFormedZkProofCell(proofCell: cell): bool {
    val proofSlice = proofCell.beginParse();
    return proofSlice.remainingBitsCount() == 0 && proofSlice.remainingRefsCount() == 3;
}

struct G1Point {
    raw: RemainingBitsAndRefs
}

struct G2Point {
    raw: RemainingBitsAndRefs
}

// ============================================================================
// DISPATCH UNION
// ============================================================================

type AllowedMessage =
    | InitWalletBinding
    | TakeWalletAddress
    | JettonTransferNotification
    | Withdraw
