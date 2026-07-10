# ZKResistor Protocol

This document specifies the public behavior and invariants of the final
ZKResistor contracts. The Tolk source is authoritative if this document and the
code ever disagree.

## 1. Protocol Model

ZKResistor provides immutable, fixed-denomination privacy pools on TON. A user
deposits an asset with a secret commitment and later proves ownership of one
unspent commitment without revealing which deposit is being withdrawn.

The protocol has three contracts:

- `Factory`: permissionlessly deploys and indexes Pools.
- `Pool`: holds one TEP-74 Jetton at one denomination.
- `TonPool`: holds native TON at one whitelisted denomination.

Contracts have no administrator, upgrade path, user or relayer allowlist,
oracle, or off-chain authority. Jetton Pools are permissionless; official
clients may independently decide which assets they display. Native TON Pools
use the four protocol denominations listed below.

## 2. Cryptographic Statement

For random 248-bit values `nullifier` and `secret`:

```text
commitment    = Poseidon(nullifier, secret)
nullifierHash = Poseidon(nullifier, 0)
recipientField = low248(Cell(0x5a4b5201, int32(workchain), uint256(addressHash)).hash())
```

Each Pool maintains a depth-20 Poseidon Merkle tree with exactly `2^20`, or
`1,048,576`, deposit slots. It therefore supports at most `1,048,576`
successful deposits and one successful withdrawal per deposited note; withdrawals
do not have a separate capacity.

The insertion proof has four public inputs:

```text
(oldRoot, newRoot, commitment, leafIndex)
```

The withdrawal proof has three public inputs:

```text
(root, nullifierHash, recipientField)
```

The insertion proof proves that the supplied commitment is appended at the next
empty leaf. The withdrawal proof proves its Merkle membership and the
`Poseidon(nullifier, secret)` relation.

Groth16 proofs use BLS12-381 and are verified on-chain. All public field values
must be canonical scalars. Proof cells must contain ordinary, exact-size G1/G2
points with no trailing data; identity and out-of-subgroup points are rejected.
The recipient must be a non-zero workchain-0 address. The contract derives the
field from the complete canonical address before proof verification. Changing
any workchain or account-hash bit therefore changes the proof input; finding an
alternative address with the same field requires a second preimage of the
domain-separated 248-bit binding hash.

Pools retain a circular history of 100 roots in total, including the current
root. After saturation, this is the current root and 99 previous roots. A
withdrawal proof must target one of them. Users can generate a fresh proof
against a newer root while their note and the corresponding public tree data
remain available.

## 3. Bounded Uniqueness State

Commitments and spent nullifiers are tracked by two domain-separated sparse
sets. This avoids one permanent dictionary entry per note.

- The low 8 key bits select one of 256 on-chain buckets.
- The remaining 247 bits form the path inside that bucket.
- Commitment and nullifier domains are `0x5a4b4301` and `0x5a4b4e01`.
- The contract stores only the current root of each materialized bucket.
- The client supplies an empty-leaf update witness containing the expected root,
  a 247-bit sibling bitmap, and the non-zero siblings.
- The contract verifies the witness against its stored root and computes the new
  root itself.

Off-chain state providers improve availability and performance but are not
trusted. A provider cannot forge a deposit, reuse a commitment, spend a
nullifier twice, or choose a new sparse root without a valid witness.

Events publish each accepted bucket update so independent clients can rebuild
and verify the same state.

## 4. Pool Creation And Activation

Anyone may create:

- a Jetton Pool for any positive `(jettonMaster, denomination)` pair;
- a TonPool for `10`, `100`, `1,000`, or `10,000` TON.

The Factory permits at most 4,096 registered Pools and 128 concurrent,
unconfirmed creations.

Creation follows this sequence:

1. Factory derives the deterministic Pool address and records the request.
2. Factory forwards only value from the current create message.
3. TonPool confirms deployment directly.
4. Pool queries its immutable Jetton master through TEP-89.
5. Only the master may bind the Pool's Jetton wallet.
6. The activated Pool confirms its identity back to Factory.
7. Factory authenticates the sender and removes transient creation state.

`FactoryPoolCreatedEvent` records an accepted request, not final activation.
Clients must use the registry and pending getters as canonical state. An
authenticated deployment bounce removes the failed registry entry and returns
the remaining create-message value to its sender.

## 5. Deposits

