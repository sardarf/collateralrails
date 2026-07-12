// Chain adapter — ethers v6 bindings shared by watcher CLI, seller sims, agent.
import { ethers } from "ethers";
import fs from "fs";

export const ABI = {
  registry: [
    "function register(uint256 bondAmount, string handle, string endpoint)",
    "function isActive(address seller) view returns (bool)",
    "function getSeller(address) view returns (uint256 bond,uint256 openExposure,uint32 served,uint32 failed,uint32 openClaims,uint256 slashedTotal,bool active,string endpoint,uint32 confirmed)",
    "function identity(address) view returns (string handle,string endpoint,bool endpointVerified)",
    "function reputation(address) view returns (uint16 score,uint8 tier,bool flagged)",
    "function verifyEndpoint(address seller)",
    "function verifier() view returns (address)",
    "function sellerCount() view returns (uint256)",
    "function sellerList(uint256) view returns (address)",
    "event SellerRegistered(address indexed seller,uint256 bond,string handle,string endpoint)",
    "event EndpointVerified(address indexed seller,string endpoint)",
    "event SellerSlashed(address indexed seller,uint256 refundTotal,uint256 penalty,uint32 failures,uint256 remainingBond)",
    "event SellerDelisted(address indexed seller,string reason)",
  ],
  router: [
    "function deposit(uint256)",
    "function pay(address seller,uint256 amount,bytes32 requestHash) returns (uint256)",
    "function getPayment(uint256) view returns (tuple(address buyer,address seller,uint128 amount,bytes32 requestHash,uint64 settledAt,uint64 receiptDeadline,uint8 status))",
    "function CLAIM_WINDOW() view returns (uint256)",
    "event PaymentSettled(uint256 indexed paymentId,address indexed buyer,address indexed seller,uint256 amount,bytes32 requestHash,uint64 receiptDeadline)",
    "event PaymentStatusChanged(uint256 indexed paymentId,uint8 status)",
  ],
  cm: [
    "function attest((uint256 paymentId,bytes32 requestHash,bytes32 responseHash) a, bytes sig)",
    "function fileClaim(address seller,uint256[] paymentIds) returns (uint256)",
    "function defend(uint256 claimId,uint256[] paymentIds)",
    "function resolve(uint256 claimId)",
    "function getClaim(uint256) view returns (address watcher,address seller,uint256 refundTotal,uint256 stake,uint64 defenseEnd,bool resolved,uint32 defendedCount,uint256[] paymentIds)",
    "function attestationOf(uint256) view returns (bytes32 sellerHash,uint64 sellerAt,bytes32 buyerHash,uint64 buyerAt)",
    "function MIN_BATCH() view returns (uint256)",
    "function HIGH_VALUE_THRESHOLD() view returns (uint256)",
    "event AttestationAnchored(uint256 indexed paymentId,address indexed signer,bool sellerSide,bytes32 responseHash)",
    "event ClaimFiled(uint256 indexed claimId,address indexed seller,address indexed watcher,uint256 count,uint256 refundTotal,uint64 defenseEnd)",
    "event ClaimResolved(uint256 indexed claimId,uint256 refunded,uint256 slashedPenalty,uint32 defended,uint32 failed)",
  ],
  usdc: [
    "function mint(address,uint256)",
    "function approve(address,uint256) returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ],
  policy: [
    "function setPolicy(uint128 maxPerPayment,uint128 budget,uint64 expiry,bool requireBonded,bool useAllowlist)",
  ],
};

export function loadDeployment(path = process.env.DEPLOYMENT || "deployment.json") {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

export function connect(dep, signerOrProvider) {
  // Wrap signers in a NonceManager: instant-mining nodes (anvil) can report a
  // stale pending nonce to ethers between back-to-back sends, causing spurious
  // "nonce has already been used" errors. NonceManager tracks nonces locally.
  const s = signerOrProvider?.signTransaction && !(signerOrProvider instanceof ethers.NonceManager)
    ? new ethers.NonceManager(signerOrProvider)
    : signerOrProvider;
  return {
    usdc: new ethers.Contract(dep.usdc, ABI.usdc, s),
    registry: new ethers.Contract(dep.registry, ABI.registry, s),
    router: new ethers.Contract(dep.router, ABI.router, s),
    cm: new ethers.Contract(dep.cm, ABI.cm, s),
    policy: new ethers.Contract(dep.policy, ABI.policy, s),
  };
}

/** EIP-712 dual delivery attestation. Signed independently by BOTH the seller
 *  and the buyer; delivery is confirmed only when the two response hashes match
 *  and both are anchored on time. There is no self-reported timestamp — the
 *  authoritative time is the on-chain anchor time, which cannot be backdated.
 *  Matching hashes prove agreement on the delivered bytes, not correctness. */
export async function signAttestation(wallet, cmAddress, chainId, attestation) {
  const domain = { name: "CollateralRails", version: "1", chainId, verifyingContract: cmAddress };
  const types = {
    Attestation: [
      { name: "paymentId", type: "uint256" },
      { name: "requestHash", type: "bytes32" },
      { name: "responseHash", type: "bytes32" },
    ],
  };
  return wallet.signTypedData(domain, types, attestation);
}
