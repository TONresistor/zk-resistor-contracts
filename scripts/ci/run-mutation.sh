#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT/build/ci-heavy"
mkdir -p "$OUT_DIR"

SCOPE="${MUTATION_SCOPE:-full}"
BASE_REF="${MUTATION_BASE_REF:-origin/main}"
LEVELS="${MUTATION_LEVELS:-critical,major}"

if [[ "$SCOPE" != "full" && "$SCOPE" != "diff" ]]; then
  echo "::error::MUTATION_SCOPE must be 'full' or 'diff'"
  exit 1
fi

run_mutation() {
  local contract="$1"
  local sources_csv="$2"
  local manifest="${3:-$ROOT/Acton.toml}"
  local test_path="${4:-}"
  local log="$OUT_DIR/mutation-${contract}.log"

  echo "::group::Mutation ${contract}"
  (
    cd "$ROOT"
    acton_args=(
      --manifest-path "$manifest"
      test
    )
    if [[ -n "$test_path" ]]; then
      acton_args+=("$test_path")
    fi
    mutation_args=(
      --mutate \
      --mutate-contract "$contract" \
      --mutation-levels "$LEVELS" \
      --reporter dot
    )
    if [[ "$SCOPE" == "diff" ]]; then
      mutation_args+=(--mutation-diff ref --mutation-diff-ref "$BASE_REF")
    fi
    acton "${acton_args[@]}" "${mutation_args[@]}"
  ) | tee "$log"
  echo "::endgroup::"

  local session_id
  session_id="$(sed -nE 's/^Session:[[:space:]]+([[:xdigit:]]+).*$/\1/p' "$log" | tail -n 1)"
  if [ -z "$session_id" ]; then
    echo "::error::Could not identify ${contract} mutation session"
    exit 1
  fi
  local sources
  IFS=',' read -r -a sources <<< "$sources_csv"
  for source in "${sources[@]}"; do
    node "$ROOT/scripts/ci/check-mutation-source.mjs" \
      --session "$ROOT/build/mutation-sessions/${session_id}.jsonl" \
      --contract "$contract" \
      --source "$source" \
      --waivers "$ROOT/scripts/ci/mutation-waivers.json"
  done
}

run_mutation \
  "Pool" \
  "contracts/pool.tolk,contracts/recipient-binding.tolk" \
  "$ROOT/Acton.toml" \
  "$ROOT/tests"
run_mutation "TonPool" "contracts/ton-pool.tolk" "$ROOT/Acton.toml" "$ROOT/tests"
run_mutation "Factory" "contracts/factory.tolk" "$ROOT/Acton.toml" "$ROOT/tests"

echo "Mutation gates passed."
