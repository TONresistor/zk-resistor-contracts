import "@stdlib/gas-payments"
import "@acton/build"
import "@acton/io"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/constants"
import "@contracts/pool-types"
import "@contracts/ton-pool-types"

const TON_POOL_TEN_YEARS_SECONDS: int = 10 * 365 * 24 * 60 * 60
const MAX_TON_POOL_STATE_CELLS: int = 16384

fun boundedTonMerkleState(
    historySlots: uint32,
    commitmentBuckets: uint16,
    nullifierBuckets: uint16,
): MerkleState {
    var rootHistory: map<uint32, uint256> = [];
    var commitmentSeenRoots: map<uint8, uint256> = [];
    var nullifierSpentRoots: map<uint8, uint256> = [];

    var slot: uint32 = 0;
    while (slot < historySlots) {
        rootHistory.set(
            slot,
            beginCell().storeUint(0x48535452, 32).storeUint(slot, 32).endCell().hash(),
        );
        slot += 1;
    }
    var bucket: uint16 = 0;
    while (bucket < commitmentBuckets) {
        commitmentSeenRoots.set(
            bucket as uint8,
            beginCell().storeUint(0x434f4d4d, 32).storeUint(bucket, 16).endCell().hash(),
        );
        bucket += 1;
    }
    bucket = 0;
    while (bucket < nullifierBuckets) {
        nullifierSpentRoots.set(
            bucket as uint8,
            beginCell().storeUint(0x4e554c4c, 32).storeUint(bucket, 16).endCell().hash(),
        );
        bucket += 1;
    }

    val isFull = historySlots == ROOT_HISTORY_SIZE as uint32 && commitmentBuckets == 256 &&
    nullifierBuckets == 256;
    return {
        nextIndex: isFull ? MERKLE_TREE_CAPACITY : historySlots,
        currentRoot: historySlots == 0
            ? EMPTY_TREE_ROOT
            : rootHistory
                .get(
                    isFull ? (MERKLE_TREE_CAPACITY - 1) % ROOT_HISTORY_SIZE : historySlots - 1,
                )
                .loadValue(),
        rootHistory,
        sparseSets: (SparseSetRoots {
            commitmentBucketCount: commitmentBuckets,
            nullifierBucketCount: nullifierBuckets,
            commitmentSeenRoots,
            nullifierSpentRoots,
        }).toCell(),
    };
}

fun boundedTonPoolStorage(merkle: MerkleState): TonPoolStorage {
    val identity: TonPoolIdentity = {
        factory: testing.treasury("ton-bounds-factory").address,
        denomination: TON_POOL_DENOM_10,
    };
    return {
        identity: identity.toCell(),
        relayerReserve: 0,
        pendingWithdrawTon: 0,
        merkle: merkle.toCell(),
    };
}

fun tonPoolStateInit(merkle: MerkleState): cell {
    return (ContractState {
        code: build("TonPool"),
        data: boundedTonPoolStorage(merkle).toCell(),
    }).toCell();
}

fun assertTonPoolRunwayCoverage(
    historySlots: uint32,
    commitmentBuckets: uint16,
    nullifierBuckets: uint16,
) {
    val merkle = boundedTonMerkleState(historySlots, commitmentBuckets, nullifierBuckets);
    val state = tonPoolStateInit(merkle);
    val (cells, bits, _) = state.calculateSizeStrict(MAX_TON_POOL_STATE_CELLS);
    val tenYearFee = calculateStorageFee(
        BASECHAIN,
        TON_POOL_TEN_YEARS_SECONDS,
        bits,
        cells,
    );
    val runway = merkle.poolRentRunway();
    println(
        "TonPool history={} commitmentBuckets={} nullifierBuckets={}",
        historySlots,
        commitmentBuckets,
        nullifierBuckets,
    );
    println(
        "TonPool cells={} bits={} fee={} runway={}",
        cells,
        bits,
        tenYearFee,
        runway,
    );
    expect(runway >= tenYearFee * 2).toEqual(true);
}

get fun `test full TonPool state stays below cell gate and has double ten-year runway`() {
    val merkle = boundedTonMerkleState(ROOT_HISTORY_SIZE as uint32, 256, 256);
    val state = tonPoolStateInit(merkle);
    val (cells, bits, refs) = state.calculateSizeStrict(MAX_TON_POOL_STATE_CELLS);
    val tenYearFee = calculateStorageFee(
        BASECHAIN,
        TON_POOL_TEN_YEARS_SECONDS,
        bits,
        cells,
    );
    println(
        "full TonPool StateInit cells={} bits={} refs={}",
        cells,
        bits,
        refs,
    );
    println(
        "full TonPool ten-year-fee={} runway={}",
        tenYearFee,
        merkle.poolRentRunway(),
    );
    expect(cells < MAX_TON_POOL_STATE_CELLS).toEqual(true);
    expect(merkle.poolRentRunway() >= tenYearFee * 2).toEqual(true);
}

get fun `test TonPool progressive runway covers measured storage milestones`() {
    assertTonPoolRunwayCoverage(0, 0, 0);
    assertTonPoolRunwayCoverage(1, 1, 0);
    assertTonPoolRunwayCoverage(32, 32, 32);
    assertTonPoolRunwayCoverage(64, 128, 128);
    assertTonPoolRunwayCoverage(ROOT_HISTORY_SIZE as uint32, 256, 256);
}
