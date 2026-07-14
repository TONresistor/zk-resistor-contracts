#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CEREMONY_DIR="${1:?usage: check-ceremony-chain.sh <ceremony-directory>}"
EXPECTED_CEREMONY_COMMIT="2a300cd303edb70e86f9663140174eba7c21d87d"
SNARKJS="$ROOT/circuits/node_modules/.bin/snarkjs"

fail() {
  echo "Ceremony chain verification failed: $*" >&2
  exit 1
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

verify_transcript_hash() {
  local file="$1"
  local expected="${2#sha256:}"
  local actual
  actual="$(hash_file "$file")"
  [[ "$actual" == "$expected" ]] || fail "SHA-256 mismatch for $file"
}

[[ -x "$SNARKJS" ]] || fail "snarkjs is not installed; run npm ci in circuits/"
[[ -d "$CEREMONY_DIR/.git" ]] || fail "$CEREMONY_DIR is not a Git checkout"

actual_commit="$(git -C "$CEREMONY_DIR" rev-parse HEAD)"
[[ "$actual_commit" == "$EXPECTED_CEREMONY_COMMIT" ]] ||
  fail "ceremony commit $actual_commit does not match $EXPECTED_CEREMONY_COMMIT"

transcript="$CEREMONY_DIR/transcript/contributions.json"
phase1_path="$(jq -er '[.contributions[] | select(.stage == "phase1")] | last | select(.name == "drand-beacon") | .ptau' "$transcript")"
phase1_hash="$(jq -er '[.contributions[] | select(.stage == "phase1")] | last | select(.name == "drand-beacon") | .ptau_hash' "$transcript")"
insert_zkey_path="$(jq -er '[.contributions[] | select(.stage == "phase2")] | last | select(.name == "drand-beacon") | .insert_zkey' "$transcript")"
insert_zkey_hash="$(jq -er '[.contributions[] | select(.stage == "phase2")] | last | select(.name == "drand-beacon") | .insert_zkey_hash' "$transcript")"
withdraw_zkey_path="$(jq -er '[.contributions[] | select(.stage == "phase2")] | last | select(.name == "drand-beacon") | .withdraw_zkey' "$transcript")"
withdraw_zkey_hash="$(jq -er '[.contributions[] | select(.stage == "phase2")] | last | select(.name == "drand-beacon") | .withdraw_zkey_hash' "$transcript")"

phase1="$CEREMONY_DIR/$phase1_path"
insert_zkey="$CEREMONY_DIR/$insert_zkey_path"
withdraw_zkey="$CEREMONY_DIR/$withdraw_zkey_path"
verify_transcript_hash "$phase1" "$phase1_hash"
verify_transcript_hash "$insert_zkey" "$insert_zkey_hash"
verify_transcript_hash "$withdraw_zkey" "$withdraw_zkey_hash"

for circuit in insert withdraw; do
  compiled_r1cs="$ROOT/circuits/build/$circuit.r1cs"
  ceremony_r1cs="$CEREMONY_DIR/circuits/$circuit.r1cs"
  [[ -f "$compiled_r1cs" ]] || fail "missing compiled $circuit R1CS"
  cmp -s "$compiled_r1cs" "$ceremony_r1cs" ||
    fail "$circuit R1CS differs from the pinned ceremony artifact"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
pot_final="$tmp_dir/pot_final.ptau"
mkdir -p "$tmp_dir/vk"

"$SNARKJS" powersoftau prepare phase2 "$phase1" "$pot_final"
"$SNARKJS" zkey verify "$CEREMONY_DIR/circuits/insert.r1cs" "$pot_final" "$insert_zkey"
"$SNARKJS" zkey verify "$CEREMONY_DIR/circuits/withdraw.r1cs" "$pot_final" "$withdraw_zkey"

"$SNARKJS" zkey export verificationkey "$insert_zkey" "$tmp_dir/vk/insert_vk.json"
"$SNARKJS" zkey export verificationkey "$withdraw_zkey" "$tmp_dir/vk/withdraw_vk.json"
diff -u "$tmp_dir/vk/insert_vk.json" "$ROOT/circuits/vk/insert_vk.json"
diff -u "$tmp_dir/vk/withdraw_vk.json" "$ROOT/circuits/vk/withdraw_vk.json"

(
  cd "$tmp_dir"
  node "$ROOT/circuits/scripts/vk-to-tolk.js" vk/insert_vk.json INSERT > verifier-insert-vk.tolk
  node "$ROOT/circuits/scripts/vk-to-tolk.js" vk/withdraw_vk.json WITHDRAW > verifier-withdraw-vk.tolk
)
diff -u "$tmp_dir/verifier-insert-vk.tolk" "$ROOT/contracts/verifier-insert-vk.tolk"
diff -u "$tmp_dir/verifier-withdraw-vk.tolk" "$ROOT/contracts/verifier-withdraw-vk.tolk"

echo "Ceremony R1CS, final zkeys, exported VKs, and Tolk constants form one verified release chain."
