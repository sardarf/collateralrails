<template>
  <div class="timeline">
    <template v-for="(s, i) in steps" :key="i">
      <span class="tl-sep" v-if="i">→</span>
      <span class="tl-step" :class="s.state"><span class="tl-dot" />{{ s.label }}</span>
    </template>
  </div>
</template>

<script setup>
// A compact lifecycle timeline for one payment, driven by stored status +
// committed attestation flags + the current clock. Mirrors SettlementRouter.Status
// and the §8 state model without overloading any single status.
import { S } from '~/composables/useProtocol'
const props = defineProps({ payment: { type: Object, required: true }, now: { type: Number, required: true } })

const steps = computed(() => {
  const p = props.payment
  const overdue = props.now > p.receiptDeadline
  const out = [{ label: 'Paid', state: 'done' }]

  // attestation stage
  out.push({ label: 'Seller attested', state: p.sellerAttested ? 'done' : (overdue ? 'bad' : 'active') })
  out.push({ label: 'Buyer attested', state: p.buyerAttested ? 'done' : (overdue ? 'bad' : 'active') })

  // terminal / outcome stage
  if (p.status === S.DeliveryConfirmed) out.push({ label: 'Delivery confirmed', state: 'done' })
  else if (p.status === S.HashMismatch) out.push({ label: 'Hash mismatch', state: 'bad' })
  else if (p.status === S.Claimed) out.push({ label: 'Claim filed', state: 'bad' })
  else if (p.status === S.Refunded) out.push({ label: 'Refunded from bond', state: 'bad' })
  else if (p.status === S.Released) out.push({ label: 'Released', state: 'done' })
  else if (overdue) out.push({ label: 'Evidence incomplete — claimable', state: 'bad' })
  else out.push({ label: 'Awaiting confirmation', state: 'active' })

  return out
})
</script>