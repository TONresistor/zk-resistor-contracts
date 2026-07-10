// A recipient's full canonical address is domain-hashed before this mask is
// applied. 248 bits fit safely inside the BLS12-381 Fr field (255 bits).
const ADDRESS_FIELD_MASK: uint256 = (1 << 248) - 1

// Domain for the full-address recipient binding:
// Cell(uint32 domain, int32 workchain, uint256 accountHash).hash().
const RECIPIENT_FIELD_DOMAIN: uint32 = 0x5a4b5201

// BLS12-381 scalar field order `r`. Any uint256 public input passed to the
// verifier MUST be < r: otherwise `x` and `x + r` reduce to the same scalar
// inside Groth16 but to different map keys here, opening a double-spend on
// `nullifierHash` and a duplicate-commitment slip on the deposit side.
const BLS12_381_R: uint256 = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001

// Merkle tree: depth 20, 1_048_576 leaves per pool.
const MERKLE_TREE_DEPTH: int = 20
const MERKLE_TREE_CAPACITY: int = 1 << 20

// Empty-tree root for depth 20 under Poseidon BLS12-381. MUST match what the
// circuit and client compute; otherwise the first deposit's insertion proof
// does not verify against the on-chain root.
const EMPTY_TREE_ROOT: uint256 = 0x276b3bddf0aaccd173fcb1b7d167d34d10680f45f6ed6363ab7ce2096874e0b3

// Historical roots retained so withdrawals stay valid across the window of
// concurrent deposits.
const ROOT_HISTORY_SIZE: int = 100

// Minimum incoming value required to process a withdraw. Covers the hard
// outflow (jetton transfer + compute + event forwarding) with ~0.03 TON
// margin. The handler reserves POOL_TON_RESERVE + earmarks and sends the
// rest back to the broadcaster.
const MIN_WITHDRAW_GAS: coins = 100000000 // 0.10 TON

// Factory base runway: more than twice the measured ten-year storage cost of
// the empty final Factory StateInit (0.362488844 TON at the release config).
const POOL_TON_RESERVE: coins = 50000000 // compatibility floor; deposits use poolRentRunway()
const FACTORY_TON_RESERVE: coins = 370000000 // 0.37 TON

// Each deposit earmarks this amount into the pool's relayerReserve; the
// matching withdraw releases it to the tx sender. The relayer is not bound
// in the proof, so anyone broadcasting a published proof earns it.
const RELAYER_REIMBURSEMENT: coins = 300000000 // 0.30 TON

// A Jetton create funds the TEP-89 query before the authenticated master
// response activates the Pool. Native TON pools do not need that handshake.
const MIN_CREATE_JETTON_POOL_FEE: coins = 450000000 // 0.45 TON
const MIN_CREATE_TON_POOL_FEE: coins = 450000000 // 0.45 TON

// Kept from the current create message only. This funds the 0.02 TON registry
// allocation plus Factory compute/action fees; all other current-message value
// is forwarded explicitly, without sweeping prior donations.
const FACTORY_CREATE_RETAINED_VALUE: coins = 40000000 // 0.04 TON

// Retained by the factory per CreatePool to fund storage rent for the pool's
// index entries (forward, reverse, create-sender). Caps the slow-burn
// registry-bloat griefing surface: a spammer at 0.20 TON / pool funds their
// own rent.
const REGISTRY_RENT_PER_POOL: coins = 20000000 // 0.02 TON

// Minimum TON a deposit must attach beyond the denomination. Splits as
// RELAYER_REIMBURSEMENT (0.30) + worst integrated sparse handler/event gas
// + progressive rent for a new history slot and commitment bucket. Any excess
// is refunded to msg.fromUser.
const MIN_DEPOSIT_VALUE: coins = 370000000 // 0.37 TON

// Shared opcodes used outside their `struct (0x...)` definitions.
const OP_JETTON_TRANSFER: int = 0x0f8a7ea5
const OP_DEPOSIT_PAYLOAD: int = 0xd6e05112

// Whitelisted TON pool denominations. Bounded set so anonymity sets
// concentrate at a few standard sizes.
const TON_POOL_DENOM_10: coins = 10000000000 // 10 TON
const TON_POOL_DENOM_100: coins = 100000000000 // 100 TON
const TON_POOL_DENOM_1K: coins = 1000000000000 // 1 000 TON
const TON_POOL_DENOM_10K: coins = 10000000000000 // 10 000 TON

fun isWhitelistedTonDenom(d: coins): bool {
    return d == TON_POOL_DENOM_10 || d == TON_POOL_DENOM_100 || d == TON_POOL_DENOM_1K ||
    d == TON_POOL_DENOM_10K;
}
