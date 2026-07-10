import "@stdlib/gas-payments"
import "@acton/build"
import "@acton/io"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/pool-types"

const TEN_YEARS_SECONDS: int = 10 * 365 * 24 * 60 * 60
const MAX_POOL_STATE_CELLS: int = 16384

fun fullBoundedMerkleState(): MerkleState {
    var rootHistory: map<uint32, uint256> = [];
    var commitmentSeenRoots: map<uint8, uint256> = [];
    var nullifierSpentRoots: map<uint8, uint256> = [];

    var historySlot: uint32 = 0;
    while (historySlot < ROOT_HISTORY_SIZE) {
        rootHistory.set(
            historySlot,
            beginCell().storeUint(0x48535452, 32).storeUint(historySlot, 32).endCell().hash(),
        );
        historySlot += 1;
    }
    var bucket: uint16 = 0;
    while (bucket < 256) {
        commitmentSeenRoots.set(
            bucket as uint8,
            beginCell().storeUint(0x434f4d4d, 32).storeUint(bucket, 16).endCell().hash(),
        );
        nullifierSpentRoots.set(
            bucket as uint8,
            beginCell().storeUint(0x4e554c4c, 32).storeUint(bucket, 16).endCell().hash(),
        );
        bucket += 1;
    }

    return {
        nextIndex: MERKLE_TREE_CAPACITY,
        currentRoot: rootHistory.get((MERKLE_TREE_CAPACITY - 1) % ROOT_HISTORY_SIZE).loadValue(),
        rootHistory,
        sparseSets: (SparseSetRoots {
            commitmentBucketCount: 256,
            nullifierBucketCount: 256,
            commitmentSeenRoots,
            nullifierSpentRoots,
        }).toCell(),
    };
}

fun boundedPoolStorage(merkle: MerkleState, withdrawalCount: uint32): Storage {
    val identity: PoolIdentity = {
        jettonMaster: testing.treasury("bounds-master").address,
        factory: testing.treasury("bounds-factory").address,
        denomination: 1,
    };
    return {
        identity: identity.toCell(),
        jettonWallet: testing.treasury("bounds-wallet").address,
        relayerReserve: 0,
        merkle: merkle.toCell(),
        withdrawalCount,
    };
}

fun emptyBoundedMerkleState(): MerkleState {
    return {
        nextIndex: 0,
        currentRoot: EMPTY_TREE_ROOT,
        rootHistory: [],
        sparseSets: (SparseSetRoots {
            commitmentBucketCount: 0,
            nullifierBucketCount: 0,
            commitmentSeenRoots: [],
            nullifierSpentRoots: [],
        }).toCell(),
    };
}

fun historyBoundedMerkleState(): MerkleState {
    var state = emptyBoundedMerkleState();
    var slot: uint32 = 0;
    while (slot < ROOT_HISTORY_SIZE) {
        state
            .rootHistory
            .set(
                slot,
                beginCell().storeUint(0x48535452, 32).storeUint(slot, 32).endCell().hash(),
            );
        slot += 1;
    }
    state.nextIndex = ROOT_HISTORY_SIZE as uint32;
    state.currentRoot = state.rootHistory.get(ROOT_HISTORY_SIZE - 1).loadValue();
    return state;
}

fun stateInitForPoolStorage(storage: Storage): cell {
    return (ContractState {
        code: build("Pool"),
        data: storage.toCell(),
    }).toCell();
}

fun tenYearPoolStorageFee(merkle: MerkleState): coins {
    val state = stateInitForPoolStorage(boundedPoolStorage(merkle, merkle.nextIndex));
    val (cells, bits, _) = state.calculateSizeStrict(MAX_POOL_STATE_CELLS);
    return calculateStorageFee(BASECHAIN, TEN_YEARS_SECONDS, bits, cells);
}

