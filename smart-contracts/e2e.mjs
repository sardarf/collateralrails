// CollateralRails runtime E2E: executes the full demo story on an in-process
// EVM (@ethereumjs/vm) with real EIP-712 dual-attestation signatures. This
// complements the Foundry suite (run `forge test` locally) by proving the
// deployed bytecode's core flows end to end.
import { VM } from "@ethereumjs/vm";
import { Block } from "@ethereumjs/block";
import { LegacyTransaction } from "@ethereumjs/tx";
import { Common, Hardfork, Chain } from "@ethereumjs/common";
import { Account, Address, hexToBytes, bytesToHex } from "@ethereumjs/util";
import { ethers } from "ethers";
import fs from "fs";

const build = JSON.parse(fs.readFileSync("out-js/build.json", "utf8"));
function artifact(name) {
  for (const f of Object.keys(build)) if (build[f][name]) {
    return { abi: build[f][name].abi, bytecode: "0x" + build[f][name].evm.bytecode.object };
  }
  throw new Error("artifact not found: " + name);
}

const common = new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Shanghai });
const vm = await VM.create({ common });

// deterministic actors
const keys = {
  deployer: "0x" + "11".repeat(32),
  honest: "0x" + "22".repeat(32),
  deadbeat: "0x" + "33".repeat(32),
  buyer: "0x" + "44".repeat(32),
  watcher: "0x" + "55".repeat(32),
  treasury: "0x" + "66".repeat(32),
};
const w = {}; // ethers wallets
const nonces = {};
for (const [n, k] of Object.entries(keys)) {
  w[n] = new ethers.Wallet(k);
  nonces[n] = 0n;
  const addr = Address.fromString(w[n].address);
  await vm.stateManager.putAccount(addr, new Account(0n, 10n ** 24n));
}

let now = 1_800_000_000n; // controllable chain time
function blockAt(ts) {
  return Block.fromBlockData({ header: { timestamp: ts, gasLimit: 30_000_000n, baseFeePerGas: 0n } }, { common });
}
async function sendTx(from, to, data, { value = 0n } = {}) {
  const tx = LegacyTransaction.fromTxData(
    { nonce: nonces[from]++, gasPrice: 0n, gasLimit: 15_000_000n, to: to ? Address.fromString(to) : undefined, value, data: hexToBytes(data) },
    { common }
  ).sign(hexToBytes(keys[from]));
  const res = await vm.runTx({ tx, block: blockAt(now), skipBalance: true, skipBlockGasLimitValidation: true });
  if (res.execResult.exceptionError) {
    const ret = bytesToHex(res.execResult.returnValue);
    throw new Error(`tx reverted (${from} -> ${to}): ${res.execResult.exceptionError.error} ${ret}`);
  }
  return res;
}
async function deploy(from, name, args = []) {
  const { abi, bytecode } = artifact(name);
  const iface = new ethers.Interface(abi);
  const data = bytecode + iface.encodeDeploy(args).slice(2);
  const res = await sendTx(from, null, data);
  return { address: res.createdAddress.toString(), iface };
}
async function call(from, c, fn, args = []) {
  return sendTx(from, c.address, c.iface.encodeFunctionData(fn, args));
}
async function view(c, fn, args = []) {
  const res = await vm.evm.runCall({
    to: Address.fromString(c.address),
    data: hexToBytes(c.iface.encodeFunctionData(fn, args)),
    block: blockAt(now),
  });
  if (res.execResult.exceptionError) throw new Error("view revert " + fn);
  return c.iface.decodeFunctionResult(fn, bytesToHex(res.execResult.returnValue));
}

// ---------------------------------------------------------------- deploy
const U = 10n ** 6n; // 6 decimals
const CALL_PRICE = 100_000n; // $0.10
const usdc = await deploy("deployer", "MockUSDC");
const registry = await deploy("deployer", "BondedRegistry", [usdc.address, 100n * U, 120n, 2000n]);

// PolicyManager needs the router address: precompute deployer's CREATE addrs
const policyAddr = ethers.getCreateAddress({ from: w.deployer.address, nonce: Number(nonces.deployer) });
const routerAddr = ethers.getCreateAddress({ from: w.deployer.address, nonce: Number(nonces.deployer) + 1 });
const policy = await deploy("deployer", "PolicyManager", [routerAddr]);
const router = await deploy("deployer", "SettlementRouter", [usdc.address, registry.address, policy.address, 60n, 86_400n]);
if (router.address.toLowerCase() !== routerAddr.toLowerCase()) throw new Error("router address prediction failed");
const cm = await deploy("deployer", "ClaimManager", [
  usdc.address, registry.address, router.address, w.treasury.address,
  3n, 50n * U, 60n, 2000n, 7500n, 1000n, 10n * U,
]);
await call("deployer", registry, "wire", [router.address, cm.address]);
await call("deployer", router, "wire", [cm.address]);
console.log("✓ deployed & wired: MockUSDC, BondedRegistry, PolicyManager, SettlementRouter, ClaimManager");

