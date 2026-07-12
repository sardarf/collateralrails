<template>
  <div>
    <div class="page-head">
      <h1 class="page-title">Demo Guide</h1>
      <p class="page-sub">Three core walkthroughs, plus advanced edge cases. Switch accounts in your wallet to play each role — open <strong>Demo roles</strong> (top-right).</p>
    </div>

    <!-- Core scenarios (expanded) -->
    <div v-for="sc in core" :key="sc.n" class="scenario">
      <details open>
        <summary class="scenario-head">
          <span class="sc-n">{{ sc.n }}</span>
          <h3>{{ sc.title }}</h3>
          <span class="sc-outcome pill" :class="sc.tone"><span class="dot" />{{ sc.outcome }}</span>
        </summary>
        <div class="scenario-body">
          <p class="roles">Roles: {{ sc.roles }} · Screens: <template v-for="(t, i) in sc.tabs" :key="t.to"><NuxtLink :to="t.to" style="color: var(--green)">{{ t.label }}</NuxtLink><span v-if="i < sc.tabs.length - 1"> · </span></template></p>
          <ol>
            <li v-for="(step, i) in sc.steps" :key="i" v-html="step" />
          </ol>
        </div>
      </details>
    </div>

    <!-- Advanced scenarios (collapsed) -->
    <details class="card setup" style="margin-top: 8px">
      <summary class="card-head">
        <span class="card-title">Advanced scenarios</span>
        <span class="card-note" style="margin-left: auto">{{ advanced.length }} more edge cases</span>
      </summary>
      <div class="card-body" style="padding: 12px">
        <div v-for="sc in advanced" :key="sc.n" class="scenario">
          <details>
            <summary class="scenario-head">
              <span class="sc-n">{{ sc.n }}</span>
              <h3>{{ sc.title }}</h3>
              <span class="sc-outcome pill" :class="sc.tone"><span class="dot" />{{ sc.outcome }}</span>
            </summary>
            <div class="scenario-body">
              <p class="roles">Roles: {{ sc.roles }} · Screens: <template v-for="(t, i) in sc.tabs" :key="t.to"><NuxtLink :to="t.to" style="color: var(--green)">{{ t.label }}</NuxtLink><span v-if="i < sc.tabs.length - 1"> · </span></template></p>
              <ol>
                <li v-for="(step, i) in sc.steps" :key="i" v-html="step" />
              </ol>
            </div>
          </details>
        </div>
      </div>
    </details>

    <p class="note">All scenarios use test USD on a local demo network. Refunds always come from the provider's bond — buyer payments are never escrowed.</p>
  </div>
</template>

<script setup>
const T = {
  home: { to: '/', label: 'Overview' },
  sellers: { to: '/sellers', label: 'Seller Registry' },
  buy: { to: '/agent', label: 'Buy Service' },
  sell: { to: '/sell', label: 'Seller Console' },
  disputes: { to: '/watchtower', label: 'Claims' },
}

