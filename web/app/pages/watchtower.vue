<template>
  <div>
    <div class="page-head">
      <h1 class="page-title">Recover funds from failed deliveries</h1>
      <p class="page-sub">Unresolved failures refund buyers from provider collateral.</p>
    </div>

    <div class="stats">
      <div class="stat amber"><div class="stat-label">Claimable failures</div><div class="stat-value">{{ totalFailures }}</div><div class="stat-sub">across {{ failures.length }} provider(s)</div></div>
      <div class="stat"><div class="stat-label">Open claims</div><div class="stat-value">{{ openClaimsCount }}</div><div class="stat-sub">{{ resolvable }} ready to resolve</div></div>
      <div class="stat rose"><div class="stat-label">Penalties applied</div><div class="stat-value">{{ fmt(totalSlashed) }}<span class="unit">USD</span></div><div class="stat-sub">{{ state.slashes.length }} time(s)</div></div>
    </div>

    <!-- Overdue deliveries -->
    <div class="card">
      <div class="card-head">
        <span class="card-title">Overdue deliveries</span>
        <div style="margin-left: auto; display: flex; gap: 10px">
          <button class="secondary" :disabled="state.busy" @click="actions.mint(100)">Get 100 test USD</button>
          <button class="secondary" :disabled="state.busy" @click="actions.approveCm">Approve watcher bond <span v-if="cmApproved">✓</span></button>
        </div>
      </div>
      <div class="card-body flush">
        <div class="table-scroll" v-if="failures.length">
          <table class="table">
            <thead><tr><th>Provider</th><th class="num">Overdue</th><th class="num">Refunds owed</th><th class="num">Est. bond</th><th>Eligibility</th><th>Action</th></tr></thead>
            <tbody>
              <tr v-for="f in failures" :key="f.seller">
                <td><NuxtLink :to="`/seller/${f.seller}`" style="color: var(--text)">{{ sellerName(f.seller) }}</NuxtLink></td>
                <td class="num">{{ f.ids.length }}</td>
                <td class="num">${{ fmt(f.total) }}</td>
                <td class="num">${{ fmt(estStake(f.total)) }}</td>
                <td>
                  <span v-if="eligible(f)" class="pill ok"><span class="dot" />{{ f.ids.length >= Number(state.minBatch) ? 'batch' : 'high-value' }}</span>
                  <span v-else class="pill muted">need ≥ {{ state.minBatch }} or ${{ fmt(state.highValue) }}</span>
                </td>
                <td>
                  <button v-if="eligible(f)" class="danger" :disabled="state.busy" @click="actions.fileClaim(f.seller, f.ids)">File claim ({{ f.ids.length }})</button>
                  <span v-else class="pill muted">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-else class="empty">Nothing overdue. Every payment is delivered, still within its deadline, or already defended.</p>
      </div>
    </div>

    <!-- Open claims -->
    <div class="card">
      <div class="card-head"><span class="card-title">Open claims</span></div>
      <div class="card-body flush">
        <div class="table-scroll" v-if="openClaims.length">
          <table class="table">
            <thead><tr><th class="num">#</th><th>Provider</th><th class="num">Payments</th><th class="num">Refunds at stake</th><th>Defense window</th><th>Action</th></tr></thead>
            <tbody>
              <tr v-for="c in openClaims" :key="c.id">
                <td class="num">{{ c.id }}</td>
                <td><NuxtLink :to="`/seller/${c.seller}`" style="color: var(--text)">{{ sellerName(c.seller) }}</NuxtLink></td>
                <td class="num">{{ c.paymentIds.length }} <span class="addr">({{ c.defendedCount }} cleared)</span></td>
                <td class="num">${{ fmt(c.refundTotal) }}</td>
                <td>
                  <span v-if="state.now <= c.defenseEnd" class="countdown cool">{{ c.defenseEnd - state.now }}s left</span>
                  <span v-else class="pill ok"><span class="dot" />ready</span>
                </td>
                <td><button :disabled="state.busy || state.now <= c.defenseEnd" @click="actions.resolve(c.id)">Refund buyers and penalize provider</button></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-else class="empty">No open claims.</p>
      </div>
    </div>

    <!-- Resolved claims -->
    <div class="card">
      <div class="card-head"><span class="card-title">Resolved claims</span></div>
      <div class="card-body flush">
        <div class="table-scroll" v-if="resolvedClaims.length">
          <table class="table">
            <thead><tr><th class="num">#</th><th>Provider</th><th class="num">Payments</th><th class="num">Refunded</th><th>Outcome</th></tr></thead>
            <tbody>
              <tr v-for="c in resolvedClaims" :key="c.id">
                <td class="num">{{ c.id }}</td>
                <td><NuxtLink :to="`/seller/${c.seller}`" style="color: var(--text)">{{ sellerName(c.seller) }}</NuxtLink></td>
                <td class="num">{{ c.paymentIds.length }} <span class="addr">({{ c.defendedCount }} cleared)</span></td>
                <td class="num">${{ fmt(c.refundTotal) }}</td>
                <td><span class="pill muted">resolved</span></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-else class="empty">No resolved claims yet.</p>
      </div>
    </div>

    <!-- Penalty history -->
    <div class="card">
      <div class="card-head"><span class="card-title">Penalty history</span></div>
      <div class="card-body flush">
        <div class="table-scroll" v-if="state.slashes.length">
          <table class="table">
            <thead><tr><th>Provider</th><th class="num">Refunded to buyers</th><th class="num">Penalty</th><th class="num">Failures</th><th class="num">Bond left</th></tr></thead>
            <tbody>
              <tr v-for="(s, i) in state.slashes" :key="i">
                <td>{{ sellerName(s.seller) }} <span class="badge bad">Penalized</span></td>
                <td class="num">${{ fmt(s.refundTotal) }}</td>
                <td class="num">${{ fmt(s.penalty) }}</td>
                <td class="num">{{ s.failures }}</td>
                <td class="num">${{ fmt(s.remainingBond) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-else class="empty">No penalties yet — either every provider is delivering, or no one has filed a claim.</p>
      </div>
    </div>
  </div>
</template>

<script setup>
import { useProtocol, S } from '~/composables/useProtocol'
import { providerName } from '~/config/display'
const { state, actions, fmt, short } = useProtocol()
const sellerName = (a) => providerName(state.sellers.find((s) => s.address.toLowerCase() === a.toLowerCase())?.handle) || short(a)
const cmApproved = computed(() => state.allowance.cm > 0n)

// A rational watcher only claims payments with no defensible on-time seller
// evidence: settled (nothing), buyer-only, or hash-mismatch (buyer contradicts).
const claimable = (p) => state.now > p.receiptDeadline
  && (p.status === S.Settled || p.status === S.BuyerAttested || p.status === S.HashMismatch)

const failures = computed(() => {
  const by = new Map()
  for (const p of state.payments) {
    if (!claimable(p)) continue
    const k = p.seller.toLowerCase()
    if (!by.has(k)) by.set(k, { seller: p.seller, ids: [], total: 0n })
    const f = by.get(k)
    f.ids.push(p.id)
    f.total += p.amount
  }
  return [...by.values()]
})
const eligible = (f) => f.ids.length >= Number(state.minBatch) || f.total >= state.highValue
// demo stake model: 10% of refunds, floor 10 USD
const estStake = (total) => { const s = total / 10n; const floor = 10n * 1_000_000n; return s > floor ? s : floor }

const openClaims = computed(() => state.claims.filter((c) => !c.resolved))
const resolvedClaims = computed(() => state.claims.filter((c) => c.resolved))
const totalFailures = computed(() => failures.value.reduce((a, f) => a + f.ids.length, 0))
const openClaimsCount = computed(() => openClaims.value.length)
const resolvable = computed(() => state.claims.filter((c) => !c.resolved && state.now > c.defenseEnd).length)
const totalSlashed = computed(() => state.slashes.reduce((a, s) => a + s.refundTotal + s.penalty, 0n))
</script>