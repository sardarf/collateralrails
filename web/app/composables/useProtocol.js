// useProtocol — single composable holding chain state + actions (viem).
import { createPublicClient, createWalletClient, custom, http, parseAbi, parseUnits, formatUnits, keccak256, toHex } from 'viem'
import { resolveNetwork } from '~/config/networks'

export const ABI = {
  usdc: parseAbi([
    'function mint(address,uint256)',
    'function approve(address,uint256) returns (bool)',
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address,address) view returns (uint256)',
  ]),
  registry: parseAbi([
    'function register(uint256 bondAmount, string handle, string endpoint)',
    'function topUp(uint256)',
    'function requestWithdrawal()',
    'function executeWithdrawal()',
    'function isActive(address) view returns (bool)',
    'function sellerCount() view returns (uint256)',
    'function sellerList(uint256) view returns (address)',
    'function MIN_BOND() view returns (uint256)',
    'function WITHDRAW_COOLDOWN() view returns (uint256)',
    'function getSeller(address) view returns (uint256 bond,uint256 openExposure,uint32 served,uint32 failed,uint32 openClaims,uint256 slashedTotal,bool active,string endpoint,uint32 confirmed)',
    'function identity(address) view returns (string handle,string endpoint,bool endpointVerified)',
    'function reputation(address) view returns (uint16 score,uint8 tier,bool flagged)',
    'function handleOwner(bytes32) view returns (address)',
    'event SellerSlashed(address indexed seller,uint256 refundTotal,uint256 penalty,uint32 failures,uint256 remainingBond)',
  ]),
  router: parseAbi([
    'function deposit(uint256)',
    'function withdraw(uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function pay(address seller,uint256 amount,bytes32 requestHash) returns (uint256)',
    'function releaseExpired(uint256)',
    'function RECEIPT_WINDOW() view returns (uint256)',
    'function CLAIM_WINDOW() view returns (uint256)',
    'event PaymentSettled(uint256 indexed paymentId,address indexed buyer,address indexed seller,uint256 amount,bytes32 requestHash,uint64 receiptDeadline)',
    'event PaymentStatusChanged(uint256 indexed paymentId,uint8 status)',
  ]),
  cm: parseAbi([
    'struct Attestation { uint256 paymentId; bytes32 requestHash; bytes32 responseHash }',
    'function attest(Attestation a, bytes sig)',
    'function fileClaim(address seller, uint256[] paymentIds) returns (uint256)',
    'function defend(uint256 claimId, uint256[] paymentIds)',
    'function resolve(uint256 claimId)',
    'function attestationOf(uint256) view returns (bytes32 sellerHash,uint64 sellerAt,bytes32 buyerHash,uint64 buyerAt)',
    'function MIN_BATCH() view returns (uint256)',
    'function HIGH_VALUE_THRESHOLD() view returns (uint256)',
    'function DEFENSE_WINDOW() view returns (uint256)',
    'function getClaim(uint256) view returns (address watcher,address seller,uint256 refundTotal,uint256 stake,uint64 defenseEnd,bool resolved,uint32 defendedCount,uint256[] paymentIds)',
    'event AttestationAnchored(uint256 indexed paymentId,address indexed signer,bool sellerSide,bytes32 responseHash)',
    'event ClaimFiled(uint256 indexed claimId,address indexed seller,address indexed watcher,uint256 count,uint256 refundTotal,uint64 defenseEnd)',
    'event ClaimResolved(uint256 indexed claimId,uint256 refunded,uint256 slashedPenalty,uint32 defended,uint32 failed)',
  ]),
  policy: parseAbi([
    'function setPolicy(uint128 maxPerPayment,uint128 budget,uint64 expiry,bool requireBonded,bool useAllowlist)',
    'function policies(address) view returns (uint128 maxPerPayment,uint128 budget,uint128 spent,uint64 expiry,bool requireBonded,bool useAllowlist,bool exists)',
  ]),
}

// SettlementRouter.Status enum — one entry per on-chain status code.
export const S = {
  None: 0, Settled: 1, SellerAttested: 2, BuyerAttested: 3,
  DeliveryConfirmed: 4, HashMismatch: 5, Claimed: 6, Refunded: 7, Released: 8,
}

