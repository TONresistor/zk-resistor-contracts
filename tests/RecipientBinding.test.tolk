import "@acton/testing/expect"
import "@contracts/recipient-binding"

const RECIPIENT_HASH_LOW_248: uint256 = 0x3d9f82a7a533c9d6cbbe3ba4c753902f72e6a9e615fad277a95330fe635882
const RECIPIENT_BINDING_FIELD: uint256 = 0xde87c6054755808089480d2d56e766528528068d671b9bed954900a1225b02

get fun `test recipient binding matches canonical SDK vector`() {
    val recipient = address.fromWorkchainAndHash(
        0,
        RECIPIENT_HASH_LOW_248 + (0x7c << 248),
    );

    expect(recipientToField(recipient)).toEqual(RECIPIENT_BINDING_FIELD);
}

get fun `test every high-byte alias differs from the fixture binding`() {
    var highByte = 0;
    while (highByte < 256) {
        val recipient = address.fromWorkchainAndHash(
            0,
            RECIPIENT_HASH_LOW_248 + (highByte << 248),
        );
        val field = recipientToField(recipient);

        if (highByte == 0x7c) {
            expect(field).toEqual(RECIPIENT_BINDING_FIELD);
        } else {
            expect(field != RECIPIENT_BINDING_FIELD).toEqual(true);
        }
        highByte += 1;
    }
}
