#!/usr/bin/env node
// Endpoint-ownership oracle. For every listed seller that isn't yet verified,
// prove they control the endpoint they registered, then write the attestation
// on-chain via registry.verifyEndpoint(). This is the trusted "verifier" the
// BondedRegistry recognises — run it with the key set as the registry verifier.
//
// Proof of control: the seller must serve, at
//     <endpoint>/.well-known/collateralrails.json
// a JSON document { "address": "0x<their wallet>" } matching their registry
// address (case-insensitive). Controlling the endpoint => controlling the file.
//
// Usage:
//   PRIVATE_KEY=<verifier key> node src/verifier.mjs           # verify once, then loop
//   PRIVATE_KEY=<verifier key> node src/verifier.mjs --once     # single pass
//   DEMO_VERIFY=1 node src/verifier.mjs --once                  # demo: skip HTTP, trust listings
//   FIXTURES=fixtures.json node src/verifier.mjs --once         # verify only addresses listed in a file
import { ethers } from "ethers";
import fs from "fs";
import { connect, loadDeployment } from "./chain.mjs";

const ONCE = process.argv.includes("--once") || !!process.env.ONCE;
const DEMO_VERIFY = !!process.env.DEMO_VERIFY;
const FIXTURES = process.env.FIXTURES
  ? new Set(JSON.parse(fs.readFileSync(process.env.FIXTURES, "utf8")).map((a) => a.toLowerCase()))
  : null;

const dep = loadDeployment();
const provider = new ethers.JsonRpcProvider(process.env.RPC || dep.rpc);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
const c = connect(dep, wallet);

// Confirm we are actually the registry's recognised verifier before doing work.
const onchainVerifier = await c.registry.verifier();
if (onchainVerifier.toLowerCase() !== wallet.address.toLowerCase()) {
  console.error(`[verifier] ${wallet.address} is NOT the registry verifier (${onchainVerifier}). ` +
    `Set the registry verifier to this key (registry.setVerifier) or use the right PRIVATE_KEY.`);
  process.exit(1);
}
console.log(`[verifier] ${wallet.address} — endpoint-ownership oracle for ${dep.registry}`);

/** Does `endpoint` prove control by `seller`? Fetches the well-known doc. */
async function provesOwnership(seller, endpoint) {
  if (DEMO_VERIFY) return true; // demo: endpoints are fake *.example hosts
  if (FIXTURES) return FIXTURES.has(seller.toLowerCase());
  const url = endpoint.replace(/\/+$/, "") + "/.well-known/collateralrails.json";
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return false;
    const doc = await res.json();
    return typeof doc.address === "string" && doc.address.toLowerCase() === seller.toLowerCase();
  } catch (e) {
    console.log(`[verifier]   fetch failed for ${url}: ${e.message}`);
    return false;
  }
}

async function pass() {
  const count = Number(await c.registry.sellerCount());
  for (let i = 0; i < count; i++) {
    const seller = await c.registry.sellerList(i);
    let handle, endpoint, endpointVerified;
    try {
      [handle, endpoint, endpointVerified] = await c.registry.identity(seller);
    } catch { continue; }
    if (endpointVerified) continue;

    const ok = await provesOwnership(seller, endpoint);
    if (!ok) {
      console.log(`[verifier] ✗ ${handle} (${seller}) — ${endpoint} did not prove ownership`);
      continue;
    }
    try {
      await (await c.registry.verifyEndpoint(seller)).wait();
      console.log(`[verifier] ✓ ${handle} (${seller}) — endpoint ${endpoint} verified on-chain`);
    } catch (e) {
      console.error(`[verifier] ! verifyEndpoint(${seller}) failed: ${e.shortMessage || e.message}`);
    }
  }
}

await pass();
if (!ONCE) {
  const interval = Number(process.env.INTERVAL || 10) * 1000;
  setInterval(() => pass().catch((e) => console.error(e.message)), interval);
}
