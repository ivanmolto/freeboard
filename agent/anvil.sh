#!/usr/bin/env bash
# The keeper agent's chain: mainnet forked at the pinned block, on anvil.
# --auto-impersonate lets script/StageWorld.s.sol broadcast from Alice, the taker and Aave's
# ACL admin without their keys (forge script --unlocked).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${MAINNET_RPC_URL:?set MAINNET_RPC_URL in .env}"
: "${FORK_BLOCK:?set FORK_BLOCK in .env}"
exec anvil --fork-url "$MAINNET_RPC_URL" --fork-block-number "$FORK_BLOCK" --auto-impersonate --port "${ANVIL_PORT:-8545}"
