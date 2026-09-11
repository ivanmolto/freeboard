#!/usr/bin/env bash
# Walk the T23 price path as TRANSACTIONS on a running anvil fork, for the page to watch (T29).
#
#   1. start the fork, paced so a page can see it move:   ANVIL_BLOCK_TIME=1 agent/anvil.sh
#   2. walk:                                               ui/walk.sh
#
# Funds the engine's accounts over anvil's RPC (the transaction-world `deal`), then broadcasts
# script/LivePricePath.s.sol — the same engine as results/price-path.txt, its three chain
# primitives overridden to transactions — with --slow, one transaction per block. Afterwards it
# checks the NODE, not the simulation: the report the walk wrote must equal the committed
# artifact on every line but the transcript hash, the router must have emitted one Swapped per
# fill under the artifact's strategy hash, and Aqua must hold the artifact's final basket.
#
# WHY THE TRANSCRIPT HASH MAY DIFFER, AND NOTHING ELSE. anvil's clock runs: between Alice's
# borrow and the walk's first read a few seconds can pass, Aave accrues that much interest, her
# health factor at the top reads 1.99999999999 instead of 1.99999999998, the first warp factor
# shifts by one unit in 1e8, and every number downstream carries a few wei of that (one run
# did; the next matched the artifact wei for wei). Every fill, the strategy hash, the spread
# and the final basket agree to the precision the artifact prints; keccak256(abi.encode(run))
# need not. The on-chain balances are therefore compared at one part in 1e9, not to the wei.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"
ARTIFACT=results/price-path.txt
ARTIFACT_JSON=results/price-path.json

WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
WBTC=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
ROUTER=0x111111338c5091E8440b67B168bAe16a668AC0De
AQUA=0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a
ACL_ADMIN=0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A

# forge-std's makeAddr(label): the private key is keccak256(label), the address is vm.addr of it.
addr() { cast wallet address --private-key "$(cast keccak "$1")"; }
ALICE=$(addr alice)
TAKER=$(addr freeboard-taker)
DEPLOYER=$(addr freeboard-deployer)

# `deal` for a node, as agent/stage.sh does it: probe the token's balance-mapping slot by writing
# keccak256(account . slot) and reading balanceOf back, restoring every miss.
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

echo "alice    $ALICE"
echo "taker    $TAKER"
echo "deployer $DEPLOYER"

# The walk must start from the pinned fork block with nothing of ours on it: the extruction's
# address, and so the strategy hash, is the deployer's nonce-0 creation.
nonce=$(cast nonce --rpc-url "$RPC" "$DEPLOYER")
if [ "$nonce" != "0" ]; then
  echo "the deployer has already sent $nonce transaction(s) on this node: restart anvil for a fresh walk" >&2
  exit 1
fi

# Gas for the four accounts that send transactions.
for who in "$ALICE" "$TAKER" "$DEPLOYER" "$ACL_ADMIN"; do
  cast rpc --rpc-url "$RPC" anvil_setBalance "$who" 0x8ac7230489e80000 >/dev/null # 10 ETH
done
# Alice: 100 WETH and 3 WBTC to supply, plus the top-row legs she ships (about 16 WETH and 0.3
# WBTC at the pin); her USDC leg is USDC she borrows. The taker: T23's float, exactly.
deal "$WETH" "$ALICE" 120000000000000000000
deal "$WBTC" "$ALICE" 400000000
deal "$WETH" "$TAKER" 100000000000000000000
deal "$WBTC" "$TAKER" 1000000000
deal "$USDC" "$TAKER" 1000000000000

# --legacy: forge otherwise asks the node for eth_feeHistory, which anvil forwards upstream and
# the upstream rate-limits; --slow: one transaction per block, so the page can watch.
forge script script/LivePricePath.s.sol --tc LivePricePath \
  --rpc-url "$RPC" --broadcast --unlocked --legacy --slow -vv

echo
echo "== the node against the committed artifact =="
if diff <(grep -v '^transcript' results/live-path.txt) <(grep -v '^transcript' "$ARTIFACT") >/dev/null; then
  echo "PASS  results/live-path.txt == $ARTIFACT on every line but the transcript hash"
  echo "      (strategy hash, every rung, every fill, the spread, the final basket)"
  echo "      transcript live     $(grep '^transcript' results/live-path.txt | awk '{print $3}')"
  echo "      transcript artifact $(grep '^transcript' "$ARTIFACT" | awk '{print $3}')  — anvil's clock, see the header"
else
  echo "FAIL  results/live-path.txt differs from $ARTIFACT beyond the transcript line:"
  diff results/live-path.txt "$ARTIFACT" || true
  exit 1
fi

hash=$(python3 -c "import json;print(json.load(open('$ARTIFACT_JSON'))['strategyHash'])")
fills=$(python3 -c "import json;print(json.load(open('$ARTIFACT_JSON'))['fills'])")
from_block=$(python3 -c "import os;print(open('.env').read().split('FORK_BLOCK=')[1].split()[0])")
swapped=$(cast logs --rpc-url "$RPC" --from-block "$from_block" --address "$ROUTER" \
  'Swapped(bytes32,address,address,address,address,uint256,uint256)' --json | python3 -c "
import json,sys
logs=json.load(sys.stdin)
print(sum(1 for l in logs if l['data'][2:66]=='$hash'[2:]))")
if [ "$swapped" = "$fills" ]; then
  echo "PASS  Swapped events under $hash on the node: $swapped == fills in the artifact"
else
  echo "FAIL  Swapped events under $hash: $swapped, artifact fills: $fills"
  exit 1
fi

ok=1
i=0
for token in "$WETH" "$WBTC" "$USDC"; do
  want=$(python3 -c "import json;print(json.load(open('$ARTIFACT_JSON'))['finalBalances'][$i])")
  have=$(cast call --rpc-url "$RPC" "$AQUA" "rawBalances(address,address,bytes32,address)(uint248,uint8)" \
    "$ALICE" "$ROUTER" "$hash" "$token" | head -1 | awk '{print $1}')
  if python3 -c "import sys; h,w=int('$have'),int('$want'); sys.exit(0 if abs(h-w)*1000000000 <= w else 1)"; then
    echo "PASS  Aqua leg $i on the node: $have ~ artifact final basket $want (within 1e-9)"
  else
    echo "FAIL  Aqua leg $i on the node: $have, artifact: $want (beyond 1e-9)"
    ok=0
  fi
  i=$((i + 1))
done
[ "$ok" = "1" ] || exit 1
echo "WALK PASSED"
