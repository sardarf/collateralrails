# CollateralRails V2

**Collateral-backed trust infrastructure for agentic commerce.**

> x402 makes agent payments possible. CollateralRails makes sellers economically accountable.

---

## 1. Project overview

CollateralRails is a trust and accountability layer that wraps around agent-to-service payments. Sellers stake a
**persistent performance bond** to be discoverable and trusted by autonomous buyers. Payments settle **instantly**
through an x402-shaped rail — nothing is escrowed per call. Delivery is proven by a **dual attestation**: the seller and
the buyer independently sign a commitment to the same delivered response, and a match confirms the delivery. When a paid
obligation is not confirmed, watchers file claims and unrefuted failures **refund buyers from the seller's own bond**.

## 2. Problem

Payment protocols such as x402 let an autonomous agent pay an unknown service provider. They do not answer the questions
that decide whether it *should*:

- Which unknown seller should the agent trust?
- How much collateral backs that seller?
- What is the seller's delivery and failure history?
- What happens if a paid obligation is not completed?
- How can an agent apply machine-readable trust policy **before** paying?

## 3. Solution

CollateralRails provides seller discovery, persistent seller collateral, transaction-capacity enforcement, dual delivery
attestations, claims, refunds from seller bonds, slashing, protocol-generated seller history, and controlled seller exit.

It is **not** an API proxy, an escrow for buyer payments, a replacement for x402, or a universal verifier of the semantic
correctness of every service. The buyer and seller communicate directly; CollateralRails sits in the trust and
accountability lifecycle around that transaction.

## 4. Why x402 alone is insufficient

x402 answers *how does an agent pay* — instantly, directly to the seller. It has no opinion on seller reliability,
capacity, or recourse on failure. CollateralRails supplies exactly that missing layer without replacing the rail: the
payment still settles directly to the seller; the bond, history and claims process provide the accountability.

## 5. Where CollateralRails sits

```
Before payment:     Buyer checks seller bond, SLA, capacity and history.
During transaction: Buyer and seller interact directly using the existing service and payment flow.
After delivery:     Buyer and seller submit cryptographic delivery attestations.
On failure:         Claims, defence, refunds and slashing are handled through CollateralRails.
```

## 6. Persistent seller bond model

A seller deposits a bond **once** and keeps it staked while participating — it is not re-created per transaction. Each
unsettled payment increases the seller's **open exposure**. The protocol enforces one core invariant:

```
Total bond − Open exposure = Available transaction capacity
Open exposure ≤ Seller bond          (enforced at payment time — a payment that would breach it reverts)
```

- Delivery confirmed → exposure decreases, capacity is restored.
- Claim succeeds → buyer refund comes from the bond, a penalty is applied, metrics update, capacity decreases.

## 7. Seller directory and discovery

The landing page and `/sellers` directory expose every seller with searchable, sortable, filterable signals: name,
wallet, category, description, join status, bond, open exposure, available capacity, declared SLA, transaction count,
confirmed deliveries, open/resolved claims, successful defences, refund count, total refunded, slash total, failure
ratio, and status (`Active`, `Capacity Limited`, `Under Claim`, `Exiting`, `Delisted`). Each seller has a detailed
profile page. There are **no subjective star ratings** — history is derived purely from protocol activity and economic
events. Reputation is earned from confirmed deliveries and cannot be bought: a fresh account is always `New`.

## 8. Buyer policy

Buyers configure a machine-readable spending policy the agent must obey (`PolicyManager`): maximum amount per payment,
total budget, expiry, require-bonded-seller, and an optional allowlist. An approved agent can spend the buyer's router
balance under this policy without ever holding the buyer's key (`approveAgent` + `payForBuyer`); refunds always go to the
buyer, never the agent.

## 9. Dual delivery attestations

The single seller-signed receipt of V1 is replaced with a **dual attestation**. The response body stays off-chain; only
cryptographic commitments are stored.

- **Seller attests:** "I produced response hash X for payment Y and request Z."
- **Buyer attests:** "I received response hash X for payment Y and request Z."

Each attestation is an EIP-712 `Attestation(uint256 paymentId, bytes32 requestHash, bytes32 responseHash)` signed by the
respective party and **anchored on-chain before the receipt deadline**. Delivery is **confirmed** only when both are
anchored on time and `sellerResponseHash == buyerResponseHash`. On confirmation the seller's exposure is released and a
confirmed delivery is recorded; the payment can never afterwards be claimed as missing delivery.

> Matching hashes prove that buyer and seller agree on the delivered response **bytes**. They do **not** universally
> prove the semantic correctness, quality, authenticity or external truth of every possible service.

## 10. Claims and defence

If a payment is not confirmed by its deadline, a watcher can aggregate a seller's deadline-expired, unconfirmed payments
into **one batch claim** (min batch size, or a single high-value payment) and posts a stake. The seller gets a **defence
window**.

