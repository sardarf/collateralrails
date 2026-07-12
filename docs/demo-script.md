# Local demo (anvil)

## One command (recommended)

```bash
./dev-local.sh            # start anvil · deploy · wire web/.env + watcher · seed the 5-act story
./dev-local.sh --reset    # same, but on a fresh chain
./dev-local.sh --no-seed  # boot + deploy only (empty registry)
```

This starts anvil, deploys the five contracts, writes the deployed addresses into
`web/.env` and `watcher/deployment.json` (via `scripts/wire-env.mjs`), and seeds the
full 5-act story (2 sellers, 10 × $0.10 payments, honest attestations, batch claim,
slash + refund + delist). Then start the frontend:

```bash
cd web && npm install && npm run dev   # reads web/.env — already wired to local anvil
```

## Manual steps (equivalent)

```bash
# 1. chain + contracts
anvil &
cd smart-contracts
cp .env.example .env            # set PRIVATE_KEY to an anvil key
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
cd ..

# 2. point the watcher at the deployment
cd watcher && npm install
cp deployment.example.json deployment.json   # fill the 5 addresses from step 1

# 3. full 5-act story (registers 2 sellers, 10 x $0.10 payments, honest
#    attestations, batch claim, slash + refund + delist)
npm run demo:full

# 4. optional: live watcher + simulators in separate terminals
RPC=http://localhost:8545 PRIVATE_KEY=<watcher key> npm run watch
RPC=http://localhost:8545 PRIVATE_KEY=<seller key>  npm run demo:honest
RPC=http://localhost:8545 PRIVATE_KEY=<seller key>  npm run demo:deadbeat
SELLER=<addr> RPC=... PRIVATE_KEY=<buyer key>       npm run demo:agent

# 5. frontend — web/.env is written by scripts/wire-env.mjs (run by dev-local.sh),
#    or copy web/.env.example and fill the 5 addresses. See web/README.md for
#    selecting a network (local | arbitrumSepolia | arbitrum | avalancheFuji | avalanche).
cd ../web && npm install && npm run dev
```

No Foundry? Verify contracts + flows without any node:
`(cd smart-contracts && npm install && SAVE=1 node compile.js src/*.sol && node e2e.mjs) && (cd watcher && npm install) && node watcher/src/selftest.mjs`
