export default defineNuxtConfig({
  ssr: false,
  compatibilityDate: '2026-07-08',
  devtools: { enabled: false },
  vite: {
    optimizeDeps: { include: ['viem'] },
    // Allow the dev server to be reached through an ngrok tunnel (host-header check).
    server: { allowedHosts: ['.ngrok-free.dev', '.ngrok-free.app', '.ngrok.io', 'collateralrails-sepolia.demo'] },
  },
  css: [
    '@fontsource/fraunces/600.css',
    '@fontsource/ibm-plex-sans/400.css',
    '@fontsource/ibm-plex-sans/600.css',
    '@fontsource/ibm-plex-mono/400.css',
    '@fontsource/ibm-plex-mono/600.css',
    '~/assets/main.css',
  ],
  // All keys are overridable per deployment via NUXT_PUBLIC_* env vars (e.g. on Vercel).
  // `network` picks a chain preset (see app/config/networks.js); the rest fall back to
  // that preset's defaults when left blank. See .env.example for the full list.
  runtimeConfig: {
    public: {
      network: 'local', // local | arbitrumSepolia | arbitrum | avalancheFuji | avalanche
      rpc: '', // blank → use the selected network's public RPC
      usdc: '',
      registry: '',
      policy: '',
      router: '',
      cm: '',
      deployBlock: 0,
    },
  },
  app: {
    head: {
      title: 'CollateralRails — Bonded Registry',
      meta: [{ name: 'description', content: 'Sellers stake to be trusted by AI agents. Refunds are paid from the seller performance bond — buyer funds are never escrowed.' }],
    },
  },
})
