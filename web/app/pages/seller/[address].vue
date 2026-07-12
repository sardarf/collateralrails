<template>
  <div>
    <NuxtLink to="/sellers" style="font-size: 13px; color: var(--text-2)">← back to Seller Registry</NuxtLink>

    <div v-if="s" style="margin-top: 12px">
      <div class="page-head">
        <h1 class="page-title" style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap">
          {{ providerName(s.handle) }}
          <span v-if="s.verified" class="verified">✓ Verified</span>
          <span v-else class="unverified">unverified endpoint</span>
          <span class="badge" :class="statusBadge" style="margin-left: 4px">{{ status }}</span>
        </h1>
        <p class="page-sub">
          <span class="mono">{{ s.endpoint || '—' }}</span> · <span class="addr">{{ s.address }}</span>
        </p>
      </div>

      <div class="card">
        <div class="card-head">
          <span class="card-title">Trust signals</span>
          <span class="tier" :class="tierClass" :title="tierHint" style="margin-left: auto">
            {{ tierLabel }}<span class="score" v-if="s.served">· {{ s.repScore }} / 1000</span>
          </span>
        </div>
        <div class="card-body">
          <div style="margin-bottom: 16px">
            <div class="meter" style="width: 100%; max-width: 420px"><div class="meter-fill" :class="meterClass" :style="{ width: ratio + '%' }" /></div>
            <div class="meter-cap">{{ fmt(s.openExposure) }} at risk / {{ fmt(s.bond) }} bond · <strong style="color: var(--green)">{{ fmt(capacity) }} available capacity</strong></div>
          </div>
          <div class="stats" style="margin: 0">
            <div class="stat"><div class="stat-label">Total bond</div><div class="stat-value">{{ fmt(s.bond) }}<span class="unit">USD</span></div></div>
            <div class="stat amber"><div class="stat-label">Open exposure</div><div class="stat-value">{{ fmt(s.openExposure) }}<span class="unit">USD</span></div></div>
            <div class="stat"><div class="stat-label">Confirmed deliveries</div><div class="stat-value">{{ s.confirmed }}</div><div class="stat-sub">of {{ s.served }} transactions</div></div>
            <div class="stat rose"><div class="stat-label">Total refunded</div><div class="stat-value">{{ fmt(s.slashedTotal) }}<span class="unit">USD</span></div><div class="stat-sub">{{ s.failed }} failures</div></div>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head"><span class="card-title">Protocol-generated record</span><span class="card-note">no subjective ratings — only economic events</span></div>
        <div class="card-body flush">
          <div class="table-scroll">
            <table class="table">
              <tbody>
                <tr><td>Transaction count</td><td class="num">{{ s.served }}</td></tr>
                <tr><td>Successful delivery confirmations</td><td class="num">{{ s.confirmed }}</td></tr>
                <tr><td>Open exposure</td><td class="num">{{ fmt(s.openExposure) }} USD</td></tr>
                <tr><td>Available capacity</td><td class="num">{{ fmt(capacity) }} USD</td></tr>
                <tr><td>Open claims</td><td class="num">{{ s.openClaims }}</td></tr>
                <tr><td>Resolved claims</td><td class="num">{{ resolvedClaims }}</td></tr>
                <tr><td>Successful defences</td><td class="num">{{ defended }}</td></tr>
                <tr><td>Refund count</td><td class="num">{{ refundCount }}</td></tr>
                <tr><td>Total refunded / slashed</td><td class="num">{{ fmt(s.slashedTotal) }} USD</td></tr>
                <tr><td>Failure ratio</td><td class="num">{{ failRatio }}</td></tr>
                <tr><td>Endpoint verified</td><td class="num">{{ s.verified ? 'yes' : 'no' }}</td></tr>
                <tr><td>Status</td><td class="num">{{ status }}</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head"><span class="card-title">Recent transactions</span></div>
        <div class="card-body flush">
          <div class="table-scroll" v-if="txs.length">
            <table class="table">
              <thead><tr><th class="num">#</th><th class="num">Amount</th><th>Lifecycle</th></tr></thead>
              <tbody>
                <tr v-for="p in txs" :key="p.id">
                  <td class="num">{{ p.id }}</td>
                  <td class="num">${{ fmt(p.amount) }}</td>
                  <td><TxTimeline :payment="p" :now="state.now" /></td>
                </tr>
              </tbody>
            </table>
          </div>
          <p v-else class="empty">No transactions for this seller yet.</p>
        </div>
      </div>

      <div class="cta-row">
        <NuxtLink to="/agent" class="btn">Buy service →</NuxtLink>
        <NuxtLink to="/sellers" class="btn secondary">Compare providers</NuxtLink>
      </div>
    </div>

    <div v-else class="card" style="margin-top: 12px"><p class="empty">No provider found at this address. <NuxtLink to="/sellers" style="color: var(--green)">Browse the registry →</NuxtLink></p></div>
  </div>
</template>

<script setup>
import { useProtocol, REP_TIERS, sellerStatus } from '~/composables/useProtocol'
import { providerName } from '~/config/display'
const route = useRoute()
const { state, fmt } = useProtocol()
const addr = computed(() => String(route.params.address || '').toLowerCase())
const s = computed(() => state.sellers.find((x) => x.address.toLowerCase() === addr.value))

const tierClass = computed(() => REP_TIERS[s.value?.repTier]?.key || 'new')
const tierLabel = computed(() => REP_TIERS[s.value?.repTier]?.label || 'New')
const tierHint = computed(() => REP_TIERS[s.value?.repTier]?.hint || '')
const status = computed(() => (s.value ? sellerStatus(s.value) : ''))
const statusBadge = computed(() => (status.value === 'Active' ? '' : status.value === 'Capacity Limited' ? 'warn' : 'bad'))
const capacity = computed(() => (s.value ? s.value.bond - s.value.openExposure : 0n))
const ratio = computed(() => (!s.value || s.value.bond === 0n ? 0 : Math.min(100, Number((s.value.openExposure * 100n) / s.value.bond))))
const meterClass = computed(() => { const r = ratio.value; return r >= 85 ? 'hot' : r >= 60 ? 'warn' : '' })
const failRatio = computed(() => (s.value?.served ? `${((s.value.failed / s.value.served) * 100).toFixed(0)}%` : '—'))

const txs = computed(() => state.payments.filter((p) => s.value && p.seller.toLowerCase() === addr.value).slice(0, 20))
const myClaims = computed(() => state.claims.filter((c) => s.value && c.seller.toLowerCase() === addr.value))
const resolvedClaims = computed(() => myClaims.value.filter((c) => c.resolved).length)
const defended = computed(() => myClaims.value.reduce((a, c) => a + Number(c.defendedCount), 0))
const refundCount = computed(() => state.slashes.filter((x) => x.seller.toLowerCase() === addr.value).reduce((a, x) => a + Number(x.failures), 0))
</script>