### Jetton Pool

1. The client generates a note and insertion proof for `nextIndex`.
2. The client generates a commitment sparse-set non-membership witness.
3. The user transfers exactly one denomination to the Pool address through
   TEP-74 and forwards at least `0.37 TON` with `DepositPayload`.
4. Pool accepts notifications only from its authenticated wallet.
5. Pool validates the payload shape, current root, tree capacity, sparse
   witness, Groth16 proof, rent runway, and relayer reserve.
6. Pool commits the new roots and emits `DepositEvent`.

### TonPool

The same checks apply, but the message carries native TON directly. Its minimum
value is:

```text
denomination + 0.37 TON
```

For either Pool type, an accepted deposit:

- inserts at `leafIndex = nextIndex` and increments `nextIndex` once;
- reserves `0.30 TON` for the future withdrawal broadcaster;
- records the commitment sparse update;
- never accepts the same commitment twice.

The user must persist the private note `(pool, denomination, leafIndex,
nullifier, secret)`. Merkle paths and sparse witnesses can be rebuilt from public
events or obtained from any synchronized provider and checked against on-chain
state. Losing the private note loses the funds.

A rejected TonPool deposit directly returns the remaining native value to
`fromUser`. A Jetton Pool instead issues one non-bouncing, self-funded
TEP-74 refund request through its bound wallet; final execution depends on that
wallet. Neither path uses historical Pool TON reserves. Forged Jetton
notifications and notifications received before wallet binding are ignored
because no safe refund identity exists.

## 6. Withdrawals

Anyone may broadcast a valid withdrawal proof. The proof binds the recipient,
not the broadcaster. Query IDs are opaque correlation fields only; they provide
neither authorization, idempotency, nor replay protection. The spent nullifier
is the withdrawal replay guard.

The Pool verifies:

1. the message and proof cell shapes;
2. a current or recent Merkle root;
3. a canonical, valid Groth16 proof;
4. a nullifier sparse-set non-membership witness;
5. sufficient pre-message balance and accounting reserves;
6. that an accepted deposit remains available for this withdrawal.

On acceptance, the Pool atomically commits its local state transition:

- marks the nullifier spent;
- updates the sparse root;
- releases one `0.30 TON` broadcaster reserve;
- records one withdrawal;
- emits the withdrawal event.

Jetton Pool requires `withdrawalCount < nextIndex` and issues one non-bouncing
TEP-74 transfer request through its bound wallet. Recipient credit occurs in the
wallet's separate transaction and is not atomic with the Pool transaction.
TonPool schedules a direct native payout and maintains
`pendingWithdrawTon = denomination * (deposits - withdrawals)`.

The broadcaster can receive up to the released `0.30 TON` earmark plus unused
attached value, net of transaction and action costs and any new sparse-state
rent allocation. Front-running a published proof can redirect this reward, but
cannot change the recipient or steal the asset payout.

Withdrawals are one-shot. There is no recovery ticket, retry command, second
payout API, or off-chain decision maker. Failure of mandatory actions in the
Pool transaction rolls back its local state transition. Once that transaction
succeeds, a downstream Jetton-wallet failure cannot restore the nullifier or
create a retry. Users must choose a valid recipient, and Jetton Pool guarantees
rely on the selected master and wallet conforming to TEP-74 and TEP-89.

## 7. Accounting

| Operation                                        |       Minimum attached value |     |
| ------------------------------------------------ | ---------------------------: | --- |
| Create Jetton Pool                               |                   `0.45 TON` |     |
| Create TonPool                                   |                   `0.45 TON` |     |
| Jetton wallet-binding trigger while unbound      |                   `0.06 TON` |     |
| Jetton trigger once bound / TonPool confirmation |                   `0.02 TON` |     |
| Jetton deposit forwarding                        |                   `0.37 TON` |     |
| SDK Jetton deposit outer attachment              |                   `0.65 TON` |     |
| TON deposit overhead                             | `0.37 TON` plus denomination |     |
| Jetton withdrawal                                |                   `0.25 TON` |     |
| TON withdrawal                                   |                   `0.10 TON` |     |

For a Jetton deposit, `0.37 TON` is the amount forwarded to the Pool. The SDK
attaches `0.65 TON` to the user's Jetton Wallet so the transfer can cross both
Jetton Wallet hops. The unused part of that outer headroom is returned to the
user through the standard TEP-74 excess path; it is not a `0.65 TON` protocol
fee.

