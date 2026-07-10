// Numeric codes are stable across versions: external indexers and the SDK
// key off these numbers. Gaps in the sequence are intentional. New errors
// take the next free slot in their subsystem.
enum Errors {
    // Generic
    InvalidMessage = 0xFFFF

    // Pool: deploy / init
    JettonWalletAlreadySet = 103
    JettonWalletNotSet = 104
    NotJettonMaster = 105

    // Pool: deposit
    InvalidAmount = 111
    CommitmentAlreadyExists = 113
    TreeFull = 114
    InvalidInsertProof = 115
    InsufficientDepositValue = 116
    InvalidDepositPayload = 117

    // Pool: withdraw
    InsufficientGas = 120
    UnknownRoot = 121
    NullifierAlreadySpent = 122
    InvalidWithdrawProof = 124
    InsufficientReserve = 127
    InsufficientBalance = 128
    InvalidRecipient = 130
    StaleSparseSetRoot = 133
    InvalidSparseSetProof = 134
    WithdrawalCapacityReached = 135

    // Factory
    PoolAlreadyExists = 200
    InvalidDenomination = 202
    InsufficientCreatePoolFee = 203
    FactoryCapacityReached = 204
    TooManyInFlightCreates = 205
    InvalidPoolConfirmation = 206
    FactoryInvariantViolation = 207
}
