# CollateralRails V2 — Testing Playbook

Step-by-step manual test guide, driven through the web UI. Follow it top to bottom; each
scenario builds on the previous one. For the full list of scenarios (including hash mismatch,
exposure limit, high-value claim, bond replenishment) see the in-app **Scenarios** tab.

> **Core idea:** sellers stake a **persistent performance bond** to be trusted by AI agents.
> Payments settle **instantly** — nothing is escrowed. Delivery is proven by a **dual
> attestation**: the seller and the buyer independently sign the **same response bytes**, and a
> match confirms the delivery. If a seller fails to deliver, buyers are refunded **from the
> seller's bond**, aggregated by a watcher into one batch claim after a defence window.

---

## 0. Setup

```bash
./dev-local.sh --reset --no-seed      # fresh anvil + contracts, empty registry
cd web && npm install && npm run dev  # app on http://localhost:3000
```

> To watch a finished example instead of doing the steps, run `./dev-local.sh --reset`
> (seeds the whole story), then reload.

**MetaMask:** add network `http://127.0.0.1:8545`, chain `31337` (the app also offers to add it
on **Connect wallet**). Import the demo keys below; the **Balances** bar labels whichever one
you're connected as. Switch roles by switching the active account in MetaMask.

| Role | Address | Private key |
|------|---------|-------------|
| **Seller · reliable** (WeatherOracle) | `0x7099…79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| **Seller · unreliable** (AlphaSignals) | `0x3C44…93BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |
| **Buyer / Agent** | `0x90F7…b906` | `0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6` |
| **Watcher** | `0x15d3…6A65` | `0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a` |
| Deployer (rarely needed) | `0xf39F…2266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |

**Timing (demo profile):** receipt window **60s** · defence window **60s** · withdrawal
cooldown **120s** · min batch **3** (or a single payment ≥ $50). Countdowns are shown live.

---

## Scenario 1 — Seller onboarding (post a performance bond)

**Connect as:** Seller · reliable (`0x7099…79C8`) · **Tab:** Sell

1. **Connect wallet**, approve the network switch.
2. Step 1: **Get 1000 test mUSDC**, then **Allow deposit** (approve each in MetaMask).
3. Step 2: fill **Service name / handle** = `WeatherOracle`, **Endpoint URL** = `https://weatheroracle.example`.
4. Step 3: keep **Deposit** = `500` → **Place deposit & list service** → approve.

✅ **Expect:** the page switches to your **Seller board** showing `WeatherOracle`, bond `500`,
capacity meter, status **Active**. In **Sellers** the service appears as a card.

**Repeat as the unreliable seller** (`0x3C44…93BC`) with handle `AlphaSignals` — someone to slash later.

---

## Scenario 2 — Agent pays under a spending policy (instant settlement)

**Connect as:** Buyer / Agent (`0x90F7…b906`) · **Tab:** Buy

1. Step 1: **Get 100 test mUSDC** → **Allow spending** → **Add $50 to balance** (approve each).
2. Step 2: set **Max per call** `0.2`, **Budget** `500`, **Expires** `30`, keep **Require bonded
   seller** → **Save policy** → approve.
3. Step 3: **Seller** = `AlphaSignals`, **Price** `0.1`, **How many** `3` → **Buy 3 call(s)** → approve each.
4. Then **Seller** = `WeatherOracle`, **How many** `1` → **Buy 1 call(s)** → approve.

✅ **Expect:** the payments table lists 4 rows, each with a lifecycle timeline (Paid →
awaiting attestations) and a countdown. Each seller's **Wallet** rose instantly — money is
*not* escrowed. On **Sellers**, both sellers now show open exposure > 0 (collateralised by bond).

---

## Scenario 3 — Happy path: dual attestation confirms delivery

**Step A — Seller signs.** Connect as Seller · reliable (`0x7099…79C8`) · **Tab:** Sell

1. Under **Deliveries to confirm**, the WeatherOracle payment shows a countdown. **Before it
   hits 0s**, click **Sign delivery** → sign the EIP-712 typed data in MetaMask.

