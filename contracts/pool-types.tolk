import "@stdlib/exotic-cells"
import "constants"
import "deployment-types"
import "sparse-set"

// Acton 1.0.0 wrappers import only this direct ABI module. Local aliases keep
// generated wrappers self-contained while preserving the referenced layouts.
type PoolSparseSetUpdateProof = SparseSetUpdateProof

type PoolConfirmPoolDeployment = ConfirmPoolDeployment

// Jetton withdrawals must self-fund the direct TEP-74 payout. The shared
// MIN_WITHDRAW_GAS remains the native-TON floor; this higher floor is verified
// against integrated sparse + Groth16 traces.
const MIN_JETTON_WITHDRAW_GAS: coins = 250000000 // 0.25 TON
const JETTON_PAYOUT_VALUE: coins = 150000000 // 0.15 TON

// Ten-year basechain storage runway at the Acton configuration used by the
// release gates, with a 2x margin. Growth is charged progressively because the
// 512 sparse roots can materialize long before the note tree reaches capacity.
const POOL_BASE_RENT_RUNWAY: coins = 270000000 // empty Pool StateInit: >2x 0.132522803
const POOL_ROOT_HISTORY_RENT_PER_SLOT: coins = 2600000
const POOL_SPARSE_BUCKET_RENT: coins = 2600000
const POOL_DEPOSIT_FEE_MARGIN: coins = 50000000 // dense integrated path + event margin

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

// jettonWallet starts null and is bound by the authenticated TEP-89 response.
// Only that wallet may forward jetton-transfer-notifications.
struct Storage {
    identity: Cell<PoolIdentity>
    jettonWallet: address?
    relayerReserve: coins
    merkle: Cell<MerkleState>
    withdrawalCount: uint32
}

struct SparseSetRoots {
    commitmentBucketCount: uint16 = 0
    nullifierBucketCount: uint16 = 0
    commitmentSeenRoots: map<uint8, uint256>
    nullifierSpentRoots: map<uint8, uint256>
}

fun createEmptySparseSetRoots(): Cell<SparseSetRoots> {
    return (SparseSetRoots {
        commitmentBucketCount: 0,
        nullifierBucketCount: 0,
        commitmentSeenRoots: [],
        nullifierSpentRoots: [],
    }).toCell();
}

struct SparseSetEventUpdate {
    bucketId: uint8
    newRoot: uint256
}

struct MerkleState {
    nextIndex: uint32
    currentRoot: uint256
    rootHistory: map<uint32, uint256> = [] // circular buffer; index = leafIndex % ROOT_HISTORY_SIZE
    sparseSets: Cell<SparseSetRoots>
}

fun MerkleState.sparseSetRoot(
    self,
    domain: uint32,
    bucketId: uint8,
): uint256 {
    val roots = self.sparseSets.load();
    val entry = domain == SPARSE_SET_COMMITMENT_DOMAIN
        ? roots.commitmentSeenRoots.get(bucketId)
        : roots.nullifierSpentRoots.get(bucketId);
    return entry.isFound ? entry.loadValue() : 0;
}

fun MerkleState.prepareSparseSetUpdate(
    self,
    domain: uint32,
    key: uint256,
    proof: cell,
): SparseSetUpdateResult {
    val bucketId = sparseSetBucketId(key) as uint8;
    var storedRoot: uint256 = 0;
    var bucketWasPresent = false;
    val roots = self.sparseSets.load();
    val entry = domain == SPARSE_SET_COMMITMENT_DOMAIN
        ? roots.commitmentSeenRoots.get(bucketId)
        : roots.nullifierSpentRoots.get(bucketId);
    if (entry.isFound) {
        storedRoot = entry.loadValue();
        bucketWasPresent = true;
    }
    var update = sparseSetApplyUpdate(domain, key, storedRoot, proof);
    update.bucketWasPresent = bucketWasPresent;
    return update;
}

