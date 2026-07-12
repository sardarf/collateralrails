// Watcher selftest — proves WatcherCore's decision logic against real
// contract logs from the in-process EVM (no RPC needed).
// Run from repo root:  (cd smart-contracts && SAVE=1 node compile.js src/*.sol) && node watcher/src/selftest.mjs
import { VM } from "@ethereumjs/vm";
import { Block } from "@ethereumjs/block";
import { LegacyTransaction } from "@ethereumjs/tx";
import { Common, Hardfork, Chain } from "@ethereumjs/common";
import { Account, Address, hexToBytes, bytesToHex } from "@ethereumjs/util";
import { ethers } from "ethers";
import fs from "fs";
import { WatcherCore } from "./core.mjs";

const build = JSON.parse(fs.readFileSync("smart-contracts/out-js/build.json", "utf8"));
const artifact = (name) => {
  for (const f of Object.keys(build)) if (build[f][name])
    return { abi: build[f][name].abi, bytecode: "0x" + build[f][name].evm.bytecode.object };
  throw new Error("missing " + name);
};

const common = new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Shanghai });
const vm = await VM.create({ common });
const keys = { deployer: "0x" + "11".repeat(32), honest: "0x" + "22".repeat(32), deadbeat: "0x" + "33".repeat(32), buyer: "0x" + "44".repeat(32), watcher: "0x" + "55".repeat(32), treasury: "0x" + "66".repeat(32) };
const w = {}, nonces = {};
for (const [n, k] of Object.entries(keys)) {
  w[n] = new ethers.Wallet(k); nonces[n] = 0n;
  await vm.stateManager.putAccount(Address.fromString(w[n].address), new Account(0n, 10n ** 24n));
}
let now = 1_900_000_000n;
const blockAt = (ts) => Block.fromBlockData({ header: { timestamp: ts, gasLimit: 30_000_000n, baseFeePerGas: 0n } }, { common });
const allLogs = [];
async function sendTx(from, to, data) {
  const tx = LegacyTransaction.fromTxData({ nonce: nonces[from]++, gasPrice: 0n, gasLimit: 15_000_000n, to: to ? Address.fromString(to) : undefined, data: hexToBytes(data) }, { common }).sign(hexToBytes(keys[from]));
  const res = await vm.runTx({ tx, block: blockAt(now), skipBalance: true, skipBlockGasLimitValidation: true });
  if (res.execResult.exceptionError) throw new Error(`revert ${from}->${to}: ${res.execResult.exceptionError.error}`);
  for (const [addr, topics, data_] of res.execResult.logs || []) {
    allLogs.push({ address: "0x" + Buffer.from(addr).toString("hex"), topics: topics.map(bytesToHex), data: bytesToHex(data_) });
  }
  return res;
}
async function deploy(from, name, args = []) {
  const { abi, bytecode } = artifact(name);
  const iface = new ethers.Interface(abi);
  const res = await sendTx(from, null, bytecode + iface.encodeDeploy(args).slice(2));
  return { address: res.createdAddress.toString(), iface };
}
const call = (from, c, fn, args = []) => sendTx(from, c.address, c.iface.encodeFunctionData(fn, args));
async function view(c, fn, args = []) {
  const r = await vm.evm.runCall({ to: Address.fromString(c.address), data: hexToBytes(c.iface.encodeFunctionData(fn, args)), block: blockAt(now) });
  return c.iface.decodeFunctionResult(fn, bytesToHex(r.execResult.returnValue));
}

// deploy protocol (demo timing: receipt 60s, claim window 1d, defense 60s)
const U = 10n ** 6n, PRICE = 100_000n;
const usdc = await deploy("deployer", "MockUSDC");
const registry = await deploy("deployer", "BondedRegistry", [usdc.address, 100n * U, 120n, 2000n]);
const routerAddr = ethers.getCreateAddress({ from: w.deployer.address, nonce: Number(nonces.deployer) + 1 });
const policy = await deploy("deployer", "PolicyManager", [routerAddr]);
const router = await deploy("deployer", "SettlementRouter", [usdc.address, registry.address, policy.address, 60n, 86_400n]);
const cm = await deploy("deployer", "ClaimManager", [usdc.address, registry.address, router.address, w.treasury.address, 3n, 50n * U, 60n, 2000n, 7500n, 1000n, 10n * U]);
await call("deployer", registry, "wire", [router.address, cm.address]);
await call("deployer", router, "wire", [cm.address]);

for (const n of ["honest", "deadbeat", "buyer", "watcher"]) await call("deployer", usdc, "mint", [w[n].address, 1000n * U]);
for (const s of ["honest", "deadbeat"]) {
  await call(s, usdc, "approve", [registry.address, ethers.MaxUint256]);
  await call(s, registry, "register", [500n * U, `${s}-seller`, `https://${s}.example`]);
}
await call("buyer", policy, "setPolicy", [200_000n, 500n * U, now + 86_400n, true, false]);
await call("buyer", usdc, "approve", [router.address, ethers.MaxUint256]);
await call("buyer", router, "deposit", [100n * U]);
await call("watcher", usdc, "approve", [cm.address, ethers.MaxUint256]);

