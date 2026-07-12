// Shared helper: read the deployed contract addresses from the latest Foundry
// broadcast for a chain. Used by wire-env.mjs (local/web + watcher) and
// set-vercel-env.mjs (push to Vercel).
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

const NAME_TO_KEY = {
  MockUSDC: 'usdc',
  BondedRegistry: 'registry',
  PolicyManager: 'policy',
  SettlementRouter: 'router',
  ClaimManager: 'cm',
}

/** { usdc, registry, policy, router, cm, deployBlock } from smart-contracts/broadcast/<chainId>/run-latest.json */
export function readDeployment(chainId) {
  const path = join(ROOT, `smart-contracts/broadcast/Deploy.s.sol/${chainId}/run-latest.json`)
  const broadcast = JSON.parse(readFileSync(path, 'utf8'))

  const addr = {}
  for (const t of broadcast.transactions) {
    if (t.transactionType === 'CREATE' && NAME_TO_KEY[t.contractName]) {
      addr[NAME_TO_KEY[t.contractName]] = t.contractAddress
    }
  }
  const missing = Object.values(NAME_TO_KEY).filter((k) => !addr[k])
  if (missing.length) throw new Error(`missing addresses for ${missing.join(', ')} in ${path}`)

  addr.deployBlock = parseInt(broadcast.receipts?.[0]?.blockNumber || '0x0', 16)
  return addr
}

/** The NUXT_PUBLIC_* env pairs the frontend needs, for a resolved deployment. */
export function nuxtEnv({ network, rpc, addr }) {
  return {
    NUXT_PUBLIC_NETWORK: network,
    NUXT_PUBLIC_RPC: rpc || '',
    NUXT_PUBLIC_USDC: addr.usdc,
    NUXT_PUBLIC_REGISTRY: addr.registry,
    NUXT_PUBLIC_POLICY: addr.policy,
    NUXT_PUBLIC_ROUTER: addr.router,
    NUXT_PUBLIC_CM: addr.cm,
    NUXT_PUBLIC_DEPLOY_BLOCK: String(addr.deployBlock),
  }
}