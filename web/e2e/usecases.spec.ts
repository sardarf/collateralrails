// End-to-end scenario, driven through the REAL UI with a mock wallet.
// Covers the full CollateralRails V2 lifecycle: bonding, policy + payment, DUAL
// delivery attestation (seller + buyer), and a watcher batch claim → slash.
// Runs serially against one fresh anvil chain (see global-setup.ts).
import { test, expect, Page } from '@playwright/test'
import { useWallet, ACCOUNTS, warp } from './wallet'

test.describe.configure({ mode: 'serial' })

// On-chain handles are entered at registration; the UI renders them through the
// provider-name map (app/config/display.js), so assertions use the display names.
const HONEST_NAME = 'Aeris Data Network'     // handle: WeatherOracle
const DEADBEAT_NAME = 'SignalForge Labs'     // handle: AlphaSignals

const shot = (page: Page, name: string) =>
  page.screenshot({ path: `e2e/screenshots/${name}.png`, fullPage: true })

// Wait until the app has read the chain (netpill status dot turns green).
async function ready(page: Page) {
  await expect(page.locator('.netpill .status-dot.ok')).toBeVisible({ timeout: 30_000 })
}

// Connect the injected wallet and wait for the account to show in the top bar.
async function connect(page: Page) {
  await page.getByRole('button', { name: 'Connect wallet' }).click()
  await expect(page.locator('.wallet-addr')).toBeVisible({ timeout: 20_000 })
}

// Click a button and wait for the tx log to confirm (its label + ✓).
async function act(page: Page, button: string | RegExp, doneText: string | RegExp) {
  await page.getByRole('button', { name: button }).first().click()
  await expect(page.locator('.txlog').first()).toContainText(doneText, { timeout: 60_000 })
}

async function registerSeller(page: Page, account: string, handle: string, displayName: string) {
  await useWallet(page, account)
  await page.goto('/sell')
  await ready(page)
  await connect(page)
  await act(page, 'Get 1000 test USD', 'Mint 1000 mUSDC ✓')
  await act(page, 'Allow bond', 'Approve registry ✓')
  await page.locator('label:has-text("Service name / handle") input').fill(handle)
  await page.locator('label:has-text("Endpoint URL") input').fill(`https://${handle.toLowerCase()}.example`)
  await page.locator('label:has-text("Bond (USD") input').fill('500')
  await act(page, 'Place bond & list service', 'Place deposit & list service ✓')
  // seller dashboard now shows this service under its display name
  await expect(page.locator('.card-title', { hasText: displayName })).toBeVisible({ timeout: 20_000 })
}

test('use case 1 — reliable seller posts a performance bond', async ({ page }) => {
  await registerSeller(page, ACCOUNTS.sellerHonest, 'WeatherOracle', HONEST_NAME)
  await shot(page, '01-seller-registers')
})

test('use case 2 — a second seller joins the registry', async ({ page }) => {
  await registerSeller(page, ACCOUNTS.sellerDeadbeat, 'AlphaSignals', DEADBEAT_NAME)
  await page.goto('/sellers')
  await ready(page)
  await expect(page.locator('.grid-cards')).toContainText(HONEST_NAME)
  await expect(page.locator('.grid-cards')).toContainText(DEADBEAT_NAME)
  await shot(page, '02-directory-two-sellers')
})

test('use case 3 — agent sets a policy, funds a rail, and pays', async ({ page }) => {
  await useWallet(page, ACCOUNTS.buyer)
  await page.goto('/agent')
  await ready(page)
  await connect(page)

  await act(page, 'Get 100 test USD', 'Mint 100 mUSDC ✓')
  await act(page, 'Allow spending', 'Approve router ✓')
  await act(page, 'Add $50 to balance', 'Fund balance ✓')
  await act(page, 'Save policy', 'Set policy ✓')

  // 3 x $0.10 to SignalForge Labs (left unattested → claimable later)
  await expect(page.locator('select option', { hasText: DEADBEAT_NAME })).toBeAttached({ timeout: 20_000 })
  await page.locator('select').selectOption(ACCOUNTS.sellerDeadbeat)
  await page.locator('label:has-text("Price") input').fill('0.1')
  await page.locator('label:has-text("How many") input').fill('3')
  await act(page, /Pay for .* service call/, /Pay \$0\.1/)
  await expect(page.locator('.card:has-text("Your payments") tbody tr')).toHaveCount(3, { timeout: 60_000 })

  // 1 x $0.10 to Aeris Data Network (payment #4 — confirmed in use case 4)
  await page.locator('select').selectOption(ACCOUNTS.sellerHonest)
  await page.locator('label:has-text("How many") input').fill('1')
  await act(page, /Pay for .* service call/, /Pay \$0\.1/)
  await expect(page.locator('.card:has-text("Your payments") tbody tr')).toHaveCount(4, { timeout: 60_000 })
  await shot(page, '03-agent-pays')
})

test('use case 4 — dual attestation confirms delivery (seller + buyer)', async ({ page }) => {
  // seller signs its side
  await useWallet(page, ACCOUNTS.sellerHonest)
  await page.goto('/sell')
  await ready(page)
  await connect(page)
  const obligations = page.locator('.card:has-text("Deliveries to attest") tbody tr')
  await expect(obligations).toHaveCount(1, { timeout: 20_000 })
  await act(page, 'Sign delivery attestation', /Attest delivery #4/)
  await expect(obligations.first()).toContainText('awaiting buyer', { timeout: 20_000 })
  await shot(page, '04a-seller-attests')

  // buyer confirms receipt with the SAME bytes -> Delivered
  await useWallet(page, ACCOUNTS.buyer)
  await page.goto('/agent')
  await ready(page)
  await connect(page)
  // payments are sorted newest-first, so the first "Confirm receipt" is #4 (Aeris Data Network)
  await act(page, 'Confirm receipt', /Attest delivery #4/)
  await expect(page.getByText('Delivered').first()).toBeVisible({ timeout: 20_000 })
  await shot(page, '04b-delivery-confirmed')
})

test('use case 5 — watcher batch-claims the failures and slashes the bond', async ({ page }) => {
  // Receipt deadlines (60s) expire — SignalForge Labs' 3 payments are now claimable.
  await warp(65)
  await useWallet(page, ACCOUNTS.watcher)
  await page.goto('/watchtower')
  await ready(page)
  await connect(page)

  await act(page, 'Get 100 test USD', 'Mint 100 mUSDC ✓')
  await act(page, 'Approve watcher bond', 'Approve claims ✓')

  const overdue = page.locator('.card:has-text("Overdue deliveries")')
  await expect(overdue).toContainText(DEADBEAT_NAME, { timeout: 20_000 })
  await act(page, /File claim/, /File batch claim/)
  await expect(page.locator('.card:has-text("Open claims")')).toContainText(DEADBEAT_NAME, { timeout: 20_000 })
  await shot(page, '05a-claim-filed')

  // Defense window (60s) elapses with no committed evidence — resolve to slash.
  await warp(65)
  await page.reload()
  await ready(page)
  await connect(page)
  await act(page, /Refund buyers and penalize provider/, 'Resolve claim #1 ✓')
  await expect(page.locator('.card:has-text("Penalty history")')).toContainText('Penalized', { timeout: 20_000 })
  await shot(page, '05b-slashed')

  // Registry now shows SignalForge Labs delisted.
  await page.goto('/sellers')
  await ready(page)
  await expect(page.locator('.scard', { hasText: DEADBEAT_NAME })).toContainText('Delisted', { timeout: 20_000 })
  await shot(page, '06-directory-final')
})