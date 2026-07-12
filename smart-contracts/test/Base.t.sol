// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "src/MockUSDC.sol";
import {BondedRegistry} from "src/BondedRegistry.sol";
import {PolicyManager} from "src/PolicyManager.sol";
import {SettlementRouter} from "src/SettlementRouter.sol";
import {ClaimManager} from "src/ClaimManager.sol";
import {ReceiptLib} from "src/ReceiptLib.sol";

contract BaseTest is Test {
    // ------------------------------------------------------------ constants
    uint256 constant MIN_BOND = 100e6; // 100 mUSDC
    uint256 constant COOLDOWN = 2 minutes;
    uint256 constant MAX_FAIL_BPS = 2_000; // delist above 20% failure ratio
    uint256 constant RECEIPT_WINDOW = 60; // 60s to attest (demo config)
    uint256 constant CLAIM_WINDOW = 1 days; // watchers may claim within
    uint256 constant MIN_BATCH = 3;
    uint256 constant HIGH_VALUE = 50e6; // single-payment claim floor
    uint256 constant DEFENSE_WINDOW = 60; // demo config
    uint256 constant PENALTY_BPS = 2_000; // 20% of refund total
    uint256 constant WATCHER_SHARE_BPS = 7_500; // 75% of penalty
    uint256 constant STAKE_BPS = 1_000; // 10% of refund total
    uint256 constant STAKE_FLOOR = 10e6; // 10 mUSDC

    uint256 constant CALL_PRICE = 100_000; // $0.10 — micropayment regime

    MockUSDC usdc;
    BondedRegistry registry;
    PolicyManager policy;
    SettlementRouter router;
    ClaimManager cm;

    address treasury = makeAddr("treasury");
    address watcher = makeAddr("watcher");
    address buyer; // the agent's account — keyed so it can sign buyer attestations
    uint256 buyerKey;

    uint256 honestKey = 0xA11CE;
    uint256 deadbeatKey = 0xBADD;
    address honest; // seller that attests deliveries
    address deadbeat; // seller that never attests

    function setUp() public virtual {
        honest = vm.addr(honestKey);
        deadbeat = vm.addr(deadbeatKey);
        (buyer, buyerKey) = makeAddrAndKey("buyer");

        usdc = new MockUSDC();
        registry = new BondedRegistry(usdc, MIN_BOND, COOLDOWN, MAX_FAIL_BPS);
        policy = new PolicyManager(_predictRouter());
        router = new SettlementRouter(usdc, registry, policy, RECEIPT_WINDOW, CLAIM_WINDOW);
        cm = new ClaimManager(
            usdc, registry, router, treasury,
            MIN_BATCH, HIGH_VALUE, DEFENSE_WINDOW,
            PENALTY_BPS, WATCHER_SHARE_BPS, STAKE_BPS, STAKE_FLOOR
        );
        registry.wire(address(router), address(cm));
        router.wire(address(cm));
        registry.setVerifier(watcher); // the watcher acts as the endpoint-ownership oracle

        // funding
        usdc.mint(honest, 1_000e6);
        usdc.mint(deadbeat, 1_000e6);
        usdc.mint(buyer, 1_000e6);
        usdc.mint(watcher, 1_000e6);

        // default buyer policy: $0.20 cap, $500 budget, bonded-only
        vm.startPrank(buyer);
        policy.setPolicy(uint128(200_000), uint128(500e6), uint64(block.timestamp + 30 days), true, false);
        usdc.approve(address(router), type(uint256).max);
        router.deposit(100e6);
        vm.stopPrank();

        vm.prank(watcher);
        usdc.approve(address(cm), type(uint256).max);
    }

    /// PolicyManager needs the router address at construction; router is the
    /// 3rd contract this test deploys after it. Predict with CREATE nonce math.
    function _predictRouter() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
    }

    // ------------------------------------------------------------- helpers

    function _register(address seller, uint256 bond) internal {
        // Unique handle per seller — the registry now enforces handle uniqueness.
        string memory who = vm.toString(seller);
        vm.startPrank(seller);
        usdc.approve(address(registry), type(uint256).max);
        registry.register(bond, string.concat("svc-", who), string.concat("https://", who, ".example"));
        vm.stopPrank();
    }

    function _pay(address seller, uint256 amount, bytes32 reqHash) internal returns (uint256 id) {
        vm.prank(buyer);
        id = router.pay(seller, amount, reqHash);
    }

    function _payN(address seller, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = _pay(seller, CALL_PRICE, keccak256(abi.encode("req", seller, i)));
        }
    }

    /// Deterministic per-payment response hash used across the dual-attestation
    /// helpers so seller and buyer sign the SAME bytes on the happy path.
    function _respHash(uint256 pid) internal pure returns (bytes32) {
        return keccak256(abi.encode("resp", pid));
    }

    /// Build, sign (with `signerKey`) and anchor one delivery attestation.
    /// The signer must be the payment's seller or buyer; the recovered address
    /// decides which side it counts as. Anchoring must be within the window.
    function _attestWith(uint256 pid, uint256 signerKey, bytes32 responseHash) internal {
        SettlementRouter.Payment memory p = router.getPayment(pid);
        ReceiptLib.Attestation memory a = ReceiptLib.Attestation({
            paymentId: pid,
            requestHash: p.requestHash,
            responseHash: responseHash
        });
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(signerKey, cm.attestationDigest(a));
        cm.attest(a, abi.encodePacked(rr, ss, v));
    }

    /// Seller-only on-time attestation (Case C: evidence incomplete, defensible).
    function _attestSeller(uint256 pid, uint256 sellerKey) internal {
        _attestWith(pid, sellerKey, _respHash(pid));
    }

    /// Full dual confirmation: seller and buyer anchor the SAME hash on time.
    function _confirm(uint256 pid, uint256 sellerKey) internal {
        _attestWith(pid, sellerKey, _respHash(pid)); // seller side
        _attestWith(pid, buyerKey, _respHash(pid)); // buyer side -> DeliveryConfirmed
    }

    function _expireReceipts() internal {
        vm.warp(block.timestamp + RECEIPT_WINDOW + 1);
    }

    function _endDefense() internal {
        vm.warp(block.timestamp + DEFENSE_WINDOW + 1);
    }
}
