import "@stdlib/exotic-cells"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@contracts/constants"
import "@contracts/sparse-set"
import "sparse-set-helpers"

fun sparseProofCell(expectedRoot: uint256, bitmap: int, siblings: cell): cell {
    return beginCell()
        .storeUint(expectedRoot, 256)
        .storeUint(bitmap, SPARSE_SET_DEPTH)
        .storeRef(siblings)
        .endCell();
}

fun emptySparseProof(expectedRoot: uint256 = 0): cell {
    return sparseProofCell(expectedRoot, 0, createEmptyCell());
}

fun denseSparseSiblings(): array<uint256> {
    var siblings: array<uint256> = [];
    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        siblings.push(level + 1);
        level += 1;
    }
    return siblings;
}

fun denseSparseOldRoot(domain: uint32, key: uint256): uint256 {
    var root: uint256 = 0;
    var path = sparseSetPath(key);
    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        val sibling: uint256 = level + 1;
        if ((path & 1) == 0) {
            root = sparseSetNodeHash(domain, level as uint8, root, sibling);
        } else {
            root = sparseSetNodeHash(domain, level as uint8, sibling, root);
        }
        path >>= 1;
        level += 1;
    }
    return root;
}

get fun `test sparse set key split uses low eight bucket bits`() {
    expect(sparseSetBucketId(0x0102)).toEqual(2);
    expect(sparseSetPath(0x0102)).toEqual(1);
    expect(sparseSetBucketId(BLS12_381_R - 1)).toEqual(0);
    expect(sparseSetPath(BLS12_381_R - 1)).toEqual((BLS12_381_R - 1) >> 8);
}

get fun `test sparse set proof root has exact canonical layout`() {
    val typed = (SparseSetUpdateProof {
        expectedRoot: 7,
        siblingBitmap: 5,
        siblings: beginCell().storeUint(11, 256).storeUint(13, 256).endCell(),
    }).toCell();
    val raw = sparseProofCell(
        7,
        5,
        beginCell().storeUint(11, 256).storeUint(13, 256).endCell(),
    );

    expect(typed.hash()).toEqual(raw.hash());
    val parsed = typed.beginParse();
    expect(parsed.remainingBitsCount()).toEqual(SPARSE_SET_PROOF_BITS);
    expect(parsed.remainingRefsCount()).toEqual(1);
}

get fun `test sparse set hashes match independent TypeScript vectors`() {
    val keyOneLeaf = sparseSetLeafHash(SPARSE_SET_COMMITMENT_DOMAIN, 1);
    expect(keyOneLeaf).toEqual(
        0x0436970446193375b4176eaf7525946aff80dd2227132e2182dcb1913a0697bb,
    );
    expect(sparseSetNodeHash(SPARSE_SET_COMMITMENT_DOMAIN, 0, keyOneLeaf, 0)).toEqual(
        0xaecfbdf470bd3f6f05453be4caa1000be993690168bcbcec49bbd8acb384ea04,
    );

    val keyOne = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        1,
        0,
        emptySparseProof(),
    );
    expect(keyOne.newRoot).toEqual(
        0xbbe0be78eb65a39b1a7b13922381e089c0b14c1c8d2ef1db3dd92010a97e97ac,
    );

    val key0102 = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        0x0102,
        0,
        emptySparseProof(),
    );
    expect(sparseSetLeafHash(SPARSE_SET_COMMITMENT_DOMAIN, 0x0102)).toEqual(
        0xf69ec039a082ce866fc04632541f19f4fc7373cb94dff365c0fa05ed19fae813,
    );
    expect(key0102.newRoot).toEqual(
        0x5af50a31a5a143de454df246051534fad6fbc551d94121157b34d6331fc5ebcd,
    );
}

