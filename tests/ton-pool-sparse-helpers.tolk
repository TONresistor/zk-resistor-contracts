import "@acton/emulation/network"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@tests/sparse-set-helpers"
import "@wrappers/TonPool.gen"

fun emptySparseSetProof(domain: uint32, key: uint256): SparseSetUpdateProof {
    val tree = newSparseSetTestTree(domain);
    return SparseSetUpdateProof.fromCell(tree.proofFor(key));
}

fun occupiedSparseSetProof(domain: uint32, key: uint256): SparseSetUpdateProof {
    var tree = newSparseSetTestTree(domain);
    tree.insert(key);
    return SparseSetUpdateProof.fromCell(tree.proofFor(key));
}

fun sparseSetRootsContaining(domain: uint32, key: uint256): Cell<SparseSetRoots> {
    var tree = newSparseSetTestTree(domain);
    tree.insert(key);

    var commitmentSeenRoots: map<uint8, uint256> = [];
    var nullifierSpentRoots: map<uint8, uint256> = [];
    val bucketId = sparseSetBucketId(key);
    val root = tree.rootFor(key);
    if (domain == SPARSE_SET_COMMITMENT_DOMAIN) {
        commitmentSeenRoots.set(bucketId, root);
    } else {
        assert (domain == SPARSE_SET_NULLIFIER_DOMAIN) throw 9903;
        nullifierSpentRoots.set(bucketId, root);
    }
    return (SparseSetRoots {
        commitmentBucketCount: domain == SPARSE_SET_COMMITMENT_DOMAIN ? 1 : 0,
        nullifierBucketCount: domain == SPARSE_SET_NULLIFIER_DOMAIN ? 1 : 0,
        commitmentSeenRoots,
        nullifierSpentRoots,
    }).toCell();
}

fun staleSparseSetProof(expectedRoot: uint256): SparseSetUpdateProof {
    return {
        expectedRoot,
        siblingBitmap: 0,
        siblings: createEmptyCell(),
    };
}

fun malformedSparseSetProof(expectedRoot: uint256): SparseSetUpdateProof {
    return {
        expectedRoot,
        siblingBitmap: 1,
        siblings: createEmptyCell(),
    };
}

fun TonPool.sendTonDepositWithEmptySparseProof(
    self,
    from: address,
    queryId: uint64,
    fromUser: address,
    commitment: uint256,
    newRoot: uint256,
    insertProof: ZkProof,
    config: SendParams = {},
): SendResultList {
    return self.sendTonDepositPayload(
        from,
        queryId,
        fromUser,
        commitment,
        newRoot,
        insertProof,
        emptySparseSetProof(SPARSE_SET_COMMITMENT_DOMAIN, commitment),
        config,
    );
}

fun TonPool.sendTonWithdrawWithEmptySparseProof(
    self,
    from: address,
    queryId: uint64,
    root: uint256,
    nullifierHash: uint256,
    recipient: address,
    proof: ZkProof,
    config: SendParams = {},
): SendResultList {
    return self.sendTonWithdraw(
        from,
        queryId,
        root,
        nullifierHash,
        recipient,
        proof,
        emptySparseSetProof(SPARSE_SET_NULLIFIER_DOMAIN, nullifierHash),
        config,
    );
}
