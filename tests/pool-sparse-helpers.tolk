import "@acton/emulation/network"
import "@contracts/pool-types"
import "@contracts/sparse-set"
import "@tests/sparse-set-helpers"
import "@wrappers/Pool.gen"

fun poolEmptySparseSetProof(domain: uint32, key: uint256): SparseSetUpdateProof {
    val tree = newSparseSetTestTree(domain);
    return SparseSetUpdateProof.fromCell(tree.proofFor(key));
}

fun poolOccupiedSparseSetProof(domain: uint32, key: uint256): SparseSetUpdateProof {
    var tree = newSparseSetTestTree(domain);
    tree.insert(key);
    return SparseSetUpdateProof.fromCell(tree.proofFor(key));
}

fun Pool.sendWithdrawWithEmptySparseProof(
    self,
    from: address,
    clientQueryId: uint64,
    root: uint256,
    nullifierHash: uint256,
    recipient: address,
    proof: ZkProof,
    config: SendParams = {},
): SendResultList {
    return self.sendWithdraw(
        from,
        clientQueryId,
        root,
        nullifierHash,
        recipient,
        proof,
        poolEmptySparseSetProof(SPARSE_SET_NULLIFIER_DOMAIN, nullifierHash),
        config,
    );
}

fun poolDepositPayload(
    queryId: uint64,
    commitment: uint256,
    newRoot: uint256,
    insertProof: ZkProof,
    commitmentSetProof: SparseSetUpdateProof,
): cell {
    return (DepositPayload {
        queryId,
        commitment,
        newRoot,
        insertProof: insertProof.toCell(),
        commitmentSetProof: commitmentSetProof.toCell(),
    }).toCell();
}
