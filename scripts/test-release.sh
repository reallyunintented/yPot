#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

JOBS="${JOBS:-0}"
PROFILE="${PROFILE:-default}"
STRICT_LINT_RAW="${STRICT_LINT:-0}"

case "${STRICT_LINT_RAW,,}" in
  1|true|yes|y|on) STRICT_LINT="1" ;;
  0|false|no|n|off|"") STRICT_LINT="0" ;;
  *)
    echo "STRICT_LINT must be boolean (true/false/1/0), got: ${STRICT_LINT_RAW}" >&2
    exit 1
    ;;
esac

echo "Running release validation with profile=${PROFILE}, jobs=${JOBS}"

run_timed() {
  local label="$1"
  shift
  local start end
  start=$(date +%s)
  "$@"
  end=$(date +%s)
  echo "    completed ${label} in $((end - start))s"
}

if [[ "$STRICT_LINT" == "1" ]]; then
  echo "[0/3] Lint (warnings are errors)"
  FOUNDRY_PROFILE="$PROFILE" forge lint -j "$JOBS" -D warnings
fi

echo "[1/3] Build"
run_timed "build" env FOUNDRY_PROFILE="$PROFILE" forge build --force -j "$JOBS" --skip test

echo "[2/3] Full suite (excluding invariants, sharded per test file)"
mapfile -t NON_INVARIANT_TESTS < <(find test -type f -name "*.t.sol" ! -name "yPotInvariant.t.sol" | sort)

if [[ "${#NON_INVARIANT_TESTS[@]}" -eq 0 ]]; then
  echo "No non-invariant tests found under test/" >&2
  exit 1
fi

for test_file in "${NON_INVARIANT_TESTS[@]}"; do
  echo "  - ${test_file}"
  run_timed "$test_file" env FOUNDRY_PROFILE="$PROFILE" forge test --summary -j "$JOBS" --match-path "$test_file"
done

echo "[3/3] Invariant suite"
run_timed "test/yPotInvariant.t.sol" env FOUNDRY_PROFILE="$PROFILE" forge test --summary -j "$JOBS" --match-path test/yPotInvariant.t.sol

echo "Release validation complete."
