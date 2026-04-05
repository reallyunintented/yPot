#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8545}"
CHAIN_ID="${CHAIN_ID:-31337}"

exec anvil --chain-id "$CHAIN_ID" --port "$PORT" ${ANVIL_ARGS:-}
