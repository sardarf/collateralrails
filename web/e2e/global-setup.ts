// Reset + deploy a fresh local anvil chain before the E2E scenario runs, so each
// run starts empty and the specs build up state through the real UI.
// Skip with E2E_SKIP_SETUP=1 (e.g. when anvil is already deployed the way you want).
import { execSync } from 'node:child_process'
import { resolve } from 'node:path'

export default async function globalSetup() {
  if (process.env.E2E_SKIP_SETUP === '1') {
    console.log('[e2e] E2E_SKIP_SETUP=1 — using the running chain as-is')
    return
  }
  const repoRoot = resolve(process.cwd(), '..')
  const PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`
  console.log('[e2e] resetting + deploying a fresh anvil chain (dev-local.sh --reset --no-seed)…')
  execSync('./dev-local.sh --reset --no-seed', {
    cwd: repoRoot,
    stdio: 'inherit',
    env: { ...process.env, PATH },
  })
}