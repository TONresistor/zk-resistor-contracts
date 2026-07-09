#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

(
  cd "$ROOT/circuits"
  node scripts/vk-to-tolk.js vk/insert_vk.json INSERT > "$TMP_DIR/verifier-insert-vk.tolk"
  node scripts/vk-to-tolk.js vk/withdraw_vk.json WITHDRAW > "$TMP_DIR/verifier-withdraw-vk.tolk"
)

diff -u "$TMP_DIR/verifier-insert-vk.tolk" "$ROOT/contracts/verifier-insert-vk.tolk"
diff -u "$TMP_DIR/verifier-withdraw-vk.tolk" "$ROOT/contracts/verifier-withdraw-vk.tolk"

echo "Verifier Tolk constants match committed VK JSON files."