const scenarios = [
  { n: 1, title: 'Successful delivery', outcome: 'Delivered', tone: 'ok', roles: 'Provider · Buyer', tabs: [T.sell, T.buy], core: true,
    steps: [
      'As the <b>reliable provider</b>, open <b>Seller Console</b> → get funded, place a bond, and go live.',
      'As the <b>buyer</b>, open <b>Buy Service</b> → set a policy, add funds, and pay the provider.',
      'Back as the <b>provider</b>, open <b>Seller Console</b> → <b>Sign delivery attestation</b> on the incoming payment.',
      'As the <b>buyer</b>, open <b>Buy Service</b> → <b>Confirm receipt</b> (signs the same response bytes).',
      'Hashes match → <span class="g">Delivered</span>. The provider’s exposure is released and a confirmed delivery is recorded.',
    ] },
  { n: 2, title: 'Failed delivery and refund', outcome: 'Refunded + penalized', tone: 'bad', roles: 'Buyer · Watcher', tabs: [T.buy, T.disputes], core: true,
    steps: [
      'The <b>buyer</b> pays an <b>unreliable provider</b>; neither side completes a matching attestation.',
      'The receipt deadline passes with no confirmed delivery.',
      'On <b>Claims</b>, <b>File claim</b> against the provider.',
      'The provider has no committed evidence, so the defense window elapses.',
      '<b>Refund buyers and penalize provider</b> → the buyer is <span class="k">refunded from the provider’s bond</span> and its failure history updates.',
    ] },
  { n: 3, title: 'Capacity protection', outcome: 'Payment rejected', tone: 'bad', roles: 'Buyer', tabs: [T.sellers, T.buy], core: true,
    steps: [
      'Pick a provider whose <b>open exposure</b> is already near its <b>bond</b> (see the capacity meter in <b>Seller Registry</b>).',
      'As the buyer, attempt a payment that would push exposure over the bond.',
      'The rail <span class="k">rejects</span> it — a provider can never owe more unconfirmed obligations than its collateral covers.',
    ] },
  { n: 4, title: 'Provider attested, buyer missing', outcome: 'Evidence incomplete', tone: 'warn', roles: 'Provider · Watcher', tabs: [T.sell, T.disputes],
    steps: [
      'The provider <b>signs its delivery</b> on time, but the buyer never confirms receipt.',
      'The payment stays <b>evidence incomplete</b> — the system does not assume either party is honest.',
      'After the deadline a watcher <em>may</em> file a claim, but the provider committed evidence on time, so it can <b>Defend</b> and clear the payment.',
    ] },
  { n: 5, title: 'Hash mismatch', outcome: 'Disputed', tone: 'bad', roles: 'Provider · Buyer · Watcher', tabs: [T.sell, T.buy, T.disputes],
    steps: [
      'The provider signs delivery (hash A). On <b>Buy Service</b>, the buyer clicks the small <b>dispute</b> link to sign a <em>different</em> artifact (hash B).',
      'Hashes differ → the payment becomes <span class="k">Disputed</span>. Exposure is <b>not</b> released as a successful delivery.',
      'After the deadline it is claimable. A contradicting buyer attestation blocks the provider’s defense, so the claim workflow applies.',
    ] },
  { n: 6, title: 'High-value single claim', outcome: 'Refunded + penalized', tone: 'bad', roles: 'Buyer · Watcher', tabs: [T.buy, T.disputes],
    steps: [
      'The buyer makes one payment above the high-value threshold to a provider who then fails to deliver.',
      'On <b>Claims</b>, the single overdue payment shows as <b>high-value</b> eligible — no full batch needed.',
      'File and resolve as usual: standard defense window, then refund + penalty.',
    ] },
  { n: 7, title: 'False / invalid claim', outcome: 'Bond forfeited', tone: 'warn', roles: 'Provider · Watcher', tabs: [T.sell, T.disputes],
    steps: [
      'A provider delivered and committed on-time evidence for its payments.',
      'A watcher files a claim against them anyway.',
      'The provider <b>Defends</b> with its committed evidence; the fully-defended claim resolves as a false claim.',
      'The watcher’s bond is <span class="k">forfeited to the provider</span> — griefing has a cost.',
    ] },
  { n: 8, title: 'Provider exit blocked, then allowed', outcome: 'Exit disciplined', tone: 'ok', roles: 'Provider', tabs: [T.sell],
    steps: [
      'On <b>Seller Console</b>, click <b>Request exit</b> while you still have open exposure or an open claim.',
      '<b>Withdraw bond</b> fails — the board shows exactly what’s blocking you.',
      'Once every obligation confirms/resolves and the cooldown ends, <b>Withdraw bond</b> succeeds and returns your full bond.',
    ] },
  { n: 9, title: 'Provider replenishes bond', outcome: 'Capacity restored', tone: 'ok', roles: 'Provider', tabs: [T.sell],
    steps: [
      'After a penalty, the provider’s available capacity has fallen.',
      'On <b>Seller Console</b>, use <b>Add to bond</b> to top it back up.',
      'Capacity is restored (subject to active-status and delisting rules).',
    ] },
]

const core = scenarios.filter((s) => s.core)
const advanced = scenarios.filter((s) => !s.core)
</script>