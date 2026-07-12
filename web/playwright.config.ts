import { defineConfig, devices } from '@playwright/test'

// E2E runs against the LOCAL anvil deployment. global-setup resets + deploys a
// fresh chain, then these specs drive the real UI through each use case with a
// mock wallet (see e2e/wallet.ts). Screenshots + an HTML report visualise them.
const PORT = Number(process.env.E2E_PORT || 3100)

export default defineConfig({
  testDir: './e2e',
  globalSetup: './e2e/global-setup.ts',
  // Shared chain state accumulates across the scenario, so run one worker in order.
  workers: 1,
  fullyParallel: false,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { outputFolder: 'e2e/report', open: 'never' }]],
  outputDir: 'e2e/results',
  use: {
    baseURL: `http://localhost:${PORT}`,
    channel: 'chrome', // use system Google Chrome — no browser download needed
    headless: true,
    launchOptions: { args: ['--no-sandbox'] },
    screenshot: 'on',
    video: 'retain-on-failure',
    trace: 'on',
    viewport: { width: 1360, height: 1000 },
  },
  projects: [{ name: 'scenario', use: { ...devices['Desktop Chrome'], channel: 'chrome' } }],
  webServer: {
    command: `npm run dev -- --port ${PORT}`,
    url: `http://localhost:${PORT}`,
    reuseExistingServer: true,
    timeout: 120_000,
  },
})