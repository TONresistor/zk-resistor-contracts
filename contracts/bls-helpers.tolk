// Thin asm wrappers for the BLS12-381 TVM opcodes.
//
// All four primitives are native TVM instructions (see `acton doc tvm BLS_*`).
// We expose them as pure Tolk functions so the verifier code stays readable.
//
// BLS12-381 point encodings follow the BLST compressed format:
//   - G1 points: 48 bytes (384 bits)
//   - G2 points: 96 bytes (768 bits)

/// # Safety
/// `x` and `y` must be valid BLS12-381 G1 points in BLST compressed
/// encoding (48 bytes / 384 bits each). Callers MUST length-check inputs
/// to exactly 384 bits and validate subgroup membership + non-identity
/// before calling, as TVM silently truncates over-length inputs and
/// throws `cell_underflow` on under-length — both are soundness defects
/// without the caller-side gate.
@pure
fun blsG1Add(x: slice, y: slice): slice
    asm "BLS_G1_ADD"

/// # Safety
/// `x` must be a valid G1 point (see blsG1Add). `scalar` is any 256-bit
/// integer; the TVM handles modular reduction internally.
@pure
fun blsG1Mul(x: slice, scalar: int): slice
    asm "BLS_G1_MUL"

/// # Safety
/// `x` must be a valid G1 point (see blsG1Add).
@pure
fun blsG1Neg(x: slice): slice
    asm "BLS_G1_NEG"

// Subgroup check. TVM's BLS opcodes validate that a point lies on the
// curve but do NOT verify it belongs to the prime-order subgroup; without
// this check, a prover can craft pairings using small-order torsion points.
/// # Safety
/// Returns true iff `x` is on the curve AND in the prime-order subgroup.
@pure
fun blsG1InGroup(x: slice): bool
    asm "BLS_G1_INGROUP"

/// # Safety
/// Returns true iff `x` is on the curve AND in the prime-order subgroup G2.
@pure
fun blsG2InGroup(x: slice): bool
    asm "BLS_G2_INGROUP"

// Identity check. e(0_G1, anything) = 1_GT collapses the pairing, which is
// a known forgery vector — a zero point is trivially in the subgroup, so
// INGROUP alone is insufficient.
/// # Safety
/// Returns true iff `x` encodes the identity element of G1.
@pure
fun blsG1IsZero(x: slice): bool
    asm "BLS_G1_ISZERO"

/// # Safety
/// Returns true iff `x` encodes the identity element of G2.
@pure
fun blsG2IsZero(x: slice): bool
    asm "BLS_G2_ISZERO"

// Multi-pairing check. Returns true iff the product of pairings equals 1
// in F_p12. For Groth16, n = 4:
//   e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
/// # Safety
/// All eight slices must be valid points in alternating G1/G2 groups.
@pure
fun blsPairingCheck4(
    a1: slice,
    a2: slice,
    b1: slice,
    b2: slice,
    c1: slice,
    c2: slice,
    d1: slice,
    d2: slice,
): bool
    asm "4 PUSHINT BLS_PAIRING"
