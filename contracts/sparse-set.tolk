import "@stdlib/exotic-cells"
import "constants"

// Transparent sparse sets used for duplicate commitments and spent nullifiers.
// The value zero is the empty-subtree sentinel; non-empty hashes are domain
// separated so the two sets cannot share witnesses.
const SPARSE_SET_COMMITMENT_DOMAIN: uint32 = 0x5a4b4301
const SPARSE_SET_NULLIFIER_DOMAIN: uint32 = 0x5a4b4e01
const SPARSE_SET_LEAF_TAG: uint8 = 1
const SPARSE_SET_NODE_TAG: uint8 = 2
const SPARSE_SET_BUCKET_BITS: int = 8
const SPARSE_SET_BUCKET_MASK: int = (1 << SPARSE_SET_BUCKET_BITS) - 1
const SPARSE_SET_DEPTH: int = 247
const SPARSE_SET_PROOF_BITS: int = 256 + SPARSE_SET_DEPTH
const SPARSE_SET_SIBLINGS_PER_CELL: int = 3

/// Canonical proof root. `siblings` is a packed chain ordered by increasing
/// tree level; its exact shape is validated by `sparseSetApplyUpdate`.
struct SparseSetUpdateProof {
    expectedRoot: uint256
    siblingBitmap: uint247
    siblings: cell
}

enum SparseSetUpdateStatus {
    Ok = 0
    InvalidDomain = 1
    InvalidKey = 2
    MalformedProof = 3
    StaleRoot = 4
    NonEmptyLeafOrInvalidWitness = 5
}

/// Runtime-only result. Pool handlers translate the status into their stable
/// deposit/withdraw error codes and persist `newRoot` only when status is Ok.
struct SparseSetUpdateResult {
    status: SparseSetUpdateStatus
    bucketId: uint8
    newRoot: uint256
    bucketWasPresent: bool = false
}

@pure
@inline
fun sparseSetIsKnownDomain(domain: uint32): bool {
    return domain == SPARSE_SET_COMMITMENT_DOMAIN || domain == SPARSE_SET_NULLIFIER_DOMAIN;
}

@pure
@inline
fun sparseSetBucketId(key: uint256): uint8 {
    return (key & SPARSE_SET_BUCKET_MASK) as uint8;
}

@pure
@inline
fun sparseSetPath(key: uint256): int {
    return key >> SPARSE_SET_BUCKET_BITS;
}

@pure
@inline
fun sparseSetLeafHash(domain: uint32, key: uint256): uint256 {
    return beginCell()
        .storeUint((domain << 8) | SPARSE_SET_LEAF_TAG, 40)
        .storeUint(key, 256)
        .hash();
}

@pure
@inline
fun sparseSetNonEmptyNodeHashWithHeader(
    header: uint48,
    left: uint256,
    right: uint256,
): uint256 {
    return beginCell().storeUint(header, 48).storeUint(left, 256).storeUint(right, 256).hash();
}

@pure
@inline
fun sparseSetNonEmptyNodeHash(
    domain: uint32,
    level: uint8,
    left: uint256,
    right: uint256,
): uint256 {
    val header = ((domain << 16) | (SPARSE_SET_NODE_TAG << 8) | level) as uint48;
    return sparseSetNonEmptyNodeHashWithHeader(header, left, right);
}

@pure
@inline
fun sparseSetIsCanonicalSiblingChunk(chunk: slice, isExotic: bool): bool {
    if (isExotic) {
        return false;
    }
    val bits = chunk.remainingBitsCount();
    val refs = chunk.remainingRefsCount();
    if (refs == 1) {
        return bits == SPARSE_SET_SIBLINGS_PER_CELL * 256;
    }
    return refs == 0 && bits <= SPARSE_SET_SIBLINGS_PER_CELL * 256 && bits % 256 == 0;
}

