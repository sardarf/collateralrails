// Display-only presentation helpers — no protocol logic, reads nothing on-chain.
// Maps raw seller handles to friendly names/categories and remaps payment
// statuses to plain buyer-facing language. Safe to edit freely.

// Friendly provider names, keyed by the on-chain handle (lower-cased).
const NAMES = {
  'aeris-data': 'Aeris Data Network',
  'routeguard': 'RouteGuard API',
  'signalforge': 'SignalForge Labs',
  'weatheroracle': 'Aeris Data Network',
  'alphasignals': 'SignalForge Labs',
}

// Human category label for a provider (there is no on-chain category field).
const CATEGORIES = {
  'aeris-data': 'Market data',
  'routeguard': 'API infrastructure',
  'signalforge': 'Trading signals',
  'weatheroracle': 'Market data',
  'alphasignals': 'Trading signals',
}

export const providerName = (handle) => NAMES[(handle || '').toLowerCase()] || handle || 'Unnamed provider'
export const providerCategory = (s) => CATEGORIES[(s?.handle || '').toLowerCase()] || 'Service provider'

// Plain-language status shown as a badge on the Buy page, keyed by the phase
// `key` produced by paymentPhase()/STATUS in the composable.
const BUY_STATUS = {
  none: { label: 'Awaiting provider attestation', tone: 'warn' },
  settled: { label: 'Awaiting provider attestation', tone: 'warn' },
  'seller-attested': { label: 'Awaiting buyer confirmation', tone: 'sky' },
  'buyer-attested': { label: 'Awaiting provider attestation', tone: 'warn' },
  confirmed: { label: 'Delivered', tone: 'ok' },
  claimable: { label: 'Refund eligible', tone: 'bad' },
  incomplete: { label: 'Refund eligible', tone: 'warn' },
  mismatch: { label: 'Disputed', tone: 'bad' },
  disputed: { label: 'Disputed', tone: 'bad' },
  claimed: { label: 'Disputed', tone: 'bad' },
  refunded: { label: 'Refunded from bond', tone: 'ok' },
  released: { label: 'Released', tone: 'muted' },
}

export const buyStatus = (phase) => BUY_STATUS[phase?.key] || { label: phase?.label || '—', tone: phase?.tone || 'muted' }