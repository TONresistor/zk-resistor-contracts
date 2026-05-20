// Client-side Merkle tree builder + path generator for the insert/withdraw
// circuits. Depth 20, Poseidon BLS12-381 hash.

import { poseidon2 } from "./poseidon-bls.js";

export const TREE_DEPTH = parseInt(process.env.TREE_DEPTH ?? "20", 10);

let zerosCache = null;

export async function zeros() {
    if (zerosCache) return zerosCache;
    const z = [0n];
    for (let i = 1; i <= TREE_DEPTH; i++) {
        z.push(BigInt(await poseidon2(z[i - 1], z[i - 1])));
    }
    return (zerosCache = z);
}

// Build a sparse tree from a list of inserted leaves.
// Returns root + helper to fetch (path, indices) for any leaf index.
export async function buildTree(leaves) {
    const z = await zeros();
    const layers = Array.from({ length: TREE_DEPTH + 1 }, () => new Map());
    leaves.forEach((leaf, i) => layers[0].set(i, BigInt(leaf)));

    for (let level = 0; level < TREE_DEPTH; level++) {
        const layer = layers[level];
        const next = layers[level + 1];
        const parents = new Set();
        for (const idx of layer.keys()) parents.add(idx >> 1);
        for (const parent of parents) {
            const li = parent * 2;
            const ri = parent * 2 + 1;
            const left = layer.get(li) ?? z[level];
            const right = layer.get(ri) ?? z[level];
            next.set(parent, BigInt(await poseidon2(left, right)));
        }
    }

    function getNode(level, idx) {
        return layers[level].get(idx) ?? z[level];
    }

    return {
        root: getNode(TREE_DEPTH, 0),
        zeros: z,

        // Path under leafIndex (LSB-first bits)
        pathFor(leafIndex) {
            const pathElements = [];
            const pathIndices = [];
            let idx = leafIndex;
            for (let level = 0; level < TREE_DEPTH; level++) {
                const sibling = idx ^ 1;
                pathElements.push(getNode(level, sibling));
                pathIndices.push(idx & 1);
                idx >>= 1;
            }
            return { pathElements, pathIndices };
        },
    };
}

// Produce the witness for `insert.circom` given an oldTree and a new commitment.
export async function insertWitness(oldLeaves, commitment, leafIndex) {
    const oldTree = await buildTree(oldLeaves);
    const path = oldTree.pathFor(leafIndex);

    // Simulate insertion and compute newRoot.
    const newLeaves = [...oldLeaves];
    newLeaves[leafIndex] = BigInt(commitment);
    const newTree = await buildTree(newLeaves);

    return {
        oldRoot: oldTree.root.toString(),
        newRoot: newTree.root.toString(),
        commitment: BigInt(commitment).toString(),
        leafIndex: BigInt(leafIndex).toString(),
        pathElements: path.pathElements.map((x) => x.toString()),
        zeros: oldTree.zeros.slice(0, TREE_DEPTH).map((x) => x.toString()),
    };
}

// Produce the witness for `withdraw.circom` (recipient-only binding).
// Note: in withdraw, the leaf IS the commitment (already in the tree).
export async function withdrawWitness({
    leaves,
    leafIndex,
    nullifier,
    secret,
    recipient,
}) {
    const commitment = BigInt(await poseidon2(BigInt(nullifier), BigInt(secret)));
    const nullifierHash = BigInt(await poseidon2(BigInt(nullifier), 0n));

    // Inject this commitment at leafIndex if not already there.
    const fullLeaves = [...leaves];
    fullLeaves[leafIndex] = commitment;
    const tree = await buildTree(fullLeaves);
    const path = tree.pathFor(leafIndex);

    return {
        // Public
        root: tree.root.toString(),
        nullifierHash: nullifierHash.toString(),
        recipient: BigInt(recipient).toString(),
        // Private
        nullifier: BigInt(nullifier).toString(),
        secret: BigInt(secret).toString(),
        pathElements: path.pathElements.map((x) => x.toString()),
        pathIndices: path.pathIndices.map((x) => x.toString()),
    };
}
