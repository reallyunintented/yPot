#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC_URL="${RPC_URL:-}"
OUT="${OUT:-$ROOT/deployments/base-sepolia-preview.json}"
WITH_UMA_RAW="${WITH_UMA:-false}"

if [[ -z "$RPC_URL" ]]; then
  echo "RPC_URL is required (expected a Base Sepolia RPC)." >&2
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "PRIVATE_KEY is required." >&2
  exit 1
fi

if [[ -z "${ORACLE_1:-}" ]]; then
  echo "ORACLE_1 is required for preview deploys. Use a second distinct EOA." >&2
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "Missing required command: cast (Foundry)." >&2
  exit 1
fi

if ! command -v forge >/dev/null 2>&1; then
  echo "Missing required command: forge (Foundry)." >&2
  exit 1
fi

case "${WITH_UMA_RAW,,}" in
  1|true|yes|y|on) WITH_UMA="true" ;;
  0|false|no|n|off|"") WITH_UMA="false" ;;
  *)
    echo "WITH_UMA must be a boolean (true/false/1/0), got: ${WITH_UMA_RAW}" >&2
    exit 1
    ;;
esac

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || true)"
if [[ "$CHAIN_ID" != "84532" ]]; then
  echo "Expected Base Sepolia chainId 84532, got: ${CHAIN_ID:-<unknown>}" >&2
  echo "Refusing preview deploy to the wrong network." >&2
  exit 1
fi

cd "$ROOT"

echo "[deploy-preview] deploying local-stack preview to Base Sepolia"
echo "[deploy-preview] output: $OUT"
echo "[deploy-preview] WITH_UMA=$WITH_UMA"

export PRIVATE_KEY
export OUT
export WITH_UMA

if [[ -n "${TREASURY:-}" ]]; then
  export TREASURY
else
  echo "[deploy-preview] TREASURY not set; DeployLocalStack will default it to the deployer address"
fi

if [[ -n "${ORACLE_0:-}" ]]; then
  export ORACLE_0
else
  echo "[deploy-preview] ORACLE_0 not set; DeployLocalStack will default it to the deployer address"
fi

export ORACLE_1

forge script script/DeployLocalStack.s.sol:DeployLocalStack \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --force

echo "[deploy-preview] done"
