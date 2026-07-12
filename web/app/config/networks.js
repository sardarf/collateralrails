// Network presets — pick one chain to run against instead of "any".
//
// Each preset pairs a viem chain (id, name, native currency, public RPC, block
// explorer, multicall) with the CollateralRails contract addresses deployed on it.
// Selection is driven by a single env var, NUXT_PUBLIC_NETWORK (see nuxt.config.ts):
//
//   local           → anvil / foundry (chain 31337), deterministic demo addresses
//   arbitrumSepolia  → Arbitrum Sepolia testnet (421614)
//   arbitrum         → Arbitrum One mainnet (42161)
//   avalancheFuji    → Avalanche Fuji testnet (43113)
//   avalanche        → Avalanche C-Chain mainnet (43114)
//
// On Vercel, set NUXT_PUBLIC_NETWORK plus the five contract addresses for that
// deployment (NUXT_PUBLIC_USDC/REGISTRY/POLICY/ROUTER/CM) and everything wires up.
// RPC defaults to the chain's public endpoint; override with NUXT_PUBLIC_RPC.
import { foundry, arbitrum, arbitrumSepolia, avalanche, avalancheFuji } from 'viem/chains'

// Deterministic addresses from `forge script Deploy` against a fresh anvil node.
// Kept as baked defaults so the local demo runs with zero extra env config.
const LOCAL_CONTRACTS = {
  usdc: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
  registry: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
  policy: '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
  router: '0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9',
  cm: '0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9',
}

const EMPTY_CONTRACTS = { usdc: '', registry: '', policy: '', router: '', cm: '' }

export const NETWORKS = {
  local: { chain: foundry, contracts: LOCAL_CONTRACTS },
  arbitrumSepolia: { chain: arbitrumSepolia, contracts: EMPTY_CONTRACTS },
  arbitrum: { chain: arbitrum, contracts: EMPTY_CONTRACTS },
  avalancheFuji: { chain: avalancheFuji, contracts: EMPTY_CONTRACTS },
  avalanche: { chain: avalanche, contracts: EMPTY_CONTRACTS },
}

export const DEFAULT_NETWORK = 'local'

// Resolve the active network from runtime config. Env vars (NUXT_PUBLIC_*) win over
// the preset, so any preset value can be overridden per deployment.
export function resolveNetwork(cfg = {}) {
  const key = NETWORKS[cfg.network] ? cfg.network : DEFAULT_NETWORK
  const { chain, contracts } = NETWORKS[key]

  const rpc = cfg.rpc || chain.rpcUrls.default.http[0]
  const explorer = chain.blockExplorers?.default?.url || ''

  return {
    key,
    chain,
    rpc,
    explorer,
    chainId: chain.id,
    deployBlock: Number(cfg.deployBlock || 0),
    contracts: {
      usdc: cfg.usdc || contracts.usdc,
      registry: cfg.registry || contracts.registry,
      policy: cfg.policy || contracts.policy,
      router: cfg.router || contracts.router,
      cm: cfg.cm || contracts.cm,
    },
  }
}