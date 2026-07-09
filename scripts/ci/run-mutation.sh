#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT/build/ci-heavy"
mkdir -p "$OUT_DIR"

BASE_REF="${MUTATION_BASE_REF:-origin/main}"
LEVELS="${MUTATION_LEVELS:-critical,major}"

run_mutation() {
  local contract="$1"
  local source="$2"
  local fail_on_any_survivor="$3"
  local log="$OUT_DIR/mutation-${contract}.log"

  echo "::group::Mutation ${contract}"
  (
    cd "$ROOT"
    acton test \
      --mutate \
      --mutate-contract "$contract" \
      --mutation-diff ref \
      --mutation-diff-ref "$BASE_REF" \
      --mutation-levels "$LEVELS" \
      --reporter dot
  ) | tee "$log"
  echo "::endgroup::"

  if [ "$fail_on_any_survivor" = "yes" ] && grep -q "SURVIVED\\|Survived Mutants" "$log"; then
    echo "::error::${contract} mutation has surviving mutants"
    exit 1
  fi

  if grep -E "contracts/${source}\\.tolk:.*SURVIVED|at contracts/${source}\\.tolk:" "$log"; then
    echo "::error::${contract} has surviving mutants in contracts/${source}.tolk"
    exit 1
  fi
}

run_mutation "Pool" "pool" "yes"
run_mutation "TonPool" "ton-pool" "no"
run_mutation "Factory" "factory" "no"

echo "Mutation gates passed."