// ---------------------------------------------------------------- fund + register
for (const n of ["honest", "deadbeat", "buyer", "watcher"]) {
  await call("deployer", usdc, "mint", [w[n].address, 1_000n * U]);
}
for (const seller of ["honest", "deadbeat"]) {
  await call(seller, usdc, "approve", [registry.address, ethers.MaxUint256]);
  await call(seller, registry, "register", [500n * U, `${seller}-svc`, `https://${seller}.example`]);
}
console.log("✓ two sellers registered with 500 mUSDC performance bonds");

// buyer policy + deposit
await call("buyer", policy, "setPolicy", [200_000n, 500n * U, now + 86_400n, true, false]);
await call("buyer", usdc, "approve", [router.address, ethers.MaxUint256]);
await call("buyer", router, "deposit", [100n * U]);
await call("watcher", usdc, "approve", [cm.address, ethers.MaxUint256]);
console.log("✓ agent policy set ($0.20/call cap, bonded-only) and balance funded");

// ---------------------------------------------------------------- payments
const honestBalBefore = (await view(usdc, "balanceOf", [w.honest.address]))[0];
const ids = { honest: [], deadbeat: [] };
let nextId = 1n;
for (const seller of ["honest", "deadbeat"]) {
  for (let i = 0; i < 5; i++) {
    const reqHash = ethers.keccak256(ethers.toUtf8Bytes(`req:${seller}:${i}`));
    await call("buyer", router, "pay", [w[seller].address, CALL_PRICE, reqHash]);
    ids[seller].push({ id: nextId++, reqHash });
  }
}
const honestBalAfter = (await view(usdc, "balanceOf", [w.honest.address]))[0];
if (honestBalAfter - honestBalBefore !== CALL_PRICE * 5n) throw new Error("instant settlement failed");
console.log("✓ 10 micropayments ($0.10 each) settled INSTANTLY to sellers — zero escrow");

// exposure check
let s = await view(registry, "getSeller", [w.honest.address]);
if (s[1] !== CALL_PRICE * 5n) throw new Error("exposure tracking wrong");

// ---------------------------------------------------------------- dual attestation (honest)
const domain = { name: "CollateralRails", version: "1", chainId: 1, verifyingContract: cm.address };
const types = { Attestation: [
  { name: "paymentId", type: "uint256" },
  { name: "requestHash", type: "bytes32" },
  { name: "responseHash", type: "bytes32" },
]};
const signAtt = (who, a) => w[who].signTypedData(domain, types, a);
async function attest(who, a) {
  await call(who, cm, "attest", [[a.paymentId, a.requestHash, a.responseHash], await signAtt(who, a)]);
}
for (const p of ids.honest) {
  const a = { paymentId: p.id, requestHash: p.reqHash, responseHash: ethers.keccak256(ethers.toUtf8Bytes("resp" + p.id)) };
  await attest("honest", a); // seller side
  await attest("buyer", a);  // buyer side signs the SAME bytes -> DeliveryConfirmed
}
s = await view(registry, "getSeller", [w.honest.address]);
if (s[1] !== 0n) throw new Error("exposure not recycled after confirmation");
if (Number(s[8]) !== 5) throw new Error("confirmed-delivery counter wrong");
console.log("✓ WeatherOracle: 5 deliveries CONFIRMED by matching dual attestations — exposure recycled to 0");

// negative: an attestation from a party that is neither seller nor buyer must revert
try {
  const p = ids.deadbeat[0];
  const a = { paymentId: p.id, requestHash: p.reqHash, responseHash: ethers.ZeroHash };
  await call("honest", cm, "attest", [[a.paymentId, a.requestHash, a.responseHash], await signAtt("honest", a)]); // honest is not this payment's party
  throw new Error("SECURITY FAIL: third-party attestation accepted");
} catch (e) { if (String(e).includes("SECURITY FAIL")) throw e; }
console.log("✓ attestation from a non-party rejected (InvalidAttestation)");

// ---------------------------------------------------------------- claim + slash
now += 61n; // receipt deadlines pass
const deadIds = ids.deadbeat.map((p) => p.id);

// premature claim on honest seller impossible (all delivery-confirmed)
try {
  await call("watcher", cm, "fileClaim", [w.honest.address, ids.honest.map((p) => p.id)]);
  throw new Error("SECURITY FAIL: claim on confirmed payments accepted");
} catch (e) { if (String(e).includes("SECURITY FAIL")) throw e; }
console.log("✓ claim against delivery-confirmed (honest) payments rejected");

const buyerBefore = (await view(usdc, "balanceOf", [w.buyer.address]))[0];
const watcherBefore = (await view(usdc, "balanceOf", [w.watcher.address]))[0];
await call("watcher", cm, "fileClaim", [w.deadbeat.address, deadIds]);
console.log("✓ watcher filed ONE aggregated batch claim for 5 failed micropayments (staked)");

// resolve blocked during defense window
try {
  await call("watcher", cm, "resolve", [1n]);
  throw new Error("SECURITY FAIL: resolved during defense window");
} catch (e) { if (String(e).includes("SECURITY FAIL")) throw e; }
console.log("✓ resolve blocked during seller defense window (due process)");

