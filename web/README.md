# CollateralRails web (Nuxt 4)

Bond-paper design system, seven screens:
- **Home** (`/`) — landing: hero, the x402 gap, persistent-collateral model, the
  transaction lifecycle, dual attestation + claims, live stats, directory preview, CTAs.
- **Sellers** (`/sellers`) — searchable/sortable/filterable seller directory of cards;
  each links to a detailed **profile** (`/seller/[address]`) of protocol-generated metrics.
- **Buy** (`/agent`) — bounded-agency policy, funding, bonded-only seller picker,
  micropayment purchases, and a per-payment transaction timeline with **Confirm receipt**
  (buyer-side EIP-712 attestation).
- **Sell** (`/sell`) — guided onboarding + Seller board: bond/exposure/capacity, **Sign
  delivery** (seller-side attestation), disputes with evidence-based **Defend**, top-up, exit.
- **Disputes** (`/watchtower`) — per-seller failure aggregation, batch/high-value eligibility,
  staked claim filing, defence-window countdowns, resolve, penalty history.
- **Scenarios** (`/scenarios`) — the nine reproducible demo walkthroughs.

Delivery is confirmed by a **dual attestation**: the seller and the buyer independently sign
the same response hash (EIP-712 via wallet). Matching hashes ⇒ confirmed; refunds always come
from the seller's performance bond, never buyer escrow.

## Networks

The app targets **one** chain, chosen with `NUXT_PUBLIC_NETWORK`. Presets live in
[`app/config/networks.js`](app/config/networks.js) — each carries the chain id, name,
native currency, public RPC and block explorer:

| `NUXT_PUBLIC_NETWORK` | Chain               | id     |
|-----------------------|---------------------|--------|
| `local` (default)     | Anvil / Foundry     | 31337  |
| `arbitrumSepolia`     | Arbitrum Sepolia    | 421614 |
| `arbitrum`            | Arbitrum One        | 42161  |
| `avalancheFuji`       | Avalanche Fuji      | 43113  |
| `avalanche`           | Avalanche C-Chain   | 43114  |

Everything else (RPC, contract addresses, deploy block) falls back to the preset and is
overridable via `NUXT_PUBLIC_*` env vars. See [`.env.example`](.env.example).

## Run locally (anvil)
```bash
npm install
npm run dev            # defaults to NUXT_PUBLIC_NETWORK=local, anvil addresses baked in
```
Wallet: any injected EIP-1193 provider (MetaMask). Import the well-known anvil keys used
by `watcher/src/demo.mjs`. State is polled every 4s from chain logs; no backend required.

## Deploy to a testnet/mainnet + Vercel
1. Deploy the contracts and copy the five printed addresses:
   ```bash
   cd ../smart-contracts
   forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --verify
   ```
2. In **Vercel → Project → Settings → Environment Variables**, set:
   - `NUXT_PUBLIC_NETWORK` = `arbitrumSepolia` (or the target above)
   - `NUXT_PUBLIC_USDC` / `NUXT_PUBLIC_REGISTRY` / `NUXT_PUBLIC_POLICY` /
     `NUXT_PUBLIC_ROUTER` / `NUXT_PUBLIC_CM` = the deployed addresses
   - `NUXT_PUBLIC_DEPLOY_BLOCK` = the block the contracts were deployed at
   - *(optional)* `NUXT_PUBLIC_RPC` = a private RPC (Alchemy/Infura) for reliability
3. Redeploy. The header shows the active chain name and the wallet is prompted to switch
   to it on connect.
