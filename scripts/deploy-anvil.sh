#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "PRIVATE_KEY is required (use an Anvil dev key)" >&2
  exit 1
fi

cd "$ROOT"

ORACLE_0="${ORACLE_0:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
ORACLE_1="${ORACLE_1:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
TREASURY="${TREASURY:-0x3c44cdddb6a900fa2b585dd299e03d12FA4293BC}"
WITH_UMA_RAW="${WITH_UMA:-false}"
case "${WITH_UMA_RAW,,}" in
  1|true|yes|y|on) WITH_UMA="true" ;;
  0|false|no|n|off|"") WITH_UMA="false" ;;
  *)
    echo "WITH_UMA must be a boolean (true/false/1/0), got: ${WITH_UMA_RAW}" >&2
    exit 1
    ;;
esac

PRIVATE_KEY="$PRIVATE_KEY" \
ORACLE_0="$ORACLE_0" \
ORACLE_1="$ORACLE_1" \
TREASURY="$TREASURY" \
WITH_UMA="$WITH_UMA" \
forge script script/DeployLocalStack.s.sol:DeployLocalStack --rpc-url "$RPC_URL" --broadcast --force
