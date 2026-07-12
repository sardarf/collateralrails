// Mock EIP-1193 wallet for E2E — no browser extension needed.
//
// It injects window.ethereum before the app loads and forwards every RPC call to
// the local anvil node. anvil's default dev accounts are UNLOCKED, so it signs
// transactions and EIP-712 typed data itself — we only override which account is
// "connected" per test. This lets Playwright drive the real UI (connect, pay,
// sign & anchor, file claim, resolve) exactly as a user with MetaMask would.
import type { Page } from '@playwright/test'

export const RPC = process.env.E2E_RPC || 'http://127.0.0.1:8545'

// anvil deterministic accounts, by the role each plays in the demo scenario.
export const ACCOUNTS = {
  deployer:       '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
  sellerHonest:   '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
  sellerDeadbeat: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
  buyer:          '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
  watcher:        '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65',
} as const

export type Role = keyof typeof ACCOUNTS

/** Inject window.ethereum bound to `account`. Call BEFORE page.goto. */
export async function useWallet(page: Page, account: string) {
  await page.addInitScript(
    ({ rpc, account }) => {
      let id = 0
      const raw = async (method: string, params: any[] = []) => {
        const res = await fetch(rpc, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
        })
        const j = await res.json()
        if (j.error) { const e: any = new Error(j.error.message); e.code = j.error.code; throw e }
        return j.result
      }
      const provider = {
        isMetaMask: true,
        request: async ({ method, params = [] }: { method: string; params?: any[] }) => {
          switch (method) {
            case 'eth_requestAccounts':
            case 'eth_accounts':
              return [account]
            case 'wallet_switchEthereumChain':
            case 'wallet_addEthereumChain':
              return null
            case 'eth_sendTransaction':
              return raw('eth_sendTransaction', [{ ...params[0], from: account }])
            case 'eth_signTypedData_v4':
              return raw('eth_signTypedData_v4', [account, params[1]])
            case 'personal_sign':
              return raw('personal_sign', [params[0], account])
            default:
              return raw(method, params)
          }
        },
        on: () => {},
        removeListener: () => {},
      }
      ;(window as any).ethereum = provider
    },
    { rpc: RPC, account },
  )
}

// ── anvil time / chain helpers (used from the Node test context) ──────────────
let rpcId = 0
async function rpc(method: string, params: any[] = []) {
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
  })
  const j = await res.json()
  if (j.error) throw new Error(j.error.message)
  return j.result
}

export async function chainNow(): Promise<number> {
  const b = await rpc('eth_getBlockByNumber', ['latest', false])
  return parseInt(b.timestamp, 16)
}

/** Fast-forward the chain clock past `ts` (absolute) with an extra margin. */
export async function warpPast(ts: number) {
  const now = await chainNow()
  await rpc('evm_setNextBlockTimestamp', [Math.max(ts + 2, now + 1)])
  await rpc('evm_mine', [])
}

/** Fast-forward `seconds` beyond the current head. */
export async function warp(seconds: number) {
  await warpPast((await chainNow()) + seconds)
}