// agent pays 5 calls to each seller; honest deliveries get matching dual
// attestations (seller + buyer sign the same response bytes) -> DeliveryConfirmed
const domain = { name: "CollateralRails", version: "1", chainId: 1, verifyingContract: cm.address };
const types = { Attestation: [{ name: "paymentId", type: "uint256" }, { name: "requestHash", type: "bytes32" }, { name: "responseHash", type: "bytes32" }] };
let pid = 1n;
for (const s of ["honest", "deadbeat"]) {
  for (let i = 0; i < 5; i++) {
    const reqHash = ethers.keccak256(ethers.toUtf8Bytes(`req:${s}:${i}`));
    await call("buyer", router, "pay", [w[s].address, PRICE, reqHash]);
    if (s === "honest") {
      const a = { paymentId: pid, requestHash: reqHash, responseHash: ethers.keccak256(ethers.toUtf8Bytes("rsp" + pid)) };
      const sellerSig = await w.honest.signTypedData(domain, types, a);
      const buyerSig = await w.buyer.signTypedData(domain, types, a);
      await call("honest", cm, "attest", [[a.paymentId, a.requestHash, a.responseHash], sellerSig]);
      await call("buyer", cm, "attest", [[a.paymentId, a.requestHash, a.responseHash], buyerSig]);
    }
    pid++;
  }
}

// ---- feed REAL contract logs into WatcherCore, exactly as the CLI does ----
const core = new WatcherCore({ minBatch: 3, highValueThreshold: 50n * U, claimWindow: 86_400 });
const routerI = router.iface, cmI = cm.iface;
function ingest() {
  for (const log of allLogs.splice(0)) {
    let parsed = null;
    try { parsed = routerI.parseLog(log) || cmI.parseLog(log); } catch {}
    if (!parsed) { try { parsed = cmI.parseLog(log); } catch {} }
    if (!parsed) continue;
    if (parsed.name === "PaymentSettled") core.onPaymentSettled({ paymentId: parsed.args[0], buyer: parsed.args[1], seller: parsed.args[2], amount: parsed.args[3], receiptDeadline: parsed.args[5] });
    if (parsed.name === "PaymentStatusChanged") core.onStatusChanged({ paymentId: parsed.args[0], status: Number(parsed.args[1]) });
    if (parsed.name === "ClaimFiled") core.onClaimFiled({ claimId: parsed.args[0], seller: parsed.args[1], paymentIds: [], defenseEnd: Number(parsed.args[5]) });
    if (parsed.name === "ClaimResolved") core.onClaimResolved({ claimId: parsed.args[0] });
  }
}
const assert = (cond, msg) => { if (!cond) throw new Error("ASSERT: " + msg); console.log("✓ " + msg); };

ingest();
assert(core.status(Number(now)).tracked === 10, "core tracked 10 payments from real logs");
assert(core.dueClaims(Number(now)).length === 0, "no claims due before deadlines expire");

now += 61n; // receipt deadlines pass
let due = core.dueClaims(Number(now));
assert(due.length === 1, "exactly ONE batch claim due after deadlines");
assert(due[0].seller === w.deadbeat.address.toLowerCase(), "due claim targets the deadbeat seller only");
assert(due[0].paymentIds.length === 5, "claim aggregates all 5 failures");
assert(due[0].refundTotal === PRICE * 5n, "refund total = 5 x $0.10");

// watcher executes its decision on-chain
await call("watcher", cm, "fileClaim", [due[0].seller, due[0].paymentIds.map(BigInt)]);
ingest();
assert(core.status(Number(now)).openClaims === 1, "core sees the filed claim from logs");
assert(core.dueClaims(Number(now)).length === 0, "no duplicate claim due after filing");
assert(core.resolvable(Number(now)).length === 0, "not resolvable during defense window");

now += 61n; // defense window over
const resolvable = core.resolvable(Number(now));
assert(resolvable.length === 1, "claim resolvable after defense window");
const buyerBefore = (await view(usdc, "balanceOf", [w.buyer.address]))[0];
await call("watcher", cm, "resolve", [BigInt(resolvable[0])]);
ingest();
const buyerAfter = (await view(usdc, "balanceOf", [w.buyer.address]))[0];
assert(buyerAfter - buyerBefore === PRICE * 5n, "buyer refunded $0.50 from the seller performance bond");
assert(core.status(Number(now)).openClaims === 0, "core marks claim resolved from logs");
const s = await view(registry, "getSeller", [w.deadbeat.address]);
assert(s[6] === false, "deadbeat delisted");

console.log("\nWATCHER SELFTEST: ALL ASSERTIONS PASSED");
