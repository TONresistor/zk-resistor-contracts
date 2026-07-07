// When true, the verifier short-circuits to `return true` and bypasses the
// on-chain pairing. This is a local-only escape hatch; mainnet and CI builds
// MUST keep it false.
const MOCK_VERIFIER: bool = false

// Lower 248 bits of an address hash, used as the field-element binding for
// the recipient in the withdraw circuit. 248 bits fit safely inside the
// BLS12-381 Fr field (255 bits) and match the frontend's encoding.
const ADDRESS_FIELD_MASK: uint256 = (1 << 248) - 1

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

// Storage reserves: minimum balance each contract retains at all times.
const POOL_TON_RESERVE: coins = 50000000 // 0.05 TON
const FACTORY_TON_RESERVE: coins = 100000000 // 0.10 TON

// Each deposit earmarks this amount into the pool's relayerReserve; the
// matching withdraw releases it to the tx sender. The relayer is not bound
// in the proof, so anyone broadcasting a published proof earns it.
const RELAYER_REIMBURSEMENT: coins = 300000000 // 0.30 TON

// Minimum TON value the factory must receive on CreatePool / CreateTonPool.
// Budget: factory rent reserve (REGISTRY_RENT_PER_POOL) + pool deploy +
// InitWalletBinding handler + outbound TEP-89 query + POOL_TON_RESERVE seed
// + safety buffer. CreateTonPool has no TEP-89 step but shares the floor.
const MIN_CREATE_POOL_FEE: coins = 200000000 // 0.20 TON

// Retained by the factory per CreatePool to fund the storage rent of the
// two registry entries it writes (forward + reverse). Sized for ~12 years
// at current TON basechain rent rates. Caps the slow-burn registry-bloat
// griefing surface: a spammer at 0.20 TON / pool funds their own rent.
const REGISTRY_RENT_PER_POOL: coins = 20000000 // 0.02 TON

// Minimum TON a deposit must attach beyond the denomination. Splits as
// RELAYER_REIMBURSEMENT (0.30) + handler gas (~0.02). Any excess is
// refunded to msg.fromUser.
const MIN_DEPOSIT_VALUE: coins = 320000000 // 0.32 TON

// Shared opcodes used outside their `struct (0x...)` definitions.
const OP_JETTON_TRANSFER: int = 0x0f8a7ea5
const OP_DEPOSIT_PAYLOAD: int = 0xd6e05111

// Outgoing withdrawal transfers use the high query-id bit as a domain tag.
// Deposit refunds always clear it. This lets the bounce handler distinguish
// retryable payouts from refunds without trusting user-controlled opcodes.
const JETTON_WITHDRAW_QUERY_DOMAIN: uint64 = 1 << 63
const JETTON_QUERY_ID_MASK: uint64 = (1 << 63) - 1

// Gas budget for outgoing jetton transfers (paid in TON).
const JETTON_TRANSFER_GAS: coins = 50000000 // 0.05 TON

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