get fun `test sparse set empty witness inserts and derives root internally`() {
    val key: uint256 = 0x0102;
    val update = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        key,
        0,
        emptySparseProof(),
    );

    expect(update.status).toEqual(SparseSetUpdateStatus.Ok);
    expect(update.bucketId).toEqual(2);
    expect(update.newRoot != 0).toEqual(true);

    var expected = sparseSetLeafHash(SPARSE_SET_COMMITMENT_DOMAIN, key);
    var path = sparseSetPath(key);
    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        if ((path & 1) == 0) {
            expected = sparseSetNodeHash(
                SPARSE_SET_COMMITMENT_DOMAIN,
                level as uint8,
                expected,
                0,
            );
        } else {
            expected = sparseSetNodeHash(
                SPARSE_SET_COMMITMENT_DOMAIN,
                level as uint8,
                0,
                expected,
            );
        }
        path >>= 1;
        level += 1;
    }
    expect(update.newRoot).toEqual(expected);
}

get fun `test sparse set domains produce independent leaves and roots`() {
    val key: uint256 = 42;
    val commitment = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        key,
        0,
        emptySparseProof(),
    );
    val nullifier = sparseSetApplyUpdate(
        SPARSE_SET_NULLIFIER_DOMAIN,
        key,
        0,
        emptySparseProof(),
    );

    expect(
        sparseSetLeafHash(SPARSE_SET_COMMITMENT_DOMAIN, key) !=
        sparseSetLeafHash(SPARSE_SET_NULLIFIER_DOMAIN, key),
    ).toEqual(true);
    expect(commitment.newRoot != nullifier.newRoot).toEqual(true);
}

get fun `test sparse set incremental helper builds valid same-bucket witnesses`() {
    var tree = newSparseSetTestTree(SPARSE_SET_COMMITMENT_DOMAIN);
    val keys: array<uint256> = [1, 257, 513, 769, 1025];
    val crossRoots: array<uint256> = [
        0xbbe0be78eb65a39b1a7b13922381e089c0b14c1c8d2ef1db3dd92010a97e97ac,
        0xeba4e2746788daf95de5297d1b6eddef5c3e43995f7e79ea85dce665a1f6d888,
        0x7732af1efa94e128ae0ed84437f9ef53f45330b868589b9bf5d3d557b63c7dda,
    ];
    var i = 0;
    while (i < keys.size()) {
        val key = keys.get(i);
        val rootBefore = tree.rootFor(key);
        val proof = tree.insert(key);
        val update = sparseSetApplyUpdate(
            SPARSE_SET_COMMITMENT_DOMAIN,
            key,
            rootBefore,
            proof,
        );
        expect(update.status).toEqual(SparseSetUpdateStatus.Ok);
        expect(update.newRoot).toEqual(tree.rootFor(key));
        if (i < crossRoots.size()) {
            expect(update.newRoot).toEqual(crossRoots.get(i));
        }
        i += 1;
    }

    // All keys use bucket 1; another bucket remains the zero sentinel.
    expect(tree.rootFor(2)).toEqual(0);

    val duplicateKey = keys.get(2);
    val duplicate = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        duplicateKey,
        tree.rootFor(duplicateKey),
        tree.proofFor(duplicateKey),
    );
    expect(duplicate.status).toEqual(SparseSetUpdateStatus.NonEmptyLeafOrInvalidWitness);
    expect(duplicate.newRoot).toEqual(0);
}

