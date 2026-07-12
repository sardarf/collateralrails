# Limitations (honest scope)

- **What the protocol proves:** that the seller and the buyer independently
  committed, on time, to the **same response bytes** (a matching dual
  attestation), or that they did not. It does **not** verify response *content*:
  correctness, quality, authenticity or external truth. That is Tier-2
  spec-graded evaluation, interface-compatible and intentionally out of scope.
- **On-time anchoring closes late fabrication.** Attestations must be anchored
  on-chain on or before the receipt deadline; the authoritative timestamp is the
  block time of anchoring, not a self-reported field. A defence reads only this
  pre-committed on-chain evidence, so a seller **cannot** wait for a claim and
  then retroactively fabricate a delivery attestation. (V1's `deliveredAt`
  self-report — which allowed exactly that — has been removed. See
  `test_LateFabricatedDefenceIsImpossible`.)
- **Content disputes are resolved conservatively, not adjudicated.** A buyer can
  sign a deliberately different hash to force a `HashMismatch`. The protocol
  treats a contradicting on-time buyer attestation as blocking the seller's
  defence (buyer-protective) and flags the case for off-chain resolution; it does
  not decide who is objectively right.
- **x402 is simulated.** The router reproduces the economic shape (instant
  machine payment bound to a request commitment); full protocol integration is a
  post-event milestone.
- **Agent authorization is minimal:** buyer-approved agents spend the buyer's
  router balance under the buyer's policy (`approveAgent` + `payForBuyer`).
  No session keys, no per-agent sub-budgets.
- Mock USDC (open mint), demo timing profiles, no underwriting, no
  upgradability/governance, no production compliance/KYC. Terminology is
  "performance bond" / "settlement assurance", never insurance or custody;
  jurisdictional review is a production item.