/// Verify an empty-leaf witness against `storedRoot` and return the only root
/// that can result from inserting `key`. The caller never supplies `newRoot`.
@pure
fun sparseSetApplyUpdate(
    domain: uint32,
    key: uint256,
    storedRoot: uint256,
    proofCell: cell,
): SparseSetUpdateResult {
    val bucketId = sparseSetBucketId(key);
    if (!sparseSetIsKnownDomain(domain)) {
        return {
            status: SparseSetUpdateStatus.InvalidDomain,
            bucketId,
            newRoot: 0,
        };
    }
    if (key >= BLS12_381_R) {
        return {
            status: SparseSetUpdateStatus.InvalidKey,
            bucketId,
            newRoot: 0,
        };
    }

    // check-disable-next-line mutable-variable-can-be-immutable
    var (proof, proofIsExotic) = proofCell.beginParseSpecial();
    if (
        proofIsExotic || proof.remainingBitsCount() != SPARSE_SET_PROOF_BITS ||
        proof.remainingRefsCount() != 1
    ) {
        return {
            status: SparseSetUpdateStatus.MalformedProof,
            bucketId,
            newRoot: 0,
        };
    }

    val expectedRoot = proof.loadUint(256);
    val siblingBitmap = proof.loadUint(SPARSE_SET_DEPTH);
    val siblingChain = proof.loadRef();
    if (expectedRoot != storedRoot) {
        return {
            status: SparseSetUpdateStatus.StaleRoot,
            bucketId,
            newRoot: 0,
        };
    }

    // The chain is validated while it is consumed. Every shape check happens
    // before a load, so malformed proofs return a status instead of throwing.
    // check-disable-next-line mutable-variable-can-be-immutable
    var (chain, chainIsExotic) = siblingChain.beginParseSpecial();
    if (!sparseSetIsCanonicalSiblingChunk(chain, chainIsExotic)) {
        return {
            status: SparseSetUpdateStatus.MalformedProof,
            bucketId,
            newRoot: 0,
        };
    }

    var oldRoot: uint256 = 0;
    var newRoot = sparseSetLeafHash(domain, key);
    var path = sparseSetPath(key);
    var bitmap = siblingBitmap;
    var level: uint8 = 0;
    val nodeDomainBuilder = beginCell().storeUint(
        (domain << 8) | SPARSE_SET_NODE_TAG,
        40,
    );

    repeat (SPARSE_SET_DEPTH) {
        var sibling: uint256 = 0;
        if ((bitmap & 1) != 0) {
            if (chain.remainingBitsCount() == 0) {
                if (chain.remainingRefsCount() != 1) {
                    return {
                        status: SparseSetUpdateStatus.MalformedProof,
                        bucketId,
                        newRoot: 0,
                    };
                }
                val nextChunk = chain.loadRef();
                // check-disable-next-line mutable-variable-can-be-immutable
                (chain, chainIsExotic) = nextChunk.beginParseSpecial();
                if (!sparseSetIsCanonicalSiblingChunk(chain, chainIsExotic)) {
                    return {
                        status: SparseSetUpdateStatus.MalformedProof,
                        bucketId,
                        newRoot: 0,
                    };
                }
                if (chain.remainingBitsCount() == 0) {
                    return {
                        status: SparseSetUpdateStatus.MalformedProof,
                        bucketId,
                        newRoot: 0,
                    };
                }
            }
            sibling = chain.loadUint(256);
            if (sibling == 0) {
                return {
                    status: SparseSetUpdateStatus.MalformedProof,
                    bucketId,
                    newRoot: 0,
                };
            }
        }

        var prefixBuilder = nodeDomainBuilder;
        prefixBuilder.storeUint(level, 8);
        if ((path & 1) == 0) {
            if (oldRoot != 0 || sibling != 0) {
                var oldBuilder = prefixBuilder;
                oldRoot = oldBuilder.storeUint(oldRoot, 256).storeUint(sibling, 256).hash();
            }
            var newBuilder = prefixBuilder;
            newRoot = newBuilder.storeUint(newRoot, 256).storeUint(sibling, 256).hash();
        } else {
            var leftPrefixBuilder = prefixBuilder;
            leftPrefixBuilder.storeUint(sibling, 256);
            if (oldRoot != 0 || sibling != 0) {
                var oldBuilder = leftPrefixBuilder;
                oldRoot = oldBuilder.storeUint(oldRoot, 256).hash();
            }
            var newBuilder = leftPrefixBuilder;
            newRoot = newBuilder.storeUint(newRoot, 256).hash();
        }

        path >>= 1;
        bitmap >>= 1;
        level += 1;
    }

    if (!chain.isEmpty()) {
        return {
            status: SparseSetUpdateStatus.MalformedProof,
            bucketId,
            newRoot: 0,
        };
    }

    if (oldRoot != storedRoot) {
        return {
            status: SparseSetUpdateStatus.NonEmptyLeafOrInvalidWitness,
            bucketId,
            newRoot: 0,
        };
    }

    return {
        status: SparseSetUpdateStatus.Ok,
        bucketId,
        newRoot,
    };
}
