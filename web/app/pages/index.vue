<template>
  <div>
    <!-- HERO -->
    <section class="hero">
      <span class="hero-eyebrow">Collateral-backed trust for agent commerce</span>
      <h1>AI agents can pay. <span class="g">CollateralRails</span> helps them choose who to trust.</h1>
      <p class="hero-lead">Providers stake collateral, buyers pay directly, and failed deliveries are refunded from provider bonds.</p>
      <div class="cta-row">
        <NuxtLink to="/sellers" class="btn">Explore providers →</NuxtLink>
        <NuxtLink to="/sell" class="btn secondary">Join as a provider</NuxtLink>
        <NuxtLink to="/scenarios" class="btn ghost">Run the demo</NuxtLink>
      </div>
    </section>

    <!-- LIVE METRICS -->
    <div class="stats" style="margin-top: 34px">
      <div class="stat">
        <div class="stat-label">Bonded providers</div>
        <div class="stat-value">{{ activeCount }}<span class="unit">/ {{ state.sellers.length }}</span></div>
        <div class="stat-sub">accepting agent traffic</div>
      </div>
      <div class="stat">
        <div class="stat-label">Collateral staked</div>
        <div class="stat-value">{{ fmt(totalBond) }}<span class="unit">USD</span></div>
        <div class="stat-sub">backing delivery</div>
      </div>
      <div class="stat amber">
        <div class="stat-label">Open exposure</div>
        <div class="stat-value">{{ fmt(totalExposure) }}<span class="unit">USD</span></div>
        <div class="stat-sub">paid, not yet delivered</div>
      </div>
      <div class="stat rose">
        <div class="stat-label">Refunded from bonds</div>
        <div class="stat-value">{{ fmt(totalSlashed) }}<span class="unit">USD</span></div>
        <div class="stat-sub">paid to buyers on failure</div>
      </div>
    </div>

    <!-- LIFECYCLE -->
    <section class="section">
      <div class="section-eyebrow">How it works</div>
      <div class="lifecycle">
        <span class="lc-step">Choose provider</span>
        <span class="lc-arrow">→</span>
        <span class="lc-step">Pay directly</span>
        <span class="lc-arrow">→</span>
        <span class="lc-step">Deliver</span>
        <span class="lc-arrow">→</span>
        <span class="lc-step">Attest</span>
        <span class="lc-arrow">→</span>
        <span class="lc-step">Refund if failed</span>
      </div>
    </section>

    <div class="cta-row" style="margin-top: 34px">
      <NuxtLink to="/sellers" class="btn">Explore providers →</NuxtLink>
      <NuxtLink to="/scenarios" class="btn secondary">See the demo guide</NuxtLink>
    </div>
  </div>
</template>

<script setup>
import { useProtocol } from '~/composables/useProtocol'
const { state, fmt } = useProtocol()

const sum = (key) => state.sellers.reduce((a, s) => a + s[key], 0n)
const totalBond = computed(() => sum('bond'))
const totalExposure = computed(() => sum('openExposure'))
const totalSlashed = computed(() => sum('slashedTotal'))
const activeCount = computed(() => state.sellers.filter((s) => s.active).length)
</script>