#!/usr/bin/env node
// Minimal CLI watcher: index PaymentSettled → track receipt deadlines →
// aggregate per-seller failures → file ONE batch claim per seller → resolve
// after the defense window. JSON-file persistence (zero infra). Permissionless:
// anyone can run this; the penalty share pays for it.
//
// Usage:
//   RPC=... PRIVATE_KEY=... node src/cli.mjs watch [--interval 5]
//   node src/cli.mjs status
import { ethers } from "ethers";
import fs from "fs";
import { WatcherCore } from "./core.mjs";
import { connect, loadDeployment } from "./chain.mjs";

const STATE_FILE = process.env.STATE_FILE || "watcher-state.json";

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); }
  catch { return { lastBlock: 0, payments: {}, claims: {} }; }
}
function saveState(core, lastBlock) {
  fs.writeFileSync(STATE_FILE, JSON.stringify({
    lastBlock,
    payments: Object.fromEntries([...core.payments].map(([k, v]) => [k, { ...v, amount: v.amount.toString() }])),
    claims: Object.fromEntries(core.claims),
  }, null, 2));
}
function hydrate(core, state) {
  for (const [k, v] of Object.entries(state.payments)) core.payments.set(k, { ...v, amount: BigInt(v.amount) });
  for (const [k, v] of Object.entries(state.claims)) core.claims.set(k, v);
}

async function main() {
  const cmd = process.argv[2] || "watch";
  const dep = loadDeployment();
  const provider = new ethers.JsonRpcProvider(process.env.RPC || dep.rpc);
  const state = loadState();

  if (cmd === "status") {
    const core = new WatcherCore({ minBatch: 3, highValueThreshold: 50_000_000n, claimWindow: 86_400 });
    hydrate(core, state);
    console.log(JSON.stringify(core.status(Math.floor(Date.now() / 1000)), null, 2));
    return;
  }

  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  const c = connect(dep, wallet);
  const cfg = {
    minBatch: Number(await c.cm.MIN_BATCH()),
    highValueThreshold: await c.cm.HIGH_VALUE_THRESHOLD(),
    claimWindow: Number(await c.router.CLAIM_WINDOW()),
  };
  const core = new WatcherCore(cfg);
  hydrate(core, state);
  console.log(`[watcher] ${wallet.address} cfg=${JSON.stringify({ ...cfg, highValueThreshold: cfg.highValueThreshold.toString() })}`);

  // one-time allowance for claim stakes
  await (await c.usdc.approve(dep.cm, ethers.MaxUint256)).wait();

  const interval = Number(process.env.INTERVAL || 5) * 1000;
  let last = state.lastBlock || (await provider.getBlockNumber()) - 1;

  async function tick() {
    const head = await provider.getBlockNumber();
    if (head > last) {
      const from = last + 1;
      for (const ev of await c.router.queryFilter(c.router.filters.PaymentSettled(), from, head)) {
        const [paymentId, buyer, seller, amount, , receiptDeadline] = ev.args;
        core.onPaymentSettled({ paymentId, buyer, seller, amount, receiptDeadline });
        console.log(`[+] payment ${paymentId} ${ethers.formatUnits(amount, 6)} mUSDC -> ${seller} (attest by ${receiptDeadline})`);
      }
      for (const ev of await c.router.queryFilter(c.router.filters.PaymentStatusChanged(), from, head)) {
        core.onStatusChanged({ paymentId: ev.args[0], status: Number(ev.args[1]) });
      }
      for (const ev of await c.cm.queryFilter(c.cm.filters.ClaimFiled(), from, head)) {
        const claim = await c.cm.getClaim(ev.args[0]).catch(() => null);
        core.onClaimFiled({
          claimId: ev.args[0], seller: ev.args[1],
          paymentIds: claim ? claim[7] : [], defenseEnd: Number(ev.args[5]),
        });
        console.log(`[!] claim ${ev.args[0]} filed vs ${ev.args[1]} (defense ends ${ev.args[5]})`);
      }
      for (const ev of await c.cm.queryFilter(c.cm.filters.ClaimResolved(), from, head)) {
        core.onClaimResolved({ claimId: ev.args[0] });
        console.log(`[✓] claim ${ev.args[0]} resolved: refunded=${ethers.formatUnits(ev.args[1], 6)} failed=${ev.args[4]}`);
      }
      last = head;
    }

    const now = (await provider.getBlock("latest")).timestamp;

    // file due batch claims (one per seller)
    for (const due of core.dueClaims(now)) {
      console.log(`[⚔] filing batch claim vs ${due.seller}: ${due.paymentIds.length} failures, ${ethers.formatUnits(due.refundTotal, 6)} mUSDC refunds`);
      try {
        const tx = await c.cm.fileClaim(due.seller, due.paymentIds);
        await tx.wait();
      } catch (e) { console.error(`[x] fileClaim failed: ${e.shortMessage || e.message}`); }
    }

    // resolve claims past their defense window
    for (const claimId of core.resolvable(now)) {
      console.log(`[⚖] resolving claim ${claimId}`);
      try {
        const tx = await c.cm.resolve(claimId);
        await tx.wait();
        core.onClaimResolved({ claimId });
      } catch (e) { console.error(`[x] resolve failed: ${e.shortMessage || e.message}`); }
    }

    saveState(core, last);
  }

  await tick();
  if (process.env.ONCE) return;
  setInterval(() => tick().catch((e) => console.error(e.message)), interval);
}

main().catch((e) => { console.error(e); process.exit(1); });