The defence relies **only on evidence committed on time**. A payment is defensible if and only if the seller anchored a
delivery attestation on-chain **on or before the receipt deadline**, with no contradicting buyer attestation. `defend()`
accepts no new signature — it reads only pre-committed on-chain state. This closes the *fabricated late defence* attack:
a seller can no longer wait for a claim, mint a synthetic response hash, sign it retroactively, and defeat the claim.
(See `test_LateFabricatedDefenceIsImpossible` and the on-time anchoring check in `smart-contracts/e2e.mjs`.)

## 11. Refund and slashing model

After the defence window, `resolve()`:

- Fully defended claim → false claim: the watcher's stake is **forfeited to the seller** (griefing deterrent).
- Surviving failures → the bond is debited: **buyers are refunded from the seller's bond**, a penalty is applied
  (split watcher bounty / treasury), reputation updates, and chronic offenders are delisted above the failure-ratio
  threshold.

**Buyer funds are never escrowed. Refunds come from the seller's persistent performance bond.**

## 12. Watcher incentives

Watchers earn a bounty for surfacing real failures and lose their stake for false claims. The Disputes board shows
claimable failures per seller, batch/high-value eligibility, estimated stake, active claims with defence deadlines,
resolution readiness, and penalty history.

## 13. Seller withdrawal lifecycle

Requesting an exit immediately stops new CR-backed payments and starts a cooldown. Final withdrawal is blocked while
**open exposure exists**, while **any claim is unresolved**, and until the **cooldown ends** — preserving the
no-exit-before-accountability invariant. The Seller board surfaces exactly what is blocking a withdrawal.

## 14. Architecture

```
                    CollateralRails

 Seller Registry   Bond   History   Claims   Slashing
        ▲             ▲      ▲         ▲        ▲
        │             │      │         │        │
        └──────────── Trust and settlement ─────┘

Buyer Agent  ───── direct request/payment ─────► Seller API
Buyer Agent  ◄──────── direct response ───────── Seller API

Buyer attestation ───────────────► CollateralRails
Seller attestation ──────────────► CollateralRails
```

```
buyer/agent ──pay/payForBuyer──► SettlementRouter ──instant transfer──► seller
     │ policy                         │  exposure += amount  (must stay ≤ bond)
     ▼                                │
PolicyManager ◄──checkAndConsume──────┘
seller ─┐                             ▼
buyer  ─┴─ EIP-712 attest ──► ClaimManager ── both match ──► confirmDelivery ─► exposure freed
watcher ── fileClaim(batch) ─► ClaimManager ── defence window (committed evidence only) ─► resolve
                                      │ slash survivors
                                      ▼
                               BondedRegistry (bond custody, reputation, delisting, exit discipline)
```

## 15. Smart contract responsibilities

| Contract | Role |
|---|---|
| `BondedRegistry` | Bond custody, seller registry & identity, reputation, exposure accounting, confirmed-delivery counter, slashing, delisting, withdrawal discipline |
| `SettlementRouter` | Simulated x402 rail: buyer balances, instant settlement, payment records, and the full status machine |
| `ClaimManager` | Dual-attestation verification, delivery confirmation, defended batch claims, evidence-based defence, aggregated slashing, watcher stakes/bounties |
| `PolicyManager` | Buyer-side bounded agency: per-payment cap, budget, expiry, allowlist, bonded-only |
| `ReceiptLib` | EIP-712 `Attestation` typed data (no self-reported timestamp — on-chain anchor time is authoritative) |
| `MockUSDC` | 6-decimal demo token (open mint — demo only) |

## 16. Frontend responsibilities

Nuxt 4 SPA (`web/`): a polished landing page; a searchable/sortable seller directory with per-seller profiles; a guided
seller onboarding + Seller board (delivery attestation, metrics, bond top-up, exit); a buyer flow with dual attestation
and a per-payment transaction timeline; a watcher/disputes board; and a demo scenarios page. The `useProtocol`
composable holds all chain state and actions (viem).

## 17. Transaction states

Stored `SettlementRouter.Status`: `Settled → SellerAttested | BuyerAttested → DeliveryConfirmed | HashMismatch →
Claimed → Refunded | Released`. Time-derived phases (`Evidence incomplete`, `Claimable`) are computed from the stored
status plus deadlines, so no single status carries two meanings. Dispute rules:

| Case | Both attest, match | Neither attests | Seller only | Buyer only | Hashes differ |
|---|---|---|---|---|---|
| Result | **Delivery confirmed** | Claimable | Evidence incomplete (defensible) | Evidence incomplete (not defensible) | Hash mismatch (not defensible) |

