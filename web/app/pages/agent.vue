<template>
  <div>
    <div class="page-head">
i      <h1 class="page-title">Buy from a trusted provider</h1>
      <p class="page-sub">The agent pays only when policy and provider capacity checks pass.</p>
    </div>

    <div class="stats">
      <div class="stat"><div class="stat-label">Prepaid balance</div><div class="stat-value">{{ fmt(myRail) }}<span class="unit">USD</span></div><div class="stat-sub">ready to spend</div></div>
      <div class="stat"><div class="stat-label">Payments</div><div class="stat-value">{{ mine.length }}</div><div class="stat-sub">{{ confirmedCount }} delivered · {{ pendingCount }} pending</div></div>
      <div class="stat amber"><div class="stat-label">Total spent</div><div class="stat-value">{{ fmt(totalSpent) }}<span class="unit">USD</span></div></div>
    </div>

    <!-- CHECKOUT FIRST -->
    <div class="card">
      <div class="card-head"><span class="card-title">Choose a provider &amp; pay</span></div>
      <div class="card-body">
        <div class="form-row">
          <label class="field">Provider
            <select v-model="seller">
              <option v-for="s in state.sellers" :key="s.address" :value="s.address" :disabled="!s.active">
                {{ providerName(s.handle) }}{{ s.verified ? ' ✓' : '' }} — {{ fmt(s.bond - s.openExposure) }} USD free{{ s.active ? '' : ' (delisted)' }}
              </option>
            </select>
          </label>
          <label class="field">Price ($)<input v-model="price" type="number" step="0.01" /></label>
          <label class="field">How many<input v-model="calls" type="number" min="1" /></label>
          <button :disabled="state.busy || !seller || !ready" @click="buy">Pay for {{ calls }} service calls</button>
          <NuxtLink v-if="seller" :to="`/seller/${seller}`" class="btn secondary" style="align-self: flex-end">View provider →</NuxtLink>
        </div>
        <p class="note" style="margin-bottom: 0" v-if="!state.account">Connect a wallet (top-right) to begin.</p>
        <p class="note" style="margin-bottom: 0" v-else-if="!ready">Complete the one-time setup below to enable buying.</p>
      </div>
    </div>

    <!-- ONE-TIME SETUP (collapses once ready) -->
    <details class="card setup" :open="setupOpen" @toggle="setupOpen = $event.target.open">
      <summary class="card-head">
        <span class="card-title">One-time setup &amp; spending policy</span>
        <span class="pill" :class="ready ? 'ok' : 'warn'" style="margin-left: auto"><span class="dot" />{{ ready ? 'Complete' : 'Action needed' }}</span>
      </summary>
      <div class="card-body">
        <p class="step-desc">Get test USD, let the rail spend it, add to your prepaid balance, then set the rules your agent must obey.</p>
        <div class="form-row">
          <button class="secondary" :disabled="state.busy || !state.account" @click="actions.mint(100)">Get 100 test USD <span v-if="hasFunds">✓</span></button>
          <button class="secondary" :disabled="state.busy || !state.account" @click="actions.approveRouter">Allow spending <span v-if="routerApproved">✓</span></button>
          <button class="secondary" :disabled="state.busy || !state.account || !routerApproved" @click="actions.deposit(50)">Add $50 to balance <span v-if="hasRail">✓</span></button>
        </div>
        <hr class="hair" />
        <p class="step-desc" style="margin-bottom: 12px">Spending policy <span v-if="state.policySet" class="pill ok" style="margin-left: 6px"><span class="dot" />saved</span></p>
        <div class="form-row">
          <label class="field">Max per call ($)<input v-model="cap" type="number" step="0.01" /></label>
          <label class="field">Total budget ($)<input v-model="budget" type="number" /></label>
          <label class="field">Expires in (days)<input v-model="days" type="number" /></label>
          <label class="check"><input v-model="bondedOnly" type="checkbox" /> Require bonded provider</label>
          <button :disabled="state.busy || !state.account" @click="actions.setPolicy(cap, budget, days, bondedOnly)">Save policy</button>
        </div>
      </div>
    </details>

    <!-- PAYMENTS -->
    <div class="card">
      <div class="card-head">
        <span class="card-title">Your payments</span>
        <span class="card-note">confirm receipt to complete a delivery</span>
      </div>
      <div class="card-body flush">
        <div class="table-scroll" v-if="mine.length">
          <table class="table">
            <thead><tr><th class="num">#</th><th>Provider</th><th class="num">Amount</th><th>Status</th><th>Action</th></tr></thead>
            <tbody>
              <tr v-for="p in visiblePayments" :key="p.id">
                <td class="num">{{ p.id }}</td>
                <td><NuxtLink :to="`/seller/${p.seller}`" style="color: var(--text)">{{ sellerName(p.seller) }}</NuxtLink></td>
                <td class="num">${{ fmt(p.amount) }}</td>
                <td><span class="pill" :class="badge(p).tone"><span class="dot" />{{ badge(p).label }}</span></td>
                <td>
                  <div v-if="canConfirm(p)" style="display: flex; gap: 8px; align-items: center">
                    <button :disabled="state.busy" @click="actions.attest(p)">Confirm receipt</button>
                    <a href="#" style="font-size: 12px; color: var(--rose)" title="Sign a different artifact to demonstrate a hash mismatch" @click.prevent="!state.busy && actions.attestMismatch(p)">dispute</a>
                  </div>
                  <span v-else class="addr">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-else class="empty">No payments yet. Choose a provider above to get started.</p>
      </div>
      <div v-if="mine.length > 5" class="card-body" style="border-top: 1px solid var(--line)">
        <button class="secondary" @click="showAll = !showAll">{{ showAll ? 'Show latest 5' : `View all payments (${mine.length})` }}</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { useProtocol, paymentPhase, S } from '~/composables/useProtocol'
