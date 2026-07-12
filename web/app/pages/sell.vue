<template>
  <div>
    <div class="page-head">
      <h1 class="page-title">Manage your bonded service</h1>
      <p class="page-sub">Attest delivery before the deadline to protect your bond and reputation.</p>
    </div>

    <!-- ONBOARDING (only until registered) -->
    <template v-if="!me">
      <div class="page-head" style="margin-bottom: 14px">
        <h2 class="thesis">Get started</h2>
        <p class="page-sub">Get funded, then place your bond and go live.</p>
      </div>

      <Step n="1" title="Get funded &amp; give permission" badge="One-time setup" :done="setupDone">
        <template #desc>Get free test USD, then allow the registry to hold your bond. Once per wallet.</template>
        <div class="form-row">
          <button class="secondary" :disabled="state.busy || !state.account" @click="actions.mint(1000)">Get 1000 test USD <span v-if="hasFunds">✓</span></button>
          <button class="secondary" :disabled="state.busy || !state.account" @click="actions.approveRegistry">Allow bond <span v-if="registryApproved">✓</span></button>
        </div>
        <p class="note" style="margin-bottom: 0" v-if="!state.account">Connect a wallet (top-right) to begin.</p>
      </Step>

      <Step n="2" title="Describe your service &amp; set your bond" :locked="!setupDone">
        <template #desc>Your handle is globally unique. Your endpoint earns a ✓ Verified badge once confirmed. Your bond is the collateral buyers are refunded from if you fail to deliver.</template>
        <div class="form-row">
          <label class="field">Service name / handle<input v-model="handle" placeholder="e.g. aeris-data" /></label>
          <label class="field">Category<input v-model="category" placeholder="e.g. Market data" /></label>
          <label class="field">Endpoint URL<input v-model="endpoint" placeholder="https://aeris.example" /></label>
        </div>
        <p class="note" style="margin-bottom: 0">Handle and endpoint are recorded on-chain.</p>
      </Step>

      <Step n="3" title="Place your bond &amp; go live" :locked="!setupDone || !handle">
        <template #desc>Bond at least <strong>{{ fmt(state.minBond) }} USD</strong>. Your available capacity equals your bond minus open exposure.</template>
        <div class="form-row">
          <label class="field">Bond (USD, min {{ fmt(state.minBond) }})<input v-model="bond" type="number" min="0" /></label>
          <button :disabled="state.busy || !state.account || !setupDone || !handle || handleTaken" @click="actions.register(bond, handle, endpoint)">Place bond &amp; list service</button>
        </div>
        <p class="note" style="margin-bottom: 0" v-if="handleTaken">The handle “{{ handle }}” is already taken — pick another.</p>
        <p class="note" style="margin-bottom: 0" v-else>Your bond is fully returned when you exit cleanly.</p>
      </Step>
    </template>

    <!-- SELLER DASHBOARD -->
    <template v-else>
      <!-- 1 · Bond summary -->
      <div class="card">
        <div class="card-head">
          <span class="card-title">{{ providerName(me.handle) }}</span>
          <span class="tier" :class="tierClass(me)" :title="tierHint(me)" style="margin-left: 10px">{{ tierLabel(me) }}<span class="score" v-if="me.served">· {{ me.repScore }}</span></span>
          <span v-if="me.verified" class="verified">✓ Verified</span>
          <span v-else class="unverified">unverified endpoint</span>
          <span class="badge" :class="statusBadge(me)" style="margin-left: auto">{{ status(me) }}</span>
        </div>
        <div class="card-body">
          <div style="margin-bottom: 16px">
            <div class="meter" style="width: 100%; max-width: 420px"><div class="meter-fill" :class="meterClass(me)" :style="{ width: ratio(me) + '%' }" /></div>
            <div class="meter-cap">{{ fmt(me.openExposure) }} at risk / {{ fmt(me.bond) }} bond · <strong style="color: var(--green)">{{ fmt(capacity) }} USD available capacity</strong></div>
          </div>
          <div class="stats" style="margin-bottom: 0">
            <div class="stat"><div class="stat-label">Bond</div><div class="stat-value">{{ fmt(me.bond) }}<span class="unit">USD</span></div></div>
            <div class="stat amber"><div class="stat-label">At risk</div><div class="stat-value">{{ fmt(me.openExposure) }}<span class="unit">USD</span></div><div class="stat-sub">unconfirmed</div></div>
            <div class="stat"><div class="stat-label">Delivered</div><div class="stat-value">{{ me.confirmed }}</div><div class="stat-sub">of {{ me.served }} · {{ me.failed }} failed</div></div>
            <div class="stat rose"><div class="stat-label">Refunded from bond</div><div class="stat-value">{{ fmt(me.slashedTotal) }}<span class="unit">USD</span></div></div>
          </div>
        </div>
      </div>

      <!-- 2 · Pending delivery attestations (primary work) -->
      <div class="card">
        <div class="card-head">
          <span class="card-title">Deliveries to attest</span>
          <span class="card-note" v-if="obligations.length">{{ obligations.length }} awaiting your signature</span>
        </div>
        <div class="card-body flush">
          <div class="table-scroll" v-if="obligations.length">
            <table class="table">
              <thead><tr><th class="num">#</th><th class="num">Amount</th><th>Time left</th><th>Action</th></tr></thead>
              <tbody>
                <tr v-for="p in obligations" :key="p.id">
                  <td class="num">{{ p.id }}</td>
                  <td class="num">${{ fmt(p.amount) }}</td>
                  <td>
                    <span v-if="state.now <= p.receiptDeadline" class="countdown">{{ p.receiptDeadline - state.now }}s</span>
                    <span v-else class="pill bad">overdue</span>
                  </td>
                  <td>
                    <button v-if="!p.sellerAttested && state.now <= p.receiptDeadline" :disabled="state.busy" @click="actions.attest(p)">Sign delivery attestation</button>
                    <span v-else-if="p.sellerAttested" class="pill sky">signed · awaiting buyer</span>
                    <span v-else class="pill muted">window closed</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p v-else class="empty">Nothing to attest right now. Each payment you receive appears here to sign before its deadline.</p>
        </div>
      </div>

      <!-- 3 · Claims against me -->
      <div class="card">
        <div class="card-head"><span class="card-title">Claims against me</span></div>
        <div class="card-body flush">
          <div class="table-scroll" v-if="against.length">
            <table class="table">
              <thead><tr><th class="num">#</th><th>Payments</th><th class="num">Refund at stake</th><th>Time to respond</th><th>Action</th></tr></thead>
              <tbody>
                <tr v-for="c in against" :key="c.id">
                  <td class="num">{{ c.id }}</td>
                  <td class="num">{{ c.paymentIds.length }} <span class="addr">({{ c.defendedCount }} cleared)</span></td>
                  <td class="num">${{ fmt(c.refundTotal) }}</td>
                  <td>
                    <span v-if="c.resolved" class="pill muted">resolved</span>
                    <span v-else-if="state.now <= c.defenseEnd" class="countdown">{{ c.defenseEnd - state.now }}s</span>
                    <span v-else class="pill bad">time’s up</span>
                  </td>
                  <td>
                    <button class="danger" :disabled="state.busy || c.resolved || state.now > c.defenseEnd || !defensibleCount(c)" @click="actions.defend(c)">
                      Defend ({{ defensibleCount(c) }})
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p v-else class="empty">No claims against you. Attesting deliveries on time keeps it that way.</p>
        </div>
      </div>

      <!-- 4 · Bond configuration (moved below the dashboard) -->
      <details class="card setup">
        <summary class="card-head">
          <span class="card-title">Bond &amp; exit</span>
          <span class="card-note" style="margin-left: auto">top up or withdraw your bond</span>
        </summary>
        <div class="card-body">
          <p class="note" style="margin: 0 0 16px" v-if="!me.verified">Your endpoint <strong>{{ me.endpoint }}</strong> isn’t verified yet.</p>
          <div class="form-row">
            <label class="field">Add to bond ($)<input v-model="topup" type="number" /></label>
            <button class="secondary" :disabled="state.busy" @click="actions.topUp(topup)">Add to bond</button>
            <button class="secondary" :disabled="state.busy" @click="actions.requestWithdrawal">Request exit</button>
            <button class="secondary" :disabled="state.busy" @click="actions.executeWithdrawal">Withdraw bond</button>
          </div>
          <p class="note" style="margin-bottom: 0">
            You can’t withdraw while
            <strong v-if="me.openExposure > 0n" style="color: var(--amber)">you have {{ fmt(me.openExposure) }} at risk</strong><span v-else>you have open exposure</span>,
            while <strong v-if="me.openClaims > 0" style="color: var(--rose)">{{ me.openClaims }} claim(s) are open</strong><span v-else>any claim is unresolved</span>,
            or before the exit cooldown ({{ Number(state.cooldown) }}s) ends. Requesting an exit stops new payments immediately.
          </p>
        </div>
      </details>
    </template>
  </div>
