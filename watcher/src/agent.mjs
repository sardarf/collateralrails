#!/usr/bin/env node
// Buyer agent simulator: sets a bounded-agency policy, funds a balance, then
// buys N micropayment calls from a seller. Refund protection comes from the
// SELLER'S PERFORMANCE BOND — the buyer escrows nothing.
import { ethers } from "ethers";
import { connect, loadDeployment } from "./chain.mjs";

const dep = loadDeployment();
const provider = new ethers.JsonRpcProvider(process.env.RPC || dep.rpc);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
const c = connect(dep, wallet);

const seller = process.env.SELLER;
const n = Number(process.env.N || 5);
const price = ethers.parseUnits(process.env.PRICE || "0.10", 6); // $0.10/call

// policy + funding (idempotent-ish demo setup)
await (await c.usdc.mint(wallet.address, ethers.parseUnits("100", 6))).wait();
await (await c.usdc.approve(dep.router, ethers.MaxUint256)).wait();
await (await c.policy.setPolicy(
  ethers.parseUnits("0.20", 6), ethers.parseUnits("500", 6),
  Math.floor(Date.now() / 1000) + 86_400, true, false
)).wait();
await (await c.router.deposit(ethers.parseUnits("50", 6))).wait();
console.log(`[agent] policy: $0.20/call cap, $500 budget, bonded sellers only`);

if (!(await c.registry.isActive(seller))) {
  console.log(`[agent] ${seller} is NOT bonded/active — refusing to pay (bonded-only policy)`);
  process.exit(0);
}
for (let i = 0; i < n; i++) {
  const reqHash = ethers.keccak256(ethers.toUtf8Bytes(`req:${seller}:${Date.now()}:${i}`));
  const tx = await c.router.pay(seller, price, reqHash);
  await tx.wait();
  console.log(`[agent] paid ${ethers.formatUnits(price, 6)} mUSDC to ${seller} — instant settlement, zero escrow`);
}
