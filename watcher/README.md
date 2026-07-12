# CollateralRails Watcher (minimal CLI)

Permissionless watcher: indexes `PaymentSettled` events, tracks receipt
deadlines, aggregates per-seller failures, files ONE batch claim per seller,
and resolves claims after the defense window. The slash penalty share pays for
the service. JSON-file persistence, no database, no API (REST enrichment is a
deliberate nice-to-have, not built).

Delivery is confirmed by a **dual attestation** — the seller and the buyer each
sign the same response hash (EIP-712), anchored on time. The watcher deliberately
skips seller-attested payments (defensible) and claims only unconfirmed ones.
Refunds are paid **from the seller's performance bond — buyer funds are never escrowed**.

## Layout
- `src/core.mjs` — pure decision logic (chain-agnostic, selftested)
- `src/cli.mjs` — `watch` / `status` commands against any RPC
- `src/verifier.mjs` — endpoint-ownership oracle: verifies each seller controls
  its endpoint (serves `/.well-known/collateralrails.json` with its address),
  then writes `registry.verifyEndpoint()` on-chain. Run with the key set as the
  registry verifier. `DEMO_VERIFY=1` skips the HTTP check for local demos.
- `src/seller.mjs` — `honest` (signs & anchors its seller-side attestation) / `deadbeat` sims
- `src/agent.mjs` — buyer policy + micropayment flow
- `src/demo.mjs` — full 5-act story against local anvil (time-warps)
- `src/selftest.mjs` — runs the story on an in-process EVM feeding REAL
  contract logs into WatcherCore (run from repo root)

## Run
```bash
npm install
cp deployment.example.json deployment.json   # fill from deploy output

# watch a live deployment
RPC=... PRIVATE_KEY=0x... npm run watch

# local full demo
anvil &
( cd ../smart-contracts && forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast )
npm run demo:full

# verify watcher logic without any node
cd .. && ( cd smart-contracts && SAVE=1 node compile.js src/*.sol ) && node watcher/src/selftest.mjs
```