get fun `test sparse set rejects unknown domain and key outside scalar field`() {
    val unknownDomain = sparseSetApplyUpdate(0xdeadbeef, 1, 0, emptySparseProof());
    expect(unknownDomain.status).toEqual(SparseSetUpdateStatus.InvalidDomain);

    val lastValid = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        BLS12_381_R - 1,
        0,
        emptySparseProof(),
    );
    expect(lastValid.status).toEqual(SparseSetUpdateStatus.Ok);

    val equalToR = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        BLS12_381_R,
        0,
        emptySparseProof(),
    );
    expect(equalToR.status).toEqual(SparseSetUpdateStatus.InvalidKey);

    val alias = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        BLS12_381_R + 1,
        0,
        emptySparseProof(),
    );
    expect(alias.status).toEqual(SparseSetUpdateStatus.InvalidKey);
    expect(
        sparseSetLeafHash(SPARSE_SET_COMMITMENT_DOMAIN, 1) !=
        sparseSetLeafHash(SPARSE_SET_COMMITMENT_DOMAIN, BLS12_381_R + 1),
    ).toEqual(true);

    val bit255 = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        1 << 255,
        0,
        emptySparseProof(),
    );
    expect(bit255.status).toEqual(SparseSetUpdateStatus.InvalidKey);
}

@test.fuzz(256)
get fun `test fuzz sparse set accepts every canonical scalar on an empty bucket`(rawKey: uint256) {
    val key = fuzz.bound(rawKey, 0, BLS12_381_R - 1);
    val update = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        key,
        0,
        emptySparseProof(),
    );
    expect(update.status).toEqual(SparseSetUpdateStatus.Ok);
    expect(update.bucketId).toEqual(sparseSetBucketId(key));
}

@test.fuzz(256)
get fun `test fuzz sparse set rejects every scalar field alias`(rawKey: uint256) {
    val maxUint256 = ((1 << 255) - 1) | (1 << 255);
    val key = fuzz.bound(rawKey, BLS12_381_R, maxUint256);
    val update = sparseSetApplyUpdate(
        SPARSE_SET_NULLIFIER_DOMAIN,
        key,
        0,
        emptySparseProof(),
    );
    expect(update.status).toEqual(SparseSetUpdateStatus.InvalidKey);
}

get fun `test sparse set rejects stale root before walking witness chain`() {
    // The sibling chain is malformed, but stale-root detection is deliberately
    // first so concurrent callers can regenerate cheaply.
    val malformedChain = beginCell().storeUint(0, 1).endCell();
    val stale = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        1,
        9,
        sparseProofCell(8, 0, malformedChain),
    );
    expect(stale.status).toEqual(SparseSetUpdateStatus.StaleRoot);
}

get fun `test sparse set rejects malformed proof root shapes`() {
    val noRef = beginCell().storeUint(0, 256).storeUint(0, SPARSE_SET_DEPTH).endCell();
    val trailingBit = beginCell()
        .storeUint(0, 256)
        .storeUint(0, SPARSE_SET_DEPTH)
        .storeUint(0, 1)
        .storeRef(createEmptyCell())
        .endCell();
    val exotic = createEmptyCell().toLibraryReference();
    val malformed: array<cell> = [noRef, trailingBit, exotic];

    var i = 0;
    while (i < malformed.size()) {
        val result = sparseSetApplyUpdate(
            SPARSE_SET_COMMITMENT_DOMAIN,
            1,
            0,
            malformed.get(i),
        );
        expect(result.status).toEqual(SparseSetUpdateStatus.MalformedProof);
        i += 1;
    }
}

get fun `test sparse set rejects noncanonical sibling cells`() {
    val explicitZero = sparseProofCell(
        0,
        1,
        beginCell().storeUint(0, 256).endCell(),
    );
    val trailingBit = sparseProofCell(
        0,
        1,
        beginCell().storeUint(3, 256).storeUint(0, 1).endCell(),
    );
    val trailingRef = sparseProofCell(
        0,
        1,
        beginCell().storeUint(3, 256).storeRef(createEmptyCell()).endCell(),
    );
    val tooFew = sparseProofCell(0, 3, beginCell().storeUint(3, 256).endCell());
    val shortIntermediate = sparseProofCell(
        0,
        15,
        beginCell()
            .storeUint(3, 256)
            .storeUint(5, 256)
            .storeRef(beginCell().storeUint(7, 256).storeUint(11, 256).endCell())
            .endCell(),
    );
    val emptyTail = sparseProofCell(
        0,
        15,
        beginCell()
            .storeUint(3, 256)
            .storeUint(5, 256)
            .storeUint(7, 256)
            .storeRef(createEmptyCell())
            .endCell(),
    );
    val exoticSibling = sparseProofCell(
        0,
        1,
        createEmptyCell().toLibraryReference(),
    );
    val malformed: array<cell> = [
        explicitZero,
        trailingBit,
        trailingRef,
        tooFew,
        shortIntermediate,
        emptyTail,
        exoticSibling,
    ];

    var i = 0;
    while (i < malformed.size()) {
        val result = sparseSetApplyUpdate(
            SPARSE_SET_COMMITMENT_DOMAIN,
            1,
            0,
            malformed.get(i),
        );
        expect(result.status).toEqual(SparseSetUpdateStatus.MalformedProof);
        i += 1;
    }
}

