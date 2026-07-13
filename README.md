# zkresistor-contracts-tolk

**Permissionless ZK privacy pools on TON.** Anyone can deploy a fixed-denomination mixer for any TEP-74 jetton, or for native TON at four standard denominations. Withdrawals settle via Groth16 proofs verified on-chain through TVM's BLS12-381 pairing precompile.

## Overview

Deposit `N` units of an asset into a pool with a commitment `c = Poseidon(nullifier, secret)`. Save the note `(asset, denomination, leafIndex, nullifier, secret)` locally. Later, anyone produces a Groth16 proof of knowledge of `(nullifier, secret)` and a recipient address. The pool verifies the proof, marks the nullifier spent, and pays the recipient the full denomination. The proof reveals nothing about which deposit is spent.

Each pool has exactly 1,048,576 deposit slots at Merkle depth 20. The final
contracts keep this capacity effective on-chain: duplicate commitments and
spent nullifiers use two bounded 256-bucket transparent sparse sets instead of
one dictionary entry per note. All pools are immutable after deploy.

## Contracts

Three Tolk contracts under `contracts/`. Tables list the messages an external
caller sends; the binding plumbing (TEP-89) and outbound TEP-74 messages are
handled internally.

### `Factory`

One deployment per network. Spawns pools on demand; both operations are permissionless. TON denominations are fixed at 10 / 100 / 1000 / 10000 so anonymity sets concentrate at standard sizes.

| Opcode | Message | Required value |
|---|---|---|
| `0xa0c0c0c0` | CreatePool | 0.45 TON |
| `0xa0c0c0c2` | CreateTonPool | 0.45 TON |

`FactoryPoolCreatedEvent` (`0x00c0c0c0`) indexes accepted create requests; it is
not an activation receipt. A later deploy bounce remains in history but releases
the pending slot. The address getters return accepted active or pending Pools;
`poolDeploymentPending` distinguishes them and `expectedPoolAddress` derives a
future Pool address. Capacity is 24,572 Jetton Pools plus four TonPools. Active
and pending entries share those same 24,576 slots, so there is no smaller global
in-flight limit that Jetton activation failures can exhaust.

### `Pool`

One per `(jettonMaster, denomination)`. Asset: a TEP-74 jetton. At creation the pool resolves its own jetton wallet on-chain via TEP-89, so the creator cannot poison the binding.

| Opcode | Message | Required value |
|---|---|---|
| `0xd6e05112` | DepositPayload inside TEP-74 notification | denomination in jettons + 0.37 TON forward |
| `0x4b6f0b51` | Withdraw | 0.25 TON |

Events: `DepositEvent` (`0x00de9052`), `WithdrawalAcceptedEvent`
(`0x00717d3c`) and `PoolReadyEvent` (`0x00def002`).

### `TonPool`

One per denomination. Asset: native TON. Same deposit / withdraw semantics as `Pool`; payout is a direct TON transfer.

| Opcode | Message | Required value |
|---|---|---|
| `0xd6e05112` | TonDepositPayload | denomination + 0.37 TON |
| `0x4b6f0b51` | TonWithdraw | 0.10 TON |

Events: `TonDepositEvent` (`0x00de9052`) and `TonWithdrawEvent`
(`0x00717d3b`).

Shared pool state is bounded: immutable identity, depth-20 root and 100-root
history, 256 commitment bucket roots, 256 nullifier bucket roots, and accounting
reserves. Jetton Pool also keeps a `withdrawalCount` bounded by `nextIndex`.

## Protocol

1. **Deposit.** Transfer `denomination` units and a commitment `c = Poseidon(nullifier, secret)` to the pool. The Pool verifies a transparent sparse non-membership witness, then inserts `c` at `leafIndex = nextIndex`.
2. **Note.** Save `(asset, denomination, leafIndex, nullifier, secret)` locally. Lose it, lose the funds.
3. **Withdraw.** Produce a Groth16 proof of knowledge of `(nullifier, secret)` for some commitment in the tree, declaring `nullifierHash = Poseidon(nullifier, 0)` and a recipient `R`.
4. **Verification.** Pool checks the root is recent, verifies a transparent sparse non-membership witness for the nullifier, and checks the pairing equation. It then records the nullifier and pays `R` the full denomination.
5. **Broadcaster.** The relayer is not bound in the proof, so anyone broadcasting a published proof claims the 0.30 TON earmark plus their unused transaction gas. A normal replay fails on the nullifier check.

