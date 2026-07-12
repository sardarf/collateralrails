# Architecture

Four contracts + one library. Refunds are paid from the SELLER'S PERFORMANCE
BOND; buyer funds are never escrowed.

```
buyer/agent ──pay/payForBuyer──► SettlementRouter ──instant transfer──► seller
     │                                │  (payment record: id, buyer, seller,
     │ policy                         │   amount, requestHash, deadline, status;
     ▼                                │   agentOf[id] if agent-initiated)
PolicyManager ◄──checkAndConsume──────┘
                                      │ exposure += amount (must stay ≤ bond)
                                      ▼
seller ─┐                             │
buyer  ─┴─ EIP-712 Attestation ──► ClaimManager
                                      │  both anchored on time + hashes match
                                      ├──► confirmDelivery ──► exposure freed, confirmed++
                                      │  hashes differ ──► markMismatch
watcher ──fileClaim(batch)──────► ClaimManager ──defence window──► resolve
                                      │ defence = seller's ON-TIME committed
                                      │ attestation only (no new signature)
                                      │ slash survivors
                                      ▼
                               BondedRegistry (bond custody, reputation,
                               delisting, withdrawal discipline)
```

Flow: (1) seller stakes into `BondedRegistry` and is listed; (2) buyer sets a
policy and funds a router balance; optionally `approveAgent` so an agent can
`payForBuyer` without holding the buyer key; (3) `pay` settles instantly to the
seller and records a delivery obligation; (4) the seller and the buyer each
anchor an EIP-712 `Attestation` on-chain before the receipt deadline — when both
are on time and `sellerResponseHash == buyerResponseHash` the payment is
`DeliveryConfirmed`, exposure is freed and a confirmed delivery is recorded;
(5) a watcher batches deadline-expired, unconfirmed payments into one staked
claim; (6) the seller may defend only payments it committed evidence for on time
(`defend()` reads pre-committed on-chain state — no new signature is accepted, so
late fabrication is impossible); (7) `resolve` slashes survivors: buyers refunded
from the bond, watcher bounty paid, reputation updated, chronic offenders
delisted.

Status machine (`SettlementRouter.Status`):
`Settled → SellerAttested | BuyerAttested → DeliveryConfirmed | HashMismatch →
Claimed → Refunded | Released`. `Evidence incomplete` and `Claimable` are derived
from the stored status plus deadlines.

Invariants: exposure ≤ bond at all times; on-time on-chain anchoring is the
authoritative delivery-evidence timestamp; no slash before the defence window
ends; a fully defended claim forfeits the watcher stake to the seller; withdrawal
requires cooldown + zero open claims + zero open exposure.