get fun `test full Pool state with 512 sparse roots stays below cell gate`() {
    val state = stateInitForPoolStorage(
        boundedPoolStorage(fullBoundedMerkleState(), MERKLE_TREE_CAPACITY),
    );
    val (cells, bits, refs) = state.calculateSizeStrict(MAX_POOL_STATE_CELLS);
    println("full Pool StateInit cells={} bits={} refs={}", cells, bits, refs);
    expect(cells < MAX_POOL_STATE_CELLS).toEqual(true);
    expect(bits > 0).toEqual(true);

    val tenYearFee = calculateStorageFee(BASECHAIN, TEN_YEARS_SECONDS, bits, cells);
    println("full Pool ten-year storage fee={} nanotons", tenYearFee);
    expect(tenYearFee > 0).toEqual(true);
}

get fun `test Pool rent components are measured for progressive allocation`() {
    val empty = stateInitForPoolStorage(boundedPoolStorage(emptyBoundedMerkleState(), 0));
    val history = stateInitForPoolStorage(
        boundedPoolStorage(historyBoundedMerkleState(), 0),
    );
    val full = stateInitForPoolStorage(
        boundedPoolStorage(fullBoundedMerkleState(), MERKLE_TREE_CAPACITY),
    );
    val (emptyCells, emptyBits, _) = empty.calculateSizeStrict(MAX_POOL_STATE_CELLS);
    val (historyCells, historyBits, _) = history.calculateSizeStrict(MAX_POOL_STATE_CELLS);
    val (fullCells, fullBits, _) = full.calculateSizeStrict(MAX_POOL_STATE_CELLS);
    val emptyFee = calculateStorageFee(BASECHAIN, TEN_YEARS_SECONDS, emptyBits, emptyCells);
    val historyFee = calculateStorageFee(
        BASECHAIN,
        TEN_YEARS_SECONDS,
        historyBits,
        historyCells,
    );
    val fullFee = calculateStorageFee(BASECHAIN, TEN_YEARS_SECONDS, fullBits, fullCells);
    println("Pool empty cells={} bits={} fee={}", emptyCells, emptyBits, emptyFee);
    println("Pool history cells={} bits={} fee={}", historyCells, historyBits, historyFee);
    println("Pool full cells={} bits={} fee={}", fullCells, fullBits, fullFee);
    expect(emptyFee < historyFee && historyFee < fullFee).toEqual(true);
}

get fun `test Pool progressive runway covers every history and sparse prefix`() {
    var historyState = emptyBoundedMerkleState();
    expect(historyState.poolRentRunway() >= tenYearPoolStorageFee(historyState) * 2).toEqual(true);
    var historyCount: uint32 = 0;
    while (historyCount < ROOT_HISTORY_SIZE) {
        val historyRoot = beginCell()
            .storeUint(0x48535452, 32)
            .storeUint(historyCount, 32)
            .endCell()
            .hash();
        historyState.rootHistory.set(historyCount, historyRoot);
        historyState.nextIndex += 1;
        historyState.currentRoot = historyRoot;
        historyCount += 1;
        expect(
            historyState.poolRentRunway() >= tenYearPoolStorageFee(historyState) * 2,
        ).toEqual(true);
    }

    var commitmentRoots: map<uint8, uint256> = [];
    var nullifierRoots: map<uint8, uint256> = [];
    var sparseCount: uint16 = 0;
    while (sparseCount <= 256) {
        val sparseState: MerkleState = {
            nextIndex: 0,
            currentRoot: EMPTY_TREE_ROOT,
            rootHistory: [],
            sparseSets: (SparseSetRoots {
                commitmentBucketCount: sparseCount,
                nullifierBucketCount: sparseCount,
                commitmentSeenRoots: commitmentRoots,
                nullifierSpentRoots: nullifierRoots,
            }).toCell(),
        };
        expect(
            sparseState.poolRentRunway() >= tenYearPoolStorageFee(sparseState) * 2,
        ).toEqual(true);
        if (sparseCount < 256) {
            // Multiplication by an odd number gives a permutation of uint8 and
            // exercises non-prefix trie shapes while every root remains unique.
            val bucket = ((sparseCount * 73) % 256) as uint8;
            commitmentRoots.set(
                bucket,
                beginCell().storeUint(0x434f4d4d, 32).storeUint(bucket, 8).endCell().hash(),
            );
            nullifierRoots.set(
                bucket,
                beginCell().storeUint(0x4e554c4c, 32).storeUint(bucket, 8).endCell().hash(),
            );
        }
        sparseCount += 1;
    }
}