// Presentation for each stored status. `tone` maps to a .pill / .badge colour.
export const STATUS = [
  { key: 'none', label: '—', tone: 'muted' },
  { key: 'settled', label: 'Paid', tone: 'warn' },
  { key: 'seller-attested', label: 'Seller attested', tone: 'cool' },
  { key: 'buyer-attested', label: 'Buyer attested', tone: 'cool' },
  { key: 'confirmed', label: 'Delivery confirmed', tone: 'ok' },
  { key: 'mismatch', label: 'Hash mismatch', tone: 'bad' },
  { key: 'claimed', label: 'Claim filed', tone: 'bad' },
  { key: 'refunded', label: 'Refunded', tone: 'ok' },
  { key: 'released', label: 'Released', tone: 'muted' },
]

// Human-readable seller status derived from on-chain signals (§2).
export function sellerStatus(s) {
  if (!s.active) return s.slashedTotal > 0n && s.failed >= s.served ? 'Delisted' : (s.withdrawing ? 'Exiting' : 'Delisted')
  if (s.openClaims > 0) return 'Under Claim'
  if (s.bond > 0n && s.openExposure >= s.bond) return 'Capacity Limited'
  return 'Active'
}

// Effective phase of a payment, factoring in the current clock. Turns the
// stored status into the richer lifecycle language of §8 (evidence incomplete,
// claimable) without overloading any single stored status.
export function paymentPhase(p, now) {
  const pre = [S.Settled, S.SellerAttested, S.BuyerAttested, S.HashMismatch]
  if (pre.includes(p.status) && now > p.receiptDeadline) {
    if (p.status === S.HashMismatch) return { key: 'disputed', label: 'Disputed — claimable', tone: 'bad' }
    if (p.status === S.Settled) return { key: 'claimable', label: 'No delivery — claimable', tone: 'bad' }
    if (p.status === S.SellerAttested) return { key: 'incomplete', label: 'Evidence incomplete (buyer missing)', tone: 'warn' }
    return { key: 'incomplete', label: 'Evidence incomplete (seller missing)', tone: 'bad' }
  }
  return STATUS[p.status] || STATUS[0]
}

// Reputation tiers, indexed by the on-chain tier code from reputation().
export const REP_TIERS = [
  { key: 'new', label: 'New', hint: 'No confirmed deliveries yet — unproven, no matter the deposit size.' },
  { key: 'building', label: 'Building', hint: 'Starting to deliver — a short but clean track record.' },
  { key: 'established', label: 'Established', hint: 'A solid, reliable delivery history.' },
  { key: 'trusted', label: 'Trusted', hint: 'High volume, high reliability, clean record.' },
  { key: 'flagged', label: 'Flagged', hint: 'Has been penalized for non-delivery — treat with caution.' },
]

// Well-known anvil demo accounts → the role each one plays in the walkthrough.
export const DEMO_ROLES = {
  '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266': { role: 'Owner', tab: '/', hint: 'Set up the contracts — you won’t usually need this account for the demo.' },
  '0x70997970c51812dc3a010c7d01b50e0d17dc79c8': { role: 'Seller · reliable', tab: '/sell', hint: 'Go to Sell → add a deposit, then confirm each delivery so the buyer can match it.' },
  '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc': { role: 'Seller · unreliable', tab: '/sell', hint: 'Go to Sell → add a deposit, then DON’T confirm deliveries — this deposit gets penalized.' },
  '0x90f79bf6eb2c4f870365e785982e1f101e93b906': { role: 'Buyer / Agent', tab: '/agent', hint: 'Go to Buy → set spending limits, add funds, buy from a bonded seller, then confirm receipt.' },
  '0x15d34aaf54267db7d7c367839aaf71a00a2c6a65': { role: 'Watcher', tab: '/watchtower', hint: 'Go to Disputes → report sellers who didn’t deliver, then resolve to apply the penalty.' },
}
export const roleOf = (a) => (a ? DEMO_ROLES[a.toLowerCase()] || null : null)
const ev = (abi, name) => abi.find((i) => i.type === 'event' && i.name === name)

// The per-payment response commitment. Seller and buyer must sign the SAME bytes
// to confirm delivery. The demo uses this deterministic string as the "delivered
// artifact" so both sides can reproduce it; a `salt` forces a mismatch on demand.
export const responseHashFor = (id, salt = '') => keccak256(toHex(`response:${id}${salt}`))

const state = reactive({
  account: null,
  now: Math.floor(Date.now() / 1000),
  chainOk: false,
  network: '',
  chainName: '',
  explorer: '',
  sellers: [], // + confirmed, repScore/repTier/flagged
  payments: [], // + sellerAttested/buyerAttested/sellerHash/buyerHash
  claims: [],
  slashes: [],
  minBond: 0n,
  minBatch: 3n,
  highValue: 0n,
  receiptWindow: 0n,
  defenseWindow: 0n,
  cooldown: 0n,
  balances: {},
  allowance: { registry: 0n, router: 0n, cm: 0n },
  policySet: false,
  busy: false,
  log: '',
})

