#!/usr/bin/env bash
# ── CollateralRails · testnet → Vercel deploy pipeline ────────────────────────
# One orchestrator, three stages. Run all, or one at a time with --stage.
#
#   ./deploy-testnet.sh                     # contracts → env → app (Arbitrum Sepolia)
#   ./deploy-testnet.sh --stage contracts   # just deploy + verify the contracts
#   ./deploy-testnet.sh --stage env         # just wire addresses → web/.env + Vercel
#   ./deploy-testnet.sh --stage app         # just build + deploy the app to Vercel
#   ./deploy-testnet.sh --network avalancheFuji
#   PRINT_ONLY=1 ./deploy-testnet.sh --stage env   # print env instead of pushing to Vercel
#
# Prereqs:
#   • Foundry (forge) + a funded deployer key
#   • smart-contracts/.env with: PRIVATE_KEY, <RPC for the target>, ARBISCAN_API_KEY (for --verify)
#   • Vercel CLI logged in + linked once:  npm i -g vercel && (cd web && vercel login && vercel link)
set -euo pipefail
cd "$(dirname "$0")"

NETWORK="arbitrumSepolia"
STAGE="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# network → (chainId, foundry rpc-endpoint alias). Extend here for more chains.
case "$NETWORK" in
  arbitrumSepolia) CHAIN_ID=421614;  RPC_ALIAS="arbitrum_sepolia" ;;
  arbitrum)        CHAIN_ID=42161;   RPC_ALIAS="arbitrum" ;;
  avalancheFuji)   CHAIN_ID=43113;   RPC_ALIAS="avalanche_fuji" ;;
  avalanche)       CHAIN_ID=43114;   RPC_ALIAS="avalanche" ;;
  *) echo "unsupported --network: $NETWORK" >&2; exit 1 ;;
esac

[ -f smart-contracts/.env ] && { set -a; . ./smart-contracts/.env; set +a; }
say() { printf '\n\033[1;32m▸ %s\033[0m\n' "$1"; }

stage_contracts() {
  say "Deploying contracts to $NETWORK (chain $CHAIN_ID)"
  : "${PRIVATE_KEY:?set PRIVATE_KEY in smart-contracts/.env}"
  ( cd smart-contracts && forge script script/Deploy.s.sol --rpc-url "$RPC_ALIAS" --broadcast --verify -vvvv )
  say "Deployed addresses (from broadcast):"
  node scripts/wire-env.mjs "$CHAIN_ID" "$NETWORK" "${WEB_RPC:-}" >/dev/null
  node -e "import('./scripts/deployment.mjs').then(m=>{const a=m.readDeployment('$CHAIN_ID');for(const[k,v]of Object.entries(a))console.log('  '+k.padEnd(11),v)})"
}

stage_env() {
  say "Wiring web/.env for $NETWORK"
  node scripts/wire-env.mjs "$CHAIN_ID" "$NETWORK" "${WEB_RPC:-}"
  say "Pushing NUXT_PUBLIC_* to Vercel"
  node scripts/set-vercel-env.mjs "$CHAIN_ID" "$NETWORK" production
}

stage_app() {
  say "Building + deploying the app to Vercel"
  ( cd web && vercel deploy --prod --yes )
}

case "$STAGE" in
  contracts) stage_contracts ;;
  env)       stage_env ;;
  app)       stage_app ;;
  all)       stage_contracts; stage_env; stage_app ;;
  *) echo "unknown --stage: $STAGE (contracts|env|app|all)" >&2; exit 1 ;;
esac

say "Stage '$STAGE' complete."