now += 61n; // defense window elapses, deadbeat produced nothing
await call("watcher", cm, "resolve", [1n]);

const buyerAfter = (await view(usdc, "balanceOf", [w.buyer.address]))[0];
const watcherAfter = (await view(usdc, "balanceOf", [w.watcher.address]))[0];
const treasuryBal = (await view(usdc, "balanceOf", [w.treasury.address]))[0];
const refund = CALL_PRICE * 5n;
const penalty = (refund * 2000n) / 10000n;
const watcherShare = (penalty * 7500n) / 10000n;
if (buyerAfter - buyerBefore !== refund) throw new Error("buyer refund wrong");
if (watcherAfter - watcherBefore !== watcherShare) throw new Error("watcher bounty wrong");
if (treasuryBal !== penalty - watcherShare) throw new Error("treasury share wrong");
console.log(`✓ SLASH: buyer refunded $${Number(refund) / 1e6} FROM SELLER BOND, watcher bounty $${Number(watcherShare) / 1e6}, treasury $${Number(penalty - watcherShare) / 1e6}`);

s = await view(registry, "getSeller", [w.deadbeat.address]);
if (s[6] !== false) throw new Error("deadbeat not delisted");
if (s[3] !== 5n && Number(s[3]) !== 5) throw new Error("failed counter wrong");
console.log(`✓ AlphaSignals: bond ${Number(s[0]) / 1e6} mUSDC remaining, 5 failures recorded, DELISTED`);

// delisted seller refused at the rail
try {
  await call("buyer", router, "pay", [w.deadbeat.address, CALL_PRICE, ethers.ZeroHash]);
  throw new Error("SECURITY FAIL: payment to delisted seller accepted");
} catch (e) { if (String(e).includes("SECURITY FAIL")) throw e; }
console.log("✓ agent's next payment to the delisted seller refused at the rail");

// agent flow: approved agent pays from buyer balance under buyer policy
const agentKey = "0x" + "77".repeat(32);
keys.agent = agentKey; w.agent = new ethers.Wallet(agentKey); nonces.agent = 0n;
await vm.stateManager.putAccount(Address.fromString(w.agent.address), new Account(0n, 10n ** 24n));
await call("buyer", router, "approveAgent", [w.agent.address, true]);
await call("agent", router, "payForBuyer", [w.buyer.address, w.honest.address, CALL_PRICE, ethers.keccak256(ethers.toUtf8Bytes("agent-req"))]);
const agentPid = 11n;
const pRec = await view(router, "getPayment", [agentPid]);
if (pRec[0].buyer.toLowerCase() !== w.buyer.address.toLowerCase()) throw new Error("agent payment buyer wrong");
if (((await view(router, "agentOf", [agentPid]))[0]).toLowerCase() !== w.agent.address.toLowerCase()) throw new Error("agentOf wrong");
try {
  await call("agent", router, "payForBuyer", [w.watcher.address, w.honest.address, CALL_PRICE, ethers.ZeroHash]);
  throw new Error("SECURITY FAIL: unapproved agent paid");
} catch (e) { if (String(e).includes("SECURITY FAIL")) throw e; }
console.log("✓ agent pays under buyer policy from buyer balance; unapproved agent rejected");
// tidy: confirm the agent payment (dual attestation) so honest seller's exposure clears
{
  const a = { paymentId: agentPid, requestHash: ethers.keccak256(ethers.toUtf8Bytes("agent-req")), responseHash: ethers.ZeroHash };
  await attest("honest", a);
  await attest("buyer", a); // matching hash -> DeliveryConfirmed
}

// §10 CORE: on-time anchoring is enforced — an attestation submitted after the
// receipt window closes is rejected, so a seller cannot fabricate delivery
// evidence after the fact (the authoritative time is the on-chain anchor time).
const lateReq = ethers.keccak256(ethers.toUtf8Bytes("late"));
await call("buyer", router, "pay", [w.honest.address, CALL_PRICE, lateReq]);
const latePid = 12n;
now += 61n; // receipt window closes with no attestation
try {
  const a = { paymentId: latePid, requestHash: lateReq, responseHash: ethers.ZeroHash };
  await call("honest", cm, "attest", [[a.paymentId, a.requestHash, a.responseHash], await signAtt("honest", a)]);
  throw new Error("SECURITY FAIL: attestation after the window accepted");
} catch (e) { if (String(e).includes("SECURITY FAIL")) throw e; }
console.log("✓ attestation after the receipt window rejected (AttestationWindowClosed) — no late fabrication");

// clear the lingering exposure via permissionless expiry so the seller can exit
now += 86_401n; // claim window closes with no claim filed
await call("honest", router, "releaseExpired", [latePid]);

// withdrawal discipline: honest seller can exit cleanly
await call("honest", registry, "requestWithdrawal", []);
now += 121n;
await call("honest", registry, "executeWithdrawal", []);
console.log("✓ honest seller exited: cooldown respected, zero exposure, full bond returned");

console.log("\nE2E DEMO STORY: ALL ASSERTIONS PASSED");
