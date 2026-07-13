# Changelog

## 2.0.1 compared with 2.0.0

- Removes the 128 pending-creation bottleneck.
- Separates pending requests from active Pools and authenticates activation from
  the deterministic Pool address.
- Raises the bounded Factory capacity from 4,096 Pools to 24,576 slots: 24,572
  Jetton Pools and four native Pools.
- Builds with Acton 1.1.0 and Tolk 1.4.1, with exact ceremony R1CS hashes pinned
  in CI.
- Requires a new immutable Factory address. Existing Pools and notes remain
  usable through their original contracts.