### Jetton settlement invariants

The caller's `clientQueryId` is correlation data only and is copied unchanged
into the standard TEP-74 payout. Each accepted withdrawal is one-shot: the Pool
marks the nullifier, increments `withdrawalCount`, sends one canonical transfer,
and exposes no second-payment API.

Only the immutable master may bind the Pool wallet through TEP-89. Only
notifications from that bound wallet can increment `nextIndex`, and every
accepted notification carries exactly one denomination. A withdrawal requires
`withdrawalCount < nextIndex`; with a standards-compliant wallet, its Jetton
balance therefore covers every accepted payout. The Pool attaches `0.15 TON`
to the wallet transfer, while the caller-funded `0.25 TON` withdrawal floor
covers Pool compute and actions. Local action failure rolls back the nullifier,
counter and reserve writes atomically.

Rejected deposits return their jettons through the pool's jetton wallet and carry the remaining inbound TON, so malformed deposits cannot trap their excess TON or consume the pool's reserves.

These guarantees apply to TEP-74/89 compliant Jettons. A malicious master can
return a non-standard wallet, but that can affect only the permissionless Pool
for its own asset. The contracts have no allowlist, admin or off-chain oracle;
official clients may still choose which assets they present to users.

### Off-chain state at one million notes

The bounded contracts remove the on-chain state-growth limit, but proving still
requires an incremental off-chain state provider. A production provider must
persist the Poseidon tree, sparse Patricia nodes, ordered events, checkpoints,
and verified journals. Rebuilding from genesis or retaining all nodes in browser
JavaScript Maps is not a one-million-note production design.

## Building from source

