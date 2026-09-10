#!/usr/bin/env bash
# Stage world on the running anvil fork (agent/anvil.sh), then write agent/world.json.
#
# Two phases, because forge's cheatcodes do not reach a live node:
#   1. fund the accounts over anvil's own RPC — anvil_dealERC20 is `deal` for a node;
#   2. every state change that is a real transaction — supply, borrow, ship, approve, the
#      oracle warp — is broadcast by script/StageWorld.s.sol from anvil's unlocked accounts.
#
# STAGE_HF (WAD) picks the rung Alice is landed on. Default 1.30e18.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"

WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
WBTC=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# anvil default mnemonic accounts 1 and 2; Aave's ACL admin, who must pay gas for one grant.
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
ACL_ADMIN=0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A

# `deal` for a node. anvil 1.5.1's anvil_dealERC20 answers "no slot found" for all three tokens on
# this fork, so this does what forge-std's `deal` does: probe the balance mapping's slot by
# writing keccak256(account . slot) for slot = 0.. and reading balanceOf back, restoring every
# miss. WETH9 keeps balanceOf at slot 3, WBTC at 0, USDC (FiatTokenV2 behind a proxy) at 9 — the
# probe finds them rather than trusting that.
deal() { # token, account, amount (decimal)
  local token=$1 account=$2 amount=$3 hex slot key before after
  hex=$(cast to-hex "$amount")
  for slot in $(seq 0 40); do
    key=$(cast index address "$account" "$slot")
    before=$(cast storage --rpc-url "$RPC" "$token" "$key")
    cast rpc --rpc-url "$RPC" anvil_setStorageAt "$token" "$key" "$(cast to-uint256 "$hex")" >/dev/null
    after=$(cast call --rpc-url "$RPC" "$token" "balanceOf(address)(uint256)" "$account" | awk '{print $1}')
    if [ "$after" = "$amount" ]; then
      return 0
    fi
    cast rpc --rpc-url "$RPC" anvil_setStorageAt "$token" "$key" "$before" >/dev/null
  done
  echo "deal: no balance slot found for $token" >&2
  return 1
}

# Alice: 100 WETH + 3 WBTC to supply, 10 WETH + 0.3 WBTC to ship. Her USDC leg is borrowed.
deal "$WETH" "$ALICE" 110000000000000000000
deal "$WBTC" "$ALICE" 330000000
# The taker's float — T23's numbers.
deal "$WETH" "$TAKER" 100000000000000000000
deal "$WBTC" "$TAKER" 1000000000
deal "$USDC" "$TAKER" 1000000000000
# One ETH for the ACL admin's grant.
cast rpc --rpc-url "$RPC" anvil_setBalance "$ACL_ADMIN" 0xde0b6b3a7640000 >/dev/null

# --legacy: forge otherwise asks the node for eth_feeHistory, which anvil forwards upstream and
# the upstream rate-limits (503 "Unable to complete request"); a gas price anvil answers itself.
STAGE_HF="${STAGE_HF:-1300000000000000000}" \
  forge script script/StageWorld.s.sol --rpc-url "$RPC" --broadcast --unlocked --legacy -vv