let pub, chain, cfg, net, started = false

export function useProtocol() {
  if (!cfg) {
    net = resolveNetwork(useRuntimeConfig().public)
    cfg = { ...net.contracts, rpc: net.rpc, chainId: net.chainId, deployBlock: net.deployBlock }
    chain = net.chain
    state.network = net.key
    state.chainName = chain.name
    state.explorer = net.explorer
  }
  pub ||= createPublicClient({ chain, transport: http(cfg.rpc) })

  const wallet = () => createWalletClient({ chain, transport: custom(window.ethereum) })
  const hexChainId = () => '0x' + Number(cfg.chainId).toString(16)

  async function ensureChain() {
    const eth = window.ethereum
    if ((await eth.request({ method: 'eth_chainId' })) === hexChainId()) return
    try {
      await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hexChainId() }] })
    } catch (e) {
      if (e.code === 4902 || e.code === -32603) {
        await eth.request({ method: 'wallet_addEthereumChain', params: [{
          chainId: hexChainId(), chainName: chain.name,
          nativeCurrency: chain.nativeCurrency, rpcUrls: [cfg.rpc],
          blockExplorerUrls: net.explorer ? [net.explorer] : undefined,
        }] })
      } else throw e
    }
  }

  async function connect() {
    const eth = window.ethereum
    if (!eth) {
      state.log = 'No wallet detected — install MetaMask, then reload this page.'
      return
    }
    state.busy = true
    state.log = 'Check MetaMask to approve the connection…'
    try {
      const [account] = await eth.request({ method: 'eth_requestAccounts' })
      state.account = account
      await ensureChain()
      state.log = `Connected ${account.slice(0, 6)}…${account.slice(-4)} on ${chain.name}`
      eth.on?.('accountsChanged', (a) => { state.account = a?.[0] || null })
      eth.on?.('chainChanged', () => { refresh() })
      await refresh()
    } catch (e) {
      if (e.code === -32002) state.log = 'A wallet request is already pending — open the MetaMask extension and approve it.'
      else if (e.code === 4001) state.log = 'Connection rejected in the wallet.'
      else state.log = `Connect failed: ${e.shortMessage || e.message}`
    } finally {
      state.busy = false
    }
  }

  async function refresh() {
    if (!cfg.registry) {
      state.chainOk = false
      state.log = `No contract addresses configured for "${net.key}". Set NUXT_PUBLIC_USDC/REGISTRY/POLICY/ROUTER/CM for this deployment.`
      return
    }
    try {
      state.now = Number((await pub.getBlock()).timestamp)
      state.chainOk = true

      // sellers
      const count = Number(await pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'sellerCount' }))
      const sellers = []
      for (let i = 0; i < count; i++) {
        const address = await pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'sellerList', args: [BigInt(i)] })
        const [s, id, rep] = await Promise.all([
          pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'getSeller', args: [address] }),
          pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'identity', args: [address] }),
          pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'reputation', args: [address] }),
        ])
        sellers.push({
          address, bond: s[0], openExposure: s[1], served: s[2], failed: s[3], openClaims: s[4],
          slashedTotal: s[5], active: s[6], endpoint: s[7], confirmed: Number(s[8]),
          handle: id[0], verified: id[2],
          repScore: Number(rep[0]), repTier: Number(rep[1]), flagged: rep[2],
        })
      }
      state.sellers = sellers
      state.minBond = await pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'MIN_BOND' })
      state.cooldown = await pub.readContract({ address: cfg.registry, abi: ABI.registry, functionName: 'WITHDRAW_COOLDOWN' })
      state.minBatch = await pub.readContract({ address: cfg.cm, abi: ABI.cm, functionName: 'MIN_BATCH' })
      state.highValue = await pub.readContract({ address: cfg.cm, abi: ABI.cm, functionName: 'HIGH_VALUE_THRESHOLD' })
      state.receiptWindow = await pub.readContract({ address: cfg.router, abi: ABI.router, functionName: 'RECEIPT_WINDOW' })
      state.defenseWindow = await pub.readContract({ address: cfg.cm, abi: ABI.cm, functionName: 'DEFENSE_WINDOW' })

      // payments + statuses + attestations from logs
      const fromBlock = BigInt(cfg.deployBlock || 0)
      const [settled, statuses, atts] = await Promise.all([
        pub.getLogs({ address: cfg.router, event: ev(ABI.router, 'PaymentSettled'), fromBlock }),
        pub.getLogs({ address: cfg.router, event: ev(ABI.router, 'PaymentStatusChanged'), fromBlock }),
        pub.getLogs({ address: cfg.cm, event: ev(ABI.cm, 'AttestationAnchored'), fromBlock }),
      ])
      const map = new Map()
      for (const l of settled) {
        map.set(l.args.paymentId.toString(), {
          id: l.args.paymentId, buyer: l.args.buyer, seller: l.args.seller,
          amount: l.args.amount, requestHash: l.args.requestHash,
          receiptDeadline: Number(l.args.receiptDeadline), status: 1,
          sellerAttested: false, buyerAttested: false, sellerHash: null, buyerHash: null,
        })
      }
      for (const l of statuses) {
        const p = map.get(l.args.paymentId.toString())
        if (p) p.status = Number(l.args.status)
      }
      for (const l of atts) {
        const p = map.get(l.args.paymentId.toString())
        if (!p) continue
        if (l.args.sellerSide) { p.sellerAttested = true; p.sellerHash = l.args.responseHash }
        else { p.buyerAttested = true; p.buyerHash = l.args.responseHash }
      }
      state.payments = [...map.values()].sort((a, b) => Number(b.id - a.id))

      // claims
      const filed = await pub.getLogs({ address: cfg.cm, event: ev(ABI.cm, 'ClaimFiled'), fromBlock })
      const claims = []
      for (const l of filed) {
        const c = await pub.readContract({ address: cfg.cm, abi: ABI.cm, functionName: 'getClaim', args: [l.args.claimId] })
        claims.push({ id: l.args.claimId, watcher: c[0], seller: c[1], refundTotal: c[2], stake: c[3], defenseEnd: Number(c[4]), resolved: c[5], defendedCount: c[6], paymentIds: c[7] })
      }
      state.claims = claims.sort((a, b) => Number(b.id - a.id))

      // slash history
      const slashed = await pub.getLogs({ address: cfg.registry, event: ev(ABI.registry, 'SellerSlashed'), fromBlock })
      state.slashes = slashed.map((l) => ({ seller: l.args.seller, refundTotal: l.args.refundTotal, penalty: l.args.penalty, failures: l.args.failures, remainingBond: l.args.remainingBond })).reverse()

      // balances for known demo accounts + connected account
      const accts = new Set(Object.keys(DEMO_ROLES))
      if (state.account) accts.add(state.account.toLowerCase())
      const balances = {}
      for (const a of accts) {
        const [usdc, rail] = await Promise.all([
          pub.readContract({ address: cfg.usdc, abi: ABI.usdc, functionName: 'balanceOf', args: [a] }),
          pub.readContract({ address: cfg.router, abi: ABI.router, functionName: 'balanceOf', args: [a] }),
        ])
        balances[a] = { usdc, rail }
      }
      state.balances = balances

      // allowances + policy for the connected account
      if (state.account) {
        const a = state.account
        const [registry, router, cm] = await Promise.all([
          pub.readContract({ address: cfg.usdc, abi: ABI.usdc, functionName: 'allowance', args: [a, cfg.registry] }),
          pub.readContract({ address: cfg.usdc, abi: ABI.usdc, functionName: 'allowance', args: [a, cfg.router] }),
          pub.readContract({ address: cfg.usdc, abi: ABI.usdc, functionName: 'allowance', args: [a, cfg.cm] }),
        ])
        state.allowance = { registry, router, cm }
        const pol = await pub.readContract({ address: cfg.policy, abi: ABI.policy, functionName: 'policies', args: [a] })
        state.policySet = pol[6]
      } else {
        state.allowance = { registry: 0n, router: 0n, cm: 0n }
        state.policySet = false
      }
    } catch (e) {
      state.chainOk = false
    }
  }

  async function tx(label, fn) {
    if (!state.account) { state.log = 'Connect a wallet first (top-right).'; return }
    state.busy = true
    state.log = `${label}…`
    try {
      await ensureChain()
      const hash = await fn(wallet())
      await pub.waitForTransactionReceipt({ hash })
      state.log = `${label} ✓ ${hash.slice(0, 18)}…`
      await refresh()
    } catch (e) {
      state.log = `${label} failed: ${e.shortMessage || e.message}`
    } finally {
      state.busy = false
    }
  }

  const write = (address, abi, functionName, args, label) =>
    tx(label, (w) => w.writeContract({ address, abi, functionName, args, account: state.account }))

  // Sign + submit an EIP-712 delivery attestation as the connected account. The
  // contract routes it to the seller or buyer side based on the recovered signer.
  async function attestAs(payment, { salt = '', label } = {}) {
    const a = { paymentId: payment.id, requestHash: payment.requestHash, responseHash: responseHashFor(payment.id, salt) }
    const sig = await wallet().signTypedData({
      account: state.account,
      domain: { name: 'CollateralRails', version: '1', chainId: Number(cfg.chainId), verifyingContract: cfg.cm },
      types: { Attestation: [
        { name: 'paymentId', type: 'uint256' }, { name: 'requestHash', type: 'bytes32' }, { name: 'responseHash', type: 'bytes32' },
      ] },
      primaryType: 'Attestation', message: a,
    })
    return tx(label || `Attest delivery #${payment.id}`, (w) =>
      w.writeContract({ address: cfg.cm, abi: ABI.cm, functionName: 'attest', args: [a, sig], account: state.account }))
  }

  const usd = (v) => parseUnits(String(v), 6)
  const actions = {
    connect,
    mint: (amount) => write(cfg.usdc, ABI.usdc, 'mint', [state.account, usd(amount)], `Mint ${amount} mUSDC`),
    approveRegistry: () => write(cfg.usdc, ABI.usdc, 'approve', [cfg.registry, 2n ** 256n - 1n], 'Approve registry'),
    approveRouter: () => write(cfg.usdc, ABI.usdc, 'approve', [cfg.router, 2n ** 256n - 1n], 'Approve router'),
    approveCm: () => write(cfg.usdc, ABI.usdc, 'approve', [cfg.cm, 2n ** 256n - 1n], 'Approve claims'),
    register: (bond, handle, endpoint) => write(cfg.registry, ABI.registry, 'register', [usd(bond), handle, endpoint], 'Place deposit & list service'),
    topUp: (amount) => write(cfg.registry, ABI.registry, 'topUp', [usd(amount)], 'Top up bond'),
    requestWithdrawal: () => write(cfg.registry, ABI.registry, 'requestWithdrawal', [], 'Request withdrawal'),
    executeWithdrawal: () => write(cfg.registry, ABI.registry, 'executeWithdrawal', [], 'Execute withdrawal'),
    setPolicy: (cap, budget, days, bondedOnly) => write(cfg.policy, ABI.policy, 'setPolicy',
      [usd(cap), usd(budget), BigInt(state.now + days * 86400), bondedOnly, false], 'Set policy'),
    deposit: (amount) => write(cfg.router, ABI.router, 'deposit', [usd(amount)], 'Fund balance'),
    pay: (seller, amount) => write(cfg.router, ABI.router, 'pay',
      [seller, usd(amount), keccak256(toHex(`req:${seller}:${Date.now()}:${Math.random()}`))], `Pay $${amount}`),
    releaseExpired: (id) => write(cfg.router, ABI.router, 'releaseExpired', [id], `Recycle capacity #${id}`),
    fileClaim: (seller, ids) => write(cfg.cm, ABI.cm, 'fileClaim', [seller, ids], `File batch claim (${ids.length} failures)`),
    resolve: (id) => write(cfg.cm, ABI.cm, 'resolve', [id], `Resolve claim #${id}`),

    // Seller confirms delivery, buyer confirms receipt — both sign the same bytes.
    attest: (payment) => attestAs(payment, { label: `Attest delivery #${payment.id}` }),
    // Deliberately sign a different artifact — used to demonstrate a hash mismatch.
    attestMismatch: (payment) => attestAs(payment, { salt: ':dispute', label: `Attest (mismatch) #${payment.id}` }),

    // Defend a claim using only the seller's on-time committed evidence: pass the
    // payments in this claim that the seller attested on time with no buyer conflict.
    defend(claim) {
      const defensible = state.payments
        .filter((p) => claim.paymentIds.includes(p.id) && p.status === S.Claimed
          && p.sellerAttested && (!p.buyerAttested || p.buyerHash === p.sellerHash))
        .map((p) => p.id)
      if (!defensible.length) { state.log = 'Nothing to defend — no on-time delivery evidence was committed for this claim.'; return Promise.resolve() }
      return write(cfg.cm, ABI.cm, 'defend', [claim.id, defensible], `Defend claim #${claim.id} (${defensible.length} with committed evidence)`)
    },
  }

  if (!started && import.meta.client) {
    started = true
    refresh()
    setInterval(refresh, 4000)
    setInterval(() => { state.now += 1 }, 1000)
  }

  const fmt = (v) => formatUnits(v ?? 0n, 6)
  const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '')
  return { state, actions, fmt, short, refresh, cfg }
}