✅ **Expect:** the row shows **signed · awaiting buyer**; the seller's exposure is *not* yet
released (a one-sided attestation isn't a confirmed delivery).

**Step B — Buyer confirms.** Connect as Buyer (`0x90F7…b906`) · **Tab:** Buy

2. On the same payment (#4), click **Confirm receipt** → sign the matching typed data.

✅ **Expect:** the lifecycle timeline reaches **Delivery confirmed** (hashes matched). On the
seller's profile, **Open exposure** returns to 0 and **Confirmed** = 1 — capacity recycled.

---

## Scenario 4 — Failure path: watcher batch-claims and slashes the bond

The unreliable seller's 3 payments go **unconfirmed**. Wait for their receipt deadlines to pass
(~60s from Scenario 2).

**Connect as:** Watcher (`0x15d3…6A65`) · **Tab:** Disputes

1. **Sellers who didn't deliver** lists `AlphaSignals` with **3** overdue payments, refunds
   owed, an estimated stake, and **batch** eligibility.
2. **Get 100 test mUSDC** → **Allow claim stake** (approve each).
3. **File claim (3)** → approve.

✅ **Expect:** an entry in **Open & resolved claims** with a defence countdown. The payments
read **Claim filed**.

4. Wait for the defence countdown to reach **ready**, then **Resolve & apply penalty** → approve.

✅ **Expect:**
- **Penalty history** gains a row: `AlphaSignals` **Penalized**, buyer refunded, penalty, reduced deposit.
- **Sellers:** `AlphaSignals` status flips to **Delisted**.
- Balances bar: the **buyer's Wallet** increased by the refund — **paid from the seller's bond**.

---

## Scenario 5 — Seller defends a claim (false claims cost the watcher)

A bonded seller that committed evidence **on time** defeats a claim, and the watcher forfeits
its stake. This is also where V2's anti-fabrication rule matters: only on-time committed
evidence defends — nothing can be signed retroactively.

1. **As Buyer** (Buy): buy **3 calls** from `WeatherOracle`.
2. **As the reliable Seller** (Sell): under **Deliveries to confirm**, **Sign delivery** on all
   three **before** their deadlines. (The buyer need not confirm.)
3. Let the deadlines pass (~60s).
4. **As Watcher** (Disputes): these payments are listed as **non-claimable** (the seller has
   committed evidence). To demonstrate the defence, file anyway isn't offered — instead observe
   that a rational watcher skips them. *(To force the path, use the seeded `--reset` story or the
   contract test `test_FalseClaimForfeitsStakeToSeller`.)*

✅ **Expect:** payments the seller attested on time are defensible; a fully defended claim
resolves with `refunded = $0` and the **watcher's stake forfeited to the seller**.

---

## Scenario 6 — Withdrawal discipline (no exit before accountability)

**Connect as:** Seller · reliable (`0x7099…79C8`) · **Tab:** Sell

1. Click **Request exit** → approve (starts the 120s cooldown, stops new payments).
2. Immediately click **Withdraw bond**.

✅ **Expect:** it **reverts** if the cooldown hasn't elapsed, there's open exposure, or an open
claim — the board tells you exactly which. Clear everything and wait out the cooldown, then
**Withdraw bond** succeeds and the deposit returns to the wallet.

---

## Resetting between runs

```bash
./dev-local.sh --reset --no-seed   # clean slate, empty registry
./dev-local.sh --reset             # clean slate, pre-seeded finished story
```

## Automated equivalents

- **Contract suite:** `cd smart-contracts && forge test -vvv` (incl. `test_DemoScript`,
  `test_LateFabricatedDefenceIsImpossible`).
- **Runtime story (no Foundry):** `cd smart-contracts && SAVE=1 node compile.js src/*.sol && node e2e.mjs`
- **Watcher selftest:** `node watcher/src/selftest.mjs`
- **Full UI end-to-end (screenshots + report):** `cd web && npm run e2e && npm run e2e:report`
  (drives onboarding → payment → dual attestation → claim → slash through the real UI).