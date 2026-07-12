// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ClaimManager} from "src/ClaimManager.sol";
import {SettlementRouter} from "src/SettlementRouter.sol";
import {ReceiptLib} from "src/ReceiptLib.sol";
import {BondedRegistry} from "src/BondedRegistry.sol";

contract ClaimsTest is BaseTest {
    // ----------------------------------------------------- dual attestation

    function test_DualAttestationConfirmsDelivery() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));

        _confirm(id, honestKey); // seller + buyer sign the same response bytes

        SettlementRouter.Payment memory p = router.getPayment(id);
        assertEq(uint8(p.status), uint8(SettlementRouter.Status.DeliveryConfirmed));
        (, uint256 exposure,,,,,,, uint32 confirmed) = registry.getSeller(honest);
        assertEq(exposure, 0); // capacity recycled on confirmation
        assertEq(confirmed, 1); // seller earns one confirmed delivery
    }

    function test_FirstAttestationMovesToAttestedState() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));

        _attestSeller(id, honestKey); // seller only

        SettlementRouter.Payment memory p = router.getPayment(id);
        assertEq(uint8(p.status), uint8(SettlementRouter.Status.SellerAttested));
        // exposure is NOT released for a one-sided attestation
        (, uint256 exposure,,,,,,, uint32 confirmed) = registry.getSeller(honest);
        assertEq(exposure, CALL_PRICE);
        assertEq(confirmed, 0);
    }

    function test_BuyerFirstThenSellerConfirms() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));

        _attestWith(id, buyerKey, _respHash(id)); // buyer first
        assertEq(uint8(router.getPayment(id).status), uint8(SettlementRouter.Status.BuyerAttested));
        _attestWith(id, honestKey, _respHash(id)); // seller matches -> confirmed

        assertEq(uint8(router.getPayment(id).status), uint8(SettlementRouter.Status.DeliveryConfirmed));
    }

    function test_HashMismatchIsNotConfirmed() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));

        _attestWith(id, honestKey, keccak256("A")); // seller says A
        _attestWith(id, buyerKey, keccak256("B")); // buyer says B

        SettlementRouter.Payment memory p = router.getPayment(id);
        assertEq(uint8(p.status), uint8(SettlementRouter.Status.HashMismatch));
        // exposure stays: a mismatch is not a successful delivery
        (, uint256 exposure,,,,,,, uint32 confirmed) = registry.getSeller(honest);
        assertEq(exposure, CALL_PRICE);
        assertEq(confirmed, 0);
    }

    function test_RevertAttestWrongSigner() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));
        // deadbeatKey is neither the seller nor the buyer of this payment
        SettlementRouter.Payment memory p = router.getPayment(id);
        ReceiptLib.Attestation memory a =
            ReceiptLib.Attestation({paymentId: id, requestHash: p.requestHash, responseHash: keccak256("r")});
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(deadbeatKey, cm.attestationDigest(a));
        vm.expectRevert(ClaimManager.InvalidAttestation.selector);
        cm.attest(a, abi.encodePacked(rr, ss, v));
    }

    function test_RevertAttestWrongRequestHash() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));
        ReceiptLib.Attestation memory a =
            ReceiptLib.Attestation({paymentId: id, requestHash: keccak256("wrong"), responseHash: keccak256("r")});
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(honestKey, cm.attestationDigest(a));
        vm.expectRevert(ClaimManager.InvalidAttestation.selector);
        cm.attest(a, abi.encodePacked(rr, ss, v));
    }

    function test_RevertAttestAfterWindow() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));
        _expireReceipts(); // now past the receipt deadline
        SettlementRouter.Payment memory p = router.getPayment(id);
        ReceiptLib.Attestation memory a =
            ReceiptLib.Attestation({paymentId: id, requestHash: p.requestHash, responseHash: _respHash(id)});
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(honestKey, cm.attestationDigest(a));
        vm.expectRevert(ClaimManager.AttestationWindowClosed.selector);
        cm.attest(a, abi.encodePacked(rr, ss, v));
    }

    function test_RevertDoubleAttestSameSide() public {
        _register(honest, 500e6);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));
        _attestSeller(id, honestKey);
        SettlementRouter.Payment memory p = router.getPayment(id);
        ReceiptLib.Attestation memory a =
            ReceiptLib.Attestation({paymentId: id, requestHash: p.requestHash, responseHash: _respHash(id)});
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(honestKey, cm.attestationDigest(a));
        vm.expectRevert(ClaimManager.AlreadyAttested.selector);
        cm.attest(a, abi.encodePacked(rr, ss, v));
    }

    function test_ConfirmedDeliveryCannotBeClaimed() public {
        _register(honest, 500e6);
        uint256[] memory ids = _payN(honest, 3);
        for (uint256 i = 0; i < 3; i++) {
            _confirm(ids[i], honestKey);
        }
        _expireReceipts();
        vm.prank(watcher);
        vm.expectRevert(ClaimManager.PaymentNotClaimable.selector);
        cm.fileClaim(honest, ids);
    }

    // ------------------------------------------------------------ agent flow

    function test_AgentPaysUnderBuyerPolicy() public {
        _register(honest, 500e6);
        address agent = makeAddr("agent");
        vm.prank(buyer);
        router.approveAgent(agent, true);

        uint256 buyerBalBefore = router.balanceOf(buyer);
        vm.prank(agent);
        uint256 id = router.payForBuyer(buyer, honest, CALL_PRICE, keccak256("agent-req"));

        // funds from buyer balance, record stores buyer, agent recorded separately
        assertEq(router.balanceOf(buyer), buyerBalBefore - CALL_PRICE);
        SettlementRouter.Payment memory pmt = router.getPayment(id);
        assertEq(pmt.buyer, buyer);
        assertEq(router.agentOf(id), agent);

        // refund path goes to the BUYER, not the agent
        vm.startPrank(agent);
        uint256 id2 = router.payForBuyer(buyer, honest, CALL_PRICE, keccak256("r2"));
        uint256 id3 = router.payForBuyer(buyer, honest, CALL_PRICE, keccak256("r3"));
        vm.stopPrank();
        _expireReceipts();
        uint256[] memory batch = new uint256[](3);
        batch[0] = id;
        batch[1] = id2;
        batch[2] = id3;
        uint256 buyerTokenBefore = usdc.balanceOf(buyer);
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(honest, batch);
        _endDefense();
        cm.resolve(claimId);
        assertEq(usdc.balanceOf(buyer), buyerTokenBefore + CALL_PRICE * 3);
    }

    function test_RevertUnapprovedAgent() public {
        _register(honest, 500e6);
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(SettlementRouter.NotApprovedAgent.selector);
        router.payForBuyer(buyer, honest, CALL_PRICE, keccak256("r"));
    }

    function test_AgentApprovalRevocable() public {
        _register(honest, 500e6);
        address agent = makeAddr("agent");
        vm.prank(buyer);
        router.approveAgent(agent, true);
        vm.prank(buyer);
        router.approveAgent(agent, false);
        vm.prank(agent);
        vm.expectRevert(SettlementRouter.NotApprovedAgent.selector);
        router.payForBuyer(buyer, honest, CALL_PRICE, keccak256("r"));
    }

    // ------------------------------------------------------------ claims

    function test_RevertClaimBelowMinBatch() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 2); // < MIN_BATCH, < high value
        _expireReceipts();
        vm.prank(watcher);
        vm.expectRevert(ClaimManager.BatchTooSmall.selector);
        cm.fileClaim(deadbeat, ids);
    }

    function test_SingleHighValueClaimAllowed() public {
        _register(deadbeat, 500e6);
        vm.prank(buyer);
        policy.setPolicy(uint128(100e6), uint128(500e6), uint64(block.timestamp + 1 days), true, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = _pay(deadbeat, HIGH_VALUE, keccak256("big"));
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        assertGt(claimId, 0);
    }

    function test_RevertClaimBeforeDeadline() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 3);
        vm.prank(watcher);
        vm.expectRevert(ClaimManager.DeadlineNotPassed.selector);
        cm.fileClaim(deadbeat, ids);
    }

    function test_BatchClaimSlashRefundsBuyersFromBond() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 5);
        uint256 refundTotal = CALL_PRICE * 5;
        _expireReceipts();

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 watcherBefore = usdc.balanceOf(watcher);

        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        _endDefense();
        cm.resolve(claimId);

        // buyer refunded FROM SELLER BOND (buyer never escrowed anything)
        assertEq(usdc.balanceOf(buyer), buyerBefore + refundTotal);

        // watcher: stake back + 75% of the 20% penalty
        uint256 penalty = (refundTotal * PENALTY_BPS) / 10_000;
        uint256 watcherShare = (penalty * WATCHER_SHARE_BPS) / 10_000;
        assertEq(usdc.balanceOf(watcher), watcherBefore + watcherShare);

        // treasury: remainder of penalty
        assertEq(usdc.balanceOf(treasury), penalty - watcherShare);

        // bond debited by refund + penalty
        (uint256 bond,,, uint32 failed,,,,,) = registry.getSeller(deadbeat);
        assertEq(bond, 500e6 - refundTotal - penalty);
        assertEq(failed, 5);

        // all payments refunded
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(uint8(router.getPayment(ids[i]).status), uint8(SettlementRouter.Status.Refunded));
        }
    }

    function test_ReputationAndDelisting() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 5); // 5 served, 5 failed = 100% fail ratio
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        _endDefense();
        cm.resolve(claimId);

        assertFalse(registry.isActive(deadbeat)); // delisted: ratio > 20%
        (,, uint32 served, uint32 failed,,,,,) = registry.getSeller(deadbeat);
        assertEq(served, 5);
        assertEq(failed, 5);
    }

    // -------------------------------------------------------------- defense

    /// Seller committed on-time attestations for 4 of 5 payments; those 4 are
    /// defensible and drop out of the claim, only the 5th slashes.
    function test_DefenceKnocksOutOnTimeAttestedItems() public {
        _register(honest, 500e6);
        uint256[] memory ids = _payN(honest, 5);
        for (uint256 i = 0; i < 4; i++) {
            _attestSeller(ids[i], honestKey); // seller commits evidence ON TIME
        }
        _expireReceipts();

        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(honest, ids);

        uint256[] memory defended = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            defended[i] = ids[i];
        }
        vm.prank(honest);
        cm.defend(claimId, defended);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        _endDefense();
        cm.resolve(claimId);

        // only the one undefended payment refunds
        assertEq(usdc.balanceOf(buyer), buyerBefore + CALL_PRICE);
        (,,, uint32 failed,,,,,) = registry.getSeller(honest);
        assertEq(failed, 1);
        assertTrue(registry.isActive(honest)); // 1/5 = 20% = threshold, not breached
    }

    /// §10 CORE: a seller that did NOT commit evidence on time cannot fabricate a
    /// defense after the claim is filed. defend() reads only pre-committed
    /// on-chain state, so there is no signature to backdate.
    function test_LateFabricatedDefenceIsImpossible() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 3); // seller never attests on time
        _expireReceipts();

        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);

        // Seller tries to defend with no committed evidence -> rejected outright.
        vm.prank(deadbeat);
        vm.expectRevert(ClaimManager.NotDefensible.selector);
        cm.defend(claimId, ids);

        // Attempting to attest now is also refused — the window is closed.
        SettlementRouter.Payment memory p = router.getPayment(ids[0]);
        ReceiptLib.Attestation memory a =
            ReceiptLib.Attestation({paymentId: ids[0], requestHash: p.requestHash, responseHash: _respHash(ids[0])});
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(deadbeatKey, cm.attestationDigest(a));
        vm.expectRevert(ClaimManager.NotAttestable.selector); // status is Claimed now
        cm.attest(a, abi.encodePacked(rr, ss, v));

        // Claim resolves against the seller: buyer refunded, seller slashed.
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _endDefense();
        cm.resolve(claimId);
        assertEq(usdc.balanceOf(buyer), buyerBefore + CALL_PRICE * 3);
    }

    /// Case D: buyer attested but the seller never did — no seller evidence, so
    /// the payment is NOT defensible and the seller is slashed.
    function test_BuyerOnlyEvidenceIsNotDefensible() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 3);
        for (uint256 i = 0; i < 3; i++) {
            _attestWith(ids[i], buyerKey, _respHash(ids[i])); // buyer attests, seller silent
        }
        _expireReceipts();

        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        vm.prank(deadbeat);
        vm.expectRevert(ClaimManager.NotDefensible.selector);
        cm.defend(claimId, ids);
    }

    /// Case E: a contradicting on-time buyer attestation blocks the seller's
    /// defense — a mismatch is resolved toward the buyer.
    function test_MismatchIsNotDefensible() public {
        _register(honest, 500e6);
        uint256[] memory ids = _payN(honest, 3);
        for (uint256 i = 0; i < 3; i++) {
            _attestWith(ids[i], honestKey, keccak256("A")); // seller
            _attestWith(ids[i], buyerKey, keccak256("B")); // buyer contradicts
        }
        _expireReceipts();

        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(honest, ids);
        vm.prank(honest);
        vm.expectRevert(ClaimManager.NotDefensible.selector);
        cm.defend(claimId, ids);
    }

    function test_FalseClaimForfeitsStakeToSeller() public {
        _register(honest, 500e6);
        uint256[] memory ids = _payN(honest, 3);
        for (uint256 i = 0; i < 3; i++) {
            _attestSeller(ids[i], honestKey); // all committed on time -> all defensible
        }
        _expireReceipts();

        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(honest, ids);
        (,,, uint256 stake,,,,) = cm.getClaim(claimId);

        vm.prank(honest);
        cm.defend(claimId, ids); // defends everything

        uint256 sellerBefore = usdc.balanceOf(honest);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _endDefense();
        cm.resolve(claimId);

        assertEq(usdc.balanceOf(honest), sellerBefore + stake); // stake forfeited to seller
        assertEq(usdc.balanceOf(buyer), buyerBefore); // no refunds
        (,,, uint32 failed,,,,,) = registry.getSeller(honest);
        assertEq(failed, 0); // reputation untouched
        assertTrue(registry.isActive(honest));
    }

    function test_RevertDefendAfterWindow() public {
        _register(honest, 500e6);
        uint256[] memory ids = _payN(honest, 3);
        for (uint256 i = 0; i < 3; i++) {
            _attestSeller(ids[i], honestKey);
        }
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(honest, ids);
        _endDefense();

        vm.prank(honest);
        vm.expectRevert(ClaimManager.DefenseWindowOver.selector);
        cm.defend(claimId, ids);
    }

    function test_RevertResolveDuringDefenseWindow() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 3);
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        vm.expectRevert(ClaimManager.DefenseWindowOpen.selector);
        cm.resolve(claimId);
    }

    function test_NoDoubleResolutionOfPayment() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 3);
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);

        // cannot include the same payments in a second claim while claimed
        vm.prank(watcher);
        vm.expectRevert(ClaimManager.PaymentNotClaimable.selector);
        cm.fileClaim(deadbeat, ids);

        _endDefense();
        cm.resolve(claimId);
        vm.expectRevert(ClaimManager.AlreadyResolved.selector);
        cm.resolve(claimId);

        // refunded payments cannot be re-claimed either
        vm.prank(watcher);
        vm.expectRevert(ClaimManager.PaymentNotClaimable.selector);
        cm.fileClaim(deadbeat, ids);
    }

    // ------------------------------------------------------------ E2E demo

    /// Replays the full demo story as living documentation.
    function test_DemoScript() public {
        // 1. two sellers stake 500 mUSDC
        _register(honest, 500e6); // WeatherOracle
        _register(deadbeat, 500e6); // AlphaSignals

        // 2. agent buys five $0.10 calls from each — instant settlement
        uint256[] memory honestIds = _payN(honest, 5);
        uint256[] memory deadIds = _payN(deadbeat, 5);

        // 3. WeatherOracle delivers: seller AND buyer attest the same bytes
        for (uint256 i = 0; i < 5; i++) {
            _confirm(honestIds[i], honestKey);
        }

        // 4. deadlines pass; watcher aggregates AlphaSignals' 5 failures
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, deadIds);

        // 5. defense window elapses with no committed evidence; one tx slashes
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _endDefense();
        cm.resolve(claimId);

        // buyer refunded $0.50 from AlphaSignals' bond
        assertEq(usdc.balanceOf(buyer), buyerBefore + CALL_PRICE * 5);
        // AlphaSignals delisted, reputation floored
        assertFalse(registry.isActive(deadbeat));
        // WeatherOracle untouched, capacity fully recycled, 5 confirmed deliveries
        assertTrue(registry.isActive(honest));
        (, uint256 exposure,, uint32 failed,,,,, uint32 confirmed) = registry.getSeller(honest);
        assertEq(exposure, 0);
        assertEq(failed, 0);
        assertEq(confirmed, 5);
        // agent's next payment to the delisted seller is refused at the rail
        vm.prank(buyer);
        vm.expectRevert();
        router.pay(deadbeat, CALL_PRICE, keccak256("never again"));
    }
}