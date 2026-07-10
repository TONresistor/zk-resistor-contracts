import "@contracts/pool-types"
import "@contracts/sparse-set"

@pure
@inline
fun sparseSetNodeHash(
    domain: uint32,
    level: uint8,
    left: uint256,
    right: uint256,
): uint256 {
    if (left == 0 && right == 0) {
        return 0;
    }
    return sparseSetNonEmptyNodeHash(domain, level, left, right);
}

// Test-only transparent tree. Production keeps only the 256 bucket roots;
// tests retain all nodes so they can generate valid witnesses incrementally.
struct SparseSetTestTree {
    domain: uint32
    nodes: map<uint256, uint256>
}

fun newSparseSetTestTree(domain: uint32): SparseSetTestTree {
    return { domain, nodes: [] };
}

@pure
fun sparseSetTestNodeKey(bucketId: int, height: int, nodeIndex: int): uint256 {
    return beginCell()
        .storeUint(bucketId, 8)
        .storeUint(height, 8)
        .storeUint(nodeIndex, SPARSE_SET_DEPTH)
        .hash();
}

@pure
fun SparseSetTestTree.nodeAt(self, bucketId: int, height: int, nodeIndex: int): uint256 {
    val lookup = self.nodes.get(sparseSetTestNodeKey(bucketId, height, nodeIndex));
    if (!lookup.isFound) {
        return 0;
    }
    return lookup.loadValue();
}

@pure
fun SparseSetTestTree.rootFor(self, key: uint256): uint256 {
    return self.nodeAt(sparseSetBucketId(key), SPARSE_SET_DEPTH, 0);
}

fun sparseSetPackTestSiblings(siblings: array<uint256>): cell {
    if (siblings.size() == 0) {
        return createEmptyCell();
    }

    var next: cell? = null;
    var chunkStart = ((siblings.size() - 1) / SPARSE_SET_SIBLINGS_PER_CELL) *
    SPARSE_SET_SIBLINGS_PER_CELL;
    while (chunkStart >= 0) {
        var chunk = beginCell();
        var i = chunkStart;
        val chunkEnd = min(
            chunkStart + SPARSE_SET_SIBLINGS_PER_CELL,
            siblings.size(),
        );
        while (i < chunkEnd) {
            chunk.storeUint(siblings.get(i), 256);
            i += 1;
        }
        if (next != null) {
            chunk.storeRef(next!);
        }
        next = chunk.endCell();
        chunkStart -= SPARSE_SET_SIBLINGS_PER_CELL;
    }
    return next!;
}

fun denseSparseSetTestSiblings(): array<uint256> {
    var siblings: array<uint256> = [];
    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        siblings.push((level as uint256) + 1);
        level += 1;
    }
    return siblings;
}

fun denseSparseSetTestOldRoot(domain: uint32, key: uint256): uint256 {
    var root: uint256 = 0;
    var path = sparseSetPath(key);
    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        val sibling: uint256 = level + 1;
        root = (path & 1) == 0
            ? sparseSetNodeHash(domain, level as uint8, root, sibling)
            : sparseSetNodeHash(domain, level as uint8, sibling, root);
        path >>= 1;
        level += 1;
    }
    return root;
}

fun denseSparseSetTestProof(domain: uint32, key: uint256): SparseSetUpdateProof {
    return {
        expectedRoot: denseSparseSetTestOldRoot(domain, key),
        siblingBitmap: ((1 << SPARSE_SET_DEPTH) - 1) as uint247,
        siblings: sparseSetPackTestSiblings(denseSparseSetTestSiblings()),
    };
}

fun denseSparseSetTestRoots(domain: uint32, key: uint256): Cell<SparseSetRoots> {
    var commitmentSeenRoots: map<uint8, uint256> = [];
    var nullifierSpentRoots: map<uint8, uint256> = [];
    val bucketId = sparseSetBucketId(key) as uint8;
    val root = denseSparseSetTestOldRoot(domain, key);
    if (domain == SPARSE_SET_COMMITMENT_DOMAIN) {
        commitmentSeenRoots.set(bucketId, root);
    } else {
        assert (domain == SPARSE_SET_NULLIFIER_DOMAIN) throw 9904;
        nullifierSpentRoots.set(bucketId, root);
    }
    return (SparseSetRoots {
        commitmentBucketCount: domain == SPARSE_SET_COMMITMENT_DOMAIN ? 1 : 0,
        nullifierBucketCount: domain == SPARSE_SET_NULLIFIER_DOMAIN ? 1 : 0,
        commitmentSeenRoots,
        nullifierSpentRoots,
    }).toCell();
}

/// Build a canonical non-membership proof against the current test tree.
fun SparseSetTestTree.proofFor(self, key: uint256): cell {
    val bucketId = sparseSetBucketId(key);
    var nodeIndex = sparseSetPath(key);
    var bitmap = 0;
    var siblings: array<uint256> = [];
    var level = 0;

    while (level < SPARSE_SET_DEPTH) {
        val sibling = self.nodeAt(bucketId, level, nodeIndex ^ 1);
        if (sibling != 0) {
            bitmap |= 1 << level;
            siblings.push(sibling);
        }
        nodeIndex >>= 1;
        level += 1;
    }

    return (SparseSetUpdateProof {
        expectedRoot: self.rootFor(key),
        siblingBitmap: bitmap as uint247,
        siblings: sparseSetPackTestSiblings(siblings),
    }).toCell();
}

/// Return the pre-insertion witness and advance the test tree to the same
/// root that the on-chain helper computes.
fun SparseSetTestTree.insert(mutate self, key: uint256): cell {
    val proof = self.proofFor(key);
    val storedRoot = self.rootFor(key);
    val update = sparseSetApplyUpdate(self.domain, key, storedRoot, proof);
    assert (update.status == SparseSetUpdateStatus.Ok) throw 9901;

    val bucketId = sparseSetBucketId(key);
    var nodeIndex = sparseSetPath(key);
    var current = sparseSetLeafHash(self.domain, key);
    self.nodes.set(sparseSetTestNodeKey(bucketId, 0, nodeIndex), current);

    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        val sibling = self.nodeAt(bucketId, level, nodeIndex ^ 1);
        if ((nodeIndex & 1) == 0) {
            current = sparseSetNodeHash(self.domain, level as uint8, current, sibling);
        } else {
            current = sparseSetNodeHash(self.domain, level as uint8, sibling, current);
        }
        nodeIndex >>= 1;
        self.nodes.set(sparseSetTestNodeKey(bucketId, level + 1, nodeIndex), current);
        level += 1;
    }

    assert (current == update.newRoot) throw 9902;
    return proof;
}
