import "constants"
import "errors"

// Bind the complete canonical TON address to the existing 248-bit Groth16
// public input. Hashing before truncation removes the trivial high-byte aliases
// created by masking the raw 256-bit account hash directly.
fun recipientToField(recipient: address): uint256 {
    val (workchain, accountHash) = recipient.getWorkchainAndHash();
    assert (workchain == 0) throw Errors.InvalidRecipient;
    assert (accountHash != 0) throw Errors.InvalidRecipient;

    val bindingHash = beginCell()
        .storeUint(RECIPIENT_FIELD_DOMAIN, 32)
        .storeInt(workchain, 32)
        .storeUint(accountHash, 256)
        .endCell()
        .hash();
    val recipientField = bindingHash & ADDRESS_FIELD_MASK;

    // The existing withdrawal circuit rejects a zero recipient public input.
    assert (recipientField != 0) throw Errors.InvalidRecipient;
    return recipientField;
}
