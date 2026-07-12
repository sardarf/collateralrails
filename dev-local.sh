#!/usr/bin/env bash
# ── CollateralRails · local dev bootstrap ─────────────────────────────────────
# One command to boot the full local scenario described in docs/demo-script.md:
#   1. start anvil (deterministic accounts) if it isn't already running
#   2. deploy the five contracts (deterministic addresses)
#   3. wire the addresses into web/.env and watcher/deployment.json
#   4. seed the 5-act demo story so the UI opens with live data
#
# Usage:
#   ./dev-local.sh            # boot + deploy + seed demo
#   ./dev-local.sh --no-seed  # boot + deploy only (empty registry)
#   ./dev-local.sh --reset    # kill any running anvil first (fresh chain)
set -euo pipefail
cd "$(dirname "$0")"

RPC="${RPC:-http://127.0.0.1:8545}"
# anvil account #0 — the deployer. Deterministic across every anvil boot.
DEPLOYER_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SEED=1
RESET=0
for arg in "$@"; do
  case "$arg" in
    --no-seed) SEED=0 ;;
    --reset)   RESET=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

say() { printf '\n\033[1;32m▸ %s\033[0m\n' "$1"; }

anvil_up() {
  curl -s "$RPC" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","id":1}' 2>/dev/null | grep -q result
}

# ── 1. anvil ──────────────────────────────────────────────────────────────────
if [ "$RESET" = "1" ] && anvil_up; then
  say "resetting: stopping existing anvil"
  pkill -x anvil || true
  sleep 1
fi

if anvil_up; then
  say "anvil already running at $RPC"
else
  say "starting anvil → logs at /tmp/collateralrails-anvil.log"
  anvil > /tmp/collateralrails-anvil.log 2>&1 &
  for _ in $(seq 1 40); do anvil_up && break; sleep 0.25; done
  anvil_up || { echo "anvil failed to start — see /tmp/collateralrails-anvil.log" >&2; exit 1; }
fi

# ── 2. deploy ─────────────────────────────────────────────────────────────────
say "deploying contracts"
( cd smart-contracts && PRIVATE_KEY="$DEPLOYER_KEY" forge script script/Deploy.s.sol \
  --rpc-url "$RPC" --broadcast --silent )

# ── 3. wire addresses into web + watcher ──────────────────────────────────────
say "wiring web/.env and watcher/deployment.json"
node scripts/wire-env.mjs 31337 local "$RPC"

# ── 4. seed the demo story ────────────────────────────────────────────────────
if [ "$SEED" = "1" ]; then
  say "seeding demo story (2 sellers · payments · attestations · batch claim · slash)"
  ( cd watcher && [ -d node_modules ] || npm install --silent; RPC="$RPC" node src/demo.mjs )
fi

say "done — start the frontend:"
echo "    cd web && npm install && npm run dev"
echo ""
echo "  MetaMask: add network $RPC (chain 31337) and import anvil keys."
echo "  Demo roles are labelled in the app's balances bar."