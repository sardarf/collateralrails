# E2E scenario tests (Playwright)

Drives the **real UI** through every use case in `docs/demo-script.md`, using a mock
wallet so no browser extension is needed. Each test performs one use case and saves a
screenshot; Playwright also produces a browsable HTML report with per-step screenshots,
video (on failure) and a trace.

## How the mock wallet works
`e2e/wallet.ts` injects `window.ethereum` before the app loads and forwards every RPC
call to the local anvil node. anvil's default dev accounts are **unlocked**, so it signs
transactions and EIP-712 typed data itself — the mock only decides *which* account is
connected per test. The app runs exactly as it would with MetaMask (connect, pay,
sign & anchor, file claim, resolve).

## Run

```bash
cd web
npm install                 # pulls @playwright/test
npm run e2e                 # resets a fresh anvil chain, then runs the scenario
npm run e2e:report          # open the HTML report (screenshots per step)
```

`npm run e2e` will, via `e2e/global-setup.ts`, run `./dev-local.sh --reset --no-seed`
to deploy a clean chain, then start the app and drive it. Requirements: Foundry (anvil,
forge) on PATH and **Google Chrome** installed (Playwright uses it via `channel: 'chrome'`
— no browser download). No Chrome? run `npx playwright install chromium` and set
`channel` to `undefined` in `playwright.config.ts`.

### Options
- `E2E_SKIP_SETUP=1 npm run e2e` — don't reset the chain; drive whatever is deployed.
- `E2E_PORT=3100` — dev-server port Playwright launches (default 3100).
- `npm run e2e:ui` — Playwright's interactive UI mode (watch it click through, time-travel).

## The scenario (`e2e/usecases.spec.ts`)
1. Honest seller posts a performance bond → **Bonded**
2. A second seller joins the registry
3. Agent sets a policy, funds a rail, pays 3× a bad seller + 1× the honest seller
4. Honest seller anchors an EIP-712 delivery attestation → receipted
5. Watcher batch-claims the expired unattested payments, defense window elapses, resolve
   → bond **slashed**, buyer refunded, seller **Delisted**

Screenshots land in `e2e/screenshots/`; the report in `e2e/report/`.