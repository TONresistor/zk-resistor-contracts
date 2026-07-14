# ZKResistor Contracts

Immutable, fixed-denomination privacy pools on TON, written in Tolk. The
contract and circuit source code in this repository is authoritative.

## How it works

1. A user generates a private note locally.
2. The note commitment is deposited into a Pool.
3. A Groth16 proof authorizes withdrawal without revealing which deposit is
   being spent.
4. The Pool records the nullifier and pays the recipient bound to the proof.

Anyone may create a Pool, deposit, or broadcast a withdrawal. The contracts
have no administrator, upgrade path, allowlist, oracle, or off-chain authority.

Each Pool provides:

- `1,048,576` deposit slots at Merkle depth 20;
- the current Merkle root and 99 previous roots, so recently generated proofs
  remain usable while new deposits arrive;
- on-chain Groth16 verification over BLS12-381;
- bounded commitment and nullifier state;
- recipient-bound withdrawal proofs;
- immutable code and identity.

## Contracts

| Contract  | Purpose                                            |
| --------- | -------------------------------------------------- |
| `Factory` | Deploys and indexes Pools permissionlessly.        |
| `Pool`    | Holds one TEP-74 Jetton at one fixed denomination. |
| `TonPool` | Holds the native asset at one fixed denomination.  |

The Factory supports up to 24,572 Jetton Pools and four TonPools. TonPool
denominations are fixed at 10, 100, 1,000, and 10,000 native units. Active and
pending creations share the same 24,576 slots.

`FactoryPoolCreatedEvent` records an accepted creation request, not final Pool
activation. Clients must use the Factory getters to distinguish pending and
active Pools.

### Minimum attached values

| Operation | Value |
|---|---:|
| Create Jetton Pool | `0.45 TON` |
| Create TonPool | `0.45 TON` |
| Jetton deposit forwarded to Pool | `0.37 TON` |
| TonPool deposit | denomination + `0.37 TON` |
| Jetton withdrawal | `0.25 TON` |
| TonPool withdrawal | `0.10 TON` |

Each accepted deposit reserves `0.30 TON` for its future withdrawal
broadcaster. Anyone can submit a valid proof, but cannot change its recipient.

Users must retain their private notes. Losing a note loses access to its funds.
Jetton settlement assumes a TEP-74 and TEP-89 compliant master and wallet; a
malicious Jetton can affect only its own permissionless Pool.

## Build

Requirements:

- Acton 1.1.0
- Tolk 1.4.1
- Circom 2.2.3
- snarkjs 0.7.6

```bash
acton build
acton test
acton fmt --check
```

```bash
cd circuits
npm ci
npm run compile
npm run check:zeros
npm run check:constraints
npm run check:toolchain
```

Acton generates the TypeScript wrappers under `wrappers/`.

## Build hashes

| Contract | Code hash |
|---|---|
| Factory | `c2c1ffadb3c46ebba1fc9b184a384590b057a8a3d19eb9edd3dfc86ed5983f36` |
| Pool | `51cd5b3ec01beb28a843d30ecf60ea998d1107342a214969ae72047f1eb82dec` |
| TonPool | `fde119db0060a01c0a00adc307ec98a2bf5b734ca7ef45e886c9ca2cce642aa3` |

Reproduce them after a clean build with:

```bash
jq -r .hash build/*.json
```

## Trusted setup

The verifier constants come from the completed multi-party ceremony in
[`TONresistor/zk-resistor-ceremony`](https://github.com/TONresistor/zk-resistor-ceremony).
The proving keys are distributed separately and are not committed here.

| Circuit | Final zkey SHA-256 |
|---|---|
| Insert | `5ef0a354249e224dc52d72bd332391503d0a63878fb6b1485ca729e040ae59ef` |
| Withdraw | `60b22adfc56e3c8268484213ea34cb29492645decc41bd0d5632762de39949ff` |

## Mainnet

| Contract | Deployment | Verified source |
|---|---|---|
| Factory | [`EQB8W1W276GWiQpK88Sx46K20rsMrCKIezOpwFGJ4dhjWz58`](https://tonviewer.com/EQB8W1W276GWiQpK88Sx46K20rsMrCKIezOpwFGJ4dhjWz58) | [TON Verifier](https://verifier.ton.org/UQB8W1W276GWiQpK88Sx46K20rsMrCKIezOpwFGJ4dhjW2O5) |
| Pool code anchor | [`EQDalKF576pLt4xO0QFxQyfk8w7juYpw99970753nyu8SGSv`](https://tonviewer.com/EQDalKF576pLt4xO0QFxQyfk8w7juYpw99970753nyu8SGSv) | [TON Verifier](https://verifier.ton.org/UQDalKF576pLt4xO0QFxQyfk8w7juYpw99970753nyu8SDlq) |
| TonPool code anchor | [`EQA4dH1RqyFsROwfRF-7rwUT8676lW6DkJkW484pIYA7wiIe`](https://tonviewer.com/EQA4dH1RqyFsROwfRF-7rwUT8676lW6DkJkW484pIYA7wiIe) | [TON Verifier](https://verifier.ton.org/UQA4dH1RqyFsROwfRF-7rwUT8676lW6DkJkW484pIYA7wn_b) |

TON Verifier binds source code to runtime code hashes. Pool anchors verify the
shared code, not a specific Pool asset or state.

- Application: [zk.resistance.dog](https://zk.resistance.dog)
- Previous deployment: [zk.resistance.dog/old/](https://zk.resistance.dog/old/)

## Reference

- [`PROTOCOL.md`](./PROTOCOL.md): protocol behavior and invariants.
- [`CHANGELOG.md`](./CHANGELOG.md): release changes.

If documentation and source code disagree, the source code is authoritative.

## License

MIT. See [LICENSE](./LICENSE).
