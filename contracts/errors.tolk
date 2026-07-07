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

    // Pool: withdraw
    InsufficientGas = 120
    UnknownRoot = 121
    NullifierAlreadySpent = 122
    InvalidWithdrawProof = 124
    InsufficientReserve = 127
    InsufficientBalance = 128
    InvalidQueryId = 129
    InvalidRecipient = 130
    WithdrawalNotRetryable = 131
    InvalidRetry = 132

    // Factory
    PoolAlreadyExists = 200
    InvalidDenomination = 202
    InsufficientCreatePoolFee = 203
}
