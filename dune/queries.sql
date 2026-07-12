-- CollateralRails — Dune dashboard queries
-- Raw-log queries (no decoded tables needed): work on any Dune-supported chain.
-- Replace {{registry}}, {{router}}, {{cm}} text parameters with deployed
-- addresses, and the `arbitrum.logs` table with your chain's logs table
-- (e.g. arbitrum.logs for Arbitrum One). Amounts are mUSDC, 6 decimals.
--
-- topic0 reference (keccak256 of event signatures):
--   SellerRegistered     0xc77acd1dd6dc167547c3fa235f91a68a22feb70cd7161e9faaeb33c9775051ac
--   SellerSlashed        0x7eb07af5827932a7a49dbf7637f22f0eb9b9132019205a38f24754e27c72eff1
--   SellerDelisted       0x6beba25ba702991e7deea43b52c0ff4fb907e844eaebde689bf7f7fad0fbae62
--   ReputationUpdated    0x28f5094dca9ea9eddb3dee097e360810e4ec8eab9fb15299386a62c407f379fb
--   PaymentSettled       0xd06f1cd9d937c2b94299a11c7e1cb5a260dfc188b5ec6c557466dcbfcb2fdd7f
--   PaymentStatusChanged 0xf879d3b4028acb77eda7e8b250ce97ca51a46b47cb3482367d544fcf6fa4bdab
--   ClaimFiled           0xa8fb35c616d08f3b1a0d7410489ba3da46179b0731567c6bf87a342f1b269408
--   ClaimResolved        0x55903d19a489b64a45cd5e2f89e821bf22fa899f44e3d3965a3c5fb3245c504f
--   ReceiptAnchored      0xdc9e9498cbe1ceacc033ec48475aba7c41ad879489bf0eefbfaf4aeee376ff73

-- ============================================================ Query 1
-- BONDED REGISTRY — live seller reputation (portable trust, the pitch chart)
-- One row per seller: latest served/failed/bond from ReputationUpdated,
-- stamped DELISTED if a SellerDelisted came after the last relist.
WITH rep AS (
  SELECT
    concat('0x', substr(cast(topic1 AS varchar), 27)) AS seller,
    bytearray_to_uint256(bytearray_substring(data, 1, 32))  AS served,
    bytearray_to_uint256(bytearray_substring(data, 33, 32)) AS failed,
    bytearray_to_uint256(bytearray_substring(data, 65, 32)) / 1e6 AS bond_musdc,
    block_time,
    row_number() OVER (PARTITION BY topic1 ORDER BY block_time DESC, index DESC) AS rn
  FROM arbitrum.logs
  WHERE contract_address = from_hex('{{registry}}')
    AND topic0 = 0x28f5094dca9ea9eddb3dee097e360810e4ec8eab9fb15299386a62c407f379fb
),
delisted AS (
  SELECT DISTINCT concat('0x', substr(cast(topic1 AS varchar), 27)) AS seller
  FROM arbitrum.logs
  WHERE contract_address = from_hex('{{registry}}')
    AND topic0 = 0x6beba25ba702991e7deea43b52c0ff4fb907e844eaebde689bf7f7fad0fbae62
)
SELECT
  r.seller,
  r.bond_musdc,
  r.served,
  r.failed,
  CASE WHEN r.served = 0 THEN 1.0
       ELSE 1.0 - CAST(r.failed AS double) / r.served END AS reliability,
  CASE WHEN d.seller IS NOT NULL THEN 'DELISTED' ELSE 'BONDED' END AS stamp
FROM rep r
LEFT JOIN delisted d ON d.seller = r.seller
WHERE r.rn = 1
ORDER BY reliability DESC, r.bond_musdc DESC;

-- ============================================================ Query 2
-- SLASH HISTORY — every slash: refunds to buyers FROM THE SELLER BOND
SELECT
  block_time,
  tx_hash,
  concat('0x', substr(cast(topic1 AS varchar), 27)) AS seller,
  bytearray_to_uint256(bytearray_substring(data, 1, 32))  / 1e6 AS refunded_to_buyers_musdc,
  bytearray_to_uint256(bytearray_substring(data, 33, 32)) / 1e6 AS penalty_musdc,
  bytearray_to_uint256(bytearray_substring(data, 65, 32))        AS failures,
  bytearray_to_uint256(bytearray_substring(data, 97, 32)) / 1e6 AS bond_remaining_musdc
FROM arbitrum.logs
WHERE contract_address = from_hex('{{registry}}')
  AND topic0 = 0x7eb07af5827932a7a49dbf7637f22f0eb9b9132019205a38f24754e27c72eff1
ORDER BY block_time DESC;

-- ============================================================ Query 3
-- PROTOCOL KPIs — headline counters for the dashboard top row
WITH pay AS (
  SELECT
    bytearray_to_uint256(bytearray_substring(data, 1, 32)) / 1e6 AS amount
  FROM arbitrum.logs
  WHERE contract_address = from_hex('{{router}}')
    AND topic0 = 0xd06f1cd9d937c2b94299a11c7e1cb5a260dfc188b5ec6c557466dcbfcb2fdd7f
),
anchored AS (
  SELECT count(*) AS n FROM arbitrum.logs
  WHERE contract_address = from_hex('{{cm}}')
    AND topic0 = 0xdc9e9498cbe1ceacc033ec48475aba7c41ad879489bf0eefbfaf4aeee376ff73
),
resolved AS (
  SELECT
    count(*) AS claims,
    sum(bytearray_to_uint256(bytearray_substring(data, 1, 32))) / 1e6 AS refunded_musdc
  FROM arbitrum.logs
  WHERE contract_address = from_hex('{{cm}}')
    AND topic0 = 0x55903d19a489b64a45cd5e2f89e821bf22fa899f44e3d3965a3c5fb3245c504f
)
SELECT
  (SELECT count(*) FROM pay)            AS payments_settled,
  (SELECT sum(amount) FROM pay)         AS volume_musdc,
  (SELECT avg(amount) FROM pay)         AS avg_payment_musdc, -- micropayment proof
  (SELECT n FROM anchored)              AS attestations_anchored,
  (SELECT claims FROM resolved)         AS claims_resolved,
  (SELECT refunded_musdc FROM resolved) AS refunded_from_bonds_musdc;

-- ============================================================ Query 4
-- PAYMENT FUNNEL — lifecycle mix over time (settled -> receipted/claimed/refunded)
-- status codes: 1 settled, 2 receipted, 3 claimed, 4 refunded, 5 released
WITH latest AS (
  SELECT
    bytearray_to_uint256(topic1) AS payment_id,
    bytearray_to_uint256(bytearray_substring(data, 1, 32)) AS status,
    row_number() OVER (PARTITION BY topic1 ORDER BY block_time DESC, index DESC) AS rn
  FROM arbitrum.logs
  WHERE contract_address = from_hex('{{router}}')
    AND topic0 = 0xf879d3b4028acb77eda7e8b250ce97ca51a46b47cb3482367d544fcf6fa4bdab
)
SELECT
  CASE status WHEN 2 THEN 'receipted (attested)'
              WHEN 3 THEN 'claimed'
              WHEN 4 THEN 'refunded from bond'
              WHEN 5 THEN 'released' END AS final_state,
  count(*) AS payments
FROM latest WHERE rn = 1
GROUP BY 1 ORDER BY 2 DESC;
