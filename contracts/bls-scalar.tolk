import "constants"

@pure
@inline
fun blsScalarIsCanonical(value: uint256): bool {
    return value < BLS12_381_R;
}