get fun `test sparse set accepts a terminal chunk with exactly three siblings`() {
    val key: uint256 = 42;
    val siblings: array<uint256> = [3, 5, 7];
    var oldRoot: uint256 = 0;
    var path = sparseSetPath(key);
    var level = 0;
    while (level < SPARSE_SET_DEPTH) {
        val sibling: uint256 = level < siblings.size() ? siblings.get(level) : 0;
        oldRoot = (path & 1) == 0
            ? sparseSetNodeHash(SPARSE_SET_NULLIFIER_DOMAIN, level as uint8, oldRoot, sibling)
            : sparseSetNodeHash(SPARSE_SET_NULLIFIER_DOMAIN, level as uint8, sibling, oldRoot);
        path >>= 1;
        level += 1;
    }

    val update = sparseSetApplyUpdate(
        SPARSE_SET_NULLIFIER_DOMAIN,
        key,
        oldRoot,
        sparseProofCell(oldRoot, 7, sparseSetPackTestSiblings(siblings)),
    );
    expect(update.status).toEqual(SparseSetUpdateStatus.Ok);
}

get fun `test sparse set rejects an exotic continuation chunk`() {
    val siblingChain = beginCell()
        .storeUint(3, 256)
        .storeUint(5, 256)
        .storeUint(7, 256)
        .storeRef(createEmptyCell().toLibraryReference())
        .endCell();
    val update = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        1,
        0,
        sparseProofCell(0, 15, siblingChain),
    );
    expect(update.status).toEqual(SparseSetUpdateStatus.MalformedProof);
}

get fun `test sparse set rejects a trailing continuation reference`() {
    val siblingChain = beginCell()
        .storeUint(3, 256)
        .storeUint(5, 256)
        .storeUint(7, 256)
        .storeRef(beginCell().storeUint(11, 256).endCell())
        .endCell();
    val update = sparseSetApplyUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        1,
        0,
        sparseProofCell(0, 7, siblingChain),
    );
    expect(update.status).toEqual(SparseSetUpdateStatus.MalformedProof);
}

get fun `test sparse set dense 247-sibling proof has canonical maximum shape`() {
    val key: uint256 = 42;
    val siblings = denseSparseSiblings();
    val siblingChain = sparseSetPackTestSiblings(siblings);
    val bitmap = (1 << SPARSE_SET_DEPTH) - 1;
    val oldRoot = denseSparseOldRoot(SPARSE_SET_NULLIFIER_DOMAIN, key);
    val proof = sparseProofCell(oldRoot, bitmap, siblingChain);
    val (cells, _, _) = proof.calculateSizeStrict(100);
    expect(cells).toEqual(84); // proof root + 83 packed sibling cells

    val update = sparseSetApplyUpdate(
        SPARSE_SET_NULLIFIER_DOMAIN,
        key,
        oldRoot,
        proof,
    );

    expect(update.status).toEqual(SparseSetUpdateStatus.Ok);
    expect(update.newRoot != 0).toEqual(true);
}
