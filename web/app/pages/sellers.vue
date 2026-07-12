<template>
  <div>
    <div class="page-head">
      <h1 class="page-title">Choose a trusted service provider</h1>
      <p class="page-sub">Compare providers by reliability, bond protection and delivery history.</p>
    </div>

    <div class="filterbar">
      <input v-model="q" placeholder="Search providers…" />
      <select v-model="sortKey">
        <option value="rep">Sort: Reputation</option>
        <option value="bond">Sort: Bond</option>
        <option value="capacity">Sort: Available capacity</option>
        <option value="confirmed">Sort: Delivered</option>
      </select>
      <span class="cta-note">{{ filtered.length }} of {{ state.sellers.length }}</span>
    </div>

    <div class="grid-cards" v-if="filtered.length">
      <div v-for="s in filtered" :key="s.address" class="scard" :class="{ delisted: !s.active }">
        <div class="scard-top">
          <div style="flex: 1">
            <div class="scard-name">{{ providerName(s.handle) }}</div>
            <div class="scard-cat">{{ providerCategory(s) }}</div>
          </div>
          <span v-if="s.verified" class="verified">✓ Verified</span>
          <span v-else class="unverified">Unverified</span>
        </div>

        <div class="scard-foot" style="margin-top: -2px">
          <span class="badge" :class="statusBadge(s)">{{ status(s) }}</span>
          <span class="tier" :class="tierClass(s)">{{ tierLabel(s) }}<span class="score" v-if="s.served">· {{ s.repScore }}</span></span>
        </div>

        <div>
          <div class="meter"><div class="meter-fill" :class="meterClass(s)" :style="{ width: ratio(s) + '%' }" /></div>
          <div class="meter-cap"><strong style="color: var(--green)">{{ fmt(s.bond - s.openExposure) }} USD</strong> available capacity</div>
        </div>

        <div class="scard-grid">
          <span class="k">Bond</span><span class="v">{{ fmt(s.bond) }} USD</span>
          <span class="k">Available capacity</span><span class="v">{{ fmt(s.bond - s.openExposure) }} USD</span>
          <span class="k">Delivered</span><span class="v">{{ s.confirmed }}</span>
          <span class="k">Failed</span><span class="v">{{ s.failed }}</span>
          <span class="k">Failure ratio</span><span class="v">{{ failRatio(s) }}</span>
        </div>

        <div v-if="s.active">
          <NuxtLink to="/agent" class="btn" style="width: 100%; justify-content: center">Buy service</NuxtLink>
        </div>
        <div v-else>
          <button disabled style="width: 100%">Unavailable</button>
          <div class="scard-warn" style="margin-top: 8px">⚠ Removed after failed deliveries</div>
        </div>

        <details class="details">
          <summary>View details</summary>
          <div class="dd-grid">
            <span class="k">Endpoint</span><span class="v">{{ s.endpoint || '—' }}</span>
            <span class="k">Address</span><span class="v">{{ s.address }}</span>
            <span class="k">Transactions</span><span class="v">{{ s.served }}</span>
            <span class="k">Open exposure</span><span class="v">{{ fmt(s.openExposure) }} USD</span>
            <span class="k">Reputation score</span><span class="v">{{ s.repScore }} / 1000</span>
          </div>
          <NuxtLink :to="`/seller/${s.address}`" class="rr-go" style="display: inline-block; margin-top: 10px">Full profile →</NuxtLink>
        </details>
      </div>
    </div>
    <div v-else class="card"><p class="empty">No providers match your search.</p></div>
  </div>
</template>

<script setup>
import { useProtocol, REP_TIERS, sellerStatus } from '~/composables/useProtocol'
import { providerName, providerCategory } from '~/config/display'
const { state, fmt } = useProtocol()

const q = ref('')
const sortKey = ref('rep')

const tierClass = (s) => REP_TIERS[s.repTier]?.key || 'new'
const tierLabel = (s) => REP_TIERS[s.repTier]?.label || 'New'
const status = (s) => sellerStatus(s)
const statusBadge = (s) => {
  const st = sellerStatus(s)
  if (st === 'Active') return ''
  if (st === 'Capacity Limited') return 'warn'
  return 'bad'
}
const ratio = (s) => (s.bond === 0n ? 0 : Math.min(100, Number((s.openExposure * 100n) / s.bond)))
const meterClass = (s) => { const r = ratio(s); return r >= 85 ? 'hot' : r >= 60 ? 'warn' : '' }
const failRatio = (s) => (s.served ? `${((s.failed / s.served) * 100).toFixed(0)}%` : '—')

const filtered = computed(() => {
  let list = [...state.sellers]
  const term = q.value.trim().toLowerCase()
  if (term) list = list.filter((s) => `${providerName(s.handle)} ${s.handle} ${s.endpoint} ${s.address}`.toLowerCase().includes(term))
  const cap = (s) => s.bond - s.openExposure
  const cmp = {
    rep: (a, b) => b.repScore - a.repScore,
    bond: (a, b) => Number(b.bond - a.bond),
    capacity: (a, b) => Number(cap(b) - cap(a)),
    confirmed: (a, b) => b.confirmed - a.confirmed,
  }[sortKey.value]
  list.sort(cmp)
  return list
})
</script>