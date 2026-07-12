#!/usr/bin/env node
// Full demo story against a local anvil node (uses evm_increaseTime).
//   anvil &
//   (cd ../smart-contracts && forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast)
//   (write addresses into watcher/deployment.json)
//   node src/demo.mjs
import { ethers } from "ethers";
import { connect, loadDeployment, signAttestation } from "./chain.mjs";
import { WatcherCore } from "./core.mjs";

const dep = loadDeployment();
const provider = new ethers.JsonRpcProvider(process.env.RPC || dep.rpc || "http://localhost:8545");
// anvil default keys
const K = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // deployer
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // honest
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // deadbeat
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // buyer
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a", // watcher
];
const [deployer, honest, deadbeat, buyer, watcher] = K.map((k) => new ethers.Wallet(k, provider));
const step = (m) => console.log(`\n=== ${m} ===`);
const warp = async (s) => { await provider.send("evm_increaseTime", [s]); await provider.send("evm_mine", []); };
// Read the latest block timestamp via a raw RPC call. ethers' getBlock("latest")
// is served from a short-lived cache that our evm_mine calls don't invalidate, so
// it returns a stale clock; a direct send always reflects the current head.
const chainNow = async () => parseInt((await provider.send("eth_getBlockByNumber", ["latest", false])).timestamp, 16);
// Warp forward until the chain clock is past `ts`. evm_increaseTime offsets
// wallclock, but instant-mining inflates block timestamps ahead of wallclock, so a
// relative bump undershoots. Set an ABSOLUTE next-block timestamp instead.
const warpTo = async (ts) => {
  const now = await chainNow();
  await provider.send("evm_setNextBlockTimestamp", [Math.max(Number(ts) + 2, now + 1)]);
  await provider.send("evm_mine", []);
};
const { chainId } = await provider.getNetwork();

step("1. Sellers stake performance bonds");
for (const [wlt, name] of [[honest, "WeatherOracle"], [deadbeat, "AlphaSignals"]]) {
  const c = connect(dep, wlt);
  const bond = ethers.parseUnits("500", 6);
  await (await c.usdc.mint(wlt.address, bond)).wait();
  await (await c.usdc.approve(dep.registry, ethers.MaxUint256)).wait();
  await (await c.registry.register(bond, name, `https://${name.toLowerCase()}.example`)).wait();
  console.log(`${name} bonded 500 mUSDC -> listed as "${name}"`);
}

// The verifier (deployer key by default) attests endpoint ownership. WeatherOracle
// gets a verified badge; AlphaSignals stays unverified so the contrast is visible.
const cv = connect(dep, deployer);
await (await cv.registry.verifyEndpoint(honest.address)).wait();
console.log("verifier ✓ WeatherOracle endpoint verified (AlphaSignals left unverified)");

step("2. Agent sets policy and buys 5 x $0.10 calls from each (instant settle, zero escrow)");
const cb = connect(dep, buyer);
await (await cb.usdc.mint(buyer.address, ethers.parseUnits("100", 6))).wait();
await (await cb.usdc.approve(dep.router, ethers.MaxUint256)).wait();
await (await cb.policy.setPolicy(ethers.parseUnits("0.20", 6), ethers.parseUnits("500", 6), Math.floor(Date.now() / 1000) + 864000, true, false)).wait();
await (await cb.router.deposit(ethers.parseUnits("50", 6))).wait();
const paid = { honest: [], deadbeat: [] };
for (const [wlt, tag] of [[honest, "honest"], [deadbeat, "deadbeat"]]) {
  for (let i = 0; i < 5; i++) {
    const reqHash = ethers.keccak256(ethers.toUtf8Bytes(`req:${tag}:${i}`));
    const rc = await (await cb.router.pay(wlt.address, ethers.parseUnits("0.10", 6), reqHash)).wait();
    const ev = rc.logs.map((l) => { try { return cb.router.interface.parseLog(l); } catch { return null; } }).find((p) => p?.name === "PaymentSettled");
    paid[tag].push({ id: ev.args[0], reqHash, deadline: Number(ev.args[5]) });
  }
  console.log(`5 payments settled instantly to ${tag}`);
}

step("3. WeatherOracle delivers: seller AND buyer sign the same response bytes (dual attestation); AlphaSignals goes dark");
const ch = connect(dep, honest);
for (const p of paid.honest) {
  const a = { paymentId: p.id, requestHash: p.reqHash, responseHash: ethers.keccak256(ethers.toUtf8Bytes("rsp" + p.id)) };
  // Seller anchors its side, then the buyer anchors the matching side -> DeliveryConfirmed.
  await (await ch.cm.attest(a, await signAttestation(honest, dep.cm, chainId, a))).wait();
  await (await cb.cm.attest(a, await signAttestation(buyer, dep.cm, chainId, a))).wait();
}
console.log("5 deliveries CONFIRMED (matching dual attestations) — WeatherOracle bond capacity fully recycled");

step("4. Receipt deadlines expire; watcher aggregates ONE batch claim");
await warpTo(Math.max(...paid.deadbeat.map((p) => p.deadline)));
const core = new WatcherCore({ minBatch: 3, highValueThreshold: ethers.parseUnits("50", 6), claimWindow: 86400 });
for (const tag of ["honest", "deadbeat"]) for (const p of paid[tag]) core.onPaymentSettled({ paymentId: p.id, seller: tag === "honest" ? honest.address : deadbeat.address, buyer: buyer.address, amount: ethers.parseUnits("0.10", 6), receiptDeadline: p.deadline });
for (const p of paid.honest) core.onStatusChanged({ paymentId: p.id, status: 4 }); // DeliveryConfirmed
const nowTs = await chainNow();
const due = core.dueClaims(nowTs);
console.log(`watcher decision: ${due.length} claim due -> seller ${due[0].seller}, ${due[0].paymentIds.length} failures, $${ethers.formatUnits(due[0].refundTotal, 6)} refunds`);
const cw = connect(dep, watcher);
await (await cw.usdc.mint(watcher.address, ethers.parseUnits("100", 6))).wait();
await (await cw.usdc.approve(dep.cm, ethers.MaxUint256)).wait();
await (await cw.cm.fileClaim(due[0].seller, due[0].paymentIds.map(BigInt))).wait();
console.log("batch claim filed (watcher staked)");

step("5. Defense window elapses with no receipts — SLASH");
await warpTo(Number((await cw.cm.getClaim(1))[4])); // claim.defenseEnd
const before = await cw.usdc.balanceOf(buyer.address);
await (await cw.cm.resolve(1)).wait();
const after = await cw.usdc.balanceOf(buyer.address);
console.log(`buyer refunded $${ethers.formatUnits(after - before, 6)} FROM THE SELLER PERFORMANCE BOND`);
const s = await cw.registry.getSeller(deadbeat.address);
console.log(`AlphaSignals: bond ${ethers.formatUnits(s[0], 6)} mUSDC, failures ${s[3]}, active=${s[6]} (DELISTED)`);
console.log("\nDEMO COMPLETE");
