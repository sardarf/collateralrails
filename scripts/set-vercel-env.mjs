#!/usr/bin/env node
// Push the frontend's NUXT_PUBLIC_* variables for a deployment into Vercel, so a
// Vercel build connects to the right chain + contracts automatically.
//
//   node scripts/set-vercel-env.mjs <chainId> <network> [environment=production]
//
// Options via env:
//   WEB_RPC        override the browser RPC (else the network preset's public RPC)
//   VERCEL_CWD     directory linked to the Vercel project (default: ./web)
//   PRINT_ONLY=1   just print the values (paste into the Vercel dashboard yourself)
//
// Prereqs for the push: `vercel login` and `vercel link` (once, in the web dir).
import { execFileSync, spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { ROOT, readDeployment, nuxtEnv } from './deployment.mjs'

const chainId = process.argv[2]
const network = process.argv[3]
const environment = process.argv[4] || 'production'
if (!chainId || !network) {
  console.error('usage: node scripts/set-vercel-env.mjs <chainId> <network> [environment]')
  process.exit(1)
}

const cwd = process.env.VERCEL_CWD || join(ROOT, 'web')
const addr = readDeployment(chainId)
const env = nuxtEnv({ network, rpc: process.env.WEB_RPC || '', addr })

console.log(`Frontend env for ${network} (chain ${chainId}), target: ${environment}`)
for (const [k, v] of Object.entries(env)) console.log(`  ${k}=${v || '(blank → preset default)'}`)

if (process.env.PRINT_ONLY === '1') {
  console.log('\nPRINT_ONLY set — nothing pushed. Add these in Vercel → Settings → Environment Variables.')
  process.exit(0)
}

const vercel = (args, input) =>
  spawnSync('vercel', args, { cwd, input, stdio: ['pipe', 'inherit', 'inherit'], encoding: 'utf8' })

try {
  execFileSync('vercel', ['--version'], { stdio: 'ignore' })
} catch {
  console.error('\nvercel CLI not found. Install with `npm i -g vercel`, then `vercel login` + `vercel link` in web/.')
  process.exit(1)
}

console.log('\nPushing to Vercel…')
for (const [k, v] of Object.entries(env)) {
  // Replace any existing value: remove (ignore "not found"), then add.
  vercel(['env', 'rm', k, environment, '-y'])
  const res = vercel(['env', 'add', k, environment], (v || '') + '\n')
  console.log(res.status === 0 ? `  ✓ ${k}` : `  ✗ ${k} (exit ${res.status})`)
}
console.log('\nDone. Redeploy so the new env takes effect: (cd web && vercel deploy --prod)')