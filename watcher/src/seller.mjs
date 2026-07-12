#!/usr/bin/env node
// Seller simulators.
//   node src/seller.mjs honest    — serves + signs & anchors its SELLER-side
//                                   delivery attestation for every payment
//                                   (the buyer/agent anchors the matching
//                                   buyer-side attestation to confirm delivery)
//   node src/seller.mjs deadbeat  — registers, takes the money, never attests
import { ethers } from "ethers";
import { connect, loadDeployment, signAttestation } from "./chain.mjs";

const mode = process.argv[2] || "honest";
const dep = loadDeployment();
const provider = new ethers.JsonRpcProvider(process.env.RPC || dep.rpc);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
const c = connect(dep, wallet);
const { chainId } = await provider.getNetwork();

// register if needed
if (!(await c.registry.isActive(wallet.address).catch(() => false))) {
  const bond = ethers.parseUnits(process.env.BOND || "500", 6);
  const handle = process.env.HANDLE || `${mode}-seller-${wallet.address.slice(2, 8)}`;
  const endpoint = process.env.ENDPOINT || `https://${mode}-seller.example`;
  await (await c.usdc.mint(wallet.address, bond)).wait();
  await (await c.usdc.approve(dep.registry, ethers.MaxUint256)).wait();
  await (await c.registry.register(bond, handle, endpoint)).wait();
  console.log(`[${mode}] registered "${handle}" (${endpoint}) with ${ethers.formatUnits(bond, 6)} mUSDC deposit`);
}

console.log(`[${mode}] ${wallet.address} listening for payments...`);
c.router.on(c.router.filters.PaymentSettled(null, null, wallet.address), async (paymentId, buyer, seller, amount, requestHash, receiptDeadline) => {
  console.log(`[${mode}] paid ${ethers.formatUnits(amount, 6)} mUSDC (payment ${paymentId})`);
  if (mode !== "honest") return console.log(`[${mode}] ...and doing nothing about it`);
  const a = {
    paymentId,
    requestHash,
    responseHash: ethers.keccak256(ethers.toUtf8Bytes(`response:${paymentId}`)),
  };
  const sig = await signAttestation(wallet, dep.cm, chainId, a);
  await (await c.cm.attest(a, sig)).wait();
  console.log(`[honest] anchored seller-side attestation for payment ${paymentId} — awaiting buyer attestation to confirm`);
});
