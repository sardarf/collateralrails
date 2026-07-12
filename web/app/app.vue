<template>
  <div>
    <header class="topbar">
      <div class="brand">
        <div class="brand-mark">C</div>
        <div>
          <div class="brand-name">CollateralRails</div>
          <div class="brand-tag">Trusted service providers for AI agents</div>
        </div>
      </div>
      <span class="spacer" />
      <span class="netpill">
        <span class="status-dot" :class="{ ok: state.chainOk }" />
        Local Demo Network
      </span>
      <button class="roles-btn" @click="rolesOpen = true">Demo roles</button>
      <span v-if="state.account" class="wallet-addr"><span class="av" />{{ short(state.account) }}</span>
      <button v-else class="wallet-btn" :disabled="state.busy" @click="actions.connect">Connect wallet</button>
    </header>

    <nav class="tabbar">
      <NuxtLink to="/">Overview</NuxtLink>
      <NuxtLink to="/sellers">Seller Registry</NuxtLink>
      <NuxtLink to="/agent">Buy Service</NuxtLink>
      <NuxtLink to="/sell">Seller Console</NuxtLink>
      <NuxtLink to="/watchtower">Claims</NuxtLink>
      <NuxtLink to="/scenarios">Demo Guide</NuxtLink>
    </nav>

    <div class="demobanner">
      <span>💵</span>
      <span>Demo uses <strong>test USD</strong> on a local demo network. No real funds.</span>
    </div>

    <div v-if="!state.account" class="rolebar warn">
      <span class="stamp" style="color: var(--amber); border-color: var(--amber-line); background: var(--amber-soft)">Not connected</span>
      <span class="hint">Click <strong>Connect wallet</strong> to start the demo. Use <strong>Demo roles</strong> to see which account plays each part.</span>
    </div>
    <div v-else-if="role" class="rolebar">
      <span class="stamp">{{ role.role }}</span>
      <span class="hint">{{ role.hint }}</span>
      <NuxtLink :to="role.tab" class="go">→ go to this account's screen</NuxtLink>
      <span class="addr">{{ short(state.account) }}</span>
    </div>
    <div v-else class="rolebar unknown">
      <span class="hint">Connected <span class="addr">{{ short(state.account) }}</span> — not a demo account. Open <strong>Demo roles</strong> to try a role.</span>
    </div>

    <main>
      <NuxtPage />
      <p v-if="state.log" class="txlog" :class="{ error: state.log.includes('failed') }">{{ state.log }}</p>
      <p class="footnote">Test USD on a local demo network — no real funds. If a provider fails to deliver, buyers are refunded from that provider's bond; your payment is never held in escrow.</p>
    </main>

    <!-- Demo roles drawer -->
    <template v-if="rolesOpen">
      <div class="drawer-scrim" @click="rolesOpen = false" />
      <aside class="drawer">
        <div class="drawer-head">
          <h3>Demo roles</h3>
          <button class="x" @click="rolesOpen = false">✕</button>
        </div>
        <div class="drawer-body">
          <p class="rr-hint" style="margin-top: 4px">Import one of these demo accounts in your wallet to play its part.</p>
          <div v-for="r in roleList" :key="r.address" class="role-row">
            <div class="rr-top">
              <span class="rr-name">{{ r.role }}</span>
              <span class="rr-addr">{{ short(r.address) }}</span>
            </div>
            <p class="rr-hint">{{ r.hint }}</p>
            <NuxtLink :to="r.tab" class="rr-go" @click="rolesOpen = false">Open screen →</NuxtLink>
          </div>
        </div>
      </aside>
    </template>
  </div>
</template>

<script setup>
import { useProtocol, roleOf, DEMO_ROLES } from '~/composables/useProtocol'
const { state, actions, short } = useProtocol()
const role = computed(() => roleOf(state.account))
const rolesOpen = ref(false)

// Compact list of the labelled demo accounts for the roles drawer.
const roleList = Object.entries(DEMO_ROLES).map(([address, r]) => ({ address, ...r }))
</script>