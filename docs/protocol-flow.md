# CollateralRails — Flow of Events & Trust Model

**One-line thesis:** buyers pay sellers *directly* (no escrow); a seller's own
**deposit** is the collateral that refunds a buyer if the seller fails to deliver.
Truth is enforced by **dual cryptographic attestations** (buyer and seller
independently sign the same delivered bytes) and **economic stakes** (lying costs
money), not by a trusted middleman.

---

## 1. Actors & contracts

| Actor | Who they are | On-chain contract they drive |
|---|---|---|
| **Seller** | A service/API provider | `BondedRegistry` (deposit), `ClaimManager` (defend) |
| **Buyer / Agent** | An AI agent (or its operator) buying calls | `PolicyManager` (limits), `SettlementRouter` (pay) |
| **Verifier** | Trusted oracle that checks endpoint ownership (the watcher's key) | `BondedRegistry.verifyEndpoint` |
| **Watcher / Auditor** | Permissionless; earns a bounty for catching non-delivery | `ClaimManager` (file & resolve claims) |

| Contract | Responsibility |
|---|---|
| `BondedRegistry` | Custody of seller **deposits**; identity (unique handle + verified endpoint); reputation; slashing |
| `PolicyManager` | The buyer's spending mandate (per-call cap, total budget, expiry, bonded-only) |
| `SettlementRouter` | Instant payment seller-ward; records each payment + its receipt deadline |
| `ClaimManager` | Disputes: batch claims, defense window, resolution, receipt verification |

---

## 2. Setup (once)

1. **Seller lists.** `registry.register(deposit, handle, endpoint)`
   - Transfers the **deposit** (≥ `MIN_BOND`) into the registry as collateral.
   - Claims a **globally-unique handle** (`handleOwner` mapping) → nobody else can list under that name.
2. **Verifier attests the endpoint.** The verifier fetches
   `https://<endpoint>/.well-known/collateralrails.json`, confirms it returns the
   seller's wallet address, then calls `registry.verifyEndpoint(seller)` →
   sets the on-chain `endpointVerified` flag. *(Anti-impersonation.)*
3. **Buyer sets a policy.** `policy.setPolicy(maxPerCall, budget, expiry, requireBonded, …)`
   — the rules the agent cannot exceed.
4. **Buyer funds the rail.** `router.deposit(amount)` — a prepaid balance the
   agent spends from.

---

## 3. Happy path — a call that is delivered

```
Buyer/Agent            SettlementRouter        BondedRegistry          Seller
    │                        │                       │                   │
    │ 1. (off-chain) call the seller's service ─────────────────────────►│
    │                        │                       │                   │
    │ 2. router.pay(seller, amount, requestHash)     │                   │
    │───────────────────────►│                       │                   │
    │                        │ 3. onPayment(): require openExposure+amt ≤ bond
    │                        │──────────────────────►│  (collateral covers it)
    │                        │ 4. transfer amount ───────────────────────►│  INSTANT, no escrow
    │                        │    emit PaymentSettled(id, …, receiptDeadline)
    │                        │                       │                   │
    │                        │ 5. seller delivers; seller AND buyer each attest │
    │                        │    cm.attest(Attestation, sig)  ◄──seller──│
    │◄──buyer signs & submits cm.attest(Attestation, sig)                 │
    │                        │ 6. hashes match → confirmDelivery():       │
    │                        │    releaseExposure() + confirmed++, done   │
```

- **Step 2 — `pay`:** money goes **straight to the seller**. The buyer is *not*
  escrowed. The router records the payment with a `requestHash` and a
  `receiptDeadline`.
- **Step 3 — the core invariant:** `onPayment` reverts unless
  `openExposure + amount ≤ deposit`. A seller can only take on as much
  unconfirmed work as their deposit can refund. **Collateral always covers the risk.**
- **Step 5 — dual `attest`:** the seller signs an **EIP-712 Attestation** bound to
  `{paymentId, requestHash, responseHash}` and anchors it on-chain before the
  deadline; the buyer independently signs and anchors the **same** commitment.
  When both are on time and `sellerResponseHash == buyerResponseHash`, the payment
  is `DeliveryConfirmed`: exposure is released and a confirmed delivery recorded.
  There is no self-reported timestamp — the on-chain anchor time is authoritative,
  so evidence can't be backdated.

---

## 4. Failure path — a call that is NOT delivered

```
   deadline passes, delivery not confirmed  ──►  payment is claimable
                    │
   Watcher: cm.fileClaim(seller, [paymentIds])   (stakes its own collateral,
                    │                              needs ≥ MIN_BATCH or high-value)
                    ▼
   Seller gets a DEFENSE WINDOW:
        cm.defend(claimId, paymentIds[])          ← clears ONLY payments the seller
                    │                                attested ON TIME (reads committed
                    │                                on-chain state; no new signature)
   cm.resolve(claimId):
        • undefended items  → registry.slash(): refund buyers FROM THE DEPOSIT,
                              pay the watcher's bounty, apply a penalty
        • defended items    → dismissed (seller proved delivery)
        • chronic offenders → delisted (deposit below min OR fail-ratio breached)
```

Refunds are paid **from the seller's deposit** — the buyer gets their money back
without ever having locked it up.

---

## 5. How the protocol keeps everyone honest

### Is the **seller** telling the truth about delivery?
- **Delivery needs BOTH parties to agree.** A confirmed delivery requires a
  seller-signed **and** a buyer-signed EIP-712 attestation of the **same response
  hash**, each anchored on time. One side can't self-certify; the signatures are
  verified on-chain and can't be forged or replayed onto another payment.
- **No late fabrication.** `defend()` reads only attestations committed on-chain
  before the deadline — a seller cannot wait for a claim and then produce a
  retroactive signature. On-time on-chain anchoring is the authoritative timestamp.
- **Silence is a provable failure.** No confirmed delivery by the deadline → the
  payment is objectively claimable. The seller can't "do nothing" and keep the money.
- **Lying costs the deposit.** Non-delivery → slash → buyer refunded from the
  seller's collateral + penalty. Delivering is the only profitable strategy.
- **Reputation is earned, not bought.** `reputation()` is computed purely from
  *confirmed* deliveries; the deposit is deliberately excluded, so a fresh /
  sybil account is always tier **New** regardless of how much it stakes.

### Is the **buyer** (or watcher) telling the truth about non-delivery?
- **A refund requires the *absence* of a valid receipt.** If the seller
  delivered and anchored (or can `defend` with) a signed receipt, the claim is
  dismissed and the buyer gets **nothing**. The seller's signature is objective
  proof that overrides any dishonest "it never arrived" claim.
- **False disputes are punished.** A watcher must **stake collateral** to file a
  claim; if the seller defends successfully, that stake is **forfeited to the
  seller**. Frivolous or malicious claims lose money.
- **No escrow to game.** The buyer never controls the seller's funds, so there is
  nothing for a dishonest buyer to withhold or claw back outside this process.

### Is the seller **who they claim to be?**
- **Unique handle** — the registry rejects a duplicate name (`HandleTaken`), so
  no one can list as your brand.
- **Verified endpoint** — the ✓ badge means the verifier confirmed the lister
  controls the real service endpoint (proof-of-control via `.well-known`).

---

## 6. Trust boundaries — what this does *not* guarantee

- It proves buyer and seller **agree on the same response bytes**, not the
  **quality/correctness** of that response. Matching hashes attest "we both saw
  this exact answer," not "the answer was good." Content-quality arbitration is
  out of scope.
- The **verifier** is a trusted role for endpoint attestation (it bridges the
  off-chain web to the chain). Everything else — payment, receipts, disputes,
  slashing — is trustless and enforced by the contracts.
- Timing (receipt window, defense window, cooldown) is configured per deployment.

---

## 7. Function-call cheat sheet

| Event | Caller | Call |
|---|---|---|
| List a service | Seller | `registry.register(deposit, handle, endpoint)` |
| Verify endpoint | Verifier | `registry.verifyEndpoint(seller)` |
| Set spending limits | Buyer | `policy.setPolicy(cap, budget, expiry, requireBonded, …)` |
| Fund prepaid balance | Buyer | `router.deposit(amount)` |
| Pay for a call | Buyer/Agent | `router.pay(seller, amount, requestHash)` |
| Attest delivery (both sides) | Seller & Buyer | `cm.attest(Attestation, sig)` |
| Open a dispute | Watcher | `cm.fileClaim(seller, paymentIds[])` |
| Defend (committed evidence) | Seller | `cm.defend(claimId, paymentIds[])` |
| Settle a dispute | Anyone | `cm.resolve(claimId)` → `registry.slash(...)` |
| Exit + reclaim deposit | Seller | `registry.requestWithdrawal()` → `executeWithdrawal()` |
