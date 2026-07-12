<template>
  <div class="card step-card" :class="{ done, locked }">
    <div class="card-head">
      <span class="step-num" :class="{ done }">
        <template v-if="done">✓</template>
        <template v-else>{{ n }}</template>
      </span>
      <span class="card-title">{{ title }}</span>
      <span v-if="badge" class="step-tag">{{ badge }}</span>
      <span class="card-note" v-if="note">{{ note }}</span>
      <span v-if="done" class="badge" style="margin-left: auto">Done</span>
    </div>
    <div class="card-body">
      <p v-if="$slots.desc" class="step-desc"><slot name="desc" /></p>
      <slot />
    </div>
  </div>
</template>

<script setup>
// A numbered step in a guided flow. Renders the shared .card chrome with a
// step index badge, an optional "prerequisite / one-time" tag, and a done state.
defineProps({
  n: { type: [Number, String], required: true },
  title: { type: String, required: true },
  note: { type: String, default: '' },
  badge: { type: String, default: '' }, // e.g. "One-time setup"
  done: { type: Boolean, default: false },
  locked: { type: Boolean, default: false },
})
</script>