Requires [Acton 1.1.0](https://github.com/ton-blockchain/acton) and, for the circuits, [circom 2.2.3](https://github.com/iden3/circom) with `snarkjs 0.7.6`.

### Contracts

```bash
acton build
acton test
acton fmt --check
```

The suite includes real Groth16 BLS12-381 pairing, dense 247-sibling sparse
witnesses, state bounds, exact economic thresholds, mutation checks, and action
failure injection. Wrappers under `wrappers/` are generated by Acton.

### Circuits

```bash
cd circuits
npm install
npm run compile
npm run check:zeros
npm run check:constraints
npm run check:toolchain
```

Constraints: `insert` 25,105, `withdraw` 14,537, `hasher` 624.

### Circuit interfaces

`insert.circom`. Public inputs `(oldRoot, newRoot, commitment, leafIndex)`. Proves `newRoot = MerkleInsert(oldRoot, commitment, leafIndex)`.

`withdraw.circom`. Public inputs `(root, nullifierHash, recipient)`. Proves knowledge of `(nullifier, secret)` for some commitment in the tree. The recipient is re-derived from the message on-chain, so it cannot be swapped between proof generation and broadcast.

### Address-to-field encoding

```
recipientField = low248(
  Cell(0x5a4b5201, int32(workchain), uint256(accountHash)).hash()
)
```

The complete canonical address is domain-hashed before truncation, so changing
any address bit invalidates the proof. The Tolk contracts and SDK mirror the
same 320-bit, zero-reference cell encoding. The final 248-bit value fits inside
the BLS12-381 Fr field.

### Current build hashes

| Contract | Code hash |
|---|---|
| Factory | `c2c1ffadb3c46ebba1fc9b184a384590b057a8a3d19eb9edd3dfc86ed5983f36` |
| Pool | `51cd5b3ec01beb28a843d30ecf60ea998d1107342a214969ae72047f1eb82dec` |
| TonPool | `fde119db0060a01c0a00adc307ec98a2bf5b734ca7ef45e886c9ca2cce642aa3` |

Reproduce with `jq -r .hash build/*.json` from a clean build.

### Trusted setup

The committed `contracts/verifier-*-vk.tolk` constants are generated from the final multi-party ceremony output in [TONresistor/zk-resistor-ceremony](https://github.com/TONresistor/zk-resistor-ceremony). Phase 2 was sealed by Drand round `6266966`.

This repo commits the on-chain verifier constants and the small exported VK JSON files under `circuits/vk/`. The final `.zkey` proving keys are not committed here; they remain in the ceremony archive and should be published with the frontend/SDK proving artifacts.

Final ceremony zkey hashes:

| Circuit | SHA-256 |
|---|---|
| insert | `5ef0a354249e224dc52d72bd332391503d0a63878fb6b1485ca729e040ae59ef` |
| withdraw | `60b22adfc56e3c8268484213ea34cb29492645decc41bd0d5632762de39949ff` |

Pinned ceremony R1CS hashes:

| Circuit | SHA-256 |
|---|---|
| insert | `614ade50a78c65a47cdc578204e9e89acb124b2c892262a027cc22b8299ffe07` |
| withdraw | `aa7017d9ca01aab59b31e22e193e0754bc5eefe4871ffe51ab5abae560c80f35` |

Committed VK JSON hashes:

| Circuit | SHA-256 |
|---|---|
| `circuits/vk/insert_vk.json` | `a2667f9d360cdb91aeeb5c1fb19e0312ea0dea5c9f7902d5e6ebec21bbfb4b71` |
| `circuits/vk/withdraw_vk.json` | `54eaba78d2b47bd01aaeaa3a2a687565e1e641ba7d87e8e9eb4385e3d377c3e6` |

### Mainnet deployments

The table below documents the currently deployed `2.0.0` Factory. This `2.0.1`
branch changes only Factory bytecode, requires a new address, and builds with
Acton 1.1.0 / Tolk 1.4.1.

The production sources are frozen at commit
[`c46b679`](https://github.com/TONresistor/zk-resistor-contracts/commit/c46b67997804d6cbaaeaa8e03813a4dd776b1422)
and reproduce the deployed bytecode with Acton 1.0.0 and Tolk 1.4.0.

| Contract | Mainnet address or anchor | Verified source |
|---|---|---|
| Factory | [`EQD3rhFaCusU0715MZonDNj8GuHeA17KygIXkBLkalpkBjle`](https://tonviewer.com/EQD3rhFaCusU0715MZonDNj8GuHeA17KygIXkBLkalpkBjle) | [TON Verifier](https://verifier.ton.org/UQD3rhFaCusU0715MZonDNj8GuHeA17KygIXkBLkalpkBmSb) |
| Pool | Code-hash anchor [`EQDalKF576pLt4xO0QFxQyfk8w7juYpw99970753nyu8SGSv`](https://tonviewer.com/EQDalKF576pLt4xO0QFxQyfk8w7juYpw99970753nyu8SGSv) | [TON Verifier](https://verifier.ton.org/UQDalKF576pLt4xO0QFxQyfk8w7juYpw99970753nyu8SDlq) |
| TonPool | Code-hash anchor [`EQA4dH1RqyFsROwfRF-7rwUT8676lW6DkJkW484pIYA7wiIe`](https://tonviewer.com/EQA4dH1RqyFsROwfRF-7rwUT8676lW6DkJkW484pIYA7wiIe) | [TON Verifier](https://verifier.ton.org/UQA4dH1RqyFsROwfRF-7rwUT8676lW6DkJkW484pIYA7wn_b) |

TON Verifier binds sources to a runtime code hash. The Pool address above is
only the deployed anchor for the shared Pool code; its asset and state are not
part of source verification.

The Factory currently registers two TonPool instances, for fixed denominations
of 10 and 100 native units. They share the verified TonPool code hash above.

- Production frontend: [zk.resistance.dog](https://zk.resistance.dog)
- Historical frontend: [zk.resistance.dog/old/](https://zk.resistance.dog/old/)

## License

MIT. See [LICENSE](./LICENSE).