Factory reserves `0.37 TON` plus `0.02 TON` per registered Pool and retains
`0.04 TON` from each create message for the new registry entry and actions. It
forwards all other value from that message (`0.41 TON` at the minimum fee).
Historical Factory funds never subsidize a new creator.

Pool rent runway is progressive:

```text
0.27 TON
+ 0.0026 TON * min(nextIndex, 100)
+ 0.0026 TON * (commitmentBucketCount + nullifierBucketCount)
```

Deposit admission excludes only refundable excess; the required asset amount
and TON overhead fund the new payout, rent, and relayer obligations. Withdrawal
solvency excludes the caller's entire attached value, so caller-funded gas
cannot satisfy an existing obligation. One user therefore cannot consume
another note's pending payout or relayer reserve.

## 8. Wire Surface

### Inbound messages

| Contract | Opcode       | Message                                                             |
| -------- | ------------ | ------------------------------------------------------------------- |
| Factory  | `0xa0c0c0c0` | `CreatePool`                                                        |
| Factory  | `0xa0c0c0c2` | `CreateTonPool`                                                     |
| Pool     | `0xa0c0c0c1` | `InitWalletBinding`                                                 |
| Pool     | `0x7362d09c` | `JettonTransferNotification` carrying `0xd6e05112` `DepositPayload` |
| TonPool  | `0xd6e05112` | `TonDepositPayload`                                                 |
| Pool     | `0x4b6f0b51` | `Withdraw`                                                          |
| TonPool  | `0x4b6f0b51` | `TonWithdraw`                                                       |

### Protocol messages and events

| Opcode       | Name                               |
| ------------ | ---------------------------------- |
| `0x46504300` | `ConfirmPoolDeployment`            |
| `0x46504301` | `PoolDeployConfirmed`              |
| `0x2c76b973` | `ProvideWalletAddress`             |
| `0xd1735400` | `TakeWalletAddress`                |
| `0x0f8a7ea5` | `JettonTransfer`                   |
| `0x00c0c0c0` | `FactoryPoolCreatedEvent`          |
| `0x00def002` | `PoolReadyEvent`                   |
| `0x00de9052` | `DepositEvent` / `TonDepositEvent` |
| `0x00717d3b` | `TonWithdrawEvent`                 |
| `0x00717d3c` | `WithdrawalAcceptedEvent`          |

All ZKResistor-defined event opcodes are encoded on 32 bits.

These tables are an index, not a replacement for the binary schema. Exact
message and event layouts are defined in `contracts/factory-types.tolk`,
`contracts/deployment-types.tolk`, `contracts/pool-types.tolk`, and
`contracts/ton-pool-types.tolk`; getter signatures are defined by the contract
sources and generated wrappers.

### Canonical getters

Factory exposes registry addresses and counts, deterministic expected addresses,
pending deployment state, capacity limits, and transient creator state.

Pool exposes immutable identity, bound wallet, denomination, Merkle root/index,
relayer reserve, rent runway, sparse roots, withdrawal count, tree depth, and
proof preview getters.

TonPool exposes immutable identity, denomination, Merkle root/index, sparse
roots, rent runway, relayer reserve, pending withdrawal TON, withdrawal count,
and tree depth.

## 9. Trust And Failure Model

- Privacy depends on the Groth16 statement, note secrecy, and the anonymity set.
- The protocol hides the deposit-withdrawal link computationally; public
  transaction metadata, Pools, denominations, commitments, nullifier hashes,
  and recipients remain observable.
- Soundness depends on the embedded verifying keys and the trusted-setup
  assumption that at least one ceremony participant destroyed their secret.
- ZK authorization and Pool accounting depend only on on-chain validation;
  Jetton custody and final settlement also depend on the selected master and
  wallet implementation.
- Off-chain providers are replaceable and cannot authorize state.
- Losing the note loses withdrawal capability.
- A stale provider may delay a user until it resynchronizes, but cannot create a
  valid false state transition.
- Jetton custody failures are local to Pools for that asset. Activation liveness
  is global: pending creations have no timeout or cancellation path, and 128
  unresolved activations exhaust the Factory's in-flight cap and block further
  Jetton and TON Pool creation.
- Contract immutability means protocol changes require new deployments.
