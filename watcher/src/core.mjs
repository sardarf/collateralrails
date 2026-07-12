// WatcherCore — pure decision logic, no chain dependency.
// Tracks receipt obligations, aggregates per-seller failures, decides when a
// batch claim is due, and when open claims are resolvable.
//
// The chain adapter feeds it events; it returns actions. This separation lets
// the same logic run against Arbitrum Sepolia (ethers adapter) or an
// in-process EVM (selftest).

export class WatcherCore {
  /**
   * @param {object} cfg { minBatch, highValueThreshold, claimWindow }
   */
  constructor(cfg) {
    this.cfg = cfg;
    // paymentId -> { seller, buyer, amount, deadline, status }
    this.payments = new Map();
    // claimId -> { seller, paymentIds, defenseEnd, resolved }
    this.claims = new Map();
  }

  // ---------------------------------------------------------------- inputs

  onPaymentSettled({ paymentId, seller, buyer, amount, receiptDeadline }) {
    this.payments.set(String(paymentId), {
      seller: seller.toLowerCase(),
      buyer,
      amount: BigInt(amount),
      deadline: Number(receiptDeadline),
      status: "settled",
    });
  }

  onStatusChanged({ paymentId, status }) {
    // mirror SettlementRouter.Status:
    // 1 Settled 2 SellerAttested 3 BuyerAttested 4 DeliveryConfirmed
    // 5 HashMismatch 6 Claimed 7 Refunded 8 Released
    const map = {
      1: "settled",
      2: "sellerAttested",
      3: "buyerAttested",
      4: "confirmed",
      5: "hashMismatch",
      6: "claimed",
      7: "refunded",
      8: "released",
    };
    const p = this.payments.get(String(paymentId));
    if (p && map[status]) p.status = map[status];
  }

  onClaimFiled({ claimId, seller, paymentIds, defenseEnd }) {
    this.claims.set(String(claimId), {
      seller: seller.toLowerCase(),
      paymentIds: paymentIds.map(String),
      defenseEnd: Number(defenseEnd),
      resolved: false,
    });
    for (const id of paymentIds) {
      const p = this.payments.get(String(id));
      if (p) p.status = "claimed";
    }
  }

  onClaimResolved({ claimId }) {
    const c = this.claims.get(String(claimId));
    if (c) c.resolved = true;
  }

  // --------------------------------------------------------------- queries

  // Statuses a rational watcher will claim after the deadline: no confirmed
  // delivery AND no defensible on-time seller evidence. A "sellerAttested"
  // payment is deliberately excluded — the seller committed evidence on time
  // and would defend, forfeiting the watcher's stake. A "hashMismatch" IS
  // claimable because a contradicting buyer attestation blocks the defense.
  static CLAIMABLE = new Set(["settled", "buyerAttested", "hashMismatch"]);

  /** Deadline-expired, unconfirmed, still-claimable payments grouped per seller. */
  failuresBySeller(now) {
    const bySeller = new Map();
    for (const [id, p] of this.payments) {
      if (!WatcherCore.CLAIMABLE.has(p.status)) continue;
      if (now <= p.deadline) continue; // not yet failed
      if (now > p.deadline + this.cfg.claimWindow) continue; // claim window closed
      if (!bySeller.has(p.seller)) bySeller.set(p.seller, []);
      bySeller.get(p.seller).push({ id, ...p });
    }
    return bySeller;
  }

  /** Batch claims that are due right now: [{ seller, paymentIds, refundTotal }] */
  dueClaims(now) {
    const out = [];
    for (const [seller, fails] of this.failuresBySeller(now)) {
      const refundTotal = fails.reduce((a, f) => a + f.amount, 0n);
      const isBatch = fails.length >= this.cfg.minBatch;
      const isHighValue = refundTotal >= this.cfg.highValueThreshold;
      if (isBatch || isHighValue) {
        out.push({ seller, paymentIds: fails.map((f) => f.id), refundTotal });
      }
    }
    return out;
  }

  /** Open claims whose defense window has ended: [claimId] */
  resolvable(now) {
    const out = [];
    for (const [id, c] of this.claims) {
      if (!c.resolved && now > c.defenseEnd) out.push(id);
    }
    return out;
  }

  status(now) {
    const awaiting = new Set(["settled", "sellerAttested", "buyerAttested"]);
    const pending = [...this.payments.values()].filter((p) => awaiting.has(p.status));
    return {
      tracked: this.payments.size,
      awaitingReceipt: pending.filter((p) => now <= p.deadline).length,
      failed: [...this.failuresBySeller(now).values()].flat().length,
      dueClaims: this.dueClaims(now).length,
      openClaims: [...this.claims.values()].filter((c) => !c.resolved).length,
      resolvable: this.resolvable(now).length,
    };
  }
}