import { providerName, buyStatus } from '~/config/display'
const { state, actions, fmt, short } = useProtocol()
const cap = ref(0.2), budget = ref(500), days = ref(30), bondedOnly = ref(true)
const seller = ref(''), price = ref(0.1), calls = ref(3)
const showAll = ref(false)
const setupOpen = ref(true)

const mine = computed(() => state.payments.filter((p) => !state.account || p.buyer.toLowerCase() === state.account.toLowerCase()))
const visiblePayments = computed(() => (showAll.value ? mine.value : mine.value.slice(0, 5)))
const sellerName = (a) => providerName(state.sellers.find((s) => s.address.toLowerCase() === a.toLowerCase())?.handle) || short(a)
const badge = (p) => buyStatus(paymentPhase(p, state.now))

const myRail = computed(() => state.balances[state.account?.toLowerCase()]?.rail ?? 0n)
const myUsdc = computed(() => state.balances[state.account?.toLowerCase()]?.usdc ?? 0n)
const hasFunds = computed(() => myUsdc.value > 0n)
const routerApproved = computed(() => state.allowance.router > 0n)
const hasRail = computed(() => myRail.value > 0n)
const ready = computed(() => routerApproved.value && hasRail.value && state.policySet)
const totalSpent = computed(() => mine.value.reduce((a, p) => a + p.amount, 0n))
const confirmedCount = computed(() => mine.value.filter((p) => p.status === S.DeliveryConfirmed).length)
const pendingCount = computed(() => mine.value.filter((p) => [S.Settled, S.SellerAttested, S.BuyerAttested].includes(p.status)).length)

// Collapse the setup section automatically once everything is ready.
watch(ready, (v) => { if (v) setupOpen.value = false })

// The buyer can confirm receipt while evidence is still open and they haven't attested.
const canConfirm = (p) => !p.buyerAttested && state.now <= p.receiptDeadline && [S.Settled, S.SellerAttested, S.BuyerAttested].includes(p.status)

async function buy() {
  for (let i = 0; i < Number(calls.value); i++) await actions.pay(seller.value, price.value)
}
</script>