</template>

<script setup>
import { useProtocol, REP_TIERS, sellerStatus, S } from '~/composables/useProtocol'
import { providerName } from '~/config/display'
const { state, actions, fmt } = useProtocol()

// onboarding form
const bond = ref(500), handle = ref(''), endpoint = ref(''), category = ref('')
const topup = ref(100)

const myUsdc = computed(() => state.balances[state.account?.toLowerCase()]?.usdc ?? 0n)
const hasFunds = computed(() => myUsdc.value > 0n)
const registryApproved = computed(() => state.allowance.registry > 0n)
const setupDone = computed(() => hasFunds.value && registryApproved.value)
const handleTaken = computed(() => {
  const h = handle.value.trim().toLowerCase()
  return !!h && state.sellers.some((s) => (s.handle || '').toLowerCase() === h)
})

const me = computed(() => state.sellers.find((s) => state.account && s.address.toLowerCase() === state.account.toLowerCase()))
const capacity = computed(() => (me.value ? me.value.bond - me.value.openExposure : 0n))

const tierClass = (s) => REP_TIERS[s.repTier]?.key || 'new'
const tierLabel = (s) => REP_TIERS[s.repTier]?.label || 'New'
const tierHint = (s) => REP_TIERS[s.repTier]?.hint || ''
const status = (s) => sellerStatus(s)
const statusBadge = (s) => { const st = sellerStatus(s); return st === 'Active' ? '' : st === 'Capacity Limited' ? 'warn' : 'bad' }
const ratio = (s) => (s.bond === 0n ? 0 : Math.min(100, Number((s.openExposure * 100n) / s.bond)))
const meterClass = (s) => { const r = ratio(s); return r >= 85 ? 'hot' : r >= 60 ? 'warn' : '' }

// payments to this seller still gathering evidence (seller can still act on)
const obligations = computed(() => state.payments.filter((p) => me.value && p.seller.toLowerCase() === me.value.address.toLowerCase()
  && [S.Settled, S.SellerAttested, S.BuyerAttested].includes(p.status)))
const against = computed(() => state.claims.filter((c) => me.value && c.seller.toLowerCase() === me.value.address.toLowerCase()))
// how many payments in a claim the seller can actually defend (committed on-time evidence)
const defensibleCount = (c) => state.payments.filter((p) => c.paymentIds.includes(p.id) && p.status === S.Claimed
  && p.sellerAttested && (!p.buyerAttested || p.buyerHash === p.sellerHash)).length
</script>