The protocol proves whether both parties agree on the same response bytes. It does not decide whether an arbitrary AI
answer, external fact, or digital product is objectively correct.

## 18. Local setup

```bash
# one command: start anvil, deploy, wire web/.env + watcher, seed the demo story
./dev-local.sh                 # --no-seed for an empty registry · --reset for a fresh chain
cd web && npm install && npm run dev
```

MetaMask: add network `http://127.0.0.1:8545` (chain 31337) and import anvil demo keys. Each account's role is labelled
in the app's balances bar.

Contracts only:

```bash
cd smart-contracts
forge build
forge test -vvv            # full suite incl. dual-attestation + anti-late-fabrication tests
```

No Foundry? A runtime harness executes the full story on an in-process EVM with real EIP-712 signatures:

```bash
cd smart-contracts && npm install
SAVE=1 node compile.js src/*.sol && node e2e.mjs
node ../watcher/src/selftest.mjs
```

## 19. Deployment instructions

```bash
cd smart-contracts
cp .env.example .env                                     # fill PRIVATE_KEY etc.
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --verify
node ../scripts/wire-env.mjs <chainId> <network> <rpc>   # wire addresses into web + watcher
```

`deploy-testnet.sh` runs the full contracts → env → Vercel pipeline. The deploy script is chain-agnostic
(constructor-parameterised timing, env-driven RPC); Robinhood Chain-ready config is included and claimed only once
executed.

## 20. Demo accounts and roles

| anvil account | Role | Screen |
|---|---|---|
| #0 `0xf39F…2266` | Owner / deployer | — |
| #1 `0x7099…79C8` | Reliable seller | Sell |
| #2 `0x3C44…93BC` | Unreliable seller | Sell |
| #3 `0x90F7…b906` | Buyer / agent | Buy |
| #4 `0x15d3…6A65` | Watcher | Disputes |

## 21. Full scenario walkthroughs

See the in-app **Scenarios** tab and `docs/DEMO.md`. Covered: (1) successful delivery; (2) missing delivery →
refund+slash; (3) seller attested, buyer missing → evidence incomplete; (4) hash mismatch; (5) exposure limit rejection;
(6) high-value single claim; (7) false claim → stake forfeited; (8) withdrawal blocked then allowed; (9) bond
replenishment. The Playwright suite (`web/e2e`) drives the happy path + failure path through the real UI.

## 22. Security assumptions

- **On-time anchoring is authoritative.** Attestations must be anchored on-chain within the receipt window; the block
  timestamp of anchoring — not a self-reported field — is the record, so evidence cannot be backdated.
- Exposure ≤ bond at all times → refunds are always collateralised.
- No slash before the defence window ends; defence reads only pre-committed evidence.
- False claims forfeit the watcher stake; no exit before accountability (cooldown + zero exposure + zero open claims).
- Replay/duplicate protection on attestations and claims; only the payment's seller/buyer can attest; only the
  ClaimManager drives router status transitions.

## 23. Known limitations

- **x402 is simulated** (the economic shape: instant machine payment bound to a request commitment). Full protocol
  integration is a post-event milestone.
- **Semantic correctness is out of scope.** Matching hashes prove byte-level agreement, not that a service's output is
  objectively correct. A buyer attesting a deliberately different hash to force a mismatch is a content dispute the
  protocol does not adjudicate — it resolves such cases buyer-protectively and flags them for off-chain resolution.
- Mock USDC (open mint), demo timing profiles, no underwriting, no upgradability/governance, no production compliance.
  Terminology is "performance bond" / "settlement assurance", never insurance or custody. See `docs/limitations.md`.

## 24. Future extensions

- Real x402 protocol integration and settlement-token support.
- Tier-2 spec-graded content evaluation for genuine quality/correctness disputes (the claim format is evaluator-ready).
- Session keys and per-agent sub-budgets for richer bounded agency.
- Staged/partial slashing, seller insurance pools, and on-chain governance of economic parameters.

## Repo layout

- `smart-contracts/` — Foundry project: `src/` contracts · `test/` suite · `script/` deploy · `compile.js` + `e2e.mjs`
- `watcher/` — CLI watcher + seller/agent simulators + anvil demo + `selftest.mjs`
- `web/` — Nuxt 4 frontend + Playwright e2e
- `scripts/` — wire broadcast addresses into `web/.env` + `watcher/deployment.json`
- `docs/` — architecture, demo playbook, protocol flow, limitations

## Economic parameters (demo profile)

Min bond 100 mUSDC · receipt window 60s · claim window 24h · defence window 60s · min batch 3 (or single payment
≥ 50 mUSDC) · penalty 20% of refunds (75% watcher / 25% treasury) · claim stake 10% (floor 10) · delist above 20%
failure ratio · withdrawal cooldown 120s (demo) / 7 days (prod).