# Dune dashboard — "Trust as a public data structure"

Four queries in `queries.sql`, built on raw logs (no decoded-table submission
needed, so they work minutes after deployment):

1. **Bonded Registry** — live seller table: bond, served/failed, reliability,
   BONDED/DELISTED stamp. This is the pitch chart: reputation portable across
   every venue because it lives in events, not a platform database.
2. **Slash History** — every slash with refunds to buyers *from the seller
   performance bond*, penalty split, and bond remaining.
3. **Protocol KPIs** — payments settled, volume, average payment size (the
   micropayment proof), attestations anchored, refunds from bonds.
4. **Payment Funnel** — final lifecycle state mix (attested / claimed /
   refunded / released).

Setup: create each query on dune.com, replace the `arbitrum.logs` table with
your chain's logs table, and set text parameters `{{registry}}`, `{{router}}`,
`{{cm}}` to the deployed addresses (0x-prefixed, lowercase). Pin all four to
one dashboard; Query 1 as the hero table, Query 3 as counters across the top.
