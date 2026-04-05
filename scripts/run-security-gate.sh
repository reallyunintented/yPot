#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TS_UTC="$(date -u +%Y%m%d-%H%M%SZ)"
REPORT_DIR="$ROOT_DIR/look/reports"
mkdir -p "$REPORT_DIR"

LOG_FILE="$REPORT_DIR/security-gate-$TS_UTC.log"
SUMMARY_FILE="$REPORT_DIR/security-gate-$TS_UTC.md"

START_EPOCH="$(date +%s)"

run_step() {
  local name="$1"
  shift

  {
    echo
    echo "================================================================"
    echo "STEP: $name"
    echo "CMD : $*"
    echo "TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "================================================================"
  } | tee -a "$LOG_FILE"

  "$@" 2>&1 | tee -a "$LOG_FILE"
}

{
  echo "# yPot Security Gate Log"
  echo "Timestamp (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Repo: $ROOT_DIR"
} > "$LOG_FILE"

run_step "Adversarial Sweep" forge test --match-path "test/adversarial/*.t.sol" -vv
run_step "Tier1 Confirm Suite" forge test --match-path test/yPotTier1Confirm.t.sol -vv
run_step "UMA Appeal Suite" forge test --match-path test/yPotUmaAppeal.t.sol -vv
run_step "Security Fixes Suite" forge test --match-path test/audit/SecurityFixes.t.sol -vv

END_EPOCH="$(date +%s)"
DURATION_SEC="$((END_EPOCH - START_EPOCH))"

{
  echo "# Security Gate Result"
  echo
  echo "- Status: PASS"
  echo "- Timestamp (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Duration: ${DURATION_SEC}s"
  echo "- Commands:"
  echo "  - forge test --match-path 'test/adversarial/*.t.sol' -vv"
  echo "  - forge test --match-path test/yPotTier1Confirm.t.sol -vv"
  echo "  - forge test --match-path test/yPotUmaAppeal.t.sol -vv"
  echo "  - forge test --match-path test/audit/SecurityFixes.t.sol -vv"
  echo "- Log: $LOG_FILE"
} > "$SUMMARY_FILE"

echo "Security gate completed successfully."
echo "Log: $LOG_FILE"
echo "Summary: $SUMMARY_FILE"
