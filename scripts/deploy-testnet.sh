#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

required_vars=(
  RPC_URL
  PRIVATE_KEY
  ASSET
  VAULT
  TREASURY
  ORACLE_COUNT
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required env var: $var" >&2
    exit 1
  fi
done

if ! [[ "${ORACLE_COUNT}" =~ ^[0-9]+$ ]] || (( ORACLE_COUNT < 2 )); then
  echo "ORACLE_COUNT must be an integer >= 2" >&2
  exit 1
fi

for ((i=0; i<ORACLE_COUNT; i++)); do
  key="ORACLE_${i}"
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required env var: $key" >&2
    exit 1
  fi
done

if ! command -v cast >/dev/null 2>&1; then
  echo "Missing required command: cast (Foundry)." >&2
  exit 1
fi

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || true)"
if ! [[ "$CHAIN_ID" =~ ^[0-9]+$ ]]; then
  echo "Could not determine chain id from RPC_URL: $RPC_URL" >&2
  exit 1
fi

case "$CHAIN_ID" in
  1|10|137|8453|42161)
    if ! is_true "${ALLOW_MAINNET_DEPLOY:-0}"; then
      echo "Refusing deploy to mainnet chainId=$CHAIN_ID in testnet-only mode." >&2
      echo "Set ALLOW_MAINNET_DEPLOY=1 only when explicitly promoting to production." >&2
      exit 1
    fi
    ;;
esac

verify_flags=()
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  verify_flags+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
  if [[ -n "${VERIFIER_URL:-}" ]]; then
    verify_flags+=(--verifier-url "$VERIFIER_URL")
  fi
fi

echo "Deploying yPot to RPC ${RPC_URL}"
forge script script/DeployyPot.s.sol:DeployyPot \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --force \
  "${verify_flags[@]}"