fun MerkleState.commitSparseSetUpdate(
    mutate self,
    domain: uint32,
    update: SparseSetUpdateResult,
) {
    assert (update.status == SparseSetUpdateStatus.Ok) throw 0xFFFE;
    val bucketId = update.bucketId as uint8;
    var roots = self.sparseSets.load();
    if (domain == SPARSE_SET_COMMITMENT_DOMAIN) {
        if (!update.bucketWasPresent) {
            assert (roots.commitmentBucketCount < 256) throw 0xFFFE;
            roots.commitmentBucketCount += 1;
        }
        roots.commitmentSeenRoots.set(bucketId, update.newRoot);
    } else {
        assert (domain == SPARSE_SET_NULLIFIER_DOMAIN) throw 0xFFFE;
        if (!update.bucketWasPresent) {
            assert (roots.nullifierBucketCount < 256) throw 0xFFFE;
            roots.nullifierBucketCount += 1;
        }
        roots.nullifierSpentRoots.set(bucketId, update.newRoot);
    }
    self.sparseSets = roots.toCell();
}

@inline
fun MerkleState.poolRentRunway(self): coins {
    val roots = self.sparseSets.load();
    val historySlots = min(self.nextIndex, ROOT_HISTORY_SIZE as uint32);
    val bucketCount: uint32 = (roots.commitmentBucketCount as uint32) +
    (roots.nullifierBucketCount as uint32);
    return POOL_BASE_RENT_RUNWAY + POOL_ROOT_HISTORY_RENT_PER_SLOT * historySlots +
    POOL_SPARSE_BUCKET_RENT * bucketCount;
}

// ------ MerkleState mutate methods (state transitions live near the data) ------

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

fun MerkleState.insertCommitmentBounded(
    mutate self,
    newRoot: uint256,
    commitmentUpdate: SparseSetUpdateResult,
): uint32 {
    self.commitSparseSetUpdate(SPARSE_SET_COMMITMENT_DOMAIN, commitmentUpdate);
    val leafIndex = self.nextIndex;
    self.nextIndex = leafIndex + 1;

    val slot: uint32 = leafIndex % ROOT_HISTORY_SIZE;
    self.rootHistory.set(slot, newRoot);
    self.currentRoot = newRoot;
    return leafIndex;
}

fun MerkleState.markNullifierSpentBounded(
    mutate self,
    nullifierUpdate: SparseSetUpdateResult,
) {
    self.commitSparseSetUpdate(SPARSE_SET_NULLIFIER_DOMAIN, nullifierUpdate);
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
struct (0xd6e05112) DepositPayload {
    queryId: uint64
    commitment: uint256
    newRoot: uint256
    insertProof: Cell<ZkProof>
    commitmentSetProof: Cell<PoolSparseSetUpdateProof>
}

// Withdraw: the recipient field binding is derived inside handleWithdraw
// from msg.recipient, so the message cannot disagree with the proof.
struct (0x4b6f0b51) Withdraw {
    clientQueryId: uint64
    root: uint256
    nullifierHash: uint256
    recipient: address
    proof: Cell<ZkProof>
    nullifierSetProof: Cell<PoolSparseSetUpdateProof>
}

// Permissionless wallet-binding retrigger. It repeats the TEP-89 query while
// no wallet is bound, then repeats the Factory confirmation once binding is complete.
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

struct (0x00de9052) DepositEvent {
    leafIndex: uint32
    commitment: uint256
    newRoot: uint256
    fromUser: address
    sparseUpdate: Cell<SparseSetEventUpdate>
}

struct (0x00717d3c) WithdrawalAcceptedEvent {
    clientQueryId: uint64
    nullifierHash: uint256
    recipient: address
    payout: coins
    sparseUpdate: Cell<SparseSetEventUpdate>
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
    val (initialProofSlice, proofIsExotic) = proofCell.beginParseSpecial();
    var proofSlice = initialProofSlice;
    if (
        proofIsExotic || proofSlice.remainingBitsCount() != 0 ||
        proofSlice.remainingRefsCount() != 3
    ) {
        return false;
    }

    val proofA = proofSlice.loadRef();
    val proofB = proofSlice.loadRef();
    val proofC = proofSlice.loadRef();
    return isOrdinaryProofPoint(proofA, 384) && isOrdinaryProofPoint(proofB, 768) &&
    isOrdinaryProofPoint(proofC, 384);
}

fun isOrdinaryProofPoint(point: cell, expectedBits: int): bool {
    val (pointSlice, pointIsExotic) = point.beginParseSpecial();
    return !pointIsExotic && pointSlice.remainingBitsCount() == expectedBits &&
    pointSlice.remainingRefsCount() == 0;
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
    | PoolConfirmPoolDeployment
    | InitWalletBinding
    | TakeWalletAddress
    | JettonTransferNotification